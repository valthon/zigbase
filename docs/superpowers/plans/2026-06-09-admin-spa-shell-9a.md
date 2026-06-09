# Admin SPA — Serving Layer & App Shell (Plan 9a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the embedded admin asset-serving layer (`/_/`) and a working, logged-in admin shell — login, a collapsible collections sidebar, and a read-only paginated records table — plus the headless-browser (Playwright) test harness covering those flows.

**Architecture:** A vendored no-build Preact+htm SPA (`src/admin/{index.html,preact.js,app.js,style.css}`) is `@embedFile`'d by `src/admin.zig` and served under `/_/` (prefix-dispatched before the API router, with an `index.html` fallback for hash routes). Auth reuses the SP5 cookie + `X-CSRF-Token` flow (no token in JS). The Zig serving layer is unit-tested; the SPA is validated by Python+Playwright tests driving a real Chromium.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>`; bare `zig` is 0.15.2). Preact+htm standalone (vendored ESM, no build). Python + Playwright for browser tests (test-time only — NOT part of `zig build`/runtime).

**Build/test:** `mise exec zig@0.16.0 -- zig build test --summary all` (Zig) and `mise exec zig@0.16.0 -- zig build` (binary). Browser tests: `python3 -m pytest tests/admin/ -v` (after `pip install playwright pytest && python3 -m playwright install chromium`).

**Branch:** Create and work on branch `admin-spa`. SP9 merges as a unit (9a+9b) after the holistic review at the end of 9b. Do NOT merge to `main` in this plan.

**Spec:** `docs/superpowers/specs/2026-06-09-admin-spa-design.md`.

---

## Verified facts (current code — do not re-derive)

- **`src/server.zig` `onRequest`:** builds `ctx`, then `const resp = router.dispatch(&routes, &ctx) catch …;`, then writes cookies, `extra_headers`, the `file_path`/`sendFile` branch, else `r.setContentType(.JSON) catch {}; r.sendBody(resp.body)`. `Server.instance.?.app` is `*App`. The `routes` array holds the `/api/*` routes. `ctx.path` is the request path.
- **`src/http.zig`:** `Response{ status, content_type="application/json", body, cookies, file_path, extra_headers }`; `Header{ name, value }`; `RequestCtx{ method, path, query, body, allocator, app, … }`.
- **API the SPA uses:** `POST /api/collections/_superusers/auth-with-password` `{identity,password}` → 200 (sets `zb_auth` httpOnly + `zb_csrf` readable cookies) / 400 bad creds. `POST /api/collections/_superusers/auth-logout` → clears cookies. `GET /api/collections` → JSON array of collections (each `{id,name,type,system,schema:[{id,name,type,required,unique,options}],indexes,listRule,viewRule,createRule,updateRule,deleteRule,options,created,updated}`). `GET /api/collections/:col/records?page&perPage&filter&sort` → `{page,perPage,totalItems,totalPages,items:[…]}` (collection-management + records lists require a superuser; the cookie session supplies it).
- **CLI:** `./zig-out/bin/zigbase superuser create --email <e> --password <p> --data-dir <d>`; `ZIGBASE_DATA_DIR=<d> ZIGBASE_HTTP_PORT=<p> ./zig-out/bin/zigbase serve`.
- **`@embedFile`:** `const bytes = @embedFile("admin/index.html");` (path relative to the importing `.zig` file) → `*const [N:0]u8` (coerces to `[]const u8`).
- **`zig build test`** does NOT analyze unreferenced `pub fn` bodies — always also run `zig build`.

---

## File Structure

- **Create** `src/admin/preact.js` — vendored htm/preact standalone ESM (Preact + hooks + htm in one file).
- **Create** `src/admin/index.html` — loads `style.css` + `app.js` (module).
- **Create** `src/admin/style.css` — dark theme, sidebar shell.
- **Create** `src/admin/app.js` — the SPA (API client + hash router + screens). Grown across tasks.
- **Create** `src/admin.zig` — `@embedFile` assets + `serve(ctx) Response`.
- **Modify** `src/server.zig` — dispatch `/_/` to `admin.serve`; honor `resp.content_type` in the body tail.
- **Modify** `src/main.zig` — add `_ = @import("admin.zig");` to the test root.
- **Create** `tests/admin/conftest.py`, `tests/admin/test_shell.py` — Playwright harness + 9a flows.
- **Modify** `.gitignore` — ignore Python/Playwright cruft if any (`tests/admin/__pycache__/`).

