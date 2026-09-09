//! Opt-in SQLite receipts for trusted, database-only custom operations.
//! Merely exporting this generic adds no runtime state, schema, or middleware.
const std = @import("std");
const db = @import("db.zig");

pub const Limits = struct {
    /// All processes using this namespace must agree on limits. Different namespaces
    /// have independent capacity; expiry is stored per receipt, never recomputed.
    namespace: []const u8,
    max_entries: u32 = 1024,
    retention_seconds: u32 = 86400,
    max_payload_bytes: u32 = 65536,
    max_result_bytes: u32 = 4096,
    cleanup_batch: u16 = 64,
};

pub const Principal = struct { collection: []const u8, record: []const u8 };
pub const Input = struct {
    principal: Principal,
    operation: []const u8,
    key: []const u8,
    /// Exact bytes, including target/resource identity and all mutation inputs.
    payload: []const u8,
    /// Trusted server Unix time captured for this attempt, never client input.
    /// Retention starts here, not at commit; writer wait/mutation consumes it.
    now: i64,
};

/// Owned-result contract: deinit with the same allocator passed to execute.
pub const Result = struct {
    storage: []u8,
    len: usize,
    replayed: bool,
    pub fn body(self: Result) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }
};

/// Callback code is trusted. Both callbacks must use ONLY the supplied connection
/// for DB access, never commit/rollback it, and never perform external side effects.
/// Authorization must be read-only and is mandatory on EVERY attempt, including replay. `mutate` writes
/// its result into the bounded buffer and returns its used length. Errors roll back.
pub const Callbacks = struct {
    context: *anyopaque,
    /// Read-only, current authorization on the supplied writer, also on replay.
    authorize: *const fn (*db.Db, *anyopaque) anyerror!void,
    mutate: *const fn (*db.Db, *anyopaque, []u8) anyerror!usize,
};

