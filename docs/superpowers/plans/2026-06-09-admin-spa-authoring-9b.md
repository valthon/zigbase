# Admin SPA — Authoring & Realtime (Plan 9b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the ZigBase admin — the full-page tabbed schema editor (Fields / API Rules / Auth+OAuth2), the record drawer editor (all field types + file upload + relations), and the realtime live-view on the records table — then a holistic review and the final merge of SP9, completing the ZigBase roadmap.

**Architecture:** Pure additions to the vendored-Preact SPA `src/admin/app.js` (no build step; `zig build` re-embeds it). New screens drive the existing `/api/*` endpoints: `POST/PATCH/DELETE /api/collections`, multipart `POST/PATCH /api/collections/:c/records`, and the SP7 WebSocket (authenticated with a short-lived token from `auth-refresh`). Each UI task ships its own Playwright headless test.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig …`; bare `zig` is 0.15.2). Preact+htm (vendored). Python+Playwright via mise (`mise exec python@3.13 -- python -m pytest tests/admin/`). Builds on Plan 9a (branch `admin-spa`).

**Build/test:** `mise exec zig@0.16.0 -- zig build` (binary) + `mise exec zig@0.16.0 -- zig build test --summary all` (Zig) + `mise exec python@3.13 -- python -m pytest tests/admin/ -v` (browser).

**Branch:** Continue on `admin-spa`. SP9 merges to `main` at the end of this plan (Task 5), after the holistic review.

**Spec:** `docs/superpowers/specs/2026-06-09-admin-spa-design.md`. **Prereq:** Plan 9a complete (209 Zig tests + 4 Playwright tests green).

---

## Verified facts (current code/API — do not re-derive)

- **`src/admin/app.js` (from 9a):** imports `{ html, render, useState, useEffect } from '/_/assets/preact.js'`; has `API` (`.collections()`, `.records(col,q)`, `.login`, `.logout`), `api(method,path,body,isForm)` (sends `X-CSRF-Token` from the `zb_csrf` cookie on writes; multipart when `isForm` and `body` is a `FormData`), `go(hash)`, `parseRoute` (→ `{name:'records'|'schema'|'collections', col}`), `Shell` (renders `RecordsTable` / `schema-stub` / `collections-home`), `RecordsTable`, `fmt`. **You extend these.**
- **Collection JSON** (`GET /api/collections` / `GET /api/collections/:idOrName`): `{ id, name, type, system, schema:[{id,name,required,unique,type,options}], indexes, listRule, viewRule, createRule, updateRule, deleteRule, options, created, updated }`. `listRule` etc. are `null` (locked), `""` (public), or a string.
- **Field `type` values + `options` shape:** `text`{min?,max?,pattern?} · `email`/`url`/`editor`{} · `date`{min?,max?} · `autodate`{onCreate,onUpdate} · `bool`{} · `number`{mode:"float"|"int"|"fixed",scale?,min?,max?} · `json`{maxSize?} · `select`{values:[],maxSelect} · `relation`{targetCollectionId,cascadeDelete,minSelect?,maxSelect} · `file`{maxSelect,maxSize?,mimeTypes?}.
- **Save payload uses key `fields`** (not `schema`): `POST /api/collections` / `PATCH /api/collections/:idOrName` with `{ name, type, fields:[…], listRule, viewRule, createRule, updateRule, deleteRule, options }`. (The output key is `schema`; the input key is `fields`.) `DELETE /api/collections/:idOrName` → 204.
- **Records:** `POST /api/collections/:c/records` / `PATCH …/:id` accept JSON **or** `multipart/form-data` (file parts under the field name; multi-file removal via a `<field>-` form value carrying a JSON array of filenames). `DELETE …/:id` → 204. `GET …/:id?expand=<relfield>` expands relations.
- **`options.auth.oauth2`** (auth collections): `{ enabled:bool, providers:[{ name, clientId, clientSecret, enabled, redirectUrls:[], authURL?, tokenURL?, userinfoURL?, scopes? }] }`. `clientSecret` is **redacted** in API output; on save, a plaintext secret is encrypted server-side and an **empty** secret preserves the stored one. `options.auth` also has `identityFields:[]`, `minPasswordLength`.
- **Realtime:** `POST /api/collections/_superusers/auth-refresh` (cookie-authed) → `{ token, record }`. WS at `/api/realtime`: send `{"action":"auth","token":…}` → `{"type":"auth","status":"ok"}`, `{"action":"subscribe","topic":"<collection>"}` → `{"type":"ack",…}`; events `{"type":"event","action":"create"|"update"|"delete","record":{…}}` (delete is id-only).
- **Built-in collections:** `_superusers` (auth, system, locked). Records list / collection mgmt require a superuser (the cookie session supplies it).
- **9a Playwright harness** (`tests/admin/conftest.py`): fixtures `binary` (zig build), `server` (temp data dir + `superuser create` + serve), `page` (chromium), helper `login(page)`. Run via `mise exec python@3.13 -- python -m pytest tests/admin/ -v` from repo root.

---

## File Structure

- **Modify** `src/admin/app.js` — add `SchemaEditor` (Tasks 1,4), `RecordDrawer` (Task 2), realtime hookup in `RecordsTable` (Task 3); wire `collections-home`/`schema-stub` to the real screens.
- **Modify** `tests/admin/conftest.py` — add a `seed`/`api_post`/`api_patch` helper (uses the page's session cookie + `zb_csrf`).
- **Create** `tests/admin/test_schema.py`, `tests/admin/test_records.py`, `tests/admin/test_realtime.py`, `tests/admin/test_oauth.py`.

---

### Task 1: Schema editor — Fields & API Rules tabs (`app.js`)

**Files:** Modify `src/admin/app.js`; Modify `tests/admin/conftest.py`; Create `tests/admin/test_schema.py`.

- [ ] **Step 1: Add `SchemaEditor` + helpers to `src/admin/app.js`** (insert before the final `render(...)`; and wire it into `Shell` — see Step 2)

```js
const FIELD_TYPES = ['text','email','url','editor','date','autodate','bool','number','json','select','relation','file'];
const RULES = ['listRule','viewRule','createRule','updateRule','deleteRule'];

