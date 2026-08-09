### Features

- `zigbase serve logs --json` prints only the structured NDJSON records from `serve.log`,
  dropping the plain-text startup banner the HTTP layer writes to the same file — so
  `zigbase serve logs --json | jq` works against a real log file instead of failing on the
  first non-JSON line. It composes with `--follow`, and says so on stderr when the file
  holds no records at all (the usual cause being a session started without
  `--log-format json`).
