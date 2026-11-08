import { html, useState, useEffect } from '/_/assets/preact.js';
import { api, API } from '/_/assets/lib/api.js';
import { control, recordBody, ownValue, isSystemField, changedRecordFields } from '/_/assets/views/collections.js';

const PER_PAGE = 30;

function UserDrawer({ collection: selectedCollection, user, onClose, onSaved }) {
  const editing = !!user;
  const col = selectedCollection.name;
  const [collection, setCollection] = useState(null);
  const [vals, setVals] = useState(() => user ? { ...user } : {});
  const [files, setFiles] = useState({});
  const [removals, setRemovals] = useState({});
  const [fieldErrs, setFieldErrs] = useState({});
  const [invalid, setInvalid] = useState({});
  const anyInvalid = Object.values(invalid).some(Boolean);
  const onValidity = (name, ok) => setInvalid(m => ({ ...m, [name]: !ok }));
  const editable = (collection?.schema || []).filter(f => !isSystemField(f.name, true) && f.type !== 'autodate');
  const minPasswordLength = collection?.options?.auth?.minPasswordLength ?? 8;
  const [email, setEmail] = useState((user && (user.email || '')) || '');
  const [username, setUsername] = useState((user && (user.username || '')) || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  useEffect(() => {
    let active = true;
    api('GET', `/collections/${encodeURIComponent(col)}`).then(current => {
      if (!active) return;
      if (!editing) setVals(values => ({
        ...Object.fromEntries((current.schema || []).filter(f => f.type === 'bool').map(f => [f.name, false])),
        ...values,
      }));
      setCollection(current);
    }).catch(x => { if (active) setErr(x.data?.message || 'Failed to load collection fields'); });
    return () => { active = false; };
  }, [col]);

  async function save(e) {
    e.preventDefault();
    if (!collection || busy) return;
    setErr(''); setFieldErrs({}); setBusy(true);
    try {
      if ((!editing || password) && new TextEncoder().encode(password).length < minPasswordLength) {
        setErr('Password is too short for this collection.');
        return;
      }
      const credentials = [];
      const values = { ...vals };
      if (!editing || email !== (user.email || '')) { credentials.push({ name: 'email' }); values.email = email; }
      if (editing ? username !== (user.username || '') : username !== '') { credentials.push({ name: 'username' }); values.username = username; }
      if (!editing || password) { credentials.push({ name: 'password' }); values.password = password; }
      // PATCH only intentional profile changes, so a stale drawer cannot undo
      // concurrent API/hook writes or validate untouched legacy profile values.
      const changed = editing ? changedRecordFields(editable, vals, user) : editable;
      const { body, isForm } = recordBody([...changed, ...credentials], values, files, removals);
      if (editing) await API.updateUser(col, user.id, body, isForm);
      else await API.createUser(col, body, isForm);
      onSaved();
    } catch (x) { setErr((x.data && x.data.message) || 'Save failed'); setFieldErrs(x.data?.data || {}); }
    finally { setBusy(false); }
  }
  async function del() {
    if (!confirm('Delete this user? This cannot be undone.')) return;
    try { await API.deleteUser(col, user.id); onSaved(); onClose(); }
    catch (x) { setErr((x.data && x.data.message) || 'Delete failed'); }
  }

  return html`
    <div class="drawer" data-test="user-drawer" style="position:fixed; top:0; right:0; bottom:0; width:380px; background:var(--panel); border-left:1px solid var(--line); padding:16px; overflow:auto; box-shadow:-8px 0 30px rgba(0,0,0,.4)">
      <div class="row"><b style="flex:1">${editing ? 'Edit user' : 'New user'}</b><button class="ghost" onClick=${onClose}>✕</button></div>
      ${err && html`<div class="error" data-test="user-error">${err}</div>`}
      <form onSubmit=${save}>
        <div class="field"><label for="user-email">Email</label><input id="user-email" data-test="user-email" type="text" inputmode="email" value=${email} onInput=${e => setEmail(e.target.value)}/></div>
        <div class="field"><label for="user-username">Username</label><input id="user-username" data-test="user-username" value=${username} onInput=${e => setUsername(e.target.value)}/></div>
        <div class="field"><label for="user-password">${editing ? 'Set new password (admin reset)' : 'Password'}</label>
          <input id="user-password" data-test="user-password" type="password" required=${!editing && minPasswordLength > 0} value=${password} onInput=${e => setPassword(e.target.value)} placeholder=${editing ? 'leave blank to keep' : ''}/></div>
        ${editable.map(f => html`<div class="field" key=${f.name}>
          <label for=${f.type === 'editor' ? undefined : 'user-field-'+f.name}><span id=${'user-field-'+f.name+'-label'}>${f.name}</span> ${f.required && html`<span class="muted" aria-hidden="true">(required)</span>`} <span class="muted" aria-hidden="true">(${f.type})</span></label>
          ${control(f, ownValue(vals, f.name), v => setVals(m => ({ ...m, [f.name]: v })), files, setFiles, removals, setRemovals, onValidity, 'user-field-'+f.name)}
          ${ownValue(fieldErrs, f.name) && html`<div class="error" data-test=${'err-'+f.name}>${ownValue(fieldErrs, f.name).message}</div>`}
        </div>`)}
        ${anyInvalid && html`<div class="error" data-test="user-save-blocked">Fix invalid JSON to save</div>`}
        <div class="row" style="gap:8px;margin-top:8px">
          <button data-test="user-save" disabled=${!collection || busy || anyInvalid}>${busy ? '…' : 'Save'}</button>
          ${editing && html`<button type="button" class="ghost" data-test="user-delete" onClick=${del}>Delete</button>`}
        </div>
      </form>
    </div>`;
}

function OAuthPanel({ col }) {
  const [providers, setProviders] = useState(null);
  useEffect(() => {
    if (!col) { setProviders([]); return; }
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

export function UsersView({ collection: col = '', collections, collectionsError }) {
  const authCols = collections?.filter(c => c.type === 'auth');
  const [rows, setRows] = useState(null);
  const [page, setPage] = useState(1);
  const [pages, setPages] = useState(1);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [err, setErr] = useState('');
  const [editing, setEditing] = useState(null);
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    if (!col && authCols?.length) {
      const chosen = authCols.find(c => c.name === 'users') || authCols[0];
      location.replace('#/users/' + encodeURIComponent(chosen.name));
    }
  }, [col, collections]);
  const selected = authCols?.find(c => c.name === col);

  function load() {
    if (!selected) return;
    setErr('');
    let active = true;
    const params = new URLSearchParams({ page, perPage: PER_PAGE, sort: '-created' });
    // Not every auth collection opts a field into FTS5 (`?search=`), so match on the
    // built-in identity columns (always present on auth collections) via a LIKE filter.
    if (q) params.set('filter', `email~${JSON.stringify(q)} || username~${JSON.stringify(q)}`);
    API.records(col, params.toString())
      .then(r => { if (active) { setRows(r.items); setPages(r.totalPages || 1); } })
      .catch(x => { if (active) setErr(x.data?.message || 'Failed to load users'); });
    return () => { active = false; };
  }

  useEffect(load, [selected, page, q]);

  function runSearch(e) { e && e.preventDefault(); setPage(1); setQ(search.trim()); }

  return html`
    <div data-test="users-view">
      <div class="row" style="justify-content:space-between;align-items:center">
        <h2>Users${col ? ' / ' + col : ''}</h2>
        <div class="row" style="gap:8px">
          <select data-test="users-collection" value=${col} onChange=${e => { location.hash = '#/users/' + encodeURIComponent(e.target.value); }}>
            ${(authCols || []).map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}
          </select>
          <button data-test="user-new" disabled=${!selected} onClick=${() => { setEditing(null); setDrawerOpen(true); }}>+ New user</button>
        </div>
      </div>
      ${selected && html`<a data-test="users-settings" href=${'#/collections/' + encodeURIComponent(col)}>Fields, rules & authentication →</a>`}
      ${authCols && !authCols.length && html`<p data-test="users-empty">No auth collections. <a href="#/collections/__new__">Create a collection</a></p>`}
      ${authCols && col && !selected && html`<div class="error" data-test="users-not-found">Auth collection not found. <a href="#/collections">Collection settings</a></div>`}
      <form class="row" onSubmit=${runSearch} style="gap:6px;margin:8px 0">
        <input data-test="users-search" placeholder="Search email or username…" value=${search} onInput=${e => setSearch(e.target.value)}/>
        <button data-test="users-search-go">Search</button>
      </form>
      ${(err || collectionsError) && html`<div class="error" data-test="users-error">${err || collectionsError}</div>`}
      ${!selected ? null : rows == null ? html`<div class="muted">…</div>` : html`
        <table class="records">
          <thead><tr><th>Email / Username</th><th>Verified</th><th>Created</th></tr></thead>
          <tbody>
            ${rows.map(u => html`
              <tr key=${u.id} data-test="user-row" style="cursor:pointer" onClick=${() => { setEditing(u); setDrawerOpen(true); }}>
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
      ${selected && html`<${OAuthPanel} col=${col}/>`}
      ${drawerOpen && selected && html`<${UserDrawer} key=${editing ? editing.id : '__new__'} collection=${selected} user=${editing} onClose=${() => setDrawerOpen(false)} onSaved=${() => { setDrawerOpen(false); load(); }}/>`}
    </div>`;
}
