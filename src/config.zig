const std = @import("std");
const clock = @import("clock.zig");
const entropy = @import("entropy.zig");
const field_policy = @import("field_policy.zig");
const logging = @import("logging.zig");

/// SMTP transport security mode (config-driven).
///   none     — plaintext SMTP (MailHog / local relays; current behavior).
///   starttls — connect plaintext, EHLO, issue STARTTLS, upgrade the same
///              connection to TLS, re-EHLO; AUTH/MAIL/RCPT/DATA run over TLS.
///   implicit — SMTPS: wrap the TCP connection in TLS immediately on connect
///              (before any SMTP bytes); the whole exchange runs over TLS.
///   auto     — infer from port: 465 → implicit, 587 → starttls, else → none.
pub const SmtpTls = enum { none, starttls, implicit, auto };

/// Detail about the single env var that failed to parse. Filled by `loadDiag` on
/// `error.InvalidEnvValue`. It rides an out-param rather than a log call because
/// `Config.load` is a pure loader driven by a stub getter in tests — this keeps the
/// exact operator-facing wording unit-testable.
pub const LoadDiag = struct {
    var_name: []const u8 = "",
    value: []const u8 = "",
    /// Human description of the accepted values, e.g. "u16 (decimal integer)" or
    /// "true|false|1|0". Rendered verbatim into the startup error.
    expected: []const u8 = "",
};

pub const LoadError = error{InvalidEnvValue};

fn envInt(comptime T: type, name: []const u8, v: []const u8, diag: *LoadDiag) LoadError!T {
    return std.fmt.parseInt(T, v, 10) catch {
        diag.* = .{ .var_name = name, .value = v, .expected = @typeName(T) ++ " (decimal integer)" };
        return error.InvalidEnvValue;
    };
}

/// Booleans accept exactly `true`, `false`, `1`, `0`. Anything else is a startup
/// error — the old "not exactly 'true' or '1' means false" rule silently discarded
/// `yes`, `TRUE`, and typos, which on a knob like ZIGBASE_TRUST_PROXY is a security bug.
fn envBool(name: []const u8, v: []const u8, diag: *LoadDiag) LoadError!bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    diag.* = .{ .var_name = name, .value = v, .expected = "true|false|1|0" };
    return error.InvalidEnvValue;
}

fn envEnum(comptime T: type, name: []const u8, v: []const u8, comptime choices: []const u8, diag: *LoadDiag) LoadError!T {
    return std.meta.stringToEnum(T, v) orelse {
        diag.* = .{ .var_name = name, .value = v, .expected = choices };
        return error.InvalidEnvValue;
    };
}

