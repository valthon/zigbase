import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

// ── Feature Flags + Experiments Admin UI ──────────────────────────────────────
// Reads declared registry via GET /api/features (superuser only).
// Mutations go through the existing settings API:
//   flag overrides   → PUT/DELETE /api/settings/flag:<name>
//   weight overrides → PUT/DELETE /api/settings/exp:<name>:weights

export function FeaturesView() {
  const [data, setData] = useState(null); // { flags: [...], experiments: [...] }
  const [err, setErr] = useState('');
  function load() {
    setErr('');
    API.featuresList().then(setData).catch(x => setErr((x.data && x.data.message) || 'Failed to load features'));
  }
  useEffect(load, []);
  return html`
    <div data-test="features-view">
      <div class="toolbar"><h2 style="margin:0">Feature Flags &amp; Experiments</h2></div>
      ${err && html`<div class="error" data-test="features-error">${err}</div>`}
      ${data == null
        ? html`<div class="muted">Loading…</div>`
        : html`
          <${FlagsSection} flags=${data.flags} onReload=${load}/>
          <${ExperimentsSection} experiments=${data.experiments} onReload=${load}/>`}
    </div>`;
}

function FlagsSection({ flags, onReload }) {
  const [err, setErr] = useState('');
  async function setOverride(name, enabled) {
    try { await API.flagOverridePut(name, enabled ? 'true' : 'false'); setErr(''); onReload(); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to update flag'); }
  }
  async function clearOverride(name) {
    try { await API.flagOverrideDel(name); setErr(''); onReload(); }
    catch (x) { if (x.status === 404) { setErr(''); onReload(); return; } setErr((x.data && x.data.message) || 'Failed to clear override'); }
  }
  const effective = (f) => f.override !== null ? f.override === 'true' : f.default;
  return html`
    <div data-test="flags-section" style="margin-bottom:28px">
      <h3 style="margin-bottom:8px">Declared Flags</h3>
      ${err && html`<div class="error" data-test="flags-error">${err}</div>`}
      ${flags.length === 0
        ? html`<p class="muted" data-test="flags-empty">No flags declared. Add <code>.flags</code> to your <code>App(cfg)</code> to manage feature flags here.</p>`
        : html`<table>
            <thead><tr><th>Name</th><th>Default</th><th>Description</th><th>Effective</th><th>Source</th><th></th></tr></thead>
            <tbody data-test="flags-rows">
              ${flags.map(f => html`<tr key=${f.name} data-test=${'flag-row-' + f.name}>
                <td><code>${f.name}</code></td>
                <td>${f.default ? 'on' : 'off'}</td>
                <td class="muted">${f.description || '—'}</td>
                <td>
                  <label><input type="checkbox" style="width:auto"
                    data-test=${'flag-override-' + f.name}
                    checked=${effective(f)}
                    onChange=${e => setOverride(f.name, e.target.checked)}
                  /> ${effective(f) ? 'on' : 'off'}</label>
                </td>
                <td><span class="badge">${f.override !== null ? 'override' : 'default'}</span></td>
                <td>
                  ${f.override !== null && html`
                    <button class="ghost" data-test=${'flag-clear-' + f.name} onClick=${() => clearOverride(f.name)}>Use default</button>`}
                </td>
              </tr>`)}
            </tbody>
          </table>`}
    </div>`;
}

function ExperimentsSection({ experiments, onReload }) {
  return html`
    <div data-test="exps-section">
      <h3 style="margin-bottom:8px">Declared Experiments</h3>
      ${experiments.length === 0
        ? html`<p class="muted" data-test="exps-empty">No experiments declared. Add <code>.experiments</code> to your <code>App(cfg)</code> to manage A/B tests here.</p>`
        : experiments.map(e => html`<${ExperimentPanel}
            key=${e.name + '|' + (e.weight_override ?? '')}
            exp=${e} onReload=${onReload}/>`)}
    </div>`;
}

function ExperimentPanel({ exp, onReload }) {
  // Initialise editable weights from the active override (parsed JSON) or the declared weights.
  function parseOrDeclared() {
    if (exp.weight_override) {
      try { return JSON.parse(exp.weight_override); } catch (_) {}
    }
    return exp.weights.slice();
  }
  const [weights, setWeights] = useState(parseOrDeclared);
  const [err, setErr] = useState('');

  async function saveWeights() {
    try { await API.expWeightsPut(exp.name, JSON.stringify(weights)); setErr(''); onReload(); }
    catch (x) { setErr((x.data && x.data.message) || 'Failed to save weights'); }
  }
  async function resetWeights() {
    try { await API.expWeightsDel(exp.name); setErr(''); onReload(); }
    catch (x) { if (x.status === 404) { onReload(); return; } setErr((x.data && x.data.message) || 'Failed to reset'); }
  }
  const setWeight = (i, v) => { const w = weights.slice(); w[i] = v; setWeights(w); };

  return html`
    <div data-test=${'exp-panel-' + exp.name}
         style="border:1px solid var(--line);border-radius:6px;padding:14px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px">
        <b data-test=${'exp-name-' + exp.name}>${exp.name}</b>
        ${exp.description && html`<span class="muted">${exp.description}</span>`}
        ${exp.weight_override !== null && html`<span class="badge" data-test=${'exp-override-badge-' + exp.name}>override</span>`}
        ${exp.sticky && html`<span class="badge">sticky</span>`}
      </div>
      ${err && html`<div class="error" data-test=${'exp-error-' + exp.name}>${err}</div>`}
      <table>
        <thead><tr><th>Variant</th><th>Declared weight</th><th>Override weight</th></tr></thead>
        <tbody>
          ${exp.variants.map((v, i) => html`<tr key=${v} data-test=${'exp-variant-row-' + exp.name + '-' + v}>
            <td><code>${v}</code></td>
            <td class="muted">${exp.weights[i]}</td>
            <td><input type="number" min="0" max="65535" style="width:80px"
              data-test=${'weight-' + exp.name + '-' + v}
              value=${weights[i] ?? exp.weights[i]}
              onInput=${e => setWeight(i, Math.max(0, Math.min(65535, parseInt(e.target.value, 10) || 0)))}
            /></td>
          </tr>`)}
        </tbody>
      </table>
      <div class="row" style="margin-top:10px;gap:8px">
        <button data-test=${'exp-save-' + exp.name} onClick=${saveWeights}>Save weights</button>
        ${exp.weight_override !== null && html`
          <button class="ghost" data-test=${'exp-reset-' + exp.name} onClick=${resetWeights}>Reset to declared</button>`}
      </div>
    </div>`;
}
