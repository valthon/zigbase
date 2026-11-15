//! Transactional REST invalidation journal. Live fanout remains best effort.
const std = @import("std");
const db = @import("../db.zig");
const protocol = @import("protocol.zig");
const schema = @import("../schema.zig");
const Arena = @import("../request_arena.zig").RequestArena;
const options = @import("build_options");
pub const max_entries = options.replay_max_entries;
pub const max_bytes = options.replay_max_bytes;
pub const max_frame_bytes = options.replay_max_frame_bytes;
pub const retention_seconds = options.replay_retention_seconds;
const backfill = @import("backfill.zig");

fn prep(a: std.mem.Allocator, conn: *db.Db, sql: []const u8) !db.Stmt {
    const pg = db.dbDialect(conn).kind == .postgres;
    const prefix = if (pg) blk: {
        var ns = try conn.prepare("SELECT pg_catalog.quote_ident(current_schema()), current_schema();");
        defer ns.finalize();
        if (!try ns.step() or ns.isNull(0) or std.mem.startsWith(u8, ns.columnText(1), "pg_")) return error.InvalidReplaySchema;
        break :blk try std.fmt.allocPrint(a, "{s}.", .{ns.columnText(0)});
    } else try a.dupe(u8, "main.");
    defer a.free(prefix);
    // Rewrite only engine-owned placeholders. A quoted PostgreSQL schema may
    // legally contain '?' or quotes that the placeholder scanner does not parse.
    const numbered = try @import("../sql/param_sink.zig").renumber(a, db.dbDialect(conn), sql);
    defer if (pg) a.free(numbered);
    const qualified = try std.mem.replaceOwned(u8, a, numbered, "journal.", prefix);
    defer a.free(qualified);
    const z = try a.dupeZ(u8, qualified);
    defer a.free(z);
    return conn.prepare(z);
}
fn execute(a: std.mem.Allocator, conn: *db.Db, sql: []const u8) !void {
    var s = try prep(a, conn, sql);
    defer s.finalize();
    _ = try s.step();
}
pub fn initialize(a: std.mem.Allocator, io: std.Io, conn: *db.Db) !void {
    if (conn.inTransaction()) return error.NestedTransaction;
    try conn.beginImmediate();
    errdefer conn.rollback() catch |err| std.log.warn("replay initialization rollback: {s}", .{@errorName(err)});
    if (db.dbDialect(conn).kind == .postgres) try conn.exec("SELECT pg_advisory_xact_lock(20903, 419);");
    try execute(a, conn, "CREATE TABLE IF NOT EXISTS journal._replay_state (id INTEGER PRIMARY KEY, secret TEXT NOT NULL, sequence BIGINT NOT NULL, floor BIGINT NOT NULL);");
    try execute(a, conn, "CREATE TABLE IF NOT EXISTS journal._replay_events (sequence BIGINT PRIMARY KEY, collection TEXT NOT NULL, frame TEXT NOT NULL, bytes BIGINT NOT NULL, expires BIGINT NOT NULL);");
    if (db.dbDialect(conn).kind == .postgres) {
        var valid = try conn.prepare("SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() AND c.relname IN ('_replay_state','_replay_events') AND c.relkind='r' AND c.relpersistence='p';");
        defer valid.finalize();
        _ = try valid.step();
        if (valid.columnInt(0) != 2) return error.InvalidReplayLedger;
    } else {
        var valid = try conn.prepare("PRAGMA main.table_list;");
        defer valid.finalize();
        var count: usize = 0;
        while (try valid.step()) {
            if (!std.mem.eql(u8, valid.columnText(1), "_replay_state") and !std.mem.eql(u8, valid.columnText(1), "_replay_events")) continue;
            if (!std.mem.eql(u8, valid.columnText(2), "table")) return error.InvalidReplayLedger;
            count += 1;
        }
        if (count != 2) return error.InvalidReplayLedger;
    }
    var random_secret: [32]u8 = undefined;
    io.random(&random_secret);
    const secret = std.fmt.bytesToHex(random_secret, .lower);
    var insert = try prep(a, conn, "INSERT INTO journal._replay_state VALUES(1,?1,0,0) ON CONFLICT(id) DO NOTHING;");
    defer insert.finalize();
    try insert.bindText(1, &secret);
    _ = try insert.step();
    try conn.commit();
}