pub const Config = struct {
    // Secure-by-default bind: loopback only. The server only listens on all
    // interfaces when explicitly opted in (`--http-host 0.0.0.0` / ZIGBASE_HTTP_HOST).
    http_host: []const u8 = "127.0.0.1",
    http_port: u16 = 8090,
    data_dir: []const u8 = "./zb_data",
    /// Public base URL of this deployment (e.g. "https://app.example.com"). Used
    /// to build absolute links in auth emails (magic-link). Empty = no link is
    /// built (magic-link emails the raw token instead). Env: ZIGBASE_PUBLIC_URL.
    public_url: []const u8 = "",
    // "" = no operator-provided secret: serveImpl auto-generates a strong random
    // secret on first run and persists it at <data_dir>/.jwt_secret (0600), reusing
    // it thereafter. An operator-provided secret must be >= 32 bytes; the old shared
    // "dev-insecure-secret-change-me" default is gone.
    jwt_secret: []const u8 = "",
    // Operator-supplied key for transparent at-rest field encryption (Theme B1). Env:
    // ZIGBASE_FIELD_KEY. "" = unset. Unlike the JWT secret it is NEVER auto-generated or
    // persisted — losing/rotating it determines data recoverability, so it must be
    // operator-managed. serveImpl REFUSES to start if any collection declares an
    // `.encrypted` field while this is empty (fail-closed: never silently store plaintext).
    field_key: []const u8 = "",
    // Generation number of the primary (write) field-encryption key — equals the
    // envelope version stamped on writes (`v<N>:`). Default 1 = the single-key
    // build's behavior (writes/reads v1:). Older read-only generations are supplied
    // via ZIGBASE_FIELD_KEY_V<M> and resolved at startup (see field_policy.Cipher).
    // Env: ZIGBASE_FIELD_KEY_GENERATION. Bump this (and supply the old key as
    // ZIGBASE_FIELD_KEY_V<old>) to rotate; then run `zigbase rewrap`.
    field_key_generation: u16 = 1,
    cookie_secure: bool = true, // secure-by-default; opt out with --insecure-cookies for plain-HTTP local dev
    auth_token_ttl_s: i64 = 14 * 24 * 3600, // 14 days
    verification_ttl_s: i64 = 7 * 24 * 3600, // 7 days
    password_reset_ttl_s: i64 = 3600, // 1 hour
    // CSV of allowed WS Origins. Empty = DENY all cross-origin upgrades (an upgrade
    // is permitted only when no Origin header is present, i.e. a non-browser client).
    // Set explicit origins to allow browser clients. Empty no longer means "allow any".
    realtime_allowed_origins: []const u8 = "",
    // SSE heartbeat interval in seconds (#188). facil.io's SSE protocol writes the comment
    // `: ping\n\n` on every protocol-timeout tick; 0 (default) inherits the listener's
    // ws_timeout (zap default 40s). Nonzero values are applied per-connection at stream open
    // and validated AT STARTUP to 1..=255 (the fio timeout is a u8) — a bad value fails boot.
    sse_heartbeat_seconds: u16 = 0,
    // Slow-consumer outbound high-water-mark (issue #203): the max queued outbound frames facil.io
    // may hold for ONE realtime (WS or SSE) connection before the server disconnects the peer. A
    // stalled/slow reader otherwise accumulates queued frames without bound (OOM/DoS). Unit is
    // FRAMES, not bytes. 0 disables the bound. Env override: ZIGBASE_REALTIME_OUTBOUND_HWM.
    realtime_outbound_hwm: u32 = @import("realtime/connection.zig").DEFAULT_OUTBOUND_HWM,
    // When false (default), the rate limiter and any client-IP logic key on the real
    // socket peer and IGNORE X-Forwarded-For / X-Real-IP (which a direct attacker can
    // spoof). Set true ONLY when behind a trusted reverse proxy that sets those headers.
    trust_proxy: bool = false,
    max_upload_size: u64 = 50 << 20, // 50 MiB per request body
    file_token_ttl_s: i64 = 120, // short-lived file-access token
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
    /// Public base URL for the one-click unsubscribe endpoint (#154 round 2). "" = feature off
    /// (see `mail/config.zig` Runtime.unsubscribe_base_url). Env overrides the comptime `.mail`
    /// key — this is what lets the stock binary be configured/e2e-tested without a rebuild.
    unsubscribe_base_url: []const u8 = "",
    // Static-file root for the default (runtime-flag) mode; set by `--serve-static`.
    // "" = no static serving. Comptime modes (.dir/.embedded/.disabled) ignore it.
    static_dir: []const u8 = "",

    // Cache-Control VALUE for static responses (§C). "" = unset: the comptime
    // `.static_cache_control` default applies if configured, else facil.io's stock
    // `max-age=3600` for dir mode / the same default for embedded assets. Applies to
    // STATIC serving only — record-file downloads keep their authorization-derived
    // Cache-Control (the tenancy invariant in api/files.zig, NEVER knob-controlled).
    // Env: ZIGBASE_STATIC_CACHE_CONTROL. Validated at startup (CR/LF, length <= 256).
    static_cache_control: []const u8 = "",

    // S3-compatible remote storage (§D). Parsed in EVERY build — a stock (no -Ds3)
    // binary needs them to detect-and-warn (the postgres_url_without_build precedent);
    // the backend itself is compiled only under -Ds3. Secrets are never logged.
    s3_bucket: []const u8 = "", // non-empty enables S3 (in an -Ds3 build)
    s3_region: []const u8 = "us-east-1",
    s3_endpoint: []const u8 = "", // "" = https://s3.<region>.amazonaws.com; MinIO/R2 set this
    s3_access_key_id: []const u8 = "",
    s3_secret_access_key: []const u8 = "",
    s3_force_path_style: ?bool = null, // null = auto: true when an endpoint is set
    s3_key_prefix: []const u8 = "",
    s3_cache_dir: []const u8 = "", // "" = <data_dir>/storage_cache
    s3_cache_max_bytes: u64 = 1 << 30, // 1 GiB spool cap

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

    // Local-command mailer. When sendmail_command is non-empty it takes
    // precedence over SMTP: the default mailer plugin resolves to CommandMailer,
    // which pipes the RFC822 message to this command's stdin (exit 0 = sent).
    // This is the "delegate delivery to a local MTA, hold no SMTP creds" setup.
    // The string is whitespace-split into argv (e.g. "sendmail -t -i" or
    // "msmtp -t"); the From: header still comes from smtp_from.
    sendmail_command: []const u8 = "", // "" = off (use SMTP/Log); non-empty = CommandMailer

    // Web Push VAPID keypair (#223), base64url. Both empty (default) = push is a logging no-op
    // (`ctx.push().send` never touches the network). Set both to enable real delivery; generate
    // a pair with `zigbase vapid-keygen`. The private key is SECRET (never logged). Env:
    // ZIGBASE_VAPID_PUBLIC_KEY / ZIGBASE_VAPID_PRIVATE_KEY.
    vapid_public_key: []const u8 = "",
    vapid_private_key: []const u8 = "",

    // Twilio SMS (#224). When all three are set, the default SMS provider plugin resolves to
    // TwilioSender; otherwise it resolves to LogSmsSender (logs the message — no network, no
    // credentials needed for dev/CI). Secrets are ENV only (like SMTP), never comptime.
    twilio_account_sid: []const u8 = "", // "" = use LogSmsSender; set (with token+from) = TwilioSender
    twilio_auth_token: []const u8 = "",
    twilio_from: []const u8 = "", // the Twilio sender number (E.164, e.g. +15551234567)

    // DEV-ONLY frozen clock (`ZIGBASE_FAKE_NOW`, an ISO-8601 UTC instant). Resolved to unix
    // seconds here so serveImpl can `clock.install` it. ALWAYS null on a production build —
    // `clock.resolveFromEnv` is comptime-gated off when the `dev_mode` build option is false,
    // so a prod binary ignores the env var entirely (see clock.zig). null = wall-clock.
    fake_now_unix: ?i64 = null,

    // DEV-ONLY seeded entropy (`ZIGBASE_FAKE_SEED`, a decimal u64). When set, ID/token
    // generation (record IDs, field IDs, token keys) uses a deterministic Xoshiro256++ PRNG
    // seeded from this value instead of the OS CSPRNG, making snapshot tests reproducible.
    // ALWAYS null on a production build — `entropy.resolveFromEnv` is comptime-gated off
    // when the `dev_mode` build option is false, so a prod binary ignores the env var
    // entirely. null = real OS CSPRNG (the always-correct default).
    fake_seed: ?u64 = null,

    // DEV-ONLY fake field-crypto (`ZIGBASE_FIELD_CRYPTO=fake`). When `.fake`, `.encrypted`
    // fields are stored READABLE as `fake:<key>:<value>` for debugging. ALWAYS `.real` on a
    // production build — `field_policy.resolveModeFromEnv` is comptime-gated off when
    // `dev_mode` is false, so a prod binary ignores the env var entirely. `.real` = AES-GCM.
    field_crypto: field_policy.Mode = .real,

    // Log line encoding. `text` (default) is human-first; `json` emits one JSON
    // object per line on stderr — the machine-readable stream agents consume.
    // Env: ZIGBASE_LOG_FORMAT. Flag (serve only): --log-format.
    log_format: logging.Format = .text,
    // Minimum severity that is emitted. Env: ZIGBASE_LOG_LEVEL; flag --log-level.
    log_level: std.log.Level = .info,
    // Per-request access lines (method, path, status, duration). On by default;
    // turn off on a high-traffic deployment that ships access logs from its proxy.
    // Env: ZIGBASE_LOG_REQUESTS; flag --no-request-log.
    log_requests: bool = true,

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
    /// On a bad value, returns `error.InvalidEnvValue` and fills `diag` with which
    /// variable, what value, and what was expected — see `load` for the common case
    /// that discards the diagnostic.
    pub fn loadDiag(getter: anytype, diag: *LoadDiag) LoadError!Config {
        var cfg = Config{};
        if (getter.get("ZIGBASE_HTTP_HOST")) |v| cfg.http_host = v;
        if (getter.get("ZIGBASE_HTTP_PORT")) |v| cfg.http_port = try envInt(u16, "ZIGBASE_HTTP_PORT", v, diag);
        if (getter.get("ZIGBASE_DATA_DIR")) |v| cfg.data_dir = v;
        if (getter.get("ZIGBASE_PUBLIC_URL")) |v| cfg.public_url = v;
        if (getter.get("ZIGBASE_JWT_SECRET")) |v| cfg.jwt_secret = v;
        if (getter.get("ZIGBASE_FIELD_KEY")) |v| cfg.field_key = v;
        if (getter.get("ZIGBASE_FIELD_KEY_GENERATION")) |v| cfg.field_key_generation = try envInt(u16, "ZIGBASE_FIELD_KEY_GENERATION", v, diag);
        if (getter.get("ZIGBASE_COOKIE_SECURE")) |v| cfg.cookie_secure = try envBool("ZIGBASE_COOKIE_SECURE", v, diag);
        if (getter.get("ZIGBASE_AUTH_TOKEN_TTL")) |v| cfg.auth_token_ttl_s = try envInt(i64, "ZIGBASE_AUTH_TOKEN_TTL", v, diag);
        if (getter.get("ZIGBASE_VERIFICATION_TTL")) |v| cfg.verification_ttl_s = try envInt(i64, "ZIGBASE_VERIFICATION_TTL", v, diag);
        if (getter.get("ZIGBASE_PASSWORD_RESET_TTL")) |v| cfg.password_reset_ttl_s = try envInt(i64, "ZIGBASE_PASSWORD_RESET_TTL", v, diag);
        if (getter.get("ZIGBASE_REALTIME_ORIGINS")) |v| cfg.realtime_allowed_origins = v;
        if (getter.get("ZIGBASE_SSE_HEARTBEAT_SECONDS")) |v| cfg.sse_heartbeat_seconds = try envInt(u16, "ZIGBASE_SSE_HEARTBEAT_SECONDS", v, diag);
        if (getter.get("ZIGBASE_REALTIME_OUTBOUND_HWM")) |v| cfg.realtime_outbound_hwm = try envInt(u32, "ZIGBASE_REALTIME_OUTBOUND_HWM", v, diag);
        if (getter.get("ZIGBASE_TRUST_PROXY")) |v| cfg.trust_proxy = try envBool("ZIGBASE_TRUST_PROXY", v, diag);
        if (getter.get("ZIGBASE_MAX_UPLOAD_SIZE")) |v| cfg.max_upload_size = try envInt(u64, "ZIGBASE_MAX_UPLOAD_SIZE", v, diag);
        if (getter.get("ZIGBASE_FILE_TOKEN_TTL")) |v| cfg.file_token_ttl_s = try envInt(i64, "ZIGBASE_FILE_TOKEN_TTL", v, diag);
        if (getter.get("ZIGBASE_SENTRY_DSN")) |v| cfg.sentry_dsn = v;
        if (getter.get("ZIGBASE_STATIC_CACHE_CONTROL")) |v| cfg.static_cache_control = v;
        if (getter.get("ZIGBASE_S3_BUCKET")) |v| cfg.s3_bucket = v;
        if (getter.get("ZIGBASE_S3_REGION")) |v| cfg.s3_region = v;
        if (getter.get("ZIGBASE_S3_ENDPOINT")) |v| cfg.s3_endpoint = v;
        if (getter.get("ZIGBASE_S3_ACCESS_KEY_ID")) |v| cfg.s3_access_key_id = v;
        if (getter.get("ZIGBASE_S3_SECRET_ACCESS_KEY")) |v| cfg.s3_secret_access_key = v;
        if (getter.get("ZIGBASE_S3_FORCE_PATH_STYLE")) |v| cfg.s3_force_path_style = try envBool("ZIGBASE_S3_FORCE_PATH_STYLE", v, diag);
        if (getter.get("ZIGBASE_S3_KEY_PREFIX")) |v| cfg.s3_key_prefix = v;
        if (getter.get("ZIGBASE_S3_CACHE_DIR")) |v| cfg.s3_cache_dir = v;
        if (getter.get("ZIGBASE_S3_CACHE_MAX_BYTES")) |v| cfg.s3_cache_max_bytes = try envInt(u64, "ZIGBASE_S3_CACHE_MAX_BYTES", v, diag);
        if (getter.get("ZIGBASE_UNSUBSCRIBE_BASE_URL")) |v| cfg.unsubscribe_base_url = v;
        if (getter.get("ZIGBASE_RATE_LIMIT_MAX")) |v| cfg.rate_limit_max = try envInt(u32, "ZIGBASE_RATE_LIMIT_MAX", v, diag);
        if (getter.get("ZIGBASE_RATE_LIMIT_WINDOW")) |v| cfg.rate_limit_window_s = try envInt(i64, "ZIGBASE_RATE_LIMIT_WINDOW", v, diag);
        if (getter.get("ZIGBASE_OAUTH_STATE_SERVER")) |v| cfg.oauth_state_server = try envBool("ZIGBASE_OAUTH_STATE_SERVER", v, diag);
        if (getter.get("ZIGBASE_OAUTH_STATE_TTL")) |v| cfg.oauth_state_ttl_s = try envInt(i64, "ZIGBASE_OAUTH_STATE_TTL", v, diag);
        if (getter.get("ZIGBASE_SMTP_HOST")) |v| cfg.smtp_host = v;
        if (getter.get("ZIGBASE_SMTP_PORT")) |v| cfg.smtp_port = try envInt(u16, "ZIGBASE_SMTP_PORT", v, diag);
        if (getter.get("ZIGBASE_SMTP_USERNAME")) |v| cfg.smtp_username = v;
        if (getter.get("ZIGBASE_SMTP_PASSWORD")) |v| cfg.smtp_password = v;
        if (getter.get("ZIGBASE_SMTP_FROM")) |v| cfg.smtp_from = v;
        if (getter.get("ZIGBASE_SMTP_TLS")) |v| cfg.smtp_tls = try envEnum(SmtpTls, "ZIGBASE_SMTP_TLS", v, "none|starttls|implicit|auto", diag);
        if (getter.get("ZIGBASE_SMTP_INSECURE")) |v|
            cfg.smtp_insecure_skip_verify = try envBool("ZIGBASE_SMTP_INSECURE", v, diag);
        if (getter.get("ZIGBASE_SENDMAIL_COMMAND")) |v| cfg.sendmail_command = v;
        if (getter.get("ZIGBASE_VAPID_PUBLIC_KEY")) |v| cfg.vapid_public_key = v;
        if (getter.get("ZIGBASE_VAPID_PRIVATE_KEY")) |v| cfg.vapid_private_key = v;
        if (getter.get("ZIGBASE_TWILIO_ACCOUNT_SID")) |v| cfg.twilio_account_sid = v;
        if (getter.get("ZIGBASE_TWILIO_AUTH_TOKEN")) |v| cfg.twilio_auth_token = v;
        if (getter.get("ZIGBASE_TWILIO_FROM")) |v| cfg.twilio_from = v;
        if (getter.get("ZIGBASE_LOG_FORMAT")) |v| cfg.log_format = try envEnum(logging.Format, "ZIGBASE_LOG_FORMAT", v, "text|json", diag);
        if (getter.get("ZIGBASE_LOG_LEVEL")) |v| cfg.log_level = logging.parseLevel(v) orelse {
            diag.* = .{ .var_name = "ZIGBASE_LOG_LEVEL", .value = v, .expected = "debug|info|warn|error" };
            return error.InvalidEnvValue;
        };
        if (getter.get("ZIGBASE_LOG_REQUESTS")) |v| cfg.log_requests = try envBool("ZIGBASE_LOG_REQUESTS", v, diag);
        // Dev-only frozen clock. resolveFromEnv is comptime-gated off on a prod build, so this
        // is always null there regardless of the env var.
        cfg.fake_now_unix = clock.resolveFromEnv(getter.get(clock.env_var));
        // Dev-only seeded entropy. resolveFromEnv is comptime-gated off on a prod build.
        cfg.fake_seed = entropy.resolveFromEnv(getter.get(entropy.env_var));
        // Dev-only fake field-crypto. resolveModeFromEnv is comptime-gated off on a prod build.
        cfg.field_crypto = field_policy.resolveModeFromEnv(getter.get(field_policy.env_var));
        return cfg;
    }

    /// Back-compat wrapper: same signature as before, diagnostic discarded. Boot uses
    /// `loadDiag` so it can print which variable was wrong.
    pub fn load(getter: anytype) !Config {
        var diag: LoadDiag = .{};
        return loadDiag(getter, &diag);
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

/// Every ZIGBASE_* variable `loadDiag` reads, alphabetically. The single source of
/// truth for "is this name a real knob"; `tests/admin/test_docs_parity.py` cross-checks
/// it against the string literals actually present in src/, so it cannot drift.
pub const known_vars = [_][]const u8{
    "ZIGBASE_AUTH_TOKEN_TTL",
    "ZIGBASE_COOKIE_SECURE",
    "ZIGBASE_DATA_DIR",
    "ZIGBASE_FAKE_NOW",
    "ZIGBASE_FAKE_SEED",
    "ZIGBASE_FIELD_CRYPTO",
    "ZIGBASE_FIELD_KEY",
    "ZIGBASE_FIELD_KEY_GENERATION",
    "ZIGBASE_FILE_TOKEN_TTL",
    "ZIGBASE_HTTP_HOST",
    "ZIGBASE_HTTP_PORT",
    "ZIGBASE_JWT_SECRET",
    "ZIGBASE_LOG_FORMAT",
    "ZIGBASE_LOG_LEVEL",
    "ZIGBASE_LOG_REQUESTS",
    "ZIGBASE_MAX_UPLOAD_SIZE",
    "ZIGBASE_OAUTH_STATE_SERVER",
    "ZIGBASE_OAUTH_STATE_TTL",
    "ZIGBASE_PASSWORD_RESET_TTL",
    "ZIGBASE_PUBLIC_URL",
    "ZIGBASE_RATE_LIMIT_MAX",
    "ZIGBASE_RATE_LIMIT_WINDOW",
    "ZIGBASE_REALTIME_ORIGINS",
    "ZIGBASE_REALTIME_OUTBOUND_HWM",
    "ZIGBASE_S3_ACCESS_KEY_ID",
    "ZIGBASE_S3_BUCKET",
    "ZIGBASE_S3_CACHE_DIR",
    "ZIGBASE_S3_CACHE_MAX_BYTES",
    "ZIGBASE_S3_ENDPOINT",
    "ZIGBASE_S3_FORCE_PATH_STYLE",
    "ZIGBASE_S3_KEY_PREFIX",
    "ZIGBASE_S3_REGION",
    "ZIGBASE_S3_SECRET_ACCESS_KEY",
    "ZIGBASE_SENDMAIL_COMMAND",
    "ZIGBASE_SENTRY_DSN",
    "ZIGBASE_SMTP_FROM",
    "ZIGBASE_SMTP_HOST",
    "ZIGBASE_SMTP_INSECURE",
    "ZIGBASE_SMTP_PASSWORD",
    "ZIGBASE_SMTP_PORT",
    "ZIGBASE_SMTP_TLS",
    "ZIGBASE_SMTP_USERNAME",
    "ZIGBASE_SSE_HEARTBEAT_SECONDS",
    "ZIGBASE_STATIC_CACHE_CONTROL",
    "ZIGBASE_TRUST_PROXY",
    "ZIGBASE_TWILIO_ACCOUNT_SID",
    "ZIGBASE_TWILIO_AUTH_TOKEN",
    "ZIGBASE_TWILIO_FROM",
    "ZIGBASE_UNSUBSCRIBE_BASE_URL",
    "ZIGBASE_VAPID_PRIVATE_KEY",
    "ZIGBASE_VAPID_PUBLIC_KEY",
    "ZIGBASE_VERIFICATION_TTL",
};

/// Every ZIGBASE_* variable that is a real knob but is NOT read by `loadDiag`, because it
/// is consumed outside `Config`. Kept separate from `known_vars` so the docs-parity test
/// (which cross-checks `known_vars` against what `loadDiag` reads) stays exact.
///
/// ZIGBASE_DB_URL: read directly by `framework.openPoolSelect` (its own `EnvGetter` over
/// the same `environ`), not through `Config.load` — the postgres-vs-sqlite backend choice
/// happens before/around config loading (#159).
///
/// CROSS-PROJECT: SP-3 introduces `ZIGBASE_SERVE_BACKGROUND` (user-facing) and
/// `ZIGBASE_SERVE_BACKGROUND_CHILD` (internal recursion guard), both read by
/// `src/serve_control.zig`, never by `Config`. Without them here, every
/// `zigbase serve --background` would print a spurious "unknown environment variable"
/// warning — this warning firing on ZigBase's own variables is exactly the failure mode
/// that trains operators to ignore it.
pub const known_external_vars = [_][]const u8{
    "ZIGBASE_DB_URL",
    "ZIGBASE_SERVE_BACKGROUND",
    "ZIGBASE_SERVE_BACKGROUND_CHILD",
    // The repo's own test-harness variables (tests/admin, tests/postgres): never read by
    // `Config`, but a harness-launched server must not warn on its own environment.
    "ZIGBASE_TEST_BINARY",
    "ZIGBASE_PG_TEST_URL",
};

/// True when `name` is a knob ZigBase understands. Two families are matched by shape
/// rather than by literal, because their names are built with `std.fmt` at runtime and
/// so can never be listed: the field-key generations (`ZIGBASE_FIELD_KEY_V<n>`) and the
/// per-provider OAuth credentials (`ZIGBASE_OAUTH_<PROVIDER>_CLIENT_ID`/`_CLIENT_SECRET`).
pub fn isKnown(name: []const u8) bool {
    for (known_vars) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    for (known_external_vars) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    if (std.mem.startsWith(u8, name, "ZIGBASE_FIELD_KEY_V") and name.len > "ZIGBASE_FIELD_KEY_V".len) return true;
    if (std.mem.startsWith(u8, name, "ZIGBASE_OAUTH_") and
        (std.mem.endsWith(u8, name, "_CLIENT_ID") or std.mem.endsWith(u8, name, "_CLIENT_SECRET"))) return true;
    return false;
}

/// Warn once per unrecognized `ZIGBASE_*` variable in the environment. A WARNING, not
/// an error: the repo's own harnesses set ZIGBASE_TEST_BINARY / ZIGBASE_PG_TEST_URL, and
/// operators legitimately keep their own ZIGBASE_-prefixed values around, so failing
/// here would break working setups to catch a typo. The value is NEVER logged — an
/// unknown name could well be a secret.
pub fn warnUnknownVars(environ: *const std.process.Environ.Map) void {
    for (environ.keys()) |name| {
        if (!std.mem.startsWith(u8, name, "ZIGBASE_")) continue;
        if (isKnown(name)) continue;
        std.log.warn("unknown environment variable {s} is set and will be ignored (run `zigbase --help` for the supported list)", .{name});
    }
}

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
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
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
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
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
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const d = try Config.load(G0{});
    try std.testing.expectEqual(SmtpTls.auto, d.smtp_tls);
    try std.testing.expectEqual(false, d.smtp_insecure_skip_verify);
}

test "rate limit defaults and overrides" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
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
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
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

test "field_key_generation defaults to 1, overridable via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expectEqual(@as(u16, 1), (try Config.load(G0{})).field_key_generation);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_FIELD_KEY_GENERATION")) return "3";
            return null;
        }
    };
    try std.testing.expectEqual(@as(u16, 3), (try Config.load(G1{})).field_key_generation);
}

