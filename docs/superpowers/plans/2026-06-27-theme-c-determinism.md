# Theme C — Deterministic Test Mode — Implementation Plan (TDD)

Spec: `docs/superpowers/specs/2026-06-27-theme-c-determinism-design.md`. Issue #84.

Build/test gate (trust the `Build Summary: N/N tests passed` line):
`mise exec zig@0.16.0 -- zig build test --summary all`

## Task 1 — `datetime.formatUtc`: unix seconds → `YYYY-MM-DD HH:MM:SS`

The override substitutes a frozen instant as a UTC datetime string, so we need the inverse
of `daysFromCivil`.

- **Test (red):** add to `datetime.zig` — `formatUtc(0)` == `"1970-01-01 00:00:00"`;
  `formatUtc(86400)` == `"1970-01-02 00:00:00"`; round-trip
  `parse(formatUtc(frozen_unix)) == frozen_unix` for `1867593600`; a pre-epoch value
  (negative) formats correctly.
- **Impl (green):** add `civilFromDays` (Hinnant inverse, `@divFloor` for negatives) and
  `formatUtc(unix: i64) [19]u8` (fixed-width buffer) or
  `formatUtcBuf(buf: []u8, unix) []const u8`.
- Commit.

## Task 2 — `src/clock_sql.zig`: register date/time overrides; add to `root.zig` test block

- Add `_ = @import("clock_sql.zig");` to the `test {}` block in `src/root.zig` (new file's
  tests don't run until listed).
- **Test (red), via an in-memory `Db` with `register` called on it:**
  1. No freeze: `SELECT unixepoch('now')` returns a plausible recent wall-clock value
     (> 2020); `SELECT datetime('2020-01-02 03:04:05')` returns that explicit value
     unchanged (pass-through).
  2. Frozen (`clock.setForTest(frozen_unix)`, dev build only): `SELECT unixepoch('now')`
     == `frozen_unix`; `SELECT datetime('now')` == `"2029-03-07 16:00:00"`;
     `SELECT date('now')` == `"2029-03-07"`; `SELECT strftime('%Y', 'now')` == `"2029"`;
     `SELECT datetime('now','+1 day')` == `"2029-03-08 16:00:00"` (modifier still works);
     zero-arg `SELECT datetime()` == frozen; explicit non-`now`
     `SELECT unixepoch('2020-01-01')` is unchanged.
  3. PROD GATE: when `!clock.enabled`, even with `setForTest`, `SELECT unixepoch('now')`
     is wall-clock (> 2020) — register is a comptime no-op.
- **Impl (green):** `register(handle: *c.sqlite3) void` — `if (comptime !clock.enabled)
  return;` then `sqlite3_create_function` for each of `date`/`time`/`datetime`/`julianday`/
  `unixepoch`/`strftime` with `nArg = -1`, `SQLITE_UTF8`, `pApp` = static name pointer,
  the shared `xFunc` callback, null step/final. `xFunc` does the delegate-to-helper logic
  from the spec. Global helper connection, lazy-opened, guarded by `std.atomic.Mutex`
  (matching `db.zig`).
- Commit.

## Task 3 — wire registration into connection open (`db.zig`)

- `Db.open` (covers the writer and `openMemory`) and `Pool.openReader` (the reader path
  that uses raw `sqlite3_open_v2`) call `clock_sql.register(handle)` after the existing
  setup/pragmas. Gated comptime inside `register`, so release is unaffected.
- **Test:** the determinism test for a pooled `Db` (writer via the pool) returns the frozen
  instant for `datetime('now')`.
- Commit.

## Task 4 — verification

- `zig build test --summary all` → all pass.
- `zig build -Doptimize=ReleaseSafe` compiles (prod path).
- `zig build test -Ddev-clock=false --summary all` → the dev-clock-off path compiles and
  the PROD GATE tests confirm no freeze.
- Commit any fixups.

## Task 5 — docs + changelog

- Update `KNOWN_LIMITATIONS.md` (the #84 note: consumer `datetime('now')` is now frozen;
  narrow the remaining limitation to `CURRENT_TIMESTAMP`/column DEFAULTs).
- Update `src/clock.zig`'s module doc "Scope" comment (now includes consumer SQL `'now'`).
- Update `docs/*.md` mention of the test clock + the `site/src/content/` mirror; keep in
  sync; `cd site && npm run build` must pass.
- Add `changelog.d/theme-c-determinism.md` with a `### Features` (and `### Internal` if
  apt) section.
- Commit.

## Task 6 — stretch: seeded entropy (only if clean)

- Evaluate `ZIGBASE_FAKE_SEED` for `crypto.genToken`/IDs behind the same comptime gate.
  If it cascades or risks prod, SKIP and note as future work. Do not compromise #84.

## Task 7 — PR

- Push to `feat/theme-c-determinism`; open PR against `main` referencing #84.