pub fn capture(a: std.mem.Allocator, io: std.Io, conn: *db.Db, col: schema.Collection, action: protocol.Action, id: []const u8, snapshot: ?std.json.Value) !void {
    const frame = try eventFrame(a, col, action, id, snapshot);
    defer a.free(frame);
    try append(a, conn, col.id, frame, @import("../clock.zig").nowUnix(io));
}

/// The retained frame for one invalidation: `{id}` (create/update) or `{id, <private delete
/// snapshot>}` (delete, which requires `snapshot`). Owned by the caller (`a`).
pub fn eventFrame(a: std.mem.Allocator, col: schema.Collection, action: protocol.Action, id: []const u8, snapshot: ?std.json.Value) ![]u8 {
    var record: std.json.ObjectMap = .empty;
    defer record.deinit(a);
    try record.put(a, "id", .{ .string = id });
    if (action == .delete) try record.put(a, @import("hub.zig").delete_snapshot_key, snapshot orelse return error.MissingDeleteSnapshot);
    return protocol.serializeEvent(a, col.name, action, .{ .object = record });
}

/// One entry of `appendMany`: the collection id it is retained under and its frame.
pub const Pending = struct { collection: []const u8, frame: []const u8 };

/// Caller owns transaction. The metadata row lock is held through its commit,
/// so another process cannot allocate a visible position ahead of this write.
pub fn append(a: std.mem.Allocator, conn: *db.Db, collection: []const u8, frame: []const u8, now: i64) !void {
    return appendMany(a, conn, &.{.{ .collection = collection, .frame = frame }}, now);
}

/// `append` for several entries, retained in order at consecutive positions. The sequence
/// allocation, expiry and budget passes run ONCE for the batch instead of once per entry (#489:
/// a delete's foreign-key cascade journals one entry per affected row). Every frame is checked
/// against `max_frame_bytes` before anything is written.
pub fn appendMany(a: std.mem.Allocator, conn: *db.Db, entries: []const Pending, now: i64) !void {
    if (!conn.inTransaction()) return error.TransactionRequired;
    if (entries.len == 0) return;
    for (entries) |e| if (e.frame.len > max_frame_bytes) return error.ReplayFrameTooLarge;
    if (now < 0 or now > @as(i64, std.math.maxInt(i64)) - retention_seconds) return error.InvalidTime;
    const n: i64 = @intCast(entries.len);
    {
        var bump = try prep(a, conn, "UPDATE journal._replay_state SET sequence=sequence+?1 WHERE id=1 AND sequence<=9223372036854775807-?1;");
        defer bump.finalize();
        try bump.bindInt(1, n);
        _ = try bump.step();
    }
    if (conn.changesCount() != 1) return error.ReplaySequenceExhausted;
    // `sequence` is now the LAST allocated position; entry i takes sequence-(n-1-i).
    var insert = try prep(a, conn, "INSERT INTO journal._replay_events SELECT sequence-?5,?1,?2,?3,?4 FROM journal._replay_state WHERE id=1;");
    defer insert.finalize();
    for (entries, 0..) |e, i| {
        try insert.bindText(1, e.collection);
        try insert.bindText(2, e.frame);
        try insert.bindInt(3, @intCast(e.frame.len));
        try insert.bindInt(4, now + retention_seconds);
        try insert.bindInt(5, n - 1 - @as(i64, @intCast(i)));
        _ = try insert.step();
        insert.reset();
    }
    // Bound work by the fixed journal ceiling, independent of application size.
    // Expiry follows the sequence prefix even if server clocks move backwards.
    var expired = try prep(a, conn, "UPDATE journal._replay_state SET floor=COALESCE((SELECT MAX(sequence) FROM journal._replay_events WHERE expires<=?1),floor) WHERE id=1;");
    defer expired.finalize();
    try expired.bindInt(1, now);
    _ = try expired.step();
    try execute(a, conn, "DELETE FROM journal._replay_events WHERE sequence<=(SELECT floor FROM journal._replay_state WHERE id=1);");
    // One bounded reverse window pass chooses the oldest prefix to evict.
    // A large frame cannot trigger thousands of repeated COUNT/SUM rescans.
    var budget = try prep(a, conn, "UPDATE journal._replay_state SET floor=COALESCE((SELECT MAX(sequence) FROM (SELECT sequence, ROW_NUMBER() OVER (ORDER BY sequence DESC) AS n, SUM(bytes) OVER (ORDER BY sequence DESC) AS b FROM journal._replay_events) AS budget WHERE n>?1 OR b>?2),floor) WHERE id=1;");
    defer budget.finalize();
    try budget.bindInt(1, max_entries);
    try budget.bindInt(2, max_bytes);
    _ = try budget.step();
    try execute(a, conn, "DELETE FROM journal._replay_events WHERE sequence<=(SELECT floor FROM journal._replay_state WHERE id=1);");
}

