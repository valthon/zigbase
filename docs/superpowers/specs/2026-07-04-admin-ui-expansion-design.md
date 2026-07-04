# ZigBase Admin UI Expansion — Design

**Goal:** Expand the embedded admin UI (`/_/`) from its current three areas
(Collections, Features, Settings) to PocketBase-class coverage by adding four
management areas — **Users & auth, Email, Files & storage, Logs & realtime** —
while preserving the zero-build, single-binary ethos. The first phase does the
enabling ES-module restructure **and** ships the first new area (Users & auth)
together; each later area is its own phase.

**Architecture:** The admin stays a no-build Preact-via-htm SPA, all assets
`@embedFile`-d into the binary. `app.js` (currently 678 lines) is decomposed
into ES modules — a thin entry, a shared component/API layer, and one module
per view — served by a generalized, ETag'd asset manifest in `src/admin.zig`.
Each area is an independently-shippable view module reusing the shared layer.

**Tech stack:** Preact 10 + hooks + htm (vendored `preact.js`, already an ES
module), native browser ES modules (no bundler, no import map needed), Zig
`@embedFile` + `src/admin.zig` static serving with CRC32 ETags, Playwright
(`tests/admin/`) for end-to-end coverage.

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler in the admin path; the
  workflow stays "edit `.js`, rebuild the binary." Every asset is
  `@embedFile`-d. No dependency may be introduced that requires bundling.
- **Preserve the module convention already in use:** modules import by absolute
  served path, e.g. `import { html, useState } from '/_/assets/preact.js'`.
- **Every served asset carries a CRC32 `ETag`** and honors `If-None-Match`
  (returns `304` on a match) — the same validation pattern the consumer
  static-asset manifest already uses.
- **`data-test=` hooks** on every interactive element; each view area gets a
  `tests/admin/test_<area>.py` Playwright file, run under `-n auto`.
- **Depth is read-mostly where writes add risk without much value** (e.g. OAuth
  provider config is comptime/env → read-only in the UI).
- Docs/site mirror stay in sync (`docs/*.md` ↔ `site/src/content/`), and the
  changelog uses `changelog.d/` fragments — per repo conventions.

---

## Current state (baseline)

`src/admin/` today:

- `index.html` — loads `app.js` as `<script type="module">`, `style.css`.
- `app.js` (678 lines) — `API` client const; `Login`, `App`, `Shell`/nav;
  `RecordsTable`, `SchemaEditor` (+ `AuthTab`, rules), `RecordDrawer`,
  `RelationPicker`; `FeaturesView` (flags + experiments); `SettingsView`.
- `preact.js` — vendored htm@3.1.1 + Preact 10 + hooks, **already an ES module**
  (`export { … html, render, useState, … }`).
- `style.css` — ~2.3 KB.

`src/admin.zig` serves a **hardcoded per-file if-chain**
(`/_/assets/app.js`, `/_/assets/preact.js`, `/_/assets/style.css`), **with no
ETag/caching**, and an `index.html` SPA fallback for any other `/_/` path.

Existing Playwright coverage (`tests/admin/`): collections, schema/rules,
records, field validation, cursor pagination, file upload, features, settings,
shell, oauth, realtime, scheduler, custom route, static files, state.

## Program decomposition

Four independently-shippable phases, built in this order. **Phase 1 carries the
foundation** (ES-module split + ETag manifest) *and* the first view area, so the
first PR ships a visible feature rather than a pure refactor. Each phase gets
**its own spec → plan → build** (with UI mockups) once its predecessor lands.

