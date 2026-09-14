//! Bounded backend-labelled execution and completed-statement lifecycle measurements.
//! No SQL or parameter text retained.
const std = @import("std");
pub const Backend = enum { sqlite, postgres };
const Seen = struct { backend: Backend, key: u64 };

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
    backend: Backend = .sqlite,
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
    statements: u64 = 0,
    lifetime_ns: u64 = 0,
    max_lifetime_ns: u64 = 0,
    calls_ns: u64 = 0,
    held_ns: u64 = 0,
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    entries: []Entry,
    count: usize = 0,
    dropped: u64 = 0,
    dropped_statements: u64 = 0,

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
    fn record(self: *Store, scope: *Scope, backend: Backend, key: u64, ns: u64, failed: bool) void {
        var repeated = false;
        for (scope.seen[0..scope.seen_count]) |seen| if (seen.key == key and seen.backend == backend) {
            repeated = true;
            break;
        };
        if (!repeated and scope.seen_count < scope.seen.len) {
            scope.seen[scope.seen_count] = .{ .backend = backend, .key = key };
            scope.seen_count += 1;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.findEntry(scope, backend, key) orelse {
            self.dropped +|= 1;
            return;
        };
        entry.executions +|= 1;
        entry.total_ns +|= ns;
        entry.max_ns = @max(entry.max_ns, ns);
        if (ns >= @as(u64, self.limits.slow_ms) * std.time.ns_per_ms) entry.slow +|= 1;
        if (repeated) entry.repeated +|= 1;
        if (failed) entry.failures +|= 1;
    }

    // Caller holds mutex. Both metric families share the same bounded key table.
    fn findEntry(self: *Store, scope: *Scope, backend: Backend, key: u64) ?*Entry {
        for (self.entries[0..self.count]) |*e| if (e.backend == backend and e.fingerprint == key and
            std.mem.eql(u8, e.route[0..e.route_len], scope.route) and std.mem.eql(u8, e.method, scope.method)) return e;
        if (self.count == self.entries.len or scope.route.len > 192) return null;
        const e = &self.entries[self.count];
        self.count += 1;
        e.* = .{ .backend = backend, .method = scope.method, .fingerprint = key, .route_len = @intCast(scope.route.len) };
        @memcpy(e.route[0..scope.route.len], scope.route);
        return e;
    }

    fn recordLifetime(self: *Store, scope: *Scope, backend: Backend, key: ?u64, lifetime: u64, calls: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = if (key) |k| self.findEntry(scope, backend, k) else null;
        const value = e orelse {
            self.dropped_statements +|= 1;
            return;
        };
        value.statements +|= 1;
        value.lifetime_ns +|= lifetime;
        value.max_lifetime_ns = @max(value.max_lifetime_ns, lifetime);
        value.calls_ns +|= calls;
        value.held_ns +|= lifetime -| calls;
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
    seen: [32]Seen = undefined,
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
    backend: Backend = .sqlite,
    scope_id: u64 = 0,
    key: ?u64 = null,
    ns: u64 = 0,
    failed: bool = false,

    pub fn needsKey(self: *const Measurement) bool {
        const scope = current orelse return false;
        return scope.store != null and self.scope_id == 0;
    }

    pub fn beforeKeyed(self: *Measurement, key: ?u64) ?i96 {
        const scope = current orelse return null;
        const store = scope.store orelse return null;
        if (self.scope_id == 0) {
            self.scope_id = scope.id;
            self.key = key;
        }
        if (self.scope_id != scope.id or self.key == null) return null;
        return std.Io.Timestamp.now(store.io, .awake).nanoseconds;
    }
    pub fn after(self: *Measurement, started: ?i96, more: bool, failed: bool) ?i96 {
        var ended: ?i96 = null;
        if (started) |start| {
            const scope = current.?;
            const now = std.Io.Timestamp.now(scope.store.?.io, .awake).nanoseconds;
            ended = now;
            self.ns +|= elapsed(start, now);
            self.failed = self.failed or failed;
        }
        if (!more) self.finish();
        return ended;
    }
    pub fn finish(self: *Measurement) void {
        defer self.* = .{};
        const scope = current orelse return;
        const store = scope.store orelse return;
        if (scope.id != self.scope_id) return;
        if (self.key) |key| {
            store.record(scope, self.backend, key, self.ns, self.failed);
        } else if (self.scope_id != 0) {
            store.mutex.lockUncancelable(store.io);
            defer store.mutex.unlock(store.io);
            store.dropped +|= 1;
        }
    }
};

fn elapsed(start: i96, end: i96) u64 {
    return @intCast(@min(std.math.maxInt(u64), @max(0, end -| start)));
}

/// A successful prepare through finalize, including all reset/reuse cycles.
/// Numeric scope identity only: no request/store pointer can escape in a Stmt.
/// Each measured call must stay in the originating scope; otherwise omit the
/// lifetime instead of guessing attribution. Scope exit itself retains no Stmts.
pub const Lifetime = struct {
    backend: Backend = .sqlite,
    // Distinguish never-scoped prepares from an origin that was lost. The latter
    // must not regain execution attribution through an unscoped fallback.
    invalidated: bool = false,
    scope_id: u64 = 0,
    key: ?u64 = null,
    started: i96 = 0,
    calls_ns: u64 = 0,

    pub fn begin() Lifetime {
        const scope = current orelse return .{};
        const store = scope.store orelse return .{};
        return .{ .scope_id = scope.id, .started = std.Io.Timestamp.now(store.io, .awake).nanoseconds };
    }

    pub fn prepared(self: *Lifetime, sql: []const u8) void {
        _ = self.matchingScope() orelse return;
        self.key = fingerprintBackend(sql, self.backend);
    }

    pub fn now(self: *Lifetime) ?i96 {
        const scope = self.matchingScope() orelse return null;
        return std.Io.Timestamp.now(scope.store.?.io, .awake).nanoseconds;
    }

    /// Validate a buffered-only call without reading a clock.
    pub fn touch(self: *Lifetime) void {
        _ = self.matchingScope();
    }

    fn matchingScope(self: *Lifetime) ?*Scope {
        const active = current orelse {
            if (self.scope_id != 0) self.invalidated = true;
            self.scope_id = 0;
            return null;
        };
        if (self.scope_id == 0) return null;
        if (active.id != self.scope_id or active.store == null) {
            self.invalidated = true;
            self.scope_id = 0;
            return null;
        }
        return active;
    }

    pub fn observeCall(self: *Lifetime, start: ?i96, end: ?i96) void {
        _ = self.matchingScope() orelse return;
        if (start) |s| if (end) |e| {
            self.calls_ns +|= elapsed(s, e);
        };
    }

    pub fn afterCall(self: *Lifetime, start: ?i96) void {
        self.observeCall(start, self.now());
    }

    pub fn finish(self: *Lifetime, finalize_start: ?i96) void {
        self.finishAt(finalize_start, self.now());
    }

    fn finishAt(self: *Lifetime, finalize_start: ?i96, ended: ?i96) void {
        defer self.* = .{};
        const active = self.matchingScope() orelse return;
        const end = ended orelse return;
        self.observeCall(finalize_start, end);
        active.store.?.recordLifetime(active, self.backend, self.key, elapsed(self.started, end), self.calls_ns);
    }
};

/// Structural fingerprint, NOT a hash of raw SQL. Literal contents, parameter
/// names, identifiers and comments never reach the hash. Only a small keyword
/// allowlist and punctuation survive. Unsupported/oversized input is omitted.
pub fn fingerprint(sql: []const u8) ?u64 {
    return fingerprintBackend(sql, .sqlite);
}

pub fn fingerprintBackend(sql: []const u8, backend: Backend) ?u64 {
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
            if (backend == .postgres and std.mem.indexOf(u8, sql[i + 2 ..][0..end], "/*") != null) return null;
            i += end + 4;
            continue;
        }
        if (ch == '\'' or ch == '"' or ch == '`' or ch == '[') {
            if (backend == .postgres and (ch == '`' or ch == '[')) return null;
            const end_ch: u8 = if (ch == '[') ']' else ch;
            i += 1;
            var closed = false;
            while (i < sql.len) {
                // PostgreSQL escape-string settings can change quote handling.
                // Omit backslashes rather than interpret literal contents.
                if (backend == .postgres and sql[i] == '\\') return null;
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
        if (backend == .postgres and ch == '$') {
            i += 1;
            const start = i;
            while (i < sql.len and std.ascii.isDigit(sql[i])) : (i += 1) {}
            if (i == start or (i < sql.len and (std.ascii.isAlphabetic(sql[i]) or sql[i] == '_' or sql[i] == '$'))) return null;
            hash.update("V ");
            continue;
        }
        if (backend == .postgres and ch == ':' and i + 1 < sql.len and sql[i + 1] == ':') {
            hash.update(":: ");
            i += 2;
            continue;
        }
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
            // These prefixes introduce alternate quoting/escape grammars.
            if (backend == .postgres and (std.ascii.eqlIgnoreCase(word, "E") or std.ascii.eqlIgnoreCase(word, "U")) and
                i < sql.len and (sql[i] == '\'' or sql[i] == '&')) return null;
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

test "PostgreSQL fingerprints accept positional binds and omit alternate literal grammars" {
    const a = fingerprintBackend("SELECT secret FROM accounts WHERE email=$1::text", .postgres);
    const b = fingerprintBackend("select other FROM customers WHERE name=$99::varchar", .postgres);
    try std.testing.expect(a != null);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(fingerprintBackend("SELECT 'private SELECT'", .postgres), fingerprintBackend("SELECT 'private DELETE'", .postgres));
    for ([_][]const u8{ "SELECT $$private SELECT$$", "SELECT $tag$private DELETE$tag$", "SELECT E'private\\' SELECT'", "SELECT U&'private'", "SELECT 'private\\' DELETE'", "SELECT /* outer /* inner */ SELECT */ 1", "SELECT $name", "SELECT $1suffix" }) |sql| {
        try std.testing.expectEqual(null, fingerprintBackend(sql, .postgres));
    }
    try std.testing.expectEqual(null, fingerprint("SELECT $1::text"));
}

test "backend identity separates aggregates and repeat accounting under one route" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    var scope = Scope.init(store, "GET", "/mixed");
    scope.enter();
    defer scope.leave();
    store.record(&scope, .sqlite, 42, 10, false);
    store.record(&scope, .postgres, 42, 20, false);
    store.record(&scope, .postgres, 42, 30, true);
    store.recordLifetime(&scope, .postgres, 42, 100, 50);
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqual(@as(u64, 0), store.entries[0].repeated);
    try std.testing.expectEqual(@as(u64, 1), store.entries[1].repeated);
    try std.testing.expectEqual(@as(u64, 50), store.entries[1].total_ns);
    try std.testing.expectEqual(@as(u64, 1), store.entries[1].statements);
}

test "bounded aggregates repeats slow errors and nested scope restoration" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{ .max_entries = 1, .slow_ms = 1 });
    defer store.destroy();
    var outer = Scope.init(store, "GET", "/items/:id");
    outer.enter();
    defer outer.leave();
    store.record(&outer, .sqlite, 1, 2_000_000, false);
    store.record(&outer, .sqlite, 1, 1, true);
    store.record(&outer, .sqlite, 2, 1, false);
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
        fn begin(s: *Store, measurement: *Measurement, lifetime: *Lifetime) void {
            var scope = Scope.init(s, "GET", "/first/:id");
            scope.enter();
            defer scope.leave();
            _ = measurement.beforeKeyed(fingerprint("SELECT ?1"));
            lifetime.* = Lifetime.begin();
            lifetime.prepared("SELECT ?1");
        }
        fn finish(s: *Store, measurement: *Measurement, lifetime: *Lifetime) void {
            var scope = Scope.init(s, "GET", "/second/:id");
            scope.enter();
            defer scope.leave();
            measurement.finish();
            lifetime.finish(null);
        }
    };
    var measurement: Measurement = .{};
    var lifetime: Lifetime = .{};
    const first = try std.Thread.spawn(.{}, H.begin, .{ store, &measurement, &lifetime });
    first.join();
    const second = try std.Thread.spawn(.{}, H.finish, .{ store, &measurement, &lifetime });
    second.join();
    try std.testing.expectEqual(@as(usize, 0), store.count);
    try std.testing.expect(current == null);
}

