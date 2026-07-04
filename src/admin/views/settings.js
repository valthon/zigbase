import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

function isFlag(value) { return value === 'true' || value === 'false'; }

export function SettingsView() {
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
