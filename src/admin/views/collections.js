import { html, useState, useEffect } from '/_/assets/preact.js';
import { api, API } from '/_/assets/lib/api.js';
import { useLiveCollection } from '/_/assets/lib/ui.js';
import { RichTextEditor, JsonEditor, stripTags } from '/_/assets/lib/editor.js';

export function RecordsTable({ col, collection, metadataError }) {
  const [data, setData] = useState(null);
  const [err, setErr] = useState('');
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState('');
  const [sort, setSort] = useState('');
  const [editing, setEditing] = useState(undefined); // undefined=closed, null=new, record=edit
  const schema = collection?.schema || [];
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
  const typeOf = Object.fromEntries((schema || []).map(f => [f.name, f.type]));
  return html`
    <div data-test="records-view">
      <div class="toolbar">
        <h2 style="margin:0">${col} <span class="muted" data-test="total">${data ? '· ' + data.totalItems + ' records' : ''}</span></h2>
        <div class="grow"></div>
        <input class="grow" data-test="filter" placeholder="filter e.g. status='published'" value=${filter} onInput=${e => setFilter(e.target.value)} onKeyDown=${e => { if (e.key === 'Enter') { setPage(1); load(); } }}/>
        <button class="ghost" data-test="apply-filter" onClick=${() => { setPage(1); load(); }}>Apply</button>
        <button data-test="new-record" disabled=${!collection} onClick=${() => setEditing(null)}>+ New record</button>
      </div>
      ${(err || metadataError) && html`<div class="error" data-test="records-error">${err || metadataError}</div>`}
      <table>
        <thead><tr>${columns.map(c => html`<th key=${c} onClick=${() => setSort(sort === c ? '-' + c : c)} style="cursor:pointer">${c}${sort === c ? ' ▲' : sort === '-' + c ? ' ▼' : ''}</th>`)}</tr></thead>
        <tbody data-test="rows">
          ${items.map(r => html`<tr key=${r.id} data-test="row" style="cursor:pointer" onClick=${() => setEditing(r)}>${columns.map(c => html`<td key=${c}>${fmt(ownValue(r, c), ownValue(typeOf, c))}</td>`)}</tr>`)}
        </tbody>
      </table>
      ${data && data.totalItems === 0 && html`<p class="muted" data-test="empty">No records.</p>`}
      <div class="pager">
        <button class="ghost" disabled=${page <= 1} onClick=${() => setPage(page - 1)}>‹ Prev</button>
        <span data-test="pageinfo">Page ${data ? data.page : page} / ${data ? data.totalPages || 1 : 1}</span>
        <button class="ghost" disabled=${data && page >= (data.totalPages || 1)} onClick=${() => setPage(page + 1)}>Next ›</button>
      </div>
      ${editing !== undefined && html`<${RecordDrawer} col=${col} record=${editing} onClose=${() => setEditing(undefined)} onSaved=${() => { setEditing(undefined); load(); }}/>`}
    </div>`;
}

