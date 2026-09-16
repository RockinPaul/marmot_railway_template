# Marmot on Railway — a thin wrapper over upstream's own image.
#
# Nothing is rebuilt. Upstream publishes multi-arch images and already does the
# hard parts well: a static Go binary with the frontend embedded, on Alpine, as
# a non-root user. This layer adds the Railway environment, moves the plugin
# cache onto a volume, and replaces the default admin:admin credential before
# anything can reach it.
ARG MARMOT_VERSION=0.10.0
FROM ghcr.io/marmotdata/marmot:${MARMOT_VERSION}

# The entrypoint needs root to hand the root-owned Railway volume to the
# marmot user; it drops back to uid 10001 with setpriv before exec'ing the
# server, so the service itself still runs unprivileged.
USER root

# BusyBox's setpriv is a capabilities-only stub with no --reuid, so the usual
# Alpine tool for dropping privileges is needed. su-exec is ~10 KB and is
# signal-transparent, which matters because it becomes PID 1's child.
RUN apk add --no-cache su-exec

# Marmot installs 31 core plugins from ghcr.io at every startup — about 800 MB
# — and there is no setting to skip or narrow that list. Pointing the plugins
# directory at the volume turns it into a one-time download instead of a cost
# paid on every redeploy. MARMOT_PLUGIN_CACHE_DIR defaults to <plugins>/cache,
# so this one variable moves both.
ENV MARMOT_PLUGINS_DIR=/data/plugins \
    MARMOT_SERVER_HOST=0.0.0.0 \
    MARMOT_ADMIN_USERNAME=admin \
    PORT=8080

COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint
ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]
