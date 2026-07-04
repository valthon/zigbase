# Admin UI Phase 2 — Email view — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an **Email** admin view (`/_/#/email`) — sender identities, suppression list, bulk-batch progress (read-only), and a read-only mail-policy strip — on the Phase-1 ES-module foundation, plus one small `GET /api/mail/config` endpoint to feed the policy strip.

**Architecture:** A new `src/admin/views/email.js` ES module (three tabs + a policy strip), wired as a `#/email` route + nav item + one `src/admin.zig` manifest row, extending `src/admin/lib/api.js` with email helpers. Composes existing superuser REST APIs; the only new server code is `src/api/mail_config.zig` (a superuser read handler returning four booleans) mounted in `server.zig`'s existing `.mail` gate block.

**Tech Stack:** Zig 0.16 (`ctx.app`, `app.pool`, `auth.authenticate`, `std.json`), Preact 10 + htm (vendored `preact.js`), the Phase-1 admin modules, Playwright (`tests/admin/`, `-n auto`).

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild; every asset `@embedFile`-d; modules import by absolute `/_/assets/...` path.
- **Superuser-only.** The mail system collections are `system=1` with NULL rules (superuser-only); the admin cookie session (`zb_auth`+`zb_csrf`) is accepted. `GET /api/mail/config` returns 403 to non-superusers.
- **No secrets in the UI.** The policy strip shows booleans only — never `webhook_secret`'s value; the Senders list uses `GET /api/senders` (which omits `verification_token`), and the raw `_sender_identities` record (which contains the token) is touched ONLY for DELETE, never rendered.
- **Reload-race guard (Phase 1 lesson):** any `<select>`/tab that drives a fetch resets its list only when the selection ACTUALLY changes; each tab owns a fetch effect keyed on its own inputs.
- **`data-test=` hooks** on interactive elements; `tests/admin/test_email.py` run under `-n auto`. Touched `.zig` stays `zig fmt`-clean (CI gate). Run the FULL `tests/admin/` suite (`-n auto`) before finishing.
- Docs/site mirror in sync; a `changelog.d/` fragment added.

## Reference: confirmed facts (read before starting)

**Mail collections (system, superuser-only) — `src/migrations.zig`:**
- `_sender_identities`: `id, created, updated, account, email, verified_at, verification_token, status(pending|verified)`. **Contains a token — never render it.**
- `_suppressions`: `id, created, updated, account, email, reason(hard_bounce|complaint|unsubscribe), source`.
- `_mail_batches`: `id, created, updated, account, list, queue, from_addr, reply_to, subject_tpl, text_tpl, html_tpl, total(int), status('active')`.
- `_mail_batch_recipients`: `id, created, updated, batch(FK→_mail_batches.id), email, vars_json, status(pending|sent|suppressed|invalid|failed|canceled), attempts(int), last_error, sent_at`.

**Existing HTTP (superuser cookie works):**
- `GET /api/senders` → `{items:[{id,email,status,verified_at}]}` (no token). `POST /api/senders {email}` → invite/re-invite. (`src/api/senders.zig`)
- Records API: `GET/POST/DELETE /api/collections/:col/records[/:id]` — use for `_suppressions` (list/add/remove), `_sender_identities` (DELETE only), `_mail_batches` + `_mail_batch_recipients` (read).
- Records list envelope: `{page, perPage, totalItems, totalPages, items}`. Query params: `page`, `perPage`, `sort`, `filter`. Filter examples used here: `reason="unsubscribe"`, `batch="<id>"` (build with `JSON.stringify`).

**Handler template — `src/api/senders.zig`:** `pub fn list(ctx: *http.RequestCtx) anyerror!http.Response` gets `const app = ctx.app orelse return ApiError.notFound()...;`, `var r = try app.pool.acquireReader(); defer app.pool.releaseReader(&r);`, `auth.authenticate(app.io, ctx.allocator, app, ctx, &r)` → `?Authed` with `.is_superuser`. JSON via `std.json.Stringify.valueAlloc(alloc, Value{.object=root}, .{})`. `app.mail` is the lowered `mail_cfg.Runtime` with `require_verified_sender: bool`, `check_suppression: bool`, `webhook_secret: []const u8`, `unsubscribe_base_url: []const u8`.

