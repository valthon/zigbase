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
  createCollection: (payload) => api('POST', '/collections', payload),
  updateCollection: (name, payload) => api('PATCH', `/collections/${encodeURIComponent(name)}`, payload),
  deleteCollection: (name) => api('DELETE', `/collections/${encodeURIComponent(name)}`),
  refresh: () => api('POST', '/collections/_superusers/auth-refresh'),
  settingsList: () => api('GET', '/settings'),
  settingsPut: (key, value) => api('PUT', `/settings/${encodeURIComponent(key)}`, { value }),
  settingsDelete: (key) => api('DELETE', `/settings/${encodeURIComponent(key)}`),
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
  if (seg[0] === 'settings') return { name: 'settings' };
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
        <a class=${'navitem hide-collapsed' + (route.name === 'settings' ? ' active' : '')} href="#/settings" data-test="nav-settings">⚙ Settings</a>
        <a class="navitem hide-collapsed" href="#/collections" data-test="nav-collections">⚙ Collections</a>
        <a class="navitem" data-test="logout" onClick=${logout} style="cursor:pointer">⎋ <span class="hide-collapsed">Logout</span></a>
      </div>
      <div class="main">
        ${route.name === 'settings' ? html`<${SettingsView}/>`
          : route.name === 'records' ? html`<${RecordsTable} col=${route.col}/>`
          : route.name === 'schema' ? html`<${SchemaEditor} name=${route.col}/>`
          : html`<div data-test="collections-home"><h2>Collections</h2><button data-test="new-collection" onClick=${() => go('#/collections/__new__')}>+ New collection</button></div>`}
      </div>
    </div>`;
}

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

function RecordsTable({ col }) {
  const [data, setData] = useState(null);
  const [err, setErr] = useState('');
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState('');
  const [sort, setSort] = useState('');
  const [editing, setEditing] = useState(undefined); // undefined=closed, null=new, record=edit
  const [schema, setSchema] = useState([]);
  useEffect(() => { API.collections().then(cs => { const c = cs.find(x => x.name === col); setSchema(c ? c.schema : []); }); }, [col]);
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
  const items = data ? data.items : [];
  const columns = items.length ? Object.keys(items[0]).filter(k => k !== 'collectionId' && k !== 'collectionName') : ['id', 'created', 'updated'];
  return html`
    <div data-test="records-view">
      <div class="toolbar">
        <h2 style="margin:0">${col} <span class="muted" data-test="total">${data ? '· ' + data.totalItems + ' records' : ''}</span></h2>
        <div class="grow"></div>
        <input class="grow" data-test="filter" placeholder="filter e.g. status='published'" value=${filter} onInput=${e => setFilter(e.target.value)} onKeyDown=${e => { if (e.key === 'Enter') { setPage(1); load(); } }}/>
        <button class="ghost" data-test="apply-filter" onClick=${() => { setPage(1); load(); }}>Apply</button>
        <button data-test="new-record" onClick=${() => setEditing(null)}>+ New record</button>
      </div>
      ${err && html`<div class="error" data-test="records-error">${err}</div>`}
      <table>
        <thead><tr>${columns.map(c => html`<th key=${c} onClick=${() => setSort(sort === c ? '-' + c : c)} style="cursor:pointer">${c}${sort === c ? ' ▲' : sort === '-' + c ? ' ▼' : ''}</th>`)}</tr></thead>
        <tbody data-test="rows">
          ${items.map(r => html`<tr key=${r.id} data-test="row" style="cursor:pointer" onClick=${() => setEditing(r)}>${columns.map(c => html`<td key=${c}>${fmt(r[c])}</td>`)}</tr>`)}
        </tbody>
      </table>
      ${data && data.totalItems === 0 && html`<p class="muted" data-test="empty">No records.</p>`}
      <div class="pager">
        <button class="ghost" disabled=${page <= 1} onClick=${() => setPage(page - 1)}>‹ Prev</button>
        <span data-test="pageinfo">Page ${data ? data.page : page} / ${data ? data.totalPages || 1 : 1}</span>
        <button class="ghost" disabled=${data && page >= (data.totalPages || 1)} onClick=${() => setPage(page + 1)}>Next ›</button>
      </div>
      ${editing !== undefined && html`<${RecordDrawer} col=${col} record=${editing} schema=${schema} onClose=${() => setEditing(undefined)} onSaved=${() => { setEditing(undefined); load(); }}/>`}
    </div>`;
}

function fmt(v) {
  if (v == null) return '';
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

const FIELD_TYPES = ['text','email','url','editor','date','autodate','bool','number','json','select','relation','file'];
const RULES = ['listRule','viewRule','createRule','updateRule','deleteRule'];
// F3: the ONLY allow-all sentinel. null/"" are Locked (admins only); "@public" opens a collection.
const PUBLIC_RULE = '@public';

function blankField() { return { id: '', name: '', type: 'text', required: false, unique: false, options: {} }; }

function SchemaEditor({ name }) {
  const isNew = name === '__new__';
  const [tab, setTab] = useState('fields');
  const [col, setCol] = useState(null);
  const [allCols, setAllCols] = useState([]);
  const [err, setErr] = useState('');
  const [fieldErrs, setFieldErrs] = useState({});
  // Rules whose mode was explicitly switched to "Expression" but whose value is
  // still empty. Without this, an empty expression (v === '') derives back to
  // Locked and the text input never appears, making it impossible to TYPE one.
  const [exprRules, setExprRules] = useState({});
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
      // Do a full page load of the saved collection's records view so the sidebar list refreshes.
      // location.assign() to a URL with a *new path query* forces a document reload (not just a
      // hashchange), avoiding the race between setting the hash and a separate location.reload().
      location.assign('/_/?saved=' + Date.now() + '#/collections/' + encodeURIComponent(saved.name) + '/records');
    } catch (x) {
      setErr((x.data && x.data.message) || 'Save failed');
      if (x.data && x.data.data) setFieldErrs(x.data.data);
    }
  }
  async function del() {
    if (!confirm('Delete collection ' + col.name + '?')) return;
    try { await API.deleteCollection(name); location.assign('/_/?deleted=' + Date.now() + '#/collections'); }
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
        ${RULES.map(r => {
          const v = col[r];
          // Safe-by-default semantics (F3): null OR "" => Locked (admins only); the explicit
          // "@public" sentinel => PUBLIC (anyone); any other string => an expression checked
          // per record. Render the three states DISTINCTLY so a wide-open rule can never be set
          // by accident (and confirm before opening one up).
          const isPublic = v === PUBLIC_RULE;
          // An empty value is Locked — UNLESS the user explicitly picked
          // Expression for this rule (so they can type one into a blank input).
          const isLocked = (v == null || v === '') && !exprRules[r];
          const mode = isPublic ? 'public' : (isLocked ? 'locked' : 'expr');
          function onMode(e) {
            const m = e.target.value;
            if (m === 'locked') { setExprRules({ ...exprRules, [r]: false }); return setRule(r, null); }
            if (m === 'public') {
              if (!confirm('Make ' + r + ' PUBLIC?\n\nAnyone on the internet will be able to ' +
                  r.replace('Rule','') + ' records in this collection, with no authentication.')) {
                // Cancelled: force a re-render (new object ref) so the controlled <select>
                // snaps back to the prior mode instead of staying visually stuck on "PUBLIC".
                setExprRules({ ...exprRules });
                return;
              }
              setExprRules({ ...exprRules, [r]: false });
              return setRule(r, PUBLIC_RULE);
            }
            // switching to expression: keep the input visible even while empty
            setExprRules({ ...exprRules, [r]: true });
            return setRule(r, (typeof v === 'string' && v !== PUBLIC_RULE && v !== '') ? v : '');
          }
          return html`<div class="field" key=${r}>
            <label>${r} ${isPublic ? html`<span style="color:#b00;font-weight:600" data-test=${'pubtag-'+r}>— PUBLIC (anyone)</span>`
              : isLocked ? html`<span class="muted" data-test=${'locktag-'+r}>— Locked (admins only)</span>` : ''}</label>
            <div class="row">
              <select style="width:170px" data-test=${'rulemode-'+r} value=${mode} onChange=${onMode}>
                <option value="locked">Locked (admins only)</option>
                <option value="expr">Expression…</option>
                <option value="public">PUBLIC — anyone</option>
              </select>
              ${mode === 'expr' && html`<input style="flex:1" data-test=${'rule-'+r} placeholder='e.g. @request.auth.id = owner' value=${typeof v === 'string' ? v : ''} onInput=${e => setRule(r, e.target.value)}/>`}
            </div>
          </div>`;
        })}
      </div>`}

      ${tab === 'auth' && html`<${AuthTab} col=${col} setCol=${setCol}/>`}
    </div>`;
}

function isSystemField(n) { return ['id','created','updated','email','username','passwordHash','tokenKey','verified'].includes(n); }

function fieldOptions(f, i, setOpt, allCols) {
  const o = f.options || {};
  if (f.type === 'select') return html`<input style="width:200px" data-test="opt-values" placeholder="values: a,b,c" value=${(o.values||[]).join(',')} onInput=${e => setOpt(i, { values: e.target.value.split(',').map(s=>s.trim()).filter(Boolean), maxSelect: o.maxSelect||1 })}/>`;
  if (f.type === 'relation') return html`<select style="width:160px" data-test="opt-target" value=${o.targetCollectionId||''} onChange=${e => setOpt(i, { targetCollectionId: e.target.value, maxSelect: o.maxSelect||1 })}><option value="">target…</option>${allCols.map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}</select>`;
  if (f.type === 'number') return html`<select style="width:110px" data-test="opt-mode" value=${o.mode||'float'} onChange=${e => setOpt(i, { mode: e.target.value, scale: e.target.value === 'fixed' ? o.scale : undefined })}>${['float','int','fixed'].map(m => html`<option key=${m} value=${m}>${m}</option>`)}</select>${o.mode === 'fixed' ? html`<input style="width:90px" type="number" min="1" max="8" step="1" data-test="opt-scale" placeholder="scale 1..8" value=${o.scale||''} onInput=${e => setOpt(i, { scale: /^[0-9]+$/.test(e.target.value) ? parseInt(e.target.value, 10) : undefined })}/>` : ''}`;
  if (f.type === 'file') return html`<input style="width:90px" type="number" data-test="opt-maxselect" placeholder="maxSel" value=${o.maxSelect||1} onInput=${e => setOpt(i, { maxSelect: +e.target.value || 1 })}/>`;
  return '';
}

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

function isFlag(value) { return value === 'true' || value === 'false'; }

function SettingsView() {
  const [entries, setEntries] = useState(null);
  const [err, setErr] = useState('');
  const [editing, setEditing] = useState(undefined); // undefined=closed, {}=new, entry=edit

  function load() {
    setErr('');
    API.settingsList().then(setEntries).catch(x => setErr((x.data && x.data.message) || 'Failed to load settings'));
  }
  useEffect(load, []);

  async function toggle(key, cur) {
    try { await API.settingsPut(key, cur === 'true' ? 'false' : 'true'); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to update'); }
  }
  async function del(key) {
    if (!confirm('Delete setting ' + key + '?')) return;
    try { await API.settingsDelete(key); load(); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to delete'); }
  }

  return html`
    <div data-test="settings-view">
      <div class="toolbar">
        <h2 style="margin:0">Settings / Feature Flags</h2>
        <div class="grow"></div>
        <button data-test="new-setting" onClick=${() => setEditing({})}>+ New setting</button>
      </div>
      ${err && html`<div class="error" data-test="settings-error">${err}</div>`}
      <table>
        <thead><tr><th>Key</th><th>Value</th><th></th></tr></thead>
        <tbody data-test="settings-rows">
          ${(entries || []).map(e => html`<tr key=${e.key} data-test="setting-row">
            <td><code data-test="setting-key">${e.key}</code></td>
            <td data-test="setting-value">${isFlag(e.value)
              ? html`<label><input type="checkbox" style="width:auto" data-test=${'flag-' + e.key} checked=${e.value === 'true'} onChange=${() => toggle(e.key, e.value)}/> ${e.value}</label>`
              : e.value}</td>
            <td>
              <button class="ghost" data-test="edit-setting" onClick=${() => setEditing(e)}>Edit</button>
              <button class="ghost" data-test="del-setting" onClick=${() => del(e.key)}>✕</button>
            </td>
          </tr>`)}
        </tbody>
      </table>
      ${entries && entries.length === 0 && html`<p class="muted" data-test="settings-empty">No settings yet.</p>`}
      ${editing !== undefined && html`<${SettingDrawer} entry=${editing} onClose=${() => setEditing(undefined)} onSaved=${() => { setEditing(undefined); load(); }}/>`}
    </div>`;
}

function SettingDrawer({ entry, onClose, onSaved }) {
  const isNew = !entry.created;
  const [key, setKey] = useState(entry.key || '');
  const [value, setValue] = useState(entry.value || '');
  const [err, setErr] = useState('');
  async function save() {
    setErr('');
    if (!key.trim()) { setErr('Key is required.'); return; }
    try { await API.settingsPut(key.trim(), value); onSaved(); }
    catch (x) { setErr((x.data && x.data.message) || 'Save failed'); }
  }
  return html`
    <div class="drawer" data-test="setting-drawer" style="position:fixed;top:0;right:0;bottom:0;width:380px;background:var(--panel);border-left:1px solid var(--line);padding:16px;overflow:auto;box-shadow:-8px 0 30px rgba(0,0,0,.4)">
      <div class="row"><b style="flex:1">${isNew ? 'New setting' : 'Edit ' + entry.key}</b><button class="ghost" data-test="drawer-close" onClick=${onClose}>✕</button></div>
      ${err && html`<div class="error" data-test="setting-error">${err}</div>`}
      <div class="field"><label>Key</label><input data-test="setting-key-input" value=${key} onInput=${e => setKey(e.target.value)} disabled=${!isNew}/></div>
      <div class="field"><label>Value</label><input data-test="setting-value-input" value=${value} onInput=${e => setValue(e.target.value)}/></div>
      <div class="row" style="margin-top:14px"><button data-test="setting-save" onClick=${save}>Save</button></div>
    </div>`;
}

render(html`<${App}/>`, document.getElementById('app'));