pub fn Idempotency(comptime limits: Limits) type {
    if (limits.namespace.len == 0 or limits.namespace.len > 128 or
        limits.max_entries == 0 or limits.max_entries > 1000000 or
        limits.retention_seconds == 0 or limits.retention_seconds > 31536000 or
        limits.max_payload_bytes == 0 or limits.max_payload_bytes > 1048576 or
        limits.max_result_bytes == 0 or limits.max_result_bytes > 1048576 or
        limits.cleanup_batch == 0 or limits.cleanup_batch > 1024)
        @compileError("invalid idempotency limits: namespace 1..128, entries 1..1000000, retention 1..31536000, payload/result 1..1048576, cleanup 1..1024");
    return struct {
        pub fn execute(allocator: std.mem.Allocator, conn: *db.Db, input: Input, callbacks: Callbacks) !Result {
            if (db.dbDialect(conn).kind != .sqlite) return error.UnsupportedBackend;
            if (conn.inTransaction()) return error.NestedTransaction;
            for ([_][]const u8{ input.principal.collection, input.principal.record, input.operation, input.key }) |part| {
                if (part.len == 0 or part.len > 128) return error.InvalidScope;
            }
            if (input.payload.len > limits.max_payload_bytes) return error.PayloadTooLarge;
            if (input.now < 0 or input.now > @as(i64, std.math.maxInt(i64)) - limits.retention_seconds) return error.InvalidTime;
            var scope: [64]u8 = undefined;
            var payload_hash: [64]u8 = undefined;
            hashParts(&scope, &.{ input.principal.collection, input.principal.record, input.operation, input.key });
            hashParts(&payload_hash, &.{input.payload});

            // SQLite's database writer lock coordinates independent processes, not
            // just the caller's pool mutex. Busy failures are retryable; no work ran.
            try conn.beginImmediate();
            errdefer if (conn.inTransaction()) conn.rollback() catch |err| std.log.warn("idempotency rollback failed: {s}; connection state uncertain; no automatic reset; caller must stop reuse and recover the connection/pool", .{@errorName(err)});
            try callbacks.authorize(conn, callbacks.context);
            try conn.exec("CREATE TABLE IF NOT EXISTS _idempotency_receipts (namespace TEXT NOT NULL, scope TEXT NOT NULL, payload TEXT NOT NULL, result TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(namespace, scope));");
            try conn.exec("CREATE INDEX IF NOT EXISTS _idempotency_expiry ON _idempotency_receipts(namespace, expires, scope);");
            // Only expired receipts from this namespace. The covering expiry index
            // bounds candidates; live receipts are never evicted to admit a key.
            var cleanup = try conn.prepare("DELETE FROM _idempotency_receipts WHERE namespace=?1 AND scope IN (SELECT scope FROM _idempotency_receipts WHERE namespace=?1 AND expires<=?2 ORDER BY expires, scope LIMIT ?3);");
            defer cleanup.finalize();
            try cleanup.bindText(1, limits.namespace);
            try cleanup.bindInt(2, input.now);
            try cleanup.bindInt(3, limits.cleanup_batch);
            _ = try cleanup.step();

            var previous = try conn.prepare("SELECT payload, result, expires FROM _idempotency_receipts WHERE namespace=?1 AND scope=?2;");
            defer previous.finalize();
            try previous.bindText(1, limits.namespace);
            try previous.bindText(2, &scope);
            if (try previous.step()) {
                // An expired target beyond this cleanup batch is removed explicitly;
                // never report a payload conflict for an expired receipt.
                if (previous.columnInt(2) > input.now) {
                    if (!std.mem.eql(u8, previous.columnText(0), &payload_hash)) return error.PayloadConflict;
                    const body = previous.columnText(1);
                    if (body.len > limits.max_result_bytes) return error.ResultTooLarge;
                    const owned = try allocator.dupe(u8, body);
                    errdefer allocator.free(owned);
                    previous.reset();
                    try conn.commit();
                    return .{ .storage = owned, .len = owned.len, .replayed = true };
                }
                previous.reset();
                var expired = try conn.prepare("DELETE FROM _idempotency_receipts WHERE namespace=?1 AND scope=?2;");
                defer expired.finalize();
                try expired.bindText(1, limits.namespace);
                try expired.bindText(2, &scope);
                _ = try expired.step();
            }
            previous.reset();
            // LIMIT bounds the count even if another configured consumer previously
            // admitted more rows. Different limits cannot shorten stored retention.
            var count = try conn.prepare("SELECT count(*) FROM (SELECT 1 FROM _idempotency_receipts WHERE namespace=?1 LIMIT ?2);");
            defer count.finalize();
            try count.bindText(1, limits.namespace);
            try count.bindInt(2, limits.max_entries);
            _ = try count.step();
            if (count.columnInt(0) >= limits.max_entries) {
                count.reset();
                // Keep bounded cleanup progress when capacity was lowered below an
                // older ledger's size. Authorization is contractually read-only;
                // mutate has not run, so only expired receipts/schema can commit.
                try conn.commit();
                return error.CapacityExceeded;
            }
            count.reset();
            const storage = try allocator.alloc(u8, limits.max_result_bytes);
            errdefer allocator.free(storage);
            const len = try callbacks.mutate(conn, callbacks.context, storage);
            if (len > storage.len) return error.ResultTooLarge;
            var insert = try conn.prepare("INSERT INTO _idempotency_receipts(namespace, scope, payload, result, expires) VALUES (?1, ?2, ?3, ?4, ?5);");
            defer insert.finalize();
            try insert.bindText(1, limits.namespace);
            try insert.bindText(2, &scope);
            try insert.bindText(3, &payload_hash);
            try insert.bindText(4, storage[0..len]);
            try insert.bindInt(5, input.now + limits.retention_seconds);
            _ = try insert.step();
            try conn.commit();
            return .{ .storage = storage, .len = len, .replayed = false };
        }
    };
}

