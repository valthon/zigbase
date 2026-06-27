# Theme C — Deterministic Test Mode (consumer-SQL clock freeze)

**Status:** Design approved 2026-06-27. Implementation in this PR.

## Background

ZigBase already has a dev-only "now" seam (`src/clock.zig`), gated by the comptime
`build_options.dev_clock` flag (`build.zig`'s `dev-clock` option, default on in Debug,
off in release). When `ZIGBASE_FAKE_NOW` is set to an ISO-8601 UTC instant, the seam
freezes every timestamp the **framework** controls: token `iat`/`exp`, the scheduler's
next-fire math, the auth rate-limiter wall clock, the auth-challenge / keyset-cursor TTL
and expiry checks.

The gap (issue **#84**): a timestamp a **consumer** writes in their own custom SQL —
`datetime('now')`, `unixepoch('now')`, `strftime(..., 'now')` — does **not** honor the
frozen clock. Those still read the OS wall clock, so an e2e snapshot test that exercises a
consumer route doing raw SQL can never be made deterministic. This is the last hole in the
dev/test determinism seam. `KNOWN_LIMITATIONS.md` documents it as a known limitation.

## Goal

When `clock.frozenUnix()` is set (dev builds only), a consumer's raw
`datetime('now')` / `unixepoch('now')` / `strftime(fmt, 'now', ...)` / `date('now')` /
`time('now')` / `julianday('now')` resolves to the **frozen instant**, on both reader and
writer connections. When no frozen time is set, they behave exactly like the SQLite
builtins (real wall clock). On a production build (`dev_clock` off) **none** of this code
exists — the registration is `comptime`-eliminated and the binary is byte-for-byte
unaffected.

## Approach: override the date/time functions via `sqlite3_create_function`

At connection open time we register application-defined SQL functions under the **same
names** as SQLite's date/time builtins (`date`, `time`, `datetime`, `julianday`,
`unixepoch`, `strftime`). An app-defined function with a builtin's name shadows the builtin
on that connection. Our override does exactly one thing differently from the builtin: it
substitutes the `'now'` time-value with the frozen instant when a freeze is active;
otherwise it is a pass-through.

### Delegation (no re-implementation of SQLite date math)

Re-implementing SQLite's full date/time grammar (modifiers like `'+1 day'`,
`'start of month'`, `'weekday 0'`, `'localtime'`, `'unixepoch'`, fractional seconds, the
`strftime` format codes) would be large and error-prone. Instead the override **delegates**
the actual computation to a process-global helper SQLite connection that has **no overrides
registered** — so its date/time functions are the genuine builtins:

1. Read `frozen = clock.frozenUnix()`.
2. Build `SELECT <name>(?1, ?2, …, ?N)` for the call's argument count `N`.
   - `N == 0` is the implicit-`'now'` form (`datetime()` ≡ `datetime('now')`). When frozen,
     emit `SELECT <name>(?1)` and bind the frozen instant; when not frozen, emit
     `SELECT <name>()`.
3. Bind each argument by its SQLite type, with one substitution: any **text** argument that
   trims (case-insensitively) to `now`, when a freeze is active, is replaced by the frozen
   instant formatted as `YYYY-MM-DD HH:MM:SS` UTC (which SQLite interprets as UTC, matching
   `'now'`). Every other argument — explicit datetimes, numeric values, modifiers like
   `'+1 day'`, the `strftime` format string — passes through untouched.
4. Step the helper statement and forward its single-column result back to the caller via
   `sqlite3_result_*`, preserving the result's type (INTEGER / FLOAT / TEXT / NULL).

The helper connection is opened lazily once (`:memory:`, `SQLITE_OPEN_FULLMUTEX`) and used
under a small spin-mutex, so concurrent reader threads share it safely. It is dev-only and
lives for the process lifetime; performance is irrelevant in a frozen-clock dev/test build.

Because delegation goes to a *separate* connection without overrides, there is **no
recursion** and the genuine SQLite date math is reused verbatim — the only behavioral change
is the `'now'` substitution.

### Why frozen time is seconds-granular

`clock.frozenUnix()` is `i64` unix **seconds**. So `strftime('%f', 'now')` under a freeze
yields `.000` fractional seconds. This matches the rest of the clock seam (the framework
clock is also seconds-granular) and is the correct, expected behavior for a *frozen* clock.

## Production-unaffected guarantee (hard requirement)

- The new module `src/clock_sql.zig` exposes `register(handle)`. Its body begins with
  `if (comptime !clock.enabled) return;`. `clock.enabled` is `build_options.dev_clock`, a
  comptime constant. On a release build it is `false`, so the entire registration body —
  including every `sqlite3_create_function` call, the callback, and the helper connection —
  is **comptime-dead** and eliminated. No `sqlite3_create_function` call is emitted, the
  connection is identical to today's, and the env var is never read.
- This is verified by building `-Doptimize=ReleaseSafe` and `-Ddev-clock=false` and
  confirming both compile, plus the existing `PROD GATE` test in `clock_test.zig` (which
  asserts time can never be frozen when `dev_clock` is off).
- Even on a dev build, when no freeze is active the override is a faithful pass-through
  (delegates the call with arguments unchanged), so default dev behavior is unchanged too.

## What is and isn't covered

**Covered (issue #84):** `datetime`, `date`, `time`, `datetime`, `julianday`, `unixepoch`,
`strftime` with the `'now'` modifier (including the zero-argument implicit-`'now'` forms),
on reader and writer connections.

**Not covered (documented as future Theme C work):**
- `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` and SQLite column `DEFAULT`
  timestamps. These are SQL keywords / read SQLite's time directly via the VFS, not
  app-overridable functions; freezing them would require a custom VFS `xCurrentTimeInt64`.
  (Framework-managed `created`/`updated` already route through the framework clock where it
  matters; raw column DEFAULTs do not.)
- **Seeded entropy** (`ZIGBASE_FAKE_SEED` for deterministic `crypto.genToken` / ID
  generation) — a stretch goal; see the plan. Only pursued if it does not risk the prod
  path.
- **Mail outbox / outbound-HTTP capture** — explicitly out of scope for this PR.

## Alternative considered: custom VFS

A custom VFS overriding `xCurrentTimeInt64` would freeze *everything* (including
`CURRENT_TIMESTAMP` and column DEFAULTs) with no per-function code. It was rejected for this
deliverable because (a) #84's prescribed seam is `sqlite3_create_function`, (b) a VFS swap
is a heavier, more global change to the connection-open path, and (c) the function-override
approach is precisely scoped to the consumer-SQL `'now'` the issue calls out. The VFS route
is noted as the natural future step if DEFAULT/`CURRENT_TIMESTAMP` freezing is wanted.
