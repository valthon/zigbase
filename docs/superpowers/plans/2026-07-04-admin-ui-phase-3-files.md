# Admin UI Phase 3 — Files & storage view — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Files & storage** admin view (`/_/#/files`) — browse per-collection file fields with image previews, upload/replace, remove files, and a read-only storage-backend strip — plus a small `GET /api/files/config` endpoint that exposes non-secret storage info.

**Architecture:** A new `src/admin/views/files.js` ES module on the Phase-1/2 foundation (one new `src/admin.zig` manifest row, `#/files` route + nav, `lib/api.js` helpers). Composes existing superuser records + `/api/files/...` APIs; the only new server code is `src/api/files_config.zig` + a small `storage_info` struct threaded onto `app` in `serveImpl` (the storage config is not otherwise retained at runtime).

**Tech Stack:** Zig 0.16 (`ctx.app`, `auth.authenticate`, `std.json`, `build_options.s3`), Preact 10 + htm, the admin `api()` client's multipart (`isForm`) path + browser `FormData`, Playwright (`tests/admin/`, `-n auto`).

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild; every asset `@embedFile`-d; modules import by absolute `/_/assets/...` path.
- **Superuser-only.** File writes/reads use the admin `zb_auth`+`zb_csrf` cookie session; `GET /api/files/config` returns 403 to non-superusers.
- **NO secrets in the UI or the endpoint.** `files_config` exposes only `backend` + `bucket`/`region`/`endpoint`/`key_prefix`/`dir` — NEVER `s3_access_key_id` / `s3_secret_access_key`. A unit test asserts no credential key appears.
- **Same-origin cookie preview.** Image previews use `<img src="/api/files/:col/:rec/:name">` (GET carries the `zb_auth` cookie; superuser bypasses `viewRule`; no CSRF on GET) — no `?token=`. Non-images → download link (`?download`).
- **Phase 1–2 guards:** every `<select>`/filter resets its list only on a real change; every async `useEffect` uses an `active`-flag cleanup; the file drawer is keyed on the record id.
- **`data-test=` hooks**; `tests/admin/test_files.py` under `-n auto`; touched `.zig` `zig fmt`-clean; run the FULL `tests/admin/` suite before finishing; docs/site mirror synced; `changelog.d/` fragment.

## Reference: confirmed facts (read before starting)

- **File field schema** (`GET /api/collections`): a field `{name, type:"file", options:{maxSelect, maxSize?, mimeTypes?}}`. `maxSelect>1` = multi. Record value = a filename string (single) or JSON array of filenames (multi); `""`/`[]` = empty.
- **Serve**: `GET /api/files/:col/:rec/:name` (superuser cookie bypasses viewRule). `?download` forces attachment. Inline for `png jpg jpeg gif webp avif bmp ico`; treat `pdf`/others as download.
- **Upload/replace**: multipart `PATCH /api/collections/:col/records/:id` (or `POST …/records`) — the multipart part name is the **collection field's own name**. Server enforces size/mime/maxSelect.
- **Remove**: single → clear the field; multi → a `<field>-` control key (e.g. `docs-`) with the filename(s). **The exact request shape is probed in Task 4.**
- **admin `api()` client** (`src/admin/lib/api.js`): `api(method, path, body, isForm)` — when `isForm` truthy it does NOT set `Content-Type` and does NOT `JSON.stringify` (so a `FormData` body works, browser sets the multipart boundary); it always adds `X-CSRF-Token` on non-GET. `API.collections()` returns the array (already `.then(r => r.items)`); `API.records(col, q)` returns the envelope.
- **Config** (`src/config.zig`): `data_dir`, `s3_bucket` (non-empty ⇒ S3, in a `-Ds3` build), `s3_region`, `s3_endpoint`, `s3_key_prefix` (all non-secret); `s3_access_key_id`, `s3_secret_access_key` (**SECRET**). Backend selection mirrors `framework.zig` `DefaultStoragePlugin.create` (`~:112`): S3 iff `comptime build_options.s3` AND `cfg.s3_bucket.len > 0`.
- **`app` init** in `serveImpl` (`src/framework.zig:~2223`, `var app = app_mod.App{ … }`) has `cfg` (a `config.Config`) in scope; `app.zig:73` already holds `storage: ?*const Storage` and `app.zig:83` `mail: …Runtime` (the pattern to mirror for `storage_info`).
- **Handler template**: `src/api/mail_config.zig` — `ctx.app`, `app.pool.acquireReader()/defer releaseReader`, `auth.authenticate(app.io, ctx.allocator, app, ctx, &r)` → `.is_superuser`, `std.json` reply.
- **Admin wiring** (Phases 1–2, now on main): `src/admin.zig` `assets` manifest (`mk(path, @embedFile(...), js_ctype)`); `src/admin/app.js` `parseRoute` + `Shell` (nav + render ternary + imports); `src/admin/views/{users,email}.js` are the reference views.

