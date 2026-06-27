const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const crypto = @import("crypto.zig");
const jwt = @import("jwt.zig");
const clock = @import("clock.zig");
const http = @import("http.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const App = @import("app.zig").App;

const HashPasswordError = @typeInfo(@typeInfo(@TypeOf(crypto.hashPassword)).@"fn".return_type.?).error_union.error_set;
const GenTokenError = @typeInfo(@typeInfo(@TypeOf(crypto.genToken)).@"fn".return_type.?).error_union.error_set;

pub const AuthError = error{ PasswordTooShort, IdentityTaken } || db.DbError || std.mem.Allocator.Error || HashPasswordError || GenTokenError;

/// Fields the server fully controls; they must NEVER be copied from client-supplied data.
/// `password` is hashed server-side; `passwordHash`/`tokenKey` are set by the server; `verified`
/// changes only via the confirm-verification endpoint.
fn isServerManagedField(name: []const u8) bool {
    return std.mem.eql(u8, name, "password") or std.mem.eql(u8, name, "passwordHash") or
        std.mem.eql(u8, name, "tokenKey") or std.mem.eql(u8, name, "verified");
}

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
        if (isServerManagedField(e.key_ptr.*)) continue; // never copy server-managed credential fields
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    try out.put(alloc, "verified", .{ .bool = false }); // never trust a client-supplied verified flag
    return .{ .object = out };
}

/// Programmatic-provisioning variant of `applyCreate` for auth records created via the
/// `Data` facade (not the HTTP layer). Unlike `applyCreate`, a `password` is OPTIONAL —
/// a passwordless flow (magic-link signup) provisions a credential-less row. The server
/// always generates a `tokenKey` (so `issueSession`/`mintLinkToken` work) and forces
/// `verified=false`; when a `password` IS supplied it is hashed (and length-checked
/// against `min_len`). Client-supplied server-managed fields are always stripped.
pub fn applyProvision(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return error.PasswordTooShort;

    // Validate + allocate the owned credentials up front so the error paths below
    // (short password, hash/token failure) can't leak a half-built object map.
    var phc: ?[]const u8 = null;
    errdefer if (phc) |p| alloc.free(p);
    if (data.object.get("password")) |pw| {
        if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
        phc = try crypto.hashPassword(io, alloc, pw.string);
    }
    var tk: ?[]const u8 = try crypto.genToken(io, alloc, 32);
    errdefer if (tk) |t| alloc.free(t);

    var out: std.json.ObjectMap = .empty;
    errdefer freeProvisioned(alloc, .{ .object = out }); // free duped keys + owned cred strings on failure

    var it = data.object.iterator();
    while (it.next()) |e| {
        if (isServerManagedField(e.key_ptr.*)) continue; // never copy server-managed credential fields
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    // Once a cred string is in `out`, `out` owns it (freeProvisioned frees it). Null the
    // local so the per-string errdefer above won't ALSO free it on a later error — running
    // both cleanups would be a double-free.
    if (phc) |p| {
        try out.put(alloc, "passwordHash", .{ .string = p });
        phc = null;
    }
    try out.put(alloc, "tokenKey", .{ .string = tk.? });
    tk = null;
    try out.put(alloc, "verified", .{ .bool = false }); // never trust a client-supplied verified flag
    return .{ .object = out };
}

/// Free a value returned by `applyProvision`. Frees what `applyProvision` *owns*: the
/// duplicated field-name keys and the generated `passwordHash`/`tokenKey` strings. The
/// copied field *values* are borrowed from the caller's input (a shallow `json.Value`
/// copy), so they are never freed here. Literal map keys (`passwordHash`/`tokenKey`/
/// `verified`) are static and also skipped. Callers using an arena can ignore this.
pub fn freeProvisioned(alloc: std.mem.Allocator, provisioned: std.json.Value) void {
    if (provisioned != .object) return;
    var obj = provisioned.object;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        // The three server-set fields use static-literal keys (not duped); skip them.
        if (std.mem.eql(u8, k, "passwordHash") or std.mem.eql(u8, k, "tokenKey") or std.mem.eql(u8, k, "verified")) continue;
        alloc.free(k);
    }
    if (obj.get("passwordHash")) |ph| alloc.free(ph.string);
    if (obj.get("tokenKey")) |tk| alloc.free(tk.string);
    obj.deinit(alloc);
}

