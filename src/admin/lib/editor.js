// src/admin/lib/editor.js — zero-dependency admin field editors (no build step).
import { html, useState } from '/_/assets/preact.js';

// ── JSON code editor ────────────────────────────────────────────────────────
// Monospace textarea with live validation, a Format button, and tab-to-indent.
// Invalid JSON never propagates upward (onChange only fires on valid/empty), and
// reports validity via onValidity so the record drawer can block Save.
export function JsonEditor({ value, onChange, onValidity, name }) {
  const initial = value == null ? '' : JSON.stringify(value, null, 2);
  const [text, setText] = useState(initial);
  const [error, setError] = useState('');

  function apply(next) {
    setText(next);
    const trimmed = next.trim();
    if (trimmed === '') { setError(''); onValidity(name, true); onChange(null); return; }
    try {
      const parsed = JSON.parse(trimmed);
      setError(''); onValidity(name, true); onChange(parsed);
    } catch (e) {
      setError(e.message); onValidity(name, false); // keep last valid value upstream
    }
  }

  function format() {
    try {
      const parsed = JSON.parse(text);
      const pretty = JSON.stringify(parsed, null, 2);
      setText(pretty); setError(''); onValidity(name, true); onChange(parsed);
    } catch (_) { /* invalid: leave the error visible, change nothing */ }
  }

  function onKeyDown(e) {
    if (e.key !== 'Tab') return;
    e.preventDefault();
    const ta = e.target, s = ta.selectionStart, en = ta.selectionEnd;
    const next = text.slice(0, s) + '  ' + text.slice(en);
    apply(next);
    requestAnimationFrame(() => { ta.selectionStart = ta.selectionEnd = s + 2; });
  }

  return html`
    <div>
      <textarea class="code" rows="6" spellcheck="false" data-test=${'in-' + name}
        value=${text} onInput=${e => apply(e.target.value)} onKeyDown=${onKeyDown}></textarea>
      <div class="row" style="margin-top:4px">
        <button type="button" class="ghost" data-test=${'json-format-' + name} onClick=${format}>Format</button>
        ${error && html`<span class="error" data-test=${'json-err-' + name}>Invalid JSON: ${error}</span>`}
      </div>
    </div>`;
}
