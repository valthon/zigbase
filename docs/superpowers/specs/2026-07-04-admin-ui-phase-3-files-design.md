# Admin UI Phase 3 — Files & storage view — Design

**Goal:** Add a **Files & storage** admin view (`/_/#/files`) — browse per-collection
file fields with image previews, upload/replace files, remove files, and a read-only
storage-backend strip. Third of the four admin areas, after merged Phases 1 (Users)
and 2 (Email).

**Architecture:** A new `src/admin/views/files.js` ES module on the Phase-1/2
foundation (browser-native ES modules, no build step; one new `src/admin.zig`
manifest row; `#/files` route + nav item; email/file helpers on `lib/api.js`). It
composes existing superuser REST APIs; the only new server code is one tiny read
endpoint `GET /api/files/config` for the storage strip (non-secret backend info).

**Tech stack:** Preact 10 + htm (vendored `preact.js`), the Phase-1/2 admin modules,
the existing `api()` client's multipart (`isForm`) path + browser `FormData`,
Playwright (`tests/admin/`, `-n auto`). One new Zig handler (`src/api/files_config.zig`)
+ route.

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild; every
  asset `@embedFile`-d; modules import by absolute `/_/assets/...` path.
- **Superuser-only.** File writes/reads use the admin `zb_auth`+`zb_csrf` cookie
  session (superuser bypasses `viewRule`/write rules); `GET /api/files/config` returns
  403 to non-superusers.
- **No secrets in the UI.** The storage strip shows the backend + non-secret operational
  config only — NEVER the S3 access key id / secret access key.
- **Same-origin cookie preview.** Image previews use `<img src="/api/files/:col/:rec/:name">`
  — a same-origin GET carries the `zb_auth` cookie automatically (no CSRF on GET,
  superuser bypasses `viewRule`), so no `?token=` is needed. Non-image files render as a
  download link (`?download`).
- **Reload-race + unmount/stale-response guards** (Phases 1–2 lessons): every
  `<select>`/filter that drives a fetch resets its list only when the selection actually
  changes; every async `useEffect` uses an `active`-flag cleanup.
- **`data-test=` hooks** on interactive elements; `tests/admin/test_files.py` under
  `-n auto`. Touched `.zig` stays `zig fmt`-clean. Run the FULL `tests/admin/` suite before
  finishing. Docs/site mirror in sync; a `changelog.d/` fragment added.

## Confirmed API surface (verified against origin/main)

All superuser; the admin cookie session works on all of these.

- **Enumerate file fields**: `GET /api/collections` → each collection's `fields[]` include
  `{name, type:"file", options:{maxSelect, maxSize?, mimeTypes?}}`. Admin filters to
  collections having ≥1 `type==="file"` field; `maxSelect>1` = multi-file.
- **List records**: `GET /api/collections/:col/records?page&perPage&sort` → `{items, totalPages, …}`.
  A file field's value is a **filename string** (single) or a **JSON array of filename
  strings** (multi); `""`/`[]` = empty.
- **Serve/preview/download**: `GET /api/files/:col/:rec/:name` — gated by `viewRule`
  (superuser bypasses). Inline for safe image types; append `?download` to force download.
- **Upload / replace**: multipart `PATCH /api/collections/:col/records/:id` (or `POST …/records`
  to create) — the multipart part name is the **collection field's own name**; server
  enforces `maxSize` (413), `mimeTypes` (400, content-sniffed), `maxSelect` (400).
- **Remove**: single field → clear it; multi field → a `<field>-` control key listing the
  filename(s) to drop. (The plan confirms whether clear/remove goes via a JSON `PATCH`
  `{field:""}` / `{"<field>-":[…]}` body or a multipart control part, against
  `src/files/plan.zig`.)
- **Storage backend info**: NOT exposed over HTTP today → the new endpoint below.

## New backend: `GET /api/files/config` (the only new server code)

A minimal superuser read endpoint for the storage strip. Returns the active backend +
non-secret operational config — **never credentials**:

```json
{ "backend": "local", "dir": "storage" }
```
or
```json
{ "backend": "s3", "bucket": "my-bucket", "region": "us-east-1",
  "endpoint": "", "key_prefix": "uploads/" }
```

- Backend = `s3` when the S3 bucket is configured, else `local` (mirrors
  `DefaultStoragePlugin.create`, `framework.zig:~112`).