fn hashParts(out: *[64]u8, parts: []const []const u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, @intCast(part.len), .big);
        hash.update(&len);
        hash.update(part);
    }
    const digest = hash.finalResult();
    out.* = std.fmt.bytesToHex(digest, .lower);
}

const TestOperation = struct {
    denied: bool = false,
    fail: bool = false,
    oversize: bool = false,
    auth_calls: usize = 0,
    fn authorize(_: *db.Db, context: *anyopaque) !void {
        const self: *TestOperation = @ptrCast(@alignCast(context));
        self.auth_calls += 1;
        if (self.denied) return error.Forbidden;
    }
    fn mutate(conn: *db.Db, context: *anyopaque, output: []u8) !usize {
        const self: *TestOperation = @ptrCast(@alignCast(context));
        try conn.exec("UPDATE counter SET n=n+1;");
        if (self.fail) return error.MutationFailed;
        if (self.oversize) return output.len + 1;
        @memcpy(output[0..3], "o\x00k");
        return 3;
    }
    fn callbacks(self: *TestOperation) Callbacks {
        return .{ .context = self, .authorize = authorize, .mutate = mutate };
    }
};
const test_input: Input = .{ .principal = .{ .collection = "users", .record = "alice" }, .operation = "increment", .key = "retry-1", .payload = "target=counter;amount=1", .now = 1000 };
fn counter(conn: *db.Db) !i64 {
    var st = try conn.prepare("SELECT n FROM counter;");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "receipt survives lost response; replay reauthorizes and rejects changed payload" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "tests" });
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES (0);");
    var op: TestOperation = .{};
    const first = try I.execute(a, &conn, test_input, op.callbacks());
    try std.testing.expect(!first.replayed);
    first.deinit(a); // Simulate commit succeeded, HTTP response was lost.
    const replay = try I.execute(a, &conn, test_input, op.callbacks());
    defer replay.deinit(a);
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualStrings("o\x00k", replay.body());
    try std.testing.expectEqual(@as(i64, 1), try counter(&conn));
    var changed = test_input;
    changed.payload = "different target";
    try std.testing.expectError(error.PayloadConflict, I.execute(a, &conn, changed, op.callbacks()));
    op.denied = true;
    try std.testing.expectError(error.Forbidden, I.execute(a, &conn, test_input, op.callbacks()));
    try std.testing.expectEqual(@as(usize, 4), op.auth_calls);
    try std.testing.expect(!conn.inTransaction());
}

test "mutation errors, output overflow and allocation failure roll back effects and receipt" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "tests", .max_result_bytes = 3 });
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES (0);");
    var op: TestOperation = .{ .fail = true };
    try std.testing.expectError(error.MutationFailed, I.execute(a, &conn, test_input, op.callbacks()));
    try std.testing.expectEqual(@as(i64, 0), try counter(&conn));
    op.fail = false;
    op.oversize = true;
    try std.testing.expectError(error.ResultTooLarge, I.execute(a, &conn, test_input, op.callbacks()));
    try std.testing.expectEqual(@as(i64, 0), try counter(&conn));
    op.oversize = false;
    try std.testing.expectError(error.OutOfMemory, I.execute(std.testing.failing_allocator, &conn, test_input, op.callbacks()));
    const result = try I.execute(a, &conn, test_input, op.callbacks());
    defer result.deinit(a);
    try std.testing.expect(!result.replayed);
    try std.testing.expectEqual(@as(i64, 1), try counter(&conn));
    try std.testing.expectError(error.OutOfMemory, I.execute(std.testing.failing_allocator, &conn, test_input, op.callbacks()));
    try std.testing.expect(!conn.inTransaction());
}

