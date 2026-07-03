//! Live realtime tests for the Postgres arm (issue #159, PR-6 core + PR-6b cross-instance).
//!
//! Two things are proven END-TO-END against a real PostgreSQL:
//!
//!   1. **PR-6 realtime authz parity.** `hub.shouldDeliver` — the per-subscriber delivery authz the
//!      WebSocket path runs in `onChannelMessage` — produces the SAME allow/deny decisions on
//!      Postgres as on SQLite for create/update (guarded SELECT against the live row, dialect-correct
//!      `$n`/`now()`) AND for delete (the pre-delete SNAPSHOT path, which evaluates the rule in a
//!      throwaway in-memory SQLite sandbox — `db.Db.openMemory()` is always the SQLite arm, so the
//!      delete-snapshot authz is backend-agnostic without any `:memory:` Postgres analog).
//!
//!   2. **PR-6b cross-instance LISTEN/NOTIFY.** A change `NOTIFY`'d on connection A is received by a
//!      listener on connection B (a second app instance sharing one database), decoded, and would be
//!      delivered to B's subscribers with B's authz applied. The payload carries only `{o,c,a,i[,t]}`
//!      — for a delete, a random token keying the deleted row's AT-REST (ciphertext) snapshot in the
//!      `_rt_delete_snapshots` side table, which B reads back over its own DB connection. The
//!      no-plaintext-in-NOTIFY guarantee (encrypted fields never transit the wire) is under test.
//!
//! They run only under `-Dpostgres=true` and require a reachable PostgreSQL; a connectivity/auth
//! failure SKIPS. Schema isolation mirrors `crud_tests.zig` (throwaway `CREATE SCHEMA` + search_path).

const std = @import("std");
const dbm = @import("../../db.zig");
const records = @import("../../records.zig");
const schema = @import("../../schema.zig");
const rules = @import("../../rules.zig");
const dialect_mod = @import("../../sql/dialect.zig");
const hub = @import("../../realtime/hub.zig");
const protocol = @import("../../realtime/protocol.zig");
const connection = @import("../../realtime/connection.zig");
const pg_bridge = @import("../../realtime/pg_bridge.zig");
const pgtests = @import("tests.zig");

const Dialect = dialect_mod.Dialect;
const Conn = connection.Conn;

fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_rt_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

fn provisionPg(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) !void {
    const tc = Dialect.postgres.textCollate();
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, try std.fmt.allocPrint(a, "CREATE TABLE \"{s}\" (\"id\" TEXT{s} PRIMARY KEY, \"created\" TEXT{s}, \"updated\" TEXT{s}", .{ col.name, tc, tc, tc }));
    for (col.fields) |f| {
        const ty = Dialect.postgres.sqlType(f.storageClass());
        const collate = if (std.mem.eql(u8, ty, "TEXT")) tc else "";
        try sql.appendSlice(a, try std.fmt.allocPrint(a, ", \"{s}\" {s}{s}", .{ f.name, ty, collate }));
    }
    try sql.appendSlice(a, ");");
    try d.exec(try std.fmt.allocPrintSentinel(a, "{s}", .{sql.items}, 0));
}

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

fn strVal(s: []const u8) std.json.Value {
    return .{ .string = s };
}

// ---- PR-6: realtime delivery authz parity on Postgres -----------------------

test "pg realtime: owner-scoped create/update delivery — only the owner is authorized" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{
        .id = "c1",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col);

    var data: std.json.ObjectMap = .empty;
    try data.put(al, "owner", strVal("u1"));
    const rec = try records.create(al, io, &d, col, .{ .object = data });
    const rid = rec.object.get("id").?.string;

    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    var anon = Conn{};

    // create/update authorize against the LIVE row via the dialect-correct guarded SELECT on PG.
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .create, rid, null, null));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .create, rid, null, null));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &anon, 0, .update, rid, null, null));
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .update, rid, null, null));
}

