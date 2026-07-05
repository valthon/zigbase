const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const policy = @import("../policy.zig");
const request = @import("../request.zig");
const auth = @import("../auth.zig");
const jwt = @import("../jwt.zig");
const crypto = @import("../crypto.zig");
const auth_api = @import("auth.zig");
const params_mod = @import("../query/params.zig");
const events = @import("../events.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const ApiError = @import("error.zig").ApiError;
const serve_file = @import("../files/serve_file.zig");
const mime = @import("../files/mime.zig");

/// Extensions safe to render inline in a browser (no script execution). Everything else downloads.
fn isInlineSafeExt(ext: []const u8) bool {
    const safe = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "pdf" };
    var buf: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > buf.len) return false;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..ext.len];
    for (safe) |s| if (std.mem.eql(u8, s, lower)) return true;
    return false;
}

fn recordReferencesFile(col: schema.Collection, rec: std.json.Value, name: []const u8) bool {
    if (rec != .object) return false;
    for (col.fields) |f| {
        if (f.fieldType() != .file) continue;
        const v = rec.object.get(f.name) orelse continue;
        switch (v) {
            .string => |s| if (std.mem.eql(u8, s, name)) return true,
            .array => |arr| for (arr.items) |it| {
                if (it == .string and std.mem.eql(u8, it.string, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Cache-Control for a file download. A `@public` viewRule alone does not make the response
/// publicly cacheable: on a tenant-owned collection the same URL serves different bytes per
/// active account, so a shared cache/CDN keyed only on the URL could replay tenant A's file to
/// tenant B.
///
/// Invariant: tenant-owned collections are NEVER publicly cacheable — full stop, regardless of
/// the requester. The Cache-Control header is a property of the URL, not the request, so it must
/// not vary by requester privilege: a superuser or explicit cross-tenant bypass fetching a
/// tenant-owned `@public` collection's file must NOT earn `public`, or a shared cache/CDN would
/// replay that superuser-fetched copy to any other tenant hitting the same URL. Only a
/// non-tenant-owned collection with a genuinely account-independent `@public` rule is
/// shared-cacheable.
fn cacheControlFor(col: schema.Collection) []const u8 {
    return if (policy.isPublic(col.viewRule) and col.options.tenant_field == null)
        "public, max-age=3600"
    else
        "private";
}

/// Resolve the requester's identity for a file download: either a `?token=` file/auth JWT, or
/// the normal bearer/cookie auth. Returns an `auth.Authed` (not `auth.Verified`) so the caller
/// can feed it straight into `tenancy.resolveRequest` — mirroring `dispatchCustom` and
/// `api/records.zig`'s `buildContext`, the other REST chokepoints that resolve tenant scope.
fn fileIdentity(ctx: *http.RequestCtx, conn: *db.Db) ?auth.Authed {
    const app = ctx.app.?;
    const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
    if (qp) |p| if (p.get("token")) |tok| {
        if (auth.verifyTokenOfTypes(ctx.allocator, app, conn, tok, &.{ .auth, .file })) |v|
            return .{ .record = v.record, .collection = v.collection, .is_superuser = v.is_superuser, .sid = v.sid };
    };
    return auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null;
}

/// GET /api/files/:col/:rec/:name
pub fn serve(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("rec") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const name = ctx.param("name") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (name.len == 0) return ApiError.notFound().toResponse(ctx.allocator);

    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!recordReferencesFile(col, rec, name)) return ApiError.notFound().toResponse(ctx.allocator);

    const ident = fileIdentity(ctx, &r);
    var rctx = request.RequestContext{
        .auth = if (ident) |i| i.record else null,
        .is_superuser = if (ident) |i| i.is_superuser else false,
        .collection = if (ident) |i| i.collection else "",
        .method = "GET",
        // session_id intentionally omitted, matching api/records.zig's buildContext (the REST
        // chokepoint this fn's rctx construction otherwise mirrors) — no hook/ability surface here
        // keys off it today, unlike server.zig's dispatchCustom which threads authed.sid through.
    };
    // Resolve the active tenant scope EXACTLY like the other REST chokepoints
    // (api/records.zig's buildContext, server.zig's dispatchCustom) so a tenant-owned
    // collection's viewRule/scope predicate sees the caller's verified active account
    // instead of always stamping account "". Anonymous requests (ident == null) still get
    // `tenancy_enabled`/`role_ranking` copied (an unresolved, fail-closed scope), matching
    // an anonymous REST request.
    if (ident) |i| {
        tenancy.resolveRequest(ctx, &r, app, i, &rctx);
    } else {
        rctx.tenancy_enabled = app.tenancy.enabled;
        rctx.role_ranking = app.role_ranking;
    }
    switch (policy.decide(col, .view, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try policy.authorizes(ctx.allocator, &r, col, .view, rid, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }

    // file.beforeServe runs only on files the requester may already access; a handler
    // returning an error denies the download as 404 (hides existence, like viewRule).
    if (app.dispatch) |d| if (d.on_file_serve) |h| {
        var fev = events.FileEvent{ .app = app, .ctx = &rctx, .collection = col_name, .record_id = rid, .filename = name };
        h(&fev) catch return ApiError.notFound().toResponse(ctx.allocator);
    };

    const storage = app.storage orelse return ApiError.internal().toResponse(ctx.allocator);

    // Presigned-redirect mode (opt-in via `App(.{ .files = .{ .s3_presign_redirect = true } })`,
    // S3-only). Authorization above has ALREADY run per-request; here we offload the byte transfer
    // to the object store by 302-redirecting to a time-limited presigned GET URL instead of
    // proxying/spooling the bytes. SECURITY: unlike the proxy path (each byte flows through an
    // authorized request), the issued URL is a BEARER capability valid until it expires
    // (`presign_ttl_s`) and is NOT bound to the authorized requester — anyone holding the URL can
    // fetch it, and it does not vary by requester privilege. Authorization still gates *issuance*;
    // keep the TTL short. `presignGetUrl` returns null on backends without presigning (local disk,
    // or a build without -Ds3), so we fall through to the unchanged proxy path. A HEAD is honored
    // too — the 302 carries no body. A signing failure propagates (→ 500), not a silent fallback.
    if (app.files.presign_redirect) {
        if (try storage.presignGetUrl(app.io, ctx.allocator, col.name, rid, name, app.files.presign_ttl_s)) |url| {
            const hs = try ctx.allocator.dupe(http.Header, &.{.{ .name = "Location", .value = url }});
            return .{ .status = 302, .body = "", .content_type = "text/plain", .extra_headers = hs };
        }
    }

    // §D.5: null = the DB references an object the backend has lost — hide existence
    // (404) but SCREAM in the logs; a transport/backend error (post retry-once inside
    // the backend) = transient -> 500.
    const maybe_path = storage.fetch(app.io, ctx.allocator, col.name, rid, name) catch |e| {
        std.log.err("storage.fetch failed for {s}/{s}/{s}: {s}", .{ col.name, rid, name, @errorName(e) });
        return ApiError.internal().toResponse(ctx.allocator);
    };
    const path = maybe_path orelse {
        std.log.err("storage backend has no object for referenced file {s}/{s}/{s}", .{ col.name, rid, name });
        return ApiError.notFound().toResponse(ctx.allocator);
    };
    // The backend reported success but the fetched path is unreadable/unstattable: 404
    // (hide existence), matching the old sendFile-catch behavior — but planned here so
    // the conditional headers below never describe a file we can't stat.
    const st = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch
        return ApiError.notFound().toResponse(ctx.allocator);

    // §B.2/§B.3: plan status + byte window from the request's conditional headers.
    // Authorization (above) already completed — no plan output can leak denied bytes.
    const etag = try serve_file.fileEtag(ctx.allocator, col.name, rid, name);
    const p = try serve_file.plan(ctx.allocator, .{
        .size = st.size,
        .etag = etag,
        .range = ctx.header("range") orelse "",
        .if_none_match = ctx.if_none_match,
        .if_range = ctx.header("if-range") orelse "",
        .head = ctx.method == .HEAD,
    });
    const cache = cacheControlFor(col);
    // facil.io no longer infers Content-Type on this route (the owned path bypasses
    // http_sendfile2's mime lookup): set it explicitly; unknown -> octet-stream.
    const content_type = mime.fromExtension(name);
    if (p.status == 304) {
        // RFC 9110 §15.4.5: a 304 replays the validator + cache policy only, but the
        // Content-Type still applies to the (unsent) representation — omitting it lets
        // the server fall back to its default application/json, which is wrong here.
        const hs304 = try ctx.allocator.dupe(http.Header, &.{
            .{ .name = "ETag", .value = etag },
            .{ .name = "Cache-Control", .value = cache },
        });
        return .{ .status = 304, .body = "", .content_type = content_type, .extra_headers = hs304 };
    }

    const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
    const force_download = if (qp) |pq| (pq.get("download") != null) else false;
    // Only render inline for known-safe types; everything else downloads
    // (neutralizes HTML/SVG/JS XSS). ?download and ?token compose orthogonally
    // with Range — disposition/identity are resolved before/independent of the plan.
    const ext = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk "";
        break :blk name[dot + 1 ..];
    };
    const inline_safe = isInlineSafeExt(ext);
    const disp_kind: []const u8 = if (force_download or !inline_safe) "attachment" else "inline";
    const disposition = try std.fmt.allocPrint(ctx.allocator, "{s}; filename=\"{s}\"", .{ disp_kind, name });

    var hs: std.ArrayList(http.Header) = .empty;
    try hs.appendSlice(ctx.allocator, &.{
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "Content-Security-Policy", .value = "default-src 'none'; sandbox" },
        .{ .name = "Cache-Control", .value = cache }, // exactly ONCE now (§B.1 fix)
        .{ .name = "Content-Disposition", .value = disposition },
        .{ .name = "ETag", .value = etag },
        .{ .name = "Accept-Ranges", .value = "bytes" },
    });
    if (p.content_range) |cr| try hs.append(ctx.allocator, .{ .name = "Content-Range", .value = cr });
    if (p.status == 416) {
        return .{ .status = 416, .body = "", .content_type = content_type, .extra_headers = try hs.toOwnedSlice(ctx.allocator) };
    }
    if (ctx.method == .HEAD) {
        // facil.io's http1_sendfile does NOT strip bodies for HEAD, so mirror
        // facil.io's own static HEAD handling (http.c:585-590): explicit
        // Content-Length + empty body — http_send_body's add_content_length is
        // set-if-missing, so the real length survives while zero bytes are sent.
        try hs.append(ctx.allocator, .{
            .name = "Content-Length",
            .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{p.len}),
        });
        return .{ .status = p.status, .body = "", .content_type = content_type, .extra_headers = try hs.toOwnedSlice(ctx.allocator) };
    }
    // 200 or 206: ALWAYS set len (the planner computed it even for the full body), so
    // this route deterministically takes server.zig's owned http_sendfile path.
    return .{
        .status = p.status,
        .body = "",
        .content_type = content_type,
        .file = .{ .path = path, .offset = p.offset, .len = p.len },
        .extra_headers = try hs.toOwnedSlice(ctx.allocator),
    };
}

test "PIN: file-download view-authz + cache route through policy byte-identically" {
    // Guards the M1 fix: `serve` gates downloads via `policy.decide(.view)` /
    // `policy.authorizes(.view)` and sets Cache-Control via `policy.isPublic`. These must
    // equal the `rules.*` primitive they replaced, so PR2 tenant-scope / PR3 abilities
    // automatically cover file downloads instead of leaking cross-tenant.
    const rules = @import("../rules.zig");
    const collections_mod = @import("../collections.zig");
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const base = try collections_mod.create(a, std.testing.io, &d, .{ .id = "", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "d1", .name = "owner", .options = .{ .text = .{} } },
        .{ .id = "d2", .name = "file", .options = .{ .file = .{ .maxSelect = 1 } } },
    } });
    try d.exec("INSERT INTO docs (id,created,updated,owner,file) VALUES ('r1','t','t','u1','a.png');");
    var owner_obj: std.json.ObjectMap = .empty;
    try owner_obj.put(a, "id", .{ .string = "u1" });
    const owner = request.RequestContext{ .auth = .{ .object = owner_obj } };

    inline for (.{ "@public", "owner = @request.auth.id", "" }) |rule| {
        var col = base;
        col.viewRule = if (rule.len == 0) null else rule;
        // The authz decision the handler branches on is identical to the rules primitive.
        try std.testing.expectEqual(rules.decide(col.viewRule, &owner), policy.decide(col, .view, &owner));
        if (policy.decide(col, .view, &owner) == .check)
            try std.testing.expectEqual(try rules.matches(a, &d, col, "r1", col.viewRule.?, &owner), try policy.authorizes(a, &d, col, .view, "r1", &owner));
        // The Cache-Control public/private decision is identical too.
        try std.testing.expectEqual(rules.isPublic(col.viewRule), policy.isPublic(col.viewRule));
    }
}

// Guards the security-review fix: a `@public` viewRule must NOT make a TENANT-OWNED collection's
// file response publicly cacheable, since the same URL serves different bytes per active account.
// A shared cache/CDN keyed only on the URL could otherwise replay tenant A's file to tenant B.
// Cache-Control is a property of the URL, not the requester: it must come out identically for a
// superuser and for an ordinary member on the very same tenant-owned collection+file — otherwise
// a superuser's fetch would poison a shared cache/CDN with a copy any other tenant could then hit.
test "PIN: cacheControlFor forces private for a tenant-owned @public collection, for every requester" {
    const fields = [_]schema.Field{
        .{ .id = "d1", .name = "owner", .options = .{ .text = .{} } },
        .{ .id = "d2", .name = "file", .options = .{ .file = .{ .maxSelect = 1 } } },
    };
    var col = schema.Collection{ .id = "c1", .name = "docs", .fields = &fields, .viewRule = "@public" };
    col.options.tenant_field = "owner"; // tenant-owned

    // Tenant-owned + @public MUST be private regardless of who's asking: requester identity
    // (member vs. superuser vs. cross-tenant bypass) must play no part in the header.
    try std.testing.expectEqualStrings("private", cacheControlFor(col));

    // A non-tenant-owned collection with a genuinely account-independent @public rule stays
    // shared-cacheable.
    var untenanted = col;
    untenanted.options.tenant_field = null;
    try std.testing.expectEqualStrings("public, max-age=3600", cacheControlFor(untenanted));

    // A locked/owner-scoped rule (not @public) stays private regardless of tenancy.
    var locked = col;
    locked.viewRule = "owner = @request.auth.id";
    try std.testing.expectEqualStrings("private", cacheControlFor(locked));
    locked.options.tenant_field = null;
    try std.testing.expectEqualStrings("private", cacheControlFor(locked));
}

test "isInlineSafeExt allows only known-safe types" {
    // Safe image/pdf types render inline.
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "pdf" }) |s| {
        try std.testing.expect(isInlineSafeExt(s));
    }
    // Case-insensitive.
    try std.testing.expect(isInlineSafeExt("PNG"));
    try std.testing.expect(isInlineSafeExt("Jpeg"));
    // Script-capable / unknown types must NOT render inline (XSS neutralization).
    for ([_][]const u8{ "html", "htm", "svg", "js", "xml" }) |s| {
        try std.testing.expect(!isInlineSafeExt(s));
    }
    // Empty extension -> not safe.
    try std.testing.expect(!isInlineSafeExt(""));
    // Anything longer than the 16-byte buffer -> not safe (length boundary).
    try std.testing.expect(!isInlineSafeExt("a" ** 17));
}