test "lifetime separates measured calls and held intervals without changing executions" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    var scope = Scope.init(store, "GET", "/held");
    scope.enter();
    defer scope.leave();
    // Synthetic monotonic timestamps keep this partition test deterministic.
    var lifetime = Lifetime{ .scope_id = scope.id, .key = 1, .started = 1000 };
    lifetime.observeCall(1000, 1010); // prepare
    lifetime.observeCall(1200, 1210); // step
    lifetime.observeCall(1400, 1410); // reset
    lifetime.observeCall(1600, 1610); // second execution
    lifetime.finishAt(1800, 1810); // finalize
    const e = store.entries[0];
    try std.testing.expectEqual(@as(u64, 1), e.statements);
    try std.testing.expectEqual(@as(u64, 810), e.lifetime_ns);
    try std.testing.expectEqual(@as(u64, 810), e.max_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 50), e.calls_ns);
    try std.testing.expectEqual(@as(u64, 760), e.held_ns);
    try std.testing.expectEqual(@as(u64, 0), e.executions);
    try std.testing.expectEqual(@as(u64, 0), e.slow);
    try std.testing.expectEqual(@as(usize, 0), scope.seen_count);
    // Finishing twice cannot record the same statement again.
    lifetime.finishAt(1900, 1910);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].statements);
}

