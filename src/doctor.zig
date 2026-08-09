//! The `doctor` check registry: a frozen set of preflight checks, and the pure
//! function that evaluates them against a `Facts` snapshot.
//!
//! This file is deliberately I/O-free. Gathering `Facts` (reading env vars,
//! stat-ing the JWT secret file, opening the DB, probing the data dir) is
//! `doctor_run.zig`'s job; every severity rule here is testable with a plain
//! struct literal, no server, no DB, no filesystem.
//!
//! The check id set is FROZEN and append-only — see `doctor_ids.txt` and
//! `scripts/check-doctor-ledger.sh` (Task 10). `Finding.check` and the
//! severity spellings are the NDJSON wire contract; `Finding.message` is not.

const std = @import("std");
const config = @import("config.zig");
const serve_session = @import("serve_session.zig");

pub const Severity = enum { ok, info, warn, err, skipped };

/// One emitted finding. Field order = declaration order = the NDJSON contract.
/// `check` and the severity spellings are FROZEN; `message` is not a contract.
pub const Finding = struct {
    check: []const u8,
    severity: []const u8, // "ok" | "info" | "warn" | "error" | "skipped"
    subject: ?[]const u8, // e.g. "posts.createRule"; null when not applicable
    message: []const u8,
};

pub const RuleFact = struct {
    collection: []const u8,
    /// "list" | "view" | "create" | "update" | "delete"
    op: []const u8,
    /// True for a write op — the half that escalates under --production.
    write: bool,
};

/// Everything the checks read. Gathered by doctor_run.zig; a plain struct here
/// so every severity rule is testable without a server, a DB, or an env.
pub const Facts = struct {
    jwt_secret_env_len: usize, // 0 = unset
    jwt_secret_file_len: usize, // 0 = absent/empty
    jwt_secret_file_mode: ?u16, // null = unknown (stat failed / absent)
    cookie_secure: bool,
    http_host: []const u8,
    trust_proxy: bool,
    public_url: []const u8,
    sendmail_command: []const u8,
    smtp_host: []const u8,
    smtp_username: []const u8,
    smtp_tls_resolved: config.SmtpTls,
    data_dir: []const u8,
    data_dir_writable: bool,
    data_dir_error: ?[]const u8, // @errorName when not writable
    db_reachable: bool, // false => the two DB checks skip
    db_error: ?[]const u8,
    rules: []const RuleFact, // only the @public ones
    migrations_pending: usize,
    migrations_orphaned: usize,
    legacy_password_hashes: usize, // auth records still on a `$zblegacy$` hash
};

pub const Summary = struct {
    summary: bool = true, // the NDJSON discriminator
    production: bool,
    checks: usize,
    errors: usize,
    warnings: usize,
    skipped: usize,
};

pub const min_jwt_secret_len = 32; // mirrors framework.min_jwt_secret_len

/// The frozen check-id ledger, in emission order. Kept adjacent to `evaluate`
/// so a ledger-test failure points somewhere useful. Append-only: see
/// `doctor_ids.txt` and `scripts/check-doctor-ledger.sh`.
pub const check_ids: []const []const u8 = &[_][]const u8{
    "jwt-secret-persisted",
    "public-rules-enumerated",
    "insecure-cookies-off",
    "host-binding",
    "trust-proxy-consistency",
    "mailer-configured",
    "migrations-applied",
    "data-dir-writable",
    "legacy-password-hashes",
};

/// Map the internal enum to its FROZEN wire spelling. `err` -> `"error"` is
/// the one case where the enum tag and the wire spelling differ (`err` is
/// close to a Zig keyword footgun; the wire contract says "error").
fn sevName(s: Severity) []const u8 {
    return switch (s) {
        .ok => "ok",
        .info => "info",
        .warn => "warn",
        .err => "error",
        .skipped => "skipped",
    };
}

fn append(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Finding),
    check: []const u8,
    severity: Severity,
    subject: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(arena, fmt, args);
    try out.append(arena, .{
        .check = check,
        .severity = sevName(severity),
        .subject = subject,
        .message = message,
    });
}

fn isWildcardHost(host: []const u8) bool {
    // Reuse the exact three spellings serve_session.probeHost already knows
    // how to redirect away from — do not maintain a second predicate.
    // probeHost substitutes a dialable loopback address ONLY for those three
    // wildcard spellings, and returns every other host (including the real
    // loopback ones) unchanged, so "did it change?" is the wildcard test.
    return !std.mem.eql(u8, serve_session.probeHost(host), host);
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "localhost");
}

