# ZigBase — Static File Serving + Example Frontends Design

**Status:** Approved design (brainstorm complete).

**Goal:** Serve static files from the ZigBase binary as a root-path fallback, with a comptime
`.static_files` config selecting one of four modes — runtime `--serve-static <dir>` flag
(default), disabled, comptime-hardcoded directory, or assets fully embedded in the binary.
Ship an Astro + React-islands frontend with each of the three examples (each exercising a
different mode), and update the docs and marketing website accordingly.

**Depends on:** the existing HTTP server/router (`src/server.zig`, `src/router.zig`), the
`Response.file_path` sendFile streaming path (`src/http.zig:87`), the framework comptime-config
validation pattern (`src/framework.zig`), and the CLI parser (`src/cli.zig`).

**Out of scope (deferred):** Range/partial-content requests; directory listings; on-the-fly
compression (gzip/brotli); SPA history-API fallback (rewrite-all-misses-to-index.html); watch
mode / live reload; symlink resolution policy beyond lexical path checks.

---

## 1. Decisions (from brainstorming)

1. **Mount point: root fallback.** Anything not matching `/_/` (admin), built-in routes, or
   custom routes falls through to static serving — like PocketBase's `pb_public`. `/api/*`
   misses keep the JSON 404 envelope; static misses return a plain-text 404.
2. **Four comptime modes via a new `.static_files` field on `App(.{...})`:**
   - *absent (default)* → runtime mode: a new `--serve-static <dir>` flag on `serve`; no flag,
     no serving.
   - `.disabled` → no serving; `--serve-static` is an unknown flag.
   - `.{ .dir = "path" }` → hardcoded directory (resolved relative to cwd at startup);
     `--serve-static` rejected.
   - `.{ .embedded = &assets.files }` → assets compiled into the binary; `--serve-static`
     rejected.
3. **One mode per example** (living documentation): blog = default/runtime flag, golfsim =
   hardcoded `.dir`, plugins = embedded.
4. **Functional frontends.** Each example's Astro site really works against its backend API,
   with React islands for the interactive parts.
5. **Embedded manifest is build-generated.** Zig cannot `@embedFile` a directory, so zigbase's
   `build.zig` exports a helper consumers import (`@import("zigbase")` in their build.zig) that
   walks an asset dir at build time and generates a manifest module of `@embedFile` entries.
6. **Blog and golfsim gain comptime `.collections` schemas** so the examples run out of the box
   (golfsim's hooks already reference users/simulators/listings/bookings by name but currently
   require manual admin-UI provisioning).

---

## 2. Architecture & modules

| Module | Responsibility | Tested |
|---|---|---|
| `src/static_files.zig` | Path sanitization, index resolution, content-type table, ETag, serve from dir (sendFile) or embedded slice | unit |
| `src/server.zig` | Fallback dispatch: after admin + built-in + custom routes miss, GET/HEAD non-`/api/` → static | smoke (pytest) |
| `src/framework.zig` | Validate `.static_files` comptime field; plumb resolved mode into the runtime | comptime tests |
| `src/cli.zig` | `--serve-static <dir>` on `serve` (only in default mode) | unit |
| `build.zig` | `pub fn embedStaticDir(...)` helper generating the embedded manifest module | exercised by plugins example |

### Core types

```zig
// src/static_files.zig
pub const StaticFile = struct {
    path: []const u8,     // request path relative to root, e.g. "assets/app-abc123.js"
    bytes: []const u8,    // @embedFile contents
    etag: []const u8,     // comptime-derived content hash
};

pub const Source = union(enum) {
    none,                          // disabled or default-mode-without-flag
    dir: []const u8,               // filesystem root
    embedded: []const StaticFile,  // build-generated manifest
};

pub fn serve(ctx: *http.RequestCtx, source: Source) !?http.Response;
// null = no file matched (caller falls through to the 404 envelope/plain 404)
```

The resolved `Source` lives on the app `Runtime` (`src/app.zig`), set from either the comptime
config or the parsed `--serve-static` flag, mirroring how `max_upload_size` is plumbed.

