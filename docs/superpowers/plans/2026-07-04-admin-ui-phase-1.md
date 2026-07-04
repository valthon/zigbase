# Admin UI Phase 1 — Foundation + Users & Auth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the embedded admin SPA into browser-native ES modules with an ETag'd asset manifest, and ship the first new management area — Users & auth (superusers + auth-collection users: list/search/CRUD + admin password reset + read-only OAuth providers).

**Architecture:** No-build Preact-via-htm SPA, all assets `@embedFile`-d. `src/admin/app.js` is split into a thin entry (`app.js`), a shared API/UI layer (`lib/api.js`, `lib/ui.js`), and per-view modules (`views/collections.js`, `views/features.js`, `views/settings.js`, new `views/users.js`). `src/admin.zig` serves them from a comptime asset manifest carrying a CRC32 ETag per file and honoring `If-None-Match` (→ `304`). The Users view calls only the existing records/auth/oauth HTTP APIs.

**Tech Stack:** Zig 0.16 (`@embedFile`, `std.hash.Crc32`, `std.fmt.comptimePrint`), Preact 10 + hooks + htm (vendored `src/admin/preact.js`, already ESM), native browser ES modules (no bundler, no import map), Playwright (`tests/admin/`, run under `-n auto`).

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler in the admin path; edit `.js`, rebuild the binary. Every asset is `@embedFile`-d. No dependency that requires bundling.
- **Module imports use absolute served paths**, e.g. `import { html, useState } from '/_/assets/preact.js'`, `import { api, API } from '/_/assets/lib/api.js'`.
- **Every served admin asset carries a CRC32 `ETag`** (comptime, format `"\"{x:0>8}\""`) and returns `304` on a matching `If-None-Match`.
- **`data-test=` hooks** on every interactive element; the Users view gets `tests/admin/test_users.py`, run under `-n auto`.
- **Sessions are OUT of Phase 1** (no cross-user admin session API; default `.epoch` mode has none). No session UI.
- Docs/site mirror stay in sync (`docs/*.md` ↔ `site/src/content/`); changelog via a `changelog.d/` fragment. `zig fmt --check` is a CI gate — keep touched `.zig` fmt-clean. Run the FULL `tests/admin/` suite (`-n auto`) before finishing, not a subset.

## Reference: current code (read before starting)

