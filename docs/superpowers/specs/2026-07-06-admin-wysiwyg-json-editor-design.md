# Admin WYSIWYG + JSON Code Editor — Design

**Date:** 2026-07-06
**Status:** Approved (design), pending spec review
**Branch:** `feat/admin-wysiwyg`
**Clears:** the `KNOWN_LIMITATIONS.md` admin bullet — "the record editor uses a
plain textarea for `editor`- and `json`-type fields (no WYSIWYG rich-text
editor)".

## Goal

Replace the single fallback `<textarea>` at `src/admin/views/collections.js`
(the `control()` helper, currently one line handling both `editor` and `json`)
so that in the admin record drawer:

- **`editor`** fields get a real zero-dependency WYSIWYG rich-text editor that
  stores sanitized HTML.
- **`json`** fields get a real zero-dependency code editor: monospace, live
  validation, a Format button, tab-to-indent — and **invalid JSON blocks Save**.

No server-side change: `editor` and `json` remain TEXT columns. This is an
admin-UI-only feature.

## Constraints (the ethos this must respect)

- **No build step.** `src/admin/*.js` is `@embedFile`-d raw into the binary and
  served from `/_/` via the asset table in `src/admin.zig`. There is no bundler.
  New modules are added as one `@embedFile` + one `mk("/_/assets/...", ...)`
  line (7 view modules already follow this pattern).
- **Zero external/CDN dependencies.** The single binary must work offline and
  under a strict CSP. No npm-bundled library, no CDN `<script>`. Everything is
  hand-written, self-contained ES modules using the vendored Preact + htm
  already at `/_/assets/preact.js`.
- **Lean default build.** The comptime CRC32 ETag pass already flags `app.js` at
  ~42 KB (`@setEvalBranchQuota` in `admin.zig`); the new module is expected to be
  small (~350–450 LOC total across both components). Any new embedded asset that
  is large enough to matter must be accounted for in `admin.zig`'s eval quota.
- **Playwright hooks.** Every interactive element carries a `data-test=…`
  attribute; the `tests/admin/` suite drives them.
- **Docs sync.** `docs/fields.md` and its `site/src/content/` mirror, plus a
  `changelog.d/` fragment and the `KNOWN_LIMITATIONS.md` edit, land with the code.

## Architecture

One new embedded module: **`src/admin/lib/editor.js`**, exporting two Preact
components:

```js
export function RichTextEditor({ value, onChange, name })          // editor fields
export function JsonEditor({ value, onChange, onValidity, name })  // json fields
```

Registered in `src/admin.zig`:

```zig
const editor_js = @embedFile("admin/lib/editor.js"); // relative to src/admin.zig
// ...
mk("/_/assets/lib/editor.js", editor_js, js_ctype),
```

`src/admin/views/collections.js` imports both and dispatches on field type in
`control()`. `lib/` is where shared UI primitives live (`lib/ui.js`,
`lib/api.js`), so the editors belong there rather than in `views/`.

### Why `contenteditable` + `execCommand`

`document.execCommand('bold'|'italic'|'insertUnorderedList'|'formatBlock'|…)` is
formally deprecated but universally supported across current browsers and is the
standard mechanism for a lean, dependency-free rich-text editor. Re-implementing
selection/range mutation by hand would multiply the code for no user benefit.
**Accepted tradeoff, documented in `docs/fields.md`.** If a browser ever drops
it, the field degrades to editing raw HTML — no data loss, since the stored
format is plain HTML text.

## Component 1: `RichTextEditor` (editor fields)

### DOM
- A toolbar `<div data-test="rte-toolbar-{name}">` of buttons.
- A `<div contenteditable data-test="in-{name}" class="rte">` edit surface.

### Toolbar actions
Each button has `data-test="rte-{action}-{name}"`:

