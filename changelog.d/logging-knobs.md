### Features

- `--log-format text|json` / `ZIGBASE_LOG_FORMAT` switches the whole log stream to one JSON object per line on stderr, and `--log-level` / `ZIGBASE_LOG_LEVEL` sets the minimum severity (`debug`, `info`, `warn`, `error`). The env vars apply to every subcommand; the flags are `serve`-only.
- New guide: **Observability & machine-readable output** (`docs/observability.md`) — the log formats, the NDJSON consumption rule, the frozen error-code registry, and the `--json` CLI conventions.
