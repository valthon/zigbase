//! Verified per-account sender identities (#154). An account proves control of a From address
//! before it may send as it. Backed by the `_sender_identities` system collection (migration
//! 0016): one row per `(account, email)`, `status` 'pending' → 'verified'.
//!
//! Flow: `requestVerification` mints a single-use token (status 'pending'); the account confirms via
//! `confirm` (a dedicated route delivers/accepts the token) which sets `status='verified'` +
//! `verified_at`. At send time `isVerified`/`assertVerified` gate the From address — enforcement is
//! OFF by default and only engages when the app sets `.mail = .{ .require_verified_sender = true }`
//! (see `mail/send.zig`), so existing simple-SMTP apps are unaffected.
//!
//! SECURITY: every query is parameter-bound and scoped to the caller's `account`. A confirm whose
//! `(account,id,token)` does not match exactly fails closed (no cross-account verification). The
//! token is compared in the DB by equality on an indexed column; callers must pass the account they
//! resolved from the request (never trust a client-supplied account).

const std = @import("std");
const db = @import("../db.zig");
const id_gen = @import("../id.zig");
const crypto = @import("../crypto.zig");

pub const status_pending = "pending";
pub const status_verified = "verified";

pub const SenderError = error{
    /// A send's From is not a verified identity for the sending account (fail closed).
    SenderNotVerified,
    /// `email` is empty / malformed / contains control chars.
    InvalidSenderEmail,
} || db.DbError || std.mem.Allocator.Error;

/// A sender identity row, as returned by `listForAccount` (allocated on the caller's arena).
pub const Identity = struct {
    id: []const u8,
    email: []const u8,
    status: []const u8,
    verified_at: []const u8,
    created: []const u8,
};

/// The result of `requestVerification`: the row id + the (single-use) token to deliver, and whether
/// the identity was ALREADY verified (in which case `token` is empty — nothing to confirm).
pub const VerificationRequest = struct {
    id: []const u8,
    email: []const u8,
    token: []const u8,
    already_verified: bool,
};

/// Light sender-email validation: non-empty, no control chars, looks like `local@domain`. Mirrors
/// the recipient check in `mail/send.zig` (kept local to avoid a cycle).
fn validateEmail(email: []const u8) SenderError!void {
    if (email.len == 0 or email.len > 254) return error.InvalidSenderEmail;
    for (email) |c| if (c < 32 or c == 127 or c == ' ') return error.InvalidSenderEmail;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return error.InvalidSenderEmail;
    if (at == 0 or at == email.len - 1) return error.InvalidSenderEmail;
    if (std.mem.indexOfScalarPos(u8, email, at + 1, '@') != null) return error.InvalidSenderEmail;
    if (std.mem.indexOfScalar(u8, email[at + 1 ..], '.') == null) return error.InvalidSenderEmail;
}

/// Request (or re-request) verification of `(account, email)`. On a `writer` connection. Inserts a
/// fresh 'pending' row (new token) when none exists; re-issues a token onto an existing pending row;
/// returns `already_verified=true` (empty token) when the identity is already verified. Idempotent
/// and account-scoped.
pub fn requestVerification(io: std.Io, alloc: std.mem.Allocator, w: *db.Db, account: []const u8, email: []const u8) SenderError!VerificationRequest {
    try validateEmail(email);

    // Existing row for this (account,email)?
    var existing_id: ?[]const u8 = null;
    var existing_status: []const u8 = "";
    {
        var st = try w.prepare("SELECT \"id\",\"status\" FROM \"_sender_identities\" WHERE \"account\"=?1 AND \"email\"=?2;");
        defer st.finalize();
        try st.bindText(1, account);
        try st.bindText(2, email);
        if (try st.step()) {
            existing_id = try alloc.dupe(u8, st.columnText(0));
            existing_status = try alloc.dupe(u8, st.columnText(1));
        }
    }

    if (existing_id) |eid| {
        if (std.mem.eql(u8, existing_status, status_verified)) {
            return .{ .id = eid, .email = email, .token = "", .already_verified = true };
        }
        // Re-issue a token on the pending row.
        const token = try crypto.genToken(io, alloc, 40);
        var up = try w.prepare("UPDATE \"_sender_identities\" SET \"verification_token\"=?1, \"updated\"=datetime('now') WHERE \"id\"=?2;");
        defer up.finalize();
        try up.bindText(1, token);
        try up.bindText(2, eid);
        _ = try up.step();
        return .{ .id = eid, .email = email, .token = token, .already_verified = false };
    }

    // Insert a fresh pending identity.
    var idbuf: [15]u8 = undefined;
    id_gen.generate(io, &idbuf);
    const rid = try alloc.dupe(u8, &idbuf);
    const token = try crypto.genToken(io, alloc, 40);
    var ins = try w.prepare(
        "INSERT INTO \"_sender_identities\" (\"id\",\"created\",\"updated\",\"account\",\"email\",\"verification_token\",\"status\") VALUES (?1,datetime('now'),datetime('now'),?2,?3,?4,?5);",
    );
    defer ins.finalize();
    try ins.bindText(1, rid);
    try ins.bindText(2, account);
    try ins.bindText(3, email);
    try ins.bindText(4, token);
    try ins.bindText(5, status_pending);
    _ = try ins.step();
    return .{ .id = rid, .email = email, .token = token, .already_verified = false };
}