function fmt(v, type) {
  if (v == null) return '';
  if (type === 'editor' && typeof v === 'string') { const t = stripTags(v); return t.length > 80 ? t.slice(0, 80) + '…' : t; }
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

const FIELD_TYPES = ['text','email','url','editor','date','autodate','bool','number','json','select','relation','file'];
const RULES = ['listRule','viewRule','createRule','updateRule','deleteRule'];
// F3: the ONLY allow-all sentinel. null/"" are Locked (admins only); "@public" opens a collection.
const PUBLIC_RULE = '@public';

function blankField() { return { id: '', name: '', type: 'text', required: false, unique: false, options: {} }; }

export function SchemaEditor({ name }) {
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
    if (col.type === 'auth' && !validPasswordMinimum(col.options?.auth?.minPasswordLength ?? 8)) {
      setErr('Minimum password length must be an integer from 0 to 255.');
      return;
    }
    const payload = { name: col.name, type: col.type, fields: col.name === '_superusers' ? [] : col.schema, options: col.options };
    if (col.name !== '_superusers') for (const r of RULES) payload[r] = col[r];
    try {
      const saved = isNew ? await API.createCollection(payload) : await API.updateCollection(name, payload);
      // Do a full page load of the saved collection's records view so the sidebar list refreshes.
      // location.assign() to a URL with a *new path query* forces a document reload (not just a
      // hashchange), avoiding the race between setting the hash and a separate location.reload().
      location.assign('/_/?saved=' + Date.now() + (saved.type === 'auth' ? '#/users/' + encodeURIComponent(saved.name) : '#/collections/' + encodeURIComponent(saved.name) + '/records'));
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
  // Draft names can temporarily equal a reserved name while the user types.
  // Protect only fields whose persisted identity belonged to the original schema.
  const originalSchema = (allCols.find(c => c.name === name) || {}).schema || [];
  const protectedFieldIds = new Set(originalSchema.filter(f => f.id && isSystemField(f.name, isAuth)).map(f => f.id));
  return html`
    <div data-test="schema-editor">
      <div class="toolbar">
        <h2 style="margin:0">${isNew ? 'New collection' : 'Edit ' + col.name}</h2>
        <div class="grow"></div>
        ${!isNew && isAuth && html`<a data-test="manage-users" href=${'#/users/' + encodeURIComponent(name)}>Manage users →</a>`}
        ${!isNew && !col.system && html`<button class="ghost" data-test="delete-collection" onClick=${del}>Delete</button>`}
        <button data-test="save-collection" disabled=${isAuth && !validPasswordMinimum(col.options?.auth?.minPasswordLength ?? 8)} onClick=${save}>Save</button>
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
          <input style="width:150px" data-test="field-name" placeholder="name" value=${f.name} onInput=${e => setF(i, { name: e.target.value })} disabled=${protectedFieldIds.has(f.id)}/>
          <select style="width:120px" data-test="field-type" value=${f.type} onChange=${e => setF(i, { type: e.target.value, options: {} })} disabled=${protectedFieldIds.has(f.id)}>${FIELD_TYPES.map(t => html`<option key=${t} value=${t}>${t}</option>`)}</select>
          <label class="muted"><input type="checkbox" style="width:auto" checked=${f.required} onChange=${e => setF(i, { required: e.target.checked })}/> req</label>
          <label class="muted"><input type="checkbox" style="width:auto" checked=${f.unique} onChange=${e => setF(i, { unique: e.target.checked })}/> uniq</label>
          ${fieldOptions(f, i, setOpt, allCols)}
          ${!protectedFieldIds.has(f.id) && html`<button class="ghost" data-test="del-field" onClick=${() => delField(i)}>✕</button>`}
          ${ownValue(fieldErrs, f.name) && html`<div class="error" style="flex-basis:100%">${ownValue(fieldErrs, f.name).message}</div>`}
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

// Keep the auth entries aligned with schema.authSystemFields; request-only
// credentials and legacy externalAuths must never become profile controls either.
export const AUTH_SYSTEM_FIELDS = ['email', 'username', 'passwordHash', 'tokenKey', 'verified', 'token_epoch'];
const SYSTEM_FIELDS = new Set(['id', 'created', 'updated', 'passwordHash', 'tokenKey'].map(n => n.toLowerCase()));
const AUTH_FIELD_NAMES = new Set(AUTH_SYSTEM_FIELDS.map(n => n.toLowerCase()));
const ACCOUNT_INPUT_FIELDS = new Set(['password', 'passwordConfirm', 'oldPassword', 'externalAuths']);
export function isSystemField(name, account = false) {
  return SYSTEM_FIELDS.has(name.toLowerCase()) ||
    (account === true && (AUTH_FIELD_NAMES.has(name.toLowerCase()) || ACCOUNT_INPUT_FIELDS.has(name)));
}

function fieldOptions(f, i, setOpt, allCols) {
  const o = f.options || {};
  if (f.type === 'select') return html`<input style="width:200px" data-test="opt-values" placeholder="values: a,b,c" value=${(o.values||[]).join(',')} onInput=${e => setOpt(i, { values: e.target.value.split(',').map(s=>s.trim()).filter(Boolean), maxSelect: o.maxSelect||1 })}/>`;
  if (f.type === 'relation') return html`<select style="width:160px" data-test="opt-target" value=${o.targetCollectionId||''} onChange=${e => setOpt(i, { targetCollectionId: e.target.value, maxSelect: o.maxSelect||1 })}><option value="">target…</option>${allCols.map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}</select>`;
  if (f.type === 'number') return html`<select style="width:110px" data-test="opt-mode" value=${o.mode||'float'} onChange=${e => setOpt(i, { mode: e.target.value, scale: e.target.value === 'fixed' ? o.scale : undefined })}>${['float','int','fixed'].map(m => html`<option key=${m} value=${m}>${m}</option>`)}</select>${o.mode === 'fixed' ? html`<input style="width:90px" type="number" min="1" max="8" step="1" data-test="opt-scale" placeholder="scale 1..8" value=${o.scale||''} onInput=${e => setOpt(i, { scale: /^[0-9]+$/.test(e.target.value) ? parseInt(e.target.value, 10) : undefined })}/>` : ''}`;
  if (f.type === 'file') return html`<input style="width:90px" type="number" data-test="opt-maxselect" placeholder="maxSel" value=${o.maxSelect||1} onInput=${e => setOpt(i, { maxSelect: +e.target.value || 1 })}/>`;
  return '';
}

function validPasswordMinimum(value) {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 255;
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
    <div class="field"><label for="min-pw">minPasswordLength</label><input id="min-pw" type="number" data-test="min-pw" min="0" max="255" step="1" aria-invalid=${!validPasswordMinimum(auth.minPasswordLength ?? 8)} value=${auth.minPasswordLength ?? 8} onInput=${e => setAuth({ minPasswordLength: e.target.value === '' ? '' : Number(e.target.value) })}/>
      ${!validPasswordMinimum(auth.minPasswordLength ?? 8) && html`<span class="error" data-test="min-pw-error">Minimum password length must be an integer from 0 to 255.</span>`}
    </div>
    <div class="field"><label>Two-factor authentication</label><select data-test="two-factor-policy" value=${auth.two_factor || 'disabled'} onChange=${e => setAuth({ two_factor: e.target.value })}>
      <option value="disabled">Disabled</option><option value="optional">Optional — enforced after enrollment</option><option value="required">Required for everyone</option>
    </select><small class="muted">Requires a binary built with two-factor support. Application policy can additionally require enrollment for selected users or groups.</small></div>
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

function RecordDrawer({ col, record, onClose, onSaved }) {
  const isNew = !record;
  const [vals, setVals] = useState(() => ({ ...(record || {}) }));
  const [files, setFiles] = useState({}); // field -> FileList
  const [removals, setRemovals] = useState({}); // field -> [filenames]
  const [err, setErr] = useState('');
  const [fieldErrs, setFieldErrs] = useState({});
  const [invalid, setInvalid] = useState({}); // field name -> true when unparseable
  const anyInvalid = Object.values(invalid).some(Boolean);
  const onValidity = (n, ok) => setInvalid(m => ({ ...m, [n]: !ok }));
  const [collection, setCollection] = useState(null);
  useEffect(() => {
    let active = true;
    api('GET', `/collections/${encodeURIComponent(col)}`).then(c => { if (active) setCollection(c); })
      .catch(x => { if (active) setErr(x.data?.message || 'Failed to load collection fields'); });
    return () => { active = false; };
  }, [col]);
  const editable = (collection?.schema || []).filter(f => !isSystemField(f.name, collection.type === 'auth') && f.type !== 'autodate');

  function set(name, v) { setVals({ ...vals, [name]: v }); }
  async function save() {
    setErr(''); setFieldErrs({});
    const { body, isForm } = recordBody(editable, vals, files, removals);
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
        <label for=${f.type === 'editor' ? undefined : 'record-field-'+f.name}><span id=${'record-field-'+f.name+'-label'}>${f.name}</span> <span class="muted" aria-hidden="true">(${f.type})</span></label>
        ${control(f, ownValue(vals, f.name), v => set(f.name, v), files, setFiles, removals, setRemovals, onValidity, 'record-field-'+f.name)}
        ${ownValue(fieldErrs, f.name) && html`<div class="error" data-test=${'err-'+f.name}>${ownValue(fieldErrs, f.name).message}</div>`}
      </div>`)}
      <div class="row" style="margin-top:14px">
        <button data-test="record-save" onClick=${save} disabled=${!collection || anyInvalid}>Save</button>
        ${anyInvalid && html`<span class="error" data-test="save-blocked">Fix invalid JSON to save</span>`}
        ${!isNew && html`<button class="ghost" data-test="record-delete" onClick=${del}>Delete</button>`}
      </div>
    </div>`;
}

export function ownValue(values, name) {
  return Object.prototype.hasOwnProperty.call(values, name) ? values[name] : undefined;
}

function recordValue(field, value) {
  if (field.type !== 'number') return value;
  if (value === '') return null;
  if (typeof value === 'number' && !Number.isFinite(value)) return String(value);
  if ((field.options?.mode || 'float') !== 'float') return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const number = Number(value);
    if (Number.isFinite(number)) return number;
  }
  return value;
}

function equalRecordValue(left, right) {
  if (left === right) return true;
  if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object') return false;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) && left.length === right.length &&
      left.every((value, index) => equalRecordValue(value, right[index]));
  }
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every(key =>
    Object.prototype.hasOwnProperty.call(right, key) && equalRecordValue(left[key], right[key]));
}

export function changedRecordFields(fields, values, original) {
  return fields.filter(f => !equalRecordValue(recordValue(f, ownValue(values, f.name)),
    recordValue(f, ownValue(original, f.name))));
}

function noSelectionValue(values) {
  let value = '__zigbase_no_selection__';
  while (values.includes(value)) value += '_';
  return value;
}

function selectDeclares(field, value) {
  return field.type === 'select' && (field.options?.maxSelect || 1) <= 1 && (field.options?.values || []).includes(value);
}

export function recordBody(editable, vals, files, removals) {
  const hasFiles = Object.values(files).some(fl => fl && fl.length);
  let body, isForm = false;
  if (hasFiles || Object.keys(removals).length) {
    const fd = new FormData(); isForm = true;
    for (const f of editable) {
      if (f.type === 'file') continue;
      const v = recordValue(f, ownValue(vals, f.name));
      if (v === undefined) continue;
      // A select declaring "" cannot use an empty part for a clear. The server
      // reads "null" as one, unless that is an option too and cannot be encoded.
      if (v === null && selectDeclares(f, '')) {
        if (!selectDeclares(f, 'null')) fd.append(f.name, 'null');
        continue;
      }
      // Text-like controls emit '' only for an intentional clear. Multipart
      // cannot encode their SQL null, so preserve untouched nulls by omission.
      if (v === null && ['text', 'date', 'editor', 'url', 'email'].includes(f.type)) continue;
      // Empty form fields clear nullable values; JSON scalars need their JSON
      // spelling too, so a string such as "true" never turns into a boolean.
      // Quote unnormalized float strings so multipart's broader parser cannot
      // accept a spelling that the JSON request would reject.
      const invalidFloat = f.type === 'number' && (f.options?.mode || 'float') === 'float' && typeof v === 'string';
      const encoded = v === null ? '' : f.type === 'json' || typeof v === 'object' || invalidFloat ? JSON.stringify(v) : String(v);
      fd.append(f.name, encoded);
    }
    for (const [name, fl] of Object.entries(files)) for (const file of fl) fd.append(name, file);
    for (const [name, names] of Object.entries(removals)) if (names.length) fd.append(name + '-', JSON.stringify(names));
    body = fd;
  } else {
    body = Object.create(null);
    for (const f of editable) {
      const v = recordValue(f, ownValue(vals, f.name));
      if (v !== undefined) body[f.name] = v;
    }
  }
  return { body, isForm };
}

export function control(f, value, set, files, setFiles, removals, setRemovals, onValidity, id) {
  const t = f.type, o = f.options || {};
  const labelledBy = id && id+'-label';
  if (t === 'bool') return html`<input id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} type="checkbox" style="width:auto" data-test=${'in-'+f.name} checked=${!!value} onChange=${e => set(e.target.checked)}/>`;
  if (t === 'number') return html`<input id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} type="text" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
  if (t === 'json') return html`<${JsonEditor} id=${id} labelledBy=${labelledBy} required=${f.required} value=${value} onChange=${set} onValidity=${onValidity} name=${f.name}/>`;
  if (t === 'editor') return html`<${RichTextEditor} id=${id} labelledBy=${labelledBy} required=${f.required} value=${value} onChange=${set} name=${f.name}/>`;
  if (t === 'date') return html`<input id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} type="text" placeholder="YYYY-MM-DD" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
  if (t === 'select') {
    const multiple = (o.maxSelect || 1) > 1;
    // A declared "" option needs its own value, distinct from "no selection".
    const none = selectDeclares(f, '') ? noSelectionValue(o.values) : '';
    // Preact core needs per-option selection for array-valued controls.
    return html`<select id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} data-test=${'in-'+f.name} multiple=${multiple} value=${multiple ? undefined : value ?? none}
      onChange=${e => set(multiple ? [...e.target.selectedOptions].map(o => o.value) : e.target.value === none ? null : e.target.value)}>
      ${!multiple && html`<option value=${none}>—</option>`}
      ${(o.values||[]).map(v => html`<option key=${v} value=${v} selected=${multiple ? Array.isArray(value) && value.includes(v) : undefined}>${v === '' ? '(empty)' : v}</option>`)}
    </select>`;
  }
  if (t === 'relation') return html`<${RelationPicker} id=${id} labelledBy=${labelledBy} required=${f.required} target=${o.targetCollectionId} multiple=${(o.maxSelect || 1) > 1} value=${value} onChange=${set} name=${f.name}/>`;
  if (t === 'file') {
    const existing = value == null ? [] : (Array.isArray(value) ? value : [value]).filter(Boolean);
    const removed = ownValue(removals, f.name) || [];
    return html`<div>
      ${existing.map(fn => html`<label class="muted" key=${fn} style="display:block"><input aria-label=${'Remove '+f.name+' file '+fn} type="checkbox" style="width:auto" data-test=${'rm-'+f.name} onChange=${e => setRemovals({ ...removals, [f.name]: e.target.checked ? [...removed, fn] : removed.filter(x=>x!==fn) })}/> ${fn} (remove)</label>`)}
      <input id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} type="file" multiple=${(o.maxSelect||1) > 1} data-test=${'in-'+f.name} onChange=${e => setFiles({ ...files, [f.name]: e.target.files })}/>
    </div>`;
  }
  return html`<input id=${id} aria-labelledby=${labelledBy} aria-required=${!!f.required} type="text" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}/>`;
}

function RelationPicker({ target, multiple, value, onChange, name, id, labelledBy, required }) {
  const [opts, setOpts] = useState([]);
  useEffect(() => {
    let active = true;
    setOpts([]);
    if (target) API.records(target, 'perPage=50').then(d => { if (active) setOpts(d.items); }).catch(() => {});
    return () => { active = false; };
  }, [target]);
  // The fetched page is a convenience list, not the complete relation value.
  // Keep references outside that page visible so adding an option preserves
  // them and removing one always requires an explicit selection change.
  const selectedIds = multiple ? (Array.isArray(value) ? value : []) : value ? [value] : [];
  const options = [...opts, ...selectedIds.filter(id => !opts.some(r => r.id === id)).map(id => ({ id }))];
  return html`<select id=${id} aria-labelledby=${labelledBy} aria-required=${!!required} data-test=${'in-'+name} multiple=${multiple} value=${multiple ? undefined : value ?? ''} onChange=${e => onChange(multiple ? [...e.target.selectedOptions].map(o => o.value) : e.target.value || null)}>
    ${!multiple && html`<option value="">—</option>`}${options.map(r => html`<option key=${r.id} value=${r.id} selected=${multiple ? selectedIds.includes(r.id) : undefined}>${r.id}</option>`)}</select>`;
}
