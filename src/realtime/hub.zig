const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const rules = @import("../rules.zig");
const policy = @import("../policy.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const request = @import("../request.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const migrations = @import("../migrations.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const Conn = connection.Conn;

pub const DeliverError = policy.PolicyError;

/// Combine clauses with `&&`, each parenthesized: `(c1) && (c2)`.
fn combineClauses(alloc: std.mem.Allocator, clauses: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (clauses, 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, " && ");
        try out.append(alloc, '(');
        try out.appendSlice(alloc, c);
        try out.append(alloc, ')');
    }
    return out.toOwnedSlice(alloc);
}

/// Decide whether `conn` should receive an event for record `record_id` in `col` at unix time `now`.
/// create/update: authorize via viewRule AND the optional subscription filter, in one guarded query.
/// delete: authorized against a SNAPSHOT of the deleted row (the live row is gone). F4 fix — the
/// writer embeds the deleted record's fields in the delete frame so an owner-scoped viewRule still
/// only notifies the authorized owner instead of every non-locked subscriber. `delete_snapshot` is
/// the deleted record object (from the broadcast frame's private snapshot); when null we fall back
/// to the coarse "deliver unless locked" behavior (e.g. no snapshot available).
pub fn shouldDeliver(
    alloc: std.mem.Allocator,
    io: std.Io,
    reader: *db.Db,
    col: schema.Collection,
    conn: *const Conn,
    now: i64,
    action: protocol.Action,
    record_id: []const u8,
    sub_filter: ?[]const u8,
    delete_snapshot: ?std.json.Value,
) DeliverError!bool {
    const rctx = conn.requestContext(now);
    // Whether the tenant scope applies to THIS subscriber on THIS collection (tenancy enabled +
    // tenant-owned + non-superuser). When it does, delivery must be scoped to the subscriber's
    // active account even if the viewRule alone would `allow` (e.g. `@public`) — otherwise a
    // tenant-owned collection leaks across accounts over WebSocket. The rule-clause decision below
    // uses the RAW rule (`rules.decide`), not the tenancy-forced `policy.decide`, so an `@public`
    // rule never gets compiled as a guard expression — the tenant predicate is composed inside
    // `policy.matchesRule`.
    const scope_applies = tenancy.scopeApplies(col, &rctx);

    if (action == .delete) {
        switch (rules.decide(col.viewRule, &rctx)) {
            .deny_locked => return false, // locked: superuser already short-circuited to .allow
            .allow => {
                // @public or superuser: anyone may learn of the delete — UNLESS the collection is
                // tenant-scoped for this subscriber, in which case authorize the deleted row's
                // snapshot against the tenant predicate (no rule clause). No snapshot -> deny.
                if (!scope_applies) return true;
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, io, col, record_id, "", snap, &rctx) catch false;
            },
            .check => {
                // Owner/expression-scoped viewRule: authorize the deleted row against its
                // snapshot (the live row is gone). The tenant predicate, when applicable, is
                // composed in by `matchesSnapshot`->`policy.matchesRule`. No snapshot -> deny.
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, io, col, record_id, col.viewRule.?, snap, &rctx) catch false;
            },
        }
    }

    var clauses: std.ArrayList([]const u8) = .empty;
    defer clauses.deinit(alloc);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return false,
        .allow => {},
        .check => try clauses.append(alloc, col.viewRule.?),
    }
    if (sub_filter) |f| if (f.len > 0) try clauses.append(alloc, f);
    // Unconstrained ONLY when there is no rule/filter clause AND no tenant scope. Otherwise run a
    // guarded query: `matchesRule` ANDs the tenant predicate in (and tolerates an empty rule, so a
    // tenant-only constraint is evaluated even with no viewRule/filter clause).
    if (clauses.items.len == 0 and !scope_applies) return true;

    const combined = if (clauses.items.len > 0) try combineClauses(alloc, clauses.items) else "";
    return policy.matchesRule(alloc, reader, col, record_id, combined, &rctx);
}

