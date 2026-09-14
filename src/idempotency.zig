//! Opt-in transactional receipts for trusted, database-only custom operations.
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
            const pg = db.dbDialect(conn).kind == .postgres;
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
            if (pg) try conn.exec("BEGIN ISOLATION LEVEL READ COMMITTED;") else try conn.beginImmediate();
            errdefer if (conn.inTransaction()) conn.rollback() catch |err| std.log.warn("idempotency rollback failed: {s}; connection state uncertain; no automatic reset; caller must stop reuse and recover the connection/pool", .{@errorName(err)});
            if (pg) try lockNamespace(conn, limits.namespace);
            try callbacks.authorize(conn, callbacks.context);
            if (pg) {
                try ensurePgLedger(conn);
            } else {
                _ = try sqliteLedgerExists(conn);
                try conn.exec("CREATE TABLE IF NOT EXISTS _idempotency_receipts (namespace TEXT NOT NULL, scope TEXT NOT NULL, payload TEXT NOT NULL, result TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(namespace, scope));");
                try conn.exec("CREATE INDEX IF NOT EXISTS _idempotency_expiry ON _idempotency_receipts(namespace, expires, scope);");
            }
            // BYTEA parameters use bounded ASCII hex through the text-only driver.
            const namespace_hex = comptime std.fmt.bytesToHex(limits.namespace, .lower);
            const namespace = if (pg) &namespace_hex else limits.namespace;
            // Only expired receipts from this namespace. The covering expiry index
            // bounds candidates; live receipts are never evicted to admit a key.
            var cleanup = try conn.prepare(if (pg) "DELETE FROM _idempotency_receipts WHERE namespace=decode($1,'hex') AND scope IN (SELECT scope FROM _idempotency_receipts WHERE namespace=decode($1,'hex') AND expires<=$2 ORDER BY expires, scope LIMIT $3);" else "DELETE FROM _idempotency_receipts WHERE namespace=?1 AND scope IN (SELECT scope FROM _idempotency_receipts WHERE namespace=?1 AND expires<=?2 ORDER BY expires, scope LIMIT ?3);");
            defer cleanup.finalize();
            try cleanup.bindText(1, namespace);
            try cleanup.bindInt(2, input.now);
            try cleanup.bindInt(3, limits.cleanup_batch);
            _ = try cleanup.step();

            // Reject oversized stored results before the PG driver buffers row data.
            var previous = try conn.prepare(if (pg) "SELECT left(payload,65), CASE WHEN octet_length(result)<=$3 THEN encode(result,'hex') ELSE '' END, expires, octet_length(result) FROM _idempotency_receipts WHERE namespace=decode($1,'hex') AND scope=$2;" else "SELECT substr(payload,1,65), CASE WHEN length(CAST(result AS BLOB))<=?3 THEN result ELSE '' END, expires, length(CAST(result AS BLOB)) FROM _idempotency_receipts WHERE namespace=?1 AND scope=?2;");
            defer previous.finalize();
            try previous.bindText(1, namespace);
            try previous.bindText(2, &scope);
            try previous.bindInt(3, limits.max_result_bytes);
            if (try previous.step()) {
                // An expired target beyond this cleanup batch is removed explicitly;
                // never report a payload conflict for an expired receipt.
                if (previous.columnInt(2) > input.now) {
                    if (!std.mem.eql(u8, previous.columnText(0), &payload_hash)) return error.PayloadConflict;
                    const body = previous.columnText(1);
                    if (previous.columnInt(3) > limits.max_result_bytes) return error.ResultTooLarge;
                    const owned = try allocator.alloc(u8, if (pg) body.len / 2 else body.len);
                    errdefer allocator.free(owned);
                    if (pg) {
                        _ = try std.fmt.hexToBytes(owned, body);
                    } else @memcpy(owned, body);
                    previous.reset();
                    try conn.commit();
                    return .{ .storage = owned, .len = owned.len, .replayed = true };
                }
                previous.reset();
                var expired = try conn.prepare(if (pg) "DELETE FROM _idempotency_receipts WHERE namespace=decode($1,'hex') AND scope=$2;" else "DELETE FROM _idempotency_receipts WHERE namespace=?1 AND scope=?2;");
                defer expired.finalize();
                try expired.bindText(1, namespace);
                try expired.bindText(2, &scope);
                _ = try expired.step();
            }
            previous.reset();
            // LIMIT bounds the count even if another configured consumer previously
            // admitted more rows. Different limits cannot shorten stored retention.
            var count = try conn.prepare(if (pg) "SELECT count(*) FROM (SELECT 1 FROM _idempotency_receipts WHERE namespace=decode($1,'hex') LIMIT $2) AS bounded;" else "SELECT count(*) FROM (SELECT 1 FROM _idempotency_receipts WHERE namespace=?1 LIMIT ?2);");
            defer count.finalize();
            try count.bindText(1, namespace);
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
            const encoded = if (pg) try allocator.alloc(u8, len * 2) else null;
            defer if (encoded) |bytes| allocator.free(bytes);
            if (encoded) |bytes| {
                const alphabet = "0123456789abcdef";
                for (storage[0..len], 0..) |byte, i| {
                    bytes[i * 2] = alphabet[byte >> 4];
                    bytes[i * 2 + 1] = alphabet[byte & 15];
                }
            }
            var insert = try conn.prepare(if (pg) "INSERT INTO _idempotency_receipts(namespace, scope, payload, result, expires) VALUES (decode($1,'hex'), $2, $3, decode($4,'hex'), $5);" else "INSERT INTO _idempotency_receipts(namespace, scope, payload, result, expires) VALUES (?1, ?2, ?3, ?4, ?5);");
            defer insert.finalize();
            try insert.bindText(1, namespace);
            try insert.bindText(2, &scope);
            try insert.bindText(3, &payload_hash);
            try insert.bindText(4, encoded orelse storage[0..len]);
            try insert.bindInt(5, input.now + limits.retention_seconds);
            _ = try insert.step();
            try conn.commit();
            return .{ .storage = storage, .len = len, .replayed = false };
        }
    };
}

