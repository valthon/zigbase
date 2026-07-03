//! Parse a libpq-style URI `postgres://user:pass@host:port/dbname?sslmode=...` into the
//! fields the wire driver needs. Accepts the `postgres://` and `postgresql://` schemes.
//! Percent-decoding is applied to the user/password/dbname components.

const std = @import("std");

pub const SslMode = enum {
    disable,
    /// Try TLS first, fall back to plaintext if the server refuses (SSLRequest → 'N').
    prefer,
    /// Require TLS; fail if the server will not negotiate it. The server is NOT
    /// authenticated (libpq `require` parity) — chain/hostname are not checked.
    require,
    /// Require TLS + verify the server certificate chain against the CA bundle
    /// (`sslrootcert=<path>` or the system root store).
    verify_ca,
    /// `verify_ca` + verify the certificate matches the URL host (SAN/CN).
    /// The DEFAULT for `postgres://` URLs since 0.10.0 (safe-by-default).
    verify_full,

    pub fn parse(s: []const u8) ?SslMode {
        if (std.mem.eql(u8, s, "disable")) return .disable;
        if (std.mem.eql(u8, s, "prefer")) return .prefer;
        if (std.mem.eql(u8, s, "allow")) return .prefer;
        if (std.mem.eql(u8, s, "require")) return .require;
        if (std.mem.eql(u8, s, "verify-ca")) return .verify_ca;
        if (std.mem.eql(u8, s, "verify-full")) return .verify_full;
        return null;
    }

    /// The libpq-style spelling, for log/error messages ("verify-full", not "verify_full").
    pub fn label(self: SslMode) []const u8 {
        return switch (self) {
            .disable => "disable",
            .prefer => "prefer",
            .require => "require",
            .verify_ca => "verify-ca",
            .verify_full => "verify-full",
        };
    }

    /// True when this mode verifies the server certificate chain (and, for
    /// `verify_full`, the hostname) — i.e. when a `TlsTrust` bundle must be built.
    pub fn verifiesCertificate(self: SslMode) bool {
        return self == .verify_ca or self == .verify_full;
    }
};

pub const ParseError = error{
    UnsupportedScheme,
    MissingHost,
    InvalidPort,
    InvalidSslMode,
    OutOfMemory,
};

/// Parsed connection parameters. All slices are owned (`dupe`d from the allocator);
/// call `deinit` to free them.
pub const Config = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16 = 5432,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8,
    sslmode: SslMode = .verify_full,
    /// True when the URL carried an explicit `sslmode=` (drives the opted-down startup
    /// warning: the DEFAULT verify-full and explicit verify modes are silent).
    sslmode_explicit: bool = false,
    /// Percent-decoded `sslrootcert=` value: a CA-bundle PEM path, or the literal
    /// "system" (libpq-16 semantics: explicitly select the system root store).
    /// Owned (duped); null when absent.
    sslrootcert: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        if (self.sslrootcert) |rc| self.allocator.free(rc);
    }
};

pub fn parse(allocator: std.mem.Allocator, uri: []const u8) ParseError!Config {
    var rest = uri;
    if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else return ParseError.UnsupportedScheme;

    // Split off the query string (?sslmode=...).
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    // authority = [user[:password]@]host[:port][/dbname]
    var userinfo: []const u8 = "";
    var hostpart = rest;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        userinfo = rest[0..at];
        hostpart = rest[at + 1 ..];
    }

    var user: []const u8 = "";
    var password: []const u8 = "";
    if (userinfo.len > 0) {
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            user = userinfo[0..colon];
            password = userinfo[colon + 1 ..];
        } else user = userinfo;
    }

    // database is everything after the first '/'.
    var database: []const u8 = "";
    if (std.mem.indexOfScalar(u8, hostpart, '/')) |slash| {
        database = hostpart[slash + 1 ..];
        hostpart = hostpart[0..slash];
    }

    // host[:port] — an IPv6 literal is bracketed: [::1]:5432
    var host: []const u8 = hostpart;
    var port: u16 = 5432;
    if (hostpart.len > 0 and hostpart[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostpart, ']') orelse return ParseError.MissingHost;
        host = hostpart[1..close];
        const after = hostpart[close + 1 ..];
        if (after.len > 0 and after[0] == ':')
            port = std.fmt.parseInt(u16, after[1..], 10) catch return ParseError.InvalidPort;
    } else if (std.mem.lastIndexOfScalar(u8, hostpart, ':')) |colon| {
        host = hostpart[0..colon];
        port = std.fmt.parseInt(u16, hostpart[colon + 1 ..], 10) catch return ParseError.InvalidPort;
    }
    if (host.len == 0) return ParseError.MissingHost;

    var sslmode: SslMode = .verify_full;
    var sslmode_explicit = false;
    var sslrootcert_raw: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "sslmode")) {
            sslmode = SslMode.parse(val) orelse return ParseError.InvalidSslMode;
            sslmode_explicit = true;
        } else if (std.mem.eql(u8, key, "sslrootcert")) {
            sslrootcert_raw = val;
        } else if (std.mem.eql(u8, key, "dbname") and database.len == 0) {
            database = val;
        }
        // Unknown query keys keep today's ignore behavior.
    }

    // Default user/database to "postgres" when unspecified (libpq defaults to the OS user;
    // "postgres" is the safest portable default for a server-side service).
    if (user.len == 0) user = "postgres";
    if (database.len == 0) database = user;

    const host_d = try pctDup(allocator, host);
    errdefer allocator.free(host_d);
    const user_d = try pctDup(allocator, user);
    errdefer allocator.free(user_d);
    const pass_d = try pctDup(allocator, password);
    errdefer allocator.free(pass_d);
    const db_d = try pctDup(allocator, database);
    errdefer allocator.free(db_d);
    const rootcert_d: ?[]u8 = if (sslrootcert_raw) |rc| try pctDup(allocator, rc) else null;

    return .{
        .allocator = allocator,
        .host = host_d,
        .port = port,
        .user = user_d,
        .password = pass_d,
        .database = db_d,
        .sslmode = sslmode,
        .sslmode_explicit = sslmode_explicit,
        .sslrootcert = rootcert_d,
    };
}