**Phase-1 admin wiring (now on main) — mirror it:**
- `src/admin.zig`: `assets` manifest built with `mk("/_/assets/…", @embedFile("admin/…"), js_ctype)` rows.
- `src/admin/app.js`: `parseRoute(hash)` maps segments → `{name}`; `Shell` renders view entry components via imports + a `route.name===…` ternary chain, and has the nav `<a data-test="nav-…">` links.
- `src/admin/lib/api.js`: exports `api(method,path,body)` + the `API` object (extend it).
- `src/admin/views/users.js`: the reference view (list/search/drawer/pagination + the `if (v===col) return;` select guard). Follow its shape.

---

## Task 1: `GET /api/mail/config` endpoint

**Files:**
- Create: `src/api/mail_config.zig`
- Modify: `src/server.zig` (import + route), `src/root.zig` (test import)
- Test: `src/api/mail_config.zig` (its own `test`), plus a browser check later.

**Interfaces:**
- Produces: `GET /api/mail/config` → `{require_verified_sender, check_suppression, webhook_configured, unsubscribe_configured}` (all bool); 401 unauth, 403 non-superuser.

- [ ] **Step 1: Write the handler** `src/api/mail_config.zig`:

```zig
//! GET /api/mail/config — superuser-only, read-only mail policy state for the admin UI.
//! Booleans only; never exposes the webhook secret or the unsubscribe URL value.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
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
    try root.put(ctx.allocator, "require_verified_sender", .{ .bool = app.mail.require_verified_sender });
    try root.put(ctx.allocator, "check_suppression", .{ .bool = app.mail.check_suppression });
    try root.put(ctx.allocator, "webhook_configured", .{ .bool = app.mail.webhook_secret.len > 0 });
    try root.put(ctx.allocator, "unsubscribe_configured", .{ .bool = app.mail.unsubscribe_base_url.len > 0 });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}),
    };
}

test "mail config reports booleans from app.mail" {
    // Confirm the mapping compiles and the field names match app.mail (mail_cfg.Runtime).
    // A full request test runs in tests/admin/test_email.py; this pins the field names.
    const cfg = @import("../mail/config.zig").Runtime{ .check_suppression = true };
    try std.testing.expect(cfg.check_suppression);
    try std.testing.expect(!cfg.require_verified_sender);
}
```

(If `auth.authenticate` returns a different shape than `senders.zig` uses, copy `senders.zig`'s exact call + `.is_superuser` access. Confirm `app.mail`'s field names against `src/mail/config.zig` `Runtime`.)

- [ ] **Step 2: Mount the route** in `src/server.zig`. Add the import near the other api imports:
```zig
const mail_config_api = @import("api/mail_config.zig");
```
Add the route inside the EXISTING `if (gates.mail_unsubscribe)` block (same `.mail` gate, `/api/mail/*` prefix — no new gate):
```zig
                .{ .method = .GET, .pattern = "/api/mail/config", .handler = mail_config_api.get },
```

- [ ] **Step 3: Register the test root** — add to `src/root.zig`'s test block:
```zig
    _ = @import("api/mail_config.zig");
```

- [ ] **Step 4: Build + test**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (ignore the spurious `failed command:` line).

- [ ] **Step 5: Verify check-gating still passes** (the route is behind the existing gate, so no new pattern needed):

Run: `bash scripts/check-gating.sh`
Expected: exit 0 ("gating invariant OK").

- [ ] **Step 6: Fmt + commit**
```bash
mise exec zig@0.16.0 -- zig fmt src/api/mail_config.zig src/server.zig src/root.zig
git add src/api/mail_config.zig src/server.zig src/root.zig
git commit -m "feat(api): GET /api/mail/config — superuser read-only mail policy"
```

---

## Task 2: Email view scaffold — route, nav, manifest, policy strip

**Files:**
- Create: `src/admin/views/email.js`, `tests/admin/test_email.py`
- Modify: `src/admin/app.js` (import + route + nav + render branch), `src/admin.zig` (manifest row), `src/admin/lib/api.js` (helpers)

**Interfaces:**
- Consumes: `api`, `API` from `lib/api.js`; `html`/hooks from `preact.js`.
- Produces: `views/email.js` exports `EmailView`; `API.mailConfig()`.