---

### Task 0: Branch + vendored library + static assets

**Files:** Create `src/admin/preact.js`, `src/admin/index.html`, `src/admin/style.css`, `src/admin/app.js`.

- [ ] **Step 1: Branch**

```bash
cd /home/valthon/nothlav/zigbase
git checkout main
git checkout -b admin-spa
```

- [ ] **Step 2: Vendor the Preact+htm standalone module**

```bash
mkdir -p src/admin
curl -fsSL https://unpkg.com/htm@3.1.1/preact/standalone.module.js -o src/admin/preact.js
# sanity: it must be an ES module exporting html/render/useState/etc.
head -c 200 src/admin/preact.js
grep -oE 'export\{[^}]*\}' src/admin/preact.js | head
wc -c src/admin/preact.js
```
Expected: a minified ESM (~10-12 KB) whose final `export{...}` includes `html`, `render`, `useState`,
`useEffect`, `useRef`, `Component`, `h`. If `unpkg` is unreachable, try
`https://cdn.jsdelivr.net/npm/htm@3.1.1/preact/standalone.module.js`. Verify the exact exported names
with the `grep` above and use those names in `app.js` (Task 2 imports `html, render, useState,
useEffect, useRef`). Add a header comment to the file noting origin + version:
prepend `/* vendored: htm@3.1.1/preact/standalone.module.js (Preact 10 + hooks + htm). No build step. */`
(use the Edit/Write tool to prepend; keep the original module body intact).

- [ ] **Step 3: Create `src/admin/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZigBase Admin</title>
  <link rel="stylesheet" href="/_/assets/style.css">
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/_/assets/app.js"></script>
</body>
</html>
```

- [ ] **Step 4: Create `src/admin/style.css`**

```css
:root { --bg:#16161a; --panel:#1d1d23; --line:#2c2c34; --fg:#e6e6ea; --muted:#9a9aa6; --accent:#6d6dff; --danger:#ff5d5d; }
* { box-sizing:border-box; }
body { margin:0; font:14px/1.5 system-ui,sans-serif; background:var(--bg); color:var(--fg); }
input,select,button,textarea { font:inherit; color:var(--fg); }
button { background:var(--accent); border:0; border-radius:6px; padding:7px 12px; color:#fff; cursor:pointer; }
button.ghost { background:transparent; border:1px solid var(--line); color:var(--fg); }
input,select,textarea { background:#101014; border:1px solid var(--line); border-radius:6px; padding:7px 9px; width:100%; }
.row { display:flex; gap:8px; align-items:center; }
.shell { display:flex; min-height:100vh; }
.sidebar { width:230px; flex:0 0 230px; background:var(--panel); border-right:1px solid var(--line); padding:12px; transition:width .15s; display:flex; flex-direction:column; }
.sidebar.collapsed { width:54px; flex-basis:54px; padding:12px 8px; }
.sidebar.collapsed .hide-collapsed { display:none; }
.brand { font-weight:700; margin-bottom:14px; display:flex; justify-content:space-between; align-items:center; }
.navitem { padding:6px 9px; border-radius:6px; cursor:pointer; color:var(--fg); text-decoration:none; display:block; }
.navitem.active { background:rgba(109,109,255,.18); }
.navitem .badge { font-size:11px; color:var(--muted); }
.spacer { margin-top:auto; }
.main { flex:1; padding:20px; overflow:auto; }
.login-wrap { max-width:340px; margin:12vh auto; background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:22px; }
.field { margin-bottom:12px; }
.field label { display:block; color:var(--muted); font-size:12px; margin-bottom:4px; }
.error { color:var(--danger); font-size:13px; }
table { width:100%; border-collapse:collapse; }
th,td { text-align:left; padding:7px 9px; border-bottom:1px solid var(--line); font-size:13px; white-space:nowrap; max-width:280px; overflow:hidden; text-overflow:ellipsis; }
th { color:var(--muted); font-weight:600; }
tbody tr:hover { background:rgba(255,255,255,.03); cursor:pointer; }
.toolbar { display:flex; gap:8px; align-items:center; margin-bottom:12px; }
.toolbar .grow { flex:1; }
.muted { color:var(--muted); }
.pager { margin-top:12px; display:flex; gap:8px; align-items:center; color:var(--muted); }
```