fn checkJwtSecret(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "jwt-secret-persisted";

    // A provided-but-short secret is fatal in BOTH modes: the server refuses
    // to start on it, so a warning would be a lie.
    if (f.jwt_secret_env_len != 0 and f.jwt_secret_env_len < min_jwt_secret_len) {
        return append(arena, out, id, .err, null, "ZIGBASE_JWT_SECRET is {d} bytes, below the minimum of {d}", .{ f.jwt_secret_env_len, min_jwt_secret_len });
    }
    if (f.jwt_secret_env_len >= min_jwt_secret_len) {
        return append(arena, out, id, .ok, null, "JWT secret supplied via ZIGBASE_JWT_SECRET", .{});
    }

    // No usable env secret. Fall back to the persisted file.
    if (f.jwt_secret_file_len == 0) {
        // Nothing set and nothing persisted: fine locally (auto-generated at
        // startup), fatal in production (every restart would invalidate
        // every issued token).
        return append(arena, out, id, if (production) .err else .warn, null, "no ZIGBASE_JWT_SECRET and no persisted secret file; a fresh one is generated on every restart", .{});
    }

    // Persisted and non-empty. Its length is assumed valid (the server would
    // not have started otherwise); the remaining question is file mode.
    const mode_ok = f.jwt_secret_file_mode != null and f.jwt_secret_file_mode.? == 0o600;
    if (mode_ok) {
        return append(arena, out, id, .ok, null, "JWT secret persisted with mode 0600", .{});
    }
    return append(arena, out, id, if (production) .err else .warn, null, "persisted JWT secret file is not mode 0600 ({?o})", .{f.jwt_secret_file_mode});
}

fn checkPublicRules(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "public-rules-enumerated";
    if (!f.db_reachable) {
        return append(arena, out, id, .skipped, null, "database unreachable: {s}", .{f.db_error orelse "unknown"});
    }
    if (f.rules.len == 0) {
        return append(arena, out, id, .ok, null, "no @public rules", .{});
    }
    for (f.rules) |r| {
        // Read rules (list/view) stay a warning in every mode: @public on a
        // read rule is a legitimate, common, deliberate choice (a public
        // blog). Write rules (create/update/delete) escalate under
        // --production: an anonymously writable collection almost never is.
        const sev: Severity = if (production and r.write) .err else .warn;
        const subject = try std.fmt.allocPrint(arena, "{s}.{s}Rule", .{ r.collection, r.op });
        try append(arena, out, id, sev, subject, "collection '{s}' is @public for {s}", .{ r.collection, r.op });
    }
}

fn checkInsecureCookies(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "insecure-cookies-off";
    if (f.cookie_secure) {
        return append(arena, out, id, .ok, null, "cookies are Secure", .{});
    }
    return append(arena, out, id, if (production) .err else .warn, null, "cookies are not Secure (ZIGBASE_COOKIE_SECURE=false)", .{});
}

fn checkHostBinding(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "host-binding";
    // Symmetric: each mode warns about the value that is wrong FOR THAT MODE.
    // A wildcard bind in local dev is surprising; a loopback bind in
    // production usually means the service is unreachable. A specific
    // interface address is a deliberate choice in either mode.
    if (isWildcardHost(f.http_host)) {
        return append(arena, out, id, if (production) .ok else .warn, null, "http_host '{s}' is a wildcard bind", .{f.http_host});
    }
    if (isLoopbackHost(f.http_host)) {
        return append(arena, out, id, if (production) .warn else .ok, null, "http_host '{s}' is loopback-only", .{f.http_host});
    }
    return append(arena, out, id, .ok, null, "http_host '{s}' is a specific interface address", .{f.http_host});
}

fn checkTrustProxyConsistency(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "trust-proxy-consistency";

    // Trusting client-settable forwarding headers while directly reachable
    // (wildcard bind) is a rate-limit / IP-auth bypass.
    if (f.trust_proxy and isWildcardHost(f.http_host)) {
        return append(arena, out, id, if (production) .err else .warn, null, "trust_proxy is on with a wildcard bind ('{s}') — forwarding headers are attacker-controlled unless a proxy is guaranteed in front", .{f.http_host});
    }

    // The mirror image: an https public URL on a loopback bind means a TLS
    // proxy is in front, but every client will key on the proxy's IP unless
    // trust_proxy is also on.
    if (!f.trust_proxy and std.mem.startsWith(u8, f.public_url, "https://") and isLoopbackHost(f.http_host)) {
        return append(arena, out, id, .warn, null, "public_url is https but http_host ('{s}') is loopback and trust_proxy is off — forwarded client IPs will all read as the proxy", .{f.http_host});
    }

    return append(arena, out, id, .ok, null, "trust_proxy is consistent with http_host and public_url", .{});
}

