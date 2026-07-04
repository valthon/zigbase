import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

function Chip({ on, label }) {
  return html`<span class="badge" style=${`background:${on ? 'var(--ok,#1a7f37)' : 'var(--line)'}`}>${on ? '✓' : '✗'} ${label}</span>`;
}

function PolicyStrip() {
  const [cfg, setCfg] = useState(null);
  useEffect(() => {
    let active = true;
    API.mailConfig().then(c => { if (active) setCfg(c); }).catch(() => { if (active) setCfg({}); });
    return () => { active = false; };
  }, []);
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

function SendersTab() {
  const [rows, setRows] = useState(null);
  const [email, setEmail] = useState('');
  const [err, setErr] = useState('');
  const [reloadTrigger, setReloadTrigger] = useState(0);
  function load() { setReloadTrigger(n => n + 1); }
  useEffect(() => {
    let active = true;
    API.senders().then(r => { if (active) setRows(r.items || []); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load senders'); });
    return () => { active = false; };
  }, [reloadTrigger]);
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
const REASONS = ['hard_bounce', 'complaint', 'unsubscribe'];
function SuppressionsTab() {
  const [rows, setRows] = useState(null);
  const [filter, setFilter] = useState('all');
  const [email, setEmail] = useState('');
  const [reason, setReason] = useState('complaint');
  const [err, setErr] = useState('');
  const [reloadTrigger, setReloadTrigger] = useState(0);
  function load() { setReloadTrigger(n => n + 1); }
  useEffect(() => {
    let active = true;
    const p = new URLSearchParams({ perPage: 100, sort: '-created' });
    if (filter !== 'all') p.set('filter', `reason=${JSON.stringify(filter)}`);
    API.suppressions(p.toString()).then(r => { if (active) setRows(r.items || []); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load'); });
    return () => { active = false; };
  }, [filter, reloadTrigger]);
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
const RCPT_STATES = ['sent', 'pending', 'failed', 'suppressed', 'invalid', 'canceled'];
function BatchProgress({ id }) {
  const [counts, setCounts] = useState(null);
  useEffect(() => {
    let active = true;
    const p = new URLSearchParams({ perPage: 500, filter: `batch=${JSON.stringify(id)}` });
    API.batchRecipients(p.toString()).then(r => {
      if (!active) return;
      const c = {}; (r.items || []).forEach(x => { c[x.status] = (c[x.status] || 0) + 1; });
      setCounts(c);
    }).catch(() => { if (active) setCounts({}); });
    return () => { active = false; };
  }, [id]);
  if (counts == null) return html`<span class="muted">…</span>`;
  return html`<span data-test="batch-progress">${RCPT_STATES.filter(s => counts[s]).map(s => `${s}: ${counts[s]}`).join('  ·  ') || 'no recipients'}</span>`;
}
function BatchesTab() {
  const [rows, setRows] = useState(null);
  const [open, setOpen] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    let active = true;
    const p = new URLSearchParams({ perPage: 50, sort: '-created' });
    API.batches(p.toString()).then(r => { if (active) setRows(r.items || []); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load batches'); });
    return () => { active = false; };
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