test "pg realtime: @public delivers to anyone; locked only to superusers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const pub_col = schema.Collection{
        .id = "c2",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = rules.public_sentinel,
    };
    const locked_col = schema.Collection{
        .id = "c3",
        .name = "secrets",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = null,
    };
    try provisionPg(al, &d, pub_col);
    try provisionPg(al, &d, locked_col);

    var pd: std.json.ObjectMap = .empty;
    try pd.put(al, "owner", strVal("u1"));
    const prec = try records.create(al, io, &d, pub_col, .{ .object = pd });
    const prid = prec.object.get("id").?.string;

    var anon = Conn{};
    var su = try authedConn(al, "admin", true);
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, pub_col, &anon, 0, .create, prid, null, null));
    // locked: anon denied, superuser allowed (id-only delete path, no row needed).
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, locked_col, &anon, 0, .delete, "GONE", null, null));
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, locked_col, &su, 0, .delete, "GONE", null, null));
}

test "pg realtime: owner-scoped DELETE authz uses the snapshot (no :memory: PG analog needed)" {
    // The deleted row is gone from Postgres, so delivery is authorized against the pre-delete
    // snapshot — evaluated in an in-memory SQLite sandbox (always the SQLite union arm). This is
    // the one historically SQLite-coupled spot; it works UNCHANGED with a live PG backend.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{
        .id = "c4",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col); // table exists but the deleted row is NOT inserted

    var snap: std.json.ObjectMap = .empty;
    try snap.put(al, "id", strVal("GONE"));
    try snap.put(al, "owner", strVal("u1"));
    const snapshot: std.json.Value = .{ .object = snap };

    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .delete, "GONE", null, snapshot));
    // No snapshot -> conservative deny even for the would-be owner.
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, "GONE", null, null));
}

// ---- PR-6b: cross-instance LISTEN/NOTIFY (token + side-table snapshot) -------

const field_policy = @import("../../field_policy.zig");

/// Create the delete-snapshot side table in the CURRENT search_path (matches migration 0018's DDL).
/// Idempotent. Used so these tests don't depend on the system migrations having been applied.
fn ensureRtTable(d: *dbm.Db) !void {
    try d.exec("CREATE TABLE IF NOT EXISTS \"_rt_delete_snapshots\" (" ++
        "\"token\" TEXT PRIMARY KEY, \"snapshot\" TEXT NOT NULL, " ++
        "\"created\" TIMESTAMPTZ NOT NULL DEFAULT now());");
}

/// Create the custom-topic broadcast side table in the CURRENT search_path (matches migration
/// 0021's DDL). Idempotent. Used so these tests don't depend on the system migrations.
fn ensureBroadcastTable(d: *dbm.Db) !void {
    try d.exec("CREATE TABLE IF NOT EXISTS \"_rt_broadcasts\" (" ++
        "\"token\" TEXT PRIMARY KEY, \"topic\" TEXT NOT NULL, \"frame\" TEXT NOT NULL, " ++
        "\"created\" TIMESTAMPTZ NOT NULL DEFAULT now());");
}

test "pg cross-instance: a create NOTIFY (token-free) is received + decoded by a listener on conn B" {
    // Two app instances sharing one database: instance B LISTENs; instance A NOTIFYs a create with a
    // DIFFERENT origin id (a remote instance). B receives + decodes the minimal {o,c,a,i} payload that
    // drives its local re-fetch + per-subscriber authz. No row data on the wire.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var conn_b = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_b.close();
    var conn_a = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_a.close();

    try dbm.dbListen(&conn_b, pg_bridge.channel);

    const payload = try pg_bridge.encode(al, "instanceA", "posts", .create, "REC42", null);
    try dbm.dbNotify(&conn_a, al, pg_bridge.channel, payload);

    const note = (try dbm.dbWaitNotification(&conn_b, al)) orelse return error.@"no notification received";
    try std.testing.expectEqualStrings(pg_bridge.channel, note.channel);
    const ev = pg_bridge.decode(al, note.payload) orelse return error.@"decode failed";
    try std.testing.expectEqualStrings("instanceA", ev.origin);
    try std.testing.expectEqualStrings("posts", ev.collection);
    try std.testing.expectEqual(protocol.Action.create, ev.action);
    try std.testing.expectEqualStrings("REC42", ev.id);
    try std.testing.expect(ev.token == null);
    // Origin differs from THIS process's id → the listener would NOT skip it.
    try std.testing.expect(!std.mem.eql(u8, ev.origin, pg_bridge.originId(io)));
}