- [ ] **Step 5: Create a minimal `src/admin/app.js` placeholder** (so `@embedFile` compiles in Task 1; replaced in Task 2)

```js
document.getElementById('app').textContent = 'loading…';
```

- [ ] **Step 6: Commit**

```bash
git add src/admin/
git commit -m "feat(admin): vendored preact+htm + static shell assets"
```

---

### Task 1: Asset serving layer (`admin.zig`, `server.zig`)

**Files:** Create `src/admin.zig`; Modify `src/server.zig`, `src/main.zig`.

- [ ] **Step 1: Create `src/admin.zig` with the tests first**

```zig
const std = @import("std");
const http = @import("http.zig");

const index_html = @embedFile("admin/index.html");
const app_js = @embedFile("admin/app.js");
const preact_js = @embedFile("admin/preact.js");
const style_css = @embedFile("admin/style.css");

const nosniff = [_]http.Header{.{ .name = "X-Content-Type-Options", .value = "nosniff" }};

fn asset(bytes: []const u8, content_type: []const u8) http.Response {
    return .{ .status = 200, .body = bytes, .content_type = content_type, .extra_headers = &nosniff };
}

/// Serve the embedded admin SPA for any path under "/_/". Known assets return their bytes; every
/// other "/_/" path returns index.html (so client-side hash routes survive refresh/deep-link).
pub fn serve(ctx: *http.RequestCtx) http.Response {
    const p = ctx.path;
    if (std.mem.eql(u8, p, "/_/assets/app.js")) return asset(app_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/preact.js")) return asset(preact_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/style.css")) return asset(style_css, "text/css");
    if (std.mem.startsWith(u8, p, "/_/assets/")) return .{ .status = 404, .body = "not found", .content_type = "text/plain" };
    return asset(index_html, "text/html");
}

test "serve returns index.html for the root and unknown spa paths" {
    var ctx = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = std.testing.allocator };
    const r = serve(&ctx);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/html", r.content_type);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "<div id=\"app\">") != null);
    var deep = http.RequestCtx{ .method = .GET, .path = "/_/collections/posts/records", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("text/html", serve(&deep).content_type); // hash-route fallback
}

test "serve returns assets with correct content types + nosniff" {
    var js = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = std.testing.allocator };
    const rjs = serve(&js);
    try std.testing.expectEqualStrings("application/javascript", rjs.content_type);
    try std.testing.expect(rjs.extra_headers.len == 1 and std.mem.eql(u8, rjs.extra_headers[0].name, "X-Content-Type-Options"));
    var css = http.RequestCtx{ .method = .GET, .path = "/_/assets/style.css", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("text/css", serve(&css).content_type);
    var pj = http.RequestCtx{ .method = .GET, .path = "/_/assets/preact.js", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("application/javascript", serve(&pj).content_type);
    var unknown = http.RequestCtx{ .method = .GET, .path = "/_/assets/nope.js", .allocator = std.testing.allocator };
    try std.testing.expectEqual(@as(u16, 404), serve(&unknown).status);
}
```

Register `_ = @import("admin.zig");` in `src/main.zig` test root.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `admin.zig` not yet imported by `server.zig`, tests reference `serve` (compiles once admin.zig exists). If `@embedFile` can't find a file, ensure all four `src/admin/*` files exist (Task 0).

- [ ] **Step 3: Wire `/_/` dispatch + `content_type` into `src/server.zig`**

Add the import: `const admin = @import("admin.zig");`.

Replace the dispatch line so `/_/` paths go to `admin.serve`:

