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

/// One Tier-2 rewrite (issue #183): a comptime-validated `match` pattern -> a fixed
/// `serve` target. Both start with '/'; `serve` names a real document in the active
/// static source (proven at comptime for embedded manifests, at startup for dirs).
pub const StaticRoute = struct { match: []const u8, serve: []const u8 };

const nosniff = http.Header{ .name = "X-Content-Type-Options", .value = "nosniff" };

/// Normalize a request path into a root-relative, '/'-separated file path.
/// Returns null for unsafe paths (no leading '/', NUL, backslash, "..").
/// "" means "the root" (callers resolve it to index.html). Caller owns the slice.
pub fn sanitize(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    // `path` is already percent-decoded by the HTTP layer (facil.io), so "%2e%2e" cannot sneak past the ".." check.
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

/// RFC 7232: a 304 carries the headers the 200 would have sent, so it reports
/// the file's real content type rather than a placeholder.
fn notModified(content_type: []const u8, headers: []const http.Header) http.Response {
    return .{ .status = 304, .body = "", .content_type = content_type, .extra_headers = headers };
}

/// True when the request's If-None-Match matches this entity tag ("*" or exact).
/// Strip an RFC 7232 weak-validator prefix ("W/") from an entity tag.
fn opaqueTag(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
}

fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    if (if_none_match.len == 0) return false;
    if (std.mem.eql(u8, if_none_match, "*")) return true;
    // RFC 7232 §3.2: If-None-Match MUST use the weak comparison function —
    // W/ prefixes are ignored on both sides (proxies may weaken our strong tag).
    const ours = opaqueTag(etag);
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, opaqueTag(std.mem.trim(u8, raw, " \t")), ours)) return true;
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
        const idx = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{rel});
        break :blk findEmbedded(files, idx);
    } orelse return null;
    const content_type = mime.fromExtension(hit.path);
    const headers = try headersWithEtag(ctx.allocator, hit.etag);
    if (etagMatches(ctx.if_none_match, hit.etag)) return notModified(content_type, headers);
    return .{
        .status = 200,
        .body = hit.bytes,
        .content_type = content_type,
        .extra_headers = headers,
    };
}

/// True iff `candidate` is the same path as `root` or lives strictly beneath it
/// (a '/'-bounded prefix, so "/a/rootEVIL" is NOT considered inside "/a/root").
fn withinRoot(root: []const u8, candidate: []const u8) bool {
    // Normalize a trailing slash OFF the root first, so "/srv/www/" and "/srv/www"
    // behave identically (the prefix/boundary checks below all run against `r`).
    const r = if (root.len > 0 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (!std.mem.startsWith(u8, candidate, r)) return false;
    if (candidate.len == r.len) return true; // exact same path
    return candidate[r.len] == '/'; // boundary must be a separator (so "/a/rootEVIL" is rejected)
}

/// "" for a root marker (".spa"), "app/x" for "app/x/.spa", null when `path` is not
/// a marker file path. `path` is root-relative and '/'-separated.
fn markerPrefix(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, ".spa")) return "";
    if (std.mem.endsWith(u8, path, "/.spa")) return path[0 .. path.len - "/.spa".len];
    return null;
}

/// True when the sanitized path's final segment is ".spa" (ASCII case-insensitive) —
/// the marker file itself is never servable (its bytes are meaningless and dir/embedded
/// sources would otherwise happily serve it). Other dotfiles (.well-known/...) are
/// unaffected. Case-insensitive because dir-mode stat on a case-insensitive filesystem
/// (macOS's default APFS/HFS+ volumes) resolves "GET /.SPA" to the same file as ".spa",
/// so the "never servable" invariant must hold regardless of request-path casing —
/// otherwise the marker's contents (deliberately meaningless, but still readable server
/// state) would leak on those platforms.
fn isSpaMarkerPath(rel: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return std.ascii.eqlIgnoreCase(base, ".spa");
}