test "pg cross-instance: a DELETE token is stored on A, NOTIFY'd, read back + authorized on B" {
    // The headline cross-instance path with the security redesign: A stores the deleted row's at-rest
    // snapshot in the side table keyed by a random token, NOTIFYs only the token; B receives it, reads
    // the snapshot back from the SHARED side table, and authorizes the delete for its subscribers.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var conn_b = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_b.close();
    var conn_a = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_a.close();
    // Shared system table in the default (public) search_path so A's write is visible to B.
    try ensureRtTable(&conn_a);

    try dbm.dbListen(&conn_b, pg_bridge.channel);

    // A: store the at-rest delete snapshot (owner u9) → token; NOTIFY only the token.
    var snap: std.json.ObjectMap = .empty;
    try snap.put(al, "id", strVal("DEL1"));
    try snap.put(al, "owner", strVal("u9"));
    const token = pg_bridge.storeDeleteSnapshot(al, io, &conn_a, .{ .object = snap }) orelse return error.@"store failed";
    const payload = try pg_bridge.encode(al, "instanceA", "notes", .delete, "DEL1", token);
    // The payload carries ONLY the token — no owner/row data.
    try std.testing.expect(std.mem.indexOf(u8, payload, "u9") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, token) != null);
    try dbm.dbNotify(&conn_a, al, pg_bridge.channel, payload);

    // B: receive the token, read the snapshot back from the shared side table.
    const note = (try dbm.dbWaitNotification(&conn_b, al)) orelse return error.@"no notification received";
    const ev = pg_bridge.decode(al, note.payload) orelse return error.@"decode failed";
    try std.testing.expectEqual(protocol.Action.delete, ev.action);
    const back = pg_bridge.readDeleteSnapshot(al, &conn_b, ev.token.?) orelse return error.@"snapshot not found";

    // B authorizes the delete against the read-back snapshot — owner u9 allowed, others denied —
    // WITHOUT the row existing on PG (the in-memory SQLite sandbox evaluates the rule).
    const col = schema.Collection{
        .id = "c5",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    var owner = try authedConn(al, "u9", false);
    var other = try authedConn(al, "u8", false);
    try std.testing.expect(try hub.shouldDeliver(al, io, &conn_b, col, &owner, 0, .delete, ev.id, null, back));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &conn_b, col, &other, 0, .delete, ev.id, null, back));

    // A FORGED NOTIFY with a fabricated token finds no side-table row → no snapshot → no delivery.
    try std.testing.expect(pg_bridge.readDeleteSnapshot(al, &conn_b, "forged-token-does-not-exist") == null);
}

