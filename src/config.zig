const std = @import("std");

/// SMTP transport security mode (config-driven).
///   none     — plaintext SMTP (MailHog / local relays; current behavior).
///   starttls — connect plaintext, EHLO, issue STARTTLS, upgrade the same
///              connection to TLS, re-EHLO; AUTH/MAIL/RCPT/DATA run over TLS.
///   implicit — SMTPS: wrap the TCP connection in TLS immediately on connect
///              (before any SMTP bytes); the whole exchange runs over TLS.
///   auto     — infer from port: 465 → implicit, 587 → starttls, else → none.
pub const SmtpTls = enum { none, starttls, implicit, auto };

pub const Config = struct {
    http_host: []const u8 = "0.0.0.0",
    http_port: u16 = 8090,
    data_dir: []const u8 = "./zb_data",
    jwt_secret: []const u8 = "dev-insecure-secret-change-me",
    cookie_secure: bool = false, // dev default; set true behind HTTPS
    auth_token_ttl_s: i64 = 14 * 24 * 3600, // 14 days
    verification_ttl_s: i64 = 7 * 24 * 3600, // 7 days
    password_reset_ttl_s: i64 = 3600, // 1 hour
    realtime_allowed_origins: []const u8 = "", // CSV of allowed WS Origins; "" = allow any (dev)
    max_upload_size: u64 = 50 << 20, // 50 MiB per request body
    file_token_ttl_s: i64 = 120, // short-lived file-access token
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting

    // SMTP / mailer. When smtp_host is empty (default), the default mailer plugin
    // resolves to LogMailer (logs verify/reset emails — pre-mailer dev/CI behavior).
    // Set smtp_host to upgrade to a real SMTP client with NO code change.
    smtp_host: []const u8 = "", // "" = use LogMailer; non-empty = SmtpMailer
    smtp_port: u16 = 25,
    smtp_username: []const u8 = "", // non-empty enables AUTH LOGIN
    smtp_password: []const u8 = "",
    smtp_from: []const u8 = "noreply@zigbase.dev", // envelope + From: header address
    smtp_tls: SmtpTls = .auto, // transport security: none/starttls/implicit/auto
    smtp_insecure_skip_verify: bool = false, // true = skip cert verification (self-signed relays)

    /// Resolve `auto` to a concrete TLS mode from the port:
    ///   465 → implicit (SMTPS), 587 → starttls, anything else → none.
    /// `none`/`starttls`/`implicit` are returned unchanged.
    pub fn resolveSmtpTls(mode: SmtpTls, port: u16) SmtpTls {
        if (mode != .auto) return mode;
        return switch (port) {
            465 => .implicit,
            587 => .starttls,
            else => .none,
        };
    }

    /// Pure loader: applies overrides from a getter (env in prod, a stub in tests).
    pub fn load(getter: *const fn ([]const u8) ?[]const u8) !Config {
        var cfg = Config{};
        if (getter("ZIGBASE_HTTP_HOST")) |v| cfg.http_host = v;
        if (getter("ZIGBASE_HTTP_PORT")) |v| cfg.http_port = try std.fmt.parseInt(u16, v, 10);
        if (getter("ZIGBASE_DATA_DIR")) |v| cfg.data_dir = v;
        if (getter("ZIGBASE_JWT_SECRET")) |v| cfg.jwt_secret = v;
        if (getter("ZIGBASE_COOKIE_SECURE")) |v| cfg.cookie_secure = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        if (getter("ZIGBASE_AUTH_TOKEN_TTL")) |v| cfg.auth_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_VERIFICATION_TTL")) |v| cfg.verification_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_PASSWORD_RESET_TTL")) |v| cfg.password_reset_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_REALTIME_ORIGINS")) |v| cfg.realtime_allowed_origins = v;
        if (getter("ZIGBASE_MAX_UPLOAD_SIZE")) |v| cfg.max_upload_size = try std.fmt.parseInt(u64, v, 10);
        if (getter("ZIGBASE_FILE_TOKEN_TTL")) |v| cfg.file_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_SENTRY_DSN")) |v| cfg.sentry_dsn = v;
        if (getter("ZIGBASE_SMTP_HOST")) |v| cfg.smtp_host = v;
        if (getter("ZIGBASE_SMTP_PORT")) |v| cfg.smtp_port = try std.fmt.parseInt(u16, v, 10);
        if (getter("ZIGBASE_SMTP_USERNAME")) |v| cfg.smtp_username = v;
        if (getter("ZIGBASE_SMTP_PASSWORD")) |v| cfg.smtp_password = v;
        if (getter("ZIGBASE_SMTP_FROM")) |v| cfg.smtp_from = v;
        if (getter("ZIGBASE_SMTP_TLS")) |v| {
            if (std.mem.eql(u8, v, "none")) cfg.smtp_tls = .none
            else if (std.mem.eql(u8, v, "starttls")) cfg.smtp_tls = .starttls
            else if (std.mem.eql(u8, v, "implicit")) cfg.smtp_tls = .implicit
            else if (std.mem.eql(u8, v, "auto")) cfg.smtp_tls = .auto
            else return error.InvalidSmtpTls;
        }
        if (getter("ZIGBASE_SMTP_INSECURE")) |v|
            cfg.smtp_insecure_skip_verify = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        return cfg;
    }
};

