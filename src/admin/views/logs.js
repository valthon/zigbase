import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

function RealtimeStrip() {
  const [s, setS] = useState(null);
  useEffect(() => {
    let active = true;
    API.realtimeStats().then(r => { if (active) setS(r); }).catch(() => { if (active) setS({}); });
    return () => { active = false; };
  }, []);
  if (s == null) return html`<div class="muted">…</div>`;
  return html`
    <div class="row" style="gap:6px;margin:6px 0" data-test="rt-strip">
      <span class="badge" data-test="rt-connections">${s.connections ?? 0} live</span>
      <span class="badge muted" data-test="rt-caps">caps: ${s.max_connections ?? 0} conns · ${s.max_subs ?? 0} subs · hwm ${s.outbound_hwm ?? 0}</span>
    </div>`;
}

export function LogsView() {
  return html`
    <div data-test="logs-view">
      <h2>Logs &amp; realtime</h2>
      <${RealtimeStrip}/>
      <${EventsLog}/>
      <${RollupsViewer}/>
    </div>`;
}

function EventsLog() {
  const [name, setName] = useState('');
  const [actor, setActor] = useState('');
  const [since, setSince] = useState('');
  const [applied, setApplied] = useState({ name: '', actor: '', since: '' });
  const [rows, setRows] = useState(null);
  const [cursor, setCursor] = useState(null);
  const [hasNext, setHasNext] = useState(false);
  const [err, setErr] = useState('');
  const [open, setOpen] = useState(null);

  function fetchPage(cur) {
    const p = new URLSearchParams({ limit: 50 });
    if (applied.name) p.set('name', applied.name);
    if (applied.actor) p.set('actor', applied.actor);
    if (applied.since) p.set('since', applied.since);
    if (cur) p.set('cursor', cur);
    return API.analyticsEvents(p.toString());
  }
  useEffect(() => {
    let active = true; setRows(null); setErr('');
    fetchPage(null)
      .then(r => { if (!active) return; setRows(r.items || []); setCursor(r.nextCursor || null); setHasNext(!!r.hasNext); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load events'); });
    return () => { active = false; };
  }, [applied]);
  function apply(e) {
    e && e.preventDefault();
    const next = { name: name.trim(), actor: actor.trim(), since: since.trim() };
    setOpen(null);
    // Guard (Phase 1–3): only reset+refetch on a REAL change — a new object ref for identical
    // values would re-run the [applied] effect and clear the list needlessly.
    if (next.name === applied.name && next.actor === applied.actor && next.since === applied.since) return;
    setApplied(next);
  }
  async function more() {
    try { const r = await fetchPage(cursor); setRows(rs => [...(rs || []), ...(r.items || [])]); setCursor(r.nextCursor || null); setHasNext(!!r.hasNext); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to load more'); }
  }
  return html`
    <div data-test="events-log" style="margin-top:12px">
      <h3>Events</h3>
      <form class="row" onSubmit=${apply} style="gap:6px;margin-bottom:8px">
        <input data-test="logs-name" placeholder="name" value=${name} onInput=${e => setName(e.target.value)}/>
        <input data-test="logs-actor" placeholder="actor" value=${actor} onInput=${e => setActor(e.target.value)}/>
        <input data-test="logs-since" placeholder="since (ISO)" value=${since} onInput=${e => setSince(e.target.value)}/>
        <button data-test="logs-apply">Apply</button>
      </form>
      ${err && html`<div class="error" data-test="events-error">${err}</div>`}
      ${rows == null ? html`<div class="muted">…</div>` : rows.length === 0 ? html`<div class="muted" data-test="events-empty">No events</div>` : html`
        <table class="records">
          <thead><tr><th>When</th><th>Name</th><th>Actor</th><th>Account</th></tr></thead>
          <tbody>
            ${rows.map(ev => html`
              <tr key=${ev.id} data-test="log-row" style="cursor:pointer" onClick=${() => setOpen(open === ev.id ? null : ev.id)}>
                <td class="muted">${(ev.occurred_at || ev.created || '').slice(0, 19)}</td>
                <td>${ev.name}</td><td class="muted">${ev.actor || ''}</td><td class="muted">${ev.account || ''}</td>
              </tr>
              ${open === ev.id ? html`<tr key=${ev.id + '-d'}><td colspan="4"><pre data-test="log-payload" style="white-space:pre-wrap;margin:0">${typeof ev.payload === 'string' ? ev.payload : JSON.stringify(ev.payload, null, 2)}</pre></td></tr>` : ''}`)}
          </tbody>
        </table>
        ${hasNext ? html`<button data-test="logs-more" onClick=${more}>Load more</button>` : ''}`}
    </div>`;
}
function RollupsViewer() {
  const [name, setName] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rows, setRows] = useState(null);
  const [state, setState] = useState('idle'); // idle | loading | ok | none | error
  async function load(e) {
    e && e.preventDefault();
    if (!name.trim()) return;
    setState('loading'); setRows(null);
    try {
      const p = new URLSearchParams();
      if (from) p.set('from', from);
      if (to) p.set('to', to);
      const r = await API.analyticsRollup(name.trim(), p.toString());
      setRows(r.items || []); setState('ok');
    } catch (x) {
      if (x.status === 404) setState('none'); else setState('error');
    }
  }
  return html`
    <div data-test="rollups-viewer" style="margin-top:16px">
      <h3>Rollups</h3>
      <form class="row" onSubmit=${load} style="gap:6px;margin-bottom:8px">
        <input data-test="rollup-name" placeholder="rollup name" value=${name} onInput=${e => setName(e.target.value)}/>
        <input data-test="rollup-from" placeholder="from" value=${from} onInput=${e => setFrom(e.target.value)}/>
        <input data-test="rollup-to" placeholder="to" value=${to} onInput=${e => setTo(e.target.value)}/>
        <button data-test="rollup-load">Load</button>
      </form>
      ${state === 'loading' ? html`<div class="muted">…</div>`
        : state === 'none' ? html`<div class="muted" data-test="rollup-none">No such rollup declared</div>`
        : state === 'error' ? html`<div class="error" data-test="rollup-error">Failed to load rollup</div>`
        : state === 'ok' ? (rows.length === 0 ? html`<div class="muted" data-test="rollup-empty">No data in range</div>` : html`
          <table class="records" data-test="rollup-table">
            <thead><tr><th>Bucket</th><th>Account</th><th>Actor</th><th>Value</th></tr></thead>
            <tbody>${rows.map((r, i) => html`<tr key=${i} data-test="rollup-row"><td class="muted">${r.bucket}</td><td class="muted">${r.account || ''}</td><td class="muted">${r.actor || ''}</td><td>${r.value}</td></tr>`)}</tbody>
          </table>`)
        : ''}
    </div>`;
}
