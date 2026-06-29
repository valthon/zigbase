//! Bounce/complaint suppression list (#154). When a provider reports a HARD bounce or a complaint
//! (spam report) for a recipient, that address is added to `_suppressions` (migration 0016) and
//! future sends to it are BLOCKED at send time (`assertNotSuppressed`) — protecting sender
//! reputation. Suppression checking is OFF by default and engages only when the app sets
//! `.mail = .{ .check_suppression = true }` (see `mail/send.zig`).
//!
//! Scope: a suppression row carries an `account`. An empty account is a GLOBAL suppression (blocks
//! every account); a non-empty account blocks only that account. `isSuppressed(account,email)`
//! matches `email` against rows whose account is `''` OR the caller's account — so a per-tenant
//! bounce never silently blocks another tenant, while a platform-wide block still works.
//!
//! Provider mapping (`parseProvider`) normalizes SES (SNS) and Postmark webhook payloads into
//! `Event{email,reason}`. Only PERMANENT bounces and complaints suppress; transient/soft bounces and
//! deliveries are ignored (returned as no events) so a temporary failure never blackholes a address.

const std = @import("std");
const db = @import("../db.zig");
const id_gen = @import("../id.zig");

pub const reason_hard_bounce = "hard_bounce";
pub const reason_complaint = "complaint";

/// Inbound providers whose bounce/complaint payloads we can normalize.
pub const Provider = enum { ses, postmark };

/// A normalized suppression event: `email` should be suppressed for `reason`.
pub const Event = struct {
    email: []const u8,
    reason: []const u8,
};

pub const SuppressionError = error{
    /// A send to a suppressed recipient (fail closed).
    RecipientSuppressed,
} || db.DbError || std.mem.Allocator.Error;

/// Upsert a suppression for `(account, email)`. Idempotent: a repeat with a different reason/source
/// updates them (the row's `created` is preserved). On a `writer` connection.
pub fn upsert(io: std.Io, w: *db.Db, account: []const u8, email: []const u8, reason: []const u8, source: []const u8) db.DbError!void {
    var idbuf: [15]u8 = undefined;
    id_gen.generate(io, &idbuf);
    var st = try w.prepare(
        "INSERT INTO \"_suppressions\" (\"id\",\"created\",\"account\",\"email\",\"reason\",\"source\") VALUES (?1,datetime('now'),?2,?3,?4,?5) " ++
            "ON CONFLICT(\"account\",\"email\") DO UPDATE SET \"reason\"=excluded.\"reason\", \"source\"=excluded.\"source\";",
    );
    defer st.finalize();
    try st.bindText(1, &idbuf);
    try st.bindText(2, account);
    try st.bindText(3, email);
    try st.bindText(4, reason);
    try st.bindText(5, source);
    _ = try st.step();
}

/// True iff `email` is suppressed for `account` — i.e. a row exists with this email AND an account
/// of `''` (global) OR `account`. Read-only.
pub fn isSuppressed(reader: *db.Db, account: []const u8, email: []const u8) db.DbError!bool {
    var st = try reader.prepare("SELECT 1 FROM \"_suppressions\" WHERE \"email\"=?1 AND (\"account\"='' OR \"account\"=?2) LIMIT 1;");
    defer st.finalize();
    try st.bindText(1, email);
    try st.bindText(2, account);
    return st.step();
}

/// Fail-closed gate: `error.RecipientSuppressed` when `email` is suppressed for `account`.
pub fn assertNotSuppressed(reader: *db.Db, account: []const u8, email: []const u8) SuppressionError!void {
    if (try isSuppressed(reader, account, email)) return error.RecipientSuppressed;
}