- `src/admin.zig` (91 lines): serves a hardcoded per-file if-chain (`/_/assets/app.js`, `preact.js`, `style.css`). **ETag/304 already exist**: `crcEtag(comptime bytes) *const [10:0]u8` (comptime CRC32, quoted `"{x:0>8}"`), and `asset(ctx, comptime bytes, comptime ctype)` which sets `[ETag, nosniff]` headers and returns `304` (empty body, same headers) when `serve_file.etagMatches(ctx.if_none_match, etag)` is true, else `200`. `index.html` is served via `asset(...)` too (so the SPA shell is also ETag'd/304'd). Three existing unit tests already cover content-types/404/SPA-fallback AND the ETag/304 behavior — **keep them**. Imports `serve_file = @import("files/serve_file.zig")` for `etagMatches`.
- `src/admin/app.js` (678 lines): top-of-file `cookie()`, `api()`, `API` object (lines 1–47); `useHashRoute`/`parseRoute`/`go` router + `Login` + `App` + `Shell` (48–152); `useLiveCollection` (~153); `RecordsTable` (~154), `SchemaEditor` (~226), `AuthTab` (~365), `RecordDrawer` (~390), `RelationPicker` (~466); `FeaturesView`/`FlagsSection`/`ExperimentsSection`/`ExperimentPanel` (~481–607); `SettingsView`/`SettingDrawer` (~608–678); and a `render(html\`<${App}/>\`, …)` mount call at the very end.
- `src/admin/index.html`: loads `<script type="module" src="/_/assets/app.js">` and `style.css`. **Unchanged by this plan.**
- `src/admin/preact.js`: vendored htm+preact, ESM (`export { … html, render, useState, useEffect, … }`). **Unchanged.**
- `src/http.zig`: `RequestCtx` has `if_none_match: []const u8 = ""` (the request's If-None-Match, filled by server.zig; http.zig:~32) and `pub fn header(name)`. `Response { status: u16, content_type: []const u8, body: []const u8, extra_headers: []const Header }`; `Header { name, value }`.
- `build.zig:~414–427`: the consumer static-asset manifest precedent — `std.hash.Crc32.hash(data)` and etag string `"\"{x:0>8}\""`. Mirror this at comptime in `admin.zig`.

## API reference for the Users view (all verified on origin/main)

- Auth session for the admin: cookie `zb_auth` (HttpOnly) + `zb_csrf` (JS-readable). The existing `api()` client already sends `X-CSRF-Token: cookie('zb_csrf')` on non-GET. `_superusers`/auth-collection record endpoints accept the superuser cookie session.
- List collections (to find auth collections): `GET /api/collections` → array of `{ id, name, type, … }`. Auth collections have `type === "auth"`; `_superusers` is one (a system auth collection, `name === "_superusers"`).
- List users: `GET /api/collections/:col/records?page=&perPage=&sort=&filter=&search=` → `{ page, perPage, totalItems, totalPages, items }`. `search` (alias `q`) is full-text-ish; `perPage` cap 500.
- Create: `POST /api/collections/:col/records` with the record body (auth collections hash a `password` field, force `verified=false`, strip plaintext from the response).
- Update: `PATCH /api/collections/:col/records/:id`.
- Admin password set (reset): `PATCH /api/collections/:col/records/:id` with `{ "password": "<new>" }` from a **superuser** session — bypasses `oldPassword`, rotates the target's `tokenKey` (logs the target out everywhere).
- Delete: `DELETE /api/collections/:col/records/:id`.
- OAuth providers (read): `GET /api/collections/:col/auth/oauth2/providers` → `{ providers: [ { name, authURL, clientId, scopes: [...] } ] }` (enabled only, no secrets).

---

## Task 1: Refactor `admin.zig` serving into a comptime asset manifest

The ETag/304 machinery ALREADY EXISTS on this branch (`crcEtag`, `asset()`, `serve_file.etagMatches` — see the Reference section). This task ONLY refactors the hardcoded per-file if-chain into a comptime `assets` manifest + loop that **reuses** `crcEtag` and `serve_file.etagMatches`, so Tasks 2–3 add view modules as one manifest row each. Behavior is byte-for-byte preserved: content-types, the `[ETag, nosniff]` header pair **in that order** (existing tests assert `extra_headers[0].name == "ETag"` and `[1].name == "X-Content-Type-Options"`), 304 on a matching `If-None-Match`, 404 for unknown `/_/assets/*`, and `index.html` served as the SPA fallback **with** its own ETag/304. Do NOT redefine the ETag helpers, change the header order, or drop `index.html`'s ETag/304.

**Files:**
- Modify: `src/admin.zig`
- Test: `src/admin.zig` (its own `test {}` blocks; discovered via `src/root.zig`)

**Interfaces:**
- Consumes: existing `crcEtag(comptime bytes) *const [10:0]u8`, `serve_file.etagMatches(a, b)`, `http.RequestCtx.if_none_match`, `http.Response`, `http.Header`.
- Produces: a comptime `assets: [_]Asset` manifest + `mk(path, bytes, ctype)` helper that Tasks 2–3 extend by adding rows; `serve(ctx)` signature unchanged.

- [ ] **Step 1: Add a failing manifest test** — KEEP the three existing tests (44–90) unchanged. Append ONE new test that iterates the not-yet-existing `assets` manifest (so it fails to compile until Step 3):

```zig
test "every manifest asset serves 200 with an ETag and 304s on its own etag" {
    for (assets) |a| {
        var g = http.RequestCtx{ .method = .GET, .path = a.path, .allocator = std.testing.allocator };
        const r = serve(&g);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
        try std.testing.expectEqualStrings("X-Content-Type-Options", r.extra_headers[1].name);
        var c = http.RequestCtx{ .method = .GET, .path = a.path, .allocator = std.testing.allocator, .if_none_match = a.etag };
        try std.testing.expectEqual(@as(u16, 304), serve(&c).status);
    }
}
```

- [ ] **Step 2: Run tests — verify the new one fails to compile**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL to compile (`assets` is undefined until Step 3).

- [ ] **Step 3: Refactor `src/admin.zig`.** Keep the imports (incl. `serve_file`), the `@embedFile` consts, `crcEtag`, and all four tests. Replace the `asset()` helper + the if-chain `serve()` with a manifest. The `Asset.headers` MUST be `[ETag, nosniff]` in that order to match the existing tests:

```zig
const js = "application/javascript";

const Asset = struct {
    path: []const u8,
    bytes: []const u8,
    ctype: []const u8,
    etag: []const u8,
    headers: []const http.Header,
};

/// Build a manifest row with its comptime CRC32 ETag + [ETag, nosniff] headers.
fn mk(comptime path: []const u8, comptime bytes: []const u8, comptime ctype: []const u8) Asset {
    const tag: []const u8 = crcEtag(bytes);
    return .{
        .path = path,
        .bytes = bytes,
        .ctype = ctype,
        .etag = tag,
        .headers = &.{
            .{ .name = "ETag", .value = tag },
            .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        },
    };
}

const assets = [_]Asset{
    mk("/_/assets/app.js", app_js, js),
    mk("/_/assets/preact.js", preact_js, js),
    mk("/_/assets/style.css", style_css, "text/css"),
    // Task 2 adds: lib/api.js, lib/ui.js, views/collections.js, views/features.js,
    // views/settings.js, views/users.js
};

/// The SPA shell — served (with its own ETag/304) for "/_/" and any unknown "/_/…" path.
const shell = mk("/_/", index_html, "text/html");

fn respond(ctx: *http.RequestCtx, a: Asset) http.Response {
    if (serve_file.etagMatches(ctx.if_none_match, a.etag))
        return .{ .status = 304, .body = "", .content_type = a.ctype, .extra_headers = a.headers };
    return .{ .status = 200, .body = a.bytes, .content_type = a.ctype, .extra_headers = a.headers };
}

/// Serve the embedded admin SPA for any path under "/_/". Known assets return their
/// bytes (with a CRC32 ETag; 304 on a matching If-None-Match); every other "/_/" path
/// returns the ETag'd index.html so client-side hash routes survive refresh.
pub fn serve(ctx: *http.RequestCtx) http.Response {
    const p = ctx.path;
    for (assets) |a| {
        if (std.mem.eql(u8, p, a.path)) return respond(ctx, a);
    }
    if (std.mem.startsWith(u8, p, "/_/assets/"))
        return .{ .status = 404, .body = "not found", .content_type = "text/plain" };
    return respond(ctx, shell);
}
```

- [ ] **Step 4: Run the tests — verify all pass** (the 3 existing + the new manifest test)

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (ignore the spurious `failed command:` line).

- [ ] **Step 5: Fmt + commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin.zig
git commit -m "refactor(admin): serve assets from a comptime manifest (reuse crcEtag/etagMatches)"
```

---

## Task 2: Split `app.js` into ES modules

Move existing code into modules with zero behavior change. The existing Playwright suite is the acceptance gate — it must pass unchanged.

**Files:**
- Create: `src/admin/lib/api.js`, `src/admin/lib/ui.js`, `src/admin/views/collections.js`, `src/admin/views/features.js`, `src/admin/views/settings.js`
- Modify: `src/admin/app.js` (reduce to entry + router + Login + App + Shell), `src/admin.zig` (add the 5 new manifest rows)
- Test: existing `tests/admin/*.py` (unchanged)

**Interfaces:**
- Produces: `lib/api.js` exports `cookie`, `api`, `API`; `lib/ui.js` exports `go`, `useLiveCollection` (and is the home for future shared components); `views/collections.js` exports `RecordsTable`, `SchemaEditor`; `views/features.js` exports `FeaturesView`; `views/settings.js` exports `SettingsView`. Task 3 adds `views/users.js` exporting `UsersView`.

- [ ] **Step 1: Create `src/admin/lib/api.js`** — move `cookie`, `api`, and the `API` object out of `app.js` verbatim, prefixed with the preact import removed (this file needs no preact) and an export:

```js
// cookie + API client (cookie/CSRF auth; no token in JS)
export function cookie(name) { /* … verbatim from app.js … */ }
export async function api(method, path, body, isForm) { /* … verbatim … */ }
export const API = { /* … verbatim … */ };
```

- [ ] **Step 2: Create `src/admin/lib/ui.js`** — the shared layer. Move `go` and `useLiveCollection` here (the latter needs the api import):

```js
import { useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

export const go = (h) => { location.hash = h; };

export function useLiveCollection(col, apply) { /* … verbatim from app.js … */ }
```

- [ ] **Step 3: Create the three existing-view modules.** Each starts with the imports it needs and exports its entry component(s); move the component functions verbatim.

`src/admin/views/collections.js`:
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { api, API } from '/_/assets/lib/api.js';
import { go, useLiveCollection } from '/_/assets/lib/ui.js';

export function RecordsTable({ col }) { /* … verbatim … */ }
export function SchemaEditor({ name }) { /* … verbatim … */ }
function AuthTab({ col, setCol }) { /* … verbatim … */ }
function RecordDrawer({ col, record, schema, onClose, onSaved }) { /* … verbatim … */ }
function RelationPicker({ target, value, onChange, name }) { /* … verbatim … */ }
```

`src/admin/views/features.js`:
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

export function FeaturesView() { /* … verbatim … */ }
function FlagsSection({ flags, onReload }) { /* … verbatim … */ }
function ExperimentsSection({ experiments, onReload }) { /* … verbatim … */ }
function ExperimentPanel({ exp, onReload }) { /* … verbatim … */ }
```

`src/admin/views/settings.js`:
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

export function SettingsView() { /* … verbatim … */ }
function SettingDrawer({ entry, onClose, onSaved }) { /* … verbatim … */ }
```

(Check each moved function for a reference to `go`, `api`, `API`, `useLiveCollection`, `html`, or a hook, and ensure that name is imported at the top of its new module. Do not change function bodies.)

- [ ] **Step 4: Reduce `src/admin/app.js`** to the entry + router + Login + App + Shell. New top of file:

```js
import { html, render, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';
import { go } from '/_/assets/lib/ui.js';
import { RecordsTable, SchemaEditor } from '/_/assets/views/collections.js';
import { FeaturesView } from '/_/assets/views/features.js';
import { SettingsView } from '/_/assets/views/settings.js';
```

Keep `useHashRoute`, `parseRoute`, `Login`, `App`, `Shell`, and the final `render(html\`<${App}/>\`, document.getElementById('app'))` mount. Remove the `export const go` line (now imported). Everything Shell references (`RecordsTable`, `SchemaEditor`, `FeaturesView`, `SettingsView`) is now imported.

- [ ] **Step 5: Add the 5 new rows to the `admin.zig` manifest** (inside the `assets` array, replacing the Task-2 comment):

```zig
    mk("/_/assets/lib/api.js", @embedFile("admin/lib/api.js"), js),
    mk("/_/assets/lib/ui.js", @embedFile("admin/lib/ui.js"), js),
    mk("/_/assets/views/collections.js", @embedFile("admin/views/collections.js"), js),
    mk("/_/assets/views/features.js", @embedFile("admin/views/features.js"), js),
    mk("/_/assets/views/settings.js", @embedFile("admin/views/settings.js"), js),
```

- [ ] **Step 6: Build, then run the full browser suite — verify no behavior change**

Run:
```bash
mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/ -q -n auto
```
Expected: all pass (same count as before the split) — proves the module split is faithful.

- [ ] **Step 7: Fmt + commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ src/admin.zig
git commit -m "refactor(admin): split app.js into ES modules (lib + views)"
```

---

## Task 3: Users view — list + search + route + nav

New `views/users.js`: pick an auth collection, list its records with search + pagination. Wire the `#/users` route, a nav item, and the manifest row.

**Files:**
- Create: `src/admin/views/users.js`, `tests/admin/test_users.py`
- Modify: `src/admin/app.js` (route + nav + import), `src/admin.zig` (manifest row)

**Interfaces:**
- Consumes: `api`, `API` from `lib/api.js`; `go` from `lib/ui.js`; `html`/hooks from `preact.js`. Uses `GET /api/collections`, `GET /api/collections/:col/records?...`.
- Produces: `views/users.js` exports `UsersView`.

- [ ] **Step 1: Write the failing Playwright test** `tests/admin/test_users.py`:

```python
from conftest import login

def _seed_user(page, col="users", email="alice@example.com"):
    from conftest import api_request
    # create the auth collection if the fixture doesn't have it, then a user
    api_request(page, "POST", "/collections", {"name": col, "type": "auth"})
    api_request(page, "POST", f"/collections/{col}/records",
                {"email": email, "password": "correct horse battery staple"})

def test_users_view_lists_and_searches(page):
    login(page)
    _seed_user(page, email="alice@example.com")
    _seed_user(page, email="bob@example.com")
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    # collection picker defaults to the first auth collection with records
    page.select_option('[data-test=users-collection]', "users")
    page.wait_for_selector('[data-test=user-row]')
    assert page.locator('[data-test=user-row]').count() >= 2
    page.fill('[data-test=users-search]', "alice")
    page.click('[data-test=users-search-go]')
    page.wait_for_function("document.querySelectorAll('[data-test=user-row]').length === 1")
    assert "alice@example.com" in page.inner_text('[data-test=user-row]')
```

- [ ] **Step 2: Run it — verify it fails**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_users.py -q`
Expected: FAIL (no `#/users` route / `users-view` element).

- [ ] **Step 3: Create `src/admin/views/users.js`** (list + search + collection picker + pagination):

```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

const PER_PAGE = 30;

export function UsersView() {
  const [authCols, setAuthCols] = useState(null);
  const [col, setCol] = useState('');
  const [rows, setRows] = useState(null);
  const [page, setPage] = useState(1);
  const [pages, setPages] = useState(1);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [err, setErr] = useState('');

  useEffect(() => {
    API.collections()
      .then(cs => {
        const auth = cs.filter(c => c.type === 'auth');
        setAuthCols(auth);
        if (auth.length && !col) setCol(auth.some(c => c.name === 'users') ? 'users' : auth[0].name);
      })
      .catch(x => setErr((x.data && x.data.message) || 'Failed to load collections'));
  }, []);

  useEffect(() => {
    if (!col) return;
    const params = new URLSearchParams({ page, perPage: PER_PAGE, sort: '-created' });
    if (q) params.set('search', q);
    API.records(col, params.toString())
      .then(r => { setRows(r.items); setPages(r.totalPages || 1); })
      .catch(x => setErr((x.data && x.data.message) || 'Failed to load users'));
  }, [col, page, q]);

  function runSearch(e) { e && e.preventDefault(); setPage(1); setQ(search.trim()); }

  return html`
    <div data-test="users-view">
      <div class="row" style="justify-content:space-between;align-items:center">
        <h2>Users</h2>
        <select data-test="users-collection" value=${col} onChange=${e => { setCol(e.target.value); setPage(1); setRows(null); }}>
          ${(authCols || []).map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}
        </select>
      </div>
      <form class="row" onSubmit=${runSearch} style="gap:6px;margin:8px 0">
        <input data-test="users-search" placeholder="Search…" value=${search} onInput=${e => setSearch(e.target.value)}/>
        <button data-test="users-search-go">Search</button>
      </form>
      ${err && html`<div class="error" data-test="users-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : html`
        <table class="records">
          <thead><tr><th>Email / Username</th><th>Verified</th><th>Created</th></tr></thead>
          <tbody>
            ${rows.map(u => html`
              <tr key=${u.id} data-test="user-row">
                <td>${u.email || u.username || u.id}</td>
                <td>${u.verified ? '✓' : ''}</td>
                <td class="muted">${(u.created || '').slice(0, 10)}</td>
              </tr>`)}
          </tbody>
        </table>
        <div class="row" style="gap:8px;margin-top:8px">
          <button data-test="users-prev" disabled=${page <= 1} onClick=${() => setPage(page - 1)}>‹</button>
          <span class="muted" data-test="users-page">${page} / ${pages}</span>
          <button data-test="users-next" disabled=${page >= pages} onClick=${() => setPage(page + 1)}>›</button>
        </div>`}
    </div>`;
}
```

- [ ] **Step 4: Wire the route + nav in `src/admin/app.js`.** Add the import:

```js
import { UsersView } from '/_/assets/views/users.js';
```

In `parseRoute`, add before the collections fallthrough:
```js
  if (seg[0] === 'users') return { name: 'users' };
```

In `Shell`'s nav (next to the Features/Settings links):
```js
        <a class=${'navitem hide-collapsed' + (route.name === 'users' ? ' active' : '')} href="#/users" data-test="nav-users">👤 Users</a>
```

In `Shell`'s main render switch, add a branch:
```js
        ${route.name === 'users' ? html`<${UsersView}/>` :
```
(prepend it to the existing `route.name === 'features' ? …` chain).

- [ ] **Step 5: Add the manifest row in `src/admin.zig`:**
```zig
    mk("/_/assets/views/users.js", @embedFile("admin/views/users.js"), js),
```

- [ ] **Step 6: Build + run the test — verify it passes**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_users.py -q`
Expected: PASS.

- [ ] **Step 7: Fmt + commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ src/admin.zig tests/admin/test_users.py
git commit -m "feat(admin): Users view — list, search, collection picker"
```

---

## Task 4: Users view — create / edit / delete + admin password reset + OAuth providers

Add a user drawer (create/edit), delete-with-confirm, an admin password-reset field (superuser PATCH), and a read-only OAuth-providers panel for the selected collection.

**Files:**
- Modify: `src/admin/views/users.js` (drawer + actions + oauth panel), `tests/admin/test_users.py` (add cases)

**Interfaces:**
- Consumes: `POST/PATCH/DELETE /api/collections/:col/records[/:id]`, `GET /api/collections/:col/auth/oauth2/providers`. Extends `API` in `lib/api.js` with helpers.

- [ ] **Step 1: Add API helpers to `src/admin/lib/api.js`** (inside the `API` object):

```js
  createUser: (col, body) => api('POST', `/collections/${encodeURIComponent(col)}/records`, body),
  updateUser: (col, id, body) => api('PATCH', `/collections/${encodeURIComponent(col)}/records/${encodeURIComponent(id)}`, body),
  deleteUser: (col, id) => api('DELETE', `/collections/${encodeURIComponent(col)}/records/${encodeURIComponent(id)}`),
  oauthProviders: (col) => api('GET', `/collections/${encodeURIComponent(col)}/auth/oauth2/providers`),
```

- [ ] **Step 2: Write the failing tests** — add to `tests/admin/test_users.py`:

```python
def test_users_create_edit_delete_and_password(page):
    login(page)
    from conftest import api_request
    api_request(page, "POST", "/collections", {"name": "users", "type": "auth"})
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    page.select_option('[data-test=users-collection]', "users")
    # create
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', "carol@example.com")
    page.fill('[data-test=user-password]', "correct horse battery staple")
    page.click('[data-test=user-save]')
    page.wait_for_function("[...document.querySelectorAll('[data-test=user-row]')].some(r => r.textContent.includes('carol@example.com'))")
    # admin password reset (superuser PATCH; no old password)
    page.click('[data-test=user-row]:has-text("carol@example.com")')
    page.fill('[data-test=user-password]', "another good passphrase here")
    page.click('[data-test=user-save]')
    page.wait_for_selector('[data-test=user-saved]')
    # delete
    page.click('[data-test=user-row]:has-text("carol@example.com")')
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=user-delete]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=user-row]')].some(r => r.textContent.includes('carol@example.com'))")