test "recordReferencesFile matches single + array file fields, ignores non-file fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "avatar", .options = .{ .file = .{ .maxSelect = 1 } } },
        .{ .id = "f2", .name = "gallery", .options = .{ .file = .{ .maxSelect = 9 } } },
        .{ .id = "f3", .name = "caption", .options = .{ .text = .{} } },
    };
    const col = schema.Collection{ .id = "c1", .name = "media", .fields = &fields };

    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "avatar", .{ .string = "pic.png" });
    var gallery = std.json.Array.init(a);
    try gallery.append(.{ .string = "g1.png" });
    try gallery.append(.{ .string = "g2.png" });
    try rec.put(a, "gallery", .{ .array = gallery });
    // A NON-file (text) field whose value collides with a filename: must NOT grant access.
    try rec.put(a, "caption", .{ .string = "evil.html" });
    const rval = std.json.Value{ .object = rec };

    // Single-file field match.
    try std.testing.expect(recordReferencesFile(col, rval, "pic.png"));
    // Array-element match.
    try std.testing.expect(recordReferencesFile(col, rval, "g1.png"));
    try std.testing.expect(recordReferencesFile(col, rval, "g2.png"));
    // Name not referenced anywhere.
    try std.testing.expect(!recordReferencesFile(col, rval, "missing.png"));
    // Collides only with a non-file text field's value -> NOT a reference (prevents
    // serving arbitrary files via a text-field collision).
    try std.testing.expect(!recordReferencesFile(col, rval, "evil.html"));
    // A non-object record is never a reference.
    try std.testing.expect(!recordReferencesFile(col, .{ .string = "x" }, "pic.png"));
}