/// Caller owns transaction. Discard the whole journal and move the floor past every position
/// issued so far, so EVERY existing cursor (all collections) answers `409 resetRequired` while
/// a checkpoint taken after this commit stays usable. This is the journal's degraded form for a
/// write it cannot record entry by entry (#489: a cascade above the announcement cap, or a
/// cascaded row whose snapshot is unreadable or larger than `max_frame_bytes`).
pub fn requireReset(a: std.mem.Allocator, conn: *db.Db) !void {
    if (!conn.inTransaction()) return error.TransactionRequired;
    // The right-hand sides read the row's old values: both columns become old sequence + 1.
    try execute(a, conn, "UPDATE journal._replay_state SET sequence=sequence+1, floor=sequence+1 WHERE id=1 AND sequence<9223372036854775807;");
    if (conn.changesCount() != 1) return error.ReplaySequenceExhausted;
    try execute(a, conn, "DELETE FROM journal._replay_events WHERE sequence<=(SELECT floor FROM journal._replay_state WHERE id=1);");
}

/// Per-request ceiling on examined journal entries (`backfill.fill`). At or above the
/// retention ceiling a page always reaches the head it started from, so neither its
/// items, `hasNext` nor page count depend on entries the caller may not see (#501).
/// Builds with `-Dreplay-max-entries` above 4096 can end a page early (see docs/api.md).
pub const scan_budget: usize = @min(max_entries, 4096);
/// Rows per read transaction while scanning. Bounds a chunk's transient frame copies.
pub const scan_chunk: usize = 128;

/// A checkpoint resolved against the journal: the position to scan after, the head
/// the scan stops at, and the key that seals the next cursor.
pub const Resolved = struct { after: i64, head: i64, key: [32]u8 };

fn begin(conn: *db.Db) !void {
    if (conn.inTransaction()) return error.NestedTransaction;
    if (db.dbDialect(conn).kind == .postgres) try conn.exec("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;") else try conn.exec("BEGIN;");
}

/// Journal head and effective floor (discarded or expired prefix) in the open transaction.
fn bounds(a: std.mem.Allocator, conn: *db.Db, now: i64, key: ?*[32]u8) !struct { head: i64, floor: i64 } {
    var state = try prep(a, conn, "SELECT secret,sequence,floor,COALESCE((SELECT MAX(sequence) FROM journal._replay_events WHERE expires<=?1),0) FROM journal._replay_state WHERE id=1;");
    defer state.finalize();
    try state.bindInt(1, now);
    if (!try state.step()) return error.ReplayUnavailable;
    if (key) |out| {
        if (state.columnText(0).len != 64) return error.InvalidReplaySecret;
        _ = std.fmt.hexToBytes(out, state.columnText(0)) catch return error.InvalidReplaySecret;
    }
    return .{ .head = state.columnInt(1), .floor = @max(state.columnInt(2), state.columnInt(3)) };
}