def test_users_oauth_providers_panel(page):
    login(page)
    from conftest import api_request
    api_request(page, "POST", "/collections", {"name": "users", "type": "auth"})
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    page.select_option('[data-test=users-collection]', "users")
    # panel renders (0 providers configured by default → empty-state)
    page.wait_for_selector('[data-test=oauth-providers]')
    assert page.locator('[data-test=oauth-empty]').is_visible()
```

- [ ] **Step 3: Run — verify they fail**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_users.py -q`
Expected: FAIL (no `user-new`/`user-drawer`/`oauth-providers`).

- [ ] **Step 4: Extend `src/admin/views/users.js`** — add a `UserDrawer` and an `OAuthPanel`, a "+ New" button, and a click-to-edit on rows. Add to the imports: `import { API } from '/_/assets/lib/api.js';` already present. Insert the components and wire them:

```js
function UserDrawer({ col, user, onClose, onSaved }) {
  const editing = !!user;
  const [email, setEmail] = useState((user && (user.email || '')) || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [saved, setSaved] = useState(false);

  async function save(e) {
    e.preventDefault();
    setErr(''); setBusy(true);
    try {
      if (editing) {
        const body = {};
        if (password) body.password = password;      // superuser PATCH → admin reset
        if (email && email !== user.email) body.email = email;
        await API.updateUser(col, user.id, body);
      } else {
        await API.createUser(col, { email, password });
      }
      setSaved(true); onSaved();
    } catch (x) { setErr((x.data && x.data.message) || 'Save failed'); }
    finally { setBusy(false); }
  }
  async function del() {
    if (!confirm('Delete this user? This cannot be undone.')) return;
    try { await API.deleteUser(col, user.id); onSaved(); onClose(); }
    catch (x) { setErr((x.data && x.data.message) || 'Delete failed'); }
  }

  return html`
    <div class="drawer" data-test="user-drawer">
      <div class="drawer-head"><h3>${editing ? 'Edit user' : 'New user'}</h3><button class="ghost" onClick=${onClose}>✕</button></div>
      <form onSubmit=${save}>
        <div class="field"><label>Email</label><input data-test="user-email" value=${email} onInput=${e => setEmail(e.target.value)}/></div>
        <div class="field"><label>${editing ? 'Set new password (admin reset)' : 'Password'}</label>
          <input data-test="user-password" type="password" value=${password} onInput=${e => setPassword(e.target.value)} placeholder=${editing ? 'leave blank to keep' : ''}/></div>
        ${err && html`<div class="error" data-test="user-error">${err}</div>`}
        ${saved && html`<div class="muted" data-test="user-saved">Saved</div>`}
        <div class="row" style="gap:8px;margin-top:8px">
          <button data-test="user-save" disabled=${busy}>${busy ? '…' : 'Save'}</button>
          ${editing && html`<button type="button" class="danger" data-test="user-delete" onClick=${del}>Delete</button>`}
        </div>
      </form>
    </div>`;
}

function OAuthPanel({ col }) {
  const [providers, setProviders] = useState(null);
  useEffect(() => {
    setProviders(null);
    API.oauthProviders(col).then(r => setProviders(r.providers || [])).catch(() => setProviders([]));
  }, [col]);
  return html`
    <div data-test="oauth-providers" style="margin-top:16px">
      <div class="muted" style="text-transform:uppercase;font-size:11px">OAuth providers</div>
      ${providers == null ? html`<div class="muted">…</div>`
        : providers.length === 0 ? html`<div class="muted" data-test="oauth-empty">None configured</div>`
        : html`<ul>${providers.map(p => html`<li key=${p.name} data-test="oauth-provider">${p.name} <span class="muted">(${p.clientId})</span></li>`)}</ul>`}
    </div>`;
}
```

