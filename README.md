# Marmot on Railway

[Marmot](https://github.com/marmotdata/marmot) — an open-source data catalog that indexes your
tables, topics, queues and APIs and exposes them to your team and your AI agents over MCP — on
Railway, with the default `admin:admin` credential replaced before the service is ever reachable.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/marmot)

## Services

| Service | Base | Public | Role |
|---|---|---|---|
| `marmot` | `ghcr.io/marmotdata/marmot:0.11.1` | **yes** | Catalog UI, REST API, MCP endpoint. |
| `Postgres` | Railway's `postgres-ssl` | no | All catalog state. Marmot runs its own migrations. |

Marmot ships as a single static Go binary with the frontend embedded, running as a non-root user —
this template adds the Railway environment rather than rebuilding anything.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `MARMOT_ADMIN_PASSWORD` | generated, 24 chars | Replaces Marmot's default `admin:admin` on first boot. Read it from the service variables. |
| `MARMOT_ENCRYPTION_SEED` | generated, 32 chars | The encryption key for stored pipeline credentials is derived from this. Keep it. |
| `MARMOT_ADMIN_USERNAME` | `admin` | The built-in account. Marmot refuses to delete it. |
| `MARMOT_DATABASE_*` | wired to Postgres | Host, port, user, password and database, referenced from the Postgres service. |
| `MARMOT_SERVER_ROOT_URL` | the public domain | Used to build OAuth callback URLs and CLI login redirects. |
| `PORT` | `8080` | The port Railway's healthcheck probes and the domain targets. Leave it alone. |
| `MARMOT_PLUGINS_DIR` | `/data/plugins` | Baked. Puts the plugin cache on the volume — see below. |

The deploy form asks for nothing you have to invent.

## First run

1. Copy `MARMOT_ADMIN_PASSWORD` from the service's **Variables** tab.
2. Open the public domain and sign in as **`admin`**.
3. Point an agent at `https://your-app.up.railway.app` for the MCP endpoint, or add a plugin to start
   cataloguing sources.

**The first boot is slow, and it is not broken.** Marmot installs its core plugins from `ghcr.io`
when it starts — 71 of them in 0.11.0, roughly 1.5 GB — and there is no setting to narrow that list,
only to switch it off. The 5 GB volume turns this into a one-time cost: later deployments reuse the
cache. Expect a few minutes the first time, which is why the healthcheck timeout is generous.

## Security

**Marmot's built-in account is `admin:admin`.** Upstream's own Docker guide says so and tells you to
change it after first login. On a public domain that is a catalog, its REST API and an MCP endpoint
open to anyone who tries the obvious pair, so this template does not rely on you getting there first.

On first boot the entrypoint starts Marmot bound to `127.0.0.1`, signs in as `admin:admin`, replaces
the password with the generated one, stops that instance and only then starts the public listener.
Nothing outside the container can reach the service while the default credential is still valid. The
container refuses to start without a password of at least 12 characters.

It is idempotent. On every later boot the `admin:admin` login simply fails, the bootstrap is skipped,
and the password stays whatever it was changed to — including by a person who rotated it in the UI.

Marmot also supports SSO through Google, GitHub, GitLab, Keycloak, Okta, Slack, Auth0 and generic
OIDC. `MARMOT_SERVER_ROOT_URL` is already set to your public domain, which those flows require.

**If your deployment still runs Marmot 0.10.0, update it.** That release answers
`GET /api/v1/plugins` and `GET /api/v1/plugins/aws/credentials/status` without authentication. It is
a read-only disclosure — which connector plugins the server has registered, and whether it holds AWS
credentials and where they come from, never the credentials themselves — but it is open to anyone
who finds the domain. 0.11.0 puts both behind a signed-in user with ingestion permissions. The same
release also enforces a pending password change on the API rather than only on the login page,
disables a deactivated user's API keys, requires `assets:view` for catalog search, and signs out
existing sessions when a password changes. The update keeps users, passwords, API keys and the
catalog: Marmot migrates the database itself on the first boot.

## The encryption key

`MARMOT_SERVER_ENCRYPTION_KEY` has to base64-decode to exactly 32 bytes, because Marmot encrypts
stored pipeline credentials with XChaCha20-Poly1305. Railway's `${{secret(N)}}` produces a random
alphanumeric string, which is not that — so the template generates `MARMOT_ENCRYPTION_SEED` and the
entrypoint derives the key from it with SHA-256.

The derivation is deterministic, so the same seed always yields the same key and credentials
encrypted by one deployment stay readable by the next. **Keep the seed.** Losing it means losing
access to stored pipeline credentials — nothing else, since everything else lives in Postgres.

## Why it is shaped this way

- **No proxy.** Unlike some templates here, Marmot has real authentication, and `/readyz` is public,
  so Railway's healthcheck can probe it directly without opening a hole.
- **The bootstrap runs on loopback.** The safest moment to replace a default credential is before the
  service has a public interface at all.
- **`MARMOT_PLUGINS_DIR` on the volume.** `MARMOT_PLUGIN_CACHE_DIR` defaults to
  `$MARMOT_PLUGINS_DIR/cache`, so one variable moves both and a 1.5 GB download becomes a one-time
  cost.
- **The cache is cleared when the Marmot version changes.** Every release pins its own version of
  each plugin, and Marmot never deletes the old ones — going from 0.10.0 to 0.11.0 left 2.3 GB on the
  volume where the live set needs 1.5 GB. The entrypoint records which version filled the cache and
  wipes it when the binary differs, so the volume holds one release's plugins at a time.
- **Root only long enough to hand over the volume.** Railway mounts volumes root-owned; the
  entrypoint chowns `/data` to uid 10001 and drops back with `su-exec` before exec'ing the server, so
  the service itself still runs unprivileged as upstream intended.
- **`restartPolicyType: ALWAYS`** with a 900 s healthcheck timeout, for that first plugin install.

## What persists

Postgres holds the catalog: assets, lineage, glossary, teams, users, API keys. The volume holds only
the plugin cache, which is rebuildable — if you lose it, the next boot downloads it again. Plugins you
install by hand go in `/data/plugins` itself, outside the cache, and are never cleared.

## Upgrading

Bump `MARMOT_VERSION` in the `Dockerfile` and push. Marmot runs its own migrations at startup. The
first boot on a new version clears the plugin cache and downloads that release's set, so it takes as
long as the first deploy did.

## Licences

Marmot is [MIT](https://github.com/marmotdata/marmot/blob/main/LICENSE). The glue in this repository
is MIT as well.