```zig
    const resp = if (std.mem.startsWith(u8, ctx.path, "/_/") or std.mem.eql(u8, ctx.path, "/_"))
        admin.serve(&ctx)
    else
        router.dispatch(&routes, &ctx) catch
            ApiError.internal().toResponse(arena.allocator()) catch {
                setZapStatus(r, 500);
                r.setContentType(.JSON) catch {};
                r.sendBody("{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}") catch {};
                return;
            };
```

Change the **body tail** to honor `resp.content_type` (it defaults to `"application/json"`, so API responses are unchanged). Replace the final `r.setContentType(.JSON) catch {};` (the one right before `r.sendBody(resp.body)`) with:

```zig
    r.setHeader("content-type", resp.content_type) catch {};
    r.sendBody(resp.body) catch {};
```

(Leave the 500-fallback `setContentType(.JSON)` lines as-is.)

- [ ] **Step 4: Run + binary build**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` (PASS) and `mise exec zig@0.16.0 -- zig build` (EXIT 0).

- [ ] **Step 5: Commit**

```bash
git add src/admin.zig src/server.zig src/main.zig
git commit -m "feat(admin): embed + serve SPA assets under /_/"
```

---

### Task 2: SPA core — API client, router, login (`app.js`)

**Files:** Modify `src/admin/app.js` (replace the placeholder).

This is the SPA's foundation: a fetch wrapper that sends `X-CSRF-Token` on writes, a hash router, and the login screen. (No Zig test — validated by the Playwright suite in Task 4.)

- [ ] **Step 1: Replace `src/admin/app.js`**

```js
import { html, render, useState, useEffect } from '/_/assets/preact.js';

// --- cookie + API client (cookie/CSRF auth; no token in JS) ---
function cookie(name) {
  const m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
  return m ? decodeURIComponent(m[1]) : '';
}
async function api(method, path, body, isForm) {
  const headers = {};
  if (!['GET', 'HEAD'].includes(method)) headers['X-CSRF-Token'] = cookie('zb_csrf');
  let payload = body;
  if (body != null && !isForm) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const res = await fetch('/api' + path, { method, headers, body: payload, credentials: 'same-origin' });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (res.status === 401 || res.status === 403) { location.hash = '#/login'; throw { status: res.status, data }; }
  if (!res.ok) throw { status: res.status, data };
  return data;
}
const API = {
  login: (identity, password) => api('POST', '/collections/_superusers/auth-with-password', { identity, password }),
  logout: () => api('POST', '/collections/_superusers/auth-logout'),
  collections: () => api('GET', '/collections'),
  records: (col, q) => api('GET', `/collections/${encodeURIComponent(col)}/records?${q}`),
};