### Comptime config (src/framework.zig)

`.static_files` joins the `allowed` field list. Accepted values, validated with clear
`@compileError`s:

```zig
.static_files = .disabled
.static_files = .{ .dir = "frontend/dist" }
.static_files = .{ .embedded = &static_assets.files }
// field absent → default: runtime --serve-static flag enabled
```

In disabled/dir/embedded modes the CLI parser receives a comptime flag telling it to reject
`--serve-static` (so `help` output also only shows the flag in default mode).

### Serving behavior (both dir and embedded)

1. **Methods:** GET and HEAD only; other methods fall through to the 404 envelope.
2. **Sanitization:** reject any path containing a `..` segment, null bytes, or backslashes;
   collapse duplicate slashes. Lexical checks only (no symlink resolution; documented).
3. **Index resolution:** `/` and paths ending in `/` resolve to `index.html` within that
   directory; a path that matches a directory on disk retries as `<path>/index.html`.
4. **Content types:** extension table — html, css, js, mjs, json, svg, png, jpg/jpeg, gif,
   webp, avif, ico, woff, woff2, ttf, wasm, txt, xml, map, pdf, mp4, webm; unknown →
   `application/octet-stream`. Always `X-Content-Type-Options: nosniff`.
5. **Caching:** embedded mode emits a comptime CRC32 content `ETag` and answers `If-None-Match`
   with `304` itself (plain body responses get no transport etag). Dir mode delegates entirely to
   facil.io's sendFile, which adds its own `etag`, `Last-Modified`, `Cache-Control: max-age=3600`,
   and handles `If-None-Match`/`304` — zigbase adds no caching headers of its own there.
6. **Transport:** dir mode sets `Response.file_path` (zap `sendFile` streaming); embedded mode
   sets `Response.body` to the comptime slice (no copy).
7. **Miss:** return null → server responds plain-text 404 (`text/plain`), distinct from the
   `/api/*` JSON envelope.

### Dispatch order (src/server.zig onRequest)

1. `/_/*` → admin UI (unchanged)
2. Built-in routes (unchanged)
3. Custom routes (unchanged)
4. **New:** method GET/HEAD and path not starting `/api/` and `Source != .none` →
   `static_files.serve()`; on hit, respond; on miss (null), respond plain-text 404.
5. Everything else (non-GET/HEAD, `/api/*`, or `Source == .none`) → JSON 404 envelope
   (unchanged).

### Embedded manifest build helper (build.zig)

zigbase's `build.zig` gains:

```zig
pub fn embedStaticDir(b: *std.Build, opts: struct {
    dir: std.Build.LazyPath,      // e.g. b.path("frontend/dist")
    module_name: []const u8 = "static_assets",
}) *std.Build.Module
```

Implementation: walk `dir` at build (configure) time with `std.fs`, emit a generated `.zig`
source into a `WriteFiles` step alongside copies of the asset files, where the generated file
declares `pub const files = [_]StaticFile{ .{ .path = "...", .bytes = @embedFile("...") , .etag = "..." }, ... }`.
Consumers do:

```zig
// build.zig
const zigbase_build = @import("zigbase");
const assets = zigbase_build.embedStaticDir(b, .{ .dir = b.path("frontend/dist") });
exe_mod.addImport("static_assets", assets);

// main.zig
const static_assets = @import("static_assets");
zigbase.App(.{ .static_files = .{ .embedded = &static_assets.files } })
```

The build fails with a clear error if the dir doesn't exist (e.g. frontend not yet built),
pointing at `npm run build`.

Note on types: the generated module cannot import zigbase's `StaticFile` (it has no module
graph edge to it), so it declares a structurally identical local struct. Since the `App(.{...})`
config is `anytype`, `framework.zig` comptime-coerces any slice of structs with
`path`/`bytes`/`etag` fields into `[]const static_files.StaticFile`.

### CLI (src/cli.zig)

