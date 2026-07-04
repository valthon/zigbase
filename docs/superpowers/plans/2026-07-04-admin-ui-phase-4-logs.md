# Admin UI Phase 4 — Logs & realtime view — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only **Logs & realtime** admin view (`/_/#/logs`) — a realtime health strip, a filterable analytics event log with cursor pagination, and an app-declared rollup viewer — plus a small `GET /api/realtime/stats` endpoint.

**Architecture:** A new `src/admin/views/logs.js` ES module on the Phase-1/2/3 foundation (one new `src/admin.zig` manifest row, `#/logs` route + nav, `lib/api.js` helpers). Composes the existing superuser analytics endpoints; the only new server code is `src/api/realtime_stats.zig` + a route (reads `connection.zig` constants/count + `app.realtime_outbound_hwm`).

**Tech Stack:** Zig 0.16 (`ctx.app`, `auth.authenticate`, `std.json`, `realtime/connection.zig`), Preact 10 + htm, the Phase-1/2/3 admin modules, Playwright (`tests/admin/`, `-n auto`).

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild; every asset `@embedFile`-d; modules import by absolute `/_/assets/...` path.
- **Superuser-only, read-only.** The view never writes. `GET /api/realtime/stats` → 403 for non-superusers. Analytics endpoints accept the `zb_auth` cookie (superuser sees all events).
- **Phase 1–3 guards:** every `<select>`/filter resets its list only on a real change; every async `useEffect` uses an `active`-flag cleanup.
- **`data-test=` hooks**; `tests/admin/test_logs.py` under `-n auto`; touched `.zig` `zig fmt`-clean; run the FULL `tests/admin/` suite before finishing; docs/site mirror synced; a `changelog.d/` fragment.

## Reference: confirmed facts (read before starting)

