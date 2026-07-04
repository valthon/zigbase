import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

const PER_PAGE = 30;

function UserDrawer({ col, user, onClose, onSaved }) {
  const editing = !!user;
  const [email, setEmail] = useState((user && (user.email || '')) || '');
  const [username, setUsername] = useState((user && (user.username || '')) || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  async function save(e) {
    e.preventDefault();
    setErr(''); setBusy(true);
    try {
      if (editing) {
        const body = {};
        if (password) body.password = password;      // superuser PATCH -> admin reset
        if (email && email !== user.email) body.email = email;
        if (username !== (user.username || '')) body.username = username;
        await API.updateUser(col, user.id, body);
      } else {
        const body = { email, password };
        if (username) body.username = username;
        await API.createUser(col, body);
      }
      onSaved();
    } catch (x) { setErr((x.data && x.data.message) || 'Save failed'); }
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
        <div class="field"><label>Email</label><input data-test="user-email" value=${email} onInput=${e => setEmail(e.target.value)}/></div>
        <div class="field"><label>Username</label><input data-test="user-username" value=${username} onInput=${e => setUsername(e.target.value)}/></div>
        <div class="field"><label>${editing ? 'Set new password (admin reset)' : 'Password'}</label>
          <input data-test="user-password" type="password" value=${password} onInput=${e => setPassword(e.target.value)} placeholder=${editing ? 'leave blank to keep' : ''}/></div>
        <div class="row" style="gap:8px;margin-top:8px">
          <button data-test="user-save" disabled=${busy}>${busy ? '…' : 'Save'}</button>
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

export function UsersView() {
  const [authCols, setAuthCols] = useState(null);
  const [col, setCol] = useState('');
  const [rows, setRows] = useState(null);
  const [page, setPage] = useState(1);
  const [pages, setPages] = useState(1);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [err, setErr] = useState('');
  const [editing, setEditing] = useState(null);
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    API.collections()
      .then(cs => {
        const auth = cs.filter(c => c.type === 'auth');
        setAuthCols(auth);
        if (auth.length && !col) setCol(auth.some(c => c.name === 'users') ? 'users' : auth[0].name);
      })
      .catch(x => setErr((x.data && x.data.message) || 'Failed to load collections'));
  }, []);

  function load() {
    if (!col) return;
    const params = new URLSearchParams({ page, perPage: PER_PAGE, sort: '-created' });
    // Not every auth collection opts a field into FTS5 (`?search=`), so match on the
    // built-in identity columns (always present on auth collections) via a LIKE filter.
    if (q) params.set('filter', `email~${JSON.stringify(q)} || username~${JSON.stringify(q)}`);
    API.records(col, params.toString())
      .then(r => { setRows(r.items); setPages(r.totalPages || 1); })
      .catch(x => setErr((x.data && x.data.message) || 'Failed to load users'));
  }

  useEffect(load, [col, page, q]);

  function runSearch(e) { e && e.preventDefault(); setPage(1); setQ(search.trim()); }

  return html`
    <div data-test="users-view">
      <div class="row" style="justify-content:space-between;align-items:center">
        <h2>Users</h2>
        <div class="row" style="gap:8px">
          <select data-test="users-collection" value=${col} onChange=${e => { const v = e.target.value; if (v === col) return; setCol(v); setPage(1); setRows(null); }}>
            ${(authCols || []).map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}
          </select>
          <button data-test="user-new" onClick=${() => { setEditing(null); setDrawerOpen(true); }}>+ New user</button>
        </div>
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
      <${OAuthPanel} col=${col}/>
      ${drawerOpen && html`<${UserDrawer} key=${editing ? editing.id : '__new__'} col=${col} user=${editing} onClose=${() => setDrawerOpen(false)} onSaved=${() => { setDrawerOpen(false); load(); }}/>`}
    </div>`;
}