function blankField() { return { id: '', name: '', type: 'text', required: false, unique: false, options: {} }; }

function SchemaEditor({ name }) {
  const isNew = name === '__new__';
  const [tab, setTab] = useState('fields');
  const [col, setCol] = useState(null);
  const [allCols, setAllCols] = useState([]);
  const [err, setErr] = useState('');
  const [fieldErrs, setFieldErrs] = useState({});
  useEffect(() => {
    API.collections().then(cs => {
      setAllCols(cs);
      if (isNew) setCol({ name: '', type: 'base', schema: [], listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null, options: { auth: { identityFields: ['email'], minPasswordLength: 8, oauth2: { enabled: false, providers: [] } } } });
      else setCol(cs.find(c => c.name === name) || null);
    }).catch(x => setErr((x.data && x.data.message) || 'Load failed'));
  }, [name]);
  if (col == null) return html`<div class="muted">…</div>`;

  function setF(i, patch) { const s = col.schema.slice(); s[i] = { ...s[i], ...patch }; setCol({ ...col, schema: s }); }
  function setOpt(i, patch) { setF(i, { options: { ...col.schema[i].options, ...patch } }); }
  function addField() { setCol({ ...col, schema: [...col.schema, blankField()] }); }
  function delField(i) { const s = col.schema.slice(); s.splice(i, 1); setCol({ ...col, schema: s }); }
  function setRule(r, v) { setCol({ ...col, [r]: v }); }

  async function save() {
    setErr(''); setFieldErrs({});
    const payload = { name: col.name, type: col.type, fields: col.schema, options: col.options };
    for (const r of RULES) payload[r] = col[r];
    try {
      const saved = isNew ? await API.createCollection(payload) : await API.updateCollection(name, payload);
      go('#/collections/' + encodeURIComponent(saved.name) + '/records');
      location.reload(); // refresh the sidebar list
    } catch (x) {
      setErr((x.data && x.data.message) || 'Save failed');
      if (x.data && x.data.data) setFieldErrs(x.data.data);
    }
  }
  async function del() {
    if (!confirm('Delete collection ' + col.name + '?')) return;
    try { await API.deleteCollection(name); go('#/collections'); location.reload(); }
    catch (x) { setErr((x.data && x.data.message) || 'Delete failed'); }
  }

  const isAuth = col.type === 'auth';
  return html`
    <div data-test="schema-editor">
      <div class="toolbar">
        <h2 style="margin:0">${isNew ? 'New collection' : 'Edit ' + col.name}</h2>
        <div class="grow"></div>
        ${!isNew && !col.system && html`<button class="ghost" data-test="delete-collection" onClick=${del}>Delete</button>`}
        <button data-test="save-collection" onClick=${save}>Save</button>
      </div>
      ${err && html`<div class="error" data-test="schema-error">${err}</div>`}
      <div class="row" style="border-bottom:1px solid var(--line); margin-bottom:12px">
        ${['fields','rules', ...(isAuth ? ['auth'] : [])].map(t => html`<button key=${t} class=${'ghost' + (tab===t?' active':'')} data-test=${'tab-'+t} onClick=${() => setTab(t)} style=${tab===t?'border-color:var(--accent)':''}>${t==='fields'?'Fields':t==='rules'?'API Rules':'Auth / OAuth2'}</button>`)}
      </div>

      ${tab === 'fields' && html`<div data-test="tab-fields-body">
        <div class="field"><label>Name</label><input data-test="col-name" value=${col.name} onInput=${e => setCol({ ...col, name: e.target.value })} disabled=${!isNew && col.system}/></div>
        ${isNew && html`<div class="field"><label>Type</label><select data-test="col-type" value=${col.type} onChange=${e => setCol({ ...col, type: e.target.value })}>${['base','auth'].map(t => html`<option key=${t} value=${t}>${t}</option>`)}</select></div>`}
        <label class="muted">Fields</label>
        ${col.schema.map((f, i) => html`<div class="row" data-test="field-row" style="margin:6px 0; align-items:flex-start; flex-wrap:wrap" key=${i}>
          <input style="width:150px" data-test="field-name" placeholder="name" value=${f.name} onInput=${e => setF(i, { name: e.target.value })} disabled=${isSystemField(f.name)}/>
          <select style="width:120px" data-test="field-type" value=${f.type} onChange=${e => setF(i, { type: e.target.value, options: {} })} disabled=${isSystemField(f.name)}>${FIELD_TYPES.map(t => html`<option key=${t} value=${t}>${t}</option>`)}</select>
          <label class="muted"><input type="checkbox" style="width:auto" checked=${f.required} onChange=${e => setF(i, { required: e.target.checked })}/> req</label>
          <label class="muted"><input type="checkbox" style="width:auto" checked=${f.unique} onChange=${e => setF(i, { unique: e.target.checked })}/> uniq</label>
          ${fieldOptions(f, i, setOpt, allCols)}
          ${!isSystemField(f.name) && html`<button class="ghost" data-test="del-field" onClick=${() => delField(i)}>✕</button>`}
          ${fieldErrs[f.name] && html`<div class="error" style="flex-basis:100%">${fieldErrs[f.name].message}</div>`}
        </div>`)}
        <button class="ghost" data-test="add-field" onClick=${addField}>+ Add field</button>
      </div>`}

      ${tab === 'rules' && html`<div data-test="tab-rules-body">
        ${RULES.map(r => html`<div class="field" key=${r}>
          <label>${r}</label>
          <div class="row">
            <input style="flex:1" data-test=${'rule-'+r} placeholder='empty = public' value=${col[r] == null ? '' : col[r]} disabled=${col[r] == null} onInput=${e => setRule(r, e.target.value)}/>
            <label class="muted"><input type="checkbox" style="width:auto" data-test=${'lock-'+r} checked=${col[r] == null} onChange=${e => setRule(r, e.target.checked ? null : '')}/> lock</label>
          </div>
        </div>`)}
      </div>`}

      ${tab === 'auth' && html`<${AuthTab} col=${col} setCol=${setCol}/>`}
    </div>`;
}

