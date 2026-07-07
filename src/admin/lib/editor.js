// src/admin/lib/editor.js — zero-dependency admin field editors (no build step).
import { html, useState, useEffect, useLayoutEffect, useRef } from '/_/assets/preact.js';

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

// ── HTML sanitizer (the XSS boundary for editor fields) ──────────────────────
const ALLOWED = new Set(['P','BR','STRONG','B','EM','I','U','S','H1','H2','H3','UL','OL','LI','BLOCKQUOTE','CODE','PRE','A']);
const DROP    = new Set(['SCRIPT','STYLE','IMG','IFRAME','OBJECT','EMBED','LINK','META','SVG','VIDEO','AUDIO','FORM','INPUT','BUTTON']);
const RENAME  = { DIV: 'p' }; // browsers emit <div> line-breaks; normalize to <p>

export function sanitizeHtml(dirty) {
  const tpl = document.createElement('template');
  tpl.innerHTML = dirty || '';
  sanitizeNode(tpl.content);
  return tpl.innerHTML;
}

function sanitizeNode(root) {
  for (const node of Array.from(root.childNodes)) {
    if (node.nodeType === Node.TEXT_NODE) continue;
    if (node.nodeType !== Node.ELEMENT_NODE) { node.remove(); continue; } // comments etc.
    let el = node;
    // SVG/MathML foreign-content elements report a LOWERCASE tagName (e.g. `svg`,
    // `script`, `image`), so they'd never match the uppercase DROP/ALLOWED/RENAME
    // sets below and would fall through to unwrap — leaking the foreign subtree's
    // text/markup. Drop any non-HTML-namespace element (and its subtree) outright.
    if (el.namespaceURI !== 'http://www.w3.org/1999/xhtml') { el.remove(); continue; }
    const tag = el.tagName;
    if (DROP.has(tag)) { el.remove(); continue; } // drop element AND its subtree
    sanitizeNode(el); // clean descendants first
    if (!ALLOWED.has(tag)) {
      const to = RENAME[tag];
      if (to) el = renameEl(el, to);
      else { unwrap(el); continue; } // keep children, drop the wrapper
    }
    for (const attr of Array.from(el.attributes)) {
      if (el.tagName === 'A' && attr.name.toLowerCase() === 'href' && safeHref(el.getAttribute('href'))) continue;
      el.removeAttribute(attr.name);
    }
    if (el.tagName === 'A') {
      if (!el.getAttribute('href')) { unwrap(el); continue; }
      el.setAttribute('rel', 'noopener noreferrer');
    }
  }
}

function renameEl(el, name) {
  const repl = document.createElement(name);
  while (el.firstChild) repl.appendChild(el.firstChild);
  el.parentNode.replaceChild(repl, el);
  return repl;
}
function unwrap(el) {
  const p = el.parentNode; if (!p) return;
  while (el.firstChild) p.insertBefore(el.firstChild, el);
  p.removeChild(el);
}
function safeHref(href) {
  if (!href) return false;
  try {
    const u = new URL(href.trim(), window.location.origin);
    return u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'mailto:';
  } catch (_) { return false; }
}

// Move the caret to the end of a contenteditable element's content — used after
// we rewrite innerHTML in emit(), so the browser doesn't drop the selection.
function placeCaretEnd(el) {
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  if (!sel) return;
  sel.removeAllRanges();
  sel.addRange(range);
}

// Collapse rich-text HTML to a short plaintext preview for table cells.
export function stripTags(dirty) {
  const tpl = document.createElement('template');
  tpl.innerHTML = dirty || '';
  return (tpl.content.textContent || '').replace(/\s+/g, ' ').trim();
}

