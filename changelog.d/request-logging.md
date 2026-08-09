### Features

- Per-request access logging: every HTTP request now emits one line with its method, path, status, and duration — as a structured record under `--log-format json`, or `GET /api/health 200 3ms` in text mode. Turn it off with `--no-request-log` / `ZIGBASE_LOG_REQUESTS=false` when a reverse proxy already ships access logs.