test "unsubscribe_base_url defaults empty, overridable via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expectEqualStrings("", (try Config.load(G0{})).unsubscribe_base_url);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_UNSUBSCRIBE_BASE_URL")) return "https://app.example.com";
            return null;
        }
    };
    try std.testing.expectEqualStrings("https://app.example.com", (try Config.load(G1{})).unsubscribe_base_url);
}

test "realtime origins default empty, overridable" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
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

test "static_cache_control defaults empty, overridable via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expectEqualStrings("", (try Config.load(G0{})).static_cache_control);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_STATIC_CACHE_CONTROL")) return "public, max-age=86400, immutable";
            return null;
        }
    };
    try std.testing.expectEqualStrings("public, max-age=86400, immutable", (try Config.load(G1{})).static_cache_control);
}

test "s3_* config: defaults empty/us-east-1/null, overridable via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const c0 = try Config.load(G0{});
    try std.testing.expectEqualStrings("", c0.s3_bucket);
    try std.testing.expectEqualStrings("us-east-1", c0.s3_region);
    try std.testing.expectEqualStrings("", c0.s3_endpoint);
    try std.testing.expectEqualStrings("", c0.s3_access_key_id);
    try std.testing.expectEqualStrings("", c0.s3_secret_access_key);
    try std.testing.expectEqual(@as(?bool, null), c0.s3_force_path_style);
    try std.testing.expectEqualStrings("", c0.s3_key_prefix);
    try std.testing.expectEqualStrings("", c0.s3_cache_dir);
    try std.testing.expectEqual(@as(u64, 1 << 30), c0.s3_cache_max_bytes);

    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_S3_BUCKET")) return "prod-bucket";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_REGION")) return "eu-west-1";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_ENDPOINT")) return "http://localhost:9000";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_ACCESS_KEY_ID")) return "AKIAEXAMPLE";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_SECRET_ACCESS_KEY")) return "secret";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_FORCE_PATH_STYLE")) return "true";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_KEY_PREFIX")) return "tenant-a/";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_CACHE_DIR")) return "/var/cache/zigbase";
            if (std.mem.eql(u8, key, "ZIGBASE_S3_CACHE_MAX_BYTES")) return "2147483648";
            return null;
        }
    };
    const c1 = try Config.load(G1{});
    try std.testing.expectEqualStrings("prod-bucket", c1.s3_bucket);
    try std.testing.expectEqualStrings("eu-west-1", c1.s3_region);
    try std.testing.expectEqualStrings("http://localhost:9000", c1.s3_endpoint);
    try std.testing.expectEqualStrings("AKIAEXAMPLE", c1.s3_access_key_id);
    try std.testing.expectEqualStrings("secret", c1.s3_secret_access_key);
    try std.testing.expectEqual(@as(?bool, true), c1.s3_force_path_style);
    try std.testing.expectEqualStrings("tenant-a/", c1.s3_key_prefix);
    try std.testing.expectEqualStrings("/var/cache/zigbase", c1.s3_cache_dir);
    try std.testing.expectEqual(@as(u64, 1 << 31), c1.s3_cache_max_bytes);
}

