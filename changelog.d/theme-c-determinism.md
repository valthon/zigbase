### Features

- The `ZIGBASE_FAKE_NOW` dev test clock now also freezes a **consumer's own raw SQL**
  `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/
  `julianday`, including their zero-argument implicit-`'now'` forms). SQLite's date/time
  builtins are shadowed on every reader and writer connection so they resolve to the frozen
  instant, while explicit datetimes and modifiers (`'+1 day'`, the `strftime` format string)
  pass through to genuine SQLite. This makes e2e/snapshot tests of consumer routes that use
  raw time SQL fully deterministic (#84). Like the rest of the test clock it is **compiled
  out of production builds** (`dev_clock` build option; off in any release build) — a prod
  binary is byte-for-byte unaffected and never reads the env var.