function isSystemField(n) { return ['id','created','updated','email','username','passwordHash','tokenKey','verified'].includes(n); }

function fieldOptions(f, i, setOpt, allCols) {
  const o = f.options || {};
  if (f.type === 'select') return html`<input style="width:200px" data-test="opt-values" placeholder="values: a,b,c" value=${(o.values||[]).join(',')} onInput=${e => setOpt(i, { values: e.target.value.split(',').map(s=>s.trim()).filter(Boolean), maxSelect: o.maxSelect||1 })}/>`;
  if (f.type === 'relation') return html`<select style="width:160px" data-test="opt-target" value=${o.targetCollectionId||''} onChange=${e => setOpt(i, { targetCollectionId: e.target.value, maxSelect: o.maxSelect||1 })}><option value="">target…</option>${allCols.map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}</select>`;
  if (f.type === 'number') return html`<select style="width:110px" data-test="opt-mode" value=${o.mode||'float'} onChange=${e => setOpt(i, { mode: e.target.value })}>${['float','int','fixed'].map(m => html`<option key=${m} value=${m}>${m}</option>`)}</select>`;
  if (f.type === 'file') return html`<input style="width:90px" type="number" data-test="opt-maxselect" placeholder="maxSel" value=${o.maxSelect||1} onInput=${e => setOpt(i, { maxSelect: +e.target.value || 1 })}/>`;
  return '';
}
```

Add to the `API` object (in `app.js`):

```js
  createCollection: (payload) => api('POST', '/collections', payload),
  updateCollection: (name, payload) => api('PATCH', `/collections/${encodeURIComponent(name)}`, payload),
  deleteCollection: (name) => api('DELETE', `/collections/${encodeURIComponent(name)}`),
```

Add a stub `AuthTab` (filled in Task 4) so Task 1 compiles:

```js
function AuthTab({ col, setCol }) { return html`<div data-test="tab-auth-body" class="muted">Auth/OAuth2 — Task 4.</div>`; }
```

- [ ] **Step 2: Wire `Shell` to the real schema editor + a "New collection" entry.** In `Shell`, replace the `schema-stub` and `collections-home` branches:
  - `route.name === 'schema'` → `html\`<${SchemaEditor} name=${route.col}/>\``
  - `collections-home` (the default branch) → add a button: `html\`<div data-test="collections-home"><h2>Collections</h2><button data-test="new-collection" onClick=${() => go('#/collections/__new__')}>+ New collection</button></div>\``

