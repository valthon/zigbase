### Features
- New `zigbase import` subcommand + `zigbase.Import` library entrypoint: encryption-aware,
  offline (no HTTP server) bulk NDJSON record import that streams and batches through the
  record engine — validation, defaults, `.encrypted` field envelope, and auth password
  hashing all applied — with optional `--upsert-key` idempotency and source-id preservation.