fn checkMailerConfigured(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    const id = "mailer-configured";
    const has_sendmail = f.sendmail_command.len != 0;
    const has_smtp = f.smtp_host.len != 0;

    if (!has_sendmail and !has_smtp) {
        return append(arena, out, id, if (production) .err else .warn, null, "no mailer configured (no sendmail_command, no smtp_host) — falls back to the Log mailer", .{});
    }

    // SMTP AUTH over a connection that resolves to no transport security
    // sends the password in the clear.
    if (has_smtp and f.smtp_username.len != 0 and f.smtp_tls_resolved == .none) {
        return append(arena, out, id, if (production) .err else .warn, null, "SMTP credentials configured but transport security resolves to none — password sent in the clear", .{});
    }

    return append(arena, out, id, .ok, null, "mailer configured", .{});
}

fn checkMigrationsApplied(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    _ = production;
    const id = "migrations-applied";
    if (!f.db_reachable) {
        return append(arena, out, id, .skipped, null, "database unreachable: {s}", .{f.db_error orelse "unknown"});
    }
    if (f.migrations_pending != 0) {
        return append(arena, out, id, .err, null, "{d} declared migration(s) pending", .{f.migrations_pending});
    }
    if (f.migrations_orphaned != 0) {
        return append(arena, out, id, .warn, null, "{d} applied migration(s) no longer declared in source (orphaned)", .{f.migrations_orphaned});
    }
    return append(arena, out, id, .ok, null, "all declared migrations applied", .{});
}

fn checkDataDirWritable(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    _ = production;
    const id = "data-dir-writable";
    if (f.data_dir_writable) {
        return append(arena, out, id, .ok, null, "data dir '{s}' is writable", .{f.data_dir});
    }
    return append(arena, out, id, .err, null, "data dir '{s}' is not writable: {s}", .{ f.data_dir, f.data_dir_error orelse "unknown" });
}

/// Legacy password hashes are a normal, self-healing transitional state during
/// a hashing-scheme migration: each one re-hashes to the current scheme on its
/// account's next successful login, so the count falls on its own as users
/// sign in. This NEVER escalates under --production — unlike the other
/// DB-backed checks, a nonzero count here is not a misconfiguration, it is
/// progress-in-flight the operator watches trend toward zero.
fn checkLegacyPasswordHashes(arena: std.mem.Allocator, f: Facts, production: bool, out: *std.ArrayListUnmanaged(Finding)) !void {
    _ = production;
    const id = "legacy-password-hashes";
    if (!f.db_reachable) {
        return append(arena, out, id, .skipped, null, "database unreachable: {s}", .{f.db_error orelse "unknown"});
    }
    if (f.legacy_password_hashes == 0) {
        return append(arena, out, id, .ok, null, "no legacy password hashes", .{});
    }
    return append(arena, out, id, .warn, null, "{d} auth record(s) still carry a legacy password hash; each re-hashes automatically on its next successful login, so this count falls as users sign in", .{f.legacy_password_hashes});
}

/// Contract 4 (arena-scoped): findings and their messages are allocated on
/// `arena` and never freed. Emission order is ledger order.
pub fn evaluate(arena: std.mem.Allocator, f: Facts, production: bool) error{OutOfMemory}![]const Finding {
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    try checkJwtSecret(arena, f, production, &out);
    try checkPublicRules(arena, f, production, &out);
    try checkInsecureCookies(arena, f, production, &out);
    try checkHostBinding(arena, f, production, &out);
    try checkTrustProxyConsistency(arena, f, production, &out);
    try checkMailerConfigured(arena, f, production, &out);
    try checkMigrationsApplied(arena, f, production, &out);
    try checkDataDirWritable(arena, f, production, &out);
    try checkLegacyPasswordHashes(arena, f, production, &out);
    return out.toOwnedSlice(arena);
}

