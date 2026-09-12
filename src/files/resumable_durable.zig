//! SQLite persistence beneath the bounded RAM session store. One owner holds a
//! boot-lifetime lock; all acknowledged transitions commit before RAM changes.
//! Payloads remain in RAM: persistence is not a streaming-memory optimization.
const std = @import("std");
const db = @import("../db.zig");
const c = @import("../c.zig").c;
const resumable = @import("resumable.zig");
const config = @import("config.zig");

pub const Durable = struct {
    pool: *db.Pool,
    io: std.Io,
    owner: std.Io.File,

    pub fn open(allocator: std.mem.Allocator, pool: *db.Pool, io: std.Io, store: *resumable.Store, now: i64) !Durable {
        var self = try acquire(allocator, pool, io);
        errdefer self.close();
        try self.restore(allocator, store, now);
        return self;
    }

    /// Acquire before migrations or startup cleanup. No session payload is loaded
    /// until restore, so provisioning does not overlap the recovered RAM budget.
    pub fn acquire(allocator: std.mem.Allocator, pool: *db.Pool, io: std.Io) !Durable {
        if (db.poolBackend(pool) != .sqlite) return error.DurableUploadsRequireSQLite;
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        const filename = c.sqlite3_db_filename(db.sqliteHandle(w), "main");
        if (filename == null or filename[0] == 0) return error.DurableUploadsRequireFileDatabase;
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, std.mem.span(filename), allocator);
        defer allocator.free(path);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.zigbase-uploads.lock", .{path});
        defer allocator.free(lock_path);
        const owner = try acquireOwner(io, lock_path);
        return .{ .pool = pool, .io = io, .owner = owner };
    }

    /// Borrows the already-held owner lease. The caller retains it on failure.
    pub fn restore(self: *Durable, allocator: std.mem.Allocator, store: *resumable.Store, now: i64) !void {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        const row_limit: usize = @intCast(c.sqlite3_limit(db.sqliteHandle(w), c.SQLITE_LIMIT_LENGTH, -1));
        if (!validLimits(store.limits) or row_limit <= config.durable_row_overhead or
            store.limits.max_upload_bytes > row_limit - config.durable_row_overhead)
            return error.DurableUploadRowLimit;
        try w.beginImmediate();
        defer rollback(w);
        var schema = try w.prepare("SELECT count(*),sum(type='table') FROM sqlite_schema WHERE name IN ('_upload_sessions','_upload_payloads','_upload_settings');");
        defer schema.finalize();
        if (!try schema.step()) return error.InvalidUploadStore;
        const existing = schema.columnInt(0) != 0;
        const complete_schema = schema.columnInt(0) == 3 and schema.columnInt(1) == 3;
        try w.exec(
            \\CREATE TABLE IF NOT EXISTS "_upload_sessions" (
            \\ id TEXT PRIMARY KEY, metadata TEXT NOT NULL, length INTEGER NOT NULL,
            \\ offset INTEGER NOT NULL, expires INTEGER NOT NULL, state TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS "_upload_payloads" (
            \\ rowid INTEGER PRIMARY KEY, session TEXT NOT NULL UNIQUE REFERENCES "_upload_sessions"(id) ON DELETE CASCADE,
            \\ payload BLOB NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS "_upload_settings" (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, limits TEXT NOT NULL);
        );
        const limits = try std.json.Stringify.valueAlloc(allocator, store.limits, .{});
        defer allocator.free(limits);
        var settings = try w.prepare("SELECT CASE WHEN typeof(version)='integer' THEN version END,CASE WHEN octet_length(limits)<=4096 THEN limits END,typeof(limits),CASE WHEN typeof(id)='integer' THEN id END FROM \"_upload_settings\" LIMIT 2;");
        defer settings.finalize();
        var changed = false;
        var previous = store.limits;
        var settings_found = false;
        if (try settings.step()) {
            settings_found = true;
            if (settings.columnType(0) != .Integer or !std.mem.eql(u8, settings.columnText(2), "text") or settings.columnType(3) != .Integer or settings.columnInt(3) != 1) return error.InvalidUploadStore;
            if (settings.columnInt(0) != 2) return error.UnsupportedUploadStoreVersion;
            const raw_limits = settings.columnText(1);
            if (raw_limits.len > 4096) return error.InvalidUploadStore;
            const parsed = std.json.parseFromSlice(resumable.Limits, allocator, raw_limits, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidUploadStore,
            };
            defer parsed.deinit();
            previous = parsed.value;
            if (!validLimits(previous)) return error.InvalidUploadStore;
            changed = !std.meta.eql(previous, store.limits);
            if (try settings.step()) return error.InvalidUploadStore;
        }
        // Keep the explicit unsupported-version error for older layouts, then
        // reject missing tables/markers before any recovery sweep or save.
        if (existing and (!complete_schema or !settings_found)) return error.InvalidUploadStore;
        // Bound recovery BEFORE UPDATE/DELETE or payload allocation. Prior
        // validated budgets bound work even when this binary lowers its limits.
        {
            var sessions = try w.prepare("SELECT count(*) FROM (SELECT 1 FROM \"_upload_sessions\" NOT INDEXED LIMIT ?);");
            defer sessions.finalize();
            try sessions.bindInt(1, @intCast(previous.max_sessions + 1));
            if (!try sessions.step() or sessions.columnInt(0) > previous.max_sessions) return error.InvalidUploadStore;
            // Validate both sides before any join can materialize corrupt keys.
            var session_keys = try w.prepare("SELECT 1 FROM \"_upload_sessions\" NOT INDEXED WHERE typeof(id)!='text' OR octet_length(id)!=32 LIMIT 1;");
            defer session_keys.finalize();
            if (try session_keys.step()) return error.InvalidUploadStore;
            var payloads = try w.prepare("SELECT count(*) FROM (SELECT 1 FROM \"_upload_payloads\" LIMIT ?);");
            defer payloads.finalize();
            try payloads.bindInt(1, @intCast(previous.max_sessions + 1));
            if (!try payloads.step() or payloads.columnInt(0) > previous.max_sessions) return error.InvalidUploadStore;
            // Bound join keys before SQLite materializes them for lookup.
            var payload_keys = try w.prepare("SELECT 1 FROM \"_upload_payloads\" WHERE typeof(session)!='text' OR octet_length(session)!=32 LIMIT 1;");
            defer payload_keys.finalize();
            if (try payload_keys.step()) return error.InvalidUploadStore;
            // Do not trust uniqueness constraints in a replaced/corrupt table.
            // Counts and key lengths above bound these grouping operations.
            var duplicate_sessions = try w.prepare("SELECT 1 FROM \"_upload_sessions\" NOT INDEXED GROUP BY id HAVING count(*)>1 LIMIT 1;");
            defer duplicate_sessions.finalize();
            if (try duplicate_sessions.step()) return error.InvalidUploadStore;
            var duplicate_payloads = try w.prepare("SELECT 1 FROM \"_upload_payloads\" NOT INDEXED GROUP BY session HAVING count(*)>1 LIMIT 1;");
            defer duplicate_payloads.finalize();
            if (try duplicate_payloads.step()) return error.InvalidUploadStore;
            var orphan = try w.prepare("SELECT 1 FROM \"_upload_payloads\" p LEFT JOIN \"_upload_sessions\" s ON s.id=p.session WHERE s.id IS NULL LIMIT 1;");
            defer orphan.finalize();
            if (try orphan.step()) return error.InvalidUploadStore;
            var preflight = try w.prepare(row_projection ++ " LIMIT ?;");
            defer preflight.finalize();
            try preflight.bindInt(1, @intCast(previous.max_sessions + 1));
            var count: usize = 0;
            var payload_total: usize = 0;
            var principals = std.StringHashMap(usize).init(allocator);
            defer {
                var keys = principals.keyIterator();
                while (keys.next()) |key| allocator.free(key.*);
                principals.deinit();
            }
            while (try preflight.step()) {
                count += 1;
                if (!settings_found or count > previous.max_sessions) return error.InvalidUploadStore;
                const row = try readRow(allocator, &preflight, previous);
                defer row.metadata.deinit();
                if (row.payload_length > previous.max_total_bytes - payload_total) return error.InvalidUploadStore;
                payload_total += row.payload_length;
                try countPrincipal(allocator, &principals, row.metadata.value.binding, previous.max_sessions_per_principal);
            }
        }
        // Never replay an interrupted mutation. Completed receipts were written
        // in the record transaction. These sweeps touch at most prior max_sessions.
        try w.exec("DELETE FROM \"_upload_payloads\" WHERE session IN (SELECT id FROM \"_upload_sessions\" WHERE state='committing');" ++
            "UPDATE \"_upload_sessions\" SET state='failed' WHERE state='committing';");
        var expired_payloads = try w.prepare("DELETE FROM \"_upload_payloads\" WHERE session IN (SELECT id FROM \"_upload_sessions\" WHERE expires<=?);");
        defer expired_payloads.finalize();
        try expired_payloads.bindInt(1, now);
        _ = try expired_payloads.step();
        var expired = try w.prepare("DELETE FROM \"_upload_sessions\" WHERE expires<=?;");
        defer expired.finalize();
        try expired.bindInt(1, now);
        _ = try expired.step();
        if (changed) {
            var live = try w.prepare("SELECT 1 FROM \"_upload_sessions\" LIMIT 1;");
            defer live.finalize();
            if (try live.step()) return error.DurableUploadBudgetsChanged;
        }
        var save = try w.prepare("INSERT INTO \"_upload_settings\" VALUES(1,2,?) ON CONFLICT(id) DO UPDATE SET limits=excluded.limits;");
        defer save.finalize();
        try save.bindText(1, limits);
        _ = try save.step();
        if (w.changesCount() != 1) return error.InvalidUploadStore;
        try load(allocator, w, store);
        try w.commit();
    }

    pub fn close(self: *Durable) void {
        self.owner.close(self.io);
    }

    pub fn begin(self: *Durable, allocator: std.mem.Allocator, s: resumable.Session) !void {
        const metadata = try std.json.Stringify.valueAlloc(allocator, Metadata{ .binding = s.binding, .target = s.target }, .{});
        defer allocator.free(metadata);
        if (metadata.len > config.durable_metadata_bytes) return error.InvalidUploadStore;
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        try w.beginImmediate();
        defer rollback(w);
        var st = try w.prepare("INSERT INTO \"_upload_sessions\"(id,metadata,length,offset,expires,state) VALUES(?,?,?,0,?,'receiving');");
        defer st.finalize();
        try st.bindText(1, &s.status.id);
        try st.bindText(2, metadata);
        try st.bindInt(3, @intCast(s.status.length));
        try st.bindInt(4, s.status.expiresAt);
        _ = try st.step();
        if (w.changesCount() != 1) return error.InvalidUploadStore;
        var payload = try w.prepare("INSERT INTO \"_upload_payloads\"(session,payload) VALUES(?,zeroblob(?));");
        defer payload.finalize();
        try payload.bindText(1, &s.status.id);
        try payload.bindInt(2, @intCast(s.status.length));
        _ = try payload.step();
        if (w.changesCount() != 1) return error.InvalidUploadStore;
        try w.commit();
    }

    pub fn append(self: *Durable, id: []const u8, offset: usize, chunk: []const u8) !void {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        try w.beginImmediate();
        defer rollback(w);
        var st = try w.prepare("SELECT p.rowid FROM \"_upload_sessions\" s JOIN \"_upload_payloads\" p ON p.session=s.id WHERE s.id=? AND s.state='receiving' AND s.offset=?;");
        defer st.finalize();
        try st.bindText(1, id);
        try st.bindInt(2, @intCast(offset));
        if (!try st.step()) return error.InvalidUploadStore;
        try writeBlob(w, st.columnInt(0), offset, chunk);
        var update = try w.prepare("UPDATE \"_upload_sessions\" SET offset=? WHERE id=?;");
        defer update.finalize();
        try update.bindInt(1, @intCast(offset + chunk.len));
        try update.bindText(2, id);
        _ = try update.step();
        if (w.changesCount() != 1) return error.InvalidUploadStore;
        try w.commit();
    }

    pub fn remove(self: *Durable, id: []const u8) !void {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        try w.beginImmediate();
        defer rollback(w);
        try deletePayload(w, id);
        var st = try w.prepare("DELETE FROM \"_upload_sessions\" WHERE id=?;");
        defer st.finalize();
        try st.bindText(1, id);
        _ = try st.step();
        if (w.changesCount() != 1) return error.InvalidUploadStore;
        try w.commit();
    }

    pub fn transition(self: *Durable, id: []const u8, state: resumable.State) !void {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        try w.beginImmediate();
        defer rollback(w);
        try setState(w, id, state);
        try w.commit();
    }

    pub fn failIfCommitting(self: *Durable, id: []const u8) !void {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        try w.beginImmediate();
        defer rollback(w);
        var st = try w.prepare("UPDATE \"_upload_sessions\" SET state='failed' WHERE id=? AND state='committing';");
        defer st.finalize();
        try st.bindText(1, id);
        _ = try st.step();
        var current = try w.prepare("SELECT state FROM \"_upload_sessions\" WHERE id=?;");
        defer current.finalize();
        try current.bindText(1, id);
        if (!try current.step() or !std.mem.eql(u8, current.columnText(0), "failed")) return error.UncertainUploadCommit;
        try deletePayload(w, id);
        try w.commit();
    }
};

const Metadata = struct { binding: resumable.Binding, target: resumable.Target };

// Bound every variable-size projection before Zig/SQLite materializes it. The
// payload itself is never selected, including for expired or invalid sessions.
const row_projection = std.fmt.comptimePrint("SELECT p.rowid,CASE WHEN octet_length(s.id)=32 THEN s.id END,CASE WHEN octet_length(metadata)<={d} THEN metadata END," ++
    "CASE WHEN typeof(length)='integer' THEN length END,CASE WHEN typeof(offset)='integer' THEN offset END,CASE WHEN typeof(expires)='integer' THEN expires END,CASE WHEN octet_length(state)<=10 THEN state END,coalesce(octet_length(payload),0)," ++
    "typeof(s.id)='text' AND typeof(metadata)='text' AND typeof(length)='integer' AND typeof(offset)='integer' AND typeof(expires)='integer' AND typeof(state)='text' AND " ++
    "CASE WHEN octet_length(state)<=10 THEN CASE WHEN state IN ('receiving','committing') THEN typeof(payload)='blob' ELSE p.session IS NULL END ELSE 0 END " ++
    "FROM \"_upload_sessions\" s LEFT JOIN \"_upload_payloads\" p ON p.session=s.id", .{config.durable_metadata_bytes});

const Row = struct {
    rowid: i64,
    id: [32]u8,
    metadata: std.json.Parsed(Metadata),
    length: usize,
    offset: usize,
    expires: i64,
    state: resumable.State,
    payload_length: usize,
};

test "recovery projection does not materialize oversized state values" {
    var w = try db.Db.openMemory();
    defer w.close();
    try w.exec("CREATE TABLE _upload_sessions(id TEXT PRIMARY KEY,metadata TEXT,length INTEGER,offset INTEGER,expires INTEGER,state TEXT);" ++
        "CREATE TABLE _upload_payloads(rowid INTEGER PRIMARY KEY,session TEXT,payload BLOB);" ++
        "INSERT INTO _upload_sessions VALUES(printf('%032d',1),'{}',4,0,0,'receiving');" ++
        "INSERT INTO _upload_payloads VALUES(1,printf('%032d',1),zeroblob(4));");
    for ([_][:0]const u8{ "CAST(zeroblob(1048576) AS TEXT)", "zeroblob(1048576)" }) |value| {
        const mutation = try std.fmt.allocPrintSentinel(std.testing.allocator, "UPDATE _upload_sessions SET state={s};", .{value}, 0);
        defer std.testing.allocator.free(mutation);
        try w.exec(mutation);
        // Persisted corruption exceeds the connection's materialization limit.
        // Reading only its byte length still works; loading it for IN does not.
        const previous = c.sqlite3_limit(db.sqliteHandle(&w), c.SQLITE_LIMIT_LENGTH, 32768);
        defer _ = c.sqlite3_limit(db.sqliteHandle(&w), c.SQLITE_LIMIT_LENGTH, previous);
        var st = try w.prepare(row_projection ++ ";");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectError(error.InvalidUploadStore, readRow(std.testing.allocator, &st, .{}));
    }
}

/// Owns one bounded metadata parse; caller deinitializes row.metadata. Used both
/// before recovery mutations and while loading surviving sessions afterward.
fn readRow(allocator: std.mem.Allocator, st: *db.Stmt, limits: resumable.Limits) !Row {
    if (st.columnInt(8) != 1) return error.InvalidUploadStore;
    const id = st.columnText(1);
    const raw = st.columnText(2);
    const length = st.columnInt(3);
    const offset = st.columnInt(4);
    const state = std.meta.stringToEnum(resumable.State, st.columnText(6)) orelse return error.InvalidUploadStore;
    const payload_length = st.columnInt(7);
    if (id.len != 32 or raw.len == 0 or raw.len > config.durable_metadata_bytes or length <= 0 or length > limits.max_upload_bytes or offset < 0 or offset > length) return error.InvalidUploadStore;
    for (id) |ch| if (!std.ascii.isHex(ch)) return error.InvalidUploadStore;
    if ((state == .committing or state == .completed) and offset != length) return error.InvalidUploadStore;
    if (payload_length != (if (state == .receiving or state == .committing) length else @as(i64, 0))) return error.InvalidUploadStore;
    const parsed = std.json.parseFromSlice(Metadata, allocator, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidUploadStore,
    };
    errdefer parsed.deinit();
    const parts = metadataParts(parsed.value);
    for (parts) |part| if (part.len == 0 or part.len > 255) return error.InvalidUploadStore;
    return .{ .rowid = st.columnInt(0), .id = id[0..32].*, .metadata = parsed, .length = @intCast(length), .offset = @intCast(offset), .expires = st.columnInt(5), .state = state, .payload_length = @intCast(payload_length) };
}

fn metadataParts(value: Metadata) [9][]const u8 {
    return .{ value.binding.collection, value.binding.principal, value.binding.collection_id, value.target.collection, value.target.collection_id, value.target.record, value.target.field, value.target.filename, value.target.mimetype };
}

fn countPrincipal(allocator: std.mem.Allocator, counts: *std.StringHashMap(usize), binding: resumable.Binding, limit: usize) !void {
    // Length prefixes preserve exact tuple identity even with embedded NULs.
    var key: [3 * (255 + 1)]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ binding.collection, binding.principal, binding.collection_id }) |part| {
        key[len] = @intCast(part.len);
        @memcpy(key[len + 1 ..][0..part.len], part);
        len += part.len + 1;
    }
    if (counts.getPtr(key[0..len])) |count| {
        if (count.* >= limit) return error.InvalidUploadStore;
        count.* += 1;
    } else {
        const owned = try allocator.dupe(u8, key[0..len]);
        errdefer allocator.free(owned);
        try counts.put(owned, 1);
    }
}

