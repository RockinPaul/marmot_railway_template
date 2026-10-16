# Changelog

## 2026-10-16 — Marmot 0.11.1

- `MARMOT_VERSION` 0.11.0 → 0.11.1 (`ghcr.io/marmotdata/marmot:0.11.1`).
- **Security fix: SQL injection through data product rules.** 0.11.0 pasted a rule's metadata field name straight into SQL. Reproduced locally through `POST /api/v1/products/rule-preview` as a signed-in user: a field containing a quote returned the raw Postgres syntax error, and a crafted field turned the rule into one that matched every asset. On 0.11.1 both return an empty match and no database error. The same fix covers label keys in metrics and enrichment queries.
- Also security-related in this release: webhook lookups are scoped to the team, webhook delivery is restricted and no longer follows redirects, and documentation images load through the authenticated API.
- No database migrations, configuration changes or new variables. The core plugin set is the same as 0.11.0.

### Upgrading an existing deployment

Nothing to change. The admin password, the encryption seed and everything in Postgres carry over. Verified locally with the template's entrypoint and variables: a 0.11.0 deployment with two assets upgraded in place, the bootstrap pass kept the existing password, the old login worked and both assets were still there. A fresh 0.11.1 deploy replaces `admin:admin` on first boot as before.

The first start after the update is slow again, like the very first deploy: the entrypoint clears the plugin cache whenever the Marmot version changes and the server downloads its core plugins (about 1.5 GB) from `ghcr.io` once more. 0.11.1 pins the same plugin versions as 0.11.0, so this download is not strictly needed this time, but the entrypoint cannot tell.
