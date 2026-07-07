# Admin WYSIWYG + JSON Code Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain-`<textarea>` fallback for `editor` and `json` fields in the admin record drawer with a zero-dependency contenteditable rich-text editor (sanitized HTML) and a JSON code editor whose invalid input blocks Save.

**Architecture:** One new embedded ES module `src/admin/lib/editor.js` exports two Preact components (`RichTextEditor`, `JsonEditor`) plus a `sanitizeHtml`/`stripTags` pair. `src/admin.zig` registers it as an embedded asset (one `@embedFile` + one `mk(...)` row). `src/admin/views/collections.js` imports both and dispatches on field type; the record drawer gains a per-field validity map that disables Save while any `json` field is unparseable. No server-side change — `editor`/`json` stay TEXT columns.

**Tech Stack:** Zig 0.16 (`@embedFile` asset table), vendored Preact 10 + htm (no build step), Python/Playwright browser tests.

## Global Constraints

- **No build step for admin JS.** Edit `src/admin/*.js` directly; it is `@embedFile`-d into the binary. Rebuild the binary to see changes: `mise exec zig@0.16.0 -- zig build`.
- **Zero external/CDN dependencies.** No npm-bundled lib, no CDN `<script>`, no remote fetch. Self-contained ES modules only, importing the vendored `/_/assets/preact.js`.
- **Every interactive element carries `data-test=…`.** The `tests/admin/` suite drives these.
- **`js_ctype` is `"application/javascript"`** (the constant in `admin.zig`).
- **New `src/*.zig` tests** only run if their file is reachable from `src/root.zig`'s test block; `admin.zig` is already reachable, so its `test {}` blocks run — no root.zig change needed.
- **Docs sync is mandatory** (repo rule): every doc change to `docs/*.md` mirrors into `site/src/content/docs/*.md`; changelog changes go in `changelog.d/` fragments, never `CHANGELOG.md`.
- **Test commands:**
  - Zig unit: `mise exec zig@0.16.0 -- zig build test --summary all` (authoritative line: `Build Summary: N/N tests passed`).
  - One browser test: `mise exec python@3.13 -- python -m pytest tests/admin/test_editor.py -q`.
- Two Playwright suites exist; **`zig build test` passing does NOT mean the browser suite passes** — run `tests/admin/test_editor.py` after every change to the admin JS.

---

## File Structure

- **Create** `src/admin/lib/editor.js` — `JsonEditor` (Task 1), then `RichTextEditor` + `sanitizeHtml` + `stripTags` (Task 2).
- **Modify** `src/admin.zig` — register `/_/assets/lib/editor.js` (Task 1); add a serve assertion.
- **Modify** `src/admin/views/collections.js` — import from `editor.js`; rewrite the `editor`/`json` branch of `control()`; thread `onValidity` + `invalid` map + Save `disabled` (Task 1); editor-cell `stripTags` preview (Task 2); delete `safeJson`.
- **Modify** `src/admin/style.css` — `.code` (Task 1); `.rte*` (Task 2).
- **Create** `tests/admin/test_editor.py` — json cases (Task 1), rich-text cases (Task 2).
- **Modify** `docs/fields.md` + `site/src/content/docs/fields.md` — json section (Task 1), editor section (Task 2).
- **Modify** `KNOWN_LIMITATIONS.md`; **create** `changelog.d/admin-wysiwyg.md` (Task 2).

---

## Task 1: JSON code editor + module registration + Save-blocking

**Files:**
- Create: `src/admin/lib/editor.js`
- Modify: `src/admin.zig` (embed + `mk` row + serve test)
- Modify: `src/admin/views/collections.js` (import, `control()` json branch, RecordDrawer validity map, remove `safeJson`)
- Modify: `src/admin/style.css` (`.code`)
- Create: `tests/admin/test_editor.py` (json cases)
- Modify: `docs/fields.md` + `site/src/content/docs/fields.md` (json section)

**Interfaces:**
- Produces: `export function JsonEditor({ value, onChange, onValidity, name })` — a monospace textarea code editor. `onChange(parsedValueOrNull)` fires only when the text parses (or is empty→`null`); on a parse failure it does NOT fire (the parent keeps the last valid value). `onValidity(name, ok)` fires on every input with the current validity.
- Produces (from RecordDrawer): a per-field `invalid` map; Save is `disabled` while any entry is truthy.