test "pg cross-instance: delete NOTIFY leaks no encrypted plaintext (token-only payload; ciphertext at-rest)" {
    // HIGH security guard (#177 review): the cross-instance delete path must NEVER put a deleted row's
    // decrypted plaintext on the NOTIFY wire (visible to any LISTENer) NOR store it as plaintext. The
    // snapshot is captured AT-REST (ciphertext) via records.getAtRest, stored in the side table, and
    // only a random token rides the wire.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);
    try ensureRtTable(&d); // side table in the temp schema so store/read resolve there

    // Stamp a field cipher on the connection (as framework.zig does in production).
    var cipher = field_policy.Cipher.fromEnv(io, "rt-crossinstance-key");
    dbm.dbSetFieldCipher(&d, @ptrCast(&cipher));

    const secret = "TOP-SECRET-PII-9f3a";
    const col = schema.Collection{
        .id = "c6",
        .name = "vault",
        .fields = &[_]schema.Field{
            .{ .id = "f1", .name = "owner", .options = .{ .text = .{} } },
            .{ .id = "f2", .name = "ssn", .encrypted = true, .options = .{ .text = .{} } },
        },
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col);

    // Create a row; the encrypted field is sealed at rest (TEXT envelope), never plaintext.
    var data: std.json.ObjectMap = .empty;
    try data.put(al, "owner", strVal("u1"));
    try data.put(al, "ssn", strVal(secret));
    const rec = try records.create(al, io, &d, col, .{ .object = data });
    const rid = rec.object.get("id").?.string;

    // Capture the AT-REST snapshot (encrypted field stays ciphertext) + store it → token.
    const snap = (try records.getAtRest(al, &d, col, rid)).?;
    // The captured snapshot's encrypted field is the ciphertext envelope, NOT the plaintext.
    const ssn_at_rest = snap.object.get("ssn").?.string;
    try std.testing.expect(std.mem.indexOf(u8, ssn_at_rest, secret) == null);
    try std.testing.expect(std.mem.startsWith(u8, ssn_at_rest, "v1:"));

    const token = pg_bridge.storeDeleteSnapshot(al, io, &d, snap) orelse return error.@"store failed";
    const payload = try pg_bridge.encode(al, "instanceA", "vault", .delete, rid, token);

    // THE GUARANTEE: the NOTIFY payload contains the token and NO row data — no plaintext secret AND
    // no ciphertext envelope (no field data of any kind rides the wire).
    try std.testing.expect(std.mem.indexOf(u8, payload, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "v1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "ssn") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, token) != null);

    // Defense in depth: the side table holds the ciphertext, never the plaintext.
    const back = pg_bridge.readDeleteSnapshot(al, &d, token) orelse return error.@"snapshot not found";
    const back_json = try std.json.Stringify.valueAlloc(al, back, .{});
    try std.testing.expect(std.mem.indexOf(u8, back_json, secret) == null);

    // The remote subscriber still gets correct delete authz from the read-back snapshot.
    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, rid, null, back));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .delete, rid, null, back));
}

test "pg delete authz: local snapshot == remote snapshot (at-rest ciphertext basis; identical authz)" {
    // Consistency guard (#177 copilot review): the LOCAL delete path now authorizes against the
    // same AT-REST (ciphertext) snapshot the cross-instance REMOTE path uses (and that the live
    // create/update path compares), so all paths agree. This pins that (a) the snapshot the local
    // path delivers for authz is the at-rest representation — an `.encrypted` field is CIPHERTEXT,
    // never decrypted plaintext, in the authz sandbox — and (b) local and remote authorize an
    // owner-scoped delete identically (owner allowed, others denied).
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);
    try ensureRtTable(&d);

    var cipher = field_policy.Cipher.fromEnv(io, "rt-consistency-key");
    dbm.dbSetFieldCipher(&d, @ptrCast(&cipher));

    // A normal owner-scoped rule (decisive authz) on a collection that ALSO has an encrypted field.
    const col = schema.Collection{
        .id = "c7",
        .name = "tokens",
        .fields = &[_]schema.Field{
            .{ .id = "f1", .name = "owner", .options = .{ .text = .{} } },
            .{ .id = "f2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
        },
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col);

    var data: std.json.ObjectMap = .empty;
    try data.put(al, "owner", strVal("u1"));
    try data.put(al, "secret", strVal("classified"));
    const rec = try records.create(al, io, &d, col, .{ .object = data });
    const rid = rec.object.get("id").?.string;

    // The local delete path's authz snapshot is the AT-REST representation (what prepareDelete
    // returns for a collection with an encrypted field): owner plaintext, secret CIPHERTEXT.
    const local_snapshot = (try records.getAtRest(al, &d, col, rid)).?;
    try std.testing.expectEqualStrings("u1", local_snapshot.object.get("owner").?.string);
    const secret_in_snapshot = local_snapshot.object.get("secret").?.string;
    try std.testing.expect(std.mem.indexOf(u8, secret_in_snapshot, "classified") == null);
    try std.testing.expect(std.mem.startsWith(u8, secret_in_snapshot, "v1:"));

    // The remote path stores that same at-rest snapshot and reads it back.
    const token = pg_bridge.storeDeleteSnapshot(al, io, &d, local_snapshot) orelse return error.@"store failed";
    const remote_snapshot = pg_bridge.readDeleteSnapshot(al, &d, token) orelse return error.@"snapshot not found";

    // local == remote: identical authz on both snapshots, for owner (allow) and non-owner (deny).
    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    const local_owner = try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, rid, null, local_snapshot);
    const remote_owner = try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, rid, null, remote_snapshot);
    const local_other = try hub.shouldDeliver(al, io, &d, col, &other, 0, .delete, rid, null, local_snapshot);
    const remote_other = try hub.shouldDeliver(al, io, &d, col, &other, 0, .delete, rid, null, remote_snapshot);
    try std.testing.expectEqual(local_owner, remote_owner);
    try std.testing.expectEqual(local_other, remote_other);
    try std.testing.expect(local_owner); // owner authorized on both
    try std.testing.expect(!local_other); // non-owner denied on both

    // And the live create/update path (ciphertext column) agrees with the delete basis: owner
    // allowed, non-owner denied — the same decisions, proving all three paths use one basis.
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .create, rid, null, null));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .create, rid, null, null));
}

