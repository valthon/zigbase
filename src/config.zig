const std = @import("std");
const clock = @import("clock.zig");

/// SMTP transport security mode (config-driven).
///   none     — plaintext SMTP (MailHog / local relays; current behavior).
///   starttls — connect plaintext, EHLO, issue STARTTLS, upgrade the same
///              connection to TLS, re-EHLO; AUTH/MAIL/RCPT/DATA run over TLS.
///   implicit — SMTPS: wrap the TCP connection in TLS immediately on connect
///              (before any SMTP bytes); the whole exchange runs over TLS.
///   auto     — infer from port: 465 → implicit, 587 → starttls, else → none.
pub const SmtpTls = enum { none, starttls, implicit, auto };

pub const Config = struct {
    // Secure-by-default bind: loopback only. The server only listens on all
    // interfaces when explicitly opted in (`--http-host 0.0.0.0` / ZIGBASE_HTTP_HOST).
    http_host: []const u8 = "127.0.0.1",
    http_port: u16 = 8090,
    data_dir: []const u8 = "./zb_data",
    // "" = no operator-provided secret: serveImpl auto-generates a strong random
    // secret on first run and persists it at <data_dir>/.jwt_secret (0600), reusing
    // it thereafter. An operator-provided secret must be >= 32 bytes; the old shared
    // "dev-insecure-secret-change-me" default is gone.
    jwt_secret: []const u8 = "",
    cookie_secure: bool = true, // secure-by-default; opt out with --insecure-cookies for plain-HTTP local dev
    auth_token_ttl_s: i64 = 14 * 24 * 3600, // 14 days
    verification_ttl_s: i64 = 7 * 24 * 3600, // 7 days
    password_reset_ttl_s: i64 = 3600, // 1 hour
    // CSV of allowed WS Origins. Empty = DENY all cross-origin upgrades (an upgrade
    // is permitted only when no Origin header is present, i.e. a non-browser client).
    // Set explicit origins to allow browser clients. Empty no longer means "allow any".
    realtime_allowed_origins: []const u8 = "",
    // When false (default), the rate limiter and any client-IP logic key on the real
    // socket peer and IGNORE X-Forwarded-For / X-Real-IP (which a direct attacker can
    // spoof). Set true ONLY when behind a trusted reverse proxy that sets those headers.
    trust_proxy: bool = false,
    max_upload_size: u64 = 50 << 20, // 50 MiB per request body
    file_token_ttl_s: i64 = 120, // short-lived file-access token
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
    // Static-file root for the default (runtime-flag) mode; set by `--serve-static`.
    // "" = no static serving. Comptime modes (.dir/.embedded/.disabled) ignore it.
    static_dir: []const u8 = "",

    // In-memory rate limiting for sensitive auth endpoints (login / password-reset /
    // email-verification). Fixed window: at most `rate_limit_max` requests per client
    // key per `rate_limit_window_s` seconds. `rate_limit_max = 0` disables it entirely.
    // Default 10/60s is well above a single interactive login (Playwright suite stays green).
    rate_limit_max: u32 = 10, // attempts per window per key; 0 = disabled
    rate_limit_window_s: i64 = 60, // window length in seconds

    // Server-side OAuth `state` (CSRF) store (F11). ON by default: the backend mints a
    // `state` via the oauth2 method initiate call and requires/verifies it on complete,
    // rejecting a missing/mismatched/expired/reused state — the secure flow. Set
    // ZIGBASE_OAUTH_STATE_SERVER=false to opt out (client-driven PKCE + client-held
    // state only), e.g. for a client that manages its own CSRF state end-to-end.
    oauth_state_server: bool = true,
    oauth_state_ttl_s: i64 = 600, // server-side state lifetime (10 min)

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

    // DEV-ONLY frozen clock (`ZIGBASE_FAKE_NOW`, an ISO-8601 UTC instant). Resolved to unix
    // seconds here so serveImpl can `clock.install` it. ALWAYS null on a production build —
    // `clock.resolveFromEnv` is comptime-gated off when the `dev_clock` build option is false,
    // so a prod binary ignores the env var entirely (see clock.zig). null = wall-clock.
    fake_now_unix: ?i64 = null,

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

    /// Pure loader: applies overrides from a getter, which is any value with a
    /// `get(key) ?[]const u8` method (env in prod via `EnvGetter`, a stub in tests).
    pub fn load(getter: anytype) !Config {
        var cfg = Config{};
        if (getter.get("ZIGBASE_HTTP_HOST")) |v| cfg.http_host = v;
        if (getter.get("ZIGBASE_HTTP_PORT")) |v| cfg.http_port = try std.fmt.parseInt(u16, v, 10);
        if (getter.get("ZIGBASE_DATA_DIR")) |v| cfg.data_dir = v;
        if (getter.get("ZIGBASE_JWT_SECRET")) |v| cfg.jwt_secret = v;
        if (getter.get("ZIGBASE_COOKIE_SECURE")) |v| cfg.cookie_secure = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        if (getter.get("ZIGBASE_AUTH_TOKEN_TTL")) |v| cfg.auth_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_VERIFICATION_TTL")) |v| cfg.verification_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_PASSWORD_RESET_TTL")) |v| cfg.password_reset_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_REALTIME_ORIGINS")) |v| cfg.realtime_allowed_origins = v;
        if (getter.get("ZIGBASE_TRUST_PROXY")) |v| cfg.trust_proxy = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        if (getter.get("ZIGBASE_MAX_UPLOAD_SIZE")) |v| cfg.max_upload_size = try std.fmt.parseInt(u64, v, 10);
        if (getter.get("ZIGBASE_FILE_TOKEN_TTL")) |v| cfg.file_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_SENTRY_DSN")) |v| cfg.sentry_dsn = v;
        if (getter.get("ZIGBASE_RATE_LIMIT_MAX")) |v| cfg.rate_limit_max = try std.fmt.parseInt(u32, v, 10);
        if (getter.get("ZIGBASE_RATE_LIMIT_WINDOW")) |v| cfg.rate_limit_window_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_OAUTH_STATE_SERVER")) |v| cfg.oauth_state_server = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        if (getter.get("ZIGBASE_OAUTH_STATE_TTL")) |v| cfg.oauth_state_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter.get("ZIGBASE_SMTP_HOST")) |v| cfg.smtp_host = v;
        if (getter.get("ZIGBASE_SMTP_PORT")) |v| cfg.smtp_port = try std.fmt.parseInt(u16, v, 10);
        if (getter.get("ZIGBASE_SMTP_USERNAME")) |v| cfg.smtp_username = v;
        if (getter.get("ZIGBASE_SMTP_PASSWORD")) |v| cfg.smtp_password = v;
        if (getter.get("ZIGBASE_SMTP_FROM")) |v| cfg.smtp_from = v;
        if (getter.get("ZIGBASE_SMTP_TLS")) |v| {
            if (std.mem.eql(u8, v, "none")) cfg.smtp_tls = .none
            else if (std.mem.eql(u8, v, "starttls")) cfg.smtp_tls = .starttls
            else if (std.mem.eql(u8, v, "implicit")) cfg.smtp_tls = .implicit
            else if (std.mem.eql(u8, v, "auto")) cfg.smtp_tls = .auto
            else return error.InvalidSmtpTls;
        }
        if (getter.get("ZIGBASE_SMTP_INSECURE")) |v|
            cfg.smtp_insecure_skip_verify = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        // Dev-only frozen clock. resolveFromEnv is comptime-gated off on a prod build, so this
        // is always null there regardless of the env var.
        cfg.fake_now_unix = clock.resolveFromEnv(getter.get(clock.env_var));
        return cfg;
    }
};