fn lockNamespace(conn: *db.Db, namespace: []const u8) !void {
    var key_hash: [64]u8 = undefined;
    hashParts(&key_hash, &.{ "zigbase-idempotency-namespace-v1", namespace });
    var digest: [8]u8 = undefined;
    _ = try std.fmt.hexToBytes(&digest, key_hash[0..16]);
    // One-bigint keys are disjoint from the engine's two-int lock keys.
    // Hash collisions only cause contention, never shared receipts.
    var lock = try conn.prepare("SELECT pg_try_advisory_xact_lock($1::bigint);");
    defer lock.finalize();
    try lock.bindInt(1, @bitCast(std.mem.readInt(u64, &digest, .big)));
    _ = try lock.step();
    if (!std.mem.eql(u8, lock.columnText(0), "t")) return error.IdempotencyBusy;
}

/// Shared with database copying: unqualified receipt SQL must resolve to the
/// intended schema's durable ordinary table, never a shadow or fallback object.
pub fn pgLedgerExists(conn: *db.Db) (db.DbError || error{InvalidReceiptLedger})!bool {
    var query = try conn.prepare("SELECT c.oid IS NOT NULL, COALESCE(n.nspname=current_schema() AND c.relpersistence='p' AND c.relkind='r', false) FROM (SELECT to_regclass('_idempotency_receipts') AS oid) resolved LEFT JOIN pg_catalog.pg_class c ON c.oid=resolved.oid LEFT JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace;");
    defer query.finalize();
    _ = try query.step();
    if (!std.mem.eql(u8, query.columnText(0), "t")) return false;
    if (!std.mem.eql(u8, query.columnText(1), "t")) return error.InvalidReceiptLedger;
    return true;
}