test "serve: header emission — exactly one Cache-Control, ETag, Accept-Ranges; 206/304/416/HEAD" {
    // Env: tmp-dir pool (api/records.zig TestEnv pattern), one @public collection with a
    // file field, one record referencing "a_0000000000.png", LocalStorage rooted in the
    // same tmp dir holding 1000 bytes for it, and an App wired with pool + storage.
    const migrations = @import("../migrations.zig");
    const files_storage = @import("../files/storage.zig");
    const app_mod = @import("../app.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ga = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/test.db", .{dir_path}, 0);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "docs", .viewRule = "@public", .fields = &[_]schema.Field{
            .{ .id = "d1", .name = "file", .options = .{ .file = .{ .maxSelect = 1 } } },
        } });
        try w.exec("INSERT INTO docs (id,created,updated,file) VALUES ('r1','t','t','a_0000000000.png');");
    }
    var local = files_storage.LocalStorage.init(dir_path);
    const storage_iface = local.storage();
    try storage_iface.put(std.testing.io, "docs", "r1", "a_0000000000.png", "x" ** 1000);
    var app = app_mod.App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .storage = &storage_iface };

    const params = [_]http.Param{
        .{ .key = "col", .value = "docs" }, .{ .key = "rec", .value = "r1" }, .{ .key = "name", .value = "a_0000000000.png" },
    };
    // Plain GET: 200, exactly one Cache-Control, ETag + Accept-Ranges, owned file ref.
    var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params };
    const r200 = try serve(&ctx);
    try std.testing.expectEqual(@as(u16, 200), r200.status);
    try std.testing.expect(r200.file != null);
    try std.testing.expectEqual(@as(?u64, 1000), r200.file.?.len); // ALWAYS len => owned path
    var cc_count: usize = 0;
    var etag_val: []const u8 = "";
    for (r200.extra_headers) |h| {
        if (std.mem.eql(u8, h.name, "Cache-Control")) cc_count += 1;
        if (std.mem.eql(u8, h.name, "ETag")) etag_val = h.value;
    }
    try std.testing.expectEqual(@as(usize, 1), cc_count); // §B.1 regression pin
    try std.testing.expectEqual(@as(usize, 18), etag_val.len);
    try std.testing.expectEqualStrings("image/png", r200.content_type); // explicit Content-Type

    // Range GET: 206 window + Content-Range.
    const range_hdrs = [_]http.Param{.{ .key = "range", .value = "bytes=100-" }};
    var ctx206 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .headers = &range_hdrs };
    const r206 = try serve(&ctx206);
    try std.testing.expectEqual(@as(u16, 206), r206.status);
    try std.testing.expectEqual(@as(u64, 100), r206.file.?.offset);
    try std.testing.expectEqual(@as(?u64, 900), r206.file.?.len);

    // Conditional GET with the minted ETag: 304 with ETag + Cache-Control ONLY.
    var ctx304 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .if_none_match = etag_val };
    const r304 = try serve(&ctx304);
    try std.testing.expectEqual(@as(u16, 304), r304.status);
    try std.testing.expectEqual(@as(usize, 2), r304.extra_headers.len);

    // Unsatisfiable range: 416 + `bytes */1000`, security headers intact, no file ref.
    const bad = [_]http.Param{.{ .key = "range", .value = "bytes=5000-" }};
    var ctx416 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .headers = &bad };
    const r416 = try serve(&ctx416);
    try std.testing.expectEqual(@as(u16, 416), r416.status);
    try std.testing.expect(r416.file == null);
    var got_cr = false;
    for (r416.extra_headers) |h| if (std.mem.eql(u8, h.name, "Content-Range")) {
        try std.testing.expectEqualStrings("bytes */1000", h.value);
        got_cr = true;
    };
    try std.testing.expect(got_cr);

    // HEAD mirrors GET: explicit Content-Length, empty body, no file ref.
    var ctxh = http.RequestCtx{ .method = .HEAD, .path = "/", .allocator = a, .app = &app, .params = &params };
    const rh = try serve(&ctxh);
    try std.testing.expectEqual(@as(u16, 200), rh.status);
    try std.testing.expect(rh.file == null);
    var got_cl = false;
    for (rh.extra_headers) |h| if (std.mem.eql(u8, h.name, "Content-Length")) {
        try std.testing.expectEqualStrings("1000", h.value);
        got_cl = true;
    };
    try std.testing.expect(got_cl);
}

