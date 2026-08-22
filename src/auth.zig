const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const db = @import("db.zig");
const schema = @import("schema.zig");
const crypto = @import("crypto.zig");
const jwt = @import("jwt.zig");
const clock = @import("clock.zig");
const http = @import("http.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const param_sink = @import("sql/param_sink.zig");
const App = @import("app.zig").App;

/// Lower + renumber a curated token-VERIFICATION statement for `conn`'s backend, then prepare it.
/// SQLite gets the verbatim `?N` SQL (zero-cost — the same slice); Postgres gets `$n` placeholders
/// (`sql/param_sink.lowerStmtZ`). The verify path (`verifyTokenOfTypes`, hit on every authenticated
/// request) reads `_sessions`/auth-record/`_superusers` through here so it works on Postgres — the
/// mint path in `api/auth.zig` was already lowered, but verify lives here. The lowered SQL lives in
/// a transient arena (`Db.prepare` copies it), so it need only outlive the call.
fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lowered = param_sink.lowerStmtZ(arena.allocator(), db.dbDialect(conn), sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

const HashPasswordError = @typeInfo(@typeInfo(@TypeOf(crypto.hashPassword)).@"fn".return_type.?).error_union.error_set;
const GenTokenError = @typeInfo(@typeInfo(@TypeOf(crypto.genToken)).@"fn".return_type.?).error_union.error_set;

pub const AuthError = error{ PasswordTooShort, IdentityTaken } || db.DbError || std.mem.Allocator.Error || HashPasswordError || GenTokenError;

/// Fields the server fully controls; they must NEVER be copied from client-supplied data.
/// `password` is hashed server-side; `oldPassword` is a REQUEST-CONTROL field (verified by
/// the PATCH handler, never stored); `passwordHash`/`tokenKey` are set by the server;
/// `verified` changes only via the confirm-verification endpoint.
fn isServerManagedField(name: []const u8) bool {
    return std.mem.eql(u8, name, "password") or std.mem.eql(u8, name, "oldPassword") or
        std.mem.eql(u8, name, "passwordHash") or
        // Provider linkage decides WHO a record is: a client that could set it could hand
        // itself someone else's account. Only the operator-only import seam writes it.
        std.mem.eql(u8, name, "externalAuths") or
        std.mem.eql(u8, name, "tokenKey") or std.mem.eql(u8, name, "verified");
}

/// Insert a borrowed JSON value under an owned copy of `key`. Until `put`
/// succeeds the map cannot see the key allocation, so guard that handoff here
/// rather than repeating an easy-to-miss OOM edge at every caller.
fn putBorrowedField(alloc: std.mem.Allocator, out: *std.json.ObjectMap, key: []const u8, value: std.json.Value) std.mem.Allocator.Error!void {
    const owned_key = try alloc.dupe(u8, key);
    errdefer alloc.free(owned_key);
    try out.put(alloc, owned_key, value);
}

/// Given the request data for an auth-collection record, return a copy with `passwordHash`,
/// `tokenKey`, and `verified` populated (plaintext `password` removed). Hashes the `password`.
/// `min_len` is the collection's minPasswordLength.
pub fn applyCreate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return error.PasswordTooShort;
    const pw = (data.object.get("password")) orelse return error.PasswordTooShort;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    var phc: ?[]const u8 = try crypto.hashPassword(io, alloc, pw.string);
    errdefer if (phc) |p| alloc.free(p);
    var tk: ?[]const u8 = try crypto.genToken(io, alloc, 32);
    errdefer if (tk) |t| alloc.free(t);
    var out: std.json.ObjectMap = .empty;
    errdefer freeProvisioned(alloc, .{ .object = out });
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (isServerManagedField(e.key_ptr.*)) continue; // never copy server-managed credential fields
        try putBorrowedField(alloc, &out, e.key_ptr.*, e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc.? });
    phc = null;
    try out.put(alloc, "tokenKey", .{ .string = tk.? });
    tk = null;
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
        try putBorrowedField(alloc, &out, e.key_ptr.*, e.value_ptr.*);
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
    errdefer freeProvisioned(alloc, .{ .object = out });
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (isServerManagedField(e.key_ptr.*)) continue;
        try putBorrowedField(alloc, &out, e.key_ptr.*, e.value_ptr.*);
    }
    if (data.object.get("password")) |pw| {
        if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
        var phc: ?[]const u8 = try crypto.hashPassword(io, alloc, pw.string);
        errdefer if (phc) |p| alloc.free(p);
        var tk: ?[]const u8 = try crypto.genToken(io, alloc, 32);
        errdefer if (tk) |t| alloc.free(t);
        try out.put(alloc, "passwordHash", .{ .string = phc.? });
        phc = null;
        try out.put(alloc, "tokenKey", .{ .string = tk.? }); // rotate, invalidating existing tokens
        tk = null;
    }
    // `verified` is never written here; it changes only via confirm-verification.
    return .{ .object = out };
}

test "applyCreate hashes the password, sets tokenKey/verified, strips plaintext" {
    // applyCreate/applyProvision/applyUpdate all return a graph freeable via freeProvisioned, so
    // they run under the raw leak-detecting allocator.
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyProvision generates tokenKey/verified with NO password (passwordless flow)" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    // No password supplied -> no passwordHash, but a tokenKey is still generated.
    try std.testing.expect(out.object.get("passwordHash") == null);
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyProvision hashes a supplied password and still strips plaintext" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
}

test "applyProvision rejects a short password when one is supplied" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyProvision(std.testing.io, a, .{ .object = data }, 8));
}

test "applyProvision strips client-supplied tokenKey/verified (forces server values)" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "tokenKey", .{ .string = "client-supplied" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
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
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyCreate(std.testing.io, a, .{ .object = data }, 8));
}

test "applyUpdate rotates tokenKey when a new password is given, no-ops otherwise" {
    const a = std.testing.allocator;
    var with_pw: std.json.ObjectMap = .empty;
    defer with_pw.deinit(a);
    try with_pw.put(a, "password", .{ .string = "longenough" });
    const updated = try applyUpdate(std.testing.io, a, .{ .object = with_pw }, 8);
    defer freeProvisioned(a, updated);
    try std.testing.expect(updated.object.get("tokenKey") != null);
    try std.testing.expect(updated.object.get("password") == null);

    var no_pw: std.json.ObjectMap = .empty;
    defer no_pw.deinit(a);
    try no_pw.put(a, "bio", .{ .string = "hi" });
    const same = try applyUpdate(std.testing.io, a, .{ .object = no_pw }, 8);
    defer freeProvisioned(a, same);
    try std.testing.expect(same.object.get("tokenKey") == null); // unchanged
    try std.testing.expectEqualStrings("hi", same.object.get("bio").?.string);
}

test "applyCreate forces verified=false even if the client sends verified=true" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}

test "applyUpdate strips client-supplied passwordHash/tokenKey/verified (no password)" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "e@x.io" });
    try data.put(a, "verified", .{ .bool = true });
    try data.put(a, "passwordHash", .{ .string = "$argon2id$evil" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    const out = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expect(out.object.get("verified") == null);
    try std.testing.expect(out.object.get("passwordHash") == null);
    try std.testing.expect(out.object.get("tokenKey") == null);
    try std.testing.expectEqualStrings("e@x.io", out.object.get("email").?.string); // legit field kept
}

test "applyUpdate with password sets server passwordHash/tokenKey and ignores client ones" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expect(!std.mem.eql(u8, out.object.get("tokenKey").?.string, "evil")); // server-generated
    try std.testing.expect(out.object.get("verified") == null); // never client-set on update
}

test "applyCreate strips client passwordHash/tokenKey (forces server values)" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "e@x.io" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "passwordHash", .{ .string = "$argon2id$evil" });
    try data.put(a, "tokenKey", .{ .string = "evil" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
    try std.testing.expect(!std.mem.eql(u8, out.object.get("passwordHash").?.string, "$argon2id$evil"));
    try std.testing.expect(!std.mem.eql(u8, out.object.get("tokenKey").?.string, "evil"));
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}

test "applyUpdate with a too-short password leaks nothing" {
    const a = std.testing.allocator;
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "displayName", .{ .string = "someone" });
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyUpdate(std.testing.io, a, .{ .object = data }, 8));
}

fn applyCreateAllocationFailureCase(a: std.mem.Allocator) !void {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "oom@example.test" });
    try data.put(a, "displayName", .{ .string = "OOM probe" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
}

test "applyCreate is leak-free at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyCreateAllocationFailureCase,
        .{},
    );
}

fn applyProvisionAllocationFailureCase(a: std.mem.Allocator) !void {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "oom@example.test" });
    try data.put(a, "displayName", .{ .string = "OOM probe" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
}

test "applyProvision is leak-free at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyProvisionAllocationFailureCase,
        .{},
    );
}

fn applyUpdateAllocationFailureCase(a: std.mem.Allocator) !void {
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "displayName", .{ .string = "OOM probe" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, out);
}

test "applyUpdate is leak-free at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyUpdateAllocationFailureCase,
        .{},
    );
}

/// Free the owned strings shared by `Authed`/`Verified` (contract-2). `record` is a
/// self-contained json graph (duped keys + owned values, via `records.get`/`superuserRecord`);
/// `collection` and `sid` are freshly duped slices — none alias the input token, ctx, or a literal.
fn freeIdentity(alloc: std.mem.Allocator, record: std.json.Value, collection: []const u8, sid: []const u8) void {
    @import("records.zig").freeRecord(alloc, record);
    alloc.free(collection);
    alloc.free(sid);
}

pub const Authed = struct {
    record: std.json.Value, // the auth record with hidden fields stripped
    collection: []const u8,
    is_superuser: bool,
    /// Server-side session id (Variant B, #99); "" in epoch mode or when the token carries
    /// no `sid`. Lets logout/refresh target the exact `_sessions` row for this request.
    sid: []const u8 = "",

    /// Free the owned graph (contract-2). Must be the SAME allocator passed to `authenticate`.
    pub fn deinit(self: *Authed, alloc: std.mem.Allocator) void {
        freeIdentity(alloc, self.record, self.collection, self.sid);
    }

    /// Build a NON-owning `Authed` from borrowed data (string literals, a caller-owned record,
    /// arena-lifetime slices) — for test fixtures and callers that never transfer ownership.
    /// The owned-result path (`authenticate`) builds `Authed` directly; this is its explicit
    /// counterpart so a borrowed construction can't be copy-paste-confused for an owned one.
    /// Do NOT call `deinit` on the result — its `collection`/`record` are not owned by any single
    /// allocator, so `deinit` would free borrowed/literal memory.
    pub fn borrowed(record: std.json.Value, collection: []const u8, is_superuser: bool) Authed {
        return .{ .record = record, .collection = collection, .is_superuser = is_superuser };
    }
};

pub const Verified = struct {
    record: std.json.Value,
    collection: []const u8,
    is_superuser: bool,
    exp: i64,
    /// See `Authed.sid`.
    sid: []const u8 = "",

    /// Free the owned graph (contract-2). Must be the SAME allocator passed to `verifyToken*`.
    pub fn deinit(self: *Verified, alloc: std.mem.Allocator) void {
        freeIdentity(alloc, self.record, self.collection, self.sid);
    }
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
    // Contract-2 (owned-result): every transient parse/lookup (peekClaims, collections.get,
    // tokenKeyEpochFor, jwt.verify) lands on this scratch arena and is reclaimed on return; only
    // the record graph (owned on `alloc`) and the freshly-duped `collection`/`sid` escape, so the
    // returned `Verified` is a self-contained graph freed by `Verified.deinit` under any allocator.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const claims = jwt.peekClaims(sa, token) catch return null;
    var ok = false;
    for (types) |t| if (claims.type == t) {
        ok = true;
        break;
    };
    if (!ok) return null;
    const is_super = std.mem.eql(u8, claims.collection, "_superusers");
    // Resolve the collection once and reuse it for both the tokenKey lookup and the
    // record fetch — avoids a redundant collections.get on every authenticated request.
    const col_or_null = if (is_super) null else (collections.get(sa, conn, claims.collection) catch return null) orelse return null;
    const table = if (is_super) "_superusers" else col_or_null.?.name;
    // One SELECT fetches BOTH the signing-key material AND the current session epoch (#99),
    // so epoch revocation adds no extra query on the hot verify path.
    const ke = (tokenKeyEpochFor(sa, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, ke.token_key);
    const now = nowUnix(conn) catch return null;
    const verified = jwt.verify(sa, token, &key, now) catch return null;
    // Session-epoch gate: reject a token whose (signature-verified) epoch no longer matches
    // the record's current epoch — i.e. "revoke all sessions" was issued. Fail closed. Only
    // `.auth` session tokens are gated; short-lived `.file` tokens are minted separately and
    // carry no epoch, so a stale-epoch check must not strand a fresh file download token.
    if (verified.type == .auth and verified.token_epoch != ke.epoch) return null;
    // Variant B session gate (#99): in TABLE mode only, an `.auth` token carrying a `sid`
    // must reference a live `_sessions` row (present + unexpired) — per-device revocation.
    // Absent/expired/error → reject (fail closed, same discipline as the epoch check). In
    // epoch mode this whole block is skipped, so the verify hot path does ZERO extra work.
    const sid_scratch: []const u8 = verified.sid orelse "";
    if (app.session_store == .table and verified.type == .auth and sid_scratch.len > 0) {
        if (!(sessionActive(conn, sid_scratch, now) catch return null)) return null;
    }
    // The record graph is the one allocation that OUTLIVES the scratch arena, so build it on
    // `alloc` directly (owned; freed by `Verified.deinit` via records.freeRecord).
    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col_or_null.?, claims.id) catch return null) orelse return null;
    };
    // Dupe the two escaping strings onto `alloc` so nothing aliases the scratch parse (which is
    // about to drop), the input token, or a literal. On an OOM here, free what we already own.
    const collection = alloc.dupe(u8, claims.collection) catch {
        @import("records.zig").freeRecord(alloc, rec);
        return null;
    };
    const sid = alloc.dupe(u8, sid_scratch) catch {
        alloc.free(collection);
        @import("records.zig").freeRecord(alloc, rec);
        return null;
    };
    return .{ .record = rec, .collection = collection, .is_superuser = is_super, .exp = claims.exp, .sid = sid };
}

/// Variant B: true iff session `sid` exists and is unexpired (`expires IS NULL OR expires > now`).
/// Table-mode verify only — never called in epoch mode (gated by `session_store == .table`).
fn sessionActive(conn: *db.Db, sid: []const u8, now: i64) !bool {
    var st = try prep(conn, "SELECT 1 FROM \"_sessions\" WHERE \"id\" = ?1 AND (\"expires\" IS NULL OR \"expires\" > ?2);");
    defer st.finalize();
    try st.bindText(1, sid);
    try st.bindInt(2, now);
    return try st.step();
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
/// A NULL epoch (back-compat default) reads as 0; the column itself is guaranteed present by
/// migration 0010. Null when the row is absent.
fn tokenKeyEpochFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?KeyEpoch {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\", COALESCE(\"token_epoch\", 0) FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
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
/// Keys AND string values are duped onto `alloc` so the returned graph is self-contained and
/// symmetric with `records.get` — freeable by `records.freeRecord` (which frees keys), never
/// aliasing a string literal. On a mid-build OOM the partial graph is freed (leak-correct under
/// any allocator, not just a request arena).
fn superuserRecord(alloc: std.mem.Allocator, conn: *db.Db, rid: []const u8) !?std.json.Value {
    var st = try prep(conn, "SELECT \"id\",\"email\",\"verified\" FROM \"_superusers\" WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    var obj: std.json.ObjectMap = .empty;
    errdefer @import("records.zig").freeRecord(alloc, .{ .object = obj });
    try obj.ensureTotalCapacity(alloc, 3);
    try putOwnedString(alloc, &obj, "id", st.columnText(0));
    try putOwnedString(alloc, &obj, "email", st.columnText(1));
    // The bool value allocates nothing; only its key is duped. If this key-dupe OOMs, the
    // errdefer above frees the id/email entries already in place.
    obj.putAssumeCapacity(try alloc.dupe(u8, "verified"), .{ .bool = st.columnInt(2) != 0 });
    return .{ .object = obj };
}

/// Put a duped `key`→(duped `val` string) into a pre-sized object. Value is duped first so a
/// key-dupe OOM cannot strand it; on that OOM the value is freed before the error propagates.
fn putOwnedString(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, val: []const u8) !void {
    const v = try alloc.dupe(u8, val);
    errdefer alloc.free(v);
    const k = try alloc.dupe(u8, key);
    obj.putAssumeCapacity(k, .{ .string = v });
}

/// Resolve the request's auth token (bearer or zb_auth cookie) to a record, or null if
/// absent/invalid. Enforces double-submit CSRF on the cookie + unsafe-method path.
/// `conn` is any open connection; `app` supplies jwt_secret. Does NOT touch app.pool.
pub fn authenticate(io: std.Io, alloc: std.mem.Allocator, app: anytype, ctx: *const http.RequestCtx, conn: *db.Db) !?Authed {
    _ = io;
    const bearer = ctx.bearerToken();
    const from_cookie = bearer == null;
    const token = bearer orelse (ctx.cookie("zb_auth") orelse return null);

    // Pre-verify gate: token TYPE and (on the cookie path) CSRF, read from an UNVERIFIED
    // peek. Contract-3 (caller-buffer): the claims borrow the stack `scratch`, and the whole
    // gate is deliberately SCOPED to a block so both go out of scope before `verifyToken`.
    // That makes the borrow's safety local and compiler-enforced: nothing below can reference
    // these claims — in particular they cannot be threaded into `verifyToken` to save its
    // re-parse, which is the one change that would let a stack borrow escape into the returned
    // `Authed`. An over-large token was already rejected inside `peekClaims`.
    {
        // align(8) so the FixedBufferAllocator wastes no bytes aligning its first allocation
        // (Claims holds i64/slice fields needing 8-byte alignment), which also makes the
        // scratch_size worst-case deterministic rather than stack-address dependent.
        var scratch: [jwt.scratch_size]u8 align(8) = undefined;
        const claims = jwt.peekClaimsInto(&scratch, token) catch return null;
        if (claims.type != .auth) return null;
        if (from_cookie and isUnsafe(ctx.method)) {
            if (ctx.csrf_token.len == 0 or claims.csrf.len == 0) return null;
            if (!ctEqlSlices(claims.csrf, ctx.csrf_token)) return null;
        }
    }
    // `v` is a contract-2 owned graph on `alloc`. The returned `Authed` TAKES OWNERSHIP of its
    // record/collection/sid (we do not deinit `v`); only the scalar `exp` is dropped. So a single
    // `Authed.deinit(alloc)` frees exactly this graph — no double-free, no leak.
    const v = verifyToken(alloc, app, conn, token) orelse return null;
    return Authed{ .record = v.record, .collection = v.collection, .is_superuser = v.is_superuser, .sid = v.sid };
}

test "authenticate resolves a valid bearer token to its record" {
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var created = try collections.create(a, std.testing.io, &d, .{
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
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(token);
    const authz = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    defer a.free(authz);
    var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(a), .authorization = authz };
    var authed = (try authenticate(app.io, a, &app, &ctx, &d)) orelse return error.TestUnexpectedNull;
    defer authed.deinit(a);
    try std.testing.expectEqualStrings("users", authed.collection);
    try std.testing.expectEqual(false, authed.is_superuser);
    try std.testing.expectEqualStrings("rec1", authed.record.object.get("id").?.string);
    try std.testing.expect(authed.record.object.get("tokenKey") == null);
}

test "authenticate rejects a token signed with the wrong key (returns null)" {
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var created = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const wrong = crypto.deriveKey(app.jwt_secret, "different-key");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    defer a.free(token);
    const authz = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    defer a.free(authz);
    var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(a), .authorization = authz };
    try std.testing.expect((try authenticate(app.io, a, &app, &ctx, &d)) == null);
}

test "authenticate requires CSRF on the cookie + unsafe-method path" {
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var created = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .csrf = "csrf-abc", .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(token);
    const cookie_hdr = try std.fmt.allocPrint(a, "zb_auth={s}", .{token});
    defer a.free(cookie_hdr);
    var bad = http.RequestCtx{ .method = .POST, .path = "/", .allocator = RequestArena.forTest(a), .cookie_header = cookie_hdr };
    try std.testing.expect((try authenticate(app.io, a, &app, &bad, &d)) == null);
    var mismatch = http.RequestCtx{ .method = .POST, .path = "/", .allocator = RequestArena.forTest(a), .cookie_header = cookie_hdr, .csrf_token = "csrf-WRONG" };
    try std.testing.expect((try authenticate(app.io, a, &app, &mismatch, &d)) == null);
    var ok = http.RequestCtx{ .method = .POST, .path = "/", .allocator = RequestArena.forTest(a), .cookie_header = cookie_hdr, .csrf_token = "csrf-abc" };
    {
        var au = (try authenticate(app.io, a, &app, &ok, &d)) orelse return error.TestUnexpectedNull;
        au.deinit(a);
    }
    var get = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(a), .cookie_header = cookie_hdr };
    {
        var au = (try authenticate(app.io, a, &app, &get, &d)) orelse return error.TestUnexpectedNull;
        au.deinit(a);
    }
}

test "verifyToken resolves a valid token string to a record + exp" {
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var created = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(token);
    var v = verifyToken(a, &app, &d, token) orelse return error.TestUnexpectedNull;
    defer v.deinit(a);
    try std.testing.expectEqualStrings("users", v.collection);
    try std.testing.expectEqual(false, v.is_superuser);
    try std.testing.expectEqual(@as(i64, 9999999999), v.exp);
    try std.testing.expectEqualStrings("rec1", v.record.object.get("id").?.string);
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    defer a.free(bad);
    try std.testing.expect(verifyToken(a, &app, &d, bad) == null);
}

test "verifyTokenOfTypes accepts a file token only when allowed" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    var created = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk");
    const file_tok = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(file_tok);
    try std.testing.expect(verifyToken(a, &app, &d, file_tok) == null);
    {
        var v = verifyTokenOfTypes(a, &app, &d, file_tok, &.{ .auth, .file }) orelse return error.TestUnexpectedNull;
        v.deinit(a);
    }
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &wrong);
    defer a.free(bad);
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, bad, &.{ .auth, .file }) == null);
}

test "verifyTokenOfTypes rejects a full .auth token under .file-only (file ?token= contract)" {
    // The file-download `?token=` path (api/files.zig fileIdentity) accepts ONLY `.file` tokens,
    // so a full session (`.auth`) token can never authenticate a download via a URL query param
    // (which would leak the session token into logs / Referer / history). Pin that type gate.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var created = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer created.deinit(a);
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk");
    const auth_tok = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(auth_tok);
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, auth_tok, &.{.file}) == null); // rejected: file-only
    {
        var v = verifyTokenOfTypes(a, &app, &d, auth_tok, &.{.auth}) orelse return error.TestUnexpectedNull; // sanity: valid .auth token
        v.deinit(a);
    }
}

test "applyCreate/applyProvision/applyUpdate strip a client-supplied externalAuths" {
    // Provider linkage decides WHO a record is: whoever holds `(provider, providerId)` signs in
    // as that record. It is installed only by the operator-only import seam
    // (`zigbase import --external-auths`), so every request-payload path drops the key —
    // create and update alike, and whether or not the collection declares such a field.
    const a = std.testing.allocator;
    var entry: std.json.ObjectMap = .empty;
    defer entry.deinit(a);
    try entry.put(a, "provider", .{ .string = "google" });
    try entry.put(a, "providerId", .{ .string = "attacker-controlled" });
    var links: std.json.Array = .init(a);
    defer links.deinit();
    try links.append(.{ .object = entry });

    var data: std.json.ObjectMap = .empty;
    defer data.deinit(a);
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "externalAuths", .{ .array = links });

    const created = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, created);
    try std.testing.expect(created.object.get("externalAuths") == null);

    const provisioned = try applyProvision(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, provisioned);
    try std.testing.expect(provisioned.object.get("externalAuths") == null);

    const updated = try applyUpdate(std.testing.io, a, .{ .object = data }, 8);
    defer freeProvisioned(a, updated);
    try std.testing.expect(updated.object.get("externalAuths") == null);
    try std.testing.expectEqualStrings("a@b.c", updated.object.get("email").?.string); // legit field kept
}
