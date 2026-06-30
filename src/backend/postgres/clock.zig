//! Dev-only: make the *Postgres* SQL clock honor the frozen test clock (`clock.frozenUnix()`).
//! This is the Postgres analog of the two SQLite-only shims `src/clock_sql.zig` (#84, shadows
//! the SQL date/time *functions*) and `src/clock_vfs.zig` (#97, a SQLite VFS overriding
//! `xCurrentTime`). PostgreSQL is a remote server — there is no in-process app-function
//! registration and no VFS hook — so neither SQLite mechanism has a Postgres equivalent.
//! Instead we reproduce their EFFECT (a frozen SQL clock under `ZIGBASE_FAKE_NOW`) with a
//! **session-level `now()` override** installed on every connection.
//!
//! ## How
//! At connection-open time, when a freeze is active, we run three statements on the fresh
//! connection (issue #159, PR-7):
//!   1. `CREATE SCHEMA IF NOT EXISTS zigbase_frozen;`
//!   2. `CREATE OR REPLACE FUNCTION zigbase_frozen.now() RETURNS timestamptz … to_timestamp(<frozen>)`
//!   3. append `zigbase_frozen, pg_catalog` to the session `search_path` (after the existing
//!      schemas), with `pg_catalog` placed *explicitly last*.
//! Function name resolution in Postgres searches `pg_catalog` IMPLICITLY FIRST unless it is
//! named explicitly in `search_path` — so the only way to shadow the built-in `pg_catalog.now()`
//! is to list `pg_catalog` after our schema. We append `zigbase_frozen, pg_catalog` to the
//! *existing* path (via `set_config` + `current_setting`), so unqualified `now()` resolves to the
//! frozen wrapper (found before the now-explicit, last `pg_catalog`) while table/type resolution
//! (and every other catalog function) is unchanged — crucially, `zigbase_frozen` is appended
//! AFTER the pre-existing schemas, so unqualified `CREATE TABLE` still targets the original first
//! schema (e.g. `public`), never `zigbase_frozen`.
//!
//! Because the dialect emits `now()` for every framework timestamp (`Dialect.nowExpr` /
//! `nowIso8601Expr` / `nowTextExpr`, used by record autodate stamping, KV upserts, the
//! `_migrations`/`_collections` metadata, …) AND a consumer's raw SQL `now()` resolves through
//! the same search_path, this single override freezes BOTH the framework's own timestamps and a
//! consumer's raw `now()` — the union of what `clock_sql` (#84) and the framework path cover on
//! SQLite. (`CURRENT_TIMESTAMP` is a reserved keyword, not a function call, so it is NOT covered
//! here — ZigBase never emits it; autodate columns are stamped via `now()`-based expressions.)
//!
//! ## Production gate (hard requirement)
//! `install` begins with `if (comptime !clock.enabled) return;`. `clock.enabled` is the comptime
//! `dev_clock` build option (off in every release build), so on a prod build the entire body is
//! comptime-dead and eliminated: no schema, no function, no search_path change — the connection
//! is byte-for-byte unchanged and `ZIGBASE_FAKE_NOW` is never consulted. Even on a dev build, the
//! override is installed ONLY while a freeze is actually active (`frozenUnix()` non-null);
//! otherwise the connection keeps the genuine wall-clock `now()`.

const std = @import("std");
const clock = @import("../../clock.zig");
const conn_mod = @import("conn.zig");

/// The schema that holds the frozen `now()` wrapper. Process-stable; created idempotently on
/// each freezing connection.
pub const schema_name = "zigbase_frozen";

/// Install the session-level frozen-`now()` override on a freshly connected `conn`. No-op
/// (comptime-eliminated) on a prod build, and a no-op at runtime when no freeze is active —
/// the connection then keeps the real `now()`. Best-effort: a failure (e.g. insufficient
/// privilege to `CREATE SCHEMA`) is logged and the connection degrades to the genuine wall
/// clock rather than failing the open.
pub fn install(conn: *conn_mod.Conn) void {
    if (comptime !clock.enabled) return;
    const frozen = clock.frozenUnix() orelse return; // no freeze → genuine now()

    var buf: [512]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf,
        \\CREATE SCHEMA IF NOT EXISTS {[schema]s};
        \\CREATE OR REPLACE FUNCTION {[schema]s}.now() RETURNS timestamptz LANGUAGE sql STABLE AS 'SELECT to_timestamp({[unix]d}::double precision)';
        \\SELECT set_config('search_path', current_setting('search_path') || ', {[schema]s}, pg_catalog', false);
    , .{ .schema = schema_name, .unix = frozen }) catch {
        std.log.warn("clock_pg: could not format frozen-now() install SQL; Postgres SQL clock NOT frozen", .{});
        return;
    };

    conn.simpleExec(sql) catch |e| {
        std.log.warn("clock_pg: failed to install frozen now() override ({s}); Postgres SQL clock NOT frozen on this connection: {s}", .{ @errorName(e), conn.errMsg() });
    };
}

// ---------------------------------------------------------------------------
// Tests — exercise the override through a real Postgres connection. They prove PR-7: the SQL
// `now()` the dialect emits (and a consumer's raw `now()`) resolve to the frozen instant when a
// freeze is active, track the wall clock otherwise, and stay wall-clock on a prod build.
//
// They run only under `-Dpostgres=true` and require a reachable PostgreSQL (mirrors
// crud_tests.zig). A connectivity/auth failure SKIPS so the suite still runs where no PG exists.
// ---------------------------------------------------------------------------
const dialect_mod = @import("../../sql/dialect.zig");

