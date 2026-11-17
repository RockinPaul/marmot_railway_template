#!/bin/sh
set -eu

MARMOT_UID=10001
MARMOT_GID=10001
DATA_DIR="$(dirname "${MARMOT_PLUGINS_DIR:-/data/plugins}")"
BOOTSTRAP_PORT=18080
umask 077

export MARMOT_SERVER_PORT="${PORT:-8080}"

# ---------------------------------------------------------------------------
# Fail closed on the admin credential
# ---------------------------------------------------------------------------
# Marmot ships with a default account of admin:admin — upstream's Docker guide
# says so and tells you to change it after first login. On a public Railway
# domain that is a data catalog, its REST API and an MCP endpoint standing open
# to whoever tries the obvious pair, so this template replaces the password
# before the service is ever reachable, and refuses to start without one.
if [ -z "${MARMOT_ADMIN_PASSWORD:-}" ] || \
   [ "$(printf '%s' "${MARMOT_ADMIN_PASSWORD}" | wc -c)" -lt 12 ]; then
    echo "FATAL: MARMOT_ADMIN_PASSWORD is empty or shorter than 12 characters." >&2
    echo "  Marmot's built-in account is admin:admin until it is changed. This" >&2
    echo "  template changes it on first boot, before the service accepts a" >&2
    echo "  single public request. The template generates a password; read it" >&2
    echo "  from the service's Variables tab." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Encryption key
# ---------------------------------------------------------------------------
# MARMOT_SERVER_ENCRYPTION_KEY must base64-decode to exactly 32 bytes, because
# Marmot uses XChaCha20-Poly1305 for pipeline credentials. Railway's
# ${{secret(N)}} produces a random alphanumeric string, which is not that, so
# the template generates a seed and the key is derived from it here.
#
# The derivation is deterministic: the same seed always yields the same key, so
# credentials encrypted by one deployment stay readable by the next. Losing the
# seed means losing access to stored pipeline credentials, nothing else.
if [ -z "${MARMOT_SERVER_ENCRYPTION_KEY:-}" ]; then
    if [ -z "${MARMOT_ENCRYPTION_SEED:-}" ]; then
        echo "FATAL: neither MARMOT_SERVER_ENCRYPTION_KEY nor MARMOT_ENCRYPTION_SEED is set." >&2
        echo "  One of them is required to encrypt stored pipeline credentials." >&2
        exit 1
    fi
    MARMOT_SERVER_ENCRYPTION_KEY="$(
        printf '%s' "${MARMOT_ENCRYPTION_SEED}" | sha256sum | cut -d' ' -f1 \
            | xxd -r -p | base64 | tr -d '\n'
    )"
    export MARMOT_SERVER_ENCRYPTION_KEY
fi

# ---------------------------------------------------------------------------
# Refresh the rebuildable plugin cache when the Marmot release changes
# ---------------------------------------------------------------------------
# The cache keeps one directory per plugin version without deleting old ones.
# Refresh it on a release change so obsolete versions do not consume the volume;
# a cache with no marker predates this check. Within a release, retain the cache,
# including security updates installed by Marmot's signed-index background updater.
PLUGINS_DIR="${MARMOT_PLUGINS_DIR:-/data/plugins}"
CACHE_DIR="${MARMOT_PLUGIN_CACHE_DIR:-${PLUGINS_DIR}/cache}"
VERSION_MARKER="${PLUGINS_DIR}/.cache-marmot-version"
MARMOT_BUILD="$(marmot version 2>/dev/null | head -n 1)"
if [ -n "${MARMOT_BUILD}" ] && [ -d "${CACHE_DIR}" ] && \
   [ "$(cat "${VERSION_MARKER}" 2>/dev/null)" != "${MARMOT_BUILD}" ]; then
    case "${CACHE_DIR}" in
        /data/?*)
            echo "marmot: plugin cache was filled by another version, clearing it for ${MARMOT_BUILD}"
            rm -rf "${CACHE_DIR}"
            ;;
        *)
            echo "marmot: plugin cache ${CACHE_DIR} is outside /data, leaving it alone" >&2
            ;;
    esac
fi
if [ -n "${MARMOT_BUILD}" ]; then
    mkdir -p "${PLUGINS_DIR}"
    printf '%s\n' "${MARMOT_BUILD}" > "${VERSION_MARKER}"
fi

# ---------------------------------------------------------------------------
# Volume ownership
# ---------------------------------------------------------------------------
# Railway mounts volumes root-owned with a lost+found directory, and the image
# runs as uid 10001. Hand the tree over before dropping privileges.
mkdir -p "${MARMOT_PLUGINS_DIR:-/data/plugins}"
chown -R "${MARMOT_UID}:${MARMOT_GID}" "${DATA_DIR}" 2>/dev/null || true