`ServeArgs` gains `serve_static: ?[]const u8 = null`; the serve loop accepts
`--serve-static <dir>` only when the comptime mode is default. `help` text updated accordingly.

---

## 3. Example frontends

Each example gains `frontend/` — an Astro project with React islands (`@astrojs/react`),
`npm run build` → `frontend/dist/`, talking to the backend's API same-origin (no CORS needed).
Astro config uses relative-friendly defaults so assets resolve when served from `/`. A tiny
shared-by-copy `api.ts` fetch client (auth header + JSON envelope handling) lives in each
frontend (no shared package; examples stay self-contained).

| Example | Static mode | Backend additions | Frontend |
|---|---|---|---|
| **blog** | default — run with `--serve-static frontend/dist` | comptime `.collections`: `posts` (title, slug, body, published; public list/view of published) | Astro pages: post list, post detail (client-fetched). React island: login + "write a post" form exercising the `slugify` hook |
| **golfsim** | comptime `.{ .dir = "frontend/dist" }` | comptime `.collections` for users / simulators / listings / bookings matching what hooks already expect | Astro pages: listings browser. React island: booking flow — pick listing/time, create booking (hold), confirm via `POST /api/bookings/:id/confirm` |
| **plugins** | embedded via `embedStaticDir` | none (collections already comptime) | Astro page with React island browsing authors + published posts; banner noting the whole site is inside the binary |

Each example README documents: `npm install && npm run build` in `frontend/`, then the
mode-appropriate run command. Example `.gitignore`s exclude `frontend/dist/` and
`node_modules/`.

---

## 4. Tests

- **Zig unit tests** (`src/static_files.zig`): traversal rejection (`..`, encoded-ish junk,
  backslashes), duplicate-slash collapse, index resolution, content-type mapping, ETag
  derivation, embedded-source lookup, HEAD has empty body semantics.
- **CLI tests** (`src/cli.zig`): `--serve-static` parsing, missing-value error.
- **Pytest integration** (`tests/admin/test_static_files.py`, following the
  `test_custom_route.py` pattern of building an example):
  - stock binary + `--serve-static <tmpdir>`: 200 with correct content-type, index.html at `/`,
    304 on If-None-Match, plain 404 on miss, traversal attempts 404, `/api/missing` still JSON.
  - build the **plugins** example (requires `npm run build` in its frontend; test skips with a
    clear message if npm is unavailable) and verify embedded serving of `/` and a hashed asset.
- **Comptime config tests** (`src/framework.zig`): each `.static_files` form compiles; invalid
  forms produce `@compileError` (verified via the existing temp-test pattern — reverted with
  Edit, never `git checkout`).

---

## 5. Docs & marketing site

**Repo docs:**
- `README.md` — features bullet + quickstart note for `--serve-static`.
- `docs/framework.md` — `.static_files` modes, `embedStaticDir` helper, dispatch-order note.
- `docs/api.md` — root-fallback serving semantics, caching/ETag, 404 behavior.
- `docs/recipes.md` — recipe: "Ship your frontend inside the binary" (Astro build → embed).
- `KNOWN_LIMITATIONS.md` — no Range requests, no directory listings, lexical symlink policy,
  no compression.
- `CHANGELOG.md` — feature entry.

**Marketing site (`site/`):**
- Mirror doc updates in `site/src/content/docs/` (framework, api, recipes, configuration).
- Index page feature grid gains static-file serving ("bring your own frontend — or embed it").
- `site/src/pages/examples/*` — each example page describes its frontend and which static mode
  it demonstrates.

---

## 6. Error handling summary

| Condition | Behavior |
|---|---|
| `--serve-static` dir missing/unreadable at startup | fatal startup error naming the path |
| `--serve-static` passed in non-default comptime mode | `UnknownFlag` parse error |
| Invalid `.static_files` comptime value | `@compileError` with the accepted forms |
| `embedStaticDir` dir missing at build time | build error pointing at `npm run build` |
| Traversal/invalid path at runtime | 404 (no distinction from missing file) |
| File deleted between stat and send (dir mode) | 404 |