- [ ] **Step 3: Build**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0) + `mise exec zig@0.16.0 -- zig build test --summary all` (PASS).

- [ ] **Step 4: Add a seeding helper to `tests/admin/conftest.py`** (append at the bottom)

```python
def csrf(page):
    for c in page.context.cookies():
        if c["name"] == "zb_csrf":
            return c["value"]
    return ""

def api_request(page, method, path, body=None):
    headers = {"X-CSRF-Token": csrf(page)}
    if body is not None:
        headers["Content-Type"] = "application/json"
    r = page.request.fetch(path, method=method, headers=headers, data=(__import__("json").dumps(body) if body is not None else None))
    return r
```

- [ ] **Step 5: Create `tests/admin/test_schema.py`**

```python
from conftest import login, api_request

def test_create_collection_with_fields_via_ui(page):
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'tasks')
    page.click('[data-test=add-field]')
    page.fill('[data-test=field-name]', 'title')  # first (only) field row
    page.click('[data-test=save-collection]')
    # after save it navigates to the records view + reloads; the sidebar should list 'tasks'
    page.wait_for_selector('[data-test=nav-tasks]', timeout=8000)

def test_edit_rules_lock_toggle(page):
    login(page)
    # seed a base collection via the API (uses the session cookie + csrf)
    api_request(page, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [{"id": "", "name": "body", "type": "text", "options": {}}], "viewRule": ""})
    page.reload()
    page.goto("/_/#/collections/notes")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-rules]')
    # viewRule was "" (public) -> not locked; lock it
    page.check('[data-test=lock-viewRule]')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=nav-notes]', timeout=8000)
    # reload editor: viewRule should now be locked (null -> checkbox checked)
    page.goto("/_/#/collections/notes")
    page.click('[data-test=tab-rules]')
    assert page.is_checked('[data-test=lock-viewRule]')
```

- [ ] **Step 6: Run browser tests**

Run: `cd /home/valthon/nothlav/zigbase && mise exec python@3.13 -- python -m pytest tests/admin/test_schema.py -v`
Expected: 2 passed. Fix `app.js` if a real bug surfaces (rebuild via `zig build`; the pytest `binary` fixture rebuilds per session, so just re-run pytest).

- [ ] **Step 7: Commit**

```bash
git add src/admin/app.js tests/admin/conftest.py tests/admin/test_schema.py
git commit -m "feat(admin): schema editor — fields + API rules tabs"
```

---

### Task 2: Record drawer editor (`app.js`)

**Files:** Modify `src/admin/app.js`; Create `tests/admin/test_records.py`.

- [ ] **Step 1: Add `RecordDrawer` + control rendering to `src/admin/app.js`** (before the final `render(...)`)