test "lifetime bounds cardinality and saturates elapsed durations and counters" {
    try std.testing.expectEqual(@as(u64, 0), elapsed(20, 10));
    try std.testing.expectEqual(std.math.maxInt(u64), elapsed(std.math.minInt(i96), std.math.maxInt(i96)));
    const store = try Store.create(std.testing.allocator, std.testing.io, .{ .max_entries = 1 });
    defer store.destroy();
    var scope = Scope.init(store, "GET", "/bounded");
    scope.enter();
    defer scope.leave();
    store.recordLifetime(&scope, .sqlite, 1, std.math.maxInt(u64), std.math.maxInt(u64));
    store.entries[0].statements = std.math.maxInt(u64);
    store.entries[0].held_ns = std.math.maxInt(u64);
    store.recordLifetime(&scope, .sqlite, 1, 20, 10);
    try std.testing.expectEqual(std.math.maxInt(u64), store.entries[0].statements);
    try std.testing.expectEqual(std.math.maxInt(u64), store.entries[0].lifetime_ns);
    try std.testing.expectEqual(std.math.maxInt(u64), store.entries[0].calls_ns);
    try std.testing.expectEqual(std.math.maxInt(u64), store.entries[0].held_ns);
    store.recordLifetime(&scope, .sqlite, 2, 20, 10);
    store.recordLifetime(&scope, .sqlite, null, 20, 10);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(@as(u64, 2), store.dropped_statements);
    try std.testing.expectEqual(@as(u64, 0), store.dropped);
}

test "lifetime crossing scopes is omitted even when control returns to its origin" {
    const store = try Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    var outer = Scope.init(store, "GET", "/outer");
    outer.enter();
    defer outer.leave();
    var lifetime = Lifetime.begin();
    lifetime.prepared("SELECT 1");
    var inner = Scope.init(store, "GET", "/inner");
    inner.enter();
    try std.testing.expectEqual(null, lifetime.now());
    inner.leave();
    lifetime.finish(null);
    try std.testing.expectEqual(@as(usize, 0), store.count);
}
