import { html, useState, useEffect } from '/_/assets/preact.js';
import { API } from '/_/assets/lib/api.js';

const IMG_EXT = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico'];
export const isImage = (name) => IMG_EXT.includes((name.split('.').pop() || '').toLowerCase());
export const fileFields = (col) => (col.schema || []).filter(f => f.type === 'file');

function StorageStrip() {
  const [cfg, setCfg] = useState(null);
  useEffect(() => {
    let active = true;
    API.filesConfig().then(c => { if (active) setCfg(c); }).catch(() => { if (active) setCfg({}); });
    return () => { active = false; };
  }, []);
  if (cfg == null) return html`<div class="muted">…</div>`;
  const label = cfg.backend === 's3' ? `S3 · ${cfg.bucket || ''} ${cfg.region || ''}` : `Local disk · ${cfg.dir || 'storage'}`;
  return html`<div class="row" style="margin:6px 0"><span class="badge" data-test="storage-backend">${label}</span></div>`;
}

export function FilesView() {
  const [cols, setCols] = useState(null);
  const [col, setCol] = useState('');
  const [err, setErr] = useState('');
  useEffect(() => {
    let active = true;
    API.collections()
      .then(cs => { if (!active) return; const withFiles = cs.filter(c => fileFields(c).length > 0); setCols(withFiles);
        if (withFiles.length && !col) setCol(withFiles[0].name); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load collections'); });
    return () => { active = false; };
  }, []);
  const active = (cols || []).find(c => c.name === col);
  return html`
    <div data-test="files-view">
      <h2>Files</h2>
      <${StorageStrip}/>
      ${err && html`<div class="error" data-test="files-error">${err}</div>`}
      ${cols == null ? html`<div class="muted">…</div>` : cols.length === 0 ? html`<div class="muted" data-test="files-none">No collections have file fields</div>` : html`
        <div class="row" style="gap:8px">
          <label class="muted">Collection</label>
          <select data-test="files-collection" value=${col} onChange=${e => { const v = e.target.value; if (v !== col) setCol(v); }}>
            ${cols.map(c => html`<option key=${c.id} value=${c.name}>${c.name}</option>`)}
          </select>
        </div>
        <${RecordsBrowser} col=${col} fields=${active ? fileFields(active) : []}/>`}
    </div>`;
}

function filesOf(rec, field) {
  const v = rec[field.name];
  if (!v) return [];
  return Array.isArray(v) ? v : [v];
}
function fileUrl(col, id, name, dl) {
  return `/api/files/${encodeURIComponent(col)}/${encodeURIComponent(id)}/${encodeURIComponent(name)}${dl ? '?download' : ''}`;
}
function FileThumb({ col, id, name }) {
  return isImage(name)
    ? html`<img data-test="file-thumb" src=${fileUrl(col, id, name)} alt=${name} style="height:40px;width:40px;object-fit:cover;border:1px solid var(--line);border-radius:4px"/>`
    : html`<a data-test="file-download" href=${fileUrl(col, id, name, true)} onClick=${e => e.stopPropagation()}>${name}</a>`;
}
function RecordsBrowser({ col, fields }) {
  const [rows, setRows] = useState(null);
  const [open, setOpen] = useState(null);
  const [err, setErr] = useState('');
  const [reload, setReload] = useState(0);
  const doReload = () => setReload(n => n + 1);
  useEffect(() => {
    if (!col) return;
    let active = true; setRows(null);
    API.records(col, new URLSearchParams({ page: 1, perPage: 50, sort: '-created' }).toString())
      .then(r => { if (active) setRows(r.items); })
      .catch(x => { if (active) setErr((x.data && x.data.message) || 'Failed to load records'); });
    return () => { active = false; };
  }, [col, reload]);
  if (err) return html`<div class="error" data-test="files-error">${err}</div>`;
  if (rows == null) return html`<div class="muted">…</div>`;
  return html`
    <table class="records" data-test="files-records">
      <thead><tr><th>Record</th>${fields.map(f => html`<th key=${f.name}>${f.name}</th>`)}</tr></thead>
      <tbody>
        ${rows.map(rec => html`
          <tr key=${rec.id} data-test="file-record-row" style="cursor:pointer" onClick=${() => setOpen(rec.id)}>
            <td class="muted">${(rec.id || '').slice(0, 8)}</td>
            ${fields.map(f => html`<td key=${f.name} class="row" style="gap:4px">
              ${filesOf(rec, f).map(n => html`<${FileThumb} key=${n} col=${col} id=${rec.id} name=${n}/>`)}
              ${filesOf(rec, f).length === 0 ? html`<span class="muted">—</span>` : ''}
            </td>`)}
          </tr>`)}
      </tbody>
    </table>
    ${open && html`<${FileDrawer} key=${open} col=${col} fields=${fields} rec=${rows.find(r => r.id === open)} onClose=${() => setOpen(null)} onChanged=${doReload}/>`}`;
}

function FileDrawer({ col, fields, rec, onClose, onChanged }) {
  if (!rec) return null;
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function upload(field, input) {
    const file = input.files && input.files[0];
    if (!file) return;
    setBusy(true); setErr('');
    try {
      const fd = new FormData();
      fd.append(field.name, file);
      await API.uploadFile(col, rec.id, fd);
      onChanged();
    } catch (x) { setErr((x.data && x.data.message) || 'Upload failed'); }
    finally { setBusy(false); input.value = ''; }
  }
  async function remove(field, name) {
    if (!confirm(`Remove ${name}?`)) return;
    setBusy(true); setErr('');
    try {
      // Probed against src/files/plan.zig: the '<field>-' control key carries the
      // removal (a verbatim filename, or JSON-array text for multiple). For a
      // single-select field it clears the field outright (planFileField ignores
      // the removal names for maxSelect==1); for a multi-select field it drops
      // only the named entry from the stored array. See task-4-report.md.
      const fd = new FormData();
      fd.append(field.name + '-', name);
      await API.uploadFile(col, rec.id, fd);
      onChanged();
    } catch (x) { setErr((x.data && x.data.message) || 'Remove failed'); }
    finally { setBusy(false); }
  }
  return html`
    <div class="drawer" data-test="file-drawer" style="position:fixed;top:0;right:0;bottom:0;width:420px;background:var(--panel);border-left:1px solid var(--line);padding:16px;overflow:auto">
      <div class="row"><b style="flex:1">Files · ${(rec.id || '').slice(0, 8)}</b><button class="ghost" onClick=${onClose}>✕</button></div>
      ${err && html`<div class="error" data-test="file-error">${err}</div>`}
      ${fields.map(field => html`
        <div key=${field.name} class="field">
          <label>${field.name} ${field.options && field.options.maxSelect > 1 ? html`<span class="badge">multi</span>` : ''}</label>
          <div class="row" style="gap:6px;flex-wrap:wrap">
            ${filesOf(rec, field).map(n => html`
              <span key=${n} class="row" style="gap:2px;align-items:center">
                <${FileThumb} col=${col} id=${rec.id} name=${n}/>
                <button class="ghost" data-test="file-remove" disabled=${busy} onClick=${() => remove(field, n)}>✕</button>
              </span>`)}
          </div>
          <input type="file" data-test="file-upload" disabled=${busy} onChange=${e => upload(field, e.target)}/>
        </div>`)}
    </div>`;
}