fn load(allocator: std.mem.Allocator, w: *db.Db, store: *resumable.Store) !void {
    var rows = try w.prepare(row_projection ++ ";");
    defer rows.finalize();
    var slot: usize = 0;
    while (try rows.step()) {
        if (slot == store.slots.len) return error.InvalidUploadStore;
        const row = try readRow(allocator, &rows, store.limits);
        defer row.metadata.deinit();
        if (row.state == .committing or row.payload_length > store.limits.max_total_bytes - store.allocated_bytes) return error.InvalidUploadStore;
        var owned: usize = 0;
        for (store.slots) |existing| if (existing) |s| {
            if (s.binding.eql(row.metadata.value.binding)) owned += 1;
        };
        if (owned >= store.limits.max_sessions_per_principal) return error.InvalidUploadStore;
        const parts = metadataParts(row.metadata.value);
        var size: usize = 0;
        for (parts) |part| {
            size += part.len;
        }
        const metadata = try allocator.alloc(u8, size);
        errdefer allocator.free(metadata);
        var strings: [parts.len][]const u8 = undefined;
        var pos: usize = 0;
        for (parts, 0..) |part, i| {
            @memcpy(metadata[pos..][0..part.len], part);
            strings[i] = metadata[pos..][0..part.len];
            pos += part.len;
        }
        const bytes = try allocator.alloc(u8, row.payload_length);
        errdefer allocator.free(bytes);
        // Only acknowledged bytes matter. Unreceived bytes are not exposed.
        if (row.state == .receiving and row.offset > 0) try readBlob(w, row.rowid, bytes[0..row.offset]);
        store.slots[slot] = .{
            .status = .{ .id = row.id, .length = row.length, .offset = row.offset, .expiresAt = row.expires, .state = row.state, .durability = "sqlite-restart" },
            .metadata = metadata,
            .bytes = bytes,
            .binding = .{ .collection = strings[0], .principal = strings[1], .collection_id = strings[2] },
            .target = .{ .collection = strings[3], .collection_id = strings[4], .record = strings[5], .field = strings[6], .filename = strings[7], .mimetype = strings[8] },
        };
        store.allocated_bytes += bytes.len;
        slot += 1;
    }
}