/// `dupe` `s` with `%XX` percent-escapes decoded.
fn pctDup(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// True if `s` looks like a Postgres connection URI (vs a SQLite file path / `:memory:`).
pub fn looksLikePostgres(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "postgres://") or std.mem.startsWith(u8, s, "postgresql://");
}

test "connstr: full URI with ipv6 host, port, password, sslmode" {
    const a = std.testing.allocator;
    var cfg = try parse(a, "postgresql://zbpg:s3cr3t@[::1]:5433/zbpgtest?sslmode=require");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("::1", cfg.host);
    try std.testing.expectEqual(@as(u16, 5433), cfg.port);
    try std.testing.expectEqualStrings("zbpg", cfg.user);
    try std.testing.expectEqualStrings("s3cr3t", cfg.password);
    try std.testing.expectEqualStrings("zbpgtest", cfg.database);
    try std.testing.expectEqual(SslMode.require, cfg.sslmode);
}

test "connstr: defaults + percent-decoding" {
    const a = std.testing.allocator;
    var cfg = try parse(a, "postgres://app%40svc@db.example.com/mydb");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("db.example.com", cfg.host);
    try std.testing.expectEqual(@as(u16, 5432), cfg.port);
    try std.testing.expectEqualStrings("app@svc", cfg.user);
    try std.testing.expectEqualStrings("", cfg.password);
    try std.testing.expectEqualStrings("mydb", cfg.database);
    try std.testing.expectEqual(SslMode.verify_full, cfg.sslmode);
}

test "connstr: bare host defaults user and database" {
    const a = std.testing.allocator;
    var cfg = try parse(a, "postgres://localhost");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("localhost", cfg.host);
    try std.testing.expectEqualStrings("postgres", cfg.user);
    try std.testing.expectEqualStrings("postgres", cfg.database);
}

test "connstr: rejects non-postgres scheme" {
    try std.testing.expectError(ParseError.UnsupportedScheme, parse(std.testing.allocator, "mysql://x/y"));
    try std.testing.expect(!looksLikePostgres("/var/data/data.db"));
    try std.testing.expect(looksLikePostgres("postgres://localhost/db"));
}

test "connstr: verify-ca/verify-full parse to the new enum members" {
    const a = std.testing.allocator;
    var ca = try parse(a, "postgres://h/db?sslmode=verify-ca");
    defer ca.deinit();
    try std.testing.expectEqual(SslMode.verify_ca, ca.sslmode);
    try std.testing.expect(ca.sslmode_explicit);
    var full = try parse(a, "postgres://h/db?sslmode=verify-full");
    defer full.deinit();
    try std.testing.expectEqual(SslMode.verify_full, full.sslmode);
    // A bogus mode is still rejected loudly.
    try std.testing.expectError(ParseError.InvalidSslMode, parse(a, "postgres://h/db?sslmode=bogus"));
}

test "connstr: DEFAULT sslmode is verify-full; explicit modes are respected + flagged" {
    const a = std.testing.allocator;
    var bare = try parse(a, "postgres://db.example.com/mydb");
    defer bare.deinit();
    try std.testing.expectEqual(SslMode.verify_full, bare.sslmode);
    try std.testing.expect(!bare.sslmode_explicit);
    inline for (.{ "disable", "prefer", "require" }, .{ SslMode.disable, SslMode.prefer, SslMode.require }) |s, m| {
        var cfg = try parse(a, "postgres://h/db?sslmode=" ++ s);
        defer cfg.deinit();
        try std.testing.expectEqual(m, cfg.sslmode);
        try std.testing.expect(cfg.sslmode_explicit);
    }
}

test "connstr: sslrootcert path, =system, and percent-decoding" {
    const a = std.testing.allocator;
    var p = try parse(a, "postgres://h/db?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fmy-ca.pem");
    defer p.deinit();
    try std.testing.expectEqualStrings("/etc/ssl/my-ca.pem", p.sslrootcert.?);
    var sys = try parse(a, "postgres://h/db?sslmode=verify-ca&sslrootcert=system");
    defer sys.deinit();
    try std.testing.expectEqualStrings("system", sys.sslrootcert.?);
    // sslrootcert with a NON-verifying mode is accepted (ignored + warned at the pool layer, libpq parity).
    var req = try parse(a, "postgres://h/db?sslmode=require&sslrootcert=/x.pem");
    defer req.deinit();
    try std.testing.expectEqual(SslMode.require, req.sslmode);
    try std.testing.expectEqualStrings("/x.pem", req.sslrootcert.?);
    // Absent -> null.
    var none = try parse(a, "postgres://h/db");
    defer none.deinit();
    try std.testing.expect(none.sslrootcert == null);
}

test "connstr: label + verifiesCertificate round out the mode surface" {
    try std.testing.expectEqualStrings("verify-full", SslMode.verify_full.label());
    try std.testing.expectEqualStrings("verify-ca", SslMode.verify_ca.label());
    try std.testing.expectEqualStrings("require", SslMode.require.label());
    try std.testing.expect(SslMode.verify_ca.verifiesCertificate());
    try std.testing.expect(SslMode.verify_full.verifiesCertificate());
    try std.testing.expect(!SslMode.require.verifiesCertificate());
    try std.testing.expect(!SslMode.prefer.verifiesCertificate());
    try std.testing.expect(!SslMode.disable.verifiesCertificate());
}