// A minimal Storage stub for the presign-redirect serve test: `fetch` returns a real on-disk path
// (so the proxy fallback yields 200) and `presignGetUrl` yields a canned URL (so the redirect path
// yields a 302 without touching a real S3). put/delete/deleteRecord are unused no-ops here.
const PresignStubStorage = struct {
    root: []const u8,
    const canned = "https://example-bucket.s3.us-east-1.amazonaws.com/docs/r1/a_0000000000.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=900&X-Amz-Signature=deadbeef";

    fn putImpl(_: *anyopaque, _: std.Io, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn fetchImpl(ctx: *anyopaque, _: std.Io, alloc: std.mem.Allocator, col: []const u8, rid: []const u8, name: []const u8) anyerror!?[]const u8 {
        const self: *PresignStubStorage = @ptrCast(@alignCast(ctx));
        return try std.fs.path.join(alloc, &.{ self.root, col, rid, name });
    }
    fn deleteImpl(_: *anyopaque, _: std.Io, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn deleteRecordImpl(_: *anyopaque, _: std.Io, _: []const u8, _: []const u8) anyerror!void {}
    fn presignImpl(_: *anyopaque, _: std.Io, alloc: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, _: u32) anyerror!?[]const u8 {
        return try alloc.dupe(u8, canned);
    }
    const vtable = @import("../files/storage.zig").Storage.VTable{
        .put = putImpl,
        .fetch = fetchImpl,
        .delete = deleteImpl,
        .deleteRecord = deleteRecordImpl,
        .presignGetUrl = presignImpl,
    };
    fn storage(self: *PresignStubStorage) @import("../files/storage.zig").Storage {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "serve: presign_redirect issues a 302 Location; default (off) still proxies" {
    const migrations = @import("../migrations.zig");
    const files_storage = @import("../files/storage.zig");
    const app_mod = @import("../app.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ga = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/test.db", .{dir_path}, 0);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "docs", .viewRule = "@public", .fields = &[_]schema.Field{
            .{ .id = "d1", .name = "file", .options = .{ .file = .{ .maxSelect = 1 } } },
        } });
        try w.exec("INSERT INTO docs (id,created,updated,file) VALUES ('r1','t','t','a_0000000000.png');");
    }
    // A real on-disk object so the proxy fallback can succeed (200); the stub's fetch returns its path.
    var local = files_storage.LocalStorage.init(dir_path);
    try local.storage().put(std.testing.io, "docs", "r1", "a_0000000000.png", "x" ** 100);

    var stub = PresignStubStorage{ .root = dir_path };
    const storage_iface = stub.storage();

    const params = [_]http.Param{
        .{ .key = "col", .value = "docs" }, .{ .key = "rec", .value = "r1" }, .{ .key = "name", .value = "a_0000000000.png" },
    };

    // presign_redirect = true → 302 to the presigned URL (authorization ran first).
    {
        var app = app_mod.App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .storage = &storage_iface, .files = .{ .presign_redirect = true, .presign_ttl_s = 900 } };
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params };
        const r = try serve(&ctx);
        try std.testing.expectEqual(@as(u16, 302), r.status);
        try std.testing.expect(r.file == null);
        var loc: []const u8 = "";
        for (r.extra_headers) |h| if (std.mem.eql(u8, h.name, "Location")) {
            loc = h.value;
        };
        try std.testing.expectEqualStrings(PresignStubStorage.canned, loc);
    }

    // A HEAD in presign mode still 302s (the redirect carries no body).
    {
        var app = app_mod.App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .storage = &storage_iface, .files = .{ .presign_redirect = true } };
        var ctxh = http.RequestCtx{ .method = .HEAD, .path = "/", .allocator = a, .app = &app, .params = &params };
        const rh = try serve(&ctxh);
        try std.testing.expectEqual(@as(u16, 302), rh.status);
    }

    // Default (presign_redirect = false) → the unchanged proxy path: 200 with an owned file ref, no Location.
    {
        var app = app_mod.App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .storage = &storage_iface };
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params };
        const r = try serve(&ctx);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(r.file != null);
        for (r.extra_headers) |h| try std.testing.expect(!std.mem.eql(u8, h.name, "Location"));
    }
}

/// POST /api/files/token — authenticated; mints a short-lived file-access token.
pub fn token(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const rid = authed.record.object.get("id").?.string;
    const table = if (authed.is_superuser) "_superusers" else authed.collection;
    const tk = (try auth_api.tokenKeyFor(ctx.allocator, w, table, rid)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const now = try auth.nowUnixPub(w);
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const claims = jwt.Claims{ .id = rid, .collection = authed.collection, .type = .file, .iat = now, .exp = now + app.file_token_ttl_s };
    const tok = try jwt.sign(ctx.allocator, claims, &key);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = tok });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}) };
}
