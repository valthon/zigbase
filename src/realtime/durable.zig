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
pub const Entry = struct { frame: []const u8 };
pub const Page = struct { items: []const Entry, position: []const u8, has_next: bool };

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
    var record: std.json.ObjectMap = .empty;
    defer record.deinit(a);
    try record.put(a, "id", .{ .string = id });
    if (action == .delete) try record.put(a, @import("hub.zig").delete_snapshot_key, snapshot orelse return error.MissingDeleteSnapshot);
    const frame = try protocol.serializeEvent(a, col.name, action, .{ .object = record });
    defer a.free(frame);
    try append(a, conn, col.id, frame, @import("../clock.zig").nowUnix(io));
}

/// Caller owns transaction. The metadata row lock is held through its commit,
/// so another process cannot allocate a visible position ahead of this write.
pub fn append(a: std.mem.Allocator, conn: *db.Db, collection: []const u8, frame: []const u8, now: i64) !void {
    if (!conn.inTransaction()) return error.TransactionRequired;
    if (frame.len > max_frame_bytes) return error.ReplayFrameTooLarge;
    if (now < 0 or now > @as(i64, std.math.maxInt(i64)) - retention_seconds) return error.InvalidTime;
    try execute(a, conn, "UPDATE journal._replay_state SET sequence=sequence+1 WHERE id=1 AND sequence<9223372036854775807;");
    if (conn.changesCount() != 1) return error.ReplaySequenceExhausted;
    var insert = try prep(a, conn, "INSERT INTO journal._replay_events SELECT sequence,?1,?2,?3,?4 FROM journal._replay_state WHERE id=1;");
    defer insert.finalize();
    try insert.bindText(1, collection);
    try insert.bindText(2, frame);
    try insert.bindInt(3, @intCast(frame.len));
    try insert.bindInt(4, now + retention_seconds);
    _ = try insert.step();
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

/// A consistent read transaction protects metadata/rows against concurrent prune.
/// Current authorization is applied by the HTTP layer AFTER releasing this reader.
pub fn readPage(arena: Arena, io: std.Io, conn: *db.Db, collection: []const u8, binding: []const u8, cursor: ?[]const u8, limit: usize, now: i64) !Page {
    if (limit == 0 or limit > 128) return error.BadLimit;
    if (conn.inTransaction()) return error.NestedTransaction;
    if (db.dbDialect(conn).kind == .postgres) try conn.exec("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;") else try conn.exec("BEGIN;");
    errdefer conn.rollback() catch |err| std.log.warn("replay read rollback: {s}", .{@errorName(err)});
    const a = arena.a;
    var state = try prep(a, conn, "SELECT secret,sequence,floor,COALESCE((SELECT MAX(sequence) FROM journal._replay_events WHERE expires<=?1),0) FROM journal._replay_state WHERE id=1;");
    defer state.finalize();
    try state.bindInt(1, now);
    if (!try state.step()) return error.ReplayUnavailable;
    var key: [32]u8 = undefined;
    if (state.columnText(0).len != 64) return error.InvalidReplaySecret;
    _ = std.fmt.hexToBytes(&key, state.columnText(0)) catch return error.InvalidReplaySecret;
    const head = state.columnInt(1);
    const floor = @max(state.columnInt(2), state.columnInt(3));
    state.reset();
    var after = head;
    if (cursor) |c| {
        after = try openCursor(key, binding, c);
        // Cursors mean "after this sequence". Equality has missed no event;
        // rejecting it would also invalidate a fresh checkpoint on an idle journal.
        if (after < floor or after > head) return error.ResetRequired;
    }
    var rows = try prep(a, conn, if (db.dbDialect(conn).kind == .postgres)
        "SELECT sequence,CASE WHEN octet_length(frame)<=?4 THEN frame ELSE NULL END FROM journal._replay_events WHERE sequence>?1 AND collection=?2 ORDER BY sequence LIMIT ?3;"
    else
        "SELECT sequence,CASE WHEN length(CAST(frame AS BLOB))<=?4 THEN frame ELSE NULL END FROM journal._replay_events WHERE sequence>?1 AND collection=?2 ORDER BY sequence LIMIT ?3;");
    defer rows.finalize();
    try rows.bindInt(1, after);
    try rows.bindText(2, collection);
    try rows.bindInt(3, @intCast(limit + 1));
    try rows.bindInt(4, max_frame_bytes);
    var items: std.ArrayList(Entry) = .empty;
    var next = head;
    var more = false;
    var last = after;
    while (try rows.step()) {
        if (items.items.len == limit) {
            next = last;
            more = true;
            break;
        }
        if (rows.isNull(1)) return error.ReplayFrameTooLarge;
        const frame = rows.columnText(1);
        if (frame.len > max_frame_bytes) return error.ReplayFrameTooLarge;
        try items.append(a, .{ .frame = try a.dupe(u8, frame) });
        last = rows.columnInt(0);
    }
    rows.reset();
    const position = try sealCursor(a, io, key, binding, next);
    try conn.commit();
    return .{ .items = items.items, .position = position, .has_next = more };
}

const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const cursor_bytes = Cipher.nonce_length + 8 + Cipher.tag_length;

fn sealCursor(a: std.mem.Allocator, io: std.Io, key: [32]u8, binding: []const u8, sequence: i64) ![]u8 {
    var token: [cursor_bytes]u8 = undefined;
    const nonce = token[0..Cipher.nonce_length];
    io.random(nonce);
    var plaintext: [8]u8 = undefined;
    std.mem.writeInt(i64, &plaintext, sequence, .big);
    Cipher.encrypt(token[Cipher.nonce_length..][0..8], token[Cipher.nonce_length + 8 ..][0..Cipher.tag_length], &plaintext, binding, nonce.*, key);
    const encoded = std.fmt.bytesToHex(token, .lower);
    return a.dupe(u8, &encoded);
}

fn openCursor(key: [32]u8, binding: []const u8, cursor: []const u8) !i64 {
    if (cursor.len != cursor_bytes * 2) return error.ResetRequired;
    var token: [cursor_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&token, cursor) catch return error.ResetRequired;
    var plaintext: [8]u8 = undefined;
    Cipher.decrypt(&plaintext, token[Cipher.nonce_length..][0..8], token[Cipher.nonce_length + 8 ..][0..Cipher.tag_length].*, binding, token[0..Cipher.nonce_length].*, key) catch return error.ResetRequired;
    return std.mem.readInt(i64, &plaintext, .big);
}

fn page(arena: Arena, conn: *db.Db, collection: []const u8, cursor: ?[]const u8, limit: usize, now: i64) !Page {
    return readPage(arena, std.testing.io, conn, collection, collection, cursor, limit, now);
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