```js
function RecordDrawer({ col, record, schema, onClose, onSaved }) {
  const isNew = !record;
  const [vals, setVals] = useState(() => ({ ...(record || {}) }));
  const [files, setFiles] = useState({}); // field -> FileList
  const [removals, setRemovals] = useState({}); // field -> [filenames]
  const [err, setErr] = useState('');
  const [fieldErrs, setFieldErrs] = useState({});
  const editable = schema.filter(f => !['id','created','updated','passwordHash','tokenKey'].includes(f.name) && f.type !== 'autodate');

  function set(name, v) { setVals({ ...vals, [name]: v }); }
  async function save() {
    setErr(''); setFieldErrs({});
    const hasFiles = Object.values(files).some(fl => fl && fl.length);
    let body, isForm = false;
    if (hasFiles || Object.keys(removals).length) {
      const fd = new FormData(); isForm = true;
      for (const f of editable) {
        if (f.type === 'file') continue;
        const v = vals[f.name];
        if (v != null) fd.append(f.name, typeof v === 'object' ? JSON.stringify(v) : String(v));
      }
      for (const [name, fl] of Object.entries(files)) for (const file of fl) fd.append(name, file);
      for (const [name, names] of Object.entries(removals)) if (names.length) fd.append(name + '-', JSON.stringify(names));
      body = fd;
    } else {
      body = {};
      for (const f of editable) if (vals[f.name] !== undefined) body[f.name] = vals[f.name];
    }
    try {
      const saved = isNew
        ? await api('POST', `/collections/${encodeURIComponent(col)}/records`, body, isForm)
        : await api('PATCH', `/collections/${encodeURIComponent(col)}/records/${encodeURIComponent(record.id)}`, body, isForm);
      onSaved(saved);
    } catch (x) { setErr((x.data && x.data.message) || 'Save failed'); if (x.data && x.data.data) setFieldErrs(x.data.data); }
  }
  async function del() {
    if (!confirm('Delete record?')) return;
    try { await api('DELETE', `/collections/${encodeURIComponent(col)}/records/${encodeURIComponent(record.id)}`); onSaved(null); }
    catch (x) { setErr((x.data && x.data.message) || 'Delete failed'); }
  }

  return html`
    <div class="drawer" data-test="record-drawer" style="position:fixed; top:0; right:0; bottom:0; width:380px; background:var(--panel); border-left:1px solid var(--line); padding:16px; overflow:auto; box-shadow:-8px 0 30px rgba(0,0,0,.4)">
      <div class="row"><b style="flex:1">${isNew ? 'New record' : 'Edit record'}</b><button class="ghost" data-test="drawer-close" onClick=${onClose}>✕</button></div>
      ${err && html`<div class="error" data-test="record-error">${err}</div>`}
      ${editable.map(f => html`<div class="field" key=${f.name}>
        <label>${f.name} <span class="muted">(${f.type})</span></label>
        ${control(f, vals[f.name], v => set(f.name, v), files, setFiles, removals, setRemovals)}
        ${fieldErrs[f.name] && html`<div class="error" data-test=${'err-'+f.name}>${fieldErrs[f.name].message}</div>`}
      </div>`)}
      <div class="row" style="margin-top:14px">
        <button data-test="record-save" onClick=${save}>Save</button>
        ${!isNew && html`<button class="ghost" data-test="record-delete" onClick=${del}>Delete</button>`}
      </div>
    </div>`;
}

function control(f, value, set, files, setFiles, removals, setRemovals) {
  const t = f.type, o = f.options || {};
  if (t === 'bool') return html`<input type="checkbox" style="width:auto" data-test=${'in-'+f.name} checked=${!!value} onChange=${e => set(e.target.checked)}/>`;
  if (t === 'number') return html`<input type="text" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
  if (t === 'editor' || t === 'json') return html`<textarea rows="4" data-test=${'in-'+f.name} value=${typeof value === 'object' ? JSON.stringify(value, null, 2) : (value ?? '')} onInput=${e => set(t === 'json' ? safeJson(e.target.value) : e.target.value)}></textarea>`;
  if (t === 'date') return html`<input type="text" placeholder="YYYY-MM-DD" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
  if (t === 'select') return html`<select data-test=${'in-'+f.name} value=${value ?? ''} onChange=${e => set(e.target.value)}><option value="">—</option>${(o.values||[]).map(v => html`<option key=${v} value=${v}>${v}</option>`)}</select>`;
  if (t === 'relation') return html`<${RelationPicker} target=${o.targetCollectionId} value=${value} onChange=${set} name=${f.name}/>`;
  if (t === 'file') {
    const existing = value == null ? [] : (Array.isArray(value) ? value : [value]).filter(Boolean);
    return html`<div>
      ${existing.map(fn => html`<label class="muted" key=${fn} style="display:block"><input type="checkbox" style="width:auto" data-test=${'rm-'+f.name} onChange=${e => setRemovals({ ...removals, [f.name]: e.target.checked ? [...(removals[f.name]||[]), fn] : (removals[f.name]||[]).filter(x=>x!==fn) })}/> ${fn} (remove)</label>`)}
      <input type="file" multiple=${(o.maxSelect||1) > 1} data-test=${'in-'+f.name} onChange=${e => setFiles({ ...files, [f.name]: e.target.files })}/>
    </div>`;
  }
  return html`<input type="text" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
}
function safeJson(s) { try { return JSON.parse(s); } catch (_) { return s; } }

function RelationPicker({ target, value, onChange, name }) {
  const [opts, setOpts] = useState([]);
  useEffect(() => { if (target) API.records(target, 'perPage=50').then(d => setOpts(d.items)).catch(() => {}); }, [target]);
  return html`<select data-test=${'in-'+name} value=${value ?? ''} onChange=${e => onChange(e.target.value || null)}>
    <option value="">—</option>${opts.map(r => html`<option key=${r.id} value=${r.id}>${r.id}</option>`)}</select>`;
}
```

- [ ] **Step 2: Open the drawer from `RecordsTable`.** In `RecordsTable`, add drawer state + a "New record" button + row-click handler. Add near the top of `RecordsTable`:

```js
  const [editing, setEditing] = useState(undefined); // undefined=closed, null=new, record=edit
  const [schema, setSchema] = useState([]);
  useEffect(() => { API.collections().then(cs => { const c = cs.find(x => x.name === col); setSchema(c ? c.schema : []); }); }, [col]);
```

In the toolbar (after the title), add: `html\`<button data-test="new-record" onClick=${() => setEditing(null)}>+ New record</button>\``. Make each row clickable: change the `<tr …>` to include `onClick=${() => setEditing(r)}`. After the table markup, render the drawer:

```js
      ${editing !== undefined && html`<${RecordDrawer} col=${col} record=${editing} schema=${schema} onClose=${() => setEditing(undefined)} onSaved=${() => { setEditing(undefined); load(); }}/>`}
```

- [ ] **Step 3: Build** — `zig build` (EXIT 0) + `zig build test` (PASS).

- [ ] **Step 4: Create `tests/admin/test_records.py`**