- [ ] **Step 1: Add API helpers** to the `API` object in `src/admin/lib/api.js`:
```js
  mailConfig: () => api('GET', '/mail/config'),
  senders: () => api('GET', '/senders'),
  inviteSender: (email) => api('POST', '/senders', { email }),
  deleteSender: (id) => api('DELETE', `/collections/_sender_identities/records/${encodeURIComponent(id)}`),
  suppressions: (q) => api('GET', `/collections/_suppressions/records?${q}`),
  addSuppression: (body) => api('POST', '/collections/_suppressions/records', body),
  removeSuppression: (id) => api('DELETE', `/collections/_suppressions/records/${encodeURIComponent(id)}`),
  batches: (q) => api('GET', `/collections/_mail_batches/records?${q}`),
  batchRecipients: (q) => api('GET', `/collections/_mail_batch_recipients/records?${q}`),
```

- [ ] **Step 2: Write the failing test** `tests/admin/test_email.py`:
```python
from conftest import login

def test_email_view_renders_tabs_and_policy(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    # policy strip fetched from GET /api/mail/config
    page.wait_for_selector('[data-test=mailcfg-webhook]')
    # three tabs present
    for t in ("senders", "suppressions", "batches"):
        assert page.locator(f'[data-test=email-tab-{t}]').count() == 1
```

- [ ] **Step 3: Run it — verify it fails**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_email.py -q`
Expected: FAIL (no `#/email` route / `email-view`).

- [ ] **Step 4: Create `src/admin/views/email.js`** (scaffold: policy strip + tab strip; tab bodies added in Tasks 3–5 as `SendersTab`/`SuppressionsTab`/`BatchesTab`, imported from the same file):
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

function Chip({ on, label }) {
  return html`<span class="badge" style=${`background:${on ? 'var(--ok,#1a7f37)' : 'var(--line)'}`}>${on ? '✓' : '✗'} ${label}</span>`;
}

function PolicyStrip() {
  const [cfg, setCfg] = useState(null);
  useEffect(() => { API.mailConfig().then(setCfg).catch(() => setCfg({})); }, []);
  if (cfg == null) return html`<div class="muted">…</div>`;
  return html`
    <div class="row" style="gap:6px;margin:6px 0" data-test="mailcfg">
      <span data-test="mailcfg-require-verified"><${Chip} on=${!!cfg.require_verified_sender} label="verified-sender"/></span>
      <span data-test="mailcfg-check-suppression"><${Chip} on=${!!cfg.check_suppression} label="suppression-check"/></span>
      <span data-test="mailcfg-webhook"><${Chip} on=${!!cfg.webhook_configured} label="webhook"/></span>
      <span data-test="mailcfg-unsubscribe"><${Chip} on=${!!cfg.unsubscribe_configured} label="unsubscribe"/></span>
    </div>`;
}

const TABS = [['senders', 'Senders'], ['suppressions', 'Suppressions'], ['batches', 'Batches']];

export function EmailView() {
  const [tab, setTab] = useState('senders');
  return html`
    <div data-test="email-view">
      <h2>Email</h2>
      <${PolicyStrip}/>
      <div class="row" style="gap:6px;border-bottom:1px solid var(--line);margin-bottom:10px">
        ${TABS.map(([id, label]) => html`
          <button key=${id} data-test=${'email-tab-' + id}
            class=${'navitem' + (tab === id ? ' active' : '')}
            onClick=${() => setTab(id)}>${label}</button>`)}
      </div>
      ${tab === 'senders' ? html`<${SendersTab}/>`
        : tab === 'suppressions' ? html`<${SuppressionsTab}/>`
        : html`<${BatchesTab}/>`}
    </div>`;
}