- **Realtime stats source** (`src/realtime/connection.zig`): `pub fn connectionCount() usize` (line 19); `pub const MAX_CONNECTIONS: usize = 10_000` (:12); `pub const MAX_SUBS: usize = 256` (:6). `app.realtime_outbound_hwm: u32` (`src/app.zig:43`, default `DEFAULT_OUTBOUND_HWM = 1024`).
- **Events endpoint** `GET /api/analytics/events` — params `name`, `actor`, `since` (occurred_at >=, lower bound only), `limit` (1–200, default 50), `cursor` (opaque; malformed → 400). Returns `{ items:[{id, created, name, payload, actor_collection, actor, account, occurred_at}], nextCursor: <string|null>, hasNext: <bool> }`.
- **Rollups endpoint** `GET /api/analytics/rollups/:name` — params `from`, `to`; unknown name → 404. Returns `{ items:[{bucket, account, actor, value, computed_at}] }`.
- **Events are written ONLY by server-side `ctx.track()`** (`src/ctx.zig:458` → `analytics.insertEvent`). There is NO HTTP ingest and `_events` is not a records collection. (This governs Task 3's test seeding — see the PROBE.)
- **Handler template**: `src/api/mail_config.zig` / `src/api/files_config.zig` — `ctx.app`, `app.pool.acquireReader()`/`defer releaseReader`, `auth.authenticate(app.io, ctx.allocator, app, ctx, &r)` → `.is_superuser`, `std.json` reply.
- **Admin wiring** (Phases 1–3, on main): `src/admin.zig` `assets` manifest (`mk(path, @embedFile(...), js_ctype)`, const is `js_ctype`); `src/admin/app.js` `parseRoute` + `Shell`; `src/admin/lib/api.js` `api(method,path,body,isForm)` + `API`; `src/admin/views/{users,email,files}.js` are the reference views. `API.collections()` returns the array.

---

## Task 1: `GET /api/realtime/stats` endpoint

**Files:**
- Create: `src/api/realtime_stats.zig`
- Modify: `src/server.zig` (import + route), `src/root.zig` (test import)
- Test: `src/api/realtime_stats.zig` unit test.

**Interfaces:**
- Produces: `GET /api/realtime/stats` → `{connections, max_connections, max_subs, outbound_hwm}` (all integers); 401 unauth, 403 non-superuser.

- [ ] **Step 1: Write the handler** `src/api/realtime_stats.zig`:
```zig
//! GET /api/realtime/stats — superuser-only, read-only realtime health: the live
//! connection count plus the static caps and configured outbound high-water-mark.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const conn = @import("../realtime/connection.zig");
const ApiError = @import("error.zig").ApiError;

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, &r) catch null) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);
    if (!a.is_superuser)
        return (ApiError{ .status = 403, .message = "Superuser only." }).toResponse(ctx.allocator);

    var root: std.json.ObjectMap = .empty;
    defer root.deinit(ctx.allocator);
    try root.put(ctx.allocator, "connections", .{ .integer = @intCast(conn.connectionCount()) });
    try root.put(ctx.allocator, "max_connections", .{ .integer = @intCast(conn.MAX_CONNECTIONS) });
    try root.put(ctx.allocator, "max_subs", .{ .integer = @intCast(conn.MAX_SUBS) });
    try root.put(ctx.allocator, "outbound_hwm", .{ .integer = @intCast(app.realtime_outbound_hwm) });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}),
    };
}

test "realtime stats exposes count + caps + hwm" {
    // Pin the connection.zig symbol names this handler depends on.
    try std.testing.expect(conn.MAX_CONNECTIONS == 10_000);
    try std.testing.expect(conn.MAX_SUBS == 256);
    _ = conn.connectionCount();
}
```
(Match `auth.authenticate` + `.is_superuser` to `mail_config.zig`. `std.json.Value.integer` is `i64`; `@intCast` from `usize`/`u32` is safe for these values. Note the `defer root.deinit` — the Phase-3 review flagged its absence as a leak; include it here.)

- [ ] **Step 2: Mount the route** in `src/server.zig`. Import:
```zig
const realtime_stats_api = @import("api/realtime_stats.zig");
```
Add to the UNCONDITIONAL base route table, near the other `/api/realtime/*` route(s) (`/api/realtime/stats` is 3 segments → cannot collide with the 4-segment `/api/realtime/sse/:clientId`):
```zig
    .{ .method = .GET, .pattern = "/api/realtime/stats", .handler = realtime_stats_api.get },
```

- [ ] **Step 3: Register test root** — add to `src/root.zig`'s test block:
```zig
    _ = @import("api/realtime_stats.zig");
```

- [ ] **Step 4: Build + test + gating.**
```bash
mise exec zig@0.16.0 -- zig build test --summary all
bash scripts/check-gating.sh
```
Expected: `Build Summary: N/N tests passed`; gating exit 0.

- [ ] **Step 5: Fmt + commit.**
```bash
mise exec zig@0.16.0 -- zig fmt src/api/realtime_stats.zig src/server.zig src/root.zig
git add src/api/realtime_stats.zig src/server.zig src/root.zig
git commit -m "feat(api): GET /api/realtime/stats — superuser realtime health"
```

---

## Task 2: Logs view scaffold — route, nav, manifest, realtime strip, API helpers

**Files:**
- Create: `src/admin/views/logs.js`, `tests/admin/test_logs.py`
- Modify: `src/admin/app.js` (import + route + nav + render branch), `src/admin.zig` (manifest row), `src/admin/lib/api.js` (helpers)

**Interfaces:**
- Produces: `views/logs.js` exports `LogsView`; `API.realtimeStats()`, `API.analyticsEvents(q)`, `API.analyticsRollup(name, q)`.

- [ ] **Step 1: Add API helpers** to the `API` object in `src/admin/lib/api.js`:
```js
  realtimeStats: () => api('GET', '/realtime/stats'),
  analyticsEvents: (q) => api('GET', `/analytics/events?${q}`),
  analyticsRollup: (name, q) => api('GET', `/analytics/rollups/${encodeURIComponent(name)}?${q}`),
```

- [ ] **Step 2: Write the failing test** `tests/admin/test_logs.py`:
```python
from conftest import login

def test_logs_view_renders_strip(page):
    login(page)
    page.goto("/_/#/logs")
    page.wait_for_selector('[data-test=logs-view]')
    # realtime health strip from GET /api/realtime/stats
    page.wait_for_selector('[data-test=rt-connections]')
    assert "10000" in page.inner_text('[data-test=rt-caps]')  # max_connections cap
```

- [ ] **Step 3: Run — verify fail.** `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_logs.py -q` → FAIL (no `#/logs`).

- [ ] **Step 4: Create `src/admin/views/logs.js`** (scaffold: realtime strip + stubs for the events log and rollups, filled in Tasks 3–4):
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

function RealtimeStrip() {
  const [s, setS] = useState(null);
  useEffect(() => {
    let active = true;
    API.realtimeStats().then(r => { if (active) setS(r); }).catch(() => { if (active) setS({}); });
    return () => { active = false; };
  }, []);
  if (s == null) return html`<div class="muted">…</div>`;
  return html`
    <div class="row" style="gap:6px;margin:6px 0" data-test="rt-strip">
      <span class="badge" data-test="rt-connections">${s.connections ?? 0} live</span>
      <span class="badge muted" data-test="rt-caps">caps: ${s.max_connections ?? 0} conns · ${s.max_subs ?? 0} subs · hwm ${s.outbound_hwm ?? 0}</span>
    </div>`;
}

export function LogsView() {
  return html`
    <div data-test="logs-view">
      <h2>Logs &amp; realtime</h2>
      <${RealtimeStrip}/>
      <${EventsLog}/>
      <${RollupsViewer}/>
    </div>`;
}

// Filled in Tasks 3–4.
function EventsLog() { return html`<div data-test="events-log"></div>`; }
function RollupsViewer() { return html`<div data-test="rollups-viewer"></div>`; }
```

- [ ] **Step 5: Wire route + nav** in `src/admin/app.js`: `import { LogsView } from '/_/assets/views/logs.js';`; in `parseRoute` add `if (seg[0] === 'logs') return { name: 'logs' };`; add a nav link `<a class=${'navitem hide-collapsed' + (route.name === 'logs' ? ' active' : '')} href="#/logs" data-test="nav-logs">📊 Logs</a>`; add the render branch `${route.name === 'logs' ? html\`<${LogsView}/>\` :` to Shell's chain.

- [ ] **Step 6: Manifest row** in `src/admin.zig`:
```zig
    mk("/_/assets/views/logs.js", @embedFile("admin/views/logs.js"), js_ctype),
```

- [ ] **Step 7: Build + test — verify pass.** Same command → PASS.

- [ ] **Step 8: Fmt + commit.**
```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ src/admin.zig tests/admin/test_logs.py
git commit -m "feat(admin): Logs view scaffold — realtime health strip"
```

---

## Task 3: Events log — filters + cursor pagination

**Files:** Modify `src/admin/views/logs.js` (`EventsLog`), `tests/admin/test_logs.py`.

**PROBE FIRST — how to get an event into `_events` for the happy-path test.** There is NO HTTP ingest; `_events` is written only by server-side `ctx.track()`. Before writing the seeded-events assertion, determine whether the standalone test server produces any trackable event through an admin action (e.g. a feature-flag exposure via `onFeatureExposure`, an experiment assignment, or any built-in `ctx.track()` call), OR whether one of the existing `tests/admin` fixture binaries (features-fixture, dating-server, etc.) emits events. If a reliable way exists, seed via it and assert a `log-row` appears. If NONE is feasible from a browser test, make the browser test assert the STRUCTURE — the filter row, the table headers, and that an empty feed shows an empty-state (`data-test=events-empty`) and `Load more` is hidden — and add a Zig-level test (in `src/api/realtime_stats.zig`'s sibling area or `src/analytics/`) that inserts an event via `analytics.insertEvent`/`ctx.track` and reads it through the events handler. Document what you found in the report.

- [ ] **Step 1: Failing test** — add to `tests/admin/test_logs.py` (structure-level, robust regardless of seeding; extend with a seeded `log-row` assertion if the probe finds a way):
```python
def test_logs_events_filters_and_pagination_controls(page):
    login(page)
    page.goto("/_/#/logs")
    page.wait_for_selector('[data-test=logs-view]')
    # events log renders its filter controls + table
    page.wait_for_selector('[data-test=events-log]')
    for t in ("logs-name", "logs-actor", "logs-since", "logs-apply"):
        assert page.locator(f'[data-test={t}]').count() == 1
    # applying a (likely no-match) filter doesn't crash and shows a resolved state
    page.fill('[data-test=logs-name]', "no_such_event_zzz")
    page.click('[data-test=logs-apply]')
    page.wait_for_selector('[data-test=events-empty]')
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `EventsLog`** in `logs.js` (filters + cursor "Load more"; the effect is keyed on an applied-filter object + cursor is managed imperatively):
```js
function EventsLog() {
  const [name, setName] = useState('');
  const [actor, setActor] = useState('');
  const [since, setSince] = useState('');
  const [applied, setApplied] = useState({ name: '', actor: '', since: '' });
  const [rows, setRows] = useState(null);
  const [cursor, setCursor] = useState(null);
  const [hasNext, setHasNext] = useState(false);
  const [err, setErr] = useState('');
  const [open, setOpen] = useState(null);

  function fetchPage(cur) {
    const p = new URLSearchParams({ limit: 50 });
    if (applied.name) p.set('name', applied.name);
    if (applied.actor) p.set('actor', applied.actor);
    if (applied.since) p.set('since', applied.since);
    if (cur) p.set('cursor', cur);
    return API.analyticsEvents(p.toString());
  }
  useEffect(() => {
    let active = true; setRows(null); setErr('');
    fetchPage(null)
      .then(r => { if (!active) return; setRows(r.items || []); setCursor(r.nextCursor || null); setHasNext(!!r.hasNext); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load events'); });
    return () => { active = false; };
  }, [applied]);
  function apply(e) { e && e.preventDefault(); setOpen(null); setApplied({ name: name.trim(), actor: actor.trim(), since: since.trim() }); }
  async function more() {
    try { const r = await fetchPage(cursor); setRows(rs => [...(rs || []), ...(r.items || [])]); setCursor(r.nextCursor || null); setHasNext(!!r.hasNext); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to load more'); }
  }
  return html`
    <div data-test="events-log" style="margin-top:12px">
      <h3>Events</h3>
      <form class="row" onSubmit=${apply} style="gap:6px;margin-bottom:8px">
        <input data-test="logs-name" placeholder="name" value=${name} onInput=${e => setName(e.target.value)}/>
        <input data-test="logs-actor" placeholder="actor" value=${actor} onInput=${e => setActor(e.target.value)}/>
        <input data-test="logs-since" placeholder="since (ISO)" value=${since} onInput=${e => setSince(e.target.value)}/>
        <button data-test="logs-apply">Apply</button>
      </form>
      ${err && html`<div class="error" data-test="events-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : rows.length === 0 ? html`<div class="muted" data-test="events-empty">No events</div>` : html`
        <table class="records">
          <thead><tr><th>When</th><th>Name</th><th>Actor</th><th>Account</th></tr></thead>
          <tbody>
            ${rows.map(ev => html`
              <tr key=${ev.id} data-test="log-row" style="cursor:pointer" onClick=${() => setOpen(open === ev.id ? null : ev.id)}>
                <td class="muted">${(ev.occurred_at || ev.created || '').slice(0, 19)}</td>
                <td>${ev.name}</td><td class="muted">${ev.actor || ''}</td><td class="muted">${ev.account || ''}</td>
              </tr>
              ${open === ev.id ? html`<tr key=${ev.id + '-d'}><td colspan="4"><pre data-test="log-payload" style="white-space:pre-wrap;margin:0">${typeof ev.payload === 'string' ? ev.payload : JSON.stringify(ev.payload, null, 2)}</pre></td></tr>` : ''}`)}
          </tbody>
        </table>
        ${hasNext ? html`<button data-test="logs-more" onClick=${more}>Load more</button>` : ''}`}
    </div>`;
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_logs.py; git commit -m "feat(admin): Logs — events feed with filters + cursor pagination"`

---

## Task 4: Rollups viewer

**Files:** Modify `src/admin/views/logs.js` (`RollupsViewer`), `tests/admin/test_logs.py`.

- [ ] **Step 1: Failing test** (unknown rollup → graceful message; no declared rollup is needed):
```python
def test_logs_rollup_unknown_name_is_graceful(page):
    login(page)
    page.goto("/_/#/logs")
    page.wait_for_selector('[data-test=logs-view]')
    page.wait_for_selector('[data-test=rollups-viewer]')
    page.fill('[data-test=rollup-name]', "no_such_rollup_zzz")
    page.click('[data-test=rollup-load]')
    page.wait_for_selector('[data-test=rollup-none]')
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `RollupsViewer`** in `logs.js`:
```js
function RollupsViewer() {
  const [name, setName] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rows, setRows] = useState(null);
  const [state, setState] = useState('idle'); // idle | loading | ok | none | error
  async function load(e) {
    e && e.preventDefault();
    if (!name.trim()) return;
    setState('loading'); setRows(null);
    try {
      const p = new URLSearchParams();
      if (from) p.set('from', from);
      if (to) p.set('to', to);
      const r = await API.analyticsRollup(name.trim(), p.toString());
      setRows(r.items || []); setState('ok');
    } catch (x) {
      if (x.status === 404) setState('none'); else setState('error');
    }
  }
  return html`
    <div data-test="rollups-viewer" style="margin-top:16px">
      <h3>Rollups</h3>
      <form class="row" onSubmit=${load} style="gap:6px;margin-bottom:8px">
        <input data-test="rollup-name" placeholder="rollup name" value=${name} onInput=${e => setName(e.target.value)}/>
        <input data-test="rollup-from" placeholder="from" value=${from} onInput=${e => setFrom(e.target.value)}/>
        <input data-test="rollup-to" placeholder="to" value=${to} onInput=${e => setTo(e.target.value)}/>
        <button data-test="rollup-load">Load</button>
      </form>
      ${state === 'loading' ? html`<div class="muted">…</div>`
        : state === 'none' ? html`<div class="muted" data-test="rollup-none">No such rollup declared</div>`
        : state === 'error' ? html`<div class="error" data-test="rollup-error">Failed to load rollup</div>`
        : state === 'ok' ? (rows.length === 0 ? html`<div class="muted" data-test="rollup-empty">No data in range</div>` : html`
          <table class="records" data-test="rollup-table">
            <thead><tr><th>Bucket</th><th>Account</th><th>Actor</th><th>Value</th></tr></thead>
            <tbody>${rows.map((r, i) => html`<tr key=${i} data-test="rollup-row"><td class="muted">${r.bucket}</td><td class="muted">${r.account || ''}</td><td class="muted">${r.actor || ''}</td><td>${r.value}</td></tr>`)}</tbody>
          </table>`)
        : ''}
    </div>`;
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_logs.py; git commit -m "feat(admin): Logs — rollups viewer"`

---

## Task 5: Docs, changelog, full-suite verification

**Files:** Create `changelog.d/admin-ui-logs.md`; modify `docs/framework.md` (+ mirror), `docs/api.md` (+ mirror, for `GET /api/realtime/stats`).

- [ ] **Step 1: Changelog** `changelog.d/admin-ui-logs.md`:
```markdown
### Features
- Admin UI: a **Logs & realtime** view — browse app analytics events with name/actor/since filters and cursor pagination, view an app-declared rollup's aggregated series, and a read-only realtime health strip (live connection count + caps). Backed by the existing analytics APIs plus a new superuser `GET /api/realtime/stats`.
```

- [ ] **Step 2: Docs.** Add a "Logs & realtime" bullet to the admin-UI section of `docs/framework.md` (mirror to `site/src/content/docs/framework.md`); document `GET /api/realtime/stats` in `docs/api.md` (mirror to `site/`). This is the FINAL admin area — if the framework.md admin-UI overview lists the covered areas, update it to include Logs. Build the site: `cd site && npm run build && cd ..` → clean.

- [ ] **Step 3: Full verification.**
```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig fmt --check src build.zig
bash scripts/check-gating.sh
mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/ -q -n auto
```
Expected: unit green; fmt clean; gating OK; full browser suite green (existing + `test_logs.py`). KNOWN FLAKE: `-n auto` intermittently fails UNRELATED tests (ECONNRESET / stale `examples/plugins/frontend/dist` / unbuilt named fixtures) — if hit, `rm -rf examples/plugins/frontend/dist`, build the named fixtures once, rerun, and re-run any failing test SERIALLY to confirm it's a flake before accepting.

- [ ] **Step 4: Commit.** `git add changelog.d/ docs/ site/; git commit -m "docs(admin): document the Logs view + GET /api/realtime/stats"`

---

## Self-review notes

- **Spec coverage:** endpoint → Task 1; scaffold + realtime strip → Task 2; events log (filters + cursor) → Task 3; rollups viewer → Task 4; docs/changelog/verify → Task 5.
- **Type/name consistency:** `API.realtimeStats/analyticsEvents/analyticsRollup` defined Task 2 Step 1; `LogsView` exported Task 2, imported in `app.js` same task; `EventsLog`/`RollupsViewer` stubbed Task 2, filled Tasks 3–4; manifest const `js_ctype`; `defer root.deinit` included in the endpoint (Phase-3 lesson).
- **Read-only:** no writes anywhere; superuser-gated stats; analytics endpoints are inherently read.
- **Confirm-when-implementing:** `auth.authenticate` call shape (copy from `mail_config.zig`); the `conn.*` symbol names (Task 1); how to seed an `_events` event for the happy-path test (Task 3 PROBE) — fall back to structure/empty-state + a Zig-level data-path test if no browser-reachable seeding exists.
