const std = @import("std");

pub const Config = struct {
    http_host: []const u8 = "0.0.0.0",
    http_port: u16 = 8090,
    data_dir: []const u8 = "./zb_data",
    jwt_secret: []const u8 = "dev-insecure-secret-change-me",
    cookie_secure: bool = false, // dev default; set true behind HTTPS
    auth_token_ttl_s: i64 = 14 * 24 * 3600, // 14 days
    verification_ttl_s: i64 = 7 * 24 * 3600, // 7 days
    password_reset_ttl_s: i64 = 3600, // 1 hour

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