/// SQLite resolves TEMP before main, then attached databases. Never let a
/// temporary/view/virtual ledger hide receipts or adopt an attached fallback.
pub fn sqliteLedgerExists(conn: *db.Db) (db.DbError || error{InvalidReceiptLedger})!bool {
    // Direct PRAGMA cannot be shadowed by a user table named pragma_table_list.
    // SQLite streams catalog rows, so filtering does not buffer all schemas.
    var query = try conn.prepare("PRAGMA table_list;");
    defer query.finalize();
    var main = false;
    var attached = false;
    while (try query.step()) {
        if (!std.ascii.eqlIgnoreCase(query.columnText(1), "_idempotency_receipts")) continue;
        const namespace = query.columnText(0);
        if (std.mem.eql(u8, namespace, "temp")) return error.InvalidReceiptLedger;
        if (std.mem.eql(u8, namespace, "main")) {
            if (!std.mem.eql(u8, query.columnText(2), "table")) return error.InvalidReceiptLedger;
            main = true;
        } else attached = true;
    }
    if (attached) return error.InvalidReceiptLedger;
    return main;
}

fn ensurePgLedger(conn: *db.Db) !void {
    if (try pgLedgerExists(conn)) return;
    // Serialize only cold first-use DDL across namespaces, never warm traffic.
    // Failed authorization never creates the lazy ledger.
    var lock = try conn.prepare("SELECT pg_try_advisory_xact_lock(1514294599, 3);");
    defer lock.finalize();
    _ = try lock.step();
    if (!std.mem.eql(u8, lock.columnText(0), "t")) return error.IdempotencyBusy;
    if (try pgLedgerExists(conn)) return;
    try conn.exec("CREATE TABLE _idempotency_receipts (namespace BYTEA NOT NULL, scope TEXT NOT NULL, payload TEXT NOT NULL, result BYTEA NOT NULL, expires BIGINT NOT NULL, PRIMARY KEY(namespace, scope)); CREATE INDEX _idempotency_expiry ON _idempotency_receipts(namespace, expires, scope);");
    // A cold search_path may create into pg_temp. Check the actual new object
    // while its DDL is still rollbackable, before cleanup or callback mutation.
    if (!try pgLedgerExists(conn)) return error.InvalidReceiptLedger;
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

test "SQLite rejects temporary receipt shadows without losing replay" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES(0);");
    const I = Idempotency(.{ .namespace = "shadow" });
    var op: TestOperation = .{};
    (try I.execute(a, &conn, test_input, op.callbacks())).deinit(a);
    for ([_][:0]const u8{
        "CREATE TEMP TABLE _IDEMPOTENCY_RECEIPTS AS SELECT * FROM main._idempotency_receipts WHERE 0;",
        "CREATE TEMP VIEW _idempotency_receipts AS SELECT * FROM main._idempotency_receipts WHERE 0;",
    }) |sql| {
        try conn.exec(sql);
        try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &conn, test_input, op.callbacks()));
        try std.testing.expectEqual(@as(i64, 1), try counter(&conn));
        try std.testing.expect(!conn.inTransaction());
        if (std.mem.indexOf(u8, sql, "TABLE") != null)
            try conn.exec("DROP TABLE temp._idempotency_receipts;")
        else
            try conn.exec("DROP VIEW temp._idempotency_receipts;");
        const replay = try I.execute(a, &conn, test_input, op.callbacks());
        defer replay.deinit(a);
        try std.testing.expect(replay.replayed);
    }
}