/// Parse a provider webhook body into normalized suppression events (allocated on `alloc`). A
/// payload with no permanent-bounce/complaint recipients yields an empty slice. Malformed JSON →
/// `error.SyntaxError` (the caller maps it to a 400).
pub fn parseProvider(alloc: std.mem.Allocator, provider: Provider, body: []const u8) ![]Event {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    // parsed borrows `alloc`; caller owns the arena (no deinit needed for arena-allocated).
    return switch (provider) {
        .ses => mapSes(alloc, parsed.value),
        .postmark => mapPostmark(alloc, parsed.value),
    };
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

/// Map an SES event (direct, or SNS-wrapped with the SES message stringified in `Message`).
fn mapSes(alloc: std.mem.Allocator, root_in: std.json.Value) ![]Event {
    // SNS delivers the SES notification JSON as a STRING in the `Message` field; unwrap it.
    var root = root_in;
    var inner_parsed: ?std.json.Parsed(std.json.Value) = null;
    if (strField(root_in, "Message")) |msg| {
        if (std.json.parseFromSlice(std.json.Value, alloc, msg, .{})) |p| {
            inner_parsed = p;
            root = p.value;
        } else |_| {}
    }

    var out: std.ArrayList(Event) = .empty;
    errdefer out.deinit(alloc);

    const kind = strField(root, "notificationType") orelse strField(root, "eventType") orelse "";
    if (std.mem.eql(u8, kind, "Bounce")) {
        const bounce = root.object.get("bounce") orelse return out.toOwnedSlice(alloc);
        // Only PERMANENT bounces suppress.
        const btype = strField(bounce, "bounceType") orelse "";
        if (!std.mem.eql(u8, btype, "Permanent")) return out.toOwnedSlice(alloc);
        if (bounce.object.get("bouncedRecipients")) |recips| {
            if (recips == .array) for (recips.array.items) |r| {
                if (strField(r, "emailAddress")) |e| try out.append(alloc, .{ .email = e, .reason = reason_hard_bounce });
            };
        }
    } else if (std.mem.eql(u8, kind, "Complaint")) {
        const complaint = root.object.get("complaint") orelse return out.toOwnedSlice(alloc);
        if (complaint.object.get("complainedRecipients")) |recips| {
            if (recips == .array) for (recips.array.items) |r| {
                if (strField(r, "emailAddress")) |e| try out.append(alloc, .{ .email = e, .reason = reason_complaint });
            };
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Map a Postmark webhook. `RecordType` "Bounce" with a hard `Type`, or "SpamComplaint", suppress.
fn mapPostmark(alloc: std.mem.Allocator, root: std.json.Value) ![]Event {
    var out: std.ArrayList(Event) = .empty;
    errdefer out.deinit(alloc);
    const record_type = strField(root, "RecordType") orelse "";
    const email = strField(root, "Email") orelse "";
    if (email.len == 0) return out.toOwnedSlice(alloc);

    if (std.mem.eql(u8, record_type, "SpamComplaint")) {
        try out.append(alloc, .{ .email = email, .reason = reason_complaint });
    } else if (std.mem.eql(u8, record_type, "Bounce")) {
        // Postmark `Type`: HardBounce / SpamNotification suppress; transient types don't.
        const ptype = strField(root, "Type") orelse "";
        if (std.mem.eql(u8, ptype, "HardBounce") or std.mem.eql(u8, ptype, "BadEmailAddress")) {
            try out.append(alloc, .{ .email = email, .reason = reason_hard_bounce });
        } else if (std.mem.eql(u8, ptype, "SpamNotification") or std.mem.eql(u8, ptype, "SpamComplaint")) {
            try out.append(alloc, .{ .email = email, .reason = reason_complaint });
        }
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

test "upsert + isSuppressed: account-scoped and global" {
    var d = try testDb();
    defer d.close();
    try upsert(testing.io, &d, "acc1", "bad@x.io", reason_hard_bounce, "ses");
    // acc1 blocked; acc2 not (per-tenant isolation).
    try testing.expect(try isSuppressed(&d, "acc1", "bad@x.io"));
    try testing.expect(!try isSuppressed(&d, "acc2", "bad@x.io"));
    try testing.expectError(error.RecipientSuppressed, assertNotSuppressed(&d, "acc1", "bad@x.io"));
    try assertNotSuppressed(&d, "acc2", "bad@x.io");

    // A GLOBAL suppression (empty account) blocks everyone.
    try upsert(testing.io, &d, "", "spammer@x.io", reason_complaint, "postmark");
    try testing.expect(try isSuppressed(&d, "acc1", "spammer@x.io"));
    try testing.expect(try isSuppressed(&d, "acc2", "spammer@x.io"));
}

test "upsert is idempotent (no duplicate row, reason updates)" {
    var d = try testDb();
    defer d.close();
    try upsert(testing.io, &d, "acc1", "x@y.io", reason_hard_bounce, "ses");
    try upsert(testing.io, &d, "acc1", "x@y.io", reason_complaint, "postmark");
    var c = try d.prepare("SELECT COUNT(*), reason, source FROM \"_suppressions\" WHERE account='acc1' AND email='x@y.io';");
    defer c.finalize();
    _ = try c.step();
    try testing.expectEqual(@as(i64, 1), c.columnInt(0));
    try testing.expectEqualStrings("complaint", c.columnText(1));
    try testing.expectEqualStrings("postmark", c.columnText(2));
}

test "parseProvider SES: permanent bounce suppresses, transient does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hard =
        \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"a@x.io"},{"emailAddress":"b@x.io"}]}}
    ;
    const evs = try parseProvider(a, .ses, hard);
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqualStrings("a@x.io", evs[0].email);
    try testing.expectEqualStrings("hard_bounce", evs[0].reason);

    const soft =
        \\{"notificationType":"Bounce","bounce":{"bounceType":"Transient","bouncedRecipients":[{"emailAddress":"c@x.io"}]}}
    ;
    try testing.expectEqual(@as(usize, 0), (try parseProvider(a, .ses, soft)).len);
}

test "parseProvider SES: complaint suppresses; SNS-wrapped Message is unwrapped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The SES notification arrives as a stringified `Message` inside an SNS envelope.
    const wrapped =
        \\{"Type":"Notification","Message":"{\"notificationType\":\"Complaint\",\"complaint\":{\"complainedRecipients\":[{\"emailAddress\":\"spam@x.io\"}]}}"}
    ;
    const evs = try parseProvider(a, .ses, wrapped);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings("spam@x.io", evs[0].email);
    try testing.expectEqualStrings("complaint", evs[0].reason);
}

test "parseProvider Postmark: hard bounce + spam complaint; soft ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hb = try parseProvider(a, .postmark,
        \\{"RecordType":"Bounce","Type":"HardBounce","Email":"hb@x.io"}
    );
    try testing.expectEqual(@as(usize, 1), hb.len);
    try testing.expectEqualStrings("hard_bounce", hb[0].reason);

    const spam = try parseProvider(a, .postmark,
        \\{"RecordType":"SpamComplaint","Email":"sc@x.io"}
    );
    try testing.expectEqual(@as(usize, 1), spam.len);
    try testing.expectEqualStrings("complaint", spam[0].reason);

    const soft = try parseProvider(a, .postmark,
        \\{"RecordType":"Bounce","Type":"Transient","Email":"t@x.io"}
    );
    try testing.expectEqual(@as(usize, 0), soft.len);
}

test "parseProvider rejects malformed JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, parseProvider(arena.allocator(), .ses, "{ not json"));
}