- [ ] **Step 1: Create `src/admin/lib/editor.js` with `JsonEditor`**

```js
// src/admin/lib/editor.js — zero-dependency admin field editors (no build step).
import { html, useState } from '/_/assets/preact.js';

// ── JSON code editor ────────────────────────────────────────────────────────
// Monospace textarea with live validation, a Format button, and tab-to-indent.
// Invalid JSON never propagates upward (onChange only fires on valid/empty), and
// reports validity via onValidity so the record drawer can block Save.
export function JsonEditor({ value, onChange, onValidity, name }) {
  const initial = value == null
    ? ''
    : (typeof value === 'string' ? value : JSON.stringify(value, null, 2));
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
```

- [ ] **Step 2: Register the module in `src/admin.zig`**

Add the `mk(...)` row to the `assets` array (after the `lib/ui.js` row), matching the existing `@embedFile`-inline style:

```zig
    mk("/_/assets/lib/ui.js", @embedFile("admin/lib/ui.js"), js_ctype),
    mk("/_/assets/lib/editor.js", @embedFile("admin/lib/editor.js"), js_ctype),
```

- [ ] **Step 3: Add the serve test to `src/admin.zig`**

In the existing `test "serve returns assets with correct content types + nosniff"`, after the `preact.js` assertion block and before the `unknown` 404 block, add:

```zig
    var ed = http.RequestCtx{ .method = .GET, .path = "/_/assets/lib/editor.js", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("application/javascript", serve(&ed).content_type);
```

- [ ] **Step 4: Run the Zig unit suite — expect PASS**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (the new `editor.js` asset serves `application/javascript`). Note: the `failed command:` line printed by `zig build test` is spurious — trust the summary line.

- [ ] **Step 5: Wire `control()` + RecordDrawer validity in `collections.js`**

At the top of `src/admin/views/collections.js`, add the import (JsonEditor only for now):

```js
import { JsonEditor } from '/_/assets/lib/editor.js';
```

In `RecordDrawer` (function starts `function RecordDrawer({ col, record, schema, onClose, onSaved })`), after the existing `const [fieldErrs, setFieldErrs] = useState({});` line, add the validity map and its setter:

```js
  const [invalid, setInvalid] = useState({}); // field name -> true when unparseable
  const anyInvalid = Object.values(invalid).some(Boolean);
  const onValidity = (n, ok) => setInvalid(m => ({ ...m, [n]: !ok }));
```

Change the field render call (currently `${control(f, vals[f.name], v => set(f.name, v), files, setFiles, removals, setRemovals)}`) to pass `onValidity`:

```js
        ${control(f, vals[f.name], v => set(f.name, v), files, setFiles, removals, setRemovals, onValidity)}
```

Change the Save button row (currently `<button data-test="record-save" onClick=${save}>Save</button>`) to disable on invalid JSON and show a hint:

```js
        <button data-test="record-save" onClick=${save} disabled=${anyInvalid}>Save</button>
        ${anyInvalid && html`<span class="error" data-test="save-blocked">Fix invalid JSON to save</span>`}
```

In `control()` (signature `function control(f, value, set, files, setFiles, removals, setRemovals)`), add the `onValidity` param and split the old combined `editor`/`json` line. Replace:

```js
  if (t === 'editor' || t === 'json') return html`<textarea rows="4" data-test=${'in-'+f.name} value=${typeof value === 'object' ? JSON.stringify(value, null, 2) : (value ?? '')} onInput=${e => set(t === 'json' ? safeJson(e.target.value) : e.target.value)}></textarea>`;
```

with (note the new signature and the two branches — `editor` keeps its textarea until Task 2):

```js
  if (t === 'json') return html`<${JsonEditor} value=${value} onChange=${set} onValidity=${onValidity} name=${f.name}/>`;
  if (t === 'editor') return html`<textarea rows="4" data-test=${'in-'+f.name} value=${value ?? ''} onInput=${e => set(e.target.value)}></textarea>`;
```

Update the `control` signature line to:

