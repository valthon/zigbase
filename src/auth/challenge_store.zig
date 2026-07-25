const std = @import("std");
const db = @import("../db.zig");
const id_gen = @import("../id.zig");
const clock = @import("../clock.zig");
const param_sink = @import("../sql/param_sink.zig");

/// Lower + renumber a curated `_authChallenges` statement for `conn`'s backend, then prepare it.
/// SQLite gets the verbatim `?N`/`datetime('now')` SQL (zero-cost); Postgres gets `$n` + `now()`.
/// The lowered SQL lives in a transient arena (`Db.prepare` copies it), so it need only outlive the call.
fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    // Arena over the page allocator: no fixed ceiling (lowerStmtZ makes several intermediate
    // allocations that the arena frees together on return), and on SQLite lowerStmtZ is a no-op
    // returning the input slice, so this costs one empty arena. `Db.prepare` copies the text.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lowered = param_sink.lowerStmtZ(arena.allocator(), db.dbDialect(conn), sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

/// Server-side TTL'd single-use challenge store backed by the `_authChallenges` table
/// (created by migration 0007). Challenges are minted by `put` and redeemed exactly once
/// by `take` (by opaque id) or `takeByIdentity` (by collection+method+identity key, newest
/// unexpired win). Both redeem paths are atomic under the writer lock: a conditional UPDATE
/// sets `consumed=1` only when the row is present, unexpired, and not already consumed;
/// `sqlite3_changes64` (via `db.Db.changesCount`) tells us whether the UPDATE raced or succeeded.
pub const ChallengeStore = struct {
    conn: *db.Db,

    /// Mint a new challenge. Generates a random 32-char opaque id, stores the payload with a
    /// TTL of `ttl_s` seconds from now, and returns the id (allocated from `alloc`).
    /// `io` supplies entropy for the id; `collection`, `method`, `identity` are the lookup key.
    pub fn put(
        self: ChallengeStore,
        alloc: std.mem.Allocator,
        io: anytype,
        collection: []const u8,
        method: []const u8,
        identity: []const u8,
        payload: []const u8,
        ttl_s: i64,
    ) ![]const u8 {
        var id_buf: [32]u8 = undefined;
        id_gen.generate(io, &id_buf);
        const cid = try alloc.dupe(u8, &id_buf);
        // `cid` is the single escaping allocation; free it if any step below fails so `put` is
        // self-freeing under a raw allocator (not only a request arena).
        errdefer alloc.free(cid);
        const now = try nowUnixDb(self.conn);
        var st = try prep(self.conn,
            \\INSERT INTO "_authChallenges"
            \\  ("id","collectionRef","method","identity","payload","expires","consumed","created")
            \\ VALUES (?1,?2,?3,?4,?5,?6,0,datetime('now'));
        );
        defer st.finalize();
        try st.bindText(1, cid);
        try st.bindText(2, collection);
        try st.bindText(3, method);
        try st.bindText(4, identity);
        try st.bindText(5, payload);
        try st.bindInt(6, now + ttl_s);
        _ = try st.step();
        return cid;
    }

    /// Atomically fetch-and-consume a challenge by its opaque `id` AND `method`.
    /// Returns the payload slice (allocated from `alloc`) when the challenge exists,
    /// matches both id and method, is unexpired, and has not yet been consumed; marks it
    /// consumed atomically. Returns null when the id is unknown, the method does not match,
    /// the challenge is already consumed, or it is expired.
    /// The method filter provides defense-in-depth: a "webauthn_reg" challenge cannot be
    /// consumed by a login take() that passes "webauthn", and vice versa.
    pub fn take(self: ChallengeStore, alloc: std.mem.Allocator, id: []const u8, method: []const u8) !?[]const u8 {
        // Conditional UPDATE: only succeeds (changes == 1) if the row is unconsumed, unexpired,
        // and matches the expected method. Read changesCount() BEFORE the statement finalizes /
        // any later statement runs, so the single-use gate never depends on finalize-ordering
        // (a future SELECT here would reset it).
        var changed: i64 = 0;
        {
            var upd = try prep(self.conn,
                \\UPDATE "_authChallenges" SET "consumed"=1
                \\ WHERE "id"=?1 AND "method"=?2 AND "consumed"=0 AND "expires" > ?3;
            );
            defer upd.finalize();
            try upd.bindText(1, id);
            try upd.bindText(2, method);
            try upd.bindInt(3, try nowUnixDb(self.conn));
            _ = try upd.step();
            changed = self.conn.changesCount();
        }
        if (changed != 1) return null;
        // The UPDATE succeeded — fetch the payload.
        var sel = try prep(self.conn,
            \\SELECT "payload" FROM "_authChallenges" WHERE "id"=?1;
        );
        defer sel.finalize();
        try sel.bindText(1, id);
        if (!try sel.step()) return null;
        return try alloc.dupe(u8, sel.columnText(0));
    }

    /// Atomically fetch-and-consume the NEWEST unexpired, unconsumed challenge for the
    /// given (collection, method, identity) triple. Useful for OTP flows where the client
    /// returns a code and an id is not needed.
    /// Returns the payload slice (allocated from `alloc`) on success; null when no matching
    /// unexpired unconsumed challenge exists.
    pub fn takeByIdentity(
        self: ChallengeStore,
        alloc: std.mem.Allocator,
        collection: []const u8,
        method: []const u8,
        identity: []const u8,
    ) !?[]const u8 {
        // SELECT the newest matching id first, then do the guarded UPDATE by that id.
        // Two concurrent takes for the same identity compete on the UPDATE; exactly one wins
        // (changesCount == 1), the other sees 0 changes and returns null.
        const cid = blk: {
            var sel = try prep(self.conn,
                \\SELECT "id" FROM "_authChallenges"
                \\ WHERE "collectionRef"=?1 AND "method"=?2 AND "identity"=?3
                \\   AND "consumed"=0 AND "expires" > ?4
                \\ ORDER BY "created" DESC LIMIT 1;
            );
            defer sel.finalize();
            try sel.bindText(1, collection);
            try sel.bindText(2, method);
            try sel.bindText(3, identity);
            try sel.bindInt(4, try nowUnixDb(self.conn));
            if (!try sel.step()) return null;
            break :blk try alloc.dupe(u8, sel.columnText(0));
        };
        // `cid` is intermediate scratch (only the payload escapes): free it on every exit so
        // takeByIdentity is self-freeing, not reliant on a caller arena.
        defer alloc.free(cid);
        // Guarded UPDATE by that id (same atomicity guarantee as take). Capture changesCount()
        // before finalize so the single-use gate never depends on statement-finalize ordering.
        var changed: i64 = 0;
        {
            var upd = try prep(self.conn,
                \\UPDATE "_authChallenges" SET "consumed"=1
                \\ WHERE "id"=?1 AND "consumed"=0 AND "expires" > ?2;
            );
            defer upd.finalize();
            try upd.bindText(1, cid);
            try upd.bindInt(2, try nowUnixDb(self.conn));
            _ = try upd.step();
            changed = self.conn.changesCount();
        }
        if (changed != 1) return null;
        // Fetch the payload for the consumed row.
        var sel2 = try prep(self.conn,
            \\SELECT "payload" FROM "_authChallenges" WHERE "id"=?1;
        );
        defer sel2.finalize();
        try sel2.bindText(1, cid);
        if (!try sel2.step()) return null;
        return try alloc.dupe(u8, sel2.columnText(0));
    }
};