/// The longest scanned SPA root that is a '/'-bounded prefix of the sanitized `rel`
/// ("" matches everything). `roots` is sorted longest-first, so the first hit wins
/// (nested markers: the innermost marker claims the miss).
fn matchSpaRoot(roots: []const []const u8, rel: []const u8) ?[]const u8 {
    for (roots) |root| {
        if (root.len == 0) return root;
        if (std.mem.startsWith(u8, rel, root) and
            (rel.len == root.len or rel[root.len] == '/')) return root;
    }
    return null;
}

/// Minimal segment matcher for Tier-2 `static_routes` (issue #183). `pattern` is a
/// comptime-validated route pattern (leading '/'; segments are literals, ":name", or a
/// terminal "*"/"**"); `rel` is a sanitize()d root-relative path ("" = the root).
///   :name — exactly one segment (capture discarded; `serve` is a fixed path)
///   *     — one or more remaining segments (the bare prefix does NOT match)
///   **    — zero or more remaining segments (the bare prefix DOES match)
/// First-match-wins ordering is the caller's job; this answers a single pattern.
pub fn matchRoute(pattern: []const u8, rel: []const u8) bool {
    if (pattern.len <= 1) return rel.len == 0; // "/" matches only the root
    var pit = std.mem.splitScalar(u8, pattern[1..], '/');
    var rit = std.mem.splitScalar(u8, rel, '/');
    // splitScalar("") still yields one "" segment; treat the root as zero segments.
    const rel_empty = rel.len == 0;
    while (pit.next()) |pseg| {
        if (std.mem.eql(u8, pseg, "**")) return true; // rest-matcher, zero or more
        if (std.mem.eql(u8, pseg, "*")) // rest-matcher, one or more
            return !rel_empty and rit.next() != null;
        const rseg = (if (rel_empty) null else rit.next()) orelse return false;
        if (pseg.len > 1 and pseg[0] == ':') continue; // one segment, any (non-empty) value
        if (!std.mem.eql(u8, pseg, rseg)) return false;
    }
    return rit.next() == null; // pattern exhausted: match iff the path has no segments left either
}

/// Startup derivation (Tier 1, EMBEDDED source only, issue #183): collect every
/// directory in the manifest containing a file named exactly `.spa`, as root-relative
/// '/'-separated prefixes ("" = the static root itself), sorted longest-first. An
/// embedded manifest is comptime-static (baked into the binary), so this set never goes
/// stale — there's no live filesystem to re-check per request, unlike dir mode below.
/// A marked directory without an `index.html` gets a startup warning and is dropped
/// (degrades to unmarked — misses there 404 or fall through to an enclosing marker).
/// Caller frees via `freeSpaRoots`.
pub fn deriveEmbeddedSpaRoots(alloc: std.mem.Allocator, files: []const StaticFile) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| alloc.free(r);
        roots.deinit(alloc);
    }
    for (files) |f| {
        const prefix = markerPrefix(f.path) orelse continue;
        const has_index = if (prefix.len == 0)
            findEmbedded(files, "index.html") != null
        else blk: {
            const idx = try std.fmt.allocPrint(alloc, "{s}/index.html", .{prefix});
            defer alloc.free(idx);
            break :blk findEmbedded(files, idx) != null;
        };
        if (!has_index) {
            std.log.warn("SPA marker at '{s}/' has no index.html; marker ignored", .{prefix});
            continue;
        }
        try roots.append(alloc, try alloc.dupe(u8, prefix));
    }
    // Longest-first so the first '/'-bounded hit in matchSpaRoot is the innermost
    // marker; equal-length ties break lexically for determinism.
    std.mem.sort([]const u8, roots.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            if (x.len != y.len) return x.len > y.len;
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return try roots.toOwnedSlice(alloc);
}

/// Free a `deriveEmbeddedSpaRoots` result. Safe to call on the comptime-empty slice the
/// marker-disabled path uses (no-op).
pub fn freeSpaRoots(alloc: std.mem.Allocator, roots: []const []const u8) void {
    if (roots.len == 0) return;
    for (roots) |r| alloc.free(r);
    alloc.free(roots);
}