| Button | Action | Result tag(s) |
|--------|--------|---------------|
| Bold | `execCommand('bold')` | `<strong>` |
| Italic | `execCommand('italic')` | `<em>` |
| Underline | `execCommand('underline')` | `<u>` |
| Strikethrough | `execCommand('strikeThrough')` | `<s>` |
| H1 / H2 / H3 | `execCommand('formatBlock', 'h1'|'h2'|'h3')` | `<h1..3>` |
| Bullet list | `execCommand('insertUnorderedList')` | `<ul><li>` |
| Numbered list | `execCommand('insertOrderedList')` | `<ol><li>` |
| Blockquote | `execCommand('formatBlock', 'blockquote')` | `<blockquote>` |
| Inline code | wrap selection in `<code>` (custom; execCommand has no code) | `<code>` |
| Link | prompt for URL, `execCommand('createLink', url)` | `<a href>` |
| Clear formatting | `execCommand('removeFormat')` + unwrap block tags | plain text |

`execCommand('styleWithCSS', false)` is set once so bold/italic emit semantic
tags (`<strong>`/`<em>`) rather than inline `style=`. The `<strong>`/`<em>`
forms (not `<b>`/`<i>`) are the expected output but the sanitizer accepts both.

### Value flow (the re-render trap)
A `contenteditable` div is **uncontrolled** — you cannot re-render its innerHTML
from Preact on every keystroke without destroying the caret. Rule:

- On **mount** and when the incoming `value` prop changes to something **other
  than what the editor itself last emitted**, set `el.innerHTML = sanitize(value)`.
- On `input`, read `el.innerHTML`, sanitize, remember it as "last emitted", and
  call `onChange(sanitized)`. Do **not** write innerHTML back on input.
- Use a `useRef` for the element and a ref for "last emitted HTML" to break the
  echo loop.

### Sanitizer (the XSS boundary)
A built-in `sanitizeHtml(html)` runs on three paths: (1) `paste`
(`e.preventDefault()` then insert sanitized HTML), (2) initial load of the stored
value into the editor, (3) every `input` before `onChange`. Implementation:
parse into a detached `document.implementation.createHTMLDocument` /
`template` element, walk the tree, and:

- **Allowed tags:** `p, br, strong, b, em, i, u, s, h1, h2, h3, ul, ol, li,
  blockquote, code, pre, a`. Any other element is unwrapped (children kept) or
  dropped (for `script`/`style`, dropped entirely including children).
- **Attributes:** all stripped **except** `href` on `<a>`. `href` is accepted
  only if it parses to `http:`, `https:`, `mailto:`, or a relative path —
  `javascript:` / `data:` are rejected. Every kept `<a>` gets
  `rel="noopener noreferrer"` forced on.
- No inline `style`, no `on*` handlers, no `class`/`id`.

This protects the admin, which re-renders stored `editor` content back into a
`contenteditable`. `docs/fields.md` documents that `editor` content is raw HTML
and that **consumer frontends are responsible for sanitizing it on their own
render** — ZigBase stores it verbatim.

### Records-table preview
`fmt()` in `collections.js` (used for table cells) currently returns raw HTML
for editor cells. Add: for `editor`-type columns, strip tags to a plaintext
preview via a tiny `stripTags()` and truncate (e.g. 80 chars). `fmt()` is
type-agnostic today; the table's cell render will pass the field type so only
`editor` columns strip. (Minimal: a `stripTags` helper applied where editor
cells render.)

## Component 2: `JsonEditor` (json fields)

### DOM
- A `<textarea data-test="in-{name}" class="code">` (monospace via CSS `.code`).
- A `<button data-test="json-format-{name}">Format</button>`.
- An inline `<div class="error" data-test="json-err-{name}">Invalid JSON: …</div>`
  shown only while the current text is unparseable.

### Behavior
- Local `text` state, initialized from `JSON.stringify(value, null, 2)` (or `''`
  when `value` is `null`/`undefined`).
- On `input`: attempt `JSON.parse(text)`.
  - **Empty/whitespace-only** → valid, treated as "no value": `onChange(null)`,
    `onValidity(name, true)`, no error.
  - **Parses** → `onChange(parsed)`, `onValidity(name, true)`, clear error.
  - **Fails** → set error message from the parse exception, `onValidity(name,
    false)`, and **do not** call `onChange` (so `vals[name]` keeps the last valid
    object — a broken string is never written).
- **Format** button: pretty-prints the current text at 2-space indent if it
  parses; no-op (leaves the error visible) if it doesn't.
- **Tab key**: inserts two spaces instead of moving focus.

### Save blocking (the approved behavior change)
`RecordDrawer` gains a validity map:

```js
const [invalid, setInvalid] = useState({}); // field name -> true when unparseable
const anyInvalid = Object.values(invalid).some(Boolean);
```

- `control()` gains one param so `JsonEditor` receives
  `onValidity = (name, ok) => setInvalid(m => ({ ...m, [name]: !ok }))`.
- The Save button is `disabled=${anyInvalid}` and, when disabled, shows a hint
  (`data-test="save-blocked"`: "Fix invalid JSON to save").
- This **replaces** the old lenient `safeJson()` path, which silently stored the
  raw string on parse failure. `safeJson` is removed.

## Testing

### Playwright — `tests/admin/test_editor.py` (new)
A collection with an `editor` field and a `json` field (created via the schema
API in a fixture), then:

1. **Rich text round-trips as sanitized HTML.** Open the record drawer, type
   text into the editor surface, select-all, click Bold, Save. Reload the
   record; assert the stored value contains `<strong>` and the visible text.
2. **Paste is sanitized.** Simulate a paste of
   `<img src=x onerror=alert(1)><script>alert(1)</script><b>ok</b>` into the
   editor; assert the resulting value contains neither `<script>` nor `onerror`
   nor `<img`, but keeps `ok`.
3. **Invalid JSON blocks Save.** In the json field, type `{ "a": }`; assert the
   `json-err-*` element appears and the Save button is `disabled`. Click Format
   — still invalid, still disabled. Replace with `{ "a": 1 }`; assert error
   clears, Save enables, Save succeeds, and the reloaded record has `a == 1`.
4. **Format button pretty-prints.** Type compact valid JSON, click Format,
   assert the textarea now contains newlines/indentation.

Harness: follows `tests/admin/conftest.py` (server auto-launched with
`--insecure-cookies`), reusing existing schema-setup and login helpers. Runs
under `-n auto`.

### Zig unit — `src/admin.zig`
One assertion that `GET /_/assets/lib/editor.js` serves `text/javascript` (or the
module's `js_ctype`), mirroring the existing per-module serve tests.

## Docs & changelog (sync checklist)

- `docs/fields.md` — the `editor` field section: describe the admin WYSIWYG, the
  allowed-tag set, the "stored as raw HTML; sanitize on your own render" trust
  note, and the `execCommand` degradation note. The `json` field section: note
  the admin code editor + save-blocking validation.
- `site/src/content/docs/fields.md` (or the mirrored path) — same edit.
- `KNOWN_LIMITATIONS.md` — remove the "plain textarea for editor/json fields"
  clause from the admin bullet (leave the Logs capability-gating clause intact).
- `changelog.d/admin-wysiwyg.md` — a `### Features` entry (user-visible).

## File map

| File | Change |
|------|--------|
| `src/admin/lib/editor.js` | **Create** — `RichTextEditor` + `JsonEditor` + `sanitizeHtml`/`stripTags`. |
| `src/admin.zig` | Add `@embedFile` + `mk(...)` for `/_/assets/lib/editor.js`; add a serve test. |
| `src/admin/views/collections.js` | Import both; rewrite the `editor`/`json` branch of `control()`; thread `onValidity` + `invalid` map + Save `disabled`; editor-cell `stripTags` preview; remove `safeJson`. |
| `src/admin/style.css` | `.rte`, `.rte` toolbar, `.code` textarea styling (light/dark aware). |
| `tests/admin/test_editor.py` | **Create** — the four Playwright cases. |
| `docs/fields.md` + site mirror | Editor/json field docs. |
| `KNOWN_LIMITATIONS.md` | Drop the resolved clause. |
| `changelog.d/admin-wysiwyg.md` | **Create** — Features fragment. |

## Out of scope (deliberate)

- Syntax highlighting for the JSON editor (needs a vendored code-editor lib —
  against the lean-build ethos; monospace + validation + format is the zero-dep
  target).
- Server-side HTML sanitization of `editor` fields (the field contract is
  free-form text; the admin sanitizes its own re-render, consumers sanitize
  theirs).
- Image upload / embedding, tables, and font/color controls in the rich-text
  editor (not part of the documented `editor` field contract; can be a later
  enhancement).
- Markdown storage (rejected in brainstorming — would change what `editor`
  fields store).