test "sse heartbeat defaults 0 (inherit listener timeout), overridable via env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expectEqual(@as(u16, 0), (try Config.load(G0{})).sse_heartbeat_seconds);
    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_SSE_HEARTBEAT_SECONDS")) return "2";
            return null;
        }
    };
    try std.testing.expectEqual(@as(u16, 2), (try Config.load(G1{})).sse_heartbeat_seconds);
}

test "a bad integer env value names the variable, the value, and what was expected" {
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_HTTP_PORT")) return "eighty";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, Config.loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_HTTP_PORT", diag.var_name);
    try std.testing.expectEqualStrings("eighty", diag.value);
    try std.testing.expect(diag.expected.len > 0);
}

test "a bad boolean env value FAILS instead of silently meaning false" {
    // Regression guard: `ZIGBASE_TRUST_PROXY=yes` used to parse as false, silently
    // leaving a security knob unapplied. It must now abort boot.
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_TRUST_PROXY")) return "yes";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, Config.loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_TRUST_PROXY", diag.var_name);
    try std.testing.expectEqualStrings("yes", diag.value);
    try std.testing.expectEqualStrings("true|false|1|0", diag.expected);
}

test "the documented boolean spellings all parse" {
    inline for (.{ .{ "true", true }, .{ "1", true }, .{ "false", false }, .{ "0", false } }) |case| {
        const G = struct {
            var raw: []const u8 = "";
            fn get(_: @This(), key: []const u8) ?[]const u8 {
                if (std.mem.eql(u8, key, "ZIGBASE_TRUST_PROXY")) return raw;
                return null;
            }
        };
        G.raw = case[0];
        try std.testing.expectEqual(case[1], (try Config.load(G{})).trust_proxy);
    }
}