fn validLimits(r: resumable.Limits) bool {
    return r.durable and @import("config.zig").validResumableLimits(r);
}

/// Called by the record mutation on its existing writer transaction. Never
/// acquire Store's mutex here: Store operations acquire mutex before writer.
pub fn markCompleted(w: *db.Db, id: []const u8) !void {
    if (!w.inTransaction()) return error.UploadReceiptRequiresTransaction;
    var st = try w.prepare("SELECT 1 FROM \"_upload_sessions\" WHERE id=? AND state='committing' AND offset=length;");
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return error.InvalidUploadStore;
    try setState(w, id, .completed);
}

test "completion requires a transaction and a full committing receipt" {
    var w = try db.Db.openMemory();
    defer w.close();
    try w.exec("CREATE TABLE _upload_sessions(id TEXT PRIMARY KEY,state TEXT,offset INTEGER,length INTEGER);" ++
        "CREATE TABLE _upload_payloads(rowid INTEGER PRIMARY KEY,session TEXT NOT NULL UNIQUE REFERENCES _upload_sessions(id) ON DELETE CASCADE,payload BLOB NOT NULL);" ++
        "INSERT INTO _upload_sessions VALUES('receipt','committing',4,4);" ++
        "INSERT INTO _upload_payloads(session,payload) VALUES('receipt',zeroblob(4));");
    try std.testing.expectError(error.UploadReceiptRequiresTransaction, markCompleted(&w, "receipt"));
    for ([_]i64{ 0, 3, 5 }) |offset| {
        try w.beginImmediate();
        defer if (w.inTransaction()) w.rollback() catch unreachable;
        {
            var update = try w.prepare("UPDATE _upload_sessions SET offset=?;");
            defer update.finalize();
            try update.bindInt(1, offset);
            _ = try update.step();
        }
        try std.testing.expectError(error.InvalidUploadStore, markCompleted(&w, "receipt"));
        try w.rollback();
    }
    try w.beginImmediate();
    defer if (w.inTransaction()) w.rollback() catch unreachable;
    try markCompleted(&w, "receipt");
    try w.commit();
    var receipt = try w.prepare("SELECT state,offset,(SELECT count(*) FROM _upload_payloads) FROM _upload_sessions;");
    defer receipt.finalize();
    try std.testing.expect(try receipt.step());
    try std.testing.expectEqualStrings("completed", receipt.columnText(0));
    try std.testing.expectEqual(@as(i64, 4), receipt.columnInt(1));
    try std.testing.expectEqual(@as(i64, 0), receipt.columnInt(2));
}

