# Static File Serving + Example Frontends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve static files from the ZigBase binary as a root-path fallback with four comptime modes (runtime `--serve-static` flag / disabled / hardcoded dir / embedded-in-binary), ship Astro + React-islands frontends for all three examples (one mode each), and update docs + the marketing site.

**Architecture:** A new `src/static_files.zig` module serves files as the last dispatch fallback in `src/server.zig` (after admin, built-in, and custom routes). The comptime `.static_files` field on `App(.{...})` resolves to a `Mode` threaded through `ServeOpts` into `serveImpl`, which sets a runtime `Source` on the app. Embedded assets come from a build-generated `@embedFile` manifest produced by a new `embedStaticDir` helper exported from zigbase's `build.zig`.

**Tech Stack:** Zig 0.16 (`mise exec zig@0.16.0 -- zig …`), zap (HTTP), Astro 5 + @astrojs/react + React 19 (example frontends), pytest (integration tests).

**Spec:** `docs/superpowers/specs/2026-06-10-static-files-design.md`

**Branch:** `feat/static-files` (already created from origin/main).

---

## Zig 0.16 API caveats (read first)

- Tagged-union/enum-literal comparison `u == .tag` does NOT compile in 0.16 — use `std.meta.activeTag(u) == .tag` (see the comment in `src/cli.zig:108`).
- Filesystem ops go through `std.Io.Dir.cwd()` with an explicit `io: std.Io` parameter (see `src/files/storage.zig:56-86`). In tests, the io is `std.testing.io`. If a needed symbol (e.g. `statFile`) isn't where you expect, find the lib path with `mise exec zig@0.16.0 -- zig env` and grep `<lib_dir>/std/Io/Dir.zig` for `pub fn`. The memory file `zig-016-std-io-migration.md` lists known renames.
- `std.ArrayList(T)` is unmanaged: `var l: std.ArrayList(u8) = .empty; try l.append(alloc, x);`.
- All zig commands: `mise exec zig@0.16.0 -- zig …` (or an activated mise shell).
- If you add a throwaway compile-error test, revert it with Edit — NEVER `git checkout <file>`.

---

### Task 1: Extension-based content types in `src/files/mime.zig`

The existing `mime.sniff` is magic-byte based (for uploads). Static serving needs extension-based mapping.

**Files:**
- Modify: `src/files/mime.zig`

- [ ] **Step 1: Write the failing tests** — append to `src/files/mime.zig`:

```zig
test "fromExtension maps common static-asset extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromExtension("assets/site.css"));
    try std.testing.expectEqualStrings("application/javascript", fromExtension("a/b/app-Abc123.js"));
    try std.testing.expectEqualStrings("application/javascript", fromExtension("m.mjs"));
    try std.testing.expectEqualStrings("application/json", fromExtension("data.json"));
    try std.testing.expectEqualStrings("image/svg+xml", fromExtension("logo.svg"));
    try std.testing.expectEqualStrings("image/png", fromExtension("img.png"));
    try std.testing.expectEqualStrings("image/jpeg", fromExtension("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", fromExtension("photo.jpeg"));
    try std.testing.expectEqualStrings("image/webp", fromExtension("img.webp"));
    try std.testing.expectEqualStrings("image/avif", fromExtension("img.avif"));
    try std.testing.expectEqualStrings("image/gif", fromExtension("anim.gif"));
    try std.testing.expectEqualStrings("image/x-icon", fromExtension("favicon.ico"));
    try std.testing.expectEqualStrings("font/woff2", fromExtension("f.woff2"));
    try std.testing.expectEqualStrings("font/woff", fromExtension("f.woff"));
    try std.testing.expectEqualStrings("font/ttf", fromExtension("f.ttf"));
    try std.testing.expectEqualStrings("application/wasm", fromExtension("mod.wasm"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", fromExtension("robots.txt"));
    try std.testing.expectEqualStrings("application/xml", fromExtension("sitemap.xml"));
    try std.testing.expectEqualStrings("application/json", fromExtension("app.js.map"));
    try std.testing.expectEqualStrings("application/pdf", fromExtension("doc.pdf"));
    try std.testing.expectEqualStrings("video/mp4", fromExtension("v.mp4"));
    try std.testing.expectEqualStrings("video/webm", fromExtension("v.webm"));
}

test "fromExtension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("archive.tar.zst"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("noext"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(""));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("trailingdot."));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: compile error, `fromExtension` not defined.

- [ ] **Step 3: Implement** — add to `src/files/mime.zig` above the tests:

```zig
const Ext = struct { ext: []const u8, mime: []const u8 };

// Longest-suffix-first where it matters (".js.map" before ".js" via explicit "map").
const extensions = [_]Ext{
    .{ .ext = "html", .mime = "text/html; charset=utf-8" },
    .{ .ext = "css", .mime = "text/css; charset=utf-8" },
    .{ .ext = "js", .mime = "application/javascript" },
    .{ .ext = "mjs", .mime = "application/javascript" },
    .{ .ext = "json", .mime = "application/json" },
    .{ .ext = "map", .mime = "application/json" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "ttf", .mime = "font/ttf" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "xml", .mime = "application/xml" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "webm", .mime = "video/webm" },
};

/// Content type from a path's file extension (the text after the LAST '.').
/// Unknown/missing extensions -> application/octet-stream.
pub fn fromExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return "application/octet-stream";
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e.ext, ext)) return e.mime;
    }
    return "application/octet-stream";
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (all existing tests stay green).

- [ ] **Step 5: Commit**

```bash
git add src/files/mime.zig
git commit -m "feat(static): extension-based content-type table in files/mime"
```

---

### Task 2: `src/static_files.zig` — types, path sanitization, embedded serving

**Files:**
- Create: `src/static_files.zig`
- Modify: `src/root.zig` (test-discovery import)
- Modify: `src/http.zig` (add `if_none_match` to RequestCtx)

- [ ] **Step 1: Create the module with types + failing tests.** Create `src/static_files.zig`:

```zig
//! Static file serving — the root-path fallback (spec:
//! docs/superpowers/specs/2026-06-10-static-files-design.md).
//! GET/HEAD requests that miss admin, built-in, and custom routes fall through
//! here (server.zig). Sources: a filesystem dir (streamed via Response.file_path
//! -> zap sendFile) or a build-generated embedded manifest (comptime bytes).
const std = @import("std");
const http = @import("http.zig");
const mime = @import("files/mime.zig");

/// One embedded asset. `etag` includes its surrounding quotes (e.g. "\"a1b2c3d4\"")
/// so it can be compared to / emitted as an ETag header value verbatim.
pub const StaticFile = struct {
    path: []const u8, // request path relative to root, '/'-separated, no leading slash
    bytes: []const u8,
    etag: []const u8,
};

/// Comptime mode selected via `App(.{ .static_files = ... })`.
///   .default  — field absent: the `--serve-static <dir>` runtime flag is enabled.
///   .disabled — no static serving; the flag is rejected.
///   .dir      — comptime-hardcoded directory (resolved against cwd at startup).
///   .embedded — assets compiled into the binary (see build.zig embedStaticDir).
pub const Mode = union(enum) {
    default,
    disabled,
    dir: []const u8,
    embedded: []const StaticFile,
};

/// Runtime source resolved in framework.serveImpl and stored on app.App.
pub const Source = union(enum) {
    none,
    dir: []const u8,
    embedded: []const StaticFile,
};

const nosniff = http.Header{ .name = "X-Content-Type-Options", .value = "nosniff" };

test "sanitize: normal paths normalize to root-relative" {
    const a = std.testing.allocator;
    const s1 = (try sanitize(a, "/index.html")).?;
    defer a.free(s1);
    try std.testing.expectEqualStrings("index.html", s1);
    const s2 = (try sanitize(a, "/a//b///c.js")).?;
    defer a.free(s2);
    try std.testing.expectEqualStrings("a/b/c.js", s2);
    const s3 = (try sanitize(a, "/")).?;
    defer a.free(s3);
    try std.testing.expectEqualStrings("", s3);
    const s4 = (try sanitize(a, "/docs/")).?;
    defer a.free(s4);
    try std.testing.expectEqualStrings("docs", s4);
    // "." segments are dropped
    const s5 = (try sanitize(a, "/a/./b.css")).?;
    defer a.free(s5);
    try std.testing.expectEqualStrings("a/b.css", s5);
}

test "sanitize: traversal and junk are rejected" {
    const a = std.testing.allocator;
    try std.testing.expect((try sanitize(a, "/../etc/passwd")) == null);
    try std.testing.expect((try sanitize(a, "/a/../../b")) == null);
    try std.testing.expect((try sanitize(a, "/a/..")) == null);
    try std.testing.expect((try sanitize(a, "/a\\b")) == null);
    try std.testing.expect((try sanitize(a, "/a\x00b")) == null);
    try std.testing.expect((try sanitize(a, "no-leading-slash")) == null);
}

const fixture = [_]StaticFile{
    .{ .path = "index.html", .bytes = "<h1>home</h1>", .etag = "\"11111111\"" },
    .{ .path = "assets/app.js", .bytes = "console.log(1)", .etag = "\"22222222\"" },
    .{ .path = "docs/index.html", .bytes = "<h1>docs</h1>", .etag = "\"33333333\"" },
};

test "embedded: exact file, root index, directory index, miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &fixture };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &ctx, src)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("console.log(1)", r.body);
    try std.testing.expectEqualStrings("application/javascript", r.content_type);
    // headers: ETag + nosniff
    try std.testing.expectEqual(@as(usize, 2), r.extra_headers.len);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("\"22222222\"", r.extra_headers[0].value);

    var root = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &root, src)).?.body);

    // "/docs" and "/docs/" both resolve to docs/index.html
    var d1 = http.RequestCtx{ .method = .GET, .path = "/docs", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d1, src)).?.body);
    var d2 = http.RequestCtx{ .method = .GET, .path = "/docs/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d2, src)).?.body);

    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.png", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src)) == null);
}

test "embedded: If-None-Match yields 304; non-GET/HEAD and .none yield null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &fixture };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator(), .if_none_match = "\"22222222\"" };
    const r = (try serve(std.testing.io, &ctx, src)).?;
    try std.testing.expectEqual(@as(u16, 304), r.status);
    try std.testing.expectEqualStrings("", r.body);

    var post = http.RequestCtx{ .method = .POST, .path = "/index.html", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &post, src)) == null);
    var none = http.RequestCtx{ .method = .GET, .path = "/index.html", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &none, Source.none)) == null);
}
```

