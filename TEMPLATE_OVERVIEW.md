# Deploy and Host Marmot on Railway

[Marmot](https://github.com/marmotdata/marmot) is an open-source data catalog. It indexes the tables,
topics, queues and APIs you already run, enriches them with ownership and business context, and makes
all of it searchable — by your team in a web UI, and by your AI agents over MCP.

This template runs it on Railway with Postgres alongside it, and replaces Marmot's default
`admin:admin` credential before the service is ever reachable from the internet.

## About Hosting Marmot

Marmot ships as a single static Go binary with its frontend embedded, so the deployed service is one
process with one HTTP port carrying the UI, the REST API and the MCP endpoint. The only thing it
needs beside itself is PostgreSQL, which this template provisions and wires up for you. It runs its
own schema migrations at startup, so there is nothing to initialise by hand.

The catalog lives entirely in Postgres — assets, lineage, glossary, teams, users, API keys. The
volume attached to the service holds only Marmot's plugin cache, which is rebuildable.

Two things are worth knowing before the first deploy. Marmot installs its connector plugins from a
container registry when it starts — 71 of them in 0.11.0, roughly 1.5 GB — and there is no setting to
narrow that list, so the first boot takes a few minutes and the volume exists to make sure you only
pay for it once.
And Marmot's built-in account is `admin:admin` until it is changed, which this template does on your
behalf before the public listener ever opens.

## Why Deploy Marmot on Railway?

- **A catalog your agents can read.** The MCP endpoint is part of the same service — no sidecar.
- **Postgres included and wired.** No connection strings to assemble.
- **Safe out of the box.** The default credential is replaced before anything can reach it.
- **SSO when you want it.** Google, GitHub, GitLab, Keycloak, Okta, Slack, Auth0 and generic OIDC.
- **It stays awake.** Scheduled ingestion keeps running with no machine of your own left on.

## Common Use Cases

- Giving an AI agent real metadata about your data estate instead of guesses.
- A searchable inventory of tables, topics, queues and APIs across several systems.
- Tracing lineage from source to destination before making a breaking change.
- Documenting ownership and business context where the whole team can find it.

## Dependencies for Marmot Hosting

- PostgreSQL 14 or later — provisioned by this template.
- Outbound access to `ghcr.io` on first boot, for the connector plugins.

### Deployment Dependencies

- Upstream project: [marmotdata/marmot](https://github.com/marmotdata/marmot) (MIT), image
  `ghcr.io/marmotdata/marmot:0.11.1`.
- Upstream documentation: [Marmot docs](https://marmotdata.io/docs/introduction).
- Template source: [RockinPaul/marmot_railway_template](https://github.com/RockinPaul/marmot_railway_template) (MIT).

### Implementation Details

**After deploying:** copy `MARMOT_ADMIN_PASSWORD` from the service's Variables tab, open the public
domain and sign in as **`admin`**. The first boot takes several minutes while the connector plugins
download; later deployments reuse the cache on the volume.

**Why the default credential is replaced automatically.** Upstream's Docker guide states that the
default username and password is `admin:admin` and tells you to change it after first login. On a
public domain, the window between "deployed" and "you got around to it" is a catalog, a REST API and
an MCP endpoint open to whoever tries the obvious pair. So on first boot the entrypoint starts Marmot
bound to loopback, signs in with the default credential, replaces the password with the generated
one, stops that instance, and only then opens the public listener. It is idempotent: on later boots
the default login fails, the step is skipped, and a password you rotated yourself is left alone.

**Keep `MARMOT_ENCRYPTION_SEED`.** Marmot encrypts stored pipeline credentials with
XChaCha20-Poly1305, whose key must be exactly 32 bytes — not something a random secret string can
satisfy — so the key is derived from this seed deterministically. The same seed always produces the
same key, which is what lets credentials survive a redeploy. Losing the seed costs you the stored
pipeline credentials and nothing else, because the rest of the catalog is in Postgres.

**If you deployed this template while it ran Marmot 0.10.0, update.** That release answers
`GET /api/v1/plugins` and `GET /api/v1/plugins/aws/credentials/status` without signing in — a
read-only disclosure of which connector plugins are registered and whether the server holds AWS
credentials, never the credentials themselves. 0.11.0 requires a signed-in user with ingestion
permissions for both, and also signs out existing sessions when a password changes, disables a
deactivated user's API keys and requires `assets:view` for catalog search. Users, passwords, API keys
and the catalog carry over; Marmot migrates the database on the first boot, and that boot re-downloads
the plugin set, so it is as slow as the first deploy.

**Notes.** The healthcheck is `/readyz`, which Marmot serves without credentials. `PORT` is 8080 and
the domain targets it. The service runs as a non-root user, as upstream intended; the entrypoint is
root only long enough to hand the Railway volume to it. The restart policy is `ALWAYS` and the
healthcheck timeout is generous, for that first plugin install.

## Licences

Marmot is MIT. The template's glue is MIT.
