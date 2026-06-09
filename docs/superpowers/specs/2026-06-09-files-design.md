# ZigBase SP8 — File Storage Design

**Status:** Approved design (brainstorm complete). Sub-project 8 of the ZigBase roadmap
(`docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md`).

**Goal:** `file`-type fields stored on local disk, uploaded via `multipart/form-data` on the existing
record endpoints, served through an access-controlled download endpoint (public files direct;
protected files via cookie / bearer / short-lived file token), behind a pluggable storage interface
(local now; S3 a later drop-in).

**Depends on:** SP3 (records + values), SP4 (access rules — `viewRule` enforcement), SP5 (auth — JWT
`sign`/`verify`, `verifyToken`, `RequestContext`), the collections engine, config. zap parses
`multipart/form-data` natively (`HttpParam.Hash_Binfile`/`Array_Binfile` with `{data, filename,
mimetype}`) and streams responses via `r.sendFile` — both confirmed in v0.10.6, so the multipart
open-risk is retired with no zap fork.

**Out of scope (deferred):** image thumbnail generation / transforms; S3 (and other) storage backends
(the `Storage` interface is designed for them); resumable/chunked uploads; partial-content / Range
requests on download.

---

## 1. Decisions (from brainstorming)

1. **Upload transport: multipart on the record endpoints.** `POST/PATCH /api/collections/:col/records`
   accept `multipart/form-data`: file fields arrive as file parts, other fields as form fields; the
   handler stores files and sets each `file` field's value to the generated stored filename(s),
   atomically with the record write. JSON bodies still work for file-less records.
2. **Protected-file access: cookie / bearer / short-lived file token.** Public-collection files
   (`viewRule == ""`) serve with no auth. Protected files authorize via the `zb_auth` cookie, a
   bearer header, or a `?token=<file-token>` query param (a short-lived `TokenType.file` JWT from
   `POST /api/files/token`), and re-enforce the record's `viewRule` in all cases.
3. **Architecture: `records.zig` stays file-agnostic.** It already stores `file`-field values as
   filename strings (single → string, multi → JSON array). A new `src/files/` package owns the
   `Storage` interface + filename naming; `api/records.zig` + `api/files.zig` orchestrate multipart
   parsing, storage, serving, and setting the filename values.
4. **Multi-file editing: add/remove modifiers** (not deferred) — see §4.
5. **Serving uses `r.sendFile`** (efficient `sendfile()` streaming), not buffering bytes into the
   request arena.

---

## 2. Architecture & modules

| Module | Responsibility | Tested |
|---|---|---|
| `src/files/storage.zig` | `Storage` vtable + `LocalStorage` (FS ops under `<data_dir>/storage/<col>/<rec>/<name>`) | unit (temp dir) |
| `src/files/naming.zig` | Pure: sanitize an uploaded filename + generate a collision-safe stored name | unit |
| `src/files/multipart.zig` | zap glue: `extract(r, alloc) → { form_fields, files }` from parsed multipart | smoke |
| `src/api/files.zig` | `GET /api/files/:col/:rec/:name` (serve) + `POST /api/files/token` | unit (handler logic) + smoke |

`src/files/multipart.zig` is the **third zap-importing module** (a deliberate, scoped exception
alongside `server.zig` and `realtime/ws.zig`): zap owns multipart parsing, so the extraction lives
next to it, producing the neutral types below; `server.zig` calls it.

### Neutral types (zap-free)

In `src/http.zig`:

```
pub const UploadedFile = struct {
    field: []const u8,    // form field name (the file field)
    filename: []const u8, // client-supplied original name (untrusted)
    mimetype: []const u8, // client-supplied content-type (untrusted; advisory)
    bytes: []const u8,    // the uploaded bytes (in the request arena)
};
```

`RequestCtx` gains: `content_type: []const u8 = ""`, `form_fields: ?std.json.Value = null`,
`files: []const UploadedFile = &.{}`. These are filled by `server.zig` **only** when the request
body is `multipart/form-data`; JSON requests are unaffected.