test "scope components are separate; capacity never evicts live receipts; expiry is stored" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "tests", .max_entries = 2, .retention_seconds = 10, .cleanup_batch = 1 });
    const Short = Idempotency(.{ .namespace = "tests", .max_entries = 2, .retention_seconds = 1, .cleanup_batch = 1 });
    const Other = Idempotency(.{ .namespace = "other", .max_entries = 1, .retention_seconds = 1 });
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES (0);");
    var op: TestOperation = .{};
    var input = test_input;
    input.principal = .{ .collection = "a", .record = "bc" };
    (try I.execute(a, &conn, input, op.callbacks())).deinit(a);
    var second = input;
    second.principal = .{ .collection = "ab", .record = "c" };
    (try I.execute(a, &conn, second, op.callbacks())).deinit(a);
    second.operation = "other";
    try std.testing.expectError(error.CapacityExceeded, I.execute(a, &conn, second, op.callbacks()));
    (try Other.execute(a, &conn, second, op.callbacks())).deinit(a);
    input.now += 2;
    const retained = try Short.execute(a, &conn, input, op.callbacks());
    defer retained.deinit(a);
    try std.testing.expect(retained.replayed); // Shorter policy cannot expire old receipt.
    input.now = 1010;
    input.payload = "changed after expiry";
    const fresh = try I.execute(a, &conn, input, op.callbacks());
    defer fresh.deinit(a);
    try std.testing.expect(!fresh.replayed);
    try std.testing.expectEqual(@as(i64, 4), try counter(&conn));
}

test "invalid input and nested transactions do not mutate or end caller transaction" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "tests", .max_payload_bytes = 32 });
    var conn = try db.Db.openMemory();
    defer conn.close();
    var op: TestOperation = .{};
    var input = test_input;
    input.key = "";
    try std.testing.expectError(error.InvalidScope, I.execute(a, &conn, input, op.callbacks()));
    input = test_input;
    input.payload = "x" ** 33;
    try std.testing.expectError(error.PayloadTooLarge, I.execute(a, &conn, input, op.callbacks()));
    input = test_input;
    input.now = std.math.maxInt(i64);
    try std.testing.expectError(error.InvalidTime, I.execute(a, &conn, input, op.callbacks()));
    try conn.beginImmediate();
    try std.testing.expectError(error.NestedTransaction, I.execute(a, &conn, test_input, op.callbacks()));
    try std.testing.expect(conn.inTransaction());
    try conn.rollback();
    try std.testing.expectEqual(@as(usize, 0), op.auth_calls);
}

test "downsized capacity makes bounded cleanup progress instead of wedging" {
    const a = std.testing.allocator;
    const Large = Idempotency(.{ .namespace = "resize", .max_entries = 4, .retention_seconds = 1 });
    const Small = Idempotency(.{ .namespace = "resize", .max_entries = 1, .cleanup_batch = 1 });
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES (0);");
    var op: TestOperation = .{};
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| {
        var input = test_input;
        input.key = key;
        (try Large.execute(a, &conn, input, op.callbacks())).deinit(a);
    }
    var input = test_input;
    input.now += 1;
    for (0..3) |_| {
        try std.testing.expectError(error.CapacityExceeded, Small.execute(a, &conn, input, op.callbacks()));
        try std.testing.expect(!conn.inTransaction());
    }
    (try Small.execute(a, &conn, input, op.callbacks())).deinit(a);
    try std.testing.expectEqual(@as(i64, 5), try counter(&conn));
}

test "commit failure rolls back mutation and receipt" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "commit-failure" });
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES(0);");
    const Broken = struct {
        fn mutate(c: *db.Db, _: *anyopaque, _: []u8) !usize {
            try c.exec("INSERT INTO child VALUES(42); UPDATE counter SET n=n+1;");
            return 0;
        }
    };
    var op: TestOperation = .{};
    try std.testing.expectError(error.ExecFailed, I.execute(a, &conn, test_input, .{ .context = &op, .authorize = TestOperation.authorize, .mutate = Broken.mutate }));
    try std.testing.expectEqual(@as(i64, 0), try counter(&conn));
    try std.testing.expect(!conn.inTransaction());
    const fresh = try I.execute(a, &conn, test_input, op.callbacks());
    defer fresh.deinit(a);
    try std.testing.expect(!fresh.replayed);
}