In `UsersView`, add drawer state and wire the New button + row click + panel. Add near the top of the component body: `const [editing, setEditing] = useState(null); const [drawerOpen, setDrawerOpen] = useState(false);` and a `reload` that re-runs the current query (extract the `useEffect` fetch into a `load()` you can call). Add a "+ New" button in the header row:
```js
        <button data-test="user-new" onClick=${() => { setEditing(null); setDrawerOpen(true); }}>+ New user</button>
```
Make each `<tr>` clickable: `onClick=${() => { setEditing(u); setDrawerOpen(true); }}` with `style="cursor:pointer"`. Render the drawer + panel at the end of `users-view`:
```js
      <${OAuthPanel} col=${col}/>
      ${drawerOpen && html`<${UserDrawer} col=${col} user=${editing} onClose=${() => setDrawerOpen(false)} onSaved=${load}/>`}
```
(Refactor the list-fetch `useEffect` body into `function load() { … }` and call it from both the effect and `onSaved`.)

- [ ] **Step 5: Build + run the tests — verify they pass**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_users.py -q`
Expected: PASS.

- [ ] **Step 6: Fmt + commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ tests/admin/test_users.py
git commit -m "feat(admin): Users view — create/edit/delete, admin password reset, OAuth panel"
```

---

## Task 5: Docs, changelog, and full-suite verification