- [ ] **Step 2: Add `if_none_match` to RequestCtx** in `src/http.zig` (after the `content_type` field, line 27):

```zig
    /// If-None-Match request header value (filled by server.zig; "" when absent).
    if_none_match: []const u8 = "",
```

- [ ] **Step 3: Add the test-discovery import** in `src/root.zig` (inside the `test {}` block, after `_ = @import("admin.zig");`):

```zig
    _ = @import("static_files.zig");
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: compile error, `sanitize`/`serve` not defined.

- [ ] **Step 5: Implement** in `src/static_files.zig` (below the types, above the tests):

```zig
/// Normalize a request path into a root-relative, '/'-separated file path.
/// Returns null for unsafe paths (no leading '/', NUL, backslash, "..").
/// "" means "the root" (callers resolve it to index.html). Caller owns the slice.
pub fn sanitize(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            out.deinit(alloc);
            return null;
        }
        if (out.items.len > 0) try out.append(alloc, '/');
        try out.appendSlice(alloc, seg);
    }
    return try out.toOwnedSlice(alloc);
}

/// Build the (ETag, nosniff) header pair in the request arena.
fn headersWithEtag(alloc: std.mem.Allocator, etag: []const u8) ![]http.Header {
    const hs = try alloc.alloc(http.Header, 2);
    hs[0] = .{ .name = "ETag", .value = etag };
    hs[1] = nosniff;
    return hs;
}

fn notModified(headers: []const http.Header) http.Response {
    return .{ .status = 304, .body = "", .content_type = "text/plain", .extra_headers = headers };
}

/// True when the request's If-None-Match matches this entity tag ("*" or exact).
fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    if (if_none_match.len == 0) return false;
    if (std.mem.eql(u8, if_none_match, "*")) return true;
    // A client may send a comma-separated list of tags.
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), etag)) return true;
    }
    return false;
}

fn findEmbedded(files: []const StaticFile, rel: []const u8) ?*const StaticFile {
    for (files) |*f| {
        if (std.mem.eql(u8, f.path, rel)) return f;
    }
    return null;
}

fn serveEmbedded(ctx: *http.RequestCtx, files: []const StaticFile, rel: []const u8) !?http.Response {
    const hit = blk: {
        if (rel.len == 0) break :blk findEmbedded(files, "index.html");
        if (findEmbedded(files, rel)) |f| break :blk f;
        // "/docs" -> "docs/index.html"
        const idx = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{rel});
        break :blk findEmbedded(files, idx);
    } orelse return null;
    const headers = try headersWithEtag(ctx.allocator, hit.etag);
    if (etagMatches(ctx.if_none_match, hit.etag)) return notModified(headers);
    return .{
        .status = 200,
        .body = hit.bytes,
        .content_type = mime.fromExtension(hit.path),
        .extra_headers = headers,
    };
}

/// Serve `ctx.path` from `source`. Returns null when no file matches (the caller
/// emits its 404), including for non-GET/HEAD methods and `.none` sources.
pub fn serve(io: std.Io, ctx: *http.RequestCtx, source: Source) !?http.Response {
    if (ctx.method != .GET and ctx.method != .HEAD) return null;
    if (std.meta.activeTag(source) == .none) return null;
    const rel = (try sanitize(ctx.allocator, ctx.path)) orelse return null;
    return switch (source) {
        .none => unreachable,
        .embedded => |files| serveEmbedded(ctx, files, rel),
        .dir => |root| serveDir(io, ctx, root, rel),
    };
}
```

For this task, stub `serveDir` so the module compiles (Task 3 implements it):

```zig
fn serveDir(io: std.Io, ctx: *http.RequestCtx, root: []const u8, rel: []const u8) !?http.Response {
    _ = io;
    _ = ctx;
    _ = root;
    _ = rel;
    return null;
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/static_files.zig src/root.zig src/http.zig
git commit -m "feat(static): static_files module — sanitization + embedded serving"
```

---

### Task 3: Directory-mode serving (stat, index resolution, ETag, sendFile)

**Files:**
- Modify: `src/static_files.zig` (replace the `serveDir` stub)

- [ ] **Step 1: Write the failing tests** — append to `src/static_files.zig`:

```zig
test "dir: serves files via file_path with ETag; index resolution; miss; traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/app.js", .data = "let x = 1;" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Use the tmp dir's absolute path as the static root.
    const root = try tmp.dir.realPathFromHandle(std.testing.io, arena.allocator());
    const src = Source{ .dir = root };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &ctx, src)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file_path != null);
    try std.testing.expect(std.mem.endsWith(u8, r.file_path.?, "assets/app.js"));
    try std.testing.expectEqual(@as(usize, 2), r.extra_headers.len);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    const etag = r.extra_headers[0].value;
    try std.testing.expect(etag.len > 2 and etag[0] == '"' and etag[etag.len - 1] == '"');

    // 304 round-trip with the produced ETag
    var again = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator(), .if_none_match = etag };
    try std.testing.expectEqual(@as(u16, 304), (try serve(std.testing.io, &again, src)).?.status);

    // "/" -> index.html
    var root_req = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    const ri = (try serve(std.testing.io, &root_req, src)).?;
    try std.testing.expect(std.mem.endsWith(u8, ri.file_path.?, "index.html"));

    // "/assets" is a directory without index.html -> null (404)
    var dir_req = http.RequestCtx{ .method = .GET, .path = "/assets", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &dir_req, src)) == null);

    // miss + traversal -> null
    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.css", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src)) == null);
    var trav = http.RequestCtx{ .method = .GET, .path = "/../secret", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &trav, src)) == null);
}
```

NOTE: `tmp.dir.realPathFromHandle` may not be the 0.16 name for "absolute path of this Dir". If it doesn't exist, grep `<zig lib>/std/Io/Dir.zig` and `<zig lib>/std/testing.zig` for `realPath`/`realpath` and use what's there; a fallback that always works is building the path from `tmp` internals the way other tests in this repo do — check `src/files/storage.zig:91-113` which uses `std.testing.tmpDir` and constructs paths relative to cwd (`.zig-cache/tmp/<sub_path>`). Mirror that existing pattern if needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: the new test fails (stub returns null for everything).

- [ ] **Step 3: Implement `serveDir`** (replace the stub):

```zig
/// Stat result for the ETag: "\"<mtime-hex>-<size-hex>\"". Returns null when the
/// path doesn't exist or isn't a regular file/dir we can serve.
fn serveDir(io: std.Io, ctx: *http.RequestCtx, root: []const u8, rel: []const u8) !?http.Response {
    // Resolve candidates: "" -> index.html; "<dir>" -> "<dir>/index.html" on directory hit.
    const first = if (rel.len == 0) "index.html" else rel;
    var full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ root, first });
    var st = std.Io.Dir.cwd().statFile(io, full) catch return null;
    if (st.kind == .directory) {
        full = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{full});
        st = std.Io.Dir.cwd().statFile(io, full) catch return null;
    }
    if (st.kind != .file) return null;
    const mtime: u128 = @bitCast(@as(i128, st.mtime));
    const etag = try std.fmt.allocPrint(ctx.allocator, "\"{x}-{x}\"", .{ mtime, st.size });
    const headers = try headersWithEtag(ctx.allocator, etag);
    if (etagMatches(ctx.if_none_match, etag)) return notModified(headers);
    return .{
        .status = 200,
        .body = "",
        .content_type = mime.fromExtension(full),
        .file_path = full,
        .extra_headers = headers,
    };
}
```

API verification (do this BEFORE wrestling with compile errors): grep the 0.16 std for the stat call and its field names:

```bash
ZIG_LIB=$(mise exec zig@0.16.0 -- zig env | grep lib_dir | cut -d'"' -f4 2>/dev/null || mise exec zig@0.16.0 -- zig env --json | python3 -c "import json,sys; print(json.load(sys.stdin)['lib_dir'])")
grep -n "pub fn statFile\|pub fn stat\b" "$ZIG_LIB/std/Io/Dir.zig"
grep -n "mtime\|kind\|size" "$ZIG_LIB/std/Io/Dir.zig" | head
```

Adjust the call/field names (`statFile` vs `statAt`, `st.mtime` type, `st.kind` enum) to whatever the 0.16 stdlib actually exposes. Keep the ETag format `"<mtime-hex>-<size-hex>"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/static_files.zig
git commit -m "feat(static): directory-mode serving with ETag/304 and sendFile streaming"
```

---

### Task 4: Server wiring — root fallback dispatch

**Files:**
- Modify: `src/server.zig` (fallback + If-None-Match capture + 304 status)
- Modify: `src/app.zig` (runtime `static_source` field)

- [ ] **Step 1: Add the runtime field** in `src/app.zig`, after the `sentry_dsn` field (line 19):

```zig
    /// Static-file source resolved by framework.serveImpl (.none = no static serving).
    static_source: @import("static_files.zig").Source = .none,
```

- [ ] **Step 2: Wire the fallback** in `src/server.zig`:

Add the import (after line 14, `const admin = ...`):

```zig
const static_files = @import("static_files.zig");
```

Capture the header in `onRequest` (after line 177, `ctx.content_type = ...`):

```zig
    ctx.if_none_match = r.getHeader("if-none-match") orelse "";
