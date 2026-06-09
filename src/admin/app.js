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
