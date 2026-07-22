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
const addr = @import("addr.zig");

pub const status_pending = "pending";
pub const status_verified = "verified";

/// Minimum seconds between verification-email (re)sends for the same pending `(account, email)`
/// (#154 review I3). A re-request inside this window does not re-issue/resend — the API returns
/// 429 — so an authenticated member cannot amplify mail at an arbitrary recipient.
pub const resend_interval_s: i64 = 60;

pub const SenderError = error{
    /// A send's From is not a verified identity for the sending account (fail closed).
    SenderNotVerified,
    /// `email` is empty / malformed / contains control chars.
    InvalidSenderEmail,
    /// A verification (re)send was requested again within `resend_interval_s` (#154 I3).
    VerificationThrottled,
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
pub fn requestVerification(io: std.Io, alloc: std.mem.Allocator, w: *db.Db, account: []const u8, email_in: []const u8) SenderError!VerificationRequest {
    try validateEmail(email_in);
    // Normalize once (I1): store + look up the SAME canonical form suppression + verified-sender use.
    const email = try addr.normalize(alloc, email_in);
    errdefer alloc.free(email);

    // Existing row for this (account,email)? Decide verified/pending and read the row's age (seconds
    // since `updated`) INSIDE the step block, so we never dupe `status` (review: senders.zig:111 leak).
    var existing_id: ?[]const u8 = null;
    var existing_verified = false;
    var age_s: i64 = 0;
    {
        var st = try w.prepare("SELECT \"id\",\"status\",CAST((julianday('now')-julianday(\"updated\"))*86400 AS INTEGER) FROM \"_sender_identities\" WHERE \"account\"=?1 AND \"email\"=?2;");
        defer st.finalize();
        try st.bindText(1, account);
        try st.bindText(2, email);
        if (try st.step()) {
            existing_verified = std.mem.eql(u8, st.columnText(1), status_verified);
            age_s = st.columnInt(2);
            existing_id = try alloc.dupe(u8, st.columnText(0));
        }
    }

    if (existing_id) |eid| {
        errdefer alloc.free(eid);
        if (existing_verified) {
            return .{ .id = eid, .email = email, .token = "", .already_verified = true };
        }
        // Rate-limit re-sends (I3): a re-request inside the window does not re-issue/resend.
        if (age_s < resend_interval_s) return error.VerificationThrottled;
        // Re-issue a token on the pending row.
        const token = try crypto.genToken(io, alloc, 40);
        errdefer alloc.free(token);
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
    errdefer alloc.free(rid);
    const token = try crypto.genToken(io, alloc, 40);
    errdefer alloc.free(token);
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
pub fn confirm(alloc: std.mem.Allocator, w: *db.Db, account: []const u8, identity_id: []const u8, token: []const u8) SenderError!bool {
    if (token.len == 0) return false;

    // Fetch the pending row's token by (id, account), then compare CONSTANT-TIME (M1) — never let a
    // SQL `=` on the secret token leak a timing oracle. A missing row / wrong account / empty stored
    // token / mismatch all fail closed (false), indistinguishably.
    var stored: ?[]u8 = null;
    defer if (stored) |s| alloc.free(s);
    {
        var st = try w.prepare("SELECT \"verification_token\" FROM \"_sender_identities\" WHERE \"id\"=?1 AND \"account\"=?2 AND \"status\"=?3;");
        defer st.finalize();
        try st.bindText(1, identity_id);
        try st.bindText(2, account);
        try st.bindText(3, status_pending);
        if (try st.step()) stored = try alloc.dupe(u8, st.columnText(0));
    }
    const s = stored orelse return false;
    if (s.len == 0 or !crypto.timingSafeEql(s, token)) return false;

    var up = try w.prepare(
        "UPDATE \"_sender_identities\" SET \"status\"=?1, \"verified_at\"=datetime('now'), \"verification_token\"='', \"updated\"=datetime('now') " ++
            "WHERE \"id\"=?2 AND \"account\"=?3 AND \"status\"=?4;",
    );
    defer up.finalize();
    try up.bindText(1, status_verified);
    try up.bindText(2, identity_id);
    try up.bindText(3, account);
    try up.bindText(4, status_pending);
    _ = try up.step();
    return w.changesCount() > 0;
}

/// True iff `(account, email)` is a VERIFIED sender identity. Read-only; account-scoped. `email` is
/// normalized (I1) so the lookup agrees with how identities are stored + how suppression keys.
pub fn isVerified(alloc: std.mem.Allocator, reader: *db.Db, account: []const u8, email_in: []const u8) SenderError!bool {
    const email = try addr.normalize(alloc, email_in);
    defer alloc.free(email);
    var st = try reader.prepare("SELECT 1 FROM \"_sender_identities\" WHERE \"account\"=?1 AND \"email\"=?2 AND \"status\"=?3 LIMIT 1;");
    defer st.finalize();
    try st.bindText(1, account);
    try st.bindText(2, email);
    try st.bindText(3, status_verified);
    return st.step();
}

/// Fail-closed gate: returns `error.SenderNotVerified` when `(account, email)` is not a verified
/// identity. Called from the send path when verified-sender enforcement is enabled.
pub fn assertVerified(alloc: std.mem.Allocator, reader: *db.Db, account: []const u8, email: []const u8) SenderError!void {
    if (!try isVerified(alloc, reader, account, email)) return error.SenderNotVerified;
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
    const a = testing.allocator;

    const req = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    defer a.free(req.id);
    defer a.free(req.email);
    defer a.free(req.token);
    try testing.expect(!req.already_verified);
    try testing.expect(req.token.len > 0);
    // Not verified yet → enforcement would reject.
    try testing.expect(!try isVerified(a, &d, "acc1", "from@app.com"));
    try testing.expectError(error.SenderNotVerified, assertVerified(a, &d, "acc1", "from@app.com"));

    // Confirm with the right token → verified.
    try testing.expect(try confirm(a, &d, "acc1", req.id, req.token));
    try testing.expect(try isVerified(a, &d, "acc1", "from@app.com"));
    try assertVerified(a, &d, "acc1", "from@app.com");
}

test "isVerified + confirm are address-case-insensitive (I1 normalization)" {
    var d = try testDb();
    defer d.close();
    const a = testing.allocator;

    // Request with a mixed-case address; it is stored lowercased.
    const req = try requestVerification(testing.io, a, &d, "acc1", "From.User@App.COM");
    defer a.free(req.id);
    defer a.free(req.email);
    defer a.free(req.token);
    try testing.expectEqualStrings("from.user@app.com", req.email);
    try testing.expect(try confirm(a, &d, "acc1", req.id, req.token));
    // A send From a differently-cased spelling of the same address still matches the verified row.
    try testing.expect(try isVerified(a, &d, "acc1", "FROM.USER@app.com"));
    try assertVerified(a, &d, "acc1", "from.user@APP.com");
}

test "confirm fails closed on wrong token, wrong account, or replay" {
    var d = try testDb();
    defer d.close();
    const a = testing.allocator;

    const req = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    defer a.free(req.id);
    defer a.free(req.email);
    defer a.free(req.token);
    // Wrong token.
    try testing.expect(!try confirm(a, &d, "acc1", req.id, "not-the-token"));
    // Wrong account (cross-account verification blocked).
    try testing.expect(!try confirm(a, &d, "acc2", req.id, req.token));
    // Right token succeeds once…
    try testing.expect(try confirm(a, &d, "acc1", req.id, req.token));
    // …and a replay (token already cleared) fails closed.
    try testing.expect(!try confirm(a, &d, "acc1", req.id, req.token));
}

test "isVerified is account-scoped (no cross-account leak)" {
    var d = try testDb();
    defer d.close();
    const a = testing.allocator;

    const req = try requestVerification(testing.io, a, &d, "acc1", "shared@app.com");
    defer a.free(req.id);
    defer a.free(req.email);
    defer a.free(req.token);
    _ = try confirm(a, &d, "acc1", req.id, req.token);
    // acc1 verified; acc2 (same email, different account) is NOT.
    try testing.expect(try isVerified(a, &d, "acc1", "shared@app.com"));
    try testing.expect(!try isVerified(a, &d, "acc2", "shared@app.com"));
}

test "requestVerification is idempotent + reports already-verified" {
    var d = try testDb();
    defer d.close();
    const a = testing.allocator;

    const r1 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    defer a.free(r1.id);
    defer a.free(r1.email);
    defer a.free(r1.token);
    _ = try confirm(a, &d, "acc1", r1.id, r1.token);
    // Once verified, a re-request reports already-verified (no token, no throttle — it returns first).
    const r3 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    defer a.free(r3.id);
    defer a.free(r3.email);
    // On the already-verified path `token` is the "" literal (no token issued), never an owned
    // allocation — freeing it would be an invalid free. Only free a real issued token.
    defer if (r3.token.len > 0) a.free(r3.token);
    try testing.expect(r3.already_verified);
    try testing.expectEqualStrings("", r3.token);
    try testing.expectEqualStrings(r1.id, r3.id); // same row re-used

    // Exactly one row for (acc1, from@app.com).
    const list = try listForAccount(a, &d, "acc1");
    defer {
        for (list) |it| {
            a.free(it.id);
            a.free(it.email);
            a.free(it.status);
            a.free(it.verified_at);
            a.free(it.created);
        }
        a.free(list);
    }
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("verified", list[0].status);
}

test "requestVerification throttles a re-send within the window (I3)" {
    var d = try testDb();
    defer d.close();
    const a = testing.allocator;

    // First request issues a token; an immediate re-request (same second → age < interval) is throttled.
    const r1 = try requestVerification(testing.io, a, &d, "acc1", "from@app.com");
    defer a.free(r1.id);
    defer a.free(r1.email);
    defer a.free(r1.token);
    try testing.expect(r1.token.len > 0);
    try testing.expectError(error.VerificationThrottled, requestVerification(testing.io, a, &d, "acc1", "from@app.com"));
    // Still exactly one row, still pending with its original token (no resend, no row churn).
    const list = try listForAccount(a, &d, "acc1");
    defer {
        for (list) |it| {
            a.free(it.id);
            a.free(it.email);
            a.free(it.status);
            a.free(it.verified_at);
            a.free(it.created);
        }
        a.free(list);
    }
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("pending", list[0].status);
}