```python
from conftest import login, api_request

def setup_posts(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "posts", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "pinned", "type": "bool", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()

def test_create_edit_delete_record(page):
    setup_posts(page)
    page.goto("/_/#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'Hello')
    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert "Hello" in page.locator('[data-test=rows]').inner_text()
    # edit
    page.click('[data-test=row]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'Edited')
    page.click('[data-test=record-save]')
    page.wait_for_function("document.querySelector('[data-test=rows]').innerText.includes('Edited')", timeout=6000)
    # delete
    page.click('[data-test=row]')
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=record-delete]')
    page.wait_for_selector('[data-test=empty]', timeout=6000)
```

- [ ] **Step 5: Run** — `mise exec python@3.13 -- python -m pytest tests/admin/test_records.py -v` → 1 passed. Fix `app.js` on a real bug.

- [ ] **Step 6: Commit**

```bash
git add src/admin/app.js tests/admin/test_records.py
git commit -m "feat(admin): record drawer editor (all field types, files, relations)"
```

---

### Task 3: Realtime live-view (`app.js`)

**Files:** Modify `src/admin/app.js`; Create `tests/admin/test_realtime.py`.

- [ ] **Step 1: Add a realtime hook + wire it into `RecordsTable`.** Add the hook (before `RecordsTable`):

```js
function useLiveCollection(col, apply) {
  useEffect(() => {
    let ws, closed = false;
    (async () => {
      let token;
      try { token = (await API.refresh()).token; } catch (_) { return; } // degrade: no live updates
      if (closed) return;
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/realtime');
      ws.onopen = () => { ws.send(JSON.stringify({ action: 'auth', token })); ws.send(JSON.stringify({ action: 'subscribe', topic: col })); };
      ws.onmessage = (e) => { let m; try { m = JSON.parse(e.data); } catch (_) { return; } if (m.type === 'event') apply(m); };
    })();
    return () => { closed = true; if (ws) try { ws.close(); } catch (_) {} };
  }, [col]);
}
```

Add to `API`: `refresh: () => api('POST', '/collections/_superusers/auth-refresh'),`.

In `RecordsTable`, after the `useEffect(load, …)`, add the live subscription that mutates `data`:

```js
  useLiveCollection(col, (m) => {
    setData(prev => {
      if (!prev) return prev;
      const items = prev.items.slice();
      const id = m.record && m.record.id;
      const idx = items.findIndex(r => r.id === id);
      if (m.action === 'delete') { if (idx >= 0) items.splice(idx, 1); }
      else if (m.action === 'update') { if (idx >= 0) items[idx] = m.record; }
      else if (m.action === 'create') { if (idx < 0) items.unshift(m.record); }
      return { ...prev, items };
    });
  });
```

- [ ] **Step 2: Build** — `zig build` (EXIT 0) + `zig build test` (PASS).

- [ ] **Step 3: Create `tests/admin/test_realtime.py`**

```python
from conftest import login, api_request

def test_records_table_updates_live(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "live", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()
    page.goto("/_/#/collections/live/records")
    page.wait_for_selector('[data-test=records-view]')
    # give the WS time to auth+subscribe
    page.wait_for_timeout(800)
    # create a record via the API (out of band) -> a live 'create' event should add a row
    api_request(page, "POST", "/api/collections/live/records", {"title": "LiveRow"})
    page.wait_for_function("document.querySelector('[data-test=rows]') && document.querySelector('[data-test=rows]').innerText.includes('LiveRow')", timeout=8000)
```

- [ ] **Step 4: Run** — `mise exec python@3.13 -- python -m pytest tests/admin/test_realtime.py -v` → 1 passed. If the live row doesn't appear, check (a) `auth-refresh` returns a token, (b) the WS auth/subscribe messages match SP7, (c) the event `record.id` matching. Fix `app.js`.

- [ ] **Step 5: Commit**

```bash
git add src/admin/app.js tests/admin/test_realtime.py
git commit -m "feat(admin): realtime live-view on the records table"
```

---

### Task 4: Auth / OAuth2 tab (`app.js`)

**Files:** Modify `src/admin/app.js`; Create `tests/admin/test_oauth.py`.

- [ ] **Step 1: Replace the `AuthTab` stub in `src/admin/app.js`** with the real tab:

```js
const OAUTH_PRESETS = ['google','github','microsoft','discord','generic'];

function AuthTab({ col, setCol }) {
  const auth = col.options.auth || { identityFields: ['email'], minPasswordLength: 8, oauth2: { enabled: false, providers: [] } };
  const oauth2 = auth.oauth2 || { enabled: false, providers: [] };
  function setAuth(patch) { setCol({ ...col, options: { ...col.options, auth: { ...auth, ...patch } } }); }
  function setOauth(patch) { setAuth({ oauth2: { ...oauth2, ...patch } }); }
  function setProv(i, patch) { const ps = oauth2.providers.slice(); ps[i] = { ...ps[i], ...patch }; setOauth({ providers: ps }); }
  function addProv() { setOauth({ enabled: true, providers: [...oauth2.providers, { name: 'google', clientId: '', clientSecret: '', enabled: true, redirectUrls: [] }] }); }
  function delProv(i) { const ps = oauth2.providers.slice(); ps.splice(i, 1); setOauth({ providers: ps }); }

  return html`<div data-test="tab-auth-body">
    <div class="field"><label>identityFields (comma)</label><input data-test="identity-fields" value=${(auth.identityFields||[]).join(',')} onInput=${e => setAuth({ identityFields: e.target.value.split(',').map(s=>s.trim()).filter(Boolean) })}/></div>
    <div class="field"><label>minPasswordLength</label><input type="number" data-test="min-pw" value=${auth.minPasswordLength||8} onInput=${e => setAuth({ minPasswordLength: +e.target.value || 8 })}/></div>
    <label class="muted"><input type="checkbox" style="width:auto" data-test="oauth-enabled" checked=${oauth2.enabled} onChange=${e => setOauth({ enabled: e.target.checked })}/> OAuth2 enabled</label>
    ${oauth2.providers.map((p, i) => html`<div class="row" data-test="oauth-provider" style="flex-wrap:wrap; border:1px solid var(--line); border-radius:8px; padding:8px; margin:8px 0" key=${i}>
      <select style="width:120px" data-test="oauth-name" value=${p.name} onChange=${e => setProv(i, { name: e.target.value })}>${OAUTH_PRESETS.map(n => html`<option key=${n} value=${n}>${n}</option>`)}</select>
      <input style="width:160px" data-test="oauth-clientid" placeholder="clientId" value=${p.clientId||''} onInput=${e => setProv(i, { clientId: e.target.value })}/>
      <input style="width:160px" type="password" data-test="oauth-secret" placeholder=${p.clientSecret ? '•••• (set; leave blank to keep)' : 'clientSecret'} value=${p.clientSecret||''} onInput=${e => setProv(i, { clientSecret: e.target.value })}/>
      <input style="width:200px" data-test="oauth-redirects" placeholder="redirectUrls (comma)" value=${(p.redirectUrls||[]).join(',')} onInput=${e => setProv(i, { redirectUrls: e.target.value.split(',').map(s=>s.trim()).filter(Boolean) })}/>
      <label class="muted"><input type="checkbox" style="width:auto" checked=${p.enabled} onChange=${e => setProv(i, { enabled: e.target.checked })}/> on</label>
      <button class="ghost" data-test="del-provider" onClick=${() => delProv(i)}>✕</button>
    </div>`)}
    <button class="ghost" data-test="add-provider" onClick=${addProv}>+ Add provider</button>
  </div>`;
}
```

Note: the secret is shown as a redacted placeholder when the loaded value is non-empty (the API
returns it redacted to `""`, so the placeholder shows the generic "set" hint only after a save reloads
with a stored value — to keep it simple, the placeholder reflects whether `p.clientSecret` is
currently non-empty in the form). On save, an empty `clientSecret` preserves the stored one
(server-side, per SP8). The `options` object (with `auth.oauth2`) is already included in the
`SchemaEditor.save` payload from Task 1.

- [ ] **Step 2: Build** — `zig build` (EXIT 0) + `zig build test` (PASS).

- [ ] **Step 3: Create `tests/admin/test_oauth.py`**

```python
from conftest import login, api_request

def test_configure_oauth_provider_and_secret_redacted(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "members", "type": "auth", "fields": []})
    page.reload()
    page.goto("/_/#/collections/members")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-auth]')
    page.click('[data-test=add-provider]')
    page.fill('[data-test=oauth-clientid]', 'my-client-id')
    page.fill('[data-test=oauth-secret]', 'my-secret')
    page.fill('[data-test=oauth-redirects]', 'https://app/cb')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=nav-members]', timeout=8000)
    # reload the editor: clientId persists, secret comes back redacted (empty input value)
    page.goto("/_/#/collections/members")
    page.click('[data-test=tab-auth]')
    page.wait_for_selector('[data-test=oauth-provider]')
    assert page.input_value('[data-test=oauth-clientid]') == 'my-client-id'
    assert page.input_value('[data-test=oauth-secret]') == ''  # redacted, never returned
```

- [ ] **Step 4: Run** — `mise exec python@3.13 -- python -m pytest tests/admin/test_oauth.py -v` → 1 passed. Fix `app.js`/payload if the secret isn't redacted or the provider doesn't persist (check that `SchemaEditor.save` includes `col.options`, and that the API redacts `clientSecret`).

- [ ] **Step 5: Commit**

```bash
git add src/admin/app.js tests/admin/test_oauth.py
git commit -m "feat(admin): auth identity + OAuth2 provider config tab"
```

---

### Task 5: Full suite, holistic review, merge

**Files:** none (validation + merge).

- [ ] **Step 1: Run the whole stack**