pub fn summarize(findings: []const Finding, production: bool) Summary {
    var s: Summary = .{ .production = production, .checks = findings.len, .errors = 0, .warnings = 0, .skipped = 0 };
    for (findings) |f| {
        if (std.mem.eql(u8, f.severity, "error")) s.errors += 1;
        if (std.mem.eql(u8, f.severity, "warn")) s.warnings += 1;
        if (std.mem.eql(u8, f.severity, "skipped")) s.skipped += 1;
    }
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A baseline `Facts` that produces an all-`ok` report, so each test below can
/// change exactly the one thing it is about. If a NEW check is added and this
/// baseline stops being clean, the first test will say so.
fn okFacts() Facts {
    return .{
        .jwt_secret_env_len = 64,
        .jwt_secret_file_len = 0,
        .jwt_secret_file_mode = null,
        .cookie_secure = true,
        .http_host = "127.0.0.1",
        .trust_proxy = false,
        .public_url = "",
        .sendmail_command = "",
        .smtp_host = "smtp.example.com",
        .smtp_username = "",
        .smtp_tls_resolved = .starttls,
        .data_dir = "/srv/zb",
        .data_dir_writable = true,
        .data_dir_error = null,
        .db_reachable = true,
        .db_error = null,
        .rules = &.{},
        .migrations_pending = 0,
        .migrations_orphaned = 0,
        .legacy_password_hashes = 0,
    };
}

fn findingFor(findings: []const Finding, id: []const u8) ?Finding {
    for (findings) |f| if (std.mem.eql(u8, f.check, id)) return f;
    return null;
}

fn severitiesFor(arena: std.mem.Allocator, findings: []const Finding, id: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (findings) |f| if (std.mem.eql(u8, f.check, id)) try out.append(arena, f.severity);
    return out.toOwnedSlice(arena);
}

test "doctor: the ledger and the registry are the same set, in the same order" {
    // Append-only is enforced against git by scripts/check-doctor-ledger.sh;
    // this test enforces that the file and the code never diverge at all.
    const ledger = @embedFile("doctor_ids.txt");
    var it = std.mem.tokenizeScalar(u8, ledger, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        try std.testing.expect(i < check_ids.len);
        try std.testing.expectEqualStrings(check_ids[i], line);
    }
    try std.testing.expectEqual(check_ids.len, i);
}

test "doctor: a clean deployment reports ok for every check, in ledger order" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const findings = try evaluate(arena, okFacts(), false);
    try std.testing.expectEqual(check_ids.len, findings.len);
    for (findings, 0..) |f, i| {
        try std.testing.expectEqualStrings(check_ids[i], f.check);
        try std.testing.expectEqualStrings("ok", f.severity);
    }
    const s = summarize(findings, false);
    try std.testing.expectEqual(@as(usize, 0), s.errors);
    try std.testing.expectEqual(@as(usize, 0), s.warnings);
}

test "doctor: jwt secret — short env errors, absent warns, production escalates, bad mode flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A provided-but-short secret is fatal in BOTH modes: the server refuses to
    // start on it, so a warning would be a lie.
    var f = okFacts();
    f.jwt_secret_env_len = 8;
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, false), "jwt-secret-persisted").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "jwt-secret-persisted").?.severity);

    // Nothing set and nothing persisted: fine locally, fatal in production
    // (every restart would invalidate every issued token).
    f = okFacts();
    f.jwt_secret_env_len = 0;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "jwt-secret-persisted").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "jwt-secret-persisted").?.severity);

    // Persisted and long enough: ok — but a group/world-readable mode is not.
    f = okFacts();
    f.jwt_secret_env_len = 0;
    f.jwt_secret_file_len = 64;
    f.jwt_secret_file_mode = 0o600;
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, true), "jwt-secret-persisted").?.severity);
    f.jwt_secret_file_mode = 0o644;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "jwt-secret-persisted").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "jwt-secret-persisted").?.severity);
}

test "doctor: public rules are enumerated one finding each, writes escalate in production" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = okFacts();
    f.rules = &.{
        .{ .collection = "posts", .op = "list", .write = false },
        .{ .collection = "posts", .op = "create", .write = true },
    };
    const dev = try evaluate(arena, f, false);
    const dev_sev = try severitiesFor(arena, dev, "public-rules-enumerated");
    try std.testing.expectEqual(@as(usize, 2), dev_sev.len);
    try std.testing.expectEqualStrings("warn", dev_sev[0]);
    try std.testing.expectEqualStrings("warn", dev_sev[1]);

    // Every finding names WHICH rule, so a ship gate can account for each one.
    var saw_subject = false;
    for (dev) |x| if (std.mem.eql(u8, x.check, "public-rules-enumerated") and x.subject != null) {
        if (std.mem.eql(u8, x.subject.?, "posts.createRule")) saw_subject = true;
    };
    try std.testing.expect(saw_subject);

    // In production a read rule stays a warning; an anonymously WRITABLE
    // collection is an error.
    const prod_sev = try severitiesFor(arena, try evaluate(arena, f, true), "public-rules-enumerated");
    try std.testing.expectEqualStrings("warn", prod_sev[0]);
    try std.testing.expectEqualStrings("error", prod_sev[1]);
}