/// For an update: if `data` contains a new `password`, return a copy with a fresh `passwordHash`
/// and a rotated `tokenKey` (invalidating existing tokens), plaintext removed. If no password is
/// present, returns `data` unchanged.
pub fn applyUpdate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return data;
    // Always return a stripped copy: client-supplied server-managed fields are never written.
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (isServerManagedField(e.key_ptr.*)) continue;
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    if (data.object.get("password")) |pw| {
        if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
        const phc = try crypto.hashPassword(io, alloc, pw.string);
        const tk = try crypto.genToken(io, alloc, 32);
        try out.put(alloc, "passwordHash", .{ .string = phc });
        try out.put(alloc, "tokenKey", .{ .string = tk }); // rotate, invalidating existing tokens
    }
    // `verified` is never written here; it changes only via confirm-verification.
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

test "applyProvision generates tokenKey/verified with NO password (passwordless flow)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    // No password supplied -> no passwordHash, but a tokenKey is still generated.
    try std.testing.expect(out.object.get("passwordHash") == null);
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyProvision hashes a supplied password and still strips plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
}

test "applyProvision rejects a short password when one is supplied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyProvision(std.testing.io, a, .{ .object = data }, 8));
}

test "applyProvision strips client-supplied tokenKey/verified (forces server values)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "tokenKey", .{ .string = "client-supplied" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(!std.mem.eql(u8, out.object.get("tokenKey").?.string, "client-supplied"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}

test "applyProvision + freeProvisioned leak nothing under the gpa (passwordless)" {
    // Run directly on the leak-checking testing allocator (no arena): applyProvision owns
    // the duped keys + generated tokenKey, and freeProvisioned must release exactly them.
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    freeProvisioned(a, out);
}

test "applyProvision + freeProvisioned leak nothing under the gpa (with password)" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    freeProvisioned(a, out);
}

test "applyProvision short-password failure leaks nothing under the gpa" {
    // Validation runs before any allocation, so the error path must allocate nothing.
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyProvision(std.testing.io, a, .{ .object = data }, 8));
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

test "applyUpdate strips client-supplied passwordHash/tokenKey/verified (no password)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "e@x.io" });
    try data.put(a, "verified", .{ .bool = true });
    try data.put(a, "passwordHash", .{ .string = "$argon2id$evil" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    const out = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(out.object.get("verified") == null);
    try std.testing.expect(out.object.get("passwordHash") == null);
    try std.testing.expect(out.object.get("tokenKey") == null);
    try std.testing.expectEqualStrings("e@x.io", out.object.get("email").?.string); // legit field kept
}

test "applyUpdate with password sets server passwordHash/tokenKey and ignores client ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expect(!std.mem.eql(u8, out.object.get("tokenKey").?.string, "evil")); // server-generated
    try std.testing.expect(out.object.get("verified") == null); // never client-set on update
}

test "applyCreate strips client passwordHash/tokenKey (forces server values)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "e@x.io" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "passwordHash", .{ .string = "$argon2id$evil" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(!std.mem.eql(u8, out.object.get("passwordHash").?.string, "$argon2id$evil"));
    try std.testing.expect(!std.mem.eql(u8, out.object.get("tokenKey").?.string, "evil"));
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}

pub const Authed = struct {
    record: std.json.Value, // the auth record with hidden fields stripped
    collection: []const u8,
    is_superuser: bool,
};

pub const Verified = struct {
    record: std.json.Value,
    collection: []const u8,
    is_superuser: bool,
    exp: i64,
};

/// Resolve a JWT string to a verified identity (no HTTP ctx, no CSRF — the caller owns transport).
/// peek claims → require type==.auth → load tokenKey → derive key → jwt.verify against SQLite now →
/// load the record (hidden fields stripped). null on any failure.
pub fn verifyToken(alloc: std.mem.Allocator, app: anytype, conn: *db.Db, token: []const u8) ?Verified {
    return verifyTokenOfTypes(alloc, app, conn, token, &.{.auth});
}