/// Production env getter: reads the process environment via Zig 0.16's pure-Zig
/// `std.process.Environ.Map` (no libc). Built in framework.loadCfg from
/// `init.environ_map` and passed to `Config.load`. Test code passes its own
/// stub getter with the same `get(self, key) ?[]const u8` shape.
pub const EnvGetter = struct {
    environ: *const std.process.Environ.Map,
    pub fn get(self: EnvGetter, key: []const u8) ?[]const u8 {
        return self.environ.get(key);
    }
};

test "defaults apply when getter returns null" {
    const G = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const cfg = try Config.load(G{});
    try std.testing.expectEqual(@as(u16, 8090), cfg.http_port);
    // Secure-by-default: loopback bind, no operator secret yet, secure cookies, no trusted proxy.
    try std.testing.expectEqualStrings("127.0.0.1", cfg.http_host);
    try std.testing.expectEqualStrings("", cfg.jwt_secret);
    try std.testing.expectEqual(true, cfg.cookie_secure);
    try std.testing.expectEqual(false, cfg.trust_proxy);
}

test "env overrides are applied and parsed" {
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_HTTP_PORT")) return "9123";
            if (std.mem.eql(u8, key, "ZIGBASE_DATA_DIR")) return "/var/zb";
            return null;
        }
    };
    const cfg = try Config.load(G{});
    try std.testing.expectEqual(@as(u16, 9123), cfg.http_port);
    try std.testing.expectEqualStrings("/var/zb", cfg.data_dir);
}

