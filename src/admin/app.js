import { html, render, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';
import { go } from '/_/assets/lib/ui.js';
import { RecordsTable, SchemaEditor } from '/_/assets/views/collections.js';
import { EmailView } from '/_/assets/views/email.js';
import { FilesView } from '/_/assets/views/files.js';
import { FeaturesView } from '/_/assets/views/features.js';
import { SettingsView } from '/_/assets/views/settings.js';
import { UsersView } from '/_/assets/views/users.js';
import { LogsView } from '/_/assets/views/logs.js';

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
  if (seg[0] === 'features') return { name: 'features' };
  if (seg[0] === 'users') return { name: 'users' };
  if (seg[0] === 'email') return { name: 'email' };
  if (seg[0] === 'files') return { name: 'files' };
  if (seg[0] === 'logs') return { name: 'logs' };
  if (seg[0] === 'collections' && seg[1] && seg[2] === 'records') return { name: 'records', col: decodeURIComponent(seg[1]) };
  if (seg[0] === 'collections' && seg[1]) return { name: 'schema', col: decodeURIComponent(seg[1]) };
  return { name: 'collections' };
}

// --- login screen ---
function Login() {
  const [email, setEmail] = useState('');
  const [pw, setPw] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState(null);
  const [enrollment, setEnrollment] = useState(null);
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState(false);
  const [recoveryCodes, setRecoveryCodes] = useState(null);
  async function accepted(out) {
    if (Array.isArray(out.recoveryCodes)) { setRecoveryCodes(out.recoveryCodes); return; }
    if (!out.pendingToken) { go('#/collections'); return; }
    setPending(out);
    if (out.status === 'enrollment_required' && out.factors?.totp) {
      setEnrollment(await API.secondFactor('enroll-begin', { pendingToken: out.pendingToken, factor: 'totp' }));
    }
  }
  async function submit(e) {
    e.preventDefault();
    setErr(''); setBusy(true);
    try {
      if (pending) await accepted(await API.secondFactor(enrollment ? 'enroll-complete' : 'complete', {
        pendingToken: pending.pendingToken, factor: recovery ? 'recovery' : 'totp', code, ceremonyId: enrollment?.ceremonyId,
      }));
      else await accepted(await API.login(email, pw));
    }
    catch (x) {
      setErr((x.data && x.data.message) || 'Login failed');
      if (enrollment && pending) {
        try { setEnrollment(await API.secondFactor('enroll-begin', { pendingToken: pending.pendingToken, factor: 'totp' })); }
        catch (_) { setEnrollment(null); setPending(null); }
      }
    }
    finally { setBusy(false); }
  }
  async function webauthn() {
    setErr(''); setBusy(true);
    const decode = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
    const encode = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    try {
      const enrolling = pending.status === 'enrollment_required';
      const options = await API.secondFactor(enrolling ? 'enroll-begin' : 'initiate', { pendingToken: pending.pendingToken, factor: 'webauthn' });
      const ceremonyId = options.ceremonyId;
      delete options.ceremonyId;
      options.challenge = decode(options.challenge);
      if (options.user) options.user.id = decode(options.user.id);
      if (options.allowCredentials) options.allowCredentials = options.allowCredentials.map(c => ({ ...c, id: decode(c.id) }));
      const credential = await navigator.credentials[enrolling ? 'create' : 'get']({ publicKey: options });
      const proof = { pendingToken: pending.pendingToken, factor: 'webauthn', ceremonyId, credentialId: credential.id, clientDataJSON: encode(credential.response.clientDataJSON) };
      if (enrolling) proof.attestationObject = encode(credential.response.attestationObject);
      else { proof.authenticatorData = encode(credential.response.authenticatorData); proof.signature = encode(credential.response.signature); }
      await accepted(await API.secondFactor(enrolling ? 'enroll-complete' : 'complete', proof));
    } catch (x) { setErr(x.data?.message || x.message || 'WebAuthn verification failed'); }
    finally { setBusy(false); }
  }
  if (recoveryCodes) return html`<div class="login-wrap"><h2>Save your recovery codes</h2><p>Store these privately. Each code works once.</p><pre data-test="recovery-codes">${recoveryCodes.join('\n')}</pre><button onClick=${() => go('#/collections')}>I saved my recovery codes</button></div>`;
  return html`
    <div class="login-wrap">
      <h2>ZigBase admin</h2>
      <form onSubmit=${submit}>
        ${!pending ? html`<div class="field"><label>Email</label><input data-test="email" value=${email} onInput=${e => setEmail(e.target.value)} autofocus/></div>
        <div class="field"><label>Password</label><input data-test="password" type="password" value=${pw} onInput=${e => setPw(e.target.value)}/></div>` : html`
        <h3>${enrollment ? 'Set up an authenticator app' : 'Verify your sign-in'}</h3>
        ${enrollment && html`<p>Enter this setup key in your authenticator app:</p><code>${enrollment.secret}</code>`}
        <div class="field"><label>${recovery ? 'Recovery code' : 'Authenticator code'}</label><input data-test="second-factor-code" value=${code} onInput=${e => setCode(e.target.value)} autocomplete="one-time-code"/></div>
        ${pending.factors?.webauthn && html`<button type="button" disabled=${busy} onClick=${webauthn}>Use a security key or passkey</button>`}
        ${pending.recoveryCodes && html`<button type="button" onClick=${() => setRecovery(!recovery)}>Use ${recovery ? 'authenticator' : 'recovery'} code</button>`}`}
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
  const [backend, setBackend] = useState('');
  const [collapsed, setCollapsed] = useState(localStorage.getItem('zb_sidebar') === '1');
  // `/api/analytics/events` is comptime-gated (R2-3 lean build) — unmounted (404) unless the
  // app configures `.analytics`. Probe it once so the Logs tab (and its deep-link) only ever
  // appear when the feature actually exists, rather than showing a tab that 404s.
  const [analyticsEnabled, setAnalyticsEnabled] = useState(false);
  useEffect(() => {
    API.collections().then(setCols).catch(x => setErr((x.data && x.data.message) || 'Failed to load collections'));
    // Read-only backend badge; degrade silently if /health is unreachable.
    API.health().then(h => setBackend(h && h.backend ? h.backend : '')).catch(() => {});
    let active = true;
    API.analyticsEvents('limit=1').then(() => { if (active) setAnalyticsEnabled(true); }).catch(() => { if (active) setAnalyticsEnabled(false); });
    return () => { active = false; };
  }, []);
  function toggle() { const v = !collapsed; setCollapsed(v); localStorage.setItem('zb_sidebar', v ? '1' : '0'); }
  async function logout() { try { await API.logout(); } catch (_) {} go('#/login'); }

  const activeCol = route.col;
  return html`
    <div class="shell">
      <div class=${'sidebar' + (collapsed ? ' collapsed' : '')}>
        <div class="brand"><span class="hide-collapsed">zigbase</span>${backend ? html`<span class="badge hide-collapsed" data-test="backend-badge" title="Active database backend">${backend === 'postgres' ? 'Postgres' : 'SQLite'}</span>` : ''}<button class="ghost" data-test="sidebar-toggle" onClick=${toggle}>${collapsed ? '»' : '«'}</button></div>
        <div class="hide-collapsed muted" style="font-size:11px;text-transform:uppercase">Collections</div>
        ${cols == null ? html`<div class="muted">…</div>` :
          cols.map(c => html`<a key=${c.id} class=${'navitem' + (c.name === activeCol ? ' active' : '')} data-test=${'nav-' + c.name} href=${'#/collections/' + encodeURIComponent(c.name) + '/records'}>
            <span class="hide-collapsed">${c.name} ${c.type !== 'base' ? html`<span class="badge">(${c.type})</span>` : ''}</span>${collapsed ? c.name[0] : ''}</a>`)}
        ${err && html`<div class="error">${err}</div>`}
        <div class="spacer"></div>
        <a class=${'navitem hide-collapsed' + (route.name === 'users' ? ' active' : '')} href="#/users" data-test="nav-users">👤 Users</a>
        <a class=${'navitem hide-collapsed' + (route.name === 'email' ? ' active' : '')} href="#/email" data-test="nav-email">📧 Email</a>
        <a class=${'navitem hide-collapsed' + (route.name === 'files' ? ' active' : '')} href="#/files" data-test="nav-files">📁 Files</a>
        ${analyticsEnabled && html`<a class=${'navitem hide-collapsed' + (route.name === 'logs' ? ' active' : '')} href="#/logs" data-test="nav-logs">📊 Logs</a>`}
        <a class=${'navitem hide-collapsed' + (route.name === 'features' ? ' active' : '')} href="#/features" data-test="nav-features">🚩 Features</a>
        <a class=${'navitem hide-collapsed' + (route.name === 'settings' ? ' active' : '')} href="#/settings" data-test="nav-settings">⚙ Settings</a>
        <a class="navitem hide-collapsed" href="#/collections" data-test="nav-collections">⚙ Collections</a>
        <a class="navitem" data-test="logout" onClick=${logout} style="cursor:pointer">⎋ <span class="hide-collapsed">Logout</span></a>
      </div>
      <div class="main">
        ${route.name === 'users' ? html`<${UsersView}/>`
          : route.name === 'email' ? html`<${EmailView}/>`
          : route.name === 'files' ? html`<${FilesView}/>`
          : route.name === 'logs' && analyticsEnabled ? html`<${LogsView}/>`
          : route.name === 'features' ? html`<${FeaturesView}/>`
          : route.name === 'settings' ? html`<${SettingsView}/>`
          : route.name === 'records' ? html`<${RecordsTable} col=${route.col}/>`
          : route.name === 'schema' ? html`<${SchemaEditor} name=${route.col}/>`
          : html`<div data-test="collections-home"><h2>Collections</h2><button data-test="new-collection" onClick=${() => go('#/collections/__new__')}>+ New collection</button></div>`}
      </div>
    </div>`;
}

render(html`<${App}/>`, document.getElementById('app'));