```js
function control(f, value, set, files, setFiles, removals, setRemovals, onValidity) {
```

Delete the now-unused `safeJson` helper line: `function safeJson(s) { try { return JSON.parse(s); } catch (_) { return s; } }`.

- [ ] **Step 6: Add `.code` styling to `src/admin/style.css`**

Append:

```css
.code { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px; white-space:pre; tab-size:2; }
```

- [ ] **Step 7: Rebuild the binary**

Run: `mise exec zig@0.16.0 -- zig build`
Expected: builds `zig-out/bin/zigbase` with the new embedded JS.

- [ ] **Step 8: Write the json Playwright tests — `tests/admin/test_editor.py`**

```python
import json
from conftest import login, api_request

def setup_posts(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "posts", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "body", "type": "editor", "options": {}},
                   {"id": "", "name": "meta", "type": "json", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()

def _meta_of(page, title):
    items = api_request(page, "GET", "/api/collections/posts/records").json()["items"]
    for it in items:
        if it.get("title") == title:
            m = it.get("meta")
            return json.loads(m) if isinstance(m, str) else m
    return None

def test_invalid_json_blocks_save_then_format_and_save(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'J1')

    # invalid JSON -> error shown + Save disabled
    page.fill('[data-test=in-meta]', '{ "a": }')
    page.wait_for_selector('[data-test=json-err-meta]')
    assert page.locator('[data-test=record-save]').is_disabled()

    # Format on invalid input is a no-op: still invalid, still disabled
    page.click('[data-test=json-format-meta]')
    assert page.locator('[data-test=record-save]').is_disabled()

    # fix it -> error clears, Save enables
    page.fill('[data-test=in-meta]', '{"a":1}')
    page.wait_for_selector('[data-test=json-err-meta]', state='detached')
    assert not page.locator('[data-test=record-save]').is_disabled()

    # Format pretty-prints
    page.click('[data-test=json-format-meta]')
    assert '\n' in page.locator('[data-test=in-meta]').input_value()

    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert _meta_of(page, 'J1') == {"a": 1}
```

- [ ] **Step 9: Run the json tests — expect PASS**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_editor.py -q`
Expected: `1 passed`. (The conftest harness builds+launches the server; if you changed JS after the last `zig build`, the harness rebuilds via the `binary` fixture.)

- [ ] **Step 10: Document the json editor**

In `docs/fields.md`, find the `### json` section (search for a `json` heading near the field reference) and add a sentence: the admin record editor renders `json` fields with a monospace code editor that validates on input, offers a **Format** button, and **blocks Save while the JSON is invalid**. Mirror the identical edit into `site/src/content/docs/fields.md`.

- [ ] **Step 11: Commit**

```bash
git add src/admin/lib/editor.js src/admin.zig src/admin/views/collections.js src/admin/style.css tests/admin/test_editor.py docs/fields.md site/src/content/docs/fields.md
git commit -m "feat(admin): JSON code editor with validation that blocks Save"
```

---

## Task 2: Rich-text WYSIWYG editor + sanitizer + table preview

**Files:**
- Modify: `src/admin/lib/editor.js` (add `RichTextEditor`, `sanitizeHtml`, `stripTags`)
- Modify: `src/admin/views/collections.js` (import `RichTextEditor`; `editor` branch of `control()`; `fmt` table preview)
- Modify: `src/admin/style.css` (`.rte*`)
- Modify: `tests/admin/test_editor.py` (rich-text cases)
- Modify: `docs/fields.md` + `site/src/content/docs/fields.md` (editor section)
- Modify: `KNOWN_LIMITATIONS.md`
- Create: `changelog.d/admin-wysiwyg.md`

**Interfaces:**
- Consumes: the module and `control()` dispatch from Task 1.
- Produces: `export function RichTextEditor({ value, onChange, name })` — a contenteditable rich-text editor whose `onChange(sanitizedHtmlString)` fires on input/paste/toolbar action. `export function sanitizeHtml(dirty)` → allowlisted HTML string. `export function stripTags(html)` → collapsed plaintext.

- [ ] **Step 1: Add the sanitizer + `stripTags` to `src/admin/lib/editor.js`**

Append to `editor.js`:

```js
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

// Collapse rich-text HTML to a short plaintext preview for table cells.
export function stripTags(dirty) {
  const tpl = document.createElement('template');
  tpl.innerHTML = dirty || '';
  return (tpl.content.textContent || '').replace(/\s+/g, ' ').trim();
}
```

- [ ] **Step 2: Add `RichTextEditor` to `src/admin/lib/editor.js`**

Update the import line at the top of `editor.js` to add `useEffect` and `useRef`:

```js
import { html, useState, useEffect, useRef } from '/_/assets/preact.js';
```

Append the component:

```js
// ── Rich-text WYSIWYG editor (editor fields) ─────────────────────────────────
// A contenteditable surface + toolbar. Stores sanitized HTML. execCommand is
// deprecated but universally supported and the standard lean-editor mechanism.
export function RichTextEditor({ value, onChange, name }) {
  const ref = useRef(null);
  const last = useRef(''); // last HTML we emitted, to break the parent-echo loop

  // Load the stored value in (sanitized) without clobbering the caret mid-edit:
  // only write innerHTML when the incoming value differs from what we emitted.
  useEffect(() => {
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
    last.current = clean;
    onChange(clean);
  }
  function cmd(command, arg) {
    const el = ref.current; if (el) el.focus();
    document.execCommand(command, false, arg);
    emit();
  }
  function link() { const url = prompt('Link URL:'); if (url) cmd('createLink', url); }
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
        onInput=${emit} onBlur=${emit} onPaste=${onPaste}></div>
    </div>`;
}
```

- [ ] **Step 3: Wire the `editor` branch + table preview in `collections.js`**

Change the import added in Task 1 to include `RichTextEditor` and `stripTags`:

```js
import { RichTextEditor, JsonEditor, stripTags } from '/_/assets/lib/editor.js';
```

In `control()`, replace the temporary editor textarea line (`if (t === 'editor') return html\`<textarea rows="4" ...>...\`;`) with:

```js
  if (t === 'editor') return html`<${RichTextEditor} value=${value} onChange=${set} name=${f.name}/>`;
```

Make the records-table cell strip tags for `editor` columns. The table renders cells as `${columns.map(c => html\`<td key=${c}>${fmt(r[c])}</td>\`)}` (in `RecordsTable`). Build a type lookup from `schema` and pass it in. Just above the `<table>` return in `RecordsTable`, add:

```js
  const typeOf = Object.fromEntries((schema || []).map(f => [f.name, f.type]));
```

Change the cell map to:

```js
          ${items.map(r => html`<tr key=${r.id} data-test="row" style="cursor:pointer" onClick=${() => setEditing(r)}>${columns.map(c => html`<td key=${c}>${fmt(r[c], typeOf[c])}</td>`)}</tr>`)}
```

Update `fmt` to strip editor HTML to a truncated preview:

```js
function fmt(v, type) {
  if (v == null) return '';
  if (type === 'editor' && typeof v === 'string') { const t = stripTags(v); return t.length > 80 ? t.slice(0, 80) + '…' : t; }
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
```

- [ ] **Step 4: Add `.rte*` styling to `src/admin/style.css`**

Append:

```css
.rte-wrap { border:1px solid var(--line); border-radius:6px; overflow:hidden; background:#101014; }
.rte-toolbar { display:flex; flex-wrap:wrap; gap:2px; padding:4px; border-bottom:1px solid var(--line); background:var(--panel); }
.rte-btn { background:transparent; border:1px solid transparent; border-radius:4px; padding:3px 7px; color:var(--fg); cursor:pointer; min-width:26px; line-height:1.2; }
.rte-btn:hover { border-color:var(--line); background:#101014; }
.rte { min-height:120px; max-height:340px; overflow:auto; padding:8px 10px; outline:none; }
.rte h1,.rte h2,.rte h3 { margin:.4em 0; }
.rte blockquote { border-left:3px solid var(--line); margin:.4em 0; padding-left:10px; color:var(--muted); }
.rte code { background:#101014; padding:1px 4px; border-radius:4px; font-family:ui-monospace,monospace; }
.rte:empty:before { content:attr(data-placeholder); color:var(--muted); }
```

- [ ] **Step 5: Rebuild the binary**