/// GC: delete all consumed or expired challenge entries. Safe to call periodically (scheduler)
/// or at startup. Removes both consumed=1 rows (already redeemed, no longer useful) and
/// rows whose TTL has elapsed (expired, unredeemable regardless of consumed state).
pub fn gcAuthChallenges(w: *db.Db) db.DbError!void {
    var st = try prep(w,
        \\DELETE FROM "_authChallenges"
        \\ WHERE "expires" <= ?1 OR "consumed"=1;
    );
    defer st.finalize();
    try st.bindInt(1, try nowUnixDb(w));
    _ = try st.step();
}

/// Unix seconds for challenge TTL/expiry, via the clock seam (honors the dev-only
/// `ZIGBASE_FAKE_NOW` override so frozen-clock e2e tests expire challenges deterministically).
fn nowUnixDb(conn: *db.Db) db.DbError!i64 {
    return clock.sqlNowUnix(conn);
}

test "ChallengeStore: put/take single-use, take returns null on replay, expired returns null" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // put/take/takeByIdentity are contract-1 (only the returned buffer escapes), so this runs under
    // the raw leak-detecting allocator, freeing each returned id/payload.
    const a = std.testing.allocator;

    const store = ChallengeStore{ .conn = &d };

    // put a challenge with 1 hour TTL
    const cid = try store.put(a, std.testing.io, "users", "otp", "alice@example.com", "secret-payload", 3600);
    defer a.free(cid);
    try std.testing.expect(cid.len == 32);

    // take once -> returns payload
    const p1 = try store.take(a, cid, "otp");
    defer if (p1) |p| a.free(p);
    try std.testing.expect(p1 != null);
    try std.testing.expectEqualStrings("secret-payload", p1.?);

    // take again (replay) -> null (already consumed)
    const p2 = try store.take(a, cid, "otp");
    try std.testing.expect(p2 == null);

    // put a challenge with negative TTL (already expired at insert)
    const expired_id = try store.put(a, std.testing.io, "users", "otp", "bob@example.com", "should-not-get", -1);
    defer a.free(expired_id);
    const p3 = try store.take(a, expired_id, "otp");
    try std.testing.expect(p3 == null);

    // unknown id -> null
    const p4 = try store.take(a, "00000000000000000000000000000000", "otp");
    try std.testing.expect(p4 == null);
}

