# ZigBase SP9 — Admin SPA Design

**Status:** Approved design (brainstorm complete). Sub-project 9 (final) of the ZigBase roadmap
(`docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md`).

**Goal:** A web admin UI for ZigBase — log in as a superuser, manage collections (schema + access
rules + auth/OAuth2 settings), and browse/edit records (all field types, file upload, relations),
with a live-updating records table — served from the single binary and talking to the existing
`/api/*` endpoints.

**Depends on:** every prior sub-project — collections/records/query (SP2/SP3), access rules (SP4),
auth + superusers + cookie/CSRF (SP5), OAuth2 provider config (SP6), realtime WS (SP7), file uploads
(SP8). No new backend features except the asset-serving layer; the SPA is a pure client of the
public API.

---

## 1. Decisions (from brainstorming)

1. **Stack: no-build Preact + htm**, vendored as a single ES module (~4 KB), hand-written `app.js`.
   No npm/node/Vite — `zig build` stays a self-contained single-binary build.
2. **Serving: embedded under `/_/`.** A new `src/admin.zig` `@embedFile`s the assets; the server
   serves the SPA at `/_/` with an `index.html` fallback for client-side routes.
3. **Auth: reuse the SP5 cookie + double-submit CSRF flow** — no JWT in `localStorage`. Admin is
   superuser-only.
4. **Realtime uses an in-memory token from `auth-refresh`** (the WS deliberately ignores cookies),
   never persisted.
5. **Scope:** core (login + collections/schema editor + records CRUD) **plus** a realtime live-view
   on the records table and an OAuth2 provider config UI. Deferred: log viewer, general settings,
   superuser-management UI beyond the CLI.

---

## 2. Architecture, build & serving

**Asset layout** (`src/admin/`, checked into the repo):
- `index.html` — loads `/_/assets/preact.js` and `/_/assets/app.js` as ES modules + `style.css`.
- `preact.js` — vendored Preact + htm (+ hooks/signals), a single file (pinned version, with a
  source comment noting origin + version). No build step.
- `app.js` — the entire SPA (hand-written; router + screens + API client).
- `style.css` — styling (dark theme; the collapsible sidebar shell).

**`src/admin.zig`:** `@embedFile`s each asset at comptime into `pub const` byte slices, and exposes
handlers. The embed makes the assets part of the binary (no disk dependency).

**Serving (`server.zig` routes):**
- `GET /_/` and `GET /_/<anything that isn't an asset>` → embedded `index.html` (so a refresh/deep
  link to a hash route still loads the app). Content-Type `text/html`.
- `GET /_/assets/app.js` → `application/javascript`; `/_/assets/preact.js` → `application/javascript`;
  `/_/assets/style.css` → `text/css`. All with `X-Content-Type-Options: nosniff`. Unknown asset → 404.
- `/api/*` is unchanged; `/_/` and `/api/` do not overlap.
- (Optional convenience: `GET /` → 302 to `/_/`. Decide in 9a; not required.)

Because the existing router matches fixed segment counts with `:param` capture, the `/_/` family is
handled as a **prefix** (the admin handler is invoked for any path under `/_/`, dispatching on the
suffix: known asset → that asset; everything else → `index.html`), not via exact-pattern routes —
`server.zig` checks the `/_/` prefix and delegates to `admin.zig`.

**Client routing (hash-based):** `#/login`, `#/collections`, `#/collections/:name` (schema editor),
`#/collections/:name/records` (records browser). Hash routing means the server only ever serves
`index.html` for `/_/...`; no server-side route table for the SPA. Unknown hash → `#/collections`
(authenticated) or `#/login` (not).

---

## 3. Auth & the API client

A small fetch wrapper inside `app.js`:
- Reads the **readable `zb_csrf` cookie** and sends it as `X-CSRF-Token` on unsafe methods
  (POST/PATCH/DELETE); the browser auto-attaches the httpOnly `zb_auth` cookie. **No token is stored
  in JS.**
- Any `401` (or `403` on a superuser-gated call) → drop to `#/login`.
- **Login** (`#/login`): POST `/api/collections/_superusers/auth-with-password` with `{identity,
  password}`; on success the cookies are set by the server → navigate to `#/collections`. Bad creds →
  inline error.