// ── Rich-text WYSIWYG editor (editor fields) ─────────────────────────────────
// A contenteditable surface + toolbar. Stores sanitized HTML. execCommand is
// deprecated but universally supported and the standard lean-editor mechanism.
export function RichTextEditor({ value, onChange, name }) {
  const ref = useRef(null);
  const last = useRef(''); // last HTML we emitted, to break the parent-echo loop

  // Load the stored value in (sanitized) without clobbering the caret mid-edit:
  // only write innerHTML when the incoming value differs from what we emitted.
  // useLayoutEffect (not useEffect) so this runs synchronously right after each
  // render — useEffect is deferred to a requestAnimationFrame, which lags far
  // enough behind rapid keystrokes (fast typing, IME, programmatic input) that
  // stale writes can land mid-edit and reset the caret to the start.
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const incoming = sanitizeHtml(value || '');
    if (incoming !== last.current) { el.innerHTML = incoming; last.current = incoming; }
  }, [value]);

  useEffect(() => {
    try { document.execCommand('styleWithCSS', false, false); } catch (_) {}
    try { document.execCommand('defaultParagraphSeparator', false, 'p'); } catch (_) {}
  }, []);

  function emit() {
    const el = ref.current; if (!el) return;
    const clean = sanitizeHtml(el.innerHTML);
    // Reflect the sanitized markup back into the live surface when it differs, so
    // what the user sees always equals what will be saved — e.g. content dropped
    // or command-inserted straight into the DOM that the sanitizer then strips.
    // Plain typing produces already-clean HTML, so this never fires mid-keystroke
    // (no caret churn); when it does fire, park the caret at the end so editing
    // continues sensibly.
    if (clean !== el.innerHTML) { el.innerHTML = clean; placeCaretEnd(el); }
    last.current = clean;
    onChange(clean);
  }
  function cmd(command, arg) {
    const el = ref.current; if (el) el.focus();
    document.execCommand(command, false, arg);
    emit();
  }
  function link() {
    const url = prompt('Link URL:');
    if (!url) return;
    if (!safeHref(url)) { alert('Only http(s):// and mailto: links are allowed.'); return; }
    cmd('createLink', url);
  }
  function code() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.getRangeAt(0).collapsed) return;
    const c = document.createElement('code');
    try { sel.getRangeAt(0).surroundContents(c); emit(); } catch (_) { /* crosses nodes */ }
  }
  function clear() {
    const el = ref.current; if (el) el.focus();
    document.execCommand('removeFormat');
    document.execCommand('formatBlock', false, 'p');
    emit();
  }
  function escapeText(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }
  function onPaste(e) {
    e.preventDefault();
    const cb = e.clipboardData || window.clipboardData;
    const data = cb.getData('text/html') || escapeText(cb.getData('text/plain'));
    document.execCommand('insertHTML', false, sanitizeHtml(data));
    emit();
  }

  const btn = (action, label, on, title) => html`
    <button type="button" class="rte-btn" data-test=${'rte-' + action + '-' + name} title=${title}
      onMouseDown=${e => e.preventDefault()} onClick=${on}>${label}</button>`;

  return html`
    <div class="rte-wrap">
      <div class="rte-toolbar" data-test=${'rte-toolbar-' + name}>
        ${btn('bold', html`<b>B</b>`, () => cmd('bold'), 'Bold')}
        ${btn('italic', html`<i>I</i>`, () => cmd('italic'), 'Italic')}
        ${btn('underline', html`<u>U</u>`, () => cmd('underline'), 'Underline')}
        ${btn('strike', html`<s>S</s>`, () => cmd('strikeThrough'), 'Strikethrough')}
        ${btn('h1', 'H1', () => cmd('formatBlock', 'h1'), 'Heading 1')}
        ${btn('h2', 'H2', () => cmd('formatBlock', 'h2'), 'Heading 2')}
        ${btn('h3', 'H3', () => cmd('formatBlock', 'h3'), 'Heading 3')}
        ${btn('ul', '• List', () => cmd('insertUnorderedList'), 'Bullet list')}
        ${btn('ol', '1. List', () => cmd('insertOrderedList'), 'Numbered list')}
        ${btn('quote', '❝', () => cmd('formatBlock', 'blockquote'), 'Blockquote')}
        ${btn('code', '</>', code, 'Inline code')}
        ${btn('link', '🔗', link, 'Link')}
        ${btn('clear', '⨯', clear, 'Clear formatting')}
      </div>
      <div class="rte" contenteditable="true" data-test=${'in-' + name} ref=${ref}
        data-placeholder="Rich text…" onInput=${emit} onBlur=${emit} onPaste=${onPaste}></div>
    </div>`;
}