fn serveDir(io: std.Io, ctx: *http.RequestCtx, root: []const u8, rel: []const u8) !?http.Response {
    const first = if (rel.len == 0) "index.html" else rel;
    var full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ root, first });
    var st = std.Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind == .directory) {
        full = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{full});
        st = std.Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    }
    if (st.kind != .file) return null;
    // F10: lexical sanitize() already blocks ".."/backslash/NUL, but a symlink INSIDE
    // the root can still point outside it (statFile follows symlinks). Canonicalize the
    // matched file AND the root, and refuse to serve anything whose real path escapes the
    // real root. realPathFile resolves every symlinked component; a miss/escape => 404.
    const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root, ctx.allocator) catch return null;
    const real_full = std.Io.Dir.cwd().realPathFileAlloc(io, full, ctx.allocator) catch return null;
    if (!withinRoot(real_root, real_full)) return null;
    // Dir mode delegates ETag/Last-Modified/Cache-Control(max-age=3600)/If-None-Match/304
    // handling to facil.io's sendFile (http_sendfile2), which always emits its own etag
    // and answers conditional requests itself — adding ours would put two ETag headers
    // on the wire. Embedded mode keeps zigbase's CRC32 ETag because plain body responses
    // get no transport etag.
    const hs = try ctx.allocator.alloc(http.Header, 1);
    hs[0] = nosniff;
    return .{
        .status = 200,
        .body = "",
        .content_type = mime.fromExtension(full),
        .file_path = full,
        .extra_headers = hs,
    };
}

/// Serve `ctx.path` from `source`. Returns null when no file matches (the caller
/// emits its 404), including for non-GET/HEAD methods and `.none` sources.
/// HEAD gets the same response as GET (status + headers + body/file_path);
/// stripping the body for HEAD is the transport layer's (zap/facil.io) job.
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

test "withinRoot: exact path, trailing-slash root, and sibling rejection (F10)" {
    // A file strictly beneath the root is within it.
    try std.testing.expect(withinRoot("/srv/www", "/srv/www/index.html"));
    // A trailing slash on the root must not change the result (regression: it used to make
    // the exact-same-path and same-path-vs-slashed-root cases wrongly return false).
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www/index.html"));
    try std.testing.expect(withinRoot("/srv/www", "/srv/www")); // exact same path
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www")); // same path, trailing-slash root
    // A sibling that merely shares the root as a string prefix is NOT inside it.
    try std.testing.expect(!withinRoot("/srv/www", "/srv/wwwEVIL/x"));
    try std.testing.expect(!withinRoot("/srv/www/", "/srv/wwwEVIL/x"));
    // A wholly unrelated path is rejected.
    try std.testing.expect(!withinRoot("/srv/www", "/etc/passwd"));
}

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
    try std.testing.expectEqual(@as(usize, 2), r.extra_headers.len);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("\"22222222\"", r.extra_headers[0].value);

    var root = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &root, src)).?.body);

    var d1 = http.RequestCtx{ .method = .GET, .path = "/docs", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d1, src)).?.body);
    var d2 = http.RequestCtx{ .method = .GET, .path = "/docs/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d2, src)).?.body);

    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.png", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src)) == null);

    // HEAD is served like GET (the transport strips the body).
    var head = http.RequestCtx{ .method = .HEAD, .path = "/assets/app.js", .allocator = arena.allocator() };
    const hr = (try serve(std.testing.io, &head, src)).?;
    try std.testing.expectEqual(@as(u16, 200), hr.status);
    try std.testing.expectEqualStrings("application/javascript", hr.content_type);
    try std.testing.expectEqual(@as(usize, 2), hr.extra_headers.len);
    try std.testing.expectEqualStrings("\"22222222\"", hr.extra_headers[0].value);
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

test "etagMatches uses RFC 7232 weak comparison (W/ prefix ignored)" {
    // A proxy (e.g. nginx gzip) may convert our strong ETag to weak; the client
    // then revalidates with W/"..." and must still get a 304.
    try std.testing.expect(etagMatches("W/\"22222222\"", "\"22222222\""));
    try std.testing.expect(etagMatches("\"x\", W/\"22222222\"", "\"22222222\""));
    try std.testing.expect(etagMatches("\"22222222\"", "W/\"22222222\""));
    try std.testing.expect(!etagMatches("W/\"junk\"", "\"22222222\""));
}

test "dir: serves files via file_path; index resolution; miss; traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/app.js", .data = "let x = 1;" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &ctx, src)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file_path != null);
    try std.testing.expect(std.mem.endsWith(u8, r.file_path.?, "assets/app.js"));
    // Dir mode emits ONLY nosniff; ETag/304 are facil.io sendFile's job.
    try std.testing.expectEqual(@as(usize, 1), r.extra_headers.len);
    try std.testing.expectEqualStrings("X-Content-Type-Options", r.extra_headers[0].name);

    var root_req = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    const ri = (try serve(std.testing.io, &root_req, src)).?;
    try std.testing.expect(std.mem.endsWith(u8, ri.file_path.?, "index.html"));

    var dir_req = http.RequestCtx{ .method = .GET, .path = "/assets", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &dir_req, src)) == null);

    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.css", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src)) == null);
    var trav = http.RequestCtx{ .method = .GET, .path = "/../secret", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &trav, src)) == null);
}