// Tabs implemented in Tasks 3–5.
function SendersTab() { return html`<div data-test="senders-tab"></div>`; }
function SuppressionsTab() { return html`<div data-test="suppressions-tab"></div>`; }
function BatchesTab() { return html`<div data-test="batches-tab"></div>`; }
```

- [ ] **Step 5: Wire route + nav** in `src/admin/app.js`. Add import `import { EmailView } from '/_/assets/views/email.js';`. In `parseRoute`, add `if (seg[0] === 'email') return { name: 'email' };`. Add a nav link next to Users: `<a class=${'navitem hide-collapsed' + (route.name === 'email' ? ' active' : '')} href="#/email" data-test="nav-email">📧 Email</a>`. In Shell's render switch, add `${route.name === 'email' ? html\`<${EmailView}/>\` :` to the chain.

- [ ] **Step 6: Manifest row** in `src/admin.zig`:
```zig
    mk("/_/assets/views/email.js", @embedFile("admin/views/email.js"), js_ctype),
```

- [ ] **Step 7: Build + test — verify it passes**

Run: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_email.py -q`
Expected: PASS.

- [ ] **Step 8: Fmt + commit**
```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ src/admin.zig tests/admin/test_email.py
git commit -m "feat(admin): Email view scaffold — route, nav, policy strip, tabs"
```

---

## Task 3: Senders tab

**Files:** Modify `src/admin/views/email.js` (`SendersTab`), `tests/admin/test_email.py` (add cases).

- [ ] **Step 1: Failing test** — add to `tests/admin/test_email.py`:
```python
def test_email_senders_invite_and_delete(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-senders]')
    page.fill('[data-test=sender-invite-email]', "from@example.com")
    page.click('[data-test=sender-invite]')
    page.wait_for_function("[...document.querySelectorAll('[data-test=sender-row]')].some(r => r.textContent.includes('from@example.com'))")
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=sender-row]:has-text("from@example.com") [data-test=sender-delete]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=sender-row]')].some(r => r.textContent.includes('from@example.com'))")
```

- [ ] **Step 2: Run — verify fail.** `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_email.py::test_email_senders_invite_and_delete -q` → FAIL.

- [ ] **Step 3: Implement `SendersTab`** in `email.js` (replace the stub):
```js
function SendersTab() {
  const [rows, setRows] = useState(null);
  const [email, setEmail] = useState('');
  const [err, setErr] = useState('');
  function load() { API.senders().then(r => setRows(r.items || [])).catch(x => setErr((x.data && x.data.message) || 'Failed to load senders')); }
  useEffect(load, []);
  async function invite(e) {
    e.preventDefault(); setErr('');
    try { await API.inviteSender(email.trim()); setEmail(''); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Invite failed'); }
  }
  async function del(id) {
    if (!confirm('Delete this sender identity?')) return;
    try { await API.deleteSender(id); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Delete failed'); }
  }
  return html`
    <div data-test="senders-tab">
      <form class="row" onSubmit=${invite} style="gap:6px;margin-bottom:8px">
        <input data-test="sender-invite-email" placeholder="from@address" value=${email} onInput=${e => setEmail(e.target.value)}/>
        <button data-test="sender-invite">Invite</button>
      </form>
      ${err && html`<div class="error" data-test="senders-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : html`
        <table class="records"><thead><tr><th>Email</th><th>Status</th><th>Verified</th><th></th></tr></thead>
        <tbody>${rows.map(s => html`
          <tr key=${s.id} data-test="sender-row">
            <td>${s.email}</td>
            <td><span class="badge">${s.status}</span></td>
            <td class="muted">${(s.verified_at || '').slice(0, 10)}</td>
            <td><button class="ghost" data-test="sender-delete" onClick=${() => del(s.id)}>✕</button></td>
          </tr>`)}</tbody></table>`}
    </div>`;
}
```

- [ ] **Step 4: Run — verify pass.** Same command → PASS.
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_email.py; git commit -m "feat(admin): Email — Senders tab (list, invite, delete)"`

---

## Task 4: Suppressions tab

**Files:** Modify `src/admin/views/email.js` (`SuppressionsTab`), `tests/admin/test_email.py`.

- [ ] **Step 1: Failing test:**
```python
def test_email_suppressions_add_filter_remove(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-suppressions]')
    page.wait_for_selector('[data-test=suppressions-tab]')
    page.fill('[data-test=suppression-add-email]', "bad@example.com")
    page.select_option('[data-test=suppression-add-reason]', "complaint")
    page.click('[data-test=suppression-add]')
    page.wait_for_function("[...document.querySelectorAll('[data-test=suppression-row]')].some(r => r.textContent.includes('bad@example.com'))")
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=suppression-row]:has-text("bad@example.com") [data-test=suppression-remove]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=suppression-row]')].some(r => r.textContent.includes('bad@example.com'))")
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `SuppressionsTab`** (records API + reason filter built with `JSON.stringify`, injection-safe):
```js
const REASONS = ['hard_bounce', 'complaint', 'unsubscribe'];
function SuppressionsTab() {
  const [rows, setRows] = useState(null);
  const [filter, setFilter] = useState('all');
  const [email, setEmail] = useState('');
  const [reason, setReason] = useState('complaint');
  const [err, setErr] = useState('');
  function load() {
    const p = new URLSearchParams({ perPage: 100, sort: '-created' });
    if (filter !== 'all') p.set('filter', `reason=${JSON.stringify(filter)}`);
    API.suppressions(p.toString()).then(r => setRows(r.items || [])).catch(x => setErr((x.data && x.data.message) || 'Failed to load'));
  }
  useEffect(load, [filter]);
  async function add(e) {
    e.preventDefault(); setErr('');
    try { await API.addSuppression({ email: email.trim(), reason, source: 'admin' }); setEmail(''); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Add failed'); }
  }
  async function remove(id) {
    if (!confirm('Remove this suppression?')) return;
    try { await API.removeSuppression(id); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Remove failed'); }
  }
  return html`
    <div data-test="suppressions-tab">
      <div class="row" style="gap:8px;margin-bottom:8px">
        <label class="muted">Reason</label>
        <select data-test="suppression-filter" value=${filter} onChange=${e => { const v = e.target.value; if (v !== filter) { setRows(null); setFilter(v); } }}>
          <option value="all">all</option>${REASONS.map(r => html`<option key=${r} value=${r}>${r}</option>`)}
        </select>
      </div>
      <form class="row" onSubmit=${add} style="gap:6px;margin-bottom:8px">
        <input data-test="suppression-add-email" placeholder="email" value=${email} onInput=${e => setEmail(e.target.value)}/>
        <select data-test="suppression-add-reason" value=${reason} onChange=${e => setReason(e.target.value)}>${REASONS.map(r => html`<option key=${r} value=${r}>${r}</option>`)}</select>
        <button data-test="suppression-add">Add</button>
      </form>
      ${err && html`<div class="error" data-test="suppressions-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : html`
        <table class="records"><thead><tr><th>Email</th><th>Reason</th><th>Source</th><th></th></tr></thead>
        <tbody>${rows.map(s => html`
          <tr key=${s.id} data-test="suppression-row">
            <td>${s.email}</td><td><span class="badge">${s.reason}</span></td><td class="muted">${s.source}</td>
            <td><button class="ghost" data-test="suppression-remove" onClick=${() => remove(s.id)}>✕</button></td>
          </tr>`)}</tbody></table>`}
    </div>`;
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_email.py; git commit -m "feat(admin): Email — Suppressions tab (list, filter, add, remove)"`

---

## Task 5: Batches tab (read-only)

**Files:** Modify `src/admin/views/email.js` (`BatchesTab`), `tests/admin/test_email.py`.

**Note:** progress = a client-side aggregation of `_mail_batch_recipients.status` filtered by `batch=<id>`.

- [ ] **Step 1: Failing test** (seed a batch + recipients via the records API, then verify the list + expanded progress):
```python
def test_email_batches_list_and_progress(page):
    login(page)
    from conftest import api_request
    api_request(page, "POST", "/api/collections/_mail_batches/records", {"id": "b1", "queue": "emails", "subject_tpl": "Hi", "total": 2, "status": "active"})
    api_request(page, "POST", "/api/collections/_mail_batch_recipients/records", {"batch": "b1", "email": "a@x.io", "status": "sent"})
    api_request(page, "POST", "/api/collections/_mail_batch_recipients/records", {"batch": "b1", "email": "b@x.io", "status": "pending"})
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-batches]')
    page.wait_for_selector('[data-test=batch-row]')
    page.click('[data-test=batch-row]:has-text("b1")')
    page.wait_for_selector('[data-test=batch-progress]')
    prog = page.inner_text('[data-test=batch-progress]')
    assert "sent" in prog and "1" in prog
```
(If the records API rejects a client-supplied `id`, drop `"id":"b1"` from the batch insert and match on the subject/`total` instead; confirm the create response shape when implementing.)

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `BatchesTab`:**
```js
const RCPT_STATES = ['sent', 'pending', 'failed', 'suppressed', 'invalid', 'canceled'];
function BatchProgress({ id }) {
  const [counts, setCounts] = useState(null);
  useEffect(() => {
    const p = new URLSearchParams({ perPage: 500, filter: `batch=${JSON.stringify(id)}` });
    API.batchRecipients(p.toString()).then(r => {
      const c = {}; (r.items || []).forEach(x => { c[x.status] = (c[x.status] || 0) + 1; });
      setCounts(c);
    }).catch(() => setCounts({}));
  }, [id]);
  if (counts == null) return html`<span class="muted">…</span>`;
  return html`<span data-test="batch-progress">${RCPT_STATES.filter(s => counts[s]).map(s => `${s}: ${counts[s]}`).join('  ·  ') || 'no recipients'}</span>`;
}
function BatchesTab() {
  const [rows, setRows] = useState(null);
  const [open, setOpen] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    const p = new URLSearchParams({ perPage: 50, sort: '-created' });
    API.batches(p.toString()).then(r => setRows(r.items || [])).catch(x => setErr((x.data && x.data.message) || 'Failed to load batches'));
  }, []);
  return html`
    <div data-test="batches-tab">
      ${err && html`<div class="error" data-test="batches-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : rows.length === 0 ? html`<div class="muted" data-test="batches-empty">No batches</div>` : html`
        <table class="records"><thead><tr><th>Batch</th><th>List</th><th>Status</th><th>Total</th><th>Progress</th></tr></thead>
        <tbody>${rows.map(b => html`
          <tr key=${b.id} data-test="batch-row" style="cursor:pointer" onClick=${() => setOpen(open === b.id ? null : b.id)}>
            <td>${(b.id || '').slice(0, 8)}</td><td>${b.list || b.subject_tpl || ''}</td>
            <td><span class="badge">${b.status}</span></td><td class="muted">${b.total}</td>
            <td>${open === b.id ? html`<${BatchProgress} id=${b.id}/>` : html`<span class="muted">expand</span>`}</td>
          </tr>`)}</tbody></table>`}
    </div>`;
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_email.py; git commit -m "feat(admin): Email — Batches tab (read-only progress)"`

---

## Task 6: Docs, changelog, full-suite verification

**Files:** Create `changelog.d/admin-ui-email.md`; modify `docs/framework.md` (+ `site/src/content/docs/framework.md`); `docs/api.md` (+ mirror) for the new endpoint.

- [ ] **Step 1: Changelog** `changelog.d/admin-ui-email.md`:
```markdown
### Features
- Admin UI: an **Email** view — manage verified sender identities (list / invite / delete), the suppression list (add / remove / filter by reason, incl. one-click-unsubscribe entries), and read-only bulk-send batch progress, with a read-only mail-policy strip. Backed by the existing mail APIs plus a new superuser `GET /api/mail/config` (booleans only, no secrets).
```

- [ ] **Step 2: Docs.** Add an "Email" bullet to the admin-UI section of `docs/framework.md` (mirror to `site/src/content/docs/framework.md`), and document `GET /api/mail/config` in `docs/api.md` (mirror to `site/src/content/docs/api.md`). Build the site: `cd site && npm run build && cd ..` → clean.

- [ ] **Step 3: Full verification.**
```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig fmt --check src build.zig
bash scripts/check-gating.sh
mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/ -q -n auto
```
Expected: unit green; fmt clean; gating OK; full browser suite green (existing + `test_email.py`). If the `-n auto` run hits the known stale-`examples/plugins/frontend/dist` / unbuilt-named-fixture flake, `rm -rf examples/plugins/frontend/dist`, build the named fixtures once, and rerun.

- [ ] **Step 4: Commit.** `git add changelog.d/ docs/ site/; git commit -m "docs(admin): document the Email view + GET /api/mail/config"`

---

## Self-review notes

- **Spec coverage:** new endpoint → Task 1; scaffold + policy strip → Task 2; Senders → Task 3; Suppressions (incl. unsubscribe as a reason filter) → Task 4; Batches read-only progress → Task 5; docs/changelog/verify → Task 6.
- **Type/name consistency:** `API.mailConfig/senders/inviteSender/deleteSender/suppressions/addSuppression/removeSuppression/batches/batchRecipients` defined once (Task 2 Step 1); `EmailView` exported Task 2, imported in `app.js` same task; `SendersTab`/`SuppressionsTab`/`BatchesTab` stubbed in Task 2, filled in Tasks 3–5. Manifest const `js_ctype` (from Phase 1).
- **Security:** policy strip is booleans only; sender list via `/api/senders` (no token); `_sender_identities` touched only for DELETE; filters built with `JSON.stringify`; all superuser.
- **Confirm-when-implementing:** `auth.authenticate` exact call + `.is_superuser` (copy from `senders.zig`); `app.mail` field names (against `src/mail/config.zig`); whether the records API accepts a client-supplied `id` on the batch-seed test (Task 5 Step 1 note).
