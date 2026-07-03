//! Live TLS-verification tests (SP3 Theme A). They run only when CI provides the relevant
//! environment: `ZIGBASE_PG_TLS_CA=<path to the self-signed server.crt>` in the
//! `postgres-tls` job (whose cert carries `subjectAltName=DNS:localhost`), and
//! `ZIGBASE_PG_PLAINTEXT=1` in the no-server-TLS `postgres` job. Absent env -> SKIP,
//! so `zig build test -Dpostgres=true` stays runnable anywhere.

const std = @import("std");
const pg = @import("postgres.zig");
const pgtests = @import("tests.zig");

/// Rebuild a connection URL from the suite's base URL (`tests.zig#testUrl`) with an
/// overridden host and query string. CI credentials are plain ASCII, so no re-encoding
/// is needed (the base URL's user/password are spliced back VERBATIM, undecoded).
fn urlWith(a: std.mem.Allocator, host: []const u8, query: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    var cfg = try pg.connstr.parse(a, base);
    defer cfg.deinit();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    const userinfo = base[scheme_end..at]; // verbatim (still percent-encoded if it ever was)
    const bracketed = std.mem.indexOfScalar(u8, host, ':') != null; // IPv6 literal
    return std.fmt.allocPrint(a, "postgres://{s}@{s}{s}{s}:{d}/{s}{s}", .{
        userinfo,
        if (bracketed) "[" else "",
        host,
        if (bracketed) "]" else "",
        cfg.port,
        cfg.database,
        query,
    });
}

/// Connect at the Conn level (so the PRECISE ConnError is observable — Db.open flattens
/// to OpenFailed), mirroring Db.open's ephemeral-trust logic for verify modes.
fn connectUrl(a: std.mem.Allocator, io: std.Io, url: []const u8) !*pg.Conn {
    var cfg = try pg.connstr.parse(a, url);
    defer cfg.deinit();
    if (cfg.sslmode.verifiesCertificate()) {
        var trust = try pg.tls_trust.TlsTrust.init(a, io, &cfg);
        defer trust.deinit();
        return pg.Conn.connect(a, io, cfg, &trust);
    }
    return pg.Conn.connect(a, io, cfg, null);
}

test "pg tls: verify-full + sslrootcert + DNS host succeeds end-to-end" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const query = try std.fmt.allocPrint(a, "?sslmode=verify-full&sslrootcert={s}", .{ca});
    defer a.free(query);
    const url = try urlWith(a, "localhost", query);
    defer a.free(url);
    const conn = try connectUrl(a, std.testing.io, url);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg tls: verify-full with system roots rejects the self-signed server (CertUntrusted)" {
    _ = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "localhost", "?sslmode=verify-full");
    defer a.free(url);
    try std.testing.expectError(error.CertUntrusted, connectUrl(a, std.testing.io, url));
}

test "pg tls: verify-full via an IP-literal host fails hostname verification" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const query = try std.fmt.allocPrint(a, "?sslmode=verify-full&sslrootcert={s}", .{ca});
    defer a.free(query);
    const url = try urlWith(a, "127.0.0.1", query);
    defer a.free(url);
    try std.testing.expectError(error.CertHostnameMismatch, connectUrl(a, std.testing.io, url));
}

test "pg tls: the DEFAULT mode is verify-full — a bare URL fails vs self-signed, succeeds with the CA" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    // No sslmode at all -> the new default (verify-full) -> untrusted self-signed chain.
    const bare = try urlWith(a, "localhost", "");
    defer a.free(bare);
    try std.testing.expectError(error.CertUntrusted, connectUrl(a, std.testing.io, bare));
    // Same bare-mode URL + the CA -> the default verifies and connects. Pins the default.
    const query = try std.fmt.allocPrint(a, "?sslrootcert={s}", .{ca});
    defer a.free(query);
    const with_ca = try urlWith(a, "localhost", query);
    defer a.free(with_ca);
    const conn = try connectUrl(a, std.testing.io, with_ca);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg tls: sslmode=require opt-down still connects (encrypted, unverified)" {
    _ = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "127.0.0.1", "?sslmode=require");
    defer a.free(url);
    const conn = try connectUrl(a, std.testing.io, url);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg plaintext: the default mode refuses a no-TLS server with the actionable error" {
    // Set only in the `postgres` CI job (service container without server TLS).
    _ = pgtests.getEnv("ZIGBASE_PG_PLAINTEXT") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "127.0.0.1", ""); // no sslmode -> default verify-full
    defer a.free(url);
    try std.testing.expectError(error.TlsRequiredButRefused, connectUrl(a, std.testing.io, url));
}