test "withinRoot: prefix must be '/'-bounded (no sibling-prefix bypass)" {
    try std.testing.expect(withinRoot("/srv/www", "/srv/www"));
    try std.testing.expect(withinRoot("/srv/www", "/srv/www/a/b.js"));
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www/a.js"));
    try std.testing.expect(!withinRoot("/srv/www", "/srv/wwwEVIL/x"));
    try std.testing.expect(!withinRoot("/srv/www", "/etc/passwd"));
}

test "dir: a symlink inside the root pointing OUTSIDE it is refused (F10)" {
    // Two sibling temp dirs: `root` is served; `outside` is not. A symlink planted
    // inside root that points at a file in `outside` must NOT be served, even though
    // the lexical path is clean and statFile would happily follow the link.
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A legitimate in-root file still serves.
    try root_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok.txt", .data = "in-root" });
    // The secret lives outside the served root.
    try out_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.txt", .data = "TOPSECRET" });

    const root = try root_tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const out_abs = try out_tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const secret_abs = try std.fmt.allocPrint(a, "{s}/secret.txt", .{out_abs});
    // Plant the escaping symlink inside the served root: root/leak.txt -> outside/secret.txt
    try root_tmp.dir.symLink(std.testing.io, secret_abs, "leak.txt", .{});

    const src = Source{ .dir = root };

    // The escaping symlink is refused (404 / null).
    var leak = http.RequestCtx{ .method = .GET, .path = "/leak.txt", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &leak, src)) == null);

    // The legitimate file is unaffected.
    var ok = http.RequestCtx{ .method = .GET, .path = "/ok.txt", .allocator = a };
    const r = (try serve(std.testing.io, &ok, src)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file_path != null);
}

// ── Tier-1 SPA marker fixtures + tests (issue #183) ─────────────────────────

const spa_fixture = [_]StaticFile{
    .{ .path = "index.html", .bytes = "<h1>home</h1>", .etag = "\"aaaaaaaa\"" },
    .{ .path = ".spa", .bytes = "MARKER-SECRET", .etag = "\"eeeeeeee\"" },
    .{ .path = "app/index.html", .bytes = "<h1>app shell</h1>", .etag = "\"bbbbbbbb\"" },
    .{ .path = "app/.spa", .bytes = "MARKER-SECRET", .etag = "\"ffffffff\"" },
    .{ .path = "app/assets/app.js", .bytes = "console.log(2)", .etag = "\"cccccccc\"" },
    // a marker whose directory has NO index.html — must be warned about and dropped
    .{ .path = "bare/.spa", .bytes = "MARKER-SECRET", .etag = "\"dddddddd\"" },
    // a REAL static file that happens to live under an "api/" prefix — proves the
    // api-guard refuses it even though a normal file lookup would otherwise find it.
    .{ .path = "api/x", .bytes = "not-the-api", .etag = "\"11111111\"" },
};

test "spa scan: embedded manifest markers derive roots (missing index.html dropped)" {
    const a = std.testing.allocator;
    const roots = try deriveEmbeddedSpaRoots(a, &spa_fixture);
    defer freeSpaRoots(a, roots);
    // "bare" is dropped (no bare/index.html); longest-first order: "app" then "".
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("app", roots[0]);
    try std.testing.expectEqualStrings("", roots[1]);
}