/// Opens `cursor` (null: a fresh checkpoint at the head). Cursors mean "after this
/// sequence". Equality with the floor has missed no event; rejecting it would also
/// invalidate a fresh checkpoint on an idle journal.
pub fn resolve(a: std.mem.Allocator, conn: *db.Db, binding: []const u8, cursor: ?[]const u8, now: i64) !Resolved {
    try begin(conn);
    errdefer conn.rollback() catch |err| std.log.warn("replay read rollback: {s}", .{@errorName(err)});
    var key: [32]u8 = undefined;
    const b = try bounds(a, conn, now, &key);
    var after = b.head;
    if (cursor) |c| {
        after = try openCursor(key, binding, c);
        if (after < b.floor or after > b.head) return error.ResetRequired;
    }
    try conn.commit();
    return .{ .after = after, .head = b.head, .key = key };
}

/// One chunk of raw (unauthorized) entries of `collection` in `(after, upto]`, at most
/// `max`. `next` is the last returned sequence when more remain, else `upto`. A
/// consistent read transaction protects metadata/rows against concurrent prune; current
/// authorization is applied by the caller AFTER releasing this reader. A floor that
/// passed `after` since the previous chunk requires reset, like a stale cursor.
pub fn readPage(arena: Arena, conn: *db.Db, collection: []const u8, after: i64, upto: i64, max: usize, now: i64) !backfill.Page {
    if (max == 0 or max > scan_chunk) return error.BadLimit;
    try begin(conn);
    errdefer conn.rollback() catch |err| std.log.warn("replay read rollback: {s}", .{@errorName(err)});
    const a = arena.a;
    const b = try bounds(a, conn, now, null);
    if (after < b.floor or after > upto or upto > b.head) return error.ResetRequired;
    var rows = try prep(a, conn, if (db.dbDialect(conn).kind == .postgres)
        "SELECT sequence,CASE WHEN octet_length(frame)<=?4 THEN frame ELSE NULL END FROM journal._replay_events WHERE sequence>?1 AND sequence<=?5 AND collection=?2 ORDER BY sequence LIMIT ?3;"
    else
        "SELECT sequence,CASE WHEN length(CAST(frame AS BLOB))<=?4 THEN frame ELSE NULL END FROM journal._replay_events WHERE sequence>?1 AND sequence<=?5 AND collection=?2 ORDER BY sequence LIMIT ?3;");
    defer rows.finalize();
    try rows.bindInt(1, after);
    try rows.bindText(2, collection);
    try rows.bindInt(3, @intCast(max + 1));
    try rows.bindInt(4, max_frame_bytes);
    try rows.bindInt(5, upto);
    var items: std.ArrayList(backfill.Entry) = .empty;
    var more = false;
    while (try rows.step()) {
        if (items.items.len == max) {
            more = true;
            break;
        }
        if (rows.isNull(1)) return error.ReplayFrameTooLarge;
        const frame = rows.columnText(1);
        if (frame.len > max_frame_bytes) return error.ReplayFrameTooLarge;
        try items.append(a, .{ .sequence = @intCast(rows.columnInt(0)), .frame = try a.dupe(u8, frame) });
    }
    rows.reset();
    try conn.commit();
    const next: u64 = if (more) items.items[items.items.len - 1].sequence else @intCast(upto);
    return .{ .items = items.items, .topic = collection, .generation = 0, .next = next, .has_next = more };
}

const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

/// Seals `words` under `key` with a fresh random nonce, authenticating `binding` as
/// associated data: the hex token reveals neither the words nor whether two tokens
/// carry equal ones. Shared by the durable journal and the process-local store (#496).
pub fn seal(comptime n: usize, a: std.mem.Allocator, io: std.Io, key: [32]u8, binding: []const u8, words: [n]u64) ![]u8 {
    var token: [Cipher.nonce_length + 8 * n + Cipher.tag_length]u8 = undefined;
    const nonce = token[0..Cipher.nonce_length];
    io.random(nonce);
    var plaintext: [8 * n]u8 = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u64, plaintext[8 * i ..][0..8], word, .big);
    Cipher.encrypt(token[Cipher.nonce_length..][0 .. 8 * n], token[Cipher.nonce_length + 8 * n ..][0..Cipher.tag_length], &plaintext, binding, nonce.*, key);
    const encoded = std.fmt.bytesToHex(token, .lower);
    return a.dupe(u8, &encoded);
}