Run: `mise exec zig@0.16.0 -- zig build`
Expected: builds cleanly.

- [ ] **Step 6: Add the rich-text Playwright tests to `tests/admin/test_editor.py`**

Append:

```python
def test_rich_text_round_trips_as_html(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'R1')

    body = page.locator('[data-test=in-body]')
    body.click()
    page.keyboard.type('Hello world')
    page.keyboard.press('Control+a')
    page.click('[data-test=rte-bold-body]')

    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)

    items = api_request(page, "GET", "/api/collections/posts/records").json()["items"]
    stored = next(it["body"] for it in items if it.get("title") == "R1")
    assert "Hello world" in stored
    assert ("<strong>" in stored) or ("<b>" in stored)  # execCommand emits one or the other

def test_paste_is_sanitized(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')

    page.evaluate("""() => {
      const el = document.querySelector('[data-test=in-body]');
      el.focus();
      const dt = new DataTransfer();
      dt.setData('text/html', '<img src=x onerror=alert(1)><script>alert(1)<\\/script><b>ok</b>');
      el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    }""")

    inner = page.locator('[data-test=in-body]').inner_html()
    assert 'ok' in inner
    assert '<script' not in inner.lower()
    assert 'onerror' not in inner.lower()
    assert '<img' not in inner.lower()
```

- [ ] **Step 7: Run the full editor suite — expect PASS**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_editor.py -q`
Expected: `3 passed`.

- [ ] **Step 8: Run the Zig unit suite — expect PASS (regression check)**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`.

- [ ] **Step 9: Document the editor field + clear the limitation**

In `docs/fields.md`, in the `### editor` section: describe the admin WYSIWYG (toolbar, sanitized HTML allowlist: `p, br, strong/b, em/i, u, s, h1-h3, ul, ol, li, blockquote, code, pre, a[href]`), state that **content is stored as raw HTML and consumer frontends must sanitize it on their own render**, and note the `execCommand` deprecation/degradation. Mirror into `site/src/content/docs/fields.md`.

In `KNOWN_LIMITATIONS.md`, edit the admin bullet: remove the clause "the record editor uses a plain textarea for `editor`- and `json`-type fields (no WYSIWYG rich-text editor), deferred." Keep the Logs capability-gating sentence that follows it.

- [ ] **Step 10: Add the changelog fragment**

Create `changelog.d/admin-wysiwyg.md`:

```markdown
### Features

- Admin UI: `editor` fields now use a rich-text WYSIWYG editor (bold, italic, headings, lists, links, blockquote, inline code) that stores sanitized HTML, and `json` fields use a code editor with live validation, a Format button, and Save disabled while the JSON is invalid.
```

- [ ] **Step 11: Commit**

```bash
git add src/admin/lib/editor.js src/admin/views/collections.js src/admin/style.css tests/admin/test_editor.py docs/fields.md site/src/content/docs/fields.md KNOWN_LIMITATIONS.md changelog.d/admin-wysiwyg.md
git commit -m "feat(admin): rich-text WYSIWYG editor for editor fields"
```

---

## Self-Review Notes

- **Spec coverage:** RichTextEditor (T2), JsonEditor + Save-blocking (T1), sanitizer allowlist + href vetting + paste/load/input paths (T2 step 1–2), table plaintext preview (T2 step 3), module registration + serve test (T1 step 2–4), all four Playwright behaviors (T1 step 8, T2 step 6), docs + site mirror + KNOWN_LIMITATIONS + changelog (T1 step 10, T2 step 9–10). Covered.
- **Type consistency:** `JsonEditor({value,onChange,onValidity,name})`, `RichTextEditor({value,onChange,name})`, `control(..., onValidity)`, `fmt(v, type)` are used identically everywhere they appear.
- **Zig-0.16 caution for the implementer:** `admin.zig` changes are two literal lines + one test assertion — no API surface. Do not touch `root.zig` (admin.zig is already in its test block).
- **Ordering:** Task 1's `control()` edit deliberately leaves `editor` on a plain textarea so Task 1 is independently shippable; Task 2 swaps it for `RichTextEditor`. The import line grows from `{ JsonEditor }` (T1) to `{ RichTextEditor, JsonEditor, stripTags }` (T2).
```