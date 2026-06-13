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