/// Opens a `seal` token. Any malformed, forged, re-bound or foreign-key token is
/// `ResetRequired`, indistinguishable from a stale cursor.
pub fn open(comptime n: usize, key: [32]u8, binding: []const u8, cursor: []const u8) ![n]u64 {
    var token: [Cipher.nonce_length + 8 * n + Cipher.tag_length]u8 = undefined;
    if (cursor.len != token.len * 2) return error.ResetRequired;
    _ = std.fmt.hexToBytes(&token, cursor) catch return error.ResetRequired;
    var plaintext: [8 * n]u8 = undefined;
    Cipher.decrypt(&plaintext, token[Cipher.nonce_length..][0 .. 8 * n], token[Cipher.nonce_length + 8 * n ..][0..Cipher.tag_length].*, binding, token[0..Cipher.nonce_length].*, key) catch return error.ResetRequired;
    var words: [n]u64 = undefined;
    for (&words, 0..) |*word, i| word.* = std.mem.readInt(u64, plaintext[8 * i ..][0..8], .big);
    return words;
}

/// The journal's cursor token: one sealed sequence, the same bytes as before #496
/// generalized the sealing, so existing checkpoints stay valid across the upgrade.
pub fn sealCursor(a: std.mem.Allocator, io: std.Io, key: [32]u8, binding: []const u8, sequence: i64) ![]u8 {
    return seal(1, a, io, key, binding, .{@bitCast(sequence)});
}

fn openCursor(key: [32]u8, binding: []const u8, cursor: []const u8) !i64 {
    return @bitCast((try open(1, key, binding, cursor))[0]);
}

/// Test helper: one unauthorized page through the same resolve/scan/seal path the
/// HTTP layer uses, with every entry delivered.
const TestPage = struct { items: []const backfill.Entry, position: []const u8, has_next: bool };
fn page(arena: Arena, conn: *db.Db, collection: []const u8, cursor: ?[]const u8, limit: usize, now: i64) !TestPage {
    const resolved = try resolve(arena.a, conn, collection, cursor, now);
    const Source = struct {
        conn: *db.Db,
        collection: []const u8,
        upto: i64,
        now: i64,
        pub fn fetch(self: @This(), chunk_arena: Arena, after: u64, max: usize) !backfill.Page {
            return readPage(chunk_arena, self.conn, self.collection, @intCast(after), self.upto, max, self.now);
        }
    };
    const All = struct {
        a: std.mem.Allocator,
        pub fn deliver(self: @This(), _: std.mem.Allocator, entry: backfill.Entry) !?backfill.Entry {
            return .{ .sequence = entry.sequence, .frame = try self.a.dupe(u8, entry.frame) };
        }
    };
    const filled = if (cursor == null)
        backfill.Filled(backfill.Entry){ .items = &.{}, .next = @intCast(resolved.head), .has_next = false }
    else
        try backfill.fill(backfill.Entry, arena, Source{ .conn = conn, .collection = collection, .upto = resolved.head, .now = now }, All{ .a = arena.a }, @intCast(resolved.after), limit, scan_budget, scan_chunk);
    return .{ .items = filled.items, .position = try sealCursor(arena.a, std.testing.io, resolved.key, collection, @intCast(filled.next)), .has_next = filled.has_next };
}

test "journal transaction rollback pagination expiry and hard budgets" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try exercise(&conn);
}