// --- tiny hash router ---
function useHashRoute() {
  const [hash, setHash] = useState(location.hash || '#/collections');
  useEffect(() => {
    const on = () => setHash(location.hash || '#/collections');
    addEventListener('hashchange', on);
    return () => removeEventListener('hashchange', on);
  }, []);
  return hash;
}
function parseRoute(hash) {
  const path = hash.replace(/^#/, '') || '/';
  const seg = path.split('/').filter(Boolean); // ['collections','posts','records']
  if (seg[0] === 'login') return { name: 'login' };
  if (seg[0] === 'collections' && seg[1] && seg[2] === 'records') return { name: 'records', col: decodeURIComponent(seg[1]) };
  if (seg[0] === 'collections' && seg[1]) return { name: 'schema', col: decodeURIComponent(seg[1]) };
  return { name: 'collections' };
}
export const go = (h) => { location.hash = h; };

// --- login screen ---
function Login() {
  const [email, setEmail] = useState('');
  const [pw, setPw] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  async function submit(e) {
    e.preventDefault();
    setErr(''); setBusy(true);
    try { await API.login(email, pw); go('#/collections'); }
    catch (x) { setErr((x.data && x.data.message) || 'Login failed'); }
    finally { setBusy(false); }
  }
  return html`
    <div class="login-wrap">
      <h2>ZigBase admin</h2>
      <form onSubmit=${submit}>
        <div class="field"><label>Email</label><input data-test="email" value=${email} onInput=${e => setEmail(e.target.value)} autofocus/></div>
        <div class="field"><label>Password</label><input data-test="password" type="password" value=${pw} onInput=${e => setPw(e.target.value)}/></div>
        ${err && html`<div class="error" data-test="login-error">${err}</div>`}
        <button data-test="login-submit" disabled=${busy}>${busy ? '…' : 'Sign in'}</button>
      </form>
    </div>`;
}

// Shell + screens are added in the next task. For now App routes login vs a stub.
function App() {
  const hash = useHashRoute();
  const route = parseRoute(hash);
  if (route.name === 'login') return html`<${Login}/>`;
  return html`<${Shell} route=${route}/>`;
}

// placeholder Shell — replaced/extended in Task 3
function Shell({ route }) { return html`<div class="main" data-test="shell">…</div>`; }

render(html`<${App}/>`, document.getElementById('app'));
```

- [ ] **Step 2: Build (assets re-embed)**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0 — `app.js` is embedded bytes, no compile of JS). `mise exec zig@0.16.0 -- zig build test --summary all` (Zig serving tests still pass; they only check the bytes are served).

- [ ] **Step 3: Commit**

```bash
git add src/admin/app.js
git commit -m "feat(admin): SPA api client + hash router + login"
```

---

### Task 3: App shell, collections sidebar, records table (`app.js`)

**Files:** Modify `src/admin/app.js` (replace the placeholder `Shell` + add screens).

- [ ] **Step 1: Replace the placeholder `Shell` in `src/admin/app.js`** with the real shell + screens (insert these before the `render(...)` call, replacing the placeholder `Shell`):

```js
function Shell({ route }) {
  const [cols, setCols] = useState(null);
  const [err, setErr] = useState('');
  const [collapsed, setCollapsed] = useState(localStorage.getItem('zb_sidebar') === '1');
  useEffect(() => {
    API.collections().then(setCols).catch(x => setErr((x.data && x.data.message) || 'Failed to load collections'));
  }, []);
  function toggle() { const v = !collapsed; setCollapsed(v); localStorage.setItem('zb_sidebar', v ? '1' : '0'); }
  async function logout() { try { await API.logout(); } catch (_) {} go('#/login'); }

  const activeCol = route.col;
  return html`
    <div class="shell">
      <div class=${'sidebar' + (collapsed ? ' collapsed' : '')}>
        <div class="brand"><span class="hide-collapsed">zigbase</span><button class="ghost" data-test="sidebar-toggle" onClick=${toggle}>${collapsed ? '»' : '«'}</button></div>
        <div class="hide-collapsed muted" style="font-size:11px;text-transform:uppercase">Collections</div>
        ${cols == null ? html`<div class="muted">…</div>` :
          cols.map(c => html`<a key=${c.id} class=${'navitem' + (c.name === activeCol ? ' active' : '')} data-test=${'nav-' + c.name} href=${'#/collections/' + encodeURIComponent(c.name) + '/records'}>
            <span class="hide-collapsed">${c.name} ${c.type !== 'base' ? html`<span class="badge">(${c.type})</span>` : ''}</span>${collapsed ? c.name[0] : ''}</a>`)}
        ${err && html`<div class="error">${err}</div>`}
        <div class="spacer"></div>
        <a class="navitem hide-collapsed" href="#/collections" data-test="nav-collections">⚙ Collections</a>
        <a class="navitem" data-test="logout" onClick=${logout} style="cursor:pointer">⎋ <span class="hide-collapsed">Logout</span></a>
      </div>
      <div class="main">
        ${route.name === 'records' ? html`<${RecordsTable} col=${route.col}/>`
          : route.name === 'schema' ? html`<div data-test="schema-stub"><h2>${route.col}</h2><p class="muted">Schema editor — Plan 9b.</p></div>`
          : html`<div data-test="collections-home"><h2>Collections</h2><p class="muted">Pick a collection from the sidebar. Create/edit lands in Plan 9b.</p></div>`}
      </div>
    </div>`;
}

function RecordsTable({ col }) {
  const [data, setData] = useState(null);
  const [err, setErr] = useState('');
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState('');
  const [sort, setSort] = useState('');
  const perPage = 30;
  function load() {
    setErr('');
    const q = new URLSearchParams({ page, perPage });
    if (filter) q.set('filter', filter);
    if (sort) q.set('sort', sort);
    API.records(col, q.toString()).then(setData).catch(x => setErr((x.data && x.data.message) || 'Failed to load records'));
  }
  useEffect(() => { setPage(1); }, [col]);
  useEffect(load, [col, page, sort]);
  const items = data ? data.items : [];
  const columns = items.length ? Object.keys(items[0]).filter(k => k !== 'collectionId' && k !== 'collectionName') : ['id', 'created', 'updated'];
  return html`
    <div data-test="records-view">
      <div class="toolbar">
        <h2 style="margin:0">${col} <span class="muted" data-test="total">${data ? '· ' + data.totalItems + ' records' : ''}</span></h2>
        <div class="grow"></div>
        <input class="grow" data-test="filter" placeholder="filter e.g. status='published'" value=${filter} onInput=${e => setFilter(e.target.value)} onKeyDown=${e => { if (e.key === 'Enter') { setPage(1); load(); } }}/>
        <button class="ghost" data-test="apply-filter" onClick=${() => { setPage(1); load(); }}>Apply</button>
      </div>
      ${err && html`<div class="error" data-test="records-error">${err}</div>`}
      <table>
        <thead><tr>${columns.map(c => html`<th key=${c} onClick=${() => setSort(sort === c ? '-' + c : c)} style="cursor:pointer">${c}${sort === c ? ' ▲' : sort === '-' + c ? ' ▼' : ''}</th>`)}</tr></thead>
        <tbody data-test="rows">
          ${items.map(r => html`<tr key=${r.id} data-test="row">${columns.map(c => html`<td key=${c}>${fmt(r[c])}</td>`)}</tr>`)}
        </tbody>
      </table>
      ${data && data.totalItems === 0 && html`<p class="muted" data-test="empty">No records.</p>`}
      <div class="pager">
        <button class="ghost" disabled=${page <= 1} onClick=${() => setPage(page - 1)}>‹ Prev</button>
        <span data-test="pageinfo">Page ${data ? data.page : page} / ${data ? data.totalPages || 1 : 1}</span>
        <button class="ghost" disabled=${data && page >= (data.totalPages || 1)} onClick=${() => setPage(page + 1)}>Next ›</button>
      </div>
    </div>`;
}

function fmt(v) {
  if (v == null) return '';
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
```

- [ ] **Step 2: Build**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0) + `mise exec zig@0.16.0 -- zig build test --summary all` (PASS).

- [ ] **Step 3: Commit**

```bash
git add src/admin/app.js
git commit -m "feat(admin): sidebar shell + collections nav + read-only records table"
```

---

### Task 4: Headless-browser test harness + 9a flows (`tests/admin/`)

**Files:** Create `tests/admin/conftest.py`, `tests/admin/test_shell.py`; Modify `.gitignore`.

- [ ] **Step 1: Install Playwright (one-time, dev/test only — not part of the build)**

```bash
python3 -m pip install --quiet playwright pytest && python3 -m playwright install chromium
python3 -c "import playwright; print('playwright ok')"
```
If the install fails (offline/sandboxed), STOP and report BLOCKED noting the environment can't run
browser tests; do not fake them.

- [ ] **Step 2: Create `tests/admin/conftest.py`** — builds the binary, seeds a superuser, runs the server, and yields a Playwright page.

```python
import os, socket, subprocess, tempfile, time, shutil, pathlib, pytest
from playwright.sync_api import sync_playwright

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]

def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

@pytest.fixture(scope="session")
def binary():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    return str(REPO / "zig-out" / "bin" / "zigbase")

@pytest.fixture()
def server(binary):
    data = tempfile.mkdtemp(prefix="zb_admin_")
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io", "--password", "adminpassword", "--data-dir", data], check=True)
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    proc = subprocess.Popen([binary, "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # wait for the port
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2): break
        except OSError: time.sleep(0.1)
    base = f"http://127.0.0.1:{port}"
    try:
        yield base
    finally:
        proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)

@pytest.fixture()
def page(server):
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(base_url=server)
        pg = ctx.new_page()
        yield pg
        ctx.close(); browser.close()

def login(page):
    page.goto("/_/#/login")
    page.fill('[data-test=email]', 'admin@x.io')
    page.fill('[data-test=password]', 'adminpassword')
    page.click('[data-test=login-submit]')
    page.wait_for_selector('[data-test=nav-collections]', timeout=5000)
```

- [ ] **Step 3: Create `tests/admin/test_shell.py`** (the 9a flow tests)

```python
from conftest import login

def test_bad_login_shows_error(page):
    page.goto("/_/#/login")
    page.fill('[data-test=email]', 'admin@x.io')
    page.fill('[data-test=password]', 'wrongpass')
    page.click('[data-test=login-submit]')
    page.wait_for_selector('[data-test=login-error]', timeout=5000)

def test_login_then_sidebar_lists_builtin_collections(page):
    login(page)
    # _superusers is a system auth collection and must appear in the sidebar
    assert page.locator('[data-test=nav-_superusers]').count() == 1

def test_unauthenticated_deeplink_bounces_to_login(page):
    # a deep link without a session should redirect to login on first API 401
    page.goto("/_/#/collections/_superusers/records")
    page.wait_for_selector('[data-test=email]', timeout=5000)  # login form

def test_browse_records_table_renders(page):
    login(page)
    page.click('[data-test=nav-_superusers]')
    page.wait_for_selector('[data-test=records-view]', timeout=5000)
    # the superuser we created is one record
    page.wait_for_selector('[data-test=row]', timeout=5000)
    assert page.locator('[data-test=row]').count() >= 1
```

NOTE on `test_unauthenticated_deeplink_bounces_to_login`: the records view calls the API on mount; an
anonymous call to a superuser-gated list returns 403 → the client sets `#/login`. If the collection's
`listRule` made it public this wouldn't bounce, but `_superusers` is locked, so the bounce holds.
Confirm the behavior and adjust the selector/collection if the app structure differs.

- [ ] **Step 4: Add to `.gitignore`**

```bash
printf '\ntests/admin/__pycache__/\n.pytest_cache/\n' >> .gitignore
```

- [ ] **Step 5: Run the browser tests**

Run: `cd /home/valthon/nothlav/zigbase && python3 -m pytest tests/admin/ -v`
Expected: 4 passed. (The `binary` fixture builds the server once; each test gets a fresh seeded server + browser.) If a test fails, fix `app.js` (not the test) unless the test's assumption is wrong, then re-run.

- [ ] **Step 6: Commit**

```bash
git add tests/admin/ .gitignore
git commit -m "test(admin): headless-browser harness + 9a shell/login/browse flows"
```

---

## Done criteria for 9a

- `zig build` + `zig build test` green; `python3 -m pytest tests/admin/` green (login, bad-login error, deep-link bounce, browse-records).
- Loading `/_/` serves the embedded SPA; a superuser can log in (cookie/CSRF), see collections in the collapsible sidebar, and browse a collection's records (paginated/filter/sort), all from the single binary. No schema/record editing yet (Plan 9b). No `main` merge.

---

## Self-Review (author)

- **Spec coverage:** embedded `/_/` serving + SPA fallback + asset content-types/nosniff (§2 → Task 1); no-build Preact vendoring (§1,§2 → Task 0); cookie+CSRF API client + login (§3 → Task 2); collapsible sidebar + collections list + read-only records table (§4 → Task 3); Zig serving unit tests + Playwright 9a flows (§7 → Tasks 1,4). Schema editor, drawer record editor, realtime, OAuth UI, and their 9b headless flows are explicitly Plan 9b.
- **Placeholder scan:** none — full code in every step. 9a seeds only via the CLI-created superuser (no API seeding needed); the schema/drawer/realtime/OAuth flows that need richer seeding are 9b.
- **Type consistency:** `admin.serve(*RequestCtx) http.Response` (Task 1) called from `server.zig`; `Response.content_type` (existing field) now honored by the body tail; `API`/`go`/`parseRoute`/`Shell`/`RecordsTable` names consistent across Tasks 2-3; `data-test` hooks in `app.js` match the Playwright selectors in Task 4.
- **Deferred to 9b (intentional):** the `schema-stub`/`collections-home` placeholders become the real schema editor + collections create; the records drawer editor; realtime; OAuth config; the 9b headless flows.
