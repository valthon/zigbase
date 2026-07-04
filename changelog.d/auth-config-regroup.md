### Breaking

- Auth configuration is now grouped under one comptime `App(.{ .auth = .{ … } })` key. The previously-scattered top-level auth keys moved under it:
  - `.auth = .{ .beforeRegister = fn, … }` (the flat lifecycle-hook group) → `.auth = .{ .hooks = .{ .beforeRegister = fn, … } }`
  - `.auth_methods = .{ … }` → `.auth = .{ .methods = .{ … } }` (both the bare-tuple and `.{ .builtins, .custom }` forms)
  - `.captcha = .{ .provider, .secret }` → `.auth = .{ .captcha = .{ … } }`
  - `.session_store = .epoch | .table` → `.auth = .{ .session = .{ .store = … } }`
  - `.session_gc_cron = "…"` → `.auth = .{ .session = .{ .gc_cron = "…" } }`

  Each old spelling is now a pointed `@compileError` naming its new location, so consumers get an actionable migration message rather than a silent no-op. Runtime auth knobs (`ZIGBASE_AUTH_TOKEN_TTL`, `ZIGBASE_OAUTH_STATE_*`, cookie security, `ZIGBASE_RATE_LIMIT_*`) intentionally remain env-configured and are **not** part of the `.auth` group.