fn exercise(conn: *db.Db) !void {
    const a = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = Arena{ .a = scratch.allocator() };
    try initialize(a, std.testing.io, conn);
    const initial = try page(arena, conn, "one", null, 2, 100);
    try std.testing.expectError(error.TransactionRequired, append(a, conn, "one", "{}", 100));
    try conn.beginImmediate();
    try append(a, conn, "one", "rolled-back", 100);
    try conn.rollback();
    try std.testing.expectEqual(@as(usize, 0), (try page(arena, conn, "one", initial.position, 2, 100)).items.len);
    try conn.beginImmediate();
    try append(a, conn, "one", "first", 100);
    try append(a, conn, "other", "private", 100);
    try append(a, conn, "one", "second", 100);
    try conn.commit();
    // Reinitialization preserves both epoch and rows across owner lifetimes.
    try initialize(a, std.testing.io, conn);
    const first = try page(arena, conn, "one", initial.position, 1, 100);
    try std.testing.expect(first.has_next);
    try std.testing.expectEqualStrings("first", first.items[0].frame);
    const second = try page(arena, conn, "one", first.position, 1, 100);
    try std.testing.expect(!second.has_next);
    try std.testing.expectEqualStrings("second", second.items[0].frame);
    try std.testing.expectError(error.ResetRequired, page(arena, conn, "one", initial.position, 1, 100 + retention_seconds));
    // At the expiry floor, all expired events were already consumed. Both the
    // caught-up cursor and a newly issued head checkpoint must remain usable.
    const caught_up = try page(arena, conn, "one", second.position, 1, 100 + retention_seconds);
    try std.testing.expectEqual(@as(usize, 0), caught_up.items.len);
    const fresh = try page(arena, conn, "one", null, 1, 100 + retention_seconds);
    try std.testing.expectEqual(@as(usize, 0), (try page(arena, conn, "one", fresh.position, 1, 100 + retention_seconds)).items.len);
    const oversized = try a.alloc(u8, max_frame_bytes + 1);
    defer a.free(oversized);
    try conn.beginImmediate();
    try std.testing.expectError(error.ReplayFrameTooLarge, append(a, conn, "one", oversized, 100));
    try conn.rollback();
    const large = oversized[0..max_frame_bytes];
    @memset(large, 'x');
    for (0..max_bytes / max_frame_bytes + 1) |_| {
        try conn.beginImmediate();
        try append(a, conn, "one", large, 100);
        try conn.commit();
    }
    try std.testing.expectError(error.ResetRequired, page(arena, conn, "one", second.position, 1, 100));
    var size = try prep(a, conn, "SELECT COUNT(*),SUM(bytes) FROM journal._replay_events;");
    defer size.finalize();
    _ = try size.step();
    try std.testing.expect(size.columnInt(0) <= max_entries);
    try std.testing.expect(size.columnInt(1) <= max_bytes);

    // #489: a batch is retained in order at consecutive positions; one frame over the budget
    // rejects the whole batch before anything is written.
    const head = try page(arena, conn, "batch", null, 1, 100);
    try conn.beginImmediate();
    try std.testing.expectError(error.ReplayFrameTooLarge, appendMany(a, conn, &.{ .{ .collection = "batch", .frame = "b0" }, .{ .collection = "batch", .frame = oversized } }, 100));
    try conn.rollback();
    try conn.beginImmediate();
    try appendMany(a, conn, &.{ .{ .collection = "batch", .frame = "b1" }, .{ .collection = "other", .frame = "o1" }, .{ .collection = "batch", .frame = "b2" } }, 100);
    try conn.commit();
    const batch = try page(arena, conn, "batch", head.position, 4, 100);
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqualStrings("b1", batch.items[0].frame);
    try std.testing.expectEqualStrings("b2", batch.items[1].frame);
    const other_head = try page(arena, conn, "other", null, 1, 100);
    // requireReset: every existing cursor of every collection — including caught-up ones —
    // must reset, while a checkpoint taken afterwards keeps working.
    try conn.beginImmediate();
    try requireReset(a, conn);
    try conn.commit();
    try std.testing.expectError(error.ResetRequired, page(arena, conn, "batch", head.position, 4, 100));
    try std.testing.expectError(error.ResetRequired, page(arena, conn, "batch", batch.position, 4, 100));
    try std.testing.expectError(error.ResetRequired, page(arena, conn, "other", other_head.position, 4, 100));
    const after = try page(arena, conn, "batch", null, 1, 100);
    try conn.beginImmediate();
    try append(a, conn, "batch", "b3", 100);
    try conn.commit();
    const resumed = try page(arena, conn, "batch", after.position, 4, 100);
    try std.testing.expectEqual(@as(usize, 1), resumed.items.len);
    try std.testing.expectEqualStrings("b3", resumed.items[0].frame);
    var remaining = try prep(a, conn, "SELECT COUNT(*) FROM journal._replay_events;");
    defer remaining.finalize();
    _ = try remaining.step();
    try std.testing.expectEqual(@as(i64, 1), remaining.columnInt(0));
}