**Files:**
- Modify: `docs/framework.md` (+ `site/src/content/docs/framework.md`) — a short "Admin UI" note that the SPA now covers Users; `docs/api.md` needs no change (no new endpoints).
- Create: `changelog.d/admin-ui-users.md`

- [ ] **Step 1: Changelog fragment** `changelog.d/admin-ui-users.md`:

```markdown
### Features
- Admin UI: a **Users** view for managing superusers and auth-collection users — list, search, create/edit/delete, admin password reset, and a read-only OAuth-providers panel. The admin SPA is now split into browser-native ES modules (no build step) and every asset is served with a CRC32 `ETag`.
```

- [ ] **Step 2: Docs.** Add a one-paragraph "Users" note to the admin-UI section of `docs/framework.md` and mirror it verbatim into `site/src/content/docs/framework.md`. If `docs/framework.md` has no admin-UI section, add a short "## Admin UI" subsection listing the covered areas (Collections, Records, Users, Features, Settings). Build the site:

```bash
cd site && npm run build && cd ..
```
Expected: clean build.

- [ ] **Step 3: Full verification.**

```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig fmt --check src build.zig
mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/ -q -n auto
```
Expected: unit tests green; fmt clean; full browser suite green (the three moved views unchanged + `test_users.py` passing).