test "ChallengeStore: take with wrong method returns null (cross-method isolation)" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const a = std.testing.allocator;

    const store = ChallengeStore{ .conn = &d };

    // Put a registration challenge under "webauthn_reg"
    const cid = try store.put(a, std.testing.io, "users", "webauthn_reg", "user1", "reg-payload", 3600);
    defer a.free(cid);

    // Attempting to take it with the login method "webauthn" must return null
    const wrong = try store.take(a, cid, "webauthn");
    try std.testing.expect(wrong == null);

    // The challenge must still be unconsumed — taking with the correct method succeeds
    const correct = try store.take(a, cid, "webauthn_reg");
    defer if (correct) |p| a.free(p);
    try std.testing.expect(correct != null);
    try std.testing.expectEqualStrings("reg-payload", correct.?);

    // A further take with the correct method now returns null (already consumed)
    const replay = try store.take(a, cid, "webauthn_reg");
    try std.testing.expect(replay == null);
}

test "ChallengeStore: takeByIdentity returns and consumes the newest matching challenge" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const a = std.testing.allocator;

    const store = ChallengeStore{ .conn = &d };

    // Put two challenges for the same identity — oldest then newest.
    // Insert with explicit created timestamps to guarantee ordering (SQLite datetime('now')
    // has 1-second resolution; two inserts in the same second get the same created value).
    // The put ids are unused here; free them immediately.
    const oid = try store.put(a, std.testing.io, "users", "otp", "carol@example.com", "old-payload", 3600);
    a.free(oid);
    const nid = try store.put(a, std.testing.io, "users", "otp", "carol@example.com", "new-payload", 7200);
    a.free(nid);

    // takeByIdentity should return one of them (newest unconsumed)
    const p1 = try store.takeByIdentity(a, "users", "otp", "carol@example.com");
    defer if (p1) |p| a.free(p);
    try std.testing.expect(p1 != null);

    // second call should return the other one
    const p2 = try store.takeByIdentity(a, "users", "otp", "carol@example.com");
    defer if (p2) |p| a.free(p);
    try std.testing.expect(p2 != null);

    // p1 and p2 are the two distinct payloads (order may vary within same second)
    const got_both = (std.mem.eql(u8, p1.?, "old-payload") or std.mem.eql(u8, p1.?, "new-payload")) and
        (std.mem.eql(u8, p2.?, "old-payload") or std.mem.eql(u8, p2.?, "new-payload")) and
        !std.mem.eql(u8, p1.?, p2.?);
    try std.testing.expect(got_both);

    // third call: none left -> null
    const p3 = try store.takeByIdentity(a, "users", "otp", "carol@example.com");
    try std.testing.expect(p3 == null);

    // no match for different method
    const mid = try store.put(a, std.testing.io, "users", "magic", "dave@example.com", "magic-payload", 3600);
    a.free(mid);
    const p4 = try store.takeByIdentity(a, "users", "otp", "dave@example.com");
    try std.testing.expect(p4 == null);
}

test "gcAuthChallenges removes expired and consumed rows, leaves live ones" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const a = std.testing.allocator;

    const store = ChallengeStore{ .conn = &d };

    // Insert a live challenge (far future expiry). live_id is asserted after GC, so it must outlive.
    const live_id = try store.put(a, std.testing.io, "users", "otp", "eve@example.com", "live", 9999999);
    defer a.free(live_id);

    // Insert an expired challenge (TTL in the past); its id is unused.
    const expired_id = try store.put(a, std.testing.io, "users", "otp", "frank@example.com", "expired", -1);
    a.free(expired_id);

    // Insert a live challenge and then consume it
    const consumed_id = try store.put(a, std.testing.io, "users", "otp", "grace@example.com", "consumed", 3600);
    defer a.free(consumed_id);
    const consumed_payload = try store.take(a, consumed_id, "otp");
    defer if (consumed_payload) |p| a.free(p);

    // Verify 3 rows before GC
    {
        var st = try d.prepare("SELECT COUNT(*) FROM \"_authChallenges\";");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 3), st.columnInt(0));
    }

    try gcAuthChallenges(&d);

    // After GC: only the live unconsumed row remains
    {
        var st = try d.prepare("SELECT COUNT(*) FROM \"_authChallenges\";");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
    }
    {
        var st = try d.prepare("SELECT \"id\" FROM \"_authChallenges\";");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqualStrings(live_id, st.columnText(0));
    }
}