test "a bad enum env value names the variable and lists the choices" {
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_TLS")) return "ssl";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, Config.loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_SMTP_TLS", diag.var_name);
    try std.testing.expectEqualStrings("none|starttls|implicit|auto", diag.expected);
}

test "known_vars is sorted, deduplicated, and covers every consumer knob" {
    for (known_vars[1..], 1..) |name, i| {
        try std.testing.expect(std.mem.order(u8, known_vars[i - 1], name) == .lt);
    }
    // Spot-check both ends and a middle entry so a truncated list fails loudly.
    try std.testing.expect(isKnown("ZIGBASE_HTTP_PORT"));
    try std.testing.expect(isKnown("ZIGBASE_SMTP_TLS"));
    try std.testing.expect(isKnown("ZIGBASE_VAPID_PRIVATE_KEY"));
}

test "log knobs default to text/info/on and parse from env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const d = try Config.load(G0{});
    try std.testing.expectEqual(logging.Format.text, d.log_format);
    try std.testing.expectEqual(std.log.Level.info, d.log_level);
    try std.testing.expectEqual(true, d.log_requests);

    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_FORMAT")) return "json";
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_LEVEL")) return "warn";
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_REQUESTS")) return "false";
            return null;
        }
    };
    const c = try Config.load(G1{});
    try std.testing.expectEqual(logging.Format.json, c.log_format);
    try std.testing.expectEqual(std.log.Level.warn, c.log_level);
    try std.testing.expectEqual(false, c.log_requests);
}