/// Like verifyToken but accepts any of `types` for the claim's `type`. The file endpoint uses
/// {.auth, .file}; the main API uses verifyToken (.auth only).
pub fn verifyTokenOfTypes(alloc: std.mem.Allocator, app: anytype, conn: *db.Db, token: []const u8, types: []const jwt.TokenType) ?Verified {
    const claims = jwt.peekClaims(alloc, token) catch return null;
    var ok = false;
    for (types) |t| if (claims.type == t) {
        ok = true;
        break;
    };
    if (!ok) return null;
    const is_super = std.mem.eql(u8, claims.collection, "_superusers");
    // Resolve the collection once and reuse it for both the tokenKey lookup and the
    // record fetch — avoids a redundant collections.get on every authenticated request.
    const col_or_null = if (is_super) null else (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
    const table = if (is_super) "_superusers" else col_or_null.?.name;
    // One SELECT fetches BOTH the signing-key material AND the current session epoch (#99),
    // so epoch revocation adds no extra query on the hot verify path.
    const ke = (tokenKeyEpochFor(alloc, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, ke.token_key);
    const now = nowUnix(conn) catch return null;
    const verified = jwt.verify(alloc, token, &key, now) catch return null;
    // Session-epoch gate: reject a token whose (signature-verified) epoch no longer matches
    // the record's current epoch — i.e. "revoke all sessions" was issued. Fail closed. Only
    // `.auth` session tokens are gated; short-lived `.file` tokens are minted separately and
    // carry no epoch, so a stale-epoch check must not strand a fresh file download token.
    if (verified.type == .auth and verified.token_epoch != ke.epoch) return null;
    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col_or_null.?, claims.id) catch return null) orelse return null;
    };
    return .{ .record = rec, .collection = claims.collection, .is_superuser = is_super, .exp = claims.exp };
}

pub fn nowUnixPub(conn: *db.Db) db.DbError!i64 {
    return nowUnix(conn);
}

/// Current unix time for token verification, via the clock seam (honors the dev-only
/// `ZIGBASE_FAKE_NOW` override so expiry checks agree with the frozen clock).
fn nowUnix(conn: *db.Db) db.DbError!i64 {
    return clock.sqlNowUnix(conn);
}

const KeyEpoch = struct { token_key: []const u8, epoch: i64 };

/// Fetch an auth record's `tokenKey` AND its session `token_epoch` (#99) in one SELECT.
/// A NULL/absent epoch column reads as 0 (back-compat). Null when the row is absent.
fn tokenKeyEpochFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?KeyEpoch {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\", COALESCE(\"token_epoch\", 0) FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return .{ .token_key = try alloc.dupe(u8, st.columnText(0)), .epoch = st.columnInt(1) };
}

fn isUnsafe(m: http.Method) bool {
    return switch (m) {
        .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
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
    const v = verifyToken(alloc, app, conn, token) orelse return null;
    return Authed{ .record = v.record, .collection = v.collection, .is_superuser = v.is_superuser };
}

test "authenticate resolves a valid bearer token to its record" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        .listRule = "",
        .viewRule = "",
        .createRule = "",
        .updateRule = "",
        .deleteRule = "",
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
        .id = "",
        .name = "users",
        .type = .auth,
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
        .id = "",
        .name = "users",
        .type = .auth,
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

test "verifyToken resolves a valid token string to a record + exp" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const v = verifyToken(a, &app, &d, token) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("users", v.collection);
    try std.testing.expectEqual(false, v.is_superuser);
    try std.testing.expectEqual(@as(i64, 9999999999), v.exp);
    try std.testing.expectEqualStrings("rec1", v.record.object.get("id").?.string);
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    try std.testing.expect(verifyToken(a, &app, &d, bad) == null);
}

test "verifyTokenOfTypes accepts a file token only when allowed" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk");
    const file_tok = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &key);
    try std.testing.expect(verifyToken(a, &app, &d, file_tok) == null);
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, file_tok, &.{ .auth, .file }) != null);
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &wrong);
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, bad, &.{ .auth, .file }) == null);
}