`Response` gains: `file_path: ?[]const u8 = null` and `extra_headers: []const Header = &.{}` (where
`Header = struct { name, value }`). When `file_path` is set, `server.zig` writes `extra_headers`,
sets the content-type from the filename (zap `setContentTypeFromFilename`), and calls `r.sendFile`
instead of `r.sendBody` — the bytes never enter the arena.

### `Storage` interface

```
pub const Storage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        put: *const fn (ctx, io, col, record_id, filename, bytes) anyerror!void,
        localPath: *const fn (ctx, alloc, col, record_id, filename) anyerror!?[]const u8, // null = not local
        delete: *const fn (ctx, io, col, record_id, filename) anyerror!void,
        deleteRecord: *const fn (ctx, io, col, record_id) anyerror!void,
    };
    // thin wrapper methods that dispatch through the vtable
};
```

`LocalStorage` writes to `<data_dir>/storage/<col>/<record_id>/<filename>` (creating dirs as needed),
returns that absolute path from `localPath` (for `sendFile`), unlinks on `delete`, and removes the
record dir on `deleteRecord`. The app holds one `Storage` (local) on `App`; S3 later implements the
same vtable. **All identifiers reaching a path are validated** — `col`/`record_id` are validated
collection names / generated ids, and `filename` is always a `naming`-sanitized stored name, never a
client string.

### Config (`config.zig`/`app.zig`)

`max_upload_size: u64 = 50 << 20` (50 MiB, per-request body cap), `file_token_ttl_s: i64 = 120`.
Storage root = `<data_dir>/storage`. `App` carries the `Storage` + these settings.

---

## 3. Filename naming (`files/naming.zig`)

Pure functions:
- `sanitizeBase(name) → []const u8`: take the client filename's basename (drop any `/`, `\`, and
  everything up to the last separator), strip a leading `.`, replace any char outside
  `[A-Za-z0-9._-]` with `_`, collapse repeats, cap length; empty/`.`/`..` → `"file"`. The result can
  never contain a path separator or `..`.
- `storedName(io, alloc, original) → []const u8`: `"<sanitized-stem>_<10-char base36>.<ext>"` (ext
  from the sanitized name, lowercased, `≤16` chars; no ext → no suffix dot). The random suffix (via
  `io.random` → base36) guarantees uniqueness within a record dir and unguessability.

Unit-tested for traversal resistance (`../../etc/passwd`, `a/b/c.png`, `..`, empty, unicode/control
chars, very long names) and ext handling.

---

## 4. Upload flow (multipart on the record endpoints)

`server.zig` `onRequest`: if `content-type` starts with `multipart/form-data`, call `r.parseBody()`
then `files.multipart.extract(r, arena)` → fill `ctx.form_fields` + `ctx.files`. Else unchanged.

### Create (`POST .../records`, multipart)

1. Use `ctx.form_fields` as the record data (instead of parsing `ctx.body`).
2. **Validate before touching disk:** for each uploaded file — the target field exists on the
   collection and is a `file` field; the field's `maxSize` (per file) and `mimeTypes` (the
   *server-sniffed* type — see §6 — must be in the allowlist); per-field file count ≤ `maxSelect`;
   the whole request ≤ `max_upload_size`. Violations → `400` (bad field/type/count) or `413` (too
   large), nothing written.
3. **Generate stored filenames** (`naming.storedName`) for each uploaded file; set each `file`
   field's value in the data (single → string, multi → array, in upload order).
4. `records.create(data)` → record id (one atomic insert carrying the filenames; required-file
   fields validate because the names are present).
5. **Write bytes** via `Storage.put(col, recordId, filename, bytes)`.
6. **Cleanup on failure:** any write error → delete the just-created record + any written files →
   `500`. (Disk writes are outside the SQL transaction; the only window is between the insert and the
   writes, and a failure rolls the record back — a brief, self-healing gap, acceptable for the MVP.)
7. `201 {record}`.

### Update (`PATCH .../records/:id`, multipart) — add/remove modifiers

Load the existing record. For each `file` field on the collection:
- **Single (`maxSelect == 1`):** an uploaded file under the field name **replaces** the existing one
  (old deleted after commit); a `<field>-` value or an explicit empty value **clears** it; the field
  absent → unchanged.
