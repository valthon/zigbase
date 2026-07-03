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
    const path = (try storage.localPath(ctx.allocator, col.name, rid, name)) orelse return ApiError.internal().toResponse(ctx.allocator);

    const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
    const force_download = if (qp) |p| (p.get("download") != null) else false;

    // Only render inline for known-safe types; everything else downloads (neutralizes HTML/SVG/JS XSS).
    const ext = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk "";
        break :blk name[dot + 1 ..];
    };
    const inline_safe = isInlineSafeExt(ext);
    const disp_kind: []const u8 = if (force_download or !inline_safe) "attachment" else "inline";
    const disposition = try std.fmt.allocPrint(ctx.allocator, "{s}; filename=\"{s}\"", .{ disp_kind, name });

    const cache = cacheControlFor(col);
    const headers = try ctx.allocator.dupe(http.Header, &.{
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "Content-Security-Policy", .value = "default-src 'none'; sandbox" },
        .{ .name = "Cache-Control", .value = cache },
        .{ .name = "Content-Disposition", .value = disposition },
    });
    return .{ .status = 200, .body = "", .file = .{ .path = path }, .extra_headers = headers };
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