/// Confirm a pending identity by `(account, id, token)`. Marks it verified (status + verified_at)
/// and returns true on success. Fails CLOSED — returns false — when the id does not exist, belongs
/// to another account, or the token does not match (no cross-account verification, no token oracle
/// beyond match/no-match). On a `writer` connection.
pub fn confirm(w: *db.Db, account: []const u8, identity_id: []const u8, token: []const u8) SenderError!bool {
    if (token.len == 0) return false;
    var up = try w.prepare(
        "UPDATE \"_sender_identities\" SET \"status\"=?1, \"verified_at\"=datetime('now'), \"verification_token\"='', \"updated\"=datetime('now') " ++
            "WHERE \"id\"=?2 AND \"account\"=?3 AND \"verification_token\"=?4 AND \"verification_token\"<>'';",
    );
    defer up.finalize();
    try up.bindText(1, status_verified);
    try up.bindText(2, identity_id);
    try up.bindText(3, account);
    try up.bindText(4, token);
    _ = try up.step();
    return w.changesCount() > 0;
}

/// True iff `(account, email)` is a VERIFIED sender identity. Read-only; account-scoped.
pub fn isVerified(reader: *db.Db, account: []const u8, email: []const u8) db.DbError!bool {
    var st = try reader.prepare("SELECT 1 FROM \"_sender_identities\" WHERE \"account\"=?1 AND \"email\"=?2 AND \"status\"=?3 LIMIT 1;");
    defer st.finalize();
    try st.bindText(1, account);
    try st.bindText(2, email);
    try st.bindText(3, status_verified);
    return st.step();
}

/// Fail-closed gate: returns `error.SenderNotVerified` when `(account, email)` is not a verified
/// identity. Called from the send path when verified-sender enforcement is enabled.
pub fn assertVerified(reader: *db.Db, account: []const u8, email: []const u8) SenderError!void {
    if (!try isVerified(reader, account, email)) return error.SenderNotVerified;
}

/// List `account`'s sender identities (newest first), allocated on `alloc`.
pub fn listForAccount(alloc: std.mem.Allocator, reader: *db.Db, account: []const u8) SenderError![]Identity {
    var out: std.ArrayList(Identity) = .empty;
    errdefer out.deinit(alloc);
    var st = try reader.prepare("SELECT \"id\",\"email\",\"status\",\"verified_at\",\"created\" FROM \"_sender_identities\" WHERE \"account\"=?1 ORDER BY \"created\" DESC;");
    defer st.finalize();
    try st.bindText(1, account);
    while (try st.step()) {
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .email = try alloc.dupe(u8, st.columnText(1)),
            .status = try alloc.dupe(u8, st.columnText(2)),
            .verified_at = try alloc.dupe(u8, st.columnText(3)),
            .created = try alloc.dupe(u8, st.columnText(4)),
        });
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("../migrations.zig");

fn testDb() !db.Db {
    var d = try db.Db.openMemory();
    errdefer d.close();
    try migrations.run(&d);
    return d;
}

test "validateEmail accepts plain addresses, rejects malformed" {
    try validateEmail("from@example.com");
    try testing.expectError(error.InvalidSenderEmail, validateEmail(""));
    try testing.expectError(error.InvalidSenderEmail, validateEmail("no-at"));
    try testing.expectError(error.InvalidSenderEmail, validateEmail("a@b"));
    try testing.expectError(error.InvalidSenderEmail, validateEmail("a@@b.com"));
    try testing.expectError(error.InvalidSenderEmail, validateEmail("a b@x.com"));
    try testing.expectError(error.InvalidSenderEmail, validateEmail("a@x.com\r\nBcc: e@v.io"));
}

test "requestVerification → confirm marks the identity verified" {
    var d = try testDb();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    try testing.expect(!req.already_verified);
    try testing.expect(req.token.len > 0);
    // Not verified yet → enforcement would reject.
    try testing.expect(!try isVerified(&d, "acc1", "from@app.com"));
    try testing.expectError(error.SenderNotVerified, assertVerified(&d, "acc1", "from@app.com"));

    // Confirm with the right token → verified.
    try testing.expect(try confirm(&d, "acc1", req.id, req.token));
    try testing.expect(try isVerified(&d, "acc1", "from@app.com"));
    try assertVerified(&d, "acc1", "from@app.com");
}

test "confirm fails closed on wrong token, wrong account, or replay" {
    var d = try testDb();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    // Wrong token.
    try testing.expect(!try confirm(&d, "acc1", req.id, "not-the-token"));
    // Wrong account (cross-account verification blocked).
    try testing.expect(!try confirm(&d, "acc2", req.id, req.token));
    // Right token succeeds once…
    try testing.expect(try confirm(&d, "acc1", req.id, req.token));
    // …and a replay (token already cleared) fails closed.
    try testing.expect(!try confirm(&d, "acc1", req.id, req.token));
}

test "isVerified is account-scoped (no cross-account leak)" {
    var d = try testDb();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = try requestVerification(testing.io, a, &d, "acc1", "shared@app.com");
    _ = try confirm(&d, "acc1", req.id, req.token);
    // acc1 verified; acc2 (same email, different account) is NOT.
    try testing.expect(try isVerified(&d, "acc1", "shared@app.com"));
    try testing.expect(!try isVerified(&d, "acc2", "shared@app.com"));
}

test "requestVerification is idempotent + reports already-verified" {
    var d = try testDb();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r1 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    const r2 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    try testing.expectEqualStrings(r1.id, r2.id); // same row re-used
    _ = try confirm(&d, "acc1", r2.id, r2.token);
    const r3 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    try testing.expect(r3.already_verified);
    try testing.expectEqualStrings("", r3.token);

    // Exactly one row for (acc1, from@app.com).
    const list = try listForAccount(a, &d, "acc1");
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("verified", list[0].status);
}