- **Logout:** POST `/api/collections/_superusers/auth-logout` (clears cookies) → `#/login`.
- The admin is **superuser-only**: all collection-management calls already require a superuser
  (SP6); a non-superuser session simply gets 403s → login.

**Realtime token (the one nuance):** the SP7 WS authenticates via an explicit `auth` message and
**ignores cookies** (CSWSH defense). So when a records table enables its live-view it: (1) POSTs
`/api/collections/_superusers/auth-refresh` (cookie-authed) which returns a fresh JWT **in the
response body**; (2) holds that token **in memory only**; (3) opens `ws://…/api/realtime`, sends
`{"action":"auth","token":…}`, then `{"action":"subscribe","topic":"<collection>"}`. On reconnect or
near token expiry, it re-refreshes. The token is never written to storage.

---

## 4. Screens

**Shell:** a collapsible left sidebar listing collections (type badge: base/auth/view) with
Settings/Superusers/Logout pinned at the bottom; the main pane shows the selected collection's
records. Sidebar collapse state persists in `localStorage` (UI-only, non-sensitive).

**Login** (`#/login`): email + password form → `auth-with-password`.

**Collections list / sidebar:** lists collections from `GET /api/collections`; "+ New collection"
opens the schema editor for a new collection.

**Schema editor** (`#/collections/:name`, full-page, tabbed):
- **Fields tab:** drag-reorder field rows; each row = name + type dropdown + per-type options +
  required/unique. Type→control map (see §5). Add/remove fields. (System fields of auth collections
  are shown read-only.)
- **API Rules tab:** the five rules (list/view/create/update/delete) — each an expression input with
  a "lock (superusers only)" toggle (`= null`) vs empty (`= public ""`) vs an expression.