- [ ] **Step 4: Commit**

```bash
git add changelog.d/admin-ui-users.md docs/framework.md site/src/content/docs/framework.md
git commit -m "docs(admin): document the Users view + changelog"
```

---

## Self-review notes

- **Spec coverage:** Foundation (ES-module split + ETag manifest) → Tasks 1–2; Users list/search → Task 3; CRUD + admin password reset + OAuth read → Task 4; docs/changelog → Task 5. Sessions intentionally ABSENT (dropped during planning — no cross-user admin API; default `.epoch` has none).
- **No behavior change in Task 2** is proven by the unchanged existing suite; the Users feature has its own `test_users.py`. The two acceptance gates stay separable even though foundation + first view ship in one PR.
- **Type/name consistency:** `mk(...)`/`Asset`/`assets`/`etagFor` defined in Task 1 and only extended (new rows) in Tasks 2–3; `API.createUser/updateUser/deleteUser/oauthProviders` defined in Task 4 Step 1 before use; `UsersView` exported in Task 3, imported in `app.js` same task.
- **`if_none_match` field name** must be confirmed against `src/http.zig:~32` in Task 1 Step 3.
- **Fixture note:** `test_users.py` creates its own `users` auth collection via the records/collections API using the logged-in superuser session (`api_request` from `conftest.py`), so it doesn't depend on a fixture shipping one.