- **Multi (`maxSelect > 1`):**
  - **removals** = the text values sent under `"<field>-"` (the field name with a trailing `-`),
    matched against the existing filenames (unknown names are no-ops);
  - **additions** = the file parts under `"<field>"`, each stored via `naming` → new filename;
  - **net** = `(existing − removals) ++ additions` (preserving order). `len(net) > maxSelect` → `400`.
  - The field absent entirely (no parts, no `-` values) → unchanged.
- Validate additions' `maxSize`/`mimeTypes`; set the field value to `net`.
- `records.update(...)`; on success **write additions** then **delete removed/replaced files**; on
  failure clean up any newly written additions and leave the record untouched.

### Delete (`DELETE .../records/:id`)

After the row is deleted, `Storage.deleteRecord(col, recordId)` removes `storage/<col>/<recordId>/`
(best-effort; a failed unlink is logged, not fatal).

---

## 5. Serving & access control (`api/files.zig`, `server.zig`)

### `GET /api/files/:col/:rec/:name`

1. Resolve the collection; load the record by id → not found → `404`.
2. **`:name` must be one of the filenames stored in that record's `file`-field values** — else `404`.
   This is the anti-traversal gate: `:name` is never used as a path component until confirmed to be a
   real, record-referenced, `naming`-sanitized stored name.
3. **Access control** — resolve identity from (in order) `?token=` (a `TokenType.file` or `.auth`
   token) → cookie → bearer. An absent/invalid/expired token is simply treated as *no identity*
   (anonymous), never an error — the request then succeeds only if the file is public:
   - `viewRule == ""` → serve (public; no auth).
   - `viewRule == null` → superuser only (else `404`).
   - else → `rules.matches(record, identity)` → serve or `404`.
4. **Serve:** `resp.file_path = Storage.localPath(col, rec, name)`; `resp.extra_headers` =
   `Referrer-Policy: no-referrer`, `Cache-Control: private` (or `public, max-age=…` when
   `viewRule == ""`), and `Content-Disposition: inline` (or `attachment; filename="<name>"` when the
   query has `download=1`). `server.zig` sets the content-type from the name and `r.sendFile`s it.
   (If `localPath` returns null — a non-local backend — fall back to reading bytes into `resp.body`;
   not reached with the local backend.)

### `POST /api/files/token`

- Requires normal auth (cookie/bearer; resolved via `auth.authenticate`). Mints a short-lived
  (`file_token_ttl_s`) JWT with `jwt.TokenType.file`, carrying the caller's identity (id +
  collection), signed with that record's per-record key (the existing `crypto.deriveKey` +
  `jwt.sign`). Returns `{token}`. Anonymous callers → `401`.

### Token verification

Add `file` to `jwt.TokenType`. The file GET accepts a `?token=` by generalizing the verify path to
accept `type ∈ {auth, file}` **for the file endpoint only**. The main record/collection endpoints and
the WS/realtime auth path still require `type == .auth`, so a `file` token can authenticate **only**
file reads, for its short TTL, still gated per-file by `viewRule`.

---

## 6. Validation & limits

- **Per field** (`schema.FileOptions`, already present): `maxSelect` (count), `maxSize` (bytes per
  file), `mimeTypes` (allowlist; `null` = unrestricted, any type accepted).
- **MIME enforcement uses the server-sniffed type**, not the client's `Content-Type` header: sniff
  from the file's magic bytes (a small built-in signature table covering common image/pdf/text/zip
  types; unknown → `application/octet-stream`). The client mimetype is advisory only. This prevents a
  client from bypassing `mimeTypes` by lying about the type.
- **Global:** `max_upload_size` caps the whole request body (zap also enforces its configured
  `max_body_size`; set it consistently). Over → `413`.
- **Filenames:** always server-generated stored names; the client original is only an input to
  `sanitizeBase`.

---

## 7. Error handling