/// Evaluate `rule` against a single deleted-record `snapshot` (F4). Builds a throwaway in-memory
/// DB, recreates `col`'s table, inserts ONLY the snapshot row (id + its stored columns preserved
/// verbatim), and runs the standard guarded SELECT. Reuses the exact rule machinery without
/// touching the (now row-less) live DB. Relation-traversing rules resolve against empty target
/// tables in the temp DB and therefore won't match — a conservative (deny) failure for delete
/// events, which is the safe direction.
///
/// BACKEND-AGNOSTIC (#159, PR-6): the sandbox is `db.Db.openMemory()`, which is ALWAYS the SQLite
/// union arm (SQLite is compiled into every build; Postgres has no `:memory:` analog). So this
/// delete-snapshot authz works identically whether the LIVE backend is SQLite or Postgres — it is
/// a self-contained, SQLite-dialect rule evaluator that never touches the live DB. `matchesRule`
/// derives its dialect per-`Db` (`db.dbDialect`), so the temp DB compiles SQLite SQL while the
/// create/update path against the live `reader` compiles Postgres `$n`/`now()` SQL — each
/// self-consistent.
fn matchesSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    col: schema.Collection,
    record_id: []const u8,
    rule: []const u8,
    snapshot: std.json.Value,
    rctx: *const request.RequestContext,
) !bool {
    if (snapshot != .object) return false;
    var tmp = try db.Db.openMemory();
    defer tmp.close();
    try migrations.run(&tmp);
    // Recreate the collection table (fresh id; we never persist relation FKs, so an isolated
    // schema is enough to evaluate column/macro comparisons).
    var spec = col;
    spec.id = "";
    spec.indexes = &.{}; // unique indexes are irrelevant for a single-row authz probe
    const live_col = try collections.create(alloc, io, &tmp, spec);

    // Direct INSERT preserving the snapshot's real id + stored scalar columns, binding each value
    // by its JSON type. (We bypass records.create on purpose: it regenerates the id and re-runs
    // validation, neither of which we want for an authz snapshot of an already-validated row.)
    var cols_sql: std.ArrayList(u8) = .empty;
    var ph_sql: std.ArrayList(u8) = .empty;
    const Bind = struct { v: std.json.Value };
    var binds: std.ArrayList(Bind) = .empty;
    try cols_sql.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try ph_sql.appendSlice(alloc, "?1,'',''");
    var n: c_int = 2;
    var it = snapshot.object.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "created") or std.mem.eql(u8, name, "updated")) continue;
        if (schema.fieldByName(live_col, name) == null) continue; // skip non-column keys (e.g. expand)
        switch (e.value_ptr.*) {
            .string, .integer, .float, .bool, .number_string => {},
            else => continue, // null/object/array: leave column NULL
        }
        try cols_sql.append(alloc, ',');
        try cols_sql.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{name}));
        try ph_sql.append(alloc, ',');
        try ph_sql.appendSlice(alloc, try std.fmt.allocPrint(alloc, "?{d}", .{n}));
        try binds.append(alloc, .{ .v = e.value_ptr.* });
        n += 1;
    }
    const sql = try std.fmt.allocPrintSentinel(alloc, "INSERT INTO \"{s}\" ({s}) VALUES ({s});", .{ col.name, cols_sql.items, ph_sql.items }, 0);
    var st = try tmp.prepare(sql);
    defer st.finalize();
    const rid = (snapshot.object.get("id") orelse return false);
    if (rid != .string) return false;
    try st.bindText(1, rid.string);
    var bi: c_int = 2;
    for (binds.items) |b| {
        switch (b.v) {
            .string => |s| try st.bindText(bi, s),
            .number_string => |s| try st.bindText(bi, s),
            .integer => |x| try st.bindInt(bi, x),
            .float => |x| try st.bindDouble(bi, x),
            .bool => |x| try st.bindInt(bi, if (x) 1 else 0),
            else => try st.bindNull(bi),
        }
        bi += 1;
    }
    _ = try st.step();
    return policy.matchesRule(alloc, &tmp, live_col, record_id, rule, rctx) catch false;
}