test "spa scan: .none / plain embedded source yields an empty (freeable) root set" {
    const a = std.testing.allocator;
    const plain = try deriveEmbeddedSpaRoots(a, &fixture);
    defer freeSpaRoots(a, plain);
    try std.testing.expectEqual(@as(usize, 0), plain.len);
}

test "spa prefix: '/'-bounded longest match; marker at app/ does not claim /application" {
    const roots = [_][]const u8{ "app/admin", "app", "" };
    try std.testing.expectEqualStrings("app/admin", matchSpaRoot(&roots, "app/admin/x/y").?);
    try std.testing.expectEqualStrings("app", matchSpaRoot(&roots, "app/orders/1").?);
    try std.testing.expectEqualStrings("app", matchSpaRoot(&roots, "app").?);
    try std.testing.expectEqualStrings("", matchSpaRoot(&roots, "pricing").?);
    try std.testing.expectEqualStrings("", matchSpaRoot(&roots, "application/x").?); // root marker, NOT "app"
    const app_only = [_][]const u8{"app"};
    try std.testing.expect(matchSpaRoot(&app_only, "application/x") == null);
    try std.testing.expect(matchSpaRoot(&app_only, "pricing") == null);
    try std.testing.expect(matchSpaRoot(&.{}, "anything") == null);
}

test "spa marker path detection: final segment '.spa' only, case-insensitive" {
    try std.testing.expect(isSpaMarkerPath(".spa"));
    try std.testing.expect(isSpaMarkerPath("app/.spa"));
    try std.testing.expect(!isSpaMarkerPath("app/.spare"));
    try std.testing.expect(!isSpaMarkerPath(".spa/x"));
    try std.testing.expect(!isSpaMarkerPath(".well-known/security.txt"));
    try std.testing.expect(!isSpaMarkerPath(""));
    // ASCII-case-insensitive: macOS's default (case-insensitive) APFS/HFS+ volumes stat
    // ".SPA"/".Spa" as the same file as ".spa" in dir mode, so "GET /.SPA" must be
    // refused too — otherwise the "never servable" invariant would be platform-dependent.
    try std.testing.expect(isSpaMarkerPath(".SPA"));
    try std.testing.expect(isSpaMarkerPath(".Spa"));
    try std.testing.expect(isSpaMarkerPath("app/.SPA"));
    try std.testing.expect(!isSpaMarkerPath("app/.SPARE"));
}

test "static_routes matcher: ':name' one segment, '*' one-or-more, '**' zero-or-more" {
    // The design-spec examples table, as assertions.
    try std.testing.expect(matchRoute("/app/orders/:id", "app/orders/42"));
    try std.testing.expect(!matchRoute("/app/orders/:id", "app/orders/42/edit")); // :id is ONE segment
    try std.testing.expect(!matchRoute("/app/orders/:id", "app/orders"));
    try std.testing.expect(matchRoute("/admin/*", "admin/x"));
    try std.testing.expect(matchRoute("/admin/*", "admin/x/y"));
    try std.testing.expect(!matchRoute("/admin/*", "admin")); // '*' needs >= 1 segment
    try std.testing.expect(matchRoute("/app/**", "app")); // '**' matches the bare prefix
    try std.testing.expect(matchRoute("/app/**", "app/a/b/c"));
    try std.testing.expect(matchRoute("/app/a/b/c", "app/a/b/c")); // exact literal
    try std.testing.expect(!matchRoute("/app/a/b/c", "app/a/b"));
    try std.testing.expect(!matchRoute("/app/x", "app/y"));
    // Root-form patterns against the root path ("" after sanitize).
    try std.testing.expect(matchRoute("/**", ""));
    try std.testing.expect(!matchRoute("/*", "")); // one-or-more can't match zero
    try std.testing.expect(matchRoute("/", ""));
    try std.testing.expect(!matchRoute("/", "x"));
    try std.testing.expect(!matchRoute("/app/**", "application")); // segment-wise, not prefix-wise
}
