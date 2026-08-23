### Features

- Added the official `zigbase-migrate-rails-api` Agent Skill and public guide for re-platforming a
  Rails API-only backend onto ZigBase, with an observed-versus-inferred source inventory, durable
  schema/endpoint/auth/side-effect decisions, deterministic NDJSON extraction that preserves ids,
  timestamps, relations, files, and supported bcrypt credentials, OpenAPI reconciliation, parity
  replay covering success, validation-failure, unauthenticated, and unauthorized cases, and a
  rehearsed cutover with an explicit backend-only scope gate.
- Added the offline `tools/rails/rails2zb.py` converter and its `tools/rails/export_source.rb`
  observed-metadata extractor, covering Rails inventory, durable decisions, deterministic
  extraction, and Active Storage file installation.
- The converter refuses to emit anything the target would silently discard: a column whose name
  ZigBase reserves (`email`, `verified`, `created` and the rest, compared case-insensitively) is a
  recorded decision rather than a field `schema apply` drops without a word, names that collide
  after `_id` is stripped keep their full column name, and a table, column, or Active Storage
  attachment whose name the target cannot accept is raised at inventory time, with `rename` (the
  replacement is carried through to the emitted schema) or `omit`, rather than failing
  mid-migration. Values are
  checked against the target's own rules too, so an impossible date, an orphan relation, a
  duplicate or malformed auth email, or text that is not UTF-8 stops the extraction instead of
  stopping the import halfway. `report.json` records what was dropped or relaxed along the way.