pub const EventFrames = struct {
    collection_channel: []const u8,
    record_channel: []const u8,
    frame_collection: []const u8,
    frame_record: []const u8,
};

/// Private key carrying the deleted record's authorization SNAPSHOT inside the *published* delete
/// frame (F4). It is consumed by `onChannelMessage` for per-subscriber authz and STRIPPED before
/// the id-only frame is delivered to the client — a subscriber never sees it.
pub const delete_snapshot_key = "_deleteSnapshot";

/// Build the two channels + two serialized frames for a record event. create/update carry `record`
/// (full, hidden fields already stripped by the caller's records.get). delete carries `{id}` plus,
/// when a snapshot of the deleted row is available, a private `_deleteSnapshot` object used only for
/// per-subscriber authorization (stripped before delivery).
pub fn buildEventFrames(
    alloc: std.mem.Allocator,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    record: ?std.json.Value,
) !EventFrames {
    const coll_channel = try alloc.dupe(u8, collection);
    const rec_channel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ collection, record_id });

    const body: std.json.Value = if (action == .delete) blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(alloc, "id", .{ .string = record_id });
        // Attach the deletion snapshot (if any) so subscribers can re-authorize owner-scoped
        // deletes. Stripped in onChannelMessage before the frame reaches the client.
        if (record) |snap| try o.put(alloc, delete_snapshot_key, snap);
        break :blk .{ .object = o };
    } else record.?;

    return .{
        .collection_channel = coll_channel,
        .record_channel = rec_channel,
        .frame_collection = try protocol.serializeEvent(alloc, coll_channel, action, body),
        .frame_record = try protocol.serializeEvent(alloc, rec_channel, action, body),
    };
}

const TestDb = struct {
    d: db.Db,
    fn init() !TestDb {
        var d = try db.Db.openMemory();
        try migrations.run(&d);
        return .{ .d = d };
    }
    fn deinit(self: *TestDb) void {
        self.d.close();
    }
    fn mkColl(self: *TestDb, a: std.mem.Allocator, name: []const u8, view_rule: ?[]const u8) !schema.Collection {
        return collections.create(a, std.testing.io, &self.d, .{
            .id = "", .name = name,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .listRule = "", .viewRule = view_rule, .createRule = "", .updateRule = "", .deleteRule = "",
        });
    }
    fn mkRec(self: *TestDb, a: std.mem.Allocator, col: schema.Collection, owner: []const u8) ![]const u8 {
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = owner });
        const rec = try records.create(a, std.testing.io, &self.d, col, .{ .object = data });
        return rec.object.get("id").?.string;
    }
};

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

test "public viewRule (@public): create delivered to anyone, no filter" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", rules.public_sentinel);
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
}

test "empty viewRule (\"\") is now LOCKED: anon receives nothing, superuser does" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", "");
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, rid, null, null));
}

test "null viewRule: superuser-only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "locked", null);
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, rid, null, null));
}

test "macro viewRule: only the owner receives the record" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &other, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .update, rid, null, null));
}

test "subscription filter narrows within an authorized viewRule" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "items", rules.public_sentinel);
    const rid = try tdb.mkRec(a, col, "alice");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, "owner = \"alice\"", null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, "owner = \"bob\"", null));
}

test "delete is id-only: locked -> only superuser; @public -> anyone" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pub_col = try tdb.mkColl(a, "p", rules.public_sentinel);
    const locked = try tdb.mkColl(a, "l", null);
    var anon = Conn{};
    // @public: anyone learns of the delete (no snapshot needed).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, pub_col, &anon, 0, .delete, "GONE", null, null));
    // null/locked: only a superuser.
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, locked, &anon, 0, .delete, "GONE", null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, locked, &su, 0, .delete, "GONE", null, null));
}

test "F4: owner-scoped delete only notifies the owner (snapshot authz)" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    // The deleted row's snapshot: owned by u1. The live row is gone (delete already committed),
    // so authorization must come from this snapshot.
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const snapshot: std.json.Value = .{ .object = snap };

    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    var anon = Conn{};
    // Owner: receives the delete. Non-owner and anonymous: do NOT (no id leak).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &other, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .delete, "GONE", null, snapshot));
    // No snapshot at all -> conservative deny, even for the would-be owner.
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .delete, "GONE", null, null));
}