test "pg receipts coordinate cold starts, namespaces, binary replay and bounded retention" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var first = try db.Db.openPostgres(a, std.testing.io, url);
    defer first.close();
    var second = try db.Db.openPostgres(a, std.testing.io, url);
    defer second.close();
    const token = try @import("crypto.zig").genToken(std.testing.io, a, 12);
    defer a.free(token);
    const create = try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA idem_{s};", .{token}, 0);
    defer a.free(create);
    const drop = try std.fmt.allocPrintSentinel(a, "DROP SCHEMA idem_{s} CASCADE;", .{token}, 0);
    defer a.free(drop);
    const path = try std.fmt.allocPrintSentinel(a, "SET search_path TO idem_{s};", .{token}, 0);
    defer a.free(path);
    try first.exec(create);
    defer first.exec(drop) catch |err| std.log.err("idempotency test schema cleanup: {s}", .{@errorName(err)});
    try first.exec(path);
    try second.exec(path);
    try second.exec("SET default_transaction_isolation='repeatable read'; SET lock_timeout='100ms';");
    try first.exec("CREATE TABLE counter(n BIGINT); INSERT INTO counter VALUES(0);");
    const I = Idempotency(.{ .namespace = "pg\x00\xff", .max_entries = 1, .retention_seconds = 10, .cleanup_batch = 1 });
    const Other = Idempotency(.{ .namespace = "other" });
    const Op = struct {
        other: *db.Db,
        cold: bool = true,
        calls: usize = 0,
        auth_calls: usize = 0,
        fn auth(_: *db.Db, context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.auth_calls += 1;
        }
        fn noEffect(_: *db.Db, _: *anyopaque, out: []u8) !usize {
            out[0] = 'x';
            return 1;
        }
        fn mutate(conn: *db.Db, context: *anyopaque, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try conn.exec("UPDATE counter SET n=n+1;");
            var denied: TestOperation = .{};
            var request = test_input;
            request.key = "different-key-same-capacity";
            try std.testing.expectError(error.IdempotencyBusy, I.execute(std.testing.allocator, self.other, request, denied.callbacks()));
            try std.testing.expectEqual(@as(usize, 0), denied.auth_calls);
            const callbacks: Callbacks = .{ .context = self, .authorize = auth, .mutate = noEffect };
            if (self.cold) {
                try std.testing.expectError(error.IdempotencyBusy, Other.execute(std.testing.allocator, self.other, test_input, callbacks));
            } else {
                (try Other.execute(std.testing.allocator, self.other, test_input, callbacks)).deinit(std.testing.allocator);
            }
            @memcpy(out[0..3], "o\x00\xff");
            return 3;
        }
    };
    var op = Op{ .other = &second };
    const callbacks: Callbacks = .{ .context = &op, .authorize = Op.auth, .mutate = Op.mutate };
    var denied: TestOperation = .{ .denied = true };
    try std.testing.expectError(error.Forbidden, I.execute(a, &first, test_input, denied.callbacks()));
    try std.testing.expect(!try pgLedgerExists(&first));
    const initial = try I.execute(a, &first, test_input, callbacks);
    defer initial.deinit(a);
    try std.testing.expectEqualSlices(u8, "o\x00\xff", initial.body());
    try std.testing.expect(!initial.replayed);
    const replay = try I.execute(a, &second, test_input, callbacks);
    defer replay.deinit(a);
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualSlices(u8, initial.body(), replay.body());
    try std.testing.expectEqual(@as(usize, 1), op.calls);
    try std.testing.expectError(error.Forbidden, I.execute(a, &first, test_input, denied.callbacks()));
    var changed = test_input;
    changed.payload = "changed";
    try std.testing.expectError(error.PayloadConflict, I.execute(a, &first, changed, callbacks));
    changed.key = "new";
    try std.testing.expectError(error.CapacityExceeded, I.execute(a, &first, changed, callbacks));
    const Small = Idempotency(.{ .namespace = "pg\x00\xff", .max_result_bytes = 2 });
    try std.testing.expectError(error.ResultTooLarge, Small.execute(a, &second, test_input, callbacks));
    try first.exec("UPDATE _idempotency_receipts SET result=decode(repeat('ff',1000000),'hex');");
    try std.testing.expectError(error.ResultTooLarge, Small.execute(a, &second, test_input, callbacks));
    // The driver itself has less memory than the stored value. Returning the
    // budget error (not OOM) proves SQL bounded the row before buffering it.
    const bounded_memory = try a.alloc(u8, 256 * 1024);
    defer a.free(bounded_memory);
    var bounded_allocator = std.heap.FixedBufferAllocator.init(bounded_memory);
    {
        var bounded = try db.Db.openPostgres(bounded_allocator.allocator(), std.testing.io, url);
        defer bounded.close();
        try bounded.exec(path);
        try std.testing.expectError(error.ResultTooLarge, Small.execute(a, &bounded, test_input, callbacks));
    }
    try std.testing.expectEqual(@as(usize, 1), op.calls);
    // A post-2038 timestamp and an expired full namespace admit one fresh key.
    changed.now = 4_000_000_000;
    op.cold = false;
    (try I.execute(a, &first, changed, callbacks)).deinit(a);
    try std.testing.expectEqual(@as(i64, 2), try counter(&first));
    var fail: TestOperation = .{ .fail = true };
    const Failing = Idempotency(.{ .namespace = "failure" });
    try std.testing.expectError(error.MutationFailed, Failing.execute(a, &first, changed, fail.callbacks()));
    try std.testing.expectEqual(@as(i64, 2), try counter(&first));
    fail.fail = false;
    fail.oversize = true;
    try std.testing.expectError(error.ResultTooLarge, Failing.execute(a, &first, changed, fail.callbacks()));
    try std.testing.expectEqual(@as(i64, 2), try counter(&first));
    fail.oversize = false;
    (try Failing.execute(a, &first, changed, fail.callbacks())).deinit(a);
    // Deferred constraints fail at COMMIT, after the receipt INSERT. Neither
    // that receipt nor the callback's effects may survive the failed commit.
    try first.exec("CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);");
    const CommitFailure = struct {
        fn mutate(conn: *db.Db, _: *anyopaque, out: []u8) !usize {
            try conn.exec("UPDATE counter SET n=n+1; INSERT INTO child VALUES(1);");
            out[0] = 'x';
            return 1;
        }
    };
    const Committing = Idempotency(.{ .namespace = "commit-failure" });
    try std.testing.expectError(error.ExecFailed, Committing.execute(a, &first, changed, .{ .context = &fail, .authorize = TestOperation.authorize, .mutate = CommitFailure.mutate }));
    try std.testing.expect(!first.inTransaction());
    try std.testing.expectEqual(@as(i64, 3), try counter(&first));
    const retry = try Committing.execute(a, &first, changed, .{ .context = &op, .authorize = Op.auth, .mutate = Op.noEffect });
    defer retry.deinit(a);
    try std.testing.expect(!retry.replayed);
    try first.begin();
    try std.testing.expectError(error.NestedTransaction, I.execute(a, &first, changed, callbacks));
    try std.testing.expect(first.inTransaction());
    try first.rollback();
    // Connection loss releases transaction locks without session-pool cleanup.
    {
        var gone = try db.Db.openPostgres(a, std.testing.io, url);
        defer gone.close();
        try gone.begin();
        try lockNamespace(&gone, "pg\x00\xff");
    }
    (try I.execute(a, &first, changed, callbacks)).deinit(a);
    // Both conversion directions must refuse nonempty lazy ledgers before
    // touching the destination, not silently omit receipts from a fresh copy.
    var sqlite = try db.Db.openMemory();
    defer sqlite.close();
    const copy = @import("dumpload.zig");
    try std.testing.expectError(error.IdempotencyReceiptsPresent, copy.run(a, &first, &sqlite, .{ .force = true }));
    try std.testing.expectError(error.IdempotencyReceiptsPresent, copy.run(a, &sqlite, &first, .{ .force = true }));
    var untouched = try sqlite.prepare("SELECT count(*) FROM sqlite_master;");
    defer untouched.finalize();
    _ = try untouched.step();
    try std.testing.expectEqual(@as(i64, 0), untouched.columnInt(0));
    try std.testing.expectEqual(@as(i64, 3), try counter(&first));
    // A ledger found later on search_path must not be adopted into this schema.
    const fallback_create = try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA fallback_{s}; ALTER TABLE _idempotency_receipts SET SCHEMA fallback_{s}; SET search_path TO idem_{s},fallback_{s};", .{ token, token, token, token }, 0);
    defer a.free(fallback_create);
    const fallback_drop = try std.fmt.allocPrintSentinel(a, "DROP SCHEMA fallback_{s} CASCADE;", .{token}, 0);
    defer a.free(fallback_drop);
    try first.exec(fallback_create);
    defer first.exec(fallback_drop) catch |err| std.log.err("idempotency fallback test cleanup: {s}", .{@errorName(err)});
    try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &first, changed, callbacks));
    try std.testing.expectError(error.InvalidReceiptLedger, copy.run(a, &first, &sqlite, .{ .force = true }));
    try std.testing.expectError(error.InvalidReceiptLedger, copy.run(a, &sqlite, &first, .{ .force = true }));
    try first.exec("CREATE VIEW _idempotency_receipts AS SELECT 1 AS sentinel;");
    try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &first, changed, callbacks));
    try std.testing.expectError(error.InvalidReceiptLedger, copy.run(a, &first, &sqlite, .{ .force = true }));
    try first.exec("DROP VIEW _idempotency_receipts;");
    const restore = try std.fmt.allocPrintSentinel(a, "ALTER TABLE fallback_{s}._idempotency_receipts SET SCHEMA idem_{s};", .{ token, token }, 0);
    defer a.free(restore);
    try first.exec(restore);
    try first.exec("CREATE TEMP TABLE _idempotency_receipts(sentinel INTEGER); INSERT INTO _idempotency_receipts VALUES(42);");
    try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &first, changed, callbacks));
    try std.testing.expectError(error.InvalidReceiptLedger, copy.run(a, &first, &sqlite, .{ .force = true }));
    var sentinel = try first.prepare("SELECT sentinel FROM _idempotency_receipts;");
    defer sentinel.finalize();
    try std.testing.expect(try sentinel.step());
    try std.testing.expectEqual(@as(i64, 42), sentinel.columnInt(0));
    sentinel.reset();
    try first.exec("DROP TABLE pg_temp._idempotency_receipts; ALTER TABLE _idempotency_receipts SET UNLOGGED;");
    try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &first, changed, callbacks));
    try std.testing.expectError(error.InvalidReceiptLedger, copy.run(a, &sqlite, &first, .{ .force = true }));
    try first.exec("ALTER TABLE _idempotency_receipts SET LOGGED;");
    const unchanged = try I.execute(a, &first, changed, callbacks);
    defer unchanged.deinit(a);
    try std.testing.expect(unchanged.replayed);
    try std.testing.expectEqual(@as(i64, 3), try counter(&first));
    const Batch = Idempotency(.{ .namespace = "batch", .max_entries = 4, .cleanup_batch = 1, .retention_seconds = 10 });
    const no_effect: Callbacks = .{ .context = &op, .authorize = Op.auth, .mutate = Op.noEffect };
    var batch_input = test_input;
    for ([_][]const u8{ "oldest", "older", "target" }, 0..) |key, i| {
        batch_input.key = key;
        batch_input.now = 1000 + @as(i64, @intCast(i));
        (try Batch.execute(a, &first, batch_input, no_effect)).deinit(a);
    }
    // Target expires after other rows and lies beyond this cleanup's one-row
    // batch. Its old payload must not prevent explicit replacement.
    batch_input.now = 1012;
    batch_input.payload = "new expired-target payload";
    const replacement = try Batch.execute(a, &first, batch_input, no_effect);
    defer replacement.deinit(a);
    try std.testing.expect(!replacement.replayed);
    const Wide = Idempotency(.{ .namespace = "progress", .max_entries = 4, .cleanup_batch = 1, .retention_seconds = 10 });
    const Narrow = Idempotency(.{ .namespace = "progress", .max_entries = 1, .cleanup_batch = 1, .retention_seconds = 10 });
    for ([_][]const u8{ "a", "b", "c", "d" }, 0..) |key, i| {
        batch_input.key = key;
        batch_input.now = 1000 + @as(i64, @intCast(i));
        (try Wide.execute(a, &first, batch_input, no_effect)).deinit(a);
    }
    batch_input.key = "new";
    batch_input.now = 1013;
    for (0..3) |_| try std.testing.expectError(error.CapacityExceeded, Narrow.execute(a, &first, batch_input, no_effect));
    const admitted = try Narrow.execute(a, &first, batch_input, no_effect);
    defer admitted.deinit(a);
    try std.testing.expect(!admitted.replayed);
}