test "pg journal isolates schema and serializes visibility across connections" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var first = try db.Db.openPostgres(a, std.testing.io, url);
    defer first.close();
    var other = try db.Db.openPostgres(a, std.testing.io, url);
    defer other.close();
    const token = try @import("../crypto.zig").genToken(std.testing.io, a, 12);
    defer a.free(token);
    const name = try std.fmt.allocPrint(a, "replay?\"'{s}", .{token});
    defer a.free(name);
    const quoted = try @import("../ddl.zig").quoteIdent(a, name);
    defer a.free(quoted);
    const create = try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA {s};", .{quoted}, 0);
    defer a.free(create);
    const drop = try std.fmt.allocPrintSentinel(a, "DROP SCHEMA {s} CASCADE;", .{quoted}, 0);
    defer a.free(drop);
    const path = try std.fmt.allocPrintSentinel(a, "SET search_path TO {s};", .{quoted}, 0);
    defer a.free(path);
    try first.exec(create);
    defer first.exec(drop) catch |err| std.log.err("replay test cleanup: {s}", .{@errorName(err)});
    try first.exec(path);
    try other.exec(path);
    try exercise(&first);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = Arena{ .a = scratch.allocator() };
    const checkpoint = try page(arena, &other, "cross", null, 1, 100);
    try first.beginImmediate();
    try append(a, &first, "cross", "committed-first", 100);
    // Readers never see an uncommitted sequence. A second writer cannot skip it.
    try std.testing.expectEqual(@as(usize, 0), (try page(arena, &other, "cross", checkpoint.position, 1, 100)).items.len);
    try other.exec("SET lock_timeout='100ms';");
    try other.beginImmediate();
    try std.testing.expectError(error.StepFailed, append(a, &other, "cross", "must-not-commit", 100));
    try std.testing.expectEqualStrings("canceling statement due to lock timeout", other.errMsg());
    try other.rollback();
    try first.commit();
    try other.beginImmediate();
    try append(a, &other, "cross", "committed-second", 100);
    try other.commit();
    const replay = try page(arena, &other, "cross", checkpoint.position, 2, 100);
    try std.testing.expectEqual(@as(usize, 2), replay.items.len);
    try std.testing.expectEqualStrings("committed-first", replay.items[0].frame);
    try std.testing.expectEqualStrings("committed-second", replay.items[1].frame);
    try first.exec("ALTER TABLE _replay_events SET UNLOGGED;");
    try std.testing.expectError(error.InvalidReplayLedger, initialize(a, std.testing.io, &first));
    try first.exec("ALTER TABLE _replay_events SET LOGGED;");
    try first.exec("CREATE TEMP TABLE _replay_events(sequence INTEGER);");
    // Explicit current-schema qualification ignores temporary shadows.
    try initialize(a, std.testing.io, &first);
    try std.testing.expectEqual(@as(usize, 2), (try page(arena, &first, "cross", checkpoint.position, 2, 100)).items.len);
}

test "journal count budget evicts oldest entry and preserves newest prefix" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try initialize(a, std.testing.io, &conn);
    try conn.beginImmediate();
    var fill = try prep(a, &conn, "WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<?1) INSERT INTO journal._replay_events SELECT v,'one','x',1,999999 FROM n;");
    defer fill.finalize();
    try fill.bindInt(1, max_entries);
    _ = try fill.step();
    var state = try prep(a, &conn, "UPDATE journal._replay_state SET sequence=?1;");
    defer state.finalize();
    try state.bindInt(1, max_entries);
    _ = try state.step();
    try append(a, &conn, "one", "newest", 100);
    try conn.commit();
    var size = try prep(a, &conn, "SELECT COUNT(*),MIN(sequence),MAX(sequence) FROM journal._replay_events;");
    defer size.finalize();
    _ = try size.step();
    try std.testing.expectEqual(@as(i64, max_entries), size.columnInt(0));
    try std.testing.expectEqual(@as(i64, 2), size.columnInt(1));
    try std.testing.expectEqual(@as(i64, max_entries) + 1, size.columnInt(2));
}