---

## Task 1: `GET /api/files/config` endpoint (+ storage-info on `app`)

**Files:**
- Create: `src/files/info.zig`, `src/api/files_config.zig`
- Modify: `src/app.zig` (add `storage_info` field), `src/framework.zig` (populate it in `serveImpl`), `src/server.zig` (import + route), `src/root.zig` (test imports)
- Test: `src/api/files_config.zig` + `src/files/info.zig` unit tests.

**Interfaces:**
- Produces: `GET /api/files/config` → `{backend:"local"|"s3", …non-secret}`; `files_info.Info` struct on `app.storage_info`.

- [ ] **Step 1: Define `src/files/info.zig`:**
```zig
//! Non-secret storage backend info, lowered from config.Config in serveImpl and
//! exposed read-only via GET /api/files/config. NEVER holds S3 credentials.
pub const Backend = enum { local, s3 };
pub const Info = struct {
    backend: Backend = .local,
    dir: []const u8 = "storage", // local: the storage subdir under data_dir
    bucket: []const u8 = "", // s3 (non-secret)
    region: []const u8 = "",
    endpoint: []const u8 = "",
    key_prefix: []const u8 = "",
};

test "Info defaults to local with no credentials fields" {
    const std = @import("std");
    const i = Info{};
    try std.testing.expect(i.backend == .local);
    try std.testing.expectEqualStrings("storage", i.dir);
}
```

- [ ] **Step 2: Add the field to `src/app.zig`** (next to `storage`/`mail`):
```zig
    /// Non-secret storage backend info (files/info.zig), lowered from config in
    /// serveImpl. Feeds GET /api/files/config. Never holds credentials.
    storage_info: @import("files/info.zig").Info = .{},
```

- [ ] **Step 3: Populate it in `serveImpl`** — in `src/framework.zig` at the `var app = app_mod.App{ … }` initializer (~:2223), add a field mirroring the `DefaultStoragePlugin.create` backend choice:
```zig
        .storage_info = .{
            .backend = if (comptime build_options.s3) (if (cfg.s3_bucket.len > 0) .s3 else .local) else .local,
            .dir = "storage",
            .bucket = cfg.s3_bucket,
            .region = cfg.s3_region,
            .endpoint = cfg.s3_endpoint,
            .key_prefix = cfg.s3_key_prefix,
        },
```
(Confirm `cfg` is the in-scope `config.Config` at that initializer and that `build_options` is imported in framework.zig — it is used by `DefaultStoragePlugin.create`. The bucket/region/etc. slices borrow from `cfg`, which outlives `app`.)

