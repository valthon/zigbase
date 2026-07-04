# Admin UI Phase 4 — Logs & realtime view — Design

**Goal:** Add a read-only **Logs & realtime** admin view (`/_/#/logs`) — a
filterable analytics event log, an app-declared rollup viewer, and a realtime
health strip. The final admin area, after merged Phases 1 (Users), 2 (Email),
and 3 (Files).

**Architecture:** A new `src/admin/views/logs.js` ES module on the Phase-1/2/3
foundation (one new `src/admin.zig` manifest row, `#/logs` route + nav,
`lib/api.js` helpers). Composes the existing superuser analytics REST endpoints;
the only new server code is one tiny read endpoint `GET /api/realtime/stats` for
the health strip (aggregate connection count + caps — the only realtime state
that is cheaply queryable).

**Tech stack:** Zig 0.16 (`ctx.app`, `auth.authenticate`, `std.json`,
`realtime/connection.zig`), Preact 10 + htm, the Phase-1/2/3 admin modules,
Playwright (`tests/admin/`, `-n auto`). One new Zig handler
(`src/api/realtime_stats.zig`) + route.

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild;
  every asset `@embedFile`-d; modules import by absolute `/_/assets/...` path.
- **Superuser-only surface.** The analytics endpoints authenticate via the
  `zb_auth` cookie (superuser sees all events; non-superuser is tenant/self
  scoped and rollups are superuser-only); `GET /api/realtime/stats` returns 403
  to non-superusers.
- **Read-only.** This view never writes: no analytics ingest (server-side
  `ctx.track()` only), no broadcast (dropped from scope), no config editing.
- **Phase 1–3 guards:** every `<select>`/filter resets its list only on a real
  change; every async `useEffect` uses an `active`-flag cleanup.
- **`data-test=` hooks**; `tests/admin/test_logs.py` under `-n auto`; touched
  `.zig` `zig fmt`-clean; run the FULL `tests/admin/` suite before finishing;
  docs/site mirror synced; a `changelog.d/` fragment.

## Confirmed API surface (verified against origin/main)

**Analytics (superuser cookie works; superuser sees all):**
- `GET /api/analytics/events` — read-only event feed from the `_events` table.
  Params: `name` (exact), `actor` (exact), `since` (`occurred_at >=`, lower bound
  only — no upper bound), `limit` (default 50, clamped 1–200), `cursor` (opaque
  keyset `"<occurred_at>|<id>"`; malformed → 400). Returns
  `{ items:[{id, created, name, payload, actor_collection, actor, account, occurred_at}], nextCursor: <string|null>, hasNext: <bool> }`.
- `GET /api/analytics/rollups/:name` — read-only aggregated series for a rollup
  **pre-declared in the app** (unknown name → 404, no oracle). Params: `from`
  (`bucket >=`), `to` (`bucket <=`). Returns `{ items:[{bucket, account, actor, value, computed_at}] }`.
- NOTE: `_events` is a migration table, NOT a registered collection — not
  reachable via the records API. There is no general request/audit log; only
  app-defined analytics events. There is NO endpoint that lists which rollups a
  server declares (rollups are app-comptime) → the viewer takes a rollup name as
  input rather than a picker.

**Realtime — introspection is essentially absent:**
- No HTTP endpoint enumerates connections or topics (no connection registry;
  subscriptions live inside facil.io). The only cheaply queryable global state:
  `connection.connectionCount()` (a live atomic, `realtime/connection.zig:19`),
  plus the static caps `MAX_CONNECTIONS = 10000`, `MAX_SUBS = 256`
  (`connection.zig:6,12`) and the live `app.realtime_outbound_hwm` (default
  `DEFAULT_OUTBOUND_HWM = 1024`). Per-connection/topic enumeration and admin
  broadcast are out of scope (would need substantial new backend bookkeeping).

## New backend: `GET /api/realtime/stats` (the only new server code)

A minimal superuser read endpoint for the health strip:

```json
{ "connections": 3, "max_connections": 10000, "max_subs": 256, "outbound_hwm": 1024 }
```