- S3 branch exposes `bucket`/`region`/`endpoint`/`key_prefix` (operational, appear in
  URLs — not secret). **The `s3_access_key_id` / `s3_secret_access_key` are NEVER
  included.** Local branch exposes the relative storage dir name only.
- New handler `src/api/files_config.zig`; route `GET /api/files/config` in `src/server.zig`.
  Storage is always present (every app has a storage backend), so the route is
  **unconditional** in the base table (no gate); superuser-gated in-handler (403 to
  non-superusers), mirroring `api/mail_config.zig`.
- The plan confirms the exact config field access (`app.config.s3_*` / `data_dir`) against
  `src/config.zig`.
- A Zig unit test (backend + fields for a local and an s3-shaped config; asserts NO
  `access_key`/`secret` field is ever present) + browser coverage.

## View design — `src/admin/views/files.js`

One exported `FilesView` at `#/files`; nav item `📁 Files`. Layout:

### Storage strip (top, read-only)
Fetches `GET /api/files/config` once (active-flag guard); renders a backend chip
(`data-test=storage-backend`, "Local disk" / "S3") + the non-secret detail
(dir, or bucket/region). Degrades quietly on 404/error.

### Collection picker
From `GET /api/collections`, filter to collections with ≥1 `type==="file"` field.
`<select data-test=files-collection>` with the Phase-1 change-guard (only reset on real
change). If none, an empty-state (`data-test=files-none`).

### Records browser
For the selected collection, list records (`data-test=file-record-row`, paginated). Each
row shows the record id + a compact preview of its file field(s) (first image thumbnail /
file-count chip). Clicking a row opens the **file drawer**.

### File drawer (per record)
For the selected record, one section per file field:
- **Field label** + its current file(s):
  - image extension (`png jpg jpeg gif webp avif bmp ico`) → `<img data-test=file-thumb src="/api/files/:col/:rec/:name">` (cookie-auth same-origin);
  - otherwise → a filename chip + `<a data-test=file-download href="/api/files/:col/:rec/:name?download">`.
- **Upload / replace**: a file `<input type=file data-test=file-upload>` → build `FormData`,
  `append(fieldName, file)`, `API.uploadFile(col, id, formData)` (a new helper using the
  `api()` `isForm` path → multipart `PATCH`); on success reload the record. Single field
  replaces; multi appends (server enforces `maxSelect`).
- **Remove** a file (`data-test=file-remove`, confirm dialog): single → clear the field;
  multi → drop that filename via the `<field>-` mechanism; reload.
The drawer is keyed on the record id (Phase-1 remount guard).

## Out of scope (documented gaps, not built)

- Server-side thumbnails / `?thumb=` resizing (not implemented in `serve`).
- Storage usage / global file listing / orphan-blob reports (no API).
- Presigned-URL / CDN-base exposure for S3 (downloads always proxy `/api/files/...`).
- Editing a collection's file-field schema (that's the Schema editor) or deleting whole
  records (that's the Collections view).
- The `/api/files/token` flow (only needed for cross-origin `<img>`; the admin is same-origin).

## Testing strategy

- `tests/admin/test_files.py` (Playwright, `-n auto`): storage strip renders the backend;
  collection picker lists only file-field collections; browse a seeded record's file field;
  **upload** a file by driving the `<input type=file>` with Playwright `set_input_files`
  (the app does the multipart PATCH) → the thumbnail/chip appears; **remove** → it's gone.
  Seed a collection with a `file` field + a record via the records API using `conftest`
  helpers; upload through the UI.
- Zig unit test for `files_config` (backend + non-secret fields; asserts no credential
  field).
- Existing suite stays green (additive: one endpoint, one view, one manifest row, one nav
  item).

## Risks

1. **Multipart upload plumbing** — confirm the admin `api()` client's `isForm` path passes
   a `FormData` body without setting `Content-Type` (so the browser sets the multipart
   boundary) while still sending the `X-CSRF-Token` header on the `PATCH`. The plan verifies
   `lib/api.js` and adds `API.uploadFile` accordingly. Playwright uploads via
   `set_input_files`.
2. **Remove mechanism** — confirm single-clear vs multi-`<field>-` request shape against
   `src/files/plan.zig` (JSON body vs multipart control key) before building the remove path.
3. **No credential leak** — `files_config` must whitelist non-secret fields explicitly; a
   unit test asserts no `access_key`/`secret` key appears.
4. **Image-vs-not detection** — decide inline preview purely by filename extension
   (matching the server's `isInlineSafeExt`, minus `pdf` which downloads).