```bash
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all
mise exec python@3.13 -- python -m pytest tests/admin/ -v
```
Expected: binary builds; Zig suite green; all Playwright tests (9a shell/login/browse + 9b schema/records/realtime/oauth) green.

- [ ] **Step 2: Manual eyeball (optional but recommended)** — `zig build`, `superuser create`, `serve`, open `/_/` in a browser; sanity-check the look/feel of the sidebar, schema editor tabs, record drawer, and a live update. (Document anything off; fix + commit.)

- [ ] **Step 3: Holistic security review** — dispatch a review over the whole SP9 diff (`git diff main..admin-spa -- 'src/*' 'tests/*'`). Focus on the **serving + client auth surface** (the SPA logic is browser-side, so the threat model is: what the embedded app + the serving layer expose):
  - **No JWT in storage:** confirm `app.js` never writes a token to `localStorage`/`sessionStorage`; the realtime token is held in a closure only.
  - **CSRF:** writes send `X-CSRF-Token` from the readable `zb_csrf` cookie; the cookie/CSRF pair is the SP5 design.
  - **Serving safety:** `admin.serve` only ever returns the four embedded assets or `index.html` — no path is interpolated into a filesystem read (no arbitrary file disclosure); assets carry `nosniff`; `/_/` can't reach `/api/*` handlers or vice-versa.
  - **Superuser-gating:** every management/records call the admin makes is already superuser-gated server-side (SP5/SP6); a non-superuser session gets 403 → login. The admin adds no new privileged endpoint.
  - **OAuth secret:** the UI never displays a stored secret (API redacts it); an empty submit preserves it; a typed secret is encrypted server-side (SP8). Confirm the UI doesn't echo it back.
  - **XSS surface:** Preact escapes interpolated text by default; confirm no `dangerouslySetInnerHTML`/`innerHTML` use in `app.js`. The `nosniff` + the SP8 file-serving `attachment` rules bound user-content rendering.
  Fix any CRITICAL/IMPORTANT findings (new commits) and re-run all three suites.

- [ ] **Step 4: Merge SP9 → `main`** (final sub-project)

```bash
git checkout main
git merge --no-ff admin-spa -m "merge: SP9 Admin SPA (collections, records, realtime, OAuth)

Embedded no-build Preact admin UI served at /_/ from the single binary:
superuser login (cookie/CSRF, no token in storage), a collapsible collections
sidebar, a full-page tabbed schema editor (fields / API rules / auth+OAuth2),
a record drawer editor (all field types, file upload, relations), and a
realtime live-view (auth-refresh token -> WS -> subscribe). Zig serving layer
unit-tested; the SPA is covered by headless-browser (Playwright) tests.
Completes the 9-sub-project ZigBase roadmap.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all
```
Expected: binary builds, full Zig suite green on `main`. Then update the project-status memory: **SP9 complete → ZigBase MVP complete (all 9 sub-projects)**; note the post-MVP follow-ups (WYSIWYG editor, realtime guard perf, logs/settings UI, image thumbnails, S3 backend).

---

## Done criteria for 9b / SP9

- `zig build` + `zig build test` green on `main`; `mise exec python@3.13 -- python -m pytest tests/admin/` green (all 9a+9b flows).
- A superuser can, from `/_/`: log in; create/edit/delete collections (fields with per-type options, the five access rules, auth identity + OAuth2 providers); browse + create/edit/delete records (all field types, file upload, relations); and see the records table update live. Single binary, cookie/CSRF auth, no token in storage.
- Holistic review clean. **The full ZigBase roadmap (SP1–SP9) is complete.**

---

## Self-Review (author)

- **Spec coverage:** schema editor Fields/Rules tabs (§4 → Task 1); record drawer editor + type→control map incl. file/relation (§4,§5 → Task 2); realtime live-view via auth-refresh token (§3,§4 → Task 3); Auth/OAuth2 tab + write-only secret (§4 → Task 4); 9b headless flows (§7,§8 → Tasks 1-4); holistic review + merge (§7,§8 → Task 5).
- **Placeholder scan:** none — full JS in every step. The `AuthTab` stub in Task 1 is intentionally a one-liner replaced verbatim in Task 4 (so Task 1 compiles), not a logic gap.
- **Type consistency:** `API.createCollection/updateCollection/deleteCollection/refresh` added where first used; save payload uses key `fields` (not `schema`) per the API; `SchemaEditor`/`RecordDrawer`/`RelationPicker`/`AuthTab`/`useLiveCollection`/`control`/`fieldOptions` names consistent; `data-test` hooks match every Playwright selector across Tasks 1-4; `RecordsTable` gains `editing`/`schema`/the live hook consistently.
- **Known/accepted:** the OAuth secret placeholder is a simple "is the in-form value non-empty" hint (the API never returns the real secret); `editor` fields use a textarea (WYSIWYG is the documented post-MVP follow-up); the realtime hook makes one connection attempt and degrades silently if the WS can't auth (table still works).