test "pg quoted schema names and cold temporary paths retain durable ownership" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var first = try db.Db.openPostgres(a, std.testing.io, url);
    defer first.close();
    const token = try @import("crypto.zig").genToken(std.testing.io, a, 12);
    defer a.free(token);
    const create = try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"Idem-App Data-{s}\";", .{token}, 0);
    defer a.free(create);
    const drop = try std.fmt.allocPrintSentinel(a, "DROP SCHEMA \"Idem-App Data-{s}\" CASCADE;", .{token}, 0);
    defer a.free(drop);
    const path = try std.fmt.allocPrintSentinel(a, "SET search_path TO \"Idem-App Data-{s}\";", .{token}, 0);
    defer a.free(path);
    const update = try std.fmt.allocPrintSentinel(a, "UPDATE \"Idem-App Data-{s}\".counter SET n=n+1;", .{token}, 0);
    defer a.free(update);
    try first.exec(create);
    defer first.exec(drop) catch |err| std.log.err("quoted schema test cleanup: {s}", .{@errorName(err)});
    try first.exec(path);
    try first.exec("CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES(0);");
    const I = Idempotency(.{ .namespace = "quoted-schema" });
    var op: TestOperation = .{};
    const initial = try I.execute(a, &first, test_input, op.callbacks());
    defer initial.deinit(a);
    try std.testing.expect(!initial.replayed);
    const replay = try I.execute(a, &first, test_input, op.callbacks());
    defer replay.deinit(a);
    try std.testing.expect(replay.replayed);
    var target = try db.Db.openMemory();
    defer target.close();
    try std.testing.expectError(error.IdempotencyReceiptsPresent, @import("dumpload.zig").run(a, &first, &target, .{ .force = true }));
    const TempOperation = struct {
        sql: [:0]const u8,
        calls: usize = 0,
        fn authorize(_: *db.Db, _: *anyopaque) !void {}
        fn mutate(conn: *db.Db, context: *anyopaque, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try conn.exec(self.sql);
            out[0] = 'x';
            return 1;
        }
    };
    // Exercise pg_temp both before and after an explicit temporary object.
    for ([_]bool{ false, true }) |initialized| {
        var temporary = try db.Db.openPostgres(a, std.testing.io, url);
        defer temporary.close();
        if (initialized) try temporary.exec("CREATE TEMP TABLE sentinel(value INTEGER); INSERT INTO sentinel VALUES(42);");
        try temporary.exec("SET search_path TO pg_temp;");
        var temp_op = TempOperation{ .sql = update };
        try std.testing.expectError(error.InvalidReceiptLedger, I.execute(a, &temporary, test_input, .{ .context = &temp_op, .authorize = TempOperation.authorize, .mutate = TempOperation.mutate }));
        try std.testing.expectEqual(@as(usize, 0), temp_op.calls);
        try std.testing.expect(!temporary.inTransaction());
        try std.testing.expectEqual(@as(i64, 1), try counter(&first));
        var ledger = try temporary.prepare("SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace=pg_my_temp_schema() AND relname='_idempotency_receipts';");
        defer ledger.finalize();
        try std.testing.expect(try ledger.step());
        try std.testing.expectEqual(@as(i64, 0), ledger.columnInt(0));
        if (initialized) {
            var sentinel = try temporary.prepare("SELECT value FROM sentinel;");
            defer sentinel.finalize();
            try std.testing.expect(try sentinel.step());
            try std.testing.expectEqual(@as(i64, 42), sentinel.columnInt(0));
        }
    }
}

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
