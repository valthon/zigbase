### Fixes

- `ZIGBASE_DB_URL` (the SQLite-vs-Postgres selector), `ZIGBASE_PUBLIC_URL` (magic-link URL base), and `ZIGBASE_SENDMAIL_COMMAND` are now documented in the README env table and `zigbase help` — they were previously undiscoverable.
- Field-encryption (`ZIGBASE_FIELD_KEY`, `ZIGBASE_FIELD_KEY_GENERATION`, `ZIGBASE_FIELD_KEY_V<n>`) env vars are now in the README env table (previously only in `zigbase help`). OAuth (`ZIGBASE_OAUTH_STATE_SERVER`/`_STATE_TTL`), rate-limit (`ZIGBASE_RATE_LIMIT_MAX`/`_WINDOW`), and SMTP (`ZIGBASE_SMTP_*`) env vars are now in `zigbase help` (previously only in the README).

### Internal

- Doc-drift guard: `tests/admin/test_docs_parity.py` fails CI when a `ZIGBASE_*` var referenced in `src/` is missing from the README table or the help text.
