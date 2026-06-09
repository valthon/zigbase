const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const crypto = @import("crypto.zig");
const jwt = @import("jwt.zig");
const http = @import("http.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const App = @import("app.zig").App;

const HashPasswordError = @typeInfo(@typeInfo(@TypeOf(crypto.hashPassword)).@"fn".return_type.?).error_union.error_set;
const GenTokenError = @typeInfo(@typeInfo(@TypeOf(crypto.genToken)).@"fn".return_type.?).error_union.error_set;

pub const AuthError = error{ PasswordTooShort, IdentityTaken } || db.DbError || std.mem.Allocator.Error || HashPasswordError || GenTokenError;

/// Given the request data for an auth-collection record, return a copy with `passwordHash`,
/// `tokenKey`, and `verified` populated (plaintext `password` removed). Hashes the `password`.
/// `min_len` is the collection's minPasswordLength.
pub fn applyCreate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return error.PasswordTooShort;
    const pw = (data.object.get("password")) orelse return error.PasswordTooShort;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue; // never store the plaintext
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    try out.put(alloc, "verified", .{ .bool = false }); // never trust a client-supplied verified flag
    return .{ .object = out };
}

/// For an update: if `data` contains a new `password`, return a copy with a fresh `passwordHash`
/// and a rotated `tokenKey` (invalidating existing tokens), plaintext removed. If no password is
/// present, returns `data` unchanged.
pub fn applyUpdate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return data;
    const pw = data.object.get("password") orelse return data;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue;
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    return .{ .object = out };
}

test "applyCreate hashes the password, sets tokenKey/verified, strips plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyCreate rejects a short password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyCreate(std.testing.io, a, .{ .object = data }, 8));
}

test "applyUpdate rotates tokenKey when a new password is given, no-ops otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var with_pw: std.json.ObjectMap = .empty;
    try with_pw.put(a, "password", .{ .string = "longenough" });
    const updated = try applyUpdate(std.testing.io, a, .{ .object = with_pw }, 8);
    try std.testing.expect(updated.object.get("tokenKey") != null);
    try std.testing.expect(updated.object.get("password") == null);

    var no_pw: std.json.ObjectMap = .empty;
    try no_pw.put(a, "bio", .{ .string = "hi" });
    const same = try applyUpdate(std.testing.io, a, .{ .object = no_pw }, 8);
    try std.testing.expect(same.object.get("tokenKey") == null); // unchanged
    try std.testing.expectEqualStrings("hi", same.object.get("bio").?.string);
}

test "applyCreate forces verified=false even if the client sends verified=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}

pub const Authed = struct {
    record: std.json.Value, // the auth record with hidden fields stripped
    collection: []const u8,
    is_superuser: bool,
};

/// Current unix time from SQLite (keeps pure code clock-free).
fn nowUnix(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT unixepoch('now');");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Fetch an auth record's tokenKey by id from `table`. Null if absent.
fn tokenKeyFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

fn isUnsafe(m: http.Method) bool {
    return switch (m) { .POST, .PUT, .PATCH, .DELETE => true, else => false };
}

/// Constant-time slice equality (length is not secret).
fn ctEqlSlices(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= p ^ q;
    return diff == 0;
}

/// Build a record object for a _superusers row (id/email/verified; secrets excluded).
fn superuserRecord(alloc: std.mem.Allocator, conn: *db.Db, rid: []const u8) !?std.json.Value {
    var st = try conn.prepare("SELECT \"id\",\"email\",\"verified\" FROM \"_superusers\" WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, st.columnText(0)) });
    try obj.put(alloc, "email", .{ .string = try alloc.dupe(u8, st.columnText(1)) });
    try obj.put(alloc, "verified", .{ .bool = st.columnInt(2) != 0 });
    return .{ .object = obj };
}

/// Resolve the request's auth token (bearer or zb_auth cookie) to a record, or null if
/// absent/invalid. Enforces double-submit CSRF on the cookie + unsafe-method path.
/// `conn` is any open connection; `app` supplies jwt_secret. Does NOT touch app.pool.
pub fn authenticate(io: std.Io, alloc: std.mem.Allocator, app: anytype, ctx: *const http.RequestCtx, conn: *db.Db) !?Authed {
    _ = io;
    const bearer = ctx.bearerToken();
    const from_cookie = bearer == null;
    const token = bearer orelse (ctx.cookie("zb_auth") orelse return null);

    const claims = jwt.peekClaims(alloc, token) catch return null;
    if (claims.type != .auth) return null;

    if (from_cookie and isUnsafe(ctx.method)) {
        if (ctx.csrf_token.len == 0 or claims.csrf.len == 0) return null;
        if (!ctEqlSlices(claims.csrf, ctx.csrf_token)) return null;
    }

    const is_super = std.mem.eql(u8, claims.collection, "_superusers");
    const table = if (is_super) "_superusers" else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        break :blk col.name;
    };

    const tk = (tokenKeyFor(alloc, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = nowUnix(conn) catch return null;
    _ = jwt.verify(alloc, token, &key, now) catch return null;

    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col, claims.id) catch return null) orelse return null;
    };

    return Authed{ .record = rec, .collection = claims.collection, .is_superuser = is_super };
}

test "authenticate resolves a valid bearer token to its record" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    const authed = (try authenticate(app.io, a, &app, &ctx, &d)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("users", authed.collection);
    try std.testing.expectEqual(false, authed.is_superuser);
    try std.testing.expectEqualStrings("rec1", authed.record.object.get("id").?.string);
    try std.testing.expect(authed.record.object.get("tokenKey") == null);
}

test "authenticate rejects a token signed with the wrong key (returns null)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const wrong = crypto.deriveKey(app.jwt_secret, "different-key");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    try std.testing.expect((try authenticate(app.io, a, &app, &ctx, &d)) == null);
}

test "authenticate requires CSRF on the cookie + unsafe-method path" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .csrf = "csrf-abc", .iat = 0, .exp = 9999999999 }, &key);
    const cookie_hdr = try std.fmt.allocPrint(a, "zb_auth={s}", .{token});
    var bad = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .cookie_header = cookie_hdr };
    try std.testing.expect((try authenticate(app.io, a, &app, &bad, &d)) == null);
    var mismatch = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .cookie_header = cookie_hdr, .csrf_token = "csrf-WRONG" };
    try std.testing.expect((try authenticate(app.io, a, &app, &mismatch, &d)) == null);
    var ok = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .cookie_header = cookie_hdr, .csrf_token = "csrf-abc" };
    try std.testing.expect((try authenticate(app.io, a, &app, &ok, &d)) != null);
    var get = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .cookie_header = cookie_hdr };
    try std.testing.expect((try authenticate(app.io, a, &app, &get, &d)) != null);
}