test "journal pages fill with authorized entries, whatever hidden writes they skip (#501)" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try initialize(a, std.testing.io, &conn);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = Arena{ .a = scratch.allocator() };
    const Mine = struct {
        pub fn deliver(_: @This(), _: std.mem.Allocator, e: backfill.Entry) !?backfill.Entry {
            return if (std.mem.eql(u8, e.frame, "mine")) e else null;
        }
    };
    const Source = struct {
        conn: *db.Db,
        upto: i64,
        pub fn fetch(self: @This(), chunk_arena: Arena, after: u64, max: usize) !backfill.Page {
            return readPage(chunk_arena, self.conn, "one", @intCast(after), self.upto, max, 100);
        }
    };
    var outcomes: [2][8]struct { items: usize, has_next: bool } = undefined;
    var counts: [2]usize = .{ 0, 0 };
    for ([_]usize{ 1, 3 }, 0..) |hidden, case| {
        const checkpoint = try resolve(a, &conn, "one", null, 100);
        try conn.beginImmediate();
        for (0..2) |_| {
            for (0..hidden) |_| try append(a, &conn, "one", "hidden", 100);
            try append(a, &conn, "other", "mine", 100); // another collection never counts
            try append(a, &conn, "one", "mine", 100);
        }
        for (0..hidden) |_| try append(a, &conn, "one", "hidden", 100);
        try conn.commit();
        var cursor = try sealCursor(a, std.testing.io, checkpoint.key, "one", checkpoint.after);
        defer a.free(cursor);
        while (true) {
            const resolved = try resolve(a, &conn, "one", cursor, 100);
            // Chunks of one row: the scan crosses several read transactions.
            const filled = try backfill.fill(backfill.Entry, arena, Source{ .conn = &conn, .upto = resolved.head }, Mine{}, @intCast(resolved.after), 1, scan_budget, 1);
            outcomes[case][counts[case]] = .{ .items = filled.items.len, .has_next = filled.has_next };
            counts[case] += 1;
            const next = try sealCursor(a, std.testing.io, resolved.key, "one", @intCast(filled.next));
            a.free(cursor);
            cursor = next;
            if (!filled.has_next) break;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), counts[0]);
    try std.testing.expectEqual(counts[0], counts[1]);
    for (outcomes[0][0..counts[0]], outcomes[1][0..counts[1]], [_]bool{ true, false }) |one, three, has_next| {
        try std.testing.expectEqual(@as(usize, 1), one.items);
        try std.testing.expectEqual(has_next, one.has_next);
        try std.testing.expectEqual(one, three);
    }
}

test "a chunk whose floor passed its position requires reset" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try initialize(a, std.testing.io, &conn);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = Arena{ .a = scratch.allocator() };
    try conn.beginImmediate();
    try append(a, &conn, "one", "first", 100);
    try conn.commit();
    // Expired by the read's clock: the scan cannot continue from before the floor,
    // and cannot read past the head the request resolved.
    try std.testing.expectError(error.ResetRequired, readPage(arena, &conn, "one", 0, 1, 1, 100 + retention_seconds));
    try std.testing.expectError(error.ResetRequired, readPage(arena, &conn, "one", 0, 2, 1, 100));
    const ok = try readPage(arena, &conn, "one", 0, 1, 1, 100);
    try std.testing.expectEqual(@as(usize, 1), ok.items.len);
    try std.testing.expect(!ok.has_next);
    try std.testing.expectEqual(@as(u64, 1), ok.next);
}

test "opaque cursor authenticates scope and ciphertext without exposing positions" {
    const a = std.testing.allocator;
    const key = [_]u8{7} ** 32;
    const first = try sealCursor(a, std.testing.io, key, "collection:0", 42);
    defer a.free(first);
    const same = try sealCursor(a, std.testing.io, key, "collection:0", 42);
    defer a.free(same);
    try std.testing.expect(!std.mem.eql(u8, first, same));
    try std.testing.expectEqual(@as(i64, 42), try openCursor(key, "collection:0", first));
    try std.testing.expectError(error.ResetRequired, openCursor(key, "other:0", first));
    try std.testing.expectError(error.ResetRequired, openCursor(key, "collection:1", first));
    first[0] = if (first[0] == '0') '1' else '0';
    try std.testing.expectError(error.ResetRequired, openCursor(key, "collection:0", first));
}