| Phase | Area | Backend (already shipped) |
|-------|------|---------------------------|
| 1 | **Foundation (ES-module split + ETag manifest) + Users & auth** | auth-2 (#195) |
| 2 | Email | email-2 (#194) |
| 3 | Files & storage | files-2 (#197) |
| 4 | Logs & realtime | analytics, realtime-2 (#198) |

---

## Foundation (delivered inside Phase 1)

The enabling restructure. Not a standalone phase — it lands in the same PR as
the Users & auth view, which is its first consumer and the thing that forces the
shared component layer to be real.

### Module layout (`src/admin/`)

```
index.html            # unchanged (still loads /_/assets/app.js as a module)
preact.js             # unchanged (vendored htm+preact ESM)
style.css             # shared conventions (may split per-view later)
app.js                # THIN: mount #app, hash router, Shell/nav shell only
lib/
  api.js              # the API client (today's `API` const), exported
  ui.js               # shared components reused by every view:
                      #   Drawer, Table, field inputs, RelationPicker,
                      #   rule editor, pagination, toasts, confirm dialog,
                      #   form helpers
views/
  collections.js      # today's RecordsTable/SchemaEditor/AuthTab/
                      #   RecordDrawer/RelationPicker, moved verbatim
  features.js         # today's FeaturesView/Flags/Experiments, moved verbatim
  settings.js         # today's SettingsView/SettingDrawer, moved verbatim
  users.js            # NEW in Phase 1 — the Users & auth view
```

Later phases add `views/email.js`, `views/files.js`, `views/logs.js`,
`views/realtime.js`.

**Imports:** absolute served paths, matching the current convention —
`import { html, useState } from '/_/assets/preact.js'`,
`import { api } from '/_/assets/lib/api.js'`,
`import { Drawer, Table } from '/_/assets/lib/ui.js'`. No import map, no
bundler: the browser resolves each module by URL against `src/admin.zig`.

### Serving: ETag'd asset manifest in `src/admin.zig`

Replace the hand-written if-chain with a comptime manifest carrying a CRC32
ETag per asset, and iterate it:

```zig
const Asset = struct {
    path: []const u8,
    bytes: []const u8,
    ctype: []const u8,
    etag: []const u8, // comptime-computed: "\"" ++ hex(crc32(bytes)) ++ "\""
};
const assets = [_]Asset{
    mkAsset("/_/assets/app.js",               @embedFile("admin/app.js"),               js),
    mkAsset("/_/assets/preact.js",            @embedFile("admin/preact.js"),            js),
    mkAsset("/_/assets/style.css",            @embedFile("admin/style.css"),            css),
    mkAsset("/_/assets/lib/api.js",           @embedFile("admin/lib/api.js"),           js),
    mkAsset("/_/assets/lib/ui.js",            @embedFile("admin/lib/ui.js"),            js),
    mkAsset("/_/assets/views/collections.js", @embedFile("admin/views/collections.js"), js),
    mkAsset("/_/assets/views/users.js",       @embedFile("admin/views/users.js"),       js),
    // … one line per module; grows by one line per new view module.
};
```

`serve()` linear-scans `assets` for an exact path match. On a match it compares
the request's `If-None-Match` against the asset's `etag`: equal → `304 Not
Modified` (no body); otherwise `200` with the bytes, content-type, `ETag`, and
the existing `nosniff` header. Any other `/_/assets/*` → 404; anything else
under `/_/` → `index.html` (SPA fallback preserved). Content-type is
`application/javascript` for `.js`, `text/css` for `.css`. The CRC32 is computed
at comptime from the embedded bytes (mirroring the consumer static-asset
manifest), so it changes automatically whenever a module's contents change and
costs nothing at runtime.

### Router & nav

`parseRoute` gains the `#/users` route in Phase 1 (and `#/email`, `#/files`,
`#/logs`, `#/realtime` as later phases land); `Shell` gains a nav item per area.
Phase 1 adds the Users item; the three existing views keep their items.

### Foundation acceptance (within Phase 1)

- The full `tests/admin/` Playwright suite passes **unchanged** for the three
  moved views (collections/schema/records/features/settings/shell) — a green
  run proves the module split is faithful, with no test edits to those files.
- New `admin.zig` unit test: every manifest path returns its correct
  content-type **and** ETag; a request with a matching `If-None-Match` →
  `304`; an unknown `/_/assets/x.js` → 404; a deep SPA path → `index.html`.
- `zig build test` green; `zig fmt --check` clean.

---

## Phase 1 — Users & auth (`views/users.js`)

Ships with the foundation above.

- Superusers and auth-collection users: list + search + create/edit/delete,
  admin password reset.
- OAuth providers: read-only list per auth collection (provider config is
  comptime/env).
- **Depth:** full CRUD on users (via the records API); admin password reset via
  a superuser `PATCH` (bypasses `oldPassword`); read-only OAuth providers.
  Impersonation is out of scope (YAGNI + security).
- **Sessions DEFERRED (decided during planning).** The shipped session API is
  self-only (`GET …/auth/sessions` returns only the caller's own sessions and
  requires `:col` to match the caller's auth collection — a superuser cannot
  enumerate another user's sessions) and only functions in
  `session_store = .table` (the default `.epoch`, incl. the standalone binary,
  has no per-device sessions). Cross-user admin session management therefore
  has no shipped endpoint; it becomes a later task that adds a superuser
  cross-user session-read endpoint first. No UI is planned against it here.
- **APIs (all shipped, verified on origin/main):** records API over auth
  collections + `_superusers` (list/create/update/delete, `search`/`filter`/
  `sort`/`page`/`perPage`); admin password set via superuser
  `PATCH …/records/:id` with a `password` field (bypasses `oldPassword`);
  `GET /api/collections/:col/auth/oauth2/providers` (per-collection, no
  secrets). No new backend needed for Phase 1.
- **Tests:** `tests/admin/test_users.py` (list/search/CRUD, admin password
  reset, OAuth-providers read) with `data-test` hooks, run under `-n auto`;
  plus the foundation acceptance above.

## Phases 2–4 — view areas (roadmap)

Each is scoped here at the level needed to sequence and estimate; the full UI
design (with mockups) is produced in that phase's own brainstorming pass.

### Phase 2 — Email (`views/email.js`)

- Sender identities: list, verification status, trigger verification, delete.
- Suppression list: view, manual add/remove.
- Bulk batches: list + progress/status (read).
- Unsubscribe events: read.
- **APIs:** senders, suppression, mail-batch collections (#194). Confirm
  read/verify endpoints in the phase plan.

### Phase 3 — Files & storage (`views/files.js`)

- Per-collection file-field browser; image preview; upload / replace / delete.
- Storage backend info (local/S3) — read.
- **APIs:** files endpoints (#197), record file fields. Bulk sync/migration is
  out of scope.

### Phase 4 — Logs & realtime (`views/logs.js`, `views/realtime.js`)

- Analytics/event log table with filters (read).
- Realtime inspector: active connections + subscribed topics (read) + send a
  test broadcast.
- **Dependency risk:** a read endpoint for *active realtime connections* may
  not exist yet — the phase plan confirms API availability first and adds a
  minimal read-only endpoint if needed. Analytics querying likewise.

---

## Cross-cutting concerns

- **Shared layer as the single source of UI:** `lib/ui.js` holds every reused
  component; `style.css` holds shared conventions. Keep both small; grow only
  as a view needs. Users & auth is first partly *because* it forces the
  table/drawer/form/confirm components to mature for reuse by Phases 2–4.
- **Testing:** one `tests/admin/test_<area>.py` per view, `data-test` hooks,
  run under `-n auto` (the suite is now parallelized, #200).
- **Risks:**
  1. *Bigger first PR.* Folding the foundation into Phase 1 means the first PR
     is a refactor **and** a new view. Mitigation: the refactor is verified
     independently by the unchanged existing suite; the new Users view has its
     own test file — the two acceptance gates stay separable even in one PR.
  2. *Many small modules → more HTTP requests on load.* Acceptable for a
     localhost admin; the ETag `304` revalidation keeps repeat loads cheap;
     concatenation is a later option if it ever matters. Do **not**
     pre-optimize into a bundler.
  3. *Later views may need new read-only backend endpoints* (realtime
     connection list, analytics query). Each phase plan confirms API
     availability before UI work — no UI is planned against a missing API.
  4. *No-build constraint is load-bearing.* Any proposed dependency that would
     require bundling is rejected at design time.
- **Out of scope (whole program):** a build step, framework migration, visual
  redesign/polish of the existing three views (separate track), user
  impersonation, log-retention configuration.

## Testing strategy (summary)

- Phase 1: existing Playwright suite unchanged (proves the refactor) + a new
  `admin.zig` manifest/ETag unit test + `tests/admin/test_users.py`.
- Phases 2–4: a new Playwright test file per area, plus any Zig unit tests for
  new backend read endpoints introduced by Phase 4.