test "tenant scoping: a subscriber receives ONLY its account's frames; unresolved account gets nothing" {
    // CRITICAL regression guard (#156): the realtime delivery path must apply the tenant predicate.
    // Before the fix `Conn.requestContext` never set tenancy_enabled/account_id, so a tenant-owned
    // `@public` collection broadcast to every subscriber — a cross-tenant leak. This test FAILS
    // under that code and passes after the fix.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tenant-owned collection with a NATURAL @public viewRule (the whole point of auto-scoping).
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "", .name = "projects", .fields = &fields, .viewRule = rules.public_sentinel,
    });
    col.options.tenant_field = "account";
    try tdb.d.exec("INSERT INTO projects (id,created,updated,title,account) VALUES " ++
        "('rA','t','t','a','accA'),('rB','t','t','b','accB');");

    // A subscriber whose connection is scoped to accA (tenancy_enabled + resolved account).
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "uA" });
    var connA = Conn{ .tenancy_enabled = true, .account_id = "accA" };
    connA.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });

    // create/update of accA's row -> delivered; accB's row -> NOT delivered (cross-tenant denied).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .create, "rB", null, null));
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .update, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .update, "rB", null, null));

    // delete uses the pre-delete snapshot: accA's snapshot delivered, accB's not.
    var snapA: std.json.ObjectMap = .empty;
    try snapA.put(a, "id", .{ .string = "rA" });
    try snapA.put(a, "account", .{ .string = "accA" });
    var snapB: std.json.ObjectMap = .empty;
    try snapB.put(a, "id", .{ .string = "rB" });
    try snapB.put(a, "account", .{ .string = "accB" });
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .delete, "rA", null, .{ .object = snapA }));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .delete, "rB", null, .{ .object = snapB }));

    // A subscriber with tenancy enabled but NO resolved account receives NOTHING on a tenant-owned
    // collection (fail closed) — even though the viewRule is @public.
    var connNone = Conn{ .tenancy_enabled = true, .account_id = "" };
    connNone.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connNone, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connNone, 0, .create, "rB", null, null));

    // A superuser bypasses tenancy (receives both); tenancy OFF on the conn = byte-identical legacy
    // (@public delivers all), proving the gate is the per-connection tenancy flag.
    var su = try authedConn(a, "admin", true);
    su.tenancy_enabled = true;
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, "rB", null, null));
    var legacy = Conn{ .tenancy_enabled = false };
    legacy.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &legacy, 0, .create, "rB", null, null));
}

test "expired identity is treated as anonymous" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 100 });
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &c, 50, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &c, 200, .update, rid, null, null));
}

test "buildEventFrames: create carries the full record on both channels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "REC1" });
    try rec.put(a, "title", .{ .string = "hi" });
    const ef = try buildEventFrames(a, "posts", .create, "REC1", .{ .object = rec });
    try std.testing.expectEqualStrings("posts", ef.collection_channel);
    try std.testing.expectEqualStrings("posts/REC1", ef.record_channel);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"topic\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"topic\":\"posts/REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"title\":\"hi\"") != null);
}

test "buildEventFrames: delete is id-only (no body fields)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ef = try buildEventFrames(a, "posts", .delete, "REC1", null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"action\":\"delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"id\":\"REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\"") == null);
}

test "F4: delete frame carries the private authz snapshot (stripped before client delivery)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "REC1" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const ef = try buildEventFrames(a, "notes", .delete, "REC1", .{ .object = snap });
    // The PUBLISHED frame includes the snapshot under the private key so subscribers can authorize.
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, delete_snapshot_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"owner\":\"u1\"") != null);
    // (onChannelMessage strips delete_snapshot_key and re-serializes an id-only frame before
    // WS.write, so the client never sees the snapshot — covered by the hub authz tests above.)
}