// ---- PR-4a: cross-instance custom topics (signal + message side-table) -------

test "pg cross-instance: signal NOTIFY round-trips conn A -> conn B and decodes as .signal" {
    // A payload-less custom-topic signal: instance A NOTIFYs {o,s} with a DIFFERENT origin, and
    // instance B's listener receives + decodes it as a .signal carrying only origin + topic.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var conn_b = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_b.close();
    var conn_a = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_a.close();

    try dbm.dbListen(&conn_b, pg_bridge.channel);

    const payload = try pg_bridge.encodeSignal(al, "instanceA", "orders");
    // Payload-less: only origin + topic ride the wire — no frame, no data.
    try std.testing.expect(std.mem.indexOf(u8, payload, "data") == null);
    try dbm.dbNotify(&conn_a, al, pg_bridge.channel, payload);

    const note = (try dbm.dbWaitNotification(&conn_b, al)) orelse return error.@"no notification received";
    try std.testing.expectEqualStrings(pg_bridge.channel, note.channel);
    const p = pg_bridge.decodeAny(al, note.payload) orelse return error.@"decode failed";
    try std.testing.expectEqualStrings("orders", p.signal.topic);
    try std.testing.expectEqualStrings("instanceA", p.signal.origin);
    // Origin differs from THIS process's id → the listener would NOT skip it.
    try std.testing.expect(!std.mem.eql(u8, p.signal.origin, pg_bridge.originId(io)));
}

test "pg cross-instance: _rt_broadcasts store/read round-trip; forged token drops; TTL GC reaps" {
    // The message-broadcast path: A stores the ENVELOPED frame in _rt_broadcasts keyed by a random
    // CSPRNG token, NOTIFYs only the token; B reads the frame back by token. A forged token finds no
    // row (fail closed). A stale row (older than the TTL) is GC'd on the next store.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);
    try ensureBroadcastTable(&d);

    const topic = "orders";
    const frame = "{\"type\":\"message\",\"topic\":\"orders\",\"data\":{\"n\":1}}";

    // store → read round-trip: topic + frame come back byte-identical.
    const token = pg_bridge.storeBroadcast(al, io, &d, topic, frame) orelse return error.@"store failed";
    const back = pg_bridge.readBroadcast(al, &d, token) orelse return error.@"frame not found";
    try std.testing.expectEqualStrings(topic, back.topic);
    try std.testing.expectEqualStrings(frame, back.frame);
    // The token is high-entropy (32 random base36 chars from the CSPRNG seam), so it is unguessable.
    try std.testing.expectEqual(@as(usize, 32), token.len);

    // A FORGED / guessed token resolves to no row → drop (fail closed).
    try std.testing.expect(pg_bridge.readBroadcast(al, &d, "forged-token-does-not-exist") == null);

    // TTL GC: seed a stale row (created 120s ago > 60s TTL), then the next store reaps it.
    try d.exec("INSERT INTO \"_rt_broadcasts\" (\"token\",\"topic\",\"frame\",\"created\") " ++
        "VALUES ('stale-token','orders','{}', now() - interval '120 seconds');");
    try std.testing.expect(pg_bridge.readBroadcast(al, &d, "stale-token") != null); // present before GC
    _ = pg_bridge.storeBroadcast(al, io, &d, topic, frame) orelse return error.@"store failed";
    try std.testing.expect(pg_bridge.readBroadcast(al, &d, "stale-token") == null); // reaped by GC
}
