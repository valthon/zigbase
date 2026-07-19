//! Live SASLprep/SCRAM tests (SP3 Theme A item 2). Require a reachable PostgreSQL whose
//! host auth is scram-sha-256 (both CI jobs force it via POSTGRES_HOST_AUTH_METHOD /
//! --auth-host); the suite role creates throwaway login roles, so it needs CREATEROLE (CI's
//! is a superuser). Skips when EITHER precondition is missing — no reachable PG, or a suite
//! role without CREATEROLE. To run these locally against an unprivileged suite role, point
//! `ZIGBASE_PG_TEST_URL` at a privileged one, e.g.
//! `postgres://postgres:postgres@[::1]:5432/zbpgtest?sslmode=require`.

const std = @import("std");
const pg = @import("postgres.zig");
const pgtests = @import("tests.zig");

fn adminOrSkip(a: std.mem.Allocator, io: std.Io) !?pg.Db {
    var db = pg.Db.open(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => return null,
        else => return e,
    };
    // The fixtures below CREATE/DROP throwaway login roles, which needs CREATEROLE (CI's suite
    // role is a superuser). Probe that privilege HERE: `DROP ROLE IF EXISTS` on an absent role
    // is a no-op when permitted and "permission denied to drop role" otherwise, so it tests the
    // privilege without creating anything. Skipping keeps a perfectly valid server whose suite
    // role simply isn't privileged (a plain dev Postgres) from failing these tests with an
    // opaque ExecFailed out of the SETUP DDL — which reads like a SCRAM bug and is not one.
    db.exec("DROP ROLE IF EXISTS zb_sasl_privilege_probe;") catch {
        db.close();
        return null;
    };
    return db;
}

/// The suite URL with the userinfo swapped for `user:pass` (verbatim splice; the fixture
/// credentials below are chosen URL-safe — no ':' '@' '/' '%').
fn urlAs(a: std.mem.Allocator, user: []const u8, pass: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(a, "{s}{s}:{s}@{s}", .{ base[0..scheme_end], user, pass, base[at + 1 ..] });
}

test "pg scram: a non-ASCII already-NFC password authenticates end-to-end" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    try admin.exec("DROP ROLE IF EXISTS zb_sasl_nfc;");
    // NFC é/è/û are SASLprep-identity (QC=Yes, ccc=0): PG stores the same bytes we send.
    try admin.exec("CREATE ROLE zb_sasl_nfc LOGIN PASSWORD 'crème-brûlée';");
    defer admin.exec("DROP ROLE IF EXISTS zb_sasl_nfc;") catch {};

    const url = try urlAs(a, "zb_sasl_nfc", "crème-brûlée");
    defer a.free(url);
    var db = try pg.Db.open(a, io, url);
    defer db.close();
    var st = try db.prepare("SELECT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
}

test "pg scram: a needs-NFKC password fails with PasswordNeedsNormalization, not a raw auth failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    try admin.exec("DROP ROLE IF EXISTS zb_sasl_nfkc;");
    // U+00AA: PG's pg_saslprep normalizes it to 'a' in the stored verifier; our client
    // refuses to guess and errors BEFORE PBKDF2 with the actionable message.
    try admin.exec("CREATE ROLE zb_sasl_nfkc LOGIN PASSWORD 'x\u{00AA}y';");
    defer admin.exec("DROP ROLE IF EXISTS zb_sasl_nfkc;") catch {};

    const url = try urlAs(a, "zb_sasl_nfkc", "x\u{00AA}y");
    defer a.free(url);
    var cfg = try pg.connstr.parse(a, url);
    defer cfg.deinit();
    // Conn level, so the PRECISE error is observable (Db.open flattens to OpenFailed).
    // Non-verifying CI sslmodes (prefer/require) -> trust=null is correct here.
    try std.testing.expect(!cfg.sslmode.verifiesCertificate());
    try std.testing.expectError(error.PasswordNeedsNormalization, pg.Conn.connect(a, io, cfg, null));
}