test "auth defaults and overrides" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(G0{});
    try std.testing.expectEqual(true, d.cookie_secure); // secure-by-default
    try std.testing.expectEqual(@as(i64, 14 * 24 * 3600), d.auth_token_ttl_s);

    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_COOKIE_SECURE")) return "false";
            if (std.mem.eql(u8, key, "ZIGBASE_AUTH_TOKEN_TTL")) return "3600";
            return null;
        }
    };
    const c = try Config.load(G1{});
    try std.testing.expectEqual(false, c.cookie_secure); // opt-out for plain-HTTP local dev
    try std.testing.expectEqual(@as(i64, 3600), c.auth_token_ttl_s);
}

test "trust_proxy defaults off, opt-in via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    try std.testing.expectEqual(false, (try Config.load(G0{})).trust_proxy);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_TRUST_PROXY")) return "true";
            return null;
        }
    };
    try std.testing.expectEqual(true, (try Config.load(G1{})).trust_proxy);
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
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_TLS")) return "starttls";
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_INSECURE")) return "true";
            return null;
        }
    };
    const cfg = try Config.load(G{});
    try std.testing.expectEqual(SmtpTls.starttls, cfg.smtp_tls);
    try std.testing.expectEqual(true, cfg.smtp_insecure_skip_verify);

    // Default: auto + verify on.
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(G0{});
    try std.testing.expectEqual(SmtpTls.auto, d.smtp_tls);
    try std.testing.expectEqual(false, d.smtp_insecure_skip_verify);
}

test "rate limit defaults and overrides" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(G0{});
    try std.testing.expectEqual(@as(u32, 10), d.rate_limit_max);
    try std.testing.expectEqual(@as(i64, 60), d.rate_limit_window_s);

    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_RATE_LIMIT_MAX")) return "0";
            if (std.mem.eql(u8, key, "ZIGBASE_RATE_LIMIT_WINDOW")) return "120";
            return null;
        }
    };
    const c = try Config.load(G1{});
    try std.testing.expectEqual(@as(u32, 0), c.rate_limit_max);
    try std.testing.expectEqual(@as(i64, 120), c.rate_limit_window_s);
}

test "oauth_state_server defaults ON, opt-out via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    // Secure-by-default: server-side OAuth CSRF state is ON unless explicitly disabled.
    try std.testing.expectEqual(true, (try Config.load(G0{})).oauth_state_server);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_STATE_SERVER")) return "false";
            return null;
        }
    };
    try std.testing.expectEqual(false, (try Config.load(G1{})).oauth_state_server);
}

test "realtime origins default empty, overridable" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    try std.testing.expectEqualStrings("", (try Config.load(G0{})).realtime_allowed_origins);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_REALTIME_ORIGINS")) return "https://app.example";
            return null;
        }
    };
    try std.testing.expectEqualStrings("https://app.example", (try Config.load(G1{})).realtime_allowed_origins);
}