```

Add `304 => .not_modified,` to the switch in `setZapStatus` (after the `204 => .no_content,` line). Verify the zap enum tag exists: `grep -n "not_modified" vendor/../zig-pkg 2>/dev/null || grep -rn "not_modified" $(find ~ -path "*zap*http*" -name "*.zig" 2>/dev/null | head -1)` — simplest reliable check: `grep -rn "not_modified" "$(mise exec zig@0.16.0 -- zig env | grep -o '/[^"]*p/zap[^"]*' | head -1)" 2>/dev/null` or just compile and read the error which lists valid tags.

Insert the static fallback in the `blk:` dispatch (between the `dispatchCustom` line 199 and the `notFound` line 200):

```zig
        if (dispatchCustom(&ctx) catch null) |hit| break :blk hit;
        if (std.meta.activeTag(self.app.static_source) != .none and
            (ctx.method == .GET or ctx.method == .HEAD) and
            !std.mem.startsWith(u8, ctx.path, "/api/"))
        {
            if (static_files.serve(self.app.io, &ctx, self.app.static_source) catch null) |hit| break :blk hit;
            break :blk http.Response{ .status = 404, .body = "not found", .content_type = "text/plain; charset=utf-8" };
        }
        break :blk ApiError.notFound().toResponse(arena.allocator()) catch {
```

- [ ] **Step 3: Build + run unit tests**

Run: `mise exec zig@0.16.0 -- zig build test --summary all && mise exec zig@0.16.0 -- zig build`
Expected: PASS / clean build.

- [ ] **Step 4: Commit**

```bash
git add src/server.zig src/app.zig
git commit -m "feat(static): root-fallback static dispatch in the HTTP server"
```

---

### Task 5: Comptime `.static_files` config + serveImpl resolution

**Files:**
- Modify: `src/framework.zig`
- Modify: `src/config.zig` (add `static_dir`)
- Modify: `src/root.zig` (export `StaticFile`)

- [ ] **Step 1: Write the failing tests** — append to `src/framework.zig`:

```zig
test "App(cfg) static_files modes: default, disabled, dir, embedded (with coercion)" {
    const static_files = @import("static_files.zig");
    try std.testing.expectEqual(static_files.Mode.default, std.meta.activeTag(App(.{}).static_mode));
    try std.testing.expectEqual(static_files.Mode.disabled, std.meta.activeTag(App(.{ .static_files = .disabled }).static_mode));

    const D = App(.{ .static_files = .{ .dir = "frontend/dist" } });
    try std.testing.expectEqual(static_files.Mode.dir, std.meta.activeTag(D.static_mode));
    try std.testing.expectEqualStrings("frontend/dist", D.static_mode.dir);

    // Embedded manifests are generated modules that declare their OWN struct type;
    // the builder coerces any slice of {path,bytes,etag} structs.
    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{.{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" }};
    };
    const E = App(.{ .static_files = .{ .embedded = &manifest.files } });
    try std.testing.expectEqual(static_files.Mode.embedded, std.meta.activeTag(E.static_mode));
    try std.testing.expectEqual(@as(usize, 1), E.static_mode.embedded.len);
    try std.testing.expectEqualStrings("index.html", E.static_mode.embedded[0].path);
    try std.testing.expectEqualStrings("\"abc\"", E.static_mode.embedded[0].etag);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: compile error, no `static_mode` decl.

- [ ] **Step 3: Implement in `src/framework.zig`:**

Add the import at the top (after `const ratelimit = ...`):

```zig
const static_files = @import("static_files.zig");
```

Add `"static_files"` to the `allowed` tuple (line 101).

Add inside `App(...)`'s returned struct (after the `MailerPlugin` decl, line 157):

```zig
        /// Comptime static-files mode (see static_files.Mode). Field absent -> .default,
        /// which enables the runtime `--serve-static <dir>` flag on `serve`.
        pub const static_mode: static_files.Mode = blk: {
            if (!@hasField(@TypeOf(cfg), "static_files")) break :blk .default;
            const sf = cfg.static_files;
            const T = @TypeOf(sf);
            if (T == @TypeOf(.enum_literal)) {
                if (std.mem.eql(u8, @tagName(sf), "disabled")) break :blk .disabled;
                @compileError("static_files: unknown value '." ++ @tagName(sf) ++ "'; expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
            }
            if (@hasField(T, "dir")) break :blk .{ .dir = sf.dir };
            if (@hasField(T, "embedded")) {
                // Coerce the generated manifest's structurally-identical struct type
                // into static_files.StaticFile (the generated module can't import it).
                const src = sf.embedded;
                var out: [src.len]static_files.StaticFile = undefined;
                for (src, 0..) |f, i| out[i] = .{ .path = f.path, .bytes = f.bytes, .etag = f.etag };
                const final = out;
                break :blk .{ .embedded = &final };
            }
            @compileError("static_files: expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
        };
```

Add the field to `Opts` (the `ServeOpts` literal, line 177):

```zig
            .static_mode = static_mode,
```

Add the field to `ServeOpts` (line 200):

```zig
    static_mode: static_files.Mode = .default,
```

In `serveImpl`, resolve and validate the source (insert after the rate_limiter block, before `var app = ...`):

```zig
    // Resolve the static-file source from the comptime mode (+ --serve-static in
    // default mode). A configured-but-missing dir is a fatal startup error.
    const static_source: static_files.Source = switch (opts.static_mode) {
        .disabled => .none,
        .dir => |d| .{ .dir = d },
        .embedded => |fs2| .{ .embedded = fs2 },
        .default => if (cfg.static_dir.len > 0) static_files.Source{ .dir = cfg.static_dir } else .none,
    };
    if (std.meta.activeTag(static_source) == .dir) {
        var probe = std.Io.Dir.cwd().openDir(io, static_source.dir, .{}) catch {
            std.log.err("static dir '{s}' is missing or unreadable (from {s})", .{
                static_source.dir,
                if (std.meta.activeTag(opts.static_mode) == .dir) "comptime .static_files" else "--serve-static",
            });
            return error.StaticDirUnavailable;
        };
        probe.close(io);
    }
```

(`openDir`/`close` signatures: same verification drill as Task 3 — grep `$ZIG_LIB/std/Io/Dir.zig`.)

And set it on the app struct literal (after `.sentry_dsn = cfg.sentry_dsn,`):

```zig
        .static_source = static_source,
```

- [ ] **Step 4: Add `static_dir` to `src/config.zig`** — after the `sentry_dsn` field:

```zig
    // Static-file root for the default (runtime-flag) mode; set by `--serve-static`.
    // "" = no static serving. Comptime modes (.dir/.embedded/.disabled) ignore it.
    static_dir: []const u8 = "",
```

- [ ] **Step 5: Export the manifest struct type from `src/root.zig`** (after the `Migration` export):

```zig
// Static files: the entry type of a build-generated embedded manifest (see
// build.zig embedStaticDir) and of `.static_files = .{ .embedded = ... }`.
pub const StaticFile = @import("static_files.zig").StaticFile;
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/framework.zig src/config.zig src/root.zig
git commit -m "feat(static): comptime .static_files config with default/disabled/dir/embedded modes"
```

---

### Task 6: CLI `--serve-static` flag (default mode only)

**Files:**
- Modify: `src/cli.zig`
- Modify: `src/framework.zig` (`loadCfg`, `runCliImpl`, help text)

- [ ] **Step 1: Write the failing tests** — append to `src/cli.zig`:

```zig
test "serve parses --serve-static when enabled" {
    const cmd = try parse(&.{ "serve", "--serve-static", "public" }, .{});
    try std.testing.expectEqualStrings("public", cmd.serve.serve_static.?);
}

test "--serve-static is an unknown flag when disabled at comptime" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--serve-static", "public" }, .{ .serve_static = false }));
}

test "--serve-static without a value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--serve-static" }, .{}));
}
```

- [ ] **Step 2: Implement in `src/cli.zig`:**

Add to `ServeArgs`:

```zig
    serve_static: ?[]const u8 = null,
```

Add an options struct and change the `parse` signature:

```zig
/// Comptime-derived parser switches. `serve_static` is true only in the default
/// static-files mode — in .disabled/.dir/.embedded the flag is rejected as unknown.
pub const ParseOpts = struct {
    serve_static: bool = true,
};

pub fn parse(args: []const []const u8, popts: ParseOpts) ParseError!Command {
```

In the serve flag loop, add before the final `else`:

```zig
        } else if (popts.serve_static and std.mem.eql(u8, a, "--serve-static")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.serve_static = args[i];
```

Update EVERY existing `parse(&.{...})` call in the tests of `src/cli.zig` to `parse(&.{...}, .{})`.

- [ ] **Step 3: Update `src/framework.zig`:**

`runCliImpl` call site (line 219):

```zig
    const cmd = cli.parse(args[1..], .{ .serve_static = std.meta.activeTag(opts.static_mode) == .default }) catch |err| {
```

`loadCfg` (line 369) gains:

```zig
    if (sa.serve_static) |v| cfg.static_dir = v;
```

`printServeUsage` becomes parameterized — change the signature to `fn printServeUsage(show_serve_static: bool) void`, keep the existing single `std.debug.print` for the current text but split so the FLAGS section can include the extra line:

```zig
fn printServeUsage(show_serve_static: bool) void {
    std.debug.print(
        \\zigbase serve — start the HTTP server (REST API + WebSocket + admin UI at /_/).
        \\
        \\USAGE:
        \\  zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]{s}
        \\
        \\FLAGS:
        \\  --http-host H    Address to bind.    [env ZIGBASE_HTTP_HOST, default 0.0.0.0]
        \\  --http-port N    TCP port to listen. [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
    , .{if (show_serve_static) " [--serve-static DIR]" else ""});
    if (show_serve_static) std.debug.print(
        \\  --serve-static DIR  Serve static files from DIR at the root path (anything
        \\                      not matching /api/, /_/, or custom routes). [default: off]
        \\
    , .{});
    std.debug.print(
        \\KEY ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET      Token-signing secret. REQUIRED in production; the server refuses
        \\                         to start with the insecure default while ZIGBASE_COOKIE_SECURE is on.
        \\  ZIGBASE_COOKIE_SECURE  Secure flag on auth cookies (true/1). Enable behind HTTPS. [default false]
        \\  ZIGBASE_SENTRY_DSN     Sentry DSN for error reporting; empty logs to stderr.
        \\  (See `zigbase help` for the full list of ZIGBASE_* variables.)
        \\
        \\EXAMPLE:
        \\  ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" zigbase serve --http-port 9000 --data-dir ./zb_data
        \\
    , .{});
}
```

Update both call sites of `printServeUsage()` in `runCliImpl` to `printServeUsage(std.meta.activeTag(opts.static_mode) == .default)`.

Also add one line to `printUsage()`'s COMMON FLAGS block (it's mode-independent text for the stock binary, which IS default mode — keep it generic):

```
        \\  --serve-static DIR  Serve static files from DIR at the root path (serve only;
        \\                      available unless the app hardcodes static files at comptime).
```

- [ ] **Step 4: Run tests + manual smoke**

```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --help   # shows --serve-static
```
Expected: PASS; help shows the new flag.

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig src/framework.zig
git commit -m "feat(static): --serve-static CLI flag, gated to the default comptime mode"
```

---

### Task 7: Integration test — runtime mode end-to-end

**Files:**
- Create: `tests/admin/test_static_files.py`

- [ ] **Step 1: Write the test:**

```python
import socket, subprocess, tempfile, time, os, pathlib, urllib.request, urllib.error

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def _wait_up(url, deadline_s=20):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                return r
        except urllib.error.HTTPError:
            return None  # server is up, request just 4xx'd
        except Exception:
            time.sleep(0.2)
    raise AssertionError("server did not come up")


def _get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def test_serve_static_runtime_mode():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    binary = REPO / "zig-out" / "bin" / "zigbase"
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>hello static</h1>")
        (pub / "assets").mkdir()
        (pub / "assets" / "app.js").write_text("console.log('hi')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # index.html at /
            st, hdr, body = _get(f"{base}/")
            assert st == 200 and b"hello static" in body
            assert "text/html" in hdr.get("Content-Type", "")

            # asset with content type + ETag, then 304
            st, hdr, body = _get(f"{base}/assets/app.js")
            assert st == 200 and b"console.log" in body
            etag = hdr.get("ETag")
            assert etag and etag.startswith('"')
            st, _, _ = _get(f"{base}/assets/app.js", {"If-None-Match": etag})
            assert st == 304

            # static miss -> plain 404 (not the JSON envelope)
            st, hdr, _ = _get(f"{base}/missing.css")
            assert st == 404
            assert "application/json" not in hdr.get("Content-Type", "")

            # /api/ miss keeps the JSON envelope
            st, hdr, body = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in hdr.get("Content-Type", "")

            # traversal blocked
            st, _, _ = _get(f"{base}/..%2f..%2fetc%2fpasswd")
            assert st in (400, 404)

            # admin UI still wins over static
            st, hdr, _ = _get(f"{base}/_/")
            assert st == 200 and "text/html" in hdr.get("Content-Type", "")
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_serve_static_missing_dir_is_fatal():
    binary = REPO / "zig-out" / "bin" / "zigbase"
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", "/nonexistent/static/dir"],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        assert proc.wait(timeout=20) != 0
```

- [ ] **Step 2: Run it**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q`
Expected: PASS. (If python/pytest are missing, install per `tests/admin` conventions: `mise exec python@3.13 -- python -m pip install pytest`.)

Note: the URL-encoded traversal test documents current behavior — zap decodes the path before we see it; whichever of 400/404 comes back, what matters is that no file outside the root is served.

- [ ] **Step 3: Commit**

```bash
git add tests/admin/test_static_files.py
git commit -m "test(static): end-to-end runtime --serve-static integration coverage"
```

---

### Task 8: `embedStaticDir` build helper

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Implement.** Append to `build.zig` (top-level, after `pub fn build`):

```zig
/// Embed every file under `dir_rel` (relative to the consumer's build root) into
/// the binary as a static-asset manifest module. Wire it up like:
///
///     const zigbase_build = @import("zigbase");                  // dep's build.zig
///     const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
///     exe_mod.addImport("static_assets", assets);
///
/// and in main.zig:
///
///     .static_files = .{ .embedded = &@import("static_assets").files }
///
/// The generated module declares `pub const files = [_]StaticFile{...}` with one
/// `@embedFile` per asset and a precomputed CRC32 content ETag.
pub fn embedStaticDir(b: *std.Build, dir_rel: []const u8) *std.Build.Module {
    const alloc = b.allocator;
    var dir = b.build_root.handle.openDir(dir_rel, .{ .iterate = true }) catch
        std.debug.panic("embedStaticDir: cannot open '{s}' — build the frontend first (e.g. `cd {s}/.. && npm run build`)", .{ dir_rel, dir_rel });
    defer dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(alloc) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next() catch |e| std.debug.panic("embedStaticDir: walk failed: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .file) continue;
        names.append(alloc, alloc.dupe(u8, entry.path) catch @panic("OOM")) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(alloc,
        \\//! Generated by zigbase's embedStaticDir — do not edit.
        \\pub const StaticFile = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        \\pub const files = [_]StaticFile{
        \\
    ) catch @panic("OOM");
    for (names.items) |rel| {
        _ = wf.addCopyFile(b.path(b.fmt("{s}/{s}", .{ dir_rel, rel })), rel);
        const data = dir.readFileAlloc(alloc, rel, 64 << 20) catch |e|
            std.debug.panic("embedStaticDir: cannot read '{s}/{s}': {s}", .{ dir_rel, rel, @errorName(e) });
        defer alloc.free(data);
        const crc = std.hash.Crc32.hash(data);
        src.appendSlice(alloc, b.fmt(
            "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\"), .etag = \"\\\"{x:0>8}\\\"\" }},\n",
            .{ rel, rel, crc },
        )) catch @panic("OOM");
    }
    src.appendSlice(alloc, "};\n") catch @panic("OOM");
    const manifest = wf.add("static_assets.zig", src.items);
    return b.createModule(.{ .root_source_file = manifest });
}
```

API caveats to verify while implementing (build.zig runs as a normal program; `b.build_root.handle` is a `std.fs.Dir` in 0.16's build system — but CHECK, the std.fs → std.Io migration may have touched it):

```bash
ZIG_LIB=$(mise exec zig@0.16.0 -- zig env | grep -oP '(?<="lib_dir": ")[^"]*' || true)
grep -n "handle" "$ZIG_LIB/std/Build.zig" | head -5          # type of build_root.handle
grep -n "pub fn walk\|pub fn readFileAlloc\|pub fn openDir" "$ZIG_LIB/std/fs/Dir.zig" 2>/dev/null | head
grep -rn "pub fn addCopyFile\|pub fn add\b" "$ZIG_LIB/std/Build/Step/WriteFile.zig" | head
```

Adjust signatures to match (e.g. `readFileAlloc` argument order, `walk` allocator position). Asset filenames are assumed not to contain `"` or `\` (true for Astro/Vite output); paths from `walk()` on Linux are '/'-separated, matching request paths.

- [ ] **Step 2: Verify `build.zig` still compiles**

Run: `mise exec zig@0.16.0 -- zig build`
Expected: clean build (the helper is compiled as part of build.zig even if uncalled).

Full exercise happens in Task 10 (plugins example). If you want a smoke test now:

```bash
mkdir -p /tmp/zb_embed_smoke && echo "<p>x</p>" > /tmp/zb_embed_smoke/index.html
# (optional) point a scratch consumer at it; otherwise rely on Task 10.
```

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "feat(static): embedStaticDir build helper generating @embedFile manifests"
```

---

### Task 9: Blog example — comptime schema + Astro frontend (runtime mode)

The blog demonstrates the DEFAULT mode: built frontend served with `--serve-static frontend/dist`.

**Files:**
- Modify: `examples/blog/src/main.zig` (add `.collections`)
- Create: `examples/blog/frontend/package.json`
- Create: `examples/blog/frontend/astro.config.mjs`
- Create: `examples/blog/frontend/tsconfig.json`
- Create: `examples/blog/frontend/.gitignore`
- Create: `examples/blog/frontend/src/lib/api.ts`
- Create: `examples/blog/frontend/src/styles/global.css`
- Create: `examples/blog/frontend/src/layouts/Layout.astro`
- Create: `examples/blog/frontend/src/components/PostList.tsx`
- Create: `examples/blog/frontend/src/components/PostView.tsx`
- Create: `examples/blog/frontend/src/components/Editor.tsx`
- Create: `examples/blog/frontend/src/pages/index.astro`
- Create: `examples/blog/frontend/src/pages/post.astro`
- Create: `examples/blog/frontend/src/pages/write.astro`
- Modify: `examples/blog/README.md`

- [ ] **Step 1: Add the comptime schema** so the frontend works out of the box. In `examples/blog/src/main.zig`, change the `App(.{...})` config to:

```zig
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
        },
        // Provisioned at startup (additive auto-migration): an auth collection with
        // open signup, and public posts readable only when published.
        .collections = .{
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "", .view = "", .create = "", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            },
            .posts = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 200 },
                    .{ .name = "slug", .type = .text, .max = 220 },
                    .{ .name = "body", .type = .text, .max = 20000 },
                    .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
                },
                .rules = .{
                    .list = "status = \"published\"",
                    .view = "status = \"published\"",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id != \"\"",
                    .delete = "@request.auth.id != \"\"",
                },
            },
        },
    }).runCli(init);
```

Also update the doc comment at the top of the file to mention the schema and frontend.

Verify it builds: `cd examples/blog && mise exec zig@0.16.0 -- zig build`

- [ ] **Step 2: Scaffold the frontend.** Create the files below verbatim.

`examples/blog/frontend/package.json`:

```json
{
  "name": "zigbase-blog-frontend",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview"
  },
  "dependencies": {
    "@astrojs/react": "^4.2.0",
    "astro": "^5.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "typescript": "^5.6.0"
  }
}
```

`examples/blog/frontend/astro.config.mjs`:

```js
// @ts-check
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

export default defineConfig({
  integrations: [react()],
  vite: {
    // `astro dev` proxies API calls to a locally running blog backend so the
    // islands work in dev; the production build is same-origin (served by the
    // blog binary itself via --serve-static).
    server: { proxy: { '/api': 'http://127.0.0.1:8090' } },
  },
});
```

`examples/blog/frontend/tsconfig.json`:

```json
{
  "extends": "astro/tsconfigs/strict",
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "react"
  }
}
```

`examples/blog/frontend/.gitignore`:

```
node_modules/
dist/
.astro/
```

`examples/blog/frontend/src/lib/api.ts`:

```ts
// Tiny same-origin client for the ZigBase records/auth API.
const TOKEN_KEY = 'blog_token';

export type Post = {
  id: string;
  title: string;
  slug: string;
  body: string;
  status: string;
  created: string;
};

export function token(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function logout(): void {
  localStorage.removeItem(TOKEN_KEY);
}

async function req(path: string, init: RequestInit = {}): Promise<any> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers['Authorization'] = `Bearer ${t}`;
  if (init.body) headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { ...init, headers });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function login(email: string, password: string): Promise<void> {
  const out = await req('/api/collections/users/auth-with-password', {
    method: 'POST',
    body: JSON.stringify({ identity: email, password }),
  });
  localStorage.setItem(TOKEN_KEY, out.token);
}

export async function signup(email: string, password: string): Promise<void> {
  await req('/api/collections/users/records', {
    method: 'POST',
    body: JSON.stringify({ email, password, passwordConfirm: password }),
  });
  await login(email, password);
}

export async function listPosts(): Promise<Post[]> {
  const out = await req('/api/collections/posts/records?sort=-created');
  return out.items;
}

export async function getPost(slug: string): Promise<Post | null> {
  const filter = encodeURIComponent(`slug = "${slug}"`);
  const out = await req(`/api/collections/posts/records?filter=${filter}`);
  return out.items[0] ?? null;
}

export async function createPost(title: string, body: string): Promise<Post> {
  return req('/api/collections/posts/records', {
    method: 'POST',
    body: JSON.stringify({ title, body, status: 'published' }),
  });
}
```

IMPORTANT verification while implementing: confirm against `docs/api.md` that (a) the password-auth body field is `identity` (it is, per docs/recipes.md), (b) signup on an auth collection uses `password`/`passwordConfirm`, and (c) the auth response carries `token` at the top level. Adjust `api.ts` if the docs say otherwise.

`examples/blog/frontend/src/styles/global.css`:

```css
:root {
  --bg: #101216;
  --fg: #e8eaf0;
  --muted: #9aa3b2;
  --accent: #f7a41d;
  --card: #1a1d24;
  font-family: system-ui, -apple-system, sans-serif;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); line-height: 1.6; }
main { max-width: 720px; margin: 0 auto; padding: 2rem 1rem; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
header.site { border-bottom: 1px solid #2a2e38; }
header.site nav { max-width: 720px; margin: 0 auto; padding: 1rem; display: flex; gap: 1.25rem; align-items: baseline; }
header.site .brand { font-weight: 700; font-size: 1.1rem; color: var(--fg); }
.card { background: var(--card); border: 1px solid #2a2e38; border-radius: 8px; padding: 1rem 1.25rem; margin: 0.75rem 0; }
.muted { color: var(--muted); font-size: 0.9rem; }
input, textarea { width: 100%; padding: 0.5rem; margin: 0.25rem 0 0.75rem; background: #0c0e12; color: var(--fg); border: 1px solid #2a2e38; border-radius: 6px; font: inherit; }
button { background: var(--accent); color: #101216; border: 0; border-radius: 6px; padding: 0.5rem 1rem; font-weight: 600; cursor: pointer; }
button:disabled { opacity: 0.5; cursor: default; }
.error { color: #ff6b6b; }
```

`examples/blog/frontend/src/layouts/Layout.astro`:

```astro
---
import '../styles/global.css';
const { title = 'ZigBase Blog' } = Astro.props;
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
  </head>
  <body>
    <header class="site">
      <nav>
        <a class="brand" href="/">ZigBase Blog</a>
        <a href="/write">Write</a>
        <a href="/_/" data-astro-reload>Admin</a>
      </nav>
    </header>
    <main><slot /></main>
  </body>
</html>
```

`examples/blog/frontend/src/components/PostList.tsx`:

```tsx
import { useEffect, useState } from 'react';
import { listPosts, type Post } from '../lib/api';

export default function PostList() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listPosts().then(setPosts).catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">Failed to load posts: {error}</p>;
  if (!posts) return <p className="muted">Loading…</p>;
  if (posts.length === 0)
    return <p className="muted">No posts yet — <a href="/write">write the first one</a>.</p>;
  return (
    <>
      {posts.map((p) => (
        <article className="card" key={p.id}>
          <h2><a href={`/post?slug=${encodeURIComponent(p.slug)}`}>{p.title}</a></h2>
          <p className="muted">{new Date(p.created).toLocaleDateString()}</p>
          <p>{p.body.slice(0, 200)}{p.body.length > 200 ? '…' : ''}</p>
        </article>
      ))}
    </>
  );
}
```

`examples/blog/frontend/src/components/PostView.tsx`:

```tsx
import { useEffect, useState } from 'react';
import { getPost, type Post } from '../lib/api';

export default function PostView() {
  const [post, setPost] = useState<Post | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const slug = new URLSearchParams(location.search).get('slug') ?? '';
    getPost(slug).then(setPost).catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (post === undefined) return <p className="muted">Loading…</p>;
  if (post === null) return <p className="muted">Post not found. <a href="/">Back home</a></p>;
  return (
    <article>
      <h1>{post.title}</h1>
      <p className="muted">{new Date(post.created).toLocaleString()}</p>
      {post.body.split(/\n\n+/).map((para, i) => <p key={i}>{para}</p>)}
    </article>
  );
}
```

`examples/blog/frontend/src/components/Editor.tsx`:

```tsx
import { useState } from 'react';
import { login, signup, createPost, token, logout } from '../lib/api';

export default function Editor() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); } catch (e: any) { setError(e.message); } finally { setBusy(false); }
  }

  if (!authed) {
    return (
      <div className="card">
        <h2>Sign in to write</h2>
        <input placeholder="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
        <button disabled={busy} onClick={() => run(async () => { await login(email, password); setAuthed(true); })}>Log in</button>{' '}
        <button disabled={busy} onClick={() => run(async () => { await signup(email, password); setAuthed(true); })}>Sign up</button>
        {error && <p className="error">{error}</p>}
      </div>
    );
  }

  return (
    <div className="card">
      <h2>New post <button className="muted" onClick={() => { logout(); setAuthed(false); }}>log out</button></h2>
      <input placeholder="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
      <textarea placeholder="Write your post…" rows={10} value={body} onChange={(e) => setBody(e.target.value)} />
      <button
        disabled={busy || !title}
        onClick={() => run(async () => {
          const post = await createPost(title, body);
          setDone(post.slug); setTitle(''); setBody('');
        })}
      >
        Publish
      </button>
      {done && <p>Published! <a href={`/post?slug=${encodeURIComponent(done)}`}>View it</a> (slug was derived by the server-side hook).</p>}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
```

`examples/blog/frontend/src/pages/index.astro`:

```astro
---
import Layout from '../layouts/Layout.astro';
import PostList from '../components/PostList.tsx';
---
<Layout title="ZigBase Blog">
  <h1>Latest posts</h1>
  <p class="muted">
    Served by the <code>blog</code> binary itself: the Astro build output is
    handed to <code>--serve-static frontend/dist</code> — ZigBase's default
    runtime static-files mode.
  </p>
  <PostList client:load />
</Layout>
```

`examples/blog/frontend/src/pages/post.astro`:

```astro
---
import Layout from '../layouts/Layout.astro';
import PostView from '../components/PostView.tsx';
---
<Layout title="Post — ZigBase Blog">
  <PostView client:load />
</Layout>
```

`examples/blog/frontend/src/pages/write.astro`:

```astro
---
import Layout from '../layouts/Layout.astro';
import Editor from '../components/Editor.tsx';
---
<Layout title="Write — ZigBase Blog">
  <h1>Write a post</h1>
  <p class="muted">
    Publishing exercises the example's <code>beforeCreate</code> hook: leave the
    slug out and the server derives it from the title.
  </p>
  <Editor client:load />
</Layout>
```

- [ ] **Step 3: Build the frontend**

```bash
cd examples/blog/frontend && npm install && npm run build
```
Expected: `dist/` with `index.html`, `post/index.html` (or `post.html`), `write/…`, and `_astro/` assets. If node/npm is missing, install via mise: `mise use -g node@22` (memory: prefer mise for tool installs).

- [ ] **Step 4: End-to-end smoke**

```bash
cd examples/blog && mise exec zig@0.16.0 -- zig build
ZIGBASE_JWT_SECRET=devsecret-not-default ./zig-out/bin/blog serve --data-dir /tmp/blog_data --http-port 8091 --serve-static frontend/dist &
sleep 2
curl -s http://127.0.0.1:8091/ | grep -i "zigbase blog"        # index served
curl -s http://127.0.0.1:8091/api/blog/ping                    # {"pong":true}
curl -s -X POST http://127.0.0.1:8091/api/collections/users/records \
  -H 'Content-Type: application/json' \
  -d '{"email":"w@x.io","password":"password123","passwordConfirm":"password123"}'   # signup works (open create rule)
kill %1; rm -rf /tmp/blog_data
```
Expected: HTML containing the page, pong JSON, and a created user record.

- [ ] **Step 5: Update `examples/blog/README.md`** — add a section (adapt the existing README's voice):

```markdown
## Frontend (Astro + React islands)

`frontend/` is an Astro site with React islands: a public post list/detail and a
login + "write a post" island that exercises the `slugify` hook. The example's
comptime `.collections` schema (users + posts) provisions itself on startup, so
the whole thing works from a fresh data dir.

```sh
cd frontend && npm install && npm run build && cd ..
zig build
ZIGBASE_JWT_SECRET=... ./zig-out/bin/blog serve --serve-static frontend/dist
# open http://127.0.0.1:8090/
```

This demonstrates ZigBase's **default static-files mode**: the binary serves
`frontend/dist` at the root path because you passed `--serve-static`. The other
modes (comptime-hardcoded dir, fully embedded) are shown by the golfsim and
plugins examples.
```

- [ ] **Step 6: Commit**

```bash
git add examples/blog
git commit -m "feat(blog-example): comptime schema + Astro/React frontend served via --serve-static"
```

---

### Task 10: Golfsim example — comptime schema + frontend (hardcoded-dir mode)

**Files:**
- Modify: `examples/golfsim/src/main.zig` (add `.collections` + `.static_files`)
- Create: `examples/golfsim/frontend/*` (same scaffold shape as blog)
- Modify: `examples/golfsim/README.md`

- [ ] **Step 1: Add schema + static mode** in `examples/golfsim/src/main.zig`. Replace the `App(.{...})` config with:

```zig
    return zigbase.App(.{
        .hooks = .{ .bookings = .{ .beforeCreate = prepareBooking } },
        .routes = .{
            .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
            .{ .method = .GET, .path = "/api/golfsim/health", .handler = health, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{
                .name = "expire-holds",
                .schedule = zigbase.schedule.Schedule{ .interval = .{ .minutes = 15 } },
                .handler = expireHolds,
            },
        },
        // Comptime-hardcoded static dir: the Astro frontend in frontend/dist is
        // served at the root path, no flag needed (and --serve-static is rejected).
        .static_files = .{ .dir = "frontend/dist" },
        // The schema the hooks/route/cron reference, provisioned at startup.
        // Mirrors the runtime-provisioning recipe in docs/recipes.md.
        .collections = .{
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "", .view = "", .create = "", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            },
            .simulators = .{
                .fields = .{
                    .{ .name = "label", .type = .text, .required = true, .max = 120 },
                    .{ .name = "owner", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                },
                .rules = .{ .list = "", .view = "", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
            },
            .listings = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 140 },
                    .{ .name = "price_per_hour", .type = .number, .required = true },
                    .{ .name = "status", .type = .select, .required = true, .values = .{ "draft", "published", "archived" } },
                    .{ .name = "simulator", .type = .relation, .target = "simulators", .required = true, .cascadeDelete = true },
                },
                .rules = .{
                    .list = "status = \"published\"",
                    .view = "status = \"published\" || @request.auth.id = simulator.owner",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id = simulator.owner",
                    .delete = "@request.auth.id = simulator.owner",
                },
            },
            .bookings = .{
                .fields = .{
                    .{ .name = "listing", .type = .relation, .target = "listings", .required = true, .cascadeDelete = true },
                    .{ .name = "guest", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                    .{ .name = "starts_at", .type = .date, .required = true },
                    .{ .name = "ends_at", .type = .date, .required = true },
                    .{ .name = "price_total", .type = .number },
                    .{ .name = "status", .type = .select, .values = .{ "pending", "confirmed", "cancelled" } },
                },
                .rules = .{
                    .list = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner",
                    .view = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id = listing.simulator.owner",
                    .delete = "@request.auth.id = guest",
                },
            },
        },
    }).runCli(init);
```

Notes: `price_total` and `status` on bookings are NOT `.required` — the beforeCreate hook computes/stamps them, and required-field validation may run before hooks; if `zig build` + a create round-trip shows validation runs AFTER hooks, tightening them is optional, not required. Also update the module doc comment (lines 16-19) — the collections are now provisioned at comptime, not manually.

Verify: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build`

- [ ] **Step 2: Scaffold the frontend.** Same `package.json` (name `zigbase-golfsim-frontend`), `tsconfig.json`, `.gitignore`, and `global.css` as the blog (copy them; api proxy port stays 8090). `astro.config.mjs` identical to blog's.

`examples/golfsim/frontend/src/lib/api.ts`:

```ts
const TOKEN_KEY = 'golfsim_token';

export type Listing = {
  id: string;
  title: string;
  price_per_hour: number;
  status: string;
  simulator: string;
  expand?: { simulator?: { label: string } };
};

export type Booking = {
  id: string;
  listing: string;
  starts_at: string;
  ends_at: string;
  price_total: number;
  status: string;
  expand?: { listing?: Listing };
};

export function token(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function logout(): void {
  localStorage.removeItem(TOKEN_KEY);
}

async function req(path: string, init: RequestInit = {}): Promise<any> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers['Authorization'] = `Bearer ${t}`;
  if (init.body) headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { ...init, headers });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function login(email: string, password: string): Promise<void> {
  const out = await req('/api/collections/users/auth-with-password', {
    method: 'POST',
    body: JSON.stringify({ identity: email, password }),
  });
  localStorage.setItem(TOKEN_KEY, out.token);
}

export async function signup(email: string, password: string): Promise<void> {
  await req('/api/collections/users/records', {
    method: 'POST',
    body: JSON.stringify({ email, password, passwordConfirm: password }),
  });
  await login(email, password);
}

export async function listListings(): Promise<Listing[]> {
  const out = await req('/api/collections/listings/records?expand=simulator&sort=-created');
  return out.items;
}

export async function createBooking(listingId: string, startsAt: string, endsAt: string): Promise<Booking> {
  // The example's beforeCreate hook validates the listing, computes price_total,
  // stamps the guest from the auth token, and forces status=pending.
  return req('/api/collections/bookings/records', {
    method: 'POST',
    body: JSON.stringify({ listing: listingId, starts_at: startsAt, ends_at: endsAt }),
  });
}

export async function myBookings(): Promise<Booking[]> {
  // The list rule restricts results to the caller's own bookings.
  const out = await req('/api/collections/bookings/records?expand=listing&sort=-created');
  return out.items;
}

export async function confirmBooking(id: string): Promise<Booking> {
  // The example's custom business route.
  return req(`/api/bookings/${id}/confirm`, { method: 'POST' });
}
```

`examples/golfsim/frontend/src/components/Auth.tsx`:

```tsx
import { useState } from 'react';
import { login, signup } from '../lib/api';

export default function Auth({ onAuthed }: { onAuthed: () => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); onAuthed(); } catch (e: any) { setError(e.message); } finally { setBusy(false); }
  }

  return (
    <div className="card">
      <h2>Sign in to book</h2>
      <input placeholder="email" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button disabled={busy} onClick={() => run(() => login(email, password))}>Log in</button>{' '}
      <button disabled={busy} onClick={() => run(() => signup(email, password))}>Sign up</button>
      {error && <p className="error">{error}</p>}
    </div>
  );
}
```

`examples/golfsim/frontend/src/components/ListingsBrowser.tsx`:

```tsx
import { useEffect, useState } from 'react';
import { listListings, createBooking, token, type Listing } from '../lib/api';
import Auth from './Auth';

function BookForm({ listing }: { listing: Listing }) {
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [booked, setBooked] = useState<number | null>(null);

  async function book() {
    setBusy(true); setError(null);
    try {
      // datetime-local gives "YYYY-MM-DDTHH:MM"; the API wants RFC3339 seconds.
      const b = await createBooking(listing.id, `${start}:00Z`, `${end}:00Z`);
      setBooked(b.price_total);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (booked !== null)
    return <p>Booked! Total ${booked.toFixed(2)} — see <a href="/bookings">your bookings</a>.</p>;
  return (
    <div>
      <input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
      <input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} />
      <button disabled={busy || !start || !end} onClick={book}>Hold this slot</button>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

export default function ListingsBrowser() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [listings, setListings] = useState<Listing[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listListings().then(setListings).catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">Failed to load listings: {error}</p>;
  if (!listings) return <p className="muted">Loading…</p>;
  return (
    <>
      {!authed && <Auth onAuthed={() => setAuthed(true)} />}
      {listings.length === 0 && (
        <p className="muted">
          No published listings yet — create a simulator + listing via the
          <a href="/_/" data-astro-reload> admin UI</a> or the API (see the README's seed script).
        </p>
      )}
      {listings.map((l) => (
        <article className="card" key={l.id}>
          <h2>{l.title}</h2>
          <p className="muted">
            {l.expand?.simulator?.label ?? 'simulator'} · ${l.price_per_hour}/hour
          </p>
          {authed ? <BookForm listing={l} /> : <p className="muted">Sign in above to book.</p>}
        </article>
      ))}
    </>
  );
}
```

`examples/golfsim/frontend/src/components/MyBookings.tsx`:

```tsx
import { useEffect, useState } from 'react';
import { myBookings, confirmBooking, token, type Booking } from '../lib/api';
import Auth from './Auth';

export default function MyBookings() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [bookings, setBookings] = useState<Booking[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  function reload() {
    myBookings().then(setBookings).catch((e) => setError(e.message));
  }
  useEffect(() => {
    if (authed) reload();
  }, [authed]);

  if (!authed) return <Auth onAuthed={() => setAuthed(true)} />;
  if (error) return <p className="error">{error}</p>;
  if (!bookings) return <p className="muted">Loading…</p>;
  if (bookings.length === 0) return <p className="muted">No bookings yet — <a href="/">browse listings</a>.</p>;
  return (
    <>
      {bookings.map((b) => (
        <article className="card" key={b.id}>
          <h2>{b.expand?.listing?.title ?? b.listing}</h2>
          <p className="muted">
            {new Date(b.starts_at).toLocaleString()} → {new Date(b.ends_at).toLocaleString()} ·
            ${b.price_total?.toFixed?.(2) ?? b.price_total} · <strong>{b.status}</strong>
          </p>
          {b.status === 'pending' && (
            <button onClick={() => confirmBooking(b.id).then(reload).catch((e) => setError(e.message))}>
              Confirm (custom route)
            </button>
          )}
        </article>
      ))}
    </>
  );
}
```

`examples/golfsim/frontend/src/layouts/Layout.astro` — same as blog's but brand `GolfSim` and nav links `/` (Listings), `/bookings` (My bookings), `/_/` (Admin).

`examples/golfsim/frontend/src/pages/index.astro`:

```astro
---
import Layout from '../layouts/Layout.astro';
import ListingsBrowser from '../components/ListingsBrowser.tsx';
---
<Layout title="GolfSim — book a simulator">
  <h1>Book a golf simulator</h1>
  <p class="muted">
    This frontend ships with the binary's <strong>comptime-hardcoded</strong> static
    dir (<code>.static_files = .{'{'} .dir = "frontend/dist" {'}'}</code>) — no flag needed.
  </p>
  <ListingsBrowser client:load />
</Layout>
```

`examples/golfsim/frontend/src/pages/bookings.astro`:

```astro
---
import Layout from '../layouts/Layout.astro';
import MyBookings from '../components/MyBookings.tsx';
---
<Layout title="My bookings — GolfSim">
  <h1>My bookings</h1>
  <MyBookings client:load />
</Layout>
```

- [ ] **Step 3: Build + smoke**

```bash
cd examples/golfsim/frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
ZIGBASE_JWT_SECRET=devsecret-not-default ./zig-out/bin/golfsim serve --data-dir /tmp/golf_data --http-port 8092 &
sleep 2
curl -s http://127.0.0.1:8092/ | grep -i "golf"                          # frontend served (no flag!)
curl -s http://127.0.0.1:8092/api/golfsim/health                          # {"status":"ok",...}
./zig-out/bin/golfsim serve --serve-static x 2>&1 | grep -i "unknown" && echo FLAG-REJECTED-OK
kill %1; rm -rf /tmp/golf_data
```
Expected: HTML, health JSON, and the `--serve-static` flag rejected (UnknownFlag) because the mode is comptime-hardcoded. (The flag-rejection run exits before binding; run it after killing the server or with a different port.)

- [ ] **Step 4: Update `examples/golfsim/README.md`** — document the frontend, the comptime schema (the runtime-provisioning walk-through in the README/recipes is now optional — note the example self-provisions), and the mode:

```markdown
## Frontend (Astro + React islands)

`frontend/` is an Astro site whose React islands drive the whole booking flow:
sign in, browse published listings, hold a slot (the `beforeCreate` hook
validates the listing, computes `price_total`, stamps the guest, and forces
`status=pending`), then confirm it through the custom
`POST /api/bookings/:id/confirm` route.

```sh
cd frontend && npm install && npm run build && cd ..
zig build
ZIGBASE_JWT_SECRET=... ./zig-out/bin/golfsim serve
# open http://127.0.0.1:8090/  — no --serve-static needed
```

This demonstrates the **comptime-hardcoded** static mode:
`.static_files = .{ .dir = "frontend/dist" }` bakes the directory into the
binary's config, and `--serve-static` is rejected as an unknown flag. The
collections (users / simulators / listings / bookings) are provisioned at
startup from the comptime `.collections` schema.
```

- [ ] **Step 5: Commit**

```bash
git add examples/golfsim
git commit -m "feat(golfsim-example): comptime schema + booking frontend via hardcoded static dir"
```

---

### Task 11: Plugins example — embedded frontend + CI + integration test

**Files:**
- Modify: `examples/plugins/build.zig`, `examples/plugins/src/main.zig`
- Create: `examples/plugins/frontend/*`
- Modify: `examples/plugins/README.md` (if present; else the module doc comment)
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/admin/test_static_files.py` (embedded test)

- [ ] **Step 1: Frontend scaffold.** Same shape as blog (`package.json` name `zigbase-plugins-frontend`, same `astro.config.mjs`/`tsconfig.json`/`.gitignore`/`global.css`).

`examples/plugins/frontend/src/lib/api.ts`:

```ts
export type Author = { id: string; name: string; email?: string };
export type Post = { id: string; title: string; status: string; author: string; expand?: { author?: Author } };

async function req(path: string): Promise<any> {
  const r = await fetch(path);
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function listAuthors(): Promise<Author[]> {
  return (await req('/api/collections/authors/records?sort=name')).items;
}

export async function listPosts(): Promise<Post[]> {
  // Only status="published" is listable (the collection's comptime list rule).
  return (await req('/api/collections/posts/records?expand=author&sort=-created')).items;
}
```

`examples/plugins/frontend/src/components/Browser.tsx`:

```tsx
import { useEffect, useState } from 'react';
import { listAuthors, listPosts, type Author, type Post } from '../lib/api';

export default function Browser() {
  const [authors, setAuthors] = useState<Author[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([listAuthors(), listPosts()])
      .then(([a, p]) => { setAuthors(a); setPosts(p); })
      .catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (!authors || !posts) return <p className="muted">Loading…</p>;
  return (
    <>
      <section className="card">
        <h2>Authors ({authors.length})</h2>
        {authors.length === 0
          ? <p className="muted">None yet — add some via the <a href="/_/" data-astro-reload>admin UI</a>.</p>
          : <ul>{authors.map((a) => <li key={a.id}>{a.name}</li>)}</ul>}
      </section>
      <section className="card">
        <h2>Published posts ({posts.length})</h2>
        {posts.length === 0
          ? <p className="muted">None yet — only posts with status "published" appear here (the comptime list rule).</p>
          : <ul>{posts.map((p) => <li key={p.id}>{p.title} <span className="muted">by {p.expand?.author?.name ?? '?'}</span></li>)}</ul>}
      </section>
    </>
  );
}
```

`examples/plugins/frontend/src/pages/index.astro` (layout inline; this site is one page):

```astro
---
import '../styles/global.css';
import Browser from '../components/Browser.tsx';
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>ZigBase plugins example</title>
  </head>
  <body>
    <header class="site">
      <nav>
        <span class="brand">ZigBase plugins example</span>
        <a href="/_/" data-astro-reload>Admin</a>
      </nav>
    </header>
    <main>
      <h1>Everything in one binary</h1>
      <p class="muted">
        This page — HTML, JS, CSS — is <strong>compiled into the executable</strong>
        via <code>embedStaticDir</code> + <code>.static_files = .{'{'} .embedded = … {'}'}</code>.
        There is no frontend directory at runtime; delete <code>frontend/dist</code>
        after building and the site still serves.
      </p>
      <Browser client:load />
    </main>
  </body>
</html>
```

- [ ] **Step 2: Wire the embed into the example build.** `examples/plugins/build.zig` becomes:

```zig
const std = @import("std");
const zigbase_build = @import("zigbase");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("zigbase", zigbase.module("zigbase"));

    // Embed the built Astro frontend into the binary (fails with a clear message
    // if frontend/dist is missing — run `npm run build` in frontend/ first).
    const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
    exe_mod.addImport("static_assets", assets);

    const exe = b.addExecutable(.{ .name = "plugins", .root_module = exe_mod });
    b.installArtifact(exe);
}
```

In `examples/plugins/src/main.zig`, add to the `App(.{...})` config (after `.pools = ...`):

```zig
        // 5. fully embedded static frontend (see build.zig embedStaticDir)
        .static_files = .{ .embedded = &@import("static_assets").files },
```

and extend the module doc comment's numbered list with item 5.

NOTE: `@import("static_assets")` from the example's root module requires the import added in build.zig — that's what `exe_mod.addImport("static_assets", assets)` does. If `@import("zigbase")` inside the example's build.zig fails to resolve, ensure the dependency name in `examples/plugins/build.zig.zon` is `zigbase` (it is) — importing a dependency's build.zig by its zon name is standard Zig.

- [ ] **Step 3: Build + smoke**

```bash
cd examples/plugins/frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
mv frontend/dist /tmp/plugins_dist_parked      # prove assets are IN the binary
ZIGBASE_JWT_SECRET=devsecret-not-default ./zig-out/bin/plugins serve --data-dir /tmp/plug_data --http-port 8093 &
sleep 2
curl -s http://127.0.0.1:8093/ | grep -i "one binary"
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://127.0.0.1:8093/$(curl -s http://127.0.0.1:8093/ | grep -oP '_astro/[^"]+\.js' | head -1)
kill %1
mv /tmp/plugins_dist_parked frontend/dist
rm -rf /tmp/plug_data
```
Expected: page HTML served with `frontend/dist` absent; hashed JS asset 200 with `application/javascript`. Also verify `--serve-static x` is rejected.

- [ ] **Step 4: Add the embedded-mode integration test** — append to `tests/admin/test_static_files.py`:

```python
import shutil


def test_embedded_static_in_plugins_example():
    if shutil.which("npm") is None:
        import pytest
        pytest.skip("npm not available; cannot build the plugins frontend")
    plugins = REPO / "examples" / "plugins"
    fe = plugins / "frontend"
    if not (fe / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=fe, check=True)
        subprocess.run(["npm", "run", "build"], cwd=fe, check=True)
    subprocess.run(ZIG + ["build"], cwd=plugins, check=True)
    binary = plugins / "zig-out" / "bin" / "plugins"
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")
            st, hdr, body = _get(f"{base}/")
            assert st == 200 and b"one binary" in body.lower()
            assert "text/html" in hdr.get("Content-Type", "")
            etag = hdr.get("ETag")
            assert etag and etag.startswith('"')
            st, _, _ = _get(f"{base}/", {"If-None-Match": etag})
            assert st == 304
        finally:
            proc.terminate(); proc.wait(timeout=10)
```

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q` — expected PASS (3 tests).

- [ ] **Step 5: Fix CI** — `examples/plugins` now needs its frontend built before `zig build`. In `.github/workflows/ci.yml`, in the `zig` job, insert before the plugins build step (and add node):

```yaml
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Build plugins example frontend (embedded assets)
        run: cd examples/plugins/frontend && npm ci --no-audit --no-fund && npm run build
```

Use `npm ci` ⇒ a `package-lock.json` must be committed for each frontend (it is generated by `npm install` in the earlier tasks — make sure `examples/*/frontend/package-lock.json` is NOT gitignored and IS committed).

- [ ] **Step 6: Update the plugins README** (`examples/plugins/README.md` if present, otherwise rely on the doc comment) with the embedded-mode story and build order (npm first, then zig).

- [ ] **Step 7: Commit**

```bash
git add examples/plugins tests/admin/test_static_files.py .github/workflows/ci.yml
git commit -m "feat(plugins-example): fully embedded Astro frontend via embedStaticDir"
```

---

### Task 12: Repo docs

**Files:**
- Modify: `README.md`, `docs/framework.md`, `docs/api.md`, `docs/recipes.md`, `KNOWN_LIMITATIONS.md`, `CHANGELOG.md`

- [ ] **Step 1: README.md** — add a features bullet (after the **Files** bullet):

```markdown
- **Static files** — serve a frontend from the same binary: `--serve-static <dir>` at runtime, or pin/embed it at comptime. → [docs/framework.md](docs/framework.md)
```

and extend the worked-examples sentence at the bottom of "Build an app on ZigBase" to mention each example now ships an Astro + React frontend demonstrating a different static-files mode.

- [ ] **Step 2: docs/framework.md** — add a numbered section (match the doc's existing structure/voice; place after the storage/mailer plugin section). Content to convey, with these code blocks:

```markdown
## N. Serve a frontend: static files

Anything that misses `/_/`, the built-in API, and your custom routes falls
through to the static-file server (GET/HEAD only; `/api/*` misses keep the JSON
404 envelope). `/` and directory paths resolve to `index.html`; every response
carries an `ETag` (304 on `If-None-Match`) and `X-Content-Type-Options: nosniff`.

Pick a mode at comptime with `.static_files`:

| Mode | Config | `--serve-static` |
|---|---|---|
| runtime flag (default) | *(field absent)* | enabled |
| disabled | `.static_files = .disabled` | rejected |
| hardcoded dir | `.static_files = .{ .dir = "frontend/dist" }` | rejected |
| embedded | `.static_files = .{ .embedded = &@import("static_assets").files }` | rejected |

Embedding compiles the assets into the binary. Generate the manifest from your
build.zig with the helper exported by zigbase's build.zig:

​```zig
const zigbase_build = @import("zigbase");
const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
exe_mod.addImport("static_assets", assets);
​```

The build fails with a clear error when `frontend/dist` is missing (build the
frontend first). A hardcoded/`--serve-static` dir that is missing at startup is
a fatal error. See examples/blog (runtime flag), examples/golfsim (hardcoded
dir), examples/plugins (embedded).
```

- [ ] **Step 3: docs/api.md** — add a "Static files" section near the file-serving docs (match the doc's heading level/voice):

```markdown
## Static files

When static serving is configured (see [framework.md](framework.md) for the
comptime modes and the `--serve-static <dir>` flag), GET and HEAD requests that
match none of the admin UI (`/_/`), the built-in API, or the app's custom routes
are served from the static root. Requests under `/api/` are never served
statically — an unmatched `/api/*` path keeps the JSON 404 envelope, while a
static miss returns a plain-text 404.

- `/` and directory paths resolve to that directory's `index.html`.
- Every response carries an `ETag`; a request with a matching `If-None-Match`
  gets `304 Not Modified`. Directory-mode tags derive from mtime+size, embedded
  tags from a build-time content hash.
- Responses include `X-Content-Type-Options: nosniff`; content types come from
  the file extension.
- Paths containing `..`, backslashes, or NUL bytes are rejected (404). There are
  no directory listings and no `Range` support.
```

- [ ] **Step 4: docs/recipes.md** — add a recipe "Ship your frontend inside the binary": Astro (or any static-site) build → `embedStaticDir` → `.static_files = .{ .embedded = ... }`, with the three-mode table and a pointer to the examples. Also update the golfsim runtime-provisioning recipe intro: the example now self-provisions via comptime `.collections`; the recipe remains as the REST-API alternative.

- [ ] **Step 5: KNOWN_LIMITATIONS.md** — add under an appropriate heading:

```markdown
## Static file serving

- No `Range`/partial-content requests (no video seeking on large files).
- No directory listings; directories resolve to `index.html` or 404.
- Path safety is lexical (`..`, backslashes, NUL rejected); symlinks inside the
  static root are followed — don't point them outside the root.
- No on-the-fly compression; pre-compress at the CDN/proxy if needed.
```

- [ ] **Step 6: CHANGELOG.md** — add under the Unreleased/next-version heading (follow the file's existing format):

```markdown
- Static file serving: root-path fallback with comptime modes — runtime
  `--serve-static <dir>` flag (default), `.disabled`, hardcoded `.dir`, or
  assets fully `.embedded` in the binary via the new `embedStaticDir` build
  helper. ETag/304 caching, nosniff, lexical traversal protection.
- Examples: all three examples ship an Astro + React-islands frontend, one per
  static mode; blog and golfsim now self-provision their schemas via comptime
  `.collections`.
```

- [ ] **Step 7: Verify + commit.** Re-read each edited doc for stale claims (e.g. golfsim README/recipes saying collections must be created manually).

```bash
git add README.md docs/framework.md docs/api.md docs/recipes.md KNOWN_LIMITATIONS.md CHANGELOG.md
git commit -m "docs: static file serving — framework modes, API semantics, recipes, limitations"
```

---

### Task 13: Marketing site

**Files:**
- Modify: `site/src/content/docs/framework.md`, `site/src/content/docs/api.md`, `site/src/content/docs/recipes.md`, `site/src/content/docs/configuration.md`, `site/src/content/docs/changelog.md`, `site/src/content/docs/known-limitations.md`
- Modify: `site/src/components/landing/Features.astro`
- Modify: `site/src/content/examples/blog.md`, `site/src/content/examples/golfsim.md`, `site/src/content/examples/plugins.md`

- [ ] **Step 1: Mirror the doc updates.** The `site/src/content/docs/*.md` files are web-native rewrites of `docs/*.md` — apply the SAME new sections from Task 12 (framework modes table + embed helper, api semantics, recipe, limitations, changelog entry), adapting links to the site's relative-link convention (`./framework`, `./api` — study how existing cross-links are written in those files first). `configuration.md`: document the `--serve-static DIR` serve flag alongside the existing flag table.

- [ ] **Step 2: Features grid.** In `site/src/components/landing/Features.astro`, add a seventh `FeatureCard` after "File storage":

```astro
    <FeatureCard title="Static file serving">
      <svg slot="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <rect x="3" y="3" width="18" height="14" rx="2" />
        <path d="M3 8h18" />
        <path d="M8 21h8M12 17v4" />
      </svg>
      Ship your frontend from the same binary — point a flag at a folder, or embed it at compile time.
    </FeatureCard>
```

Check the grid still looks intentional with 7 cards (`cd site && npm run build` and eyeball `dist/index.html`, or `npm run dev`); if the layout needs an even count, instead fold the copy into the existing "Single static binary" card AND add this new card, keeping 8 total by also splitting "Auth + OAuth2" — prefer whatever the grid CSS handles gracefully (it's an auto-fill grid; odd counts are usually fine).

- [ ] **Step 3: Example pages.** Each `site/src/content/examples/*.md` gets a "Frontend" section describing its Astro + React frontend and which static mode it demonstrates (reuse the README copy from Tasks 9-11, adapted to the page's voice), and update each page's `summary` frontmatter to mention the frontend, e.g. blog: `summary: A minimal app on ZigBase-as-a-library — slugify hook + an Astro/React frontend served with --serve-static.`

- [ ] **Step 4: Build the site**

```bash
cd site && npm run build
```
Expected: clean Astro build, no broken-link warnings. Also run `npm run check` if it passes today (it's in package.json scripts).

- [ ] **Step 5: Commit**

```bash
git add site
git commit -m "feat(site): static file serving — feature card, docs mirror, example frontends"
```

---

### Task 14: Final verification

- [ ] **Step 1: Full test sweep**

```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig build
(cd examples/blog && mise exec zig@0.16.0 -- zig build)
(cd examples/golfsim && mise exec zig@0.16.0 -- zig build)
(cd examples/plugins && mise exec zig@0.16.0 -- zig build)   # requires frontend/dist
mise exec python@3.13 -- python -m pytest tests/admin -q     # full admin suite incl. new tests
(cd site && npm run build)
```
Expected: everything green. Fix anything that isn't before claiming completion (superpowers:verification-before-completion).

- [ ] **Step 2: Spec cross-check.** Re-read `docs/superpowers/specs/2026-06-10-static-files-design.md` §1-§6 and confirm each decision landed (modes, dispatch order, ETag, embed helper, one-mode-per-example, docs list, error-handling table).

- [ ] **Step 3: Commit any stragglers, then finish**

Use superpowers:finishing-a-development-branch — present merge/PR options for `feat/static-files`.