| Condition | Status |
|---|---|
| Upload to a non-existent / non-`file` field | 400 |
| File exceeds `maxSize`, count exceeds `maxSelect`, or net multi-field exceeds `maxSelect` | 400 |
| Sniffed MIME not in `mimeTypes` | 400 |
| Request body exceeds `max_upload_size` | 413 |
| Record validation/conflict on create/update | 400 / 409 / 422 (existing record-handler mapping) |
| Storage write failure (after record write) | 500 (record + partial files rolled back) |
| File GET: unknown collection/record, or `:name` not referenced by the record | 404 |
| File GET: protected file, identity fails `viewRule` | 404 (hide existence) |
| `POST /api/files/token` while unauthenticated | 401 |
| Success: serve / upload / token | 200 / 201 / 200 |

All record/collection identifiers reaching SQL or a filesystem path are validated; filenames are
sanitized/generated. No client string is ever used as a raw path component.

---

## 8. Testing strategy

- **`files/naming.zig` (pure):** sanitize traversal/edge cases; stored-name format + ext handling +
  uniqueness across calls.
- **`files/storage.zig` (temp dir):** `put`/`localPath`/`delete`/`deleteRecord` round-trips;
  `deleteRecord` removes the whole record dir; missing-file delete is a no-op.
- **MIME sniffing (pure):** known signatures → correct type; unknown → octet-stream; truncated input
  safe.
- **Upload-orchestration logic** (the create/update file-field computation — additions/removals/net,
  validation decisions): factor the pure decision (`planFileWrites(existing, uploads, removals,
  field) → {value, to_write, to_delete} | error`) so it's unit-tested without zap, then the handler
  wires it to `Storage` + `records`. Cover single replace/clear, multi add/remove/net-cap,
  maxSize/maxSelect/mime violations.
- **Serving access decision** (pure-ish, against a temp DB): public served; protected served only to
  an authorized identity; `:name` not referenced → 404; superuser-only for `null` viewRule.
- **`multipart.zig` + the `sendFile` path:** smoke-only (real zap request).
- **Live smoke (8b):** upload an image to a public collection via multipart → `GET /api/files/...`
  returns the bytes with the right content-type; a protected collection's file is refused to an
  anonymous client, served with a valid file token / cookie; multi-file add+remove in one PATCH;
  record delete removes the files from disk.
- **Holistic security review** before merge: path traversal (both ends), MIME-bypass, the file-token
  scope (can't authenticate the main API; short TTL; viewRule still enforced), access-control parity
  with REST `GET`, cleanup/orphan handling on failure, and DoS (upload size cap, no unbounded arena
  buffering on serve).

---

## 9. Build slicing — two plans

**8a — storage, naming, and file-field logic (no HTTP/zap):**
- `files/naming.zig` (sanitize + stored name) — pure, unit-tested.
- `files/storage.zig` (`Storage` vtable + `LocalStorage`) — temp-dir-tested.
- MIME sniffing (a `files/mime.zig` or within storage) — pure, unit-tested.
- `planFileWrites` (the create/update file-field computation: additions/removals/net/validation) —
  pure, unit-tested across the matrix.
- `Response`/`RequestCtx` neutral-type additions (`UploadedFile`, `file_path`, `extra_headers`,
  `content_type`/`form_fields`/`files`) — wired but inert until 8b.
- Config + `Storage` on `App`.

**8b — transport, endpoints & wiring:**
- `files/multipart.zig` (zap extraction) + `server.zig` multipart detection + the `file_path`/
  `sendFile` response path + `extra_headers` writing.
- `api/records.zig` create/update made multipart-aware (uses `form_fields`/`files` + `planFileWrites`
  + `Storage`, with cleanup-on-failure); delete calls `Storage.deleteRecord`.
- `api/files.zig` (`GET /api/files/:col/:rec/:name` + `POST /api/files/token`); `jwt.TokenType.file`
  + the generalized verify for the file endpoint; routes in `server.zig`.
- Live smoke, holistic security review, then merge SP8 (8a+8b) as a unit to `main`.

NOTE: `zig build test` does not analyze unreferenced `pub fn` bodies — 8b must run **both**
`zig build` (binary) and `zig build test` (this bit SP7).