fn setState(w: *db.Db, id: []const u8, state: resumable.State) !void {
    std.debug.assert(w.inTransaction());
    var st = try w.prepare("UPDATE \"_upload_sessions\" SET state=? WHERE id=?;");
    defer st.finalize();
    try st.bindText(1, @tagName(state));
    try st.bindText(2, id);
    _ = try st.step();
    if (w.changesCount() != 1) return error.InvalidUploadStore;
    if (state != .committing) try deletePayload(w, id);
}

fn deletePayload(w: *db.Db, id: []const u8) !void {
    var st = try w.prepare("DELETE FROM \"_upload_payloads\" WHERE session=?;");
    defer st.finalize();
    try st.bindText(1, id);
    _ = try st.step();
    if (w.changesCount() > 1) return error.InvalidUploadStore;
    if (w.changesCount() == 0) {
        // Failed/completed receipts may already have no payload. Distinguish
        // that valid case from a trigger silently ignoring the deletion.
        var remaining = try w.prepare("SELECT 1 FROM \"_upload_payloads\" WHERE session=? LIMIT 1;");
        defer remaining.finalize();
        try remaining.bindText(1, id);
        if (try remaining.step()) return error.InvalidUploadStore;
    }
}

fn rollback(w: *db.Db) void {
    if (w.inTransaction()) w.rollback() catch |err| {
        std.debug.panic("durable upload rollback failed: {s}; refusing to continue with a live transaction", .{@errorName(err)});
    };
}