- [ ] **Step 4: Write the handler `src/api/files_config.zig`:**
```zig
//! GET /api/files/config — superuser-only, read-only storage backend info for the
//! admin UI. Non-secret only; NEVER exposes the S3 access key id / secret.
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

    const si = app.storage_info;
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "backend", .{ .string = if (si.backend == .s3) "s3" else "local" });
    if (si.backend == .s3) {
        try root.put(ctx.allocator, "bucket", .{ .string = si.bucket });
        try root.put(ctx.allocator, "region", .{ .string = si.region });
        try root.put(ctx.allocator, "endpoint", .{ .string = si.endpoint });
        try root.put(ctx.allocator, "key_prefix", .{ .string = si.key_prefix });
    } else {
        try root.put(ctx.allocator, "dir", .{ .string = si.dir });
    }
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}),
    };
}

test "files config JSON never contains credential keys" {
    const info = @import("../files/info.zig");
    // Pin: the Info struct has no access-key/secret fields at all.
    const fields = @typeInfo(info.Info).@"struct".fields;
    inline for (fields) |f| {
        try std.testing.expect(std.mem.indexOf(u8, f.name, "access_key") == null);
        try std.testing.expect(std.mem.indexOf(u8, f.name, "secret") == null);
    }
}
```
(Match `auth.authenticate`'s exact call + `.is_superuser` to `mail_config.zig`/`senders.zig`.)

- [ ] **Step 5: Mount the route** in `src/server.zig`. Import near the api imports:
```zig
const files_config_api = @import("api/files_config.zig");
```
Add to the UNCONDITIONAL base route table, next to the other `/api/files/*` routes (it is 3 segments — `api/files/config` — so it never collides with the 5-segment `:col/:rec/:name` serve route, same shape as `/api/files/token`):
```zig
    .{ .method = .GET, .pattern = "/api/files/config", .handler = files_config_api.get },
```

- [ ] **Step 6: Register test roots** in `src/root.zig`'s test block:
```zig
    _ = @import("api/files_config.zig");
    _ = @import("files/info.zig");
```

- [ ] **Step 7: Build + test + gating.**
```bash
mise exec zig@0.16.0 -- zig build test --summary all
bash scripts/check-gating.sh
```
Expected: `Build Summary: N/N tests passed`; gating exit 0 (the route is unconditional — no gate needed).

- [ ] **Step 8: Fmt + commit.**
```bash
mise exec zig@0.16.0 -- zig fmt src/files/info.zig src/api/files_config.zig src/app.zig src/framework.zig src/server.zig src/root.zig
git add src/files/info.zig src/api/files_config.zig src/app.zig src/framework.zig src/server.zig src/root.zig
git commit -m "feat(api): GET /api/files/config — superuser storage backend info"
```

---

## Task 2: Files view scaffold — route, nav, manifest, storage strip, collection picker

**Files:**
- Create: `src/admin/views/files.js`, `tests/admin/test_files.py`
- Modify: `src/admin/app.js` (import + route + nav + render branch), `src/admin.zig` (manifest row), `src/admin/lib/api.js` (helpers)

**Interfaces:**
- Consumes: `api`, `API` from `lib/api.js`; `html`/hooks. `GET /api/files/config`, `GET /api/collections`.
- Produces: `views/files.js` exports `FilesView`; `API.filesConfig()`, `API.uploadFile(col,id,formData)`.

- [ ] **Step 1: Add API helpers** to the `API` object in `src/admin/lib/api.js`:
```js
  filesConfig: () => api('GET', '/files/config'),
  uploadFile: (col, id, formData) => api('PATCH', `/collections/${encodeURIComponent(col)}/records/${encodeURIComponent(id)}`, formData, true),
```
(`API.collections()` and `API.records(col, q)` already exist and are reused.)

- [ ] **Step 2: Write the failing test** `tests/admin/test_files.py`:
```python
from conftest import login, api_request

def _seed_file_collection(page, col="assets"):
    api_request(page, "POST", "/api/collections", {"name": col, "type": "base",
        "fields": [{"name": "img", "type": "file", "options": {"maxSelect": 1}}]})

def test_files_view_storage_strip_and_picker(page):
    login(page)
    _seed_file_collection(page)
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    # storage strip fetched from GET /api/files/config
    page.wait_for_selector('[data-test=storage-backend]')
    assert page.inner_text('[data-test=storage-backend]').strip() != ""
    # collection picker lists the file-field collection
    page.wait_for_selector('[data-test=files-collection]')
    page.select_option('[data-test=files-collection]', "assets")
```

- [ ] **Step 3: Run it — verify fail.** `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_files.py -q` → FAIL (no `#/files`).

- [ ] **Step 4: Create `src/admin/views/files.js`** (scaffold: storage strip + collection picker filtered to file-field collections + a records-browser stub filled in Task 3):
```js
import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

const IMG_EXT = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico'];
export const isImage = (name) => IMG_EXT.includes((name.split('.').pop() || '').toLowerCase());
export const fileFields = (col) => (col.fields || []).filter(f => f.type === 'file');

function StorageStrip() {
  const [cfg, setCfg] = useState(null);
  useEffect(() => {
    let active = true;
    API.filesConfig().then(c => { if (active) setCfg(c); }).catch(() => { if (active) setCfg({}); });
    return () => { active = false; };
  }, []);
  if (cfg == null) return html`<div class="muted">…</div>`;
  const label = cfg.backend === 's3' ? `S3 · ${cfg.bucket || ''} ${cfg.region || ''}` : `Local disk · ${cfg.dir || 'storage'}`;
  return html`<div class="row" style="margin:6px 0"><span class="badge" data-test="storage-backend">${label}</span></div>`;
}

export function FilesView() {
  const [cols, setCols] = useState(null);
  const [col, setCol] = useState('');
  const [err, setErr] = useState('');
  useEffect(() => {
    let active = true;
    API.collections()
      .then(cs => { if (!active) return; const withFiles = cs.filter(c => fileFields(c).length > 0); setCols(withFiles);
        if (withFiles.length && !col) setCol(withFiles[0].name); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load collections'); });
    return () => { active = false; };
  }, []);
  const active = (cols || []).find(c => c.name === col);
  return html`
    <div data-test="files-view">
      <h2>Files</h2>
      <${StorageStrip}/>
      ${err && html`<div class="error" data-test="files-error">${err}</div>`}
      ${cols == null ? html`<div class="muted">…</div>` : cols.length === 0 ? html`<div class="muted" data-test="files-none">No collections have file fields</div>` : html`
        <div class="row" style="gap:8px">
          <label class="muted">Collection</label>
          <select data-test="files-collection" value=${col} onChange=${e => { const v = e.target.value; if (v !== col) setCol(v); }}>
            ${cols.map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}
          </select>
        </div>
        <${RecordsBrowser} col=${col} fields=${active ? fileFields(active) : []}/>`}
    </div>`;
}

// Filled in Task 3.
function RecordsBrowser({ col, fields }) { return html`<div data-test="files-records"></div>`; }
```

- [ ] **Step 5: Wire route + nav** in `src/admin/app.js`: `import { FilesView } from '/_/assets/views/files.js';`; in `parseRoute` add `if (seg[0] === 'files') return { name: 'files' };`; add a nav link `<a class=${'navitem hide-collapsed' + (route.name === 'files' ? ' active' : '')} href="#/files" data-test="nav-files">📁 Files</a>`; add the render branch `${route.name === 'files' ? html\`<${FilesView}/>\` :` to Shell's chain.

- [ ] **Step 6: Manifest row** in `src/admin.zig`:
```zig
    mk("/_/assets/views/files.js", @embedFile("admin/views/files.js"), js_ctype),
```

- [ ] **Step 7: Build + test — verify pass.** Same command → PASS.

- [ ] **Step 8: Fmt + commit.**
```bash
mise exec zig@0.16.0 -- zig fmt src/admin.zig
git add src/admin/ src/admin.zig tests/admin/test_files.py
git commit -m "feat(admin): Files view scaffold — storage strip + collection picker"
```

---

## Task 3: Records browser + file preview

**Files:** Modify `src/admin/views/files.js` (`RecordsBrowser`), `tests/admin/test_files.py`.

**Interfaces:** Consumes `API.records`. A file field value is a string (single) or array (multi); normalize to an array with `filesOf(rec, field)`.

- [ ] **Step 1: Failing test** — add to `tests/admin/test_files.py`:
```python
def test_files_browse_shows_record_file(page):
    login(page)
    _seed_file_collection(page)
    # seed a record WITH a file via multipart (use Playwright's request API with multipart)
    import pathlib
    png = pathlib.Path(__file__).parent / "_fixtures_1x1.png"
    png.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6360000002000100" + "05fe02fea7"[:8] + "0000000049454e44ae426082"))
    r = page.request.post("/api/collections/assets/records",
        multipart={"img": {"name": "pic.png", "mimeType": "image/png", "buffer": png.read_bytes()}},
        headers={"X-CSRF-Token": _csrf(page)})
    assert r.ok, r.text()
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    page.select_option('[data-test=files-collection]', "assets")
    page.wait_for_selector('[data-test=file-record-row]')
    # the record's image field renders a thumbnail
    page.click('[data-test=file-record-row]')
    page.wait_for_selector('[data-test=file-thumb]')
    src = page.get_attribute('[data-test=file-thumb]', 'src')
    assert src.startswith('/api/files/assets/') and src.endswith('.png')
```
Add a `_csrf` helper at the top of the test file (read the `zb_csrf` cookie): 
```python
def _csrf(page):
    for c in page.context.cookies():
        if c["name"] == "zb_csrf": return c["value"]
    return ""
```
(If the 1x1 PNG hex is awkward, generate a valid tiny PNG in the test with a known-good byte literal; the point is a real image file the server accepts.)

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `RecordsBrowser` + a file drawer opener** in `files.js` (replace the stub):
```js
function filesOf(rec, field) {
  const v = rec[field.name];
  if (!v) return [];
  return Array.isArray(v) ? v : [v];
}
function fileUrl(col, id, name, dl) {
  return `/api/files/${encodeURIComponent(col)}/${encodeURIComponent(id)}/${encodeURIComponent(name)}${dl ? '?download' : ''}`;
}
function FileThumb({ col, id, name }) {
  return isImage(name)
    ? html`<img data-test="file-thumb" src=${fileUrl(col, id, name)} alt=${name} style="height:40px;width:40px;object-fit:cover;border:1px solid var(--line);border-radius:4px"/>`
    : html`<a data-test="file-download" href=${fileUrl(col, id, name, true)}>${name}</a>`;
}
function RecordsBrowser({ col, fields }) {
  const [rows, setRows] = useState(null);
  const [open, setOpen] = useState(null);
  const [err, setErr] = useState('');
  const [reload, setReload] = useState(0);
  const doReload = () => setReload(n => n + 1);
  useEffect(() => {
    let active = true; setRows(null);
    API.records(col, new URLSearchParams({ page: 1, perPage: 50, sort: '-created' }).toString())
      .then(r => { if (active) setRows(r.items); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load records'); });
    return () => { active = false; };
  }, [col, reload]);
  if (err) return html`<div class="error" data-test="files-error">${err}</div>`;
  if (rows == null) return html`<div class="muted">…</div>`;
  return html`
    <table class="records" data-test="files-records">
      <thead><tr><th>Record</th>${fields.map(f => html`<th key=${f.name}>${f.name}</th>`)}</tr></thead>
      <tbody>
        ${rows.map(rec => html`
          <tr key=${rec.id} data-test="file-record-row" style="cursor:pointer" onClick=${() => setOpen(rec.id)}>
            <td class="muted">${(rec.id || '').slice(0, 8)}</td>
            ${fields.map(f => html`<td key=${f.name} class="row" style="gap:4px">
              ${filesOf(rec, f).map(n => html`<${FileThumb} key=${n} col=${col} id=${rec.id} name=${n}/>`)}
              ${filesOf(rec, f).length === 0 ? html`<span class="muted">—</span>` : ''}
            </td>`)}
          </tr>`)}
      </tbody>
    </table>
    ${open && html`<${FileDrawer} key=${open} col=${col} fields=${fields} rec=${rows.find(r => r.id === open)} onClose=${() => setOpen(null)} onChanged=${doReload}/>`}`;
}

// Filled in Task 4.
function FileDrawer({ col, fields, rec, onClose, onChanged }) {
  return html`<div class="drawer" data-test="file-drawer"><button class="ghost" onClick=${onClose}>✕</button></div>`;
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_files.py; git commit -m "feat(admin): Files — records browser + image preview"`

---

## Task 4: File drawer — upload / replace / remove

**Files:** Modify `src/admin/views/files.js` (`FileDrawer`), `tests/admin/test_files.py`.

**PROBE FIRST (the remove mechanism is uncertain).** Before writing `remove`, empirically determine how to clear/remove a file, against `src/files/plan.zig`. Launch a server, create the `assets` collection (single `img` file field) + a multi-file field collection, upload files, then test each candidate and keep the one that works:
- (a) multipart `PATCH` with a form field `img-` = the filename (the `<field>-` control key), for BOTH single and multi;
- (b) a JSON `PATCH` `{ "img": "" }` to clear a single field;
- (c) multipart `PATCH` with the field present but empty.
Record in the report which mechanism clears a single field and which removes one file from a multi field, and implement those. Do NOT hardcode an unverified shape.

- [ ] **Step 1: Failing test** — add to `tests/admin/test_files.py` (upload via the UI file input, then remove):
```python
def test_files_upload_and_remove(page):
    login(page)
    _seed_file_collection(page)
    # a record with no file yet
    api_request(page, "POST", "/api/collections/assets/records", {})
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    page.select_option('[data-test=files-collection]', "assets")
    page.wait_for_selector('[data-test=file-record-row]')
    page.click('[data-test=file-record-row]')
    page.wait_for_selector('[data-test=file-drawer]')
    import pathlib
    png = pathlib.Path(__file__).parent / "_fixtures_1x1.png"  # written in test_files_browse_shows_record_file / a fixture helper
    page.set_input_files('[data-test=file-upload]', str(png))
    page.wait_for_selector('[data-test=file-drawer] [data-test=file-thumb]')
    # remove it
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=file-remove]')
    page.wait_for_function("!document.querySelector('[data-test=file-drawer] [data-test=file-thumb]')")
```
Extract the tiny-PNG creation into a `_write_png(dirpath)` helper at the top of the file so both tests share it.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `FileDrawer`** in `files.js` — one section per file field: current file(s) with thumb/download + a remove button, and a file input to upload/replace. Use `API.uploadFile` (multipart) for upload and the PROBED mechanism for remove:
```js
function FileDrawer({ col, fields, rec, onClose, onChanged }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function upload(field, input) {
    const file = input.files && input.files[0];
    if (!file) return;
    setBusy(true); setErr('');
    try {
      const fd = new FormData();
      fd.append(field.name, file);
      await API.uploadFile(col, rec.id, fd);
      onChanged();
    } catch (x) { setErr((x.data && x.data.message) || 'Upload failed'); }
    finally { setBusy(false); input.value = ''; }
  }
  async function remove(field, name) {
    if (!confirm(`Remove ${name}?`)) return;
    setBusy(true); setErr('');
    try {
      // IMPLEMENT PER TASK-4 PROBE. Example if the `<field>-` multipart control works:
      const fd = new FormData();
      fd.append(field.name + '-', name);
      await API.uploadFile(col, rec.id, fd);
      onChanged();
    } catch (x) { setErr((x.data && x.data.message) || 'Remove failed'); }
    finally { setBusy(false); }
  }
  return html`
    <div class="drawer" data-test="file-drawer" style="position:fixed;top:0;right:0;bottom:0;width:420px;background:var(--panel);border-left:1px solid var(--line);padding:16px;overflow:auto">
      <div class="row"><b style="flex:1">Files · ${(rec.id || '').slice(0, 8)}</b><button class="ghost" onClick=${onClose}>✕</button></div>
      ${err && html`<div class="error" data-test="file-error">${err}</div>`}
      ${fields.map(field => html`
        <div key=${field.name} class="field">
          <label>${field.name} ${field.options && field.options.maxSelect > 1 ? html`<span class="badge">multi</span>` : ''}</label>
          <div class="row" style="gap:6px;flex-wrap:wrap">
            ${filesOf(rec, field).map(n => html`
              <span key=${n} class="row" style="gap:2px;align-items:center">
                <${FileThumb} col=${col} id=${rec.id} name=${n}/>
                <button class="ghost" data-test="file-remove" disabled=${busy} onClick=${() => remove(field, n)}>✕</button>
              </span>`)}
          </div>
          <input type="file" data-test="file-upload" disabled=${busy} onChange=${e => upload(field, e.target)}/>
        </div>`)}
    </div>`;
}
```
(The `FileDrawer` is keyed on the record id in `RecordsBrowser` (Task 3), so switching records remounts it. `filesOf`/`FileThumb`/`fileUrl` are defined in Task 3.)

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit.** `mise exec zig@0.16.0 -- zig fmt src/admin.zig; git add src/admin/ tests/admin/test_files.py; git commit -m "feat(admin): Files — file drawer upload/replace/remove"`

---

## Task 5: Docs, changelog, full-suite verification

**Files:** Create `changelog.d/admin-ui-files.md`; modify `docs/framework.md` (+ mirror), `docs/api.md` (+ mirror, for `GET /api/files/config`).

- [ ] **Step 1: Changelog** `changelog.d/admin-ui-files.md`:
```markdown
### Features
- Admin UI: a **Files** view — browse per-collection file fields with image previews, upload/replace files, and remove them, plus a read-only storage-backend strip (local disk vs S3). Backed by the existing records + file-serve APIs plus a new superuser `GET /api/files/config` (non-secret backend info only — never the S3 credentials).
```

- [ ] **Step 2: Docs.** Add a "Files" bullet to the admin-UI section of `docs/framework.md` (mirror to `site/src/content/docs/framework.md`); document `GET /api/files/config` in `docs/api.md` (mirror to `site/`). Build the site: `cd site && npm run build && cd ..` → clean.

- [ ] **Step 3: Full verification.**
```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig fmt --check src build.zig
bash scripts/check-gating.sh
mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/ -q -n auto
```
Expected: unit green; fmt clean; gating OK; full browser suite green (existing + `test_files.py`). If the `-n auto` run hits the known stale-`examples/plugins/frontend/dist` / unbuilt-named-fixture flake, `rm -rf examples/plugins/frontend/dist`, build the named fixtures once, rerun; re-run any failing test SERIALLY to confirm it's a flake (not a regression) before accepting.

- [ ] **Step 4: Commit.** `git add changelog.d/ docs/ site/; git commit -m "docs(admin): document the Files view + GET /api/files/config"`

---

## Self-review notes

- **Spec coverage:** endpoint + storage-info threading → Task 1; storage strip + collection picker → Task 2; browse + preview → Task 3; upload/replace + remove → Task 4; docs/changelog/verify → Task 5.
- **Security:** `files_config` whitelists non-secret fields (unit test asserts no `access_key`/`secret` field on `Info`); same-origin cookie preview (no token); superuser-gated.
- **Type/name consistency:** `API.filesConfig/uploadFile` defined Task 2 Step 1; `isImage/fileFields` (Task 2) + `filesOf/fileUrl/FileThumb` (Task 3) used by the drawer (Task 4); `FilesView` exported Task 2, imported in `app.js` same task; manifest const `js_ctype`.
- **Confirm-when-implementing:** `cfg`/`build_options` in-scope at the framework.zig app initializer (Task 1 Step 3); `auth.authenticate` call shape (copy from `mail_config.zig`); the file-remove request shape (Task 4 PROBE); a valid tiny PNG the server accepts (Task 3/4 fixture).