wait_for_ready() {
    _port="$1"
    _i=0
    while [ "${_i}" -lt 600 ]; do
        if wget -q -O /dev/null "http://127.0.0.1:${_port}/readyz" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "${BOOT_PID}" 2>/dev/null; then
            echo "FATAL: marmot exited during the bootstrap pass." >&2
            exit 1
        fi
        _i=$((_i + 1))
        sleep 1
    done
    echo "FATAL: marmot did not become ready within 600s." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Replace admin:admin before the public listener opens
# ---------------------------------------------------------------------------
# The same shape as the Scrumboy template: bring the server up bound to
# loopback, take ownership of the default account, then stop it and start the
# real listener. Nothing outside the container can reach the service while the
# default credential is still valid.
#
# This is idempotent. On every later boot the admin:admin login simply fails,
# the bootstrap is skipped, and the password stays whatever it was changed to —
# including by a human who rotated it from the UI.
echo "marmot: bootstrap pass on 127.0.0.1:${BOOTSTRAP_PORT}"
# su-exec is backgrounded directly rather than through a shell function: a
# function call runs in a subshell, so $! would be the subshell's pid and the
# kill below would leave the bootstrap server running. Measured exactly that
# once — a stale listener on the bootstrap port holding database connections.
su-exec "${MARMOT_UID}:${MARMOT_GID}" \
    env MARMOT_SERVER_HOST=127.0.0.1 MARMOT_SERVER_PORT="${BOOTSTRAP_PORT}" \
    marmot run &
BOOT_PID=$!
wait_for_ready "${BOOTSTRAP_PORT}"

LOGIN_RESPONSE="$(mktemp)"
AUTH_CONFIG="$(mktemp)"
PASSWORD_BODY="$(mktemp)"
trap 'rm -f "${LOGIN_RESPONSE}" "${AUTH_CONFIG}" "${PASSWORD_BODY}"' EXIT

bootstrap_abort() {
    echo "FATAL: $1; refusing to expose the public listener." >&2
    kill -TERM "${BOOT_PID}" 2>/dev/null || true
    wait "${BOOT_PID}" 2>/dev/null || true
    exit 1
}

if ! LOGIN_STATUS="$(curl --silent --show-error --output "${LOGIN_RESPONSE}" \
        --write-out '%{http_code}' --header 'Content-Type: application/json' \
        --data '{"username":"admin","password":"admin"}' \
        "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/users/login")"; then
    bootstrap_abort "default-credential login transport failed"
fi

case "${LOGIN_STATUS}" in
    200)
        if ! jq -er '.access_token | select(type == "string" and test("^[A-Za-z0-9._~-]+$")) | "header = \"Authorization: Bearer \(.)\""' \
                "${LOGIN_RESPONSE}" > "${AUTH_CONFIG}"; then
            bootstrap_abort "default-credential login returned an invalid token"
        fi
        jq -n '{new_password: env.MARMOT_ADMIN_PASSWORD}' > "${PASSWORD_BODY}"
        if curl --fail --silent --show-error --output /dev/null \
                --config "${AUTH_CONFIG}" --header 'Content-Type: application/json' \
                --data-binary "@${PASSWORD_BODY}" \
                "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/users/update-password" 2>/dev/null; then
            echo "marmot: default admin password replaced"
        else
            bootstrap_abort "could not replace the default admin password"
        fi
        ;;
    401)
        if ! jq -e 'type == "object" and .error == "Invalid credentials"' "${LOGIN_RESPONSE}" >/dev/null; then
            bootstrap_abort "default-credential login returned an unexpected rejection"
        fi
        echo "marmot: default credential already replaced, keeping the existing password"
        ;;
    *) bootstrap_abort "default-credential login returned HTTP ${LOGIN_STATUS}" ;;
esac
rm -f "${LOGIN_RESPONSE}" "${AUTH_CONFIG}" "${PASSWORD_BODY}"
trap - EXIT

kill -TERM "${BOOT_PID}" 2>/dev/null || true
wait "${BOOT_PID}" 2>/dev/null || true

# Confirm the bootstrap listener is actually gone before opening the public
# one. A leaked instance would keep holding database connections, and its
# silent survival is the failure this check exists to catch.
_gone=""
_i=0
while [ "${_i}" -lt 60 ]; do
    if ! wget -q -O /dev/null "http://127.0.0.1:${BOOTSTRAP_PORT}/readyz" 2>/dev/null; then
        _gone=1
        break
    fi
    _i=$((_i + 1))
    sleep 1
done
if [ -z "${_gone}" ]; then
    echo "FATAL: the bootstrap listener on ${BOOTSTRAP_PORT} did not shut down." >&2
    exit 1
fi

echo "marmot: bootstrap complete, starting public listener on 0.0.0.0:${MARMOT_SERVER_PORT}"

# exec directly rather than through the helper: exec cannot replace the shell
# with a shell function, so marmot would not become PID 1.
exec su-exec "${MARMOT_UID}:${MARMOT_GID}" marmot run "$@"
