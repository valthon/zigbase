### Features

- `zigbase serve --background` detaches the server into its own process group, writing
  its output to `<data-dir>/serve.log` and exiting 0 only once the server actually
  answers `GET /api/health` — so a script or agent can start a server and immediately
  use it. Manage it with `zigbase serve status [--json]`, `zigbase serve stop`
  (idempotent), and `zigbase serve logs [--follow]`. Liveness is an `flock(2)` held for
  the process lifetime, so a `kill -9`'d session is detected as gone rather than
  lingering as a stale pid file.
- A detected AI-agent environment (`CLAUDECODE`, `CODEX_THREAD_ID`, `GEMINI_CLI`, and
  the rest of the usual table) makes `zigbase serve` background itself automatically,
  printing which provider was detected and how to turn it off. Set
  `ZIGBASE_SERVE_BACKGROUND=0` to opt out, or `=1` to force background mode anywhere.