test "doctor: cookie, host-binding, and trust-proxy severities are mode-dependent" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = okFacts();
    f.cookie_secure = false;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "insecure-cookies-off").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "insecure-cookies-off").?.severity);

    // host-binding is symmetric: each mode warns about the value that is wrong
    // FOR THAT MODE.
    f = okFacts();
    f.http_host = "0.0.0.0";
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "host-binding").?.severity);
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, true), "host-binding").?.severity);
    f.http_host = "127.0.0.1";
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, false), "host-binding").?.severity);
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, true), "host-binding").?.severity);
    // A specific interface address is a deliberate choice in either mode.
    f.http_host = "10.0.1.7";
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, false), "host-binding").?.severity);
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, true), "host-binding").?.severity);

    // Trusting client-settable forwarding headers while directly reachable is
    // a rate-limit bypass.
    f = okFacts();
    f.trust_proxy = true;
    f.http_host = "0.0.0.0";
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "trust-proxy-consistency").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "trust-proxy-consistency").?.severity);

    // The mirror image: an https public URL on a loopback bind means a TLS
    // proxy is in front, but every client will key on the proxy's IP.
    f = okFacts();
    f.public_url = "https://app.example.com";
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "trust-proxy-consistency").?.severity);
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, true), "trust-proxy-consistency").?.severity);
}

test "doctor: mailer — unconfigured and cleartext-credentialed SMTP both flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = okFacts();
    f.smtp_host = "";
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "mailer-configured").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "mailer-configured").?.severity);

    // A local MTA is a real mailer.
    f.sendmail_command = "sendmail -t -i";
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, true), "mailer-configured").?.severity);

    // SMTP AUTH over a connection that resolves to no transport security sends
    // the password in the clear.
    f = okFacts();
    f.smtp_username = "apikey";
    f.smtp_tls_resolved = .none;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "mailer-configured").?.severity);
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, true), "mailer-configured").?.severity);
}

test "doctor: migrations and data dir; an unreachable DB skips its dependent checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = okFacts();
    f.migrations_pending = 2;
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, false), "migrations-applied").?.severity);
    f = okFacts();
    f.migrations_orphaned = 1;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "migrations-applied").?.severity);

    f = okFacts();
    f.data_dir_writable = false;
    f.data_dir_error = "AccessDenied";
    try std.testing.expectEqualStrings("error", findingFor(try evaluate(arena, f, false), "data-dir-writable").?.severity);

    // A DB we could not open makes the three DB-backed checks SKIPPED, not ok
    // and not error — claiming "no @public rules" when we could not look would
    // be the worst possible answer for a ship gate.
    f = okFacts();
    f.db_reachable = false;
    f.db_error = "FileNotFound";
    const skipped = try evaluate(arena, f, true);
    try std.testing.expectEqualStrings("skipped", findingFor(skipped, "public-rules-enumerated").?.severity);
    try std.testing.expectEqualStrings("skipped", findingFor(skipped, "migrations-applied").?.severity);
    try std.testing.expectEqualStrings("skipped", findingFor(skipped, "legacy-password-hashes").?.severity);
    const s = summarize(skipped, true);
    try std.testing.expectEqual(@as(usize, 3), s.skipped);
    try std.testing.expectEqual(@as(usize, 0), s.errors);
}

test "doctor: legacy password hashes warn in both modes (never escalate), unreachable db skips" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = okFacts();
    f.legacy_password_hashes = 0;
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, false), "legacy-password-hashes").?.severity);
    try std.testing.expectEqualStrings("ok", findingFor(try evaluate(arena, f, true), "legacy-password-hashes").?.severity);

    // Legacy hashes are a normal, self-healing transitional state (each one
    // re-hashes on its account's next successful login) — this is the
    // judgment call worth locking: it must NOT escalate under --production
    // the way the other DB-backed checks do.
    f = okFacts();
    f.legacy_password_hashes = 3;
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, false), "legacy-password-hashes").?.severity);
    try std.testing.expectEqualStrings("warn", findingFor(try evaluate(arena, f, true), "legacy-password-hashes").?.severity);

    f = okFacts();
    f.db_reachable = false;
    f.db_error = "FileNotFound";
    try std.testing.expectEqualStrings("skipped", findingFor(try evaluate(arena, f, false), "legacy-password-hashes").?.severity);
}