- **Auth / OAuth2 tab** (auth collections only): identity fields + minPasswordLength; **OAuth2
  provider config** — enable a provider, set clientId / clientSecret / redirectURLs (saved into the
  collection's `options.auth.oauth2`; the backend encrypts the secret on save per SP8). Secrets are
  **write-only** — never returned, shown as a redacted placeholder; submitting empty leaves the
  stored secret unchanged.
- Save → POST `/api/collections` (new) or PATCH `/api/collections/:name`. Delete → DELETE with a
  confirm.

**Records browser** (`#/collections/:name/records`):
- Paginated table driven by `GET /api/collections/:col/records?page&perPage&filter&sort`; a filter
  input (the SP3 filter language) and sort control. "+ New record".
- Row click → **right-side drawer editor**: a dynamic form from the schema (§5), with file
  drop/preview, relation search-chips (querying the target collection), and `expand` for showing
  related records. Save = POST (create) / PATCH (update), **multipart** when the form has file
  inputs, JSON otherwise. Delete with confirm.
- **Live-view:** the table subscribes to the collection over the realtime WS (via the in-memory-token
  path, §3) and applies `create`/`update`/`delete` events to the visible rows (insert/replace/remove;
  delete events are id-only). If the WS can't connect, the table still works — just not live.

---

## 5. Field type → form control mapping

| Field type | Editor control | Notes |
|---|---|---|
| text / email / url | text input | required/unique flags; email/url client-validated |
| editor | textarea | rich text deferred — plain textarea for the MVP |
| number | number input | mode (float/int/fixed) + scale from schema; sent as a precise string for int/fixed |
| bool | toggle | |
| date / autodate | date(-time) input | autodate is read-only (server-set) |
| select | dropdown / multi-select | from the field's `values`; maxSelect |
| relation | search-chip picker | searches the target collection; cascade/maxSelect honored; supports expand |
| file | drop zone + preview | shows existing files with remove (the SP8 `<field>-` removal); add via multipart; maxSelect/maxSize/mimeTypes from schema |
| json | code textarea | validated as JSON before submit |

The same map drives both the records drawer editor and (for the type options) the schema editor.

---

## 6. Error handling

- API errors render the `{code,message,data}` envelope; **field-level validation errors** (the
  `data` map from SP2/SP3) highlight the offending inputs with their messages.
- `401`/`403` → `#/login`. Network failure → a retry banner; the app stays usable.
- The realtime WS degrades gracefully (no live updates, no error spam) if it can't connect/auth.
- Multipart vs JSON is chosen automatically by whether the record form has pending file inputs.

---

## 7. Testing strategy

Two layers — the Zig serving layer is unit-tested in-process, and the SPA is exercised by **automated
headless-browser end-to-end tests**:
- **The Zig serving layer is unit-tested** (`src/admin.zig` via the handler/`RequestCtx` test
  pattern): `GET /_/` returns the embedded `index.html` (Content-Type text/html); `/_/assets/app.js`
  returns the embedded bytes with `application/javascript` + `nosniff`; `/_/assets/style.css` →
  `text/css`; an unknown asset → 404; a non-asset `/_/x/y` falls back to `index.html`.
- **Automated headless-browser tests** drive a real Chromium against a running `zigbase` server,
  asserting the rendered UI + behavior. Tooling: **Python + Playwright** (the prior sub-projects'
  smokes already used Python; `pip install playwright` + `playwright install chromium`). This is a
  **test-time dependency only** — it is NOT part of `zig build`, the runtime, or the single binary;
  the build stays zero-Node. The tests live under `tests/admin/` (e.g. `test_admin.py`) and run as a
  dedicated step (the SP9 "smoke" becomes this automated suite), seeding via the `superuser create`
  CLI + the API. Coverage grows with the slices:
  - *9a flows:* load `/_/`, log in as a superuser (assert redirect to `#/collections`), see the
    collections in the sidebar, open a collection and see its records table paginate/filter; a bad
    login shows an error; an unauthenticated deep-link bounces to `#/login`.
  - *9b flows:* create a collection with several field types + access rules and see it appear;
    open the record drawer, create/edit/delete a record including a **file upload** and a
    **relation**; trigger a change via the API and assert the table updates **live**; configure an
    OAuth2 provider and confirm the secret is **redacted** after reload.
- **Holistic review** focuses on the serving layer + the client's auth/CSRF/token handling: no JWT in
  storage; CSRF header sent on writes; the realtime token held in memory only; `nosniff` on assets;
  the `/_/` routes don't leak server files (only embedded assets are served — no arbitrary path read);
  superuser-gating relied upon end-to-end.

---

## 8. Build slicing — two plans

**9a — serving layer + app shell (a working, logged-in admin that lists data):**
- `src/admin/{index.html, preact.js, app.js, style.css}` (vendored Preact; the app shell + router +
  API client + `#/login` + the collapsible sidebar + collections list + the records **table**
  (read-only, paginated/filter/sort)).
- `src/admin.zig` (`@embedFile` + handlers) + `server.zig` routes + the **unit tests** for serving.
- The **headless-browser test harness** (`tests/admin/`) + the 9a flows (login, sidebar, browse).
- Result: you can load `/_/`, log in as a superuser, see collections and browse records.

**9b — authoring + realtime (completes the admin):**
- The schema editor (Fields / API Rules / Auth+OAuth2 tabs, with the OAuth2 provider config).
- The record drawer editor (all field types, file upload, relations, validation-error surfacing).
- The realtime live-view (auth-refresh token → WS → subscribe → apply events).
- The 9b headless-browser flows (create-collection, drawer edit, file upload, relation, live update,
  OAuth config + redaction), holistic security review, then **merge SP9 → `main`**, completing the
  9-sub-project ZigBase roadmap.

---

## 9. Out of scope (deferred)

- Log / request viewer (needs a new backend log store + API).
- General settings/config UI; superuser management UI (CLI exists).
- Rich-text (WYSIWYG) editor for `editor` fields — **confirmed wanted, deferred to a post-MVP
  iteration**; the MVP renders `editor` fields as a plain textarea, and the type→control map is the
  single place a WYSIWYG control later slots in.
- View-collection (SQL view) editing UI; import/export; API-docs/preview screen.
- A JS build pipeline / framework upgrade (intentionally avoided to keep the single-binary, no-node
  build).
- i18n, theming options, mobile-optimized layout.