const frozen_iso = "2029-03-07T16:00:00Z";
const frozen_unix: i64 = 1867593600; // = datetime.parse(frozen_iso)

const default_url = "postgres://zbpg:zbpg_secret_pw@[::1]:5432/zbpgtest?sslmode=require";

fn getEnv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > key.len and std.mem.startsWith(u8, e, key) and e[key.len] == '=')
            return e[key.len + 1 ..];
    }
    return null;
}

fn testUrl() []const u8 {
    return getEnv("ZIGBASE_PG_TEST_URL") orelse default_url;
}

/// Open a raw `Conn`, or null to signal "no reachable PG → skip" (only a connect failure skips).
fn connectOrSkip(a: std.mem.Allocator, io: std.Io) !?*conn_mod.Conn {
    const connstr = @import("connstr.zig");
    var cfg = connstr.parse(a, testUrl()) catch return null;
    defer cfg.deinit();
    return conn_mod.Conn.connect(a, io, cfg) catch null;
}

fn scalarText(a: std.mem.Allocator, conn: *conn_mod.Conn, sql: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const res = try conn.execExtended(arena.allocator(), sql, &.{});
    try std.testing.expect(res.rows.len >= 1);
    return a.dupe(u8, res.rows[0][0] orelse "");
}

test "frozen: Postgres now()/nowIso8601 resolve to the frozen instant (dev build + live PG)" {
    if (!clock.enabled) return error.SkipZigTest;

    const io = std.testing.io;
    const a = std.testing.allocator;

    clock.setForTest(frozen_unix);
    defer clock.resetForTest();

    // The override is installed at connect time (reads frozenUnix()), so the freeze must be set
    // BEFORE the connection is opened — exactly as the server installs it after `clock.install`.
    const conn = (try connectOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn.deinit();
    install(conn);

    // The exact ISO-8601 expression `Dialect.postgres.nowIso8601Expr()` emits for autodate
    // columns must now reflect the frozen instant.
    const iso_expr = dialect_mod.Dialect.postgres.nowIso8601Expr();
    var qbuf: [256]u8 = undefined;
    const q = try std.fmt.bufPrint(&qbuf, "SELECT {s}", .{iso_expr});
    const iso = try scalarText(a, conn, q);
    defer a.free(iso);
    try std.testing.expectEqualStrings(frozen_iso, iso);

    // A consumer's raw now() (cast to text via the same ISO shape) is frozen too.
    const raw = try scalarText(a, conn, "SELECT to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')");
    defer a.free(raw);
    try std.testing.expectEqualStrings(frozen_iso, raw);
}

test "frozen: an autodate-style INSERT stamps the frozen instant on Postgres (dev build + live PG)" {
    if (!clock.enabled) return error.SkipZigTest;

    const io = std.testing.io;
    const a = std.testing.allocator;

    clock.setForTest(frozen_unix);
    defer clock.resetForTest();

    const conn = (try connectOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn.deinit();
    install(conn); // server-faithful: the ONLY search_path mutation is the one install() makes.

    // Guard the ordering bug: `zigbase_frozen` must be appended AFTER the existing schemas, so an
    // unqualified CREATE TABLE still targets the original first schema (e.g. `public`) — never the
    // frozen-clock schema. `current_schemas(false)` is the resolved, non-implicit path in order.
    const first_schema = try scalarText(a, conn, "SELECT (current_schemas(false))[1]");
    defer a.free(first_schema);
    try std.testing.expect(!std.mem.eql(u8, first_schema, schema_name));

    // A throwaway TEMP table with a TEXT timestamp column whose DEFAULT is exactly the expression
    // `records.zig` stamps an autodate field with on create (`nowIso8601Expr()`). The DEFAULT's
    // `now()` resolves through the install()-mutated search_path to the frozen wrapper. TEMP keeps
    // it session-local (no shared-schema pollution) while exercising the real now() resolution.
    const iso_expr = dialect_mod.Dialect.postgres.nowIso8601Expr();
    var cbuf: [320]u8 = undefined;
    const create_sql = try std.fmt.bufPrintZ(&cbuf,
        \\CREATE TEMP TABLE t (id TEXT PRIMARY KEY, created TEXT DEFAULT {s});
    , .{iso_expr});
    try conn.simpleExec(create_sql);
    try conn.simpleExec("INSERT INTO t (id) VALUES ('r1');");

    const created = try scalarText(a, conn, "SELECT created FROM t WHERE id='r1'");
    defer a.free(created);
    try std.testing.expectEqualStrings(frozen_iso, created);
}

test "no freeze: Postgres now() tracks the real wall clock (dev build + live PG)" {
    if (!clock.enabled) return error.SkipZigTest;

    const io = std.testing.io;
    const a = std.testing.allocator;

    clock.resetForTest(); // ensure no freeze
    const conn = (try connectOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn.deinit();
    install(conn); // no-op: no freeze active → genuine now()

    // unix epoch of now() must be a plausible recent wall-clock value, not the frozen instant.
    const secs_txt = try scalarText(a, conn, "SELECT floor(extract(epoch from now()))::bigint::text");
    defer a.free(secs_txt);
    const secs = try std.fmt.parseInt(i64, secs_txt, 10);
    try std.testing.expect(secs > 1577836800); // after 2020-01-01
    try std.testing.expect(secs != frozen_unix);
}