fn writeBlob(w: *db.Db, row: i64, offset: usize, bytes: []const u8) !void {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(db.sqliteHandle(w), "main", "_upload_payloads", "payload", row, 1, &blob) != c.SQLITE_OK) return error.UploadBlobOpenFailed;
    // Explicit close reports the primary failure. Close still runs after write failure.
    const result = c.sqlite3_blob_write(blob, bytes.ptr, @intCast(bytes.len), @intCast(offset));
    const closed = c.sqlite3_blob_close(blob);
    if (result != c.SQLITE_OK) return error.UploadBlobWriteFailed;
    if (closed != c.SQLITE_OK) return error.UploadBlobCloseFailed;
}
fn readBlob(w: *db.Db, row: i64, bytes: []u8) !void {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(db.sqliteHandle(w), "main", "_upload_payloads", "payload", row, 0, &blob) != c.SQLITE_OK) return error.UploadBlobOpenFailed;
    const result = c.sqlite3_blob_read(blob, bytes.ptr, @intCast(bytes.len), 0);
    const closed = c.sqlite3_blob_close(blob);
    if (result != c.SQLITE_OK) return error.UploadBlobReadFailed;
    if (closed != c.SQLITE_OK) return error.UploadBlobCloseFailed;
}

fn acquireOwner(io: std.Io, path: []const u8) !std.Io.File {
    return openOwner(io, path) catch |err| switch (err) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .exclusive = true, .lock = .exclusive, .lock_nonblocking = true }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => openOwner(io, path),
            else => create_err,
        },
        else => err,
    };
}
fn openOwner(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true });
}
