//! Bounded SQLite statement-step measurements. No SQL or parameter text retained.
const std = @import("std");

pub const Limits = struct { max_entries: u16 = 64, slow_ms: u32 = 100 };
pub fn resolve(comptime cfg: anytype) Limits {
    if (!@hasField(@TypeOf(cfg), "query_workbench")) return .{};
    if (!@import("build_options").query_workbench) @compileError(".query_workbench requires -Dquery-workbench=true");
    if (@typeInfo(@TypeOf(cfg.query_workbench)) != .@"struct") @compileError(".query_workbench must be a struct");
    var result: Limits = .{};
    for (std.meta.fields(@TypeOf(cfg.query_workbench))) |f| {
        if (!@hasField(Limits, f.name)) @compileError("unknown .query_workbench limit: " ++ f.name);
        @field(result, f.name) = @field(cfg.query_workbench, f.name);
    }
    if (result.max_entries == 0 or result.max_entries > 256 or result.slow_ms == 0)
        @compileError("query workbench requires 1..256 entries and positive slow_ms");
    return result;
}

pub const Entry = struct {
    route: [192]u8 = undefined,
    route_len: u8 = 0,
    method: []const u8,
    fingerprint: u64,
    executions: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    slow: u64 = 0,
    repeated: u64 = 0,
    failures: u64 = 0,
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    entries: []Entry,
    count: usize = 0,
    dropped: u64 = 0,

    pub fn create(a: std.mem.Allocator, io: std.Io, limits: Limits) !*Store {
        const self = try a.create(Store);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .io = io, .limits = limits, .entries = try a.alloc(Entry, limits.max_entries) };
        return self;
    }
    pub fn destroy(self: *Store) void {
        const a = self.allocator;
        a.free(self.entries);
        a.destroy(self);
    }
    fn record(self: *Store, scope: *Scope, key: u64, ns: u64, failed: bool) void {
        var repeated = false;
        for (scope.seen[0..scope.seen_count]) |seen| if (seen == key) {
            repeated = true;
            break;
        };
        if (!repeated and scope.seen_count < scope.seen.len) {
            scope.seen[scope.seen_count] = key;
            scope.seen_count += 1;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = blk: {
            for (self.entries[0..self.count]) |*e| if (e.fingerprint == key and
                std.mem.eql(u8, e.route[0..e.route_len], scope.route) and std.mem.eql(u8, e.method, scope.method)) break :blk e;
            if (self.count == self.entries.len or scope.route.len > 192) {
                self.dropped +|= 1;
                return;
            }
            const e = &self.entries[self.count];
            self.count += 1;
            e.* = .{ .method = scope.method, .fingerprint = key, .route_len = @intCast(scope.route.len) };
            @memcpy(e.route[0..scope.route.len], scope.route);
            break :blk e;
        };
        entry.executions +|= 1;
        entry.total_ns +|= ns;
        entry.max_ns = @max(entry.max_ns, ns);
        if (ns >= @as(u64, self.limits.slow_ms) * std.time.ns_per_ms) entry.slow +|= 1;
        if (repeated) entry.repeated +|= 1;
        if (failed) entry.failures +|= 1;
    }
};

threadlocal var current: ?*Scope = null;
var serial: std.atomic.Value(u64) = .init(0);
pub const Scope = struct {
    store: ?*Store,
    route: []const u8,
    method: []const u8,
    previous: ?*Scope = null,
    id: u64 = 0,
    seen: [32]u64 = undefined,
    seen_count: usize = 0,

    pub fn init(store: ?*Store, method: []const u8, route: []const u8) Scope {
        return .{ .store = store, .method = method, .route = route };
    }
    pub fn enter(self: *Scope) void {
        self.previous = current;
        // On astronomical counter exhaustion disable collection, never alias a
        // statement retained across scopes. No request pointer enters a Stmt.
        var id = serial.load(.monotonic);
        while (id != std.math.maxInt(u64)) {
            id = serial.cmpxchgWeak(id, id + 1, .monotonic, .monotonic) orelse {
                self.id = id + 1;
                break;
            };
        }
        if (self.id == 0) self.store = null;
        current = self;
    }
    pub fn leave(self: *Scope) void {
        std.debug.assert(current == self);
        current = self.previous;
    }
};

pub const Measurement = struct {
    scope_id: u64 = 0,
    key: ?u64 = null,
    ns: u64 = 0,
    failed: bool = false,

    pub fn needsSql(self: *const Measurement) bool {
        const scope = current orelse return false;
        return scope.store != null and self.scope_id == 0;
    }

    pub fn before(self: *Measurement, sql: []const u8) ?i96 {
        const scope = current orelse return null;
        const store = scope.store orelse return null;
        if (self.scope_id == 0) {
            self.scope_id = scope.id;
            self.key = fingerprint(sql);
        }
        if (self.scope_id != scope.id or self.key == null) return null;
        return std.Io.Timestamp.now(store.io, .awake).nanoseconds;
    }
    pub fn after(self: *Measurement, started: ?i96, more: bool, failed: bool) void {
        if (started) |start| {
            const scope = current.?;
            const now = std.Io.Timestamp.now(scope.store.?.io, .awake).nanoseconds;
            self.ns +|= @intCast(@min(std.math.maxInt(u64), @max(0, now - start)));
            self.failed = self.failed or failed;
        }
        if (!more) self.finish();
    }
    pub fn finish(self: *Measurement) void {
        defer self.* = .{};
        const scope = current orelse return;
        const store = scope.store orelse return;
        if (scope.id != self.scope_id) return;
        if (self.key) |key| {
            store.record(scope, key, self.ns, self.failed);
        } else if (self.scope_id != 0) {
            store.mutex.lockUncancelable(store.io);
            defer store.mutex.unlock(store.io);
            store.dropped +|= 1;
        }
    }
};