test "Postgres is refused before connection access" {
    if (comptime @import("build_options").postgres) {
        var conn: db.Db = .{ .postgres = undefined };
        var op: TestOperation = .{};
        try std.testing.expectError(error.UnsupportedBackend, Idempotency(.{ .namespace = "test" }).execute(std.testing.allocator, &conn, test_input, op.callbacks()));
        try std.testing.expectEqual(@as(usize, 0), op.auth_calls);
    }
}

test "rollback failure preserves the original error and does not reset the connection" {
    const c = @import("c.zig").c;
    const I = Idempotency(.{ .namespace = "rollback-failure" });
    var conn = try db.Db.openMemory();
    defer conn.close();
    const handle = if (comptime @import("build_options").postgres) conn.sqlite.handle else conn.handle;
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES(0);");
    const Failure = struct {
        fn denyRollback(_: ?*anyopaque, action: c_int, detail: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            if (action == c.SQLITE_TRANSACTION and detail != null and std.mem.eql(u8, std.mem.span(detail), "ROLLBACK")) return c.SQLITE_DENY;
            return c.SQLITE_OK;
        }
        fn mutate(connection: *db.Db, _: *anyopaque, _: []u8) !usize {
            try connection.exec("UPDATE counter SET n=n+1;");
            const h = if (comptime @import("build_options").postgres) connection.sqlite.handle else connection.handle;
            try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(h, denyRollback, null));
            return error.MutationFailed;
        }
    };
    // Clear the fault even on assertion failure so close never inherits the hook.
    defer std.debug.assert(c.sqlite3_set_authorizer(handle, null, null) == c.SQLITE_OK);
    var op: TestOperation = .{};
    try std.testing.expectError(error.MutationFailed, I.execute(std.testing.allocator, &conn, test_input, .{ .context = &op, .authorize = TestOperation.authorize, .mutate = Failure.mutate }));
    try std.testing.expect(conn.inTransaction());
    // No pool eviction or reset occurred. Explicit recovery belongs to the caller.
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(handle, null, null));
    try conn.rollback();
    try std.testing.expectEqual(@as(i64, 0), try counter(&conn));
}

test "independent SQLite writers cannot execute a concurrent duplicate" {
    const a = std.testing.allocator;
    const I = Idempotency(.{ .namespace = "concurrency" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/data.db", .{root}, 0);
    defer a.free(path);
    var first = try db.Db.open(path);
    defer first.close();
    var second = try db.Db.open(path);
    defer second.close();
    try first.exec("PRAGMA journal_mode=WAL; CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES (0);");
    const Concurrent = struct {
        second: *db.Db,
        op: TestOperation = .{},
        attempted: bool = false,
        fn auth(_: *db.Db, _: *anyopaque) !void {}
        fn mutate(conn: *db.Db, context: *anyopaque, output: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            // Reenter through a completely independent connection while the first
            // effect is uncommitted. SQLite must refuse BEFORE second authorization.
            try conn.exec("UPDATE counter SET n=n+1;");
            try std.testing.expectError(error.ExecFailed, I.execute(std.testing.allocator, self.second, test_input, self.op.callbacks()));
            try std.testing.expectEqual(@as(usize, 0), self.op.auth_calls);
            self.attempted = true;
            @memcpy(output[0..2], "ok");
            return 2;
        }
    };
    var race: Concurrent = .{ .second = &second };
    (try I.execute(a, &first, test_input, .{ .context = &race, .authorize = Concurrent.auth, .mutate = Concurrent.mutate })).deinit(a);
    try std.testing.expect(race.attempted);
    const retry = try I.execute(a, &second, test_input, race.op.callbacks());
    defer retry.deinit(a);
    try std.testing.expect(retry.replayed);
    try std.testing.expectEqual(@as(i64, 1), try counter(&second));
}