/// Real env getter for production use.
/// Uses std.c.getenv (POSIX libc) which takes a null-terminated key.
/// std.posix.getenv does not exist in Zig 0.16.0; std.c.getenv is the correct path.
pub fn envGetter(key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const z: [:0]const u8 = buf[0..key.len :0];
    const result = std.c.getenv(z.ptr) orelse return null;
    return std.mem.span(result);
}

test "defaults apply when getter returns null" {
    const G = struct {
        fn get(_: []const u8) ?[]const u8 {
            return null;
        }
    };
    const cfg = try Config.load(&G.get);
    try std.testing.expectEqual(@as(u16, 8090), cfg.http_port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.http_host);
}

test "env overrides are applied and parsed" {
    const G = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_HTTP_PORT")) return "9123";
            if (std.mem.eql(u8, key, "ZIGBASE_DATA_DIR")) return "/var/zb";
            return null;
        }
    };
    const cfg = try Config.load(&G.get);
    try std.testing.expectEqual(@as(u16, 9123), cfg.http_port);
    try std.testing.expectEqualStrings("/var/zb", cfg.data_dir);
}

test "auth defaults and overrides" {
    const G0 = struct {
        fn get(_: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(&G0.get);
    try std.testing.expectEqual(false, d.cookie_secure);
    try std.testing.expectEqual(@as(i64, 14 * 24 * 3600), d.auth_token_ttl_s);

    const G1 = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_COOKIE_SECURE")) return "true";
            if (std.mem.eql(u8, key, "ZIGBASE_AUTH_TOKEN_TTL")) return "3600";
            return null;
        }
    };
    const c = try Config.load(&G1.get);
    try std.testing.expectEqual(true, c.cookie_secure);
    try std.testing.expectEqual(@as(i64, 3600), c.auth_token_ttl_s);
}

test "smtp_tls auto inference from port" {
    // auto resolves per-port.
    try std.testing.expectEqual(SmtpTls.implicit, Config.resolveSmtpTls(.auto, 465));
    try std.testing.expectEqual(SmtpTls.starttls, Config.resolveSmtpTls(.auto, 587));
    try std.testing.expectEqual(SmtpTls.none, Config.resolveSmtpTls(.auto, 25));
    try std.testing.expectEqual(SmtpTls.none, Config.resolveSmtpTls(.auto, 2525));
    // explicit modes pass through unchanged regardless of port.
    try std.testing.expectEqual(SmtpTls.none, Config.resolveSmtpTls(.none, 465));
    try std.testing.expectEqual(SmtpTls.starttls, Config.resolveSmtpTls(.starttls, 25));
    try std.testing.expectEqual(SmtpTls.implicit, Config.resolveSmtpTls(.implicit, 587));
}

test "smtp tls env overrides" {
    const G = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_TLS")) return "starttls";
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_INSECURE")) return "true";
            return null;
        }
    };
    const cfg = try Config.load(&G.get);
    try std.testing.expectEqual(SmtpTls.starttls, cfg.smtp_tls);
    try std.testing.expectEqual(true, cfg.smtp_insecure_skip_verify);

    // Default: auto + verify on.
    const G0 = struct {
        fn get(_: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(&G0.get);
    try std.testing.expectEqual(SmtpTls.auto, d.smtp_tls);
    try std.testing.expectEqual(false, d.smtp_insecure_skip_verify);
}

test "realtime origins default empty, overridable" {
    const G0 = struct {
        fn get(_: []const u8) ?[]const u8 { return null; }
    };
    try std.testing.expectEqualStrings("", (try Config.load(&G0.get)).realtime_allowed_origins);
    const G1 = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_REALTIME_ORIGINS")) return "https://app.example";
            return null;
        }
    };
    try std.testing.expectEqualStrings("https://app.example", (try Config.load(&G1.get)).realtime_allowed_origins);
}
