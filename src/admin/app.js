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

render(html`<${App}/>`, document.getElementById('app'));