- `connections` = `connection.connectionCount()`; `max_connections` /
  `max_subs` = the `connection.zig` constants; `outbound_hwm` =
  `app.realtime_outbound_hwm`.
- New handler `src/api/realtime_stats.zig`; route `GET /api/realtime/stats` in
  `src/server.zig`. It's `/api/realtime/*` — placed alongside the existing
  realtime routes. Realtime is always compiled in, so the route is
  **unconditional** in the base table; superuser-gated in-handler (403 to
  non-superusers), mirroring `api/mail_config.zig` / `api/files_config.zig`.
- The plan confirms the exact `connection.zig` symbol names + how the handler
  reaches `app.realtime_outbound_hwm`.
- A Zig unit test (the constants/count map into the JSON) + browser coverage.

## View design — `src/admin/views/logs.js`

One exported `LogsView` at `#/logs`; nav item `📊 Logs`. Layout:

### Realtime health strip (top, read-only)
Fetches `GET /api/realtime/stats` once (active-flag guard); renders chips:
live connections, and the caps (`data-test=rt-connections`, `rt-caps`). Degrades
quietly on 404/error.

### Events log (the core)
- Filter row: `name` input, `actor` input, `since` datetime input →
  `data-test=logs-name` / `logs-actor` / `logs-since` + a `logs-apply` button.
- Table from `GET /api/analytics/events?…`: columns occurred_at, name, actor,
  account, and a payload cell (truncated; click a row to expand the full payload
  JSON in a detail area). `data-test=log-row`.
- **Cursor pagination** (not offset): a `Load more` button
  (`data-test=logs-more`) that appends the next page using `nextCursor`; hidden
  when `hasNext` is false. Applying a filter resets the cursor.

### Rollups viewer
- A rollup-name input (`data-test=rollup-name`) + `from`/`to` date inputs +
  `data-test=rollup-load`. On load, `GET /api/analytics/rollups/:name?from&to`
  → a table of `{bucket, account, actor, value}` (`data-test=rollup-row`). A 404
  (unknown rollup) shows a friendly "no such rollup / none declared" message
  (`data-test=rollup-none`) rather than an error.

## Out of scope (documented gaps, not built)

- Per-connection / per-topic realtime inspection (no registry exists — only the
  aggregate count is queryable).
- Sending a test broadcast (dropped from scope; would need a new hub endpoint).
- A general request/access/audit log (does not exist — only `ctx.track()`
  analytics events).
- Creating analytics events from the UI (ingest is server-side only).
- A rollup-name picker (no endpoint lists declared rollups; the viewer takes a
  name as input).

## Testing strategy

- `tests/admin/test_logs.py` (Playwright, `-n auto`): the realtime strip renders
  the connection count + caps; the events log table renders with filters and
  `Load more` cursor pagination; the rollups viewer handles an unknown rollup
  name gracefully.
- **Seeding events — RISK/PROBE:** there is NO HTTP path to create an analytics
  event (`_events` is written only by server-side `ctx.track()`, and isn't a
  records collection). The plan's test task must determine how events reach
  `_events` in the standalone test server — e.g. whether ordinary admin actions
  (record CRUD, logins) auto-emit trackable events, or whether a fixture app
  that calls `ctx.track()` on a route is needed. If neither is feasible, the
  events-log test asserts the table + filters + empty-state render correctly
  (structure), and a Zig-level test covers the events endpoint's data path. The
  realtime strip and rollups-404 paths are testable without seeded events.
- Zig unit test for `realtime_stats` (the count + caps map into JSON).

## Risks

1. **Event seeding for the test** (above) — resolve in the plan before writing
   the happy-path assertion; fall back to structure/empty-state + Zig coverage.
2. **`realtime_stats` field access** — confirm `connection.connectionCount()`
   and the `MAX_CONNECTIONS`/`MAX_SUBS` constant names, and that
   `app.realtime_outbound_hwm` is the right field, against
   `src/realtime/connection.zig` + `src/app.zig`.
3. **Route ordering** — `/api/realtime/stats` (3 segments) must not shadow or be
   shadowed by `/api/realtime/sse/:clientId` (4 segments) — different lengths, so
   safe (same as the files/mail config routes).