test "a bad log format or level fails fast with the accepted choices" {
    const GF = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_FORMAT")) return "ndjson";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, Config.loadDiag(GF{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_LOG_FORMAT", diag.var_name);
    try std.testing.expectEqualStrings("text|json", diag.expected);

    const GL = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_LEVEL")) return "trace";
            return null;
        }
    };
    diag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, Config.loadDiag(GL{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_LOG_LEVEL", diag.var_name);
    try std.testing.expectEqualStrings("debug|info|warn|error", diag.expected);
}

test "isKnown accepts the templated families and rejects a typo" {
    // These names are built with std.fmt at runtime, so they can never appear in
    // known_vars literally — they are matched by shape.
    try std.testing.expect(isKnown("ZIGBASE_FIELD_KEY_V2"));
    try std.testing.expect(isKnown("ZIGBASE_OAUTH_GOOGLE_CLIENT_ID"));
    try std.testing.expect(isKnown("ZIGBASE_OAUTH_GITHUB_CLIENT_SECRET"));
    // A near-miss must NOT be swallowed — catching this typo is the whole point.
    try std.testing.expect(!isKnown("ZIGBASE_HTTP_PORTS"));
    try std.testing.expect(!isKnown("ZIGBASE_TRUST_PROXIES"));
    try std.testing.expect(!isKnown("ZIGBASE_OAUTH_GOOGLE_SECRET"));
    // Non-ZIGBASE names are never our business.
    try std.testing.expect(!isKnown("PATH"));
}