/// Structural fingerprint, NOT a hash of raw SQL. Literal contents, parameter
/// names, identifiers and comments never reach the hash. Only a small keyword
/// allowlist and punctuation survive. Unsupported/oversized input is omitted.
pub fn fingerprint(sql: []const u8) ?u64 {
    if (sql.len == 0 or sql.len > 16384) return null;
    var hash = std.hash.Wyhash.init(0);
    var i: usize = 0;
    while (i < sql.len) {
        const ch = sql[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }
        if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            while (i < sql.len and sql[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            const end = std.mem.indexOf(u8, sql[i + 2 ..], "*/") orelse return null;
            i += end + 4;
            continue;
        }
        if (ch == '\'' or ch == '"' or ch == '`' or ch == '[') {
            const end_ch: u8 = if (ch == '[') ']' else ch;
            i += 1;
            var closed = false;
            while (i < sql.len) {
                if (sql[i] == end_ch) {
                    i += 1;
                    if (ch != '[' and i < sql.len and sql[i] == end_ch) {
                        i += 1;
                        continue;
                    }
                    closed = true;
                    break;
                }
                i += 1;
            }
            if (!closed) return null;
            hash.update(if (ch == '\'') "V " else "I ");
            continue;
        }
        // SQLite's named binds can contain Tcl-style ::suffix(...) with
        // SQL-looking contents. Omit them entirely, never hash their suffix.
        if (ch == '$' or ch == ':' or ch == '@' or ch == '#') return null;
        if (std.ascii.isDigit(ch) or ch == '?') {
            i += 1;
            while (i < sql.len and (std.ascii.isAlphanumeric(sql[i]) or sql[i] == '_' or sql[i] == '.')) : (i += 1) {}
            hash.update("V ");
            continue;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < sql.len and (std.ascii.isAlphanumeric(sql[i]) or sql[i] == '_')) : (i += 1) {}
            const word = sql[start..i];
            var keyword = false;
            inline for (.{ "SELECT", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "JOIN", "LEFT", "INNER", "ON", "AND", "OR", "IN", "NOT", "NULL", "ORDER", "BY", "GROUP", "LIMIT", "OFFSET", "ASC", "DESC", "SET", "VALUES", "RETURNING", "IS", "LIKE", "EXISTS", "DISTINCT" }) |known| {
                if (std.ascii.eqlIgnoreCase(word, known)) {
                    hash.update(known ++ " ");
                    keyword = true;
                }
            }
            if (!keyword) hash.update("I ");
            continue;
        }
        if (std.mem.indexOfScalar(u8, "(),.*=<>!+-/%|&;", ch) != null) {
            hash.update(&.{ ch, ' ' });
            i += 1;
            continue;
        }
        return null;
    }
    return hash.final();
}

test "fingerprints exclude literal identifier parameter and comment contents" {
    try std.testing.expectEqual(fingerprint("SELECT secret FROM accounts WHERE email='alice-secret' -- ignored"), fingerprint("select other FROM other WHERE name='bob''secret'"));
    try std.testing.expectEqual(fingerprint("SELECT \"secret\" FROM x WHERE n = ?123"), fingerprint("SELECT \"other\" FROM z WHERE p = 99123"));
    try std.testing.expectEqual(null, fingerprint("SELECT 'unterminated"));
    try std.testing.expectEqual(null, fingerprint("SELECT /* unclosed"));
    try std.testing.expectEqual(null, fingerprint("SELECT $x(SELECT)"));
    try std.testing.expectEqual(null, fingerprint("SELECT $x(DELETE)"));
    try std.testing.expectEqual(null, fingerprint("SELECT $x::name(private)"));
    try std.testing.expectEqual(null, fingerprint("SELECT :x(SELECT)"));
    try std.testing.expectEqual(null, fingerprint("SELECT @x(DELETE)"));
    try std.testing.expectEqual(null, fingerprint("SELECT #x::name(private)"));
}

test "bounded aggregates repeats slow errors and nested scope restoration" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{ .max_entries = 1, .slow_ms = 1 });
    defer store.destroy();
    var outer = Scope.init(store, "GET", "/items/:id");
    outer.enter();
    defer outer.leave();
    store.record(&outer, 1, 2_000_000, false);
    store.record(&outer, 1, 1, true);
    store.record(&outer, 2, 1, false);
    var nested = Scope.init(null, "GET", "/inspect");
    nested.enter();
    nested.leave();
    try std.testing.expect(current == &outer);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(@as(u64, 1), store.dropped);
    try std.testing.expectEqual(@as(u64, 2), store.entries[0].executions);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].repeated);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].slow);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].failures);
}

test "cross-thread retained measurements cannot alias another request scope" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    const H = struct {
        fn begin(s: *Store, measurement: *Measurement) void {
            var scope = Scope.init(s, "GET", "/first/:id");
            scope.enter();
            defer scope.leave();
            _ = measurement.before("SELECT ?1");
        }
        fn finish(s: *Store, measurement: *Measurement) void {
            var scope = Scope.init(s, "GET", "/second/:id");
            scope.enter();
            defer scope.leave();
            measurement.finish();
        }
    };
    var measurement: Measurement = .{};
    const first = try std.Thread.spawn(.{}, H.begin, .{ store, &measurement });
    first.join();
    const second = try std.Thread.spawn(.{}, H.finish, .{ store, &measurement });
    second.join();
    try std.testing.expectEqual(@as(usize, 0), store.count);
    try std.testing.expect(current == null);
}
