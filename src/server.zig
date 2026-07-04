const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const health = @import("api/health.zig");
const collections_api = @import("api/collections.zig");
const records_api = @import("api/records.zig");
const accounts_api = @import("api/accounts.zig");
const senders_api = @import("api/senders.zig");
const mail_inbound = @import("mail/inbound.zig");
const mail_unsub_api = @import("api/mail_unsubscribe.zig");
const auth_api = @import("api/auth.zig");
const auth_methods_api = @import("api/auth_methods.zig");
const magic_link_consume_api = @import("api/magic_link_consume.zig");
const webauthn_register_api = @import("api/webauthn_register.zig");
const oauth_api = @import("api/oauth.zig");
const sessions_api = @import("api/sessions.zig");
const files_api = @import("api/files.zig");
const settings_api = @import("api/settings.zig");
const features_api = @import("api/features.zig");
const state_api = @import("api/state.zig");
const analytics_api = @import("analytics/api.zig");
const realtime_ws = @import("realtime/ws.zig");
const realtime_api = @import("api/realtime.zig");
const files_multipart = @import("files/multipart.zig");
const admin = @import("admin.zig");
const static_files = @import("static_files.zig");
const ApiError = @import("api/error.zig").ApiError;
const auth = @import("auth.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const Ctx = @import("ctx.zig").Ctx;
const crypto = @import("crypto.zig");
const clock = @import("clock.zig");
const tenancy = @import("tenancy/tenancy.zig");

fn healthHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return health.handle(ctx);
}

/// Comptime gates for the built-in route table + admin SPA (R2-2/R2-3). Every
/// field default-true: `Server(.{})` is byte-equivalent to the historical table.
/// INVARIANT (gating policy): no unconditional fn-pointer registration for
/// optional capabilities — fn-pointer tables are where Zig's lazy analysis dies,
/// so every optional subsystem's routes concat in ONLY under its gate.
pub const Gates = struct {
    admin: bool = true,
    analytics: bool = true,
    senders: bool = true,
    mail_webhook: bool = true,
    tenancy: bool = true,
    webauthn: bool = true,
    magic_link: bool = true,
    oauth2: bool = true,
    /// #194 round 2: PUBLIC one-click unsubscribe (RFC 8058). Its own route group and
    /// module (`api/mail_unsubscribe.zig`), gated like senders/mail_webhook on `.mail`.
    mail_unsubscribe: bool = true,
};

// ── §C.1: tunable static Cache-Control via facil.io's OWN state-callback API ────────
// There is no facil.io settings field and no compile-time define for the static
// max-age; the value is a runtime FIOBJ created by http_lib_init at
// FIO_CALL_ON_INITIALIZE (vendored http_internal.c:223) and held in a NON-static C
// global (http_internal.h:81). We link the same compiled facil.io, so declare the
// global + the callback API and swap the FIOBJ exactly once at FIO_CALL_PRE_START —
// which fio_start forces strictly AFTER ON_INITIALIZE (fio.c:3925), so the object
// exists and our replacement is never clobbered. facil.io's header-emission path is
// untouched: http_sendfile2 keeps fiobj_dup-ing this global (http.c:484); it just
// dups our value. Scope (documented): the global affects EVERY http_sendfile2
// response process-wide — in ZigBase that is exactly dir-mode static (record files
// left this path in §B), but a consumer route calling r.sendFile directly inherits
// it too; that IS the knob. Single process; PRE_START runs in the master before any
// worker forks, so the swap is fork-safe.
extern var HTTP_HVALUE_MAX_AGE: zap.fio.FIOBJ;
extern fn fio_state_callback_add(
    event: c_int,
    func: ?*const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
) void;
/// callback_type_e ordinal (vendored fio.h:1578-1608): ON_INITIALIZE=0, PRE_START=1.
const FIO_CALL_PRE_START: c_int = 1;
/// The knob value; static lifetime (points into env/argv/comptime memory that
/// outlives the server — set once in listen(), read once in the callback).
var static_cache_control_value: []const u8 = "";

fn replaceStaticMaxAge(_: ?*anyopaque) callconv(.c) void {
    zap.fio.fiobj_free_wrapped(HTTP_HVALUE_MAX_AGE);
    HTTP_HVALUE_MAX_AGE = zap.fio.fiobj_str_new(static_cache_control_value.ptr, static_cache_control_value.len);
}

/// Type-erased pointer to the running app, set by whichever `Server(gates)` instance calls
/// `listen()`. `realtime/ws.zig`'s `on_upgrade` callback runs outside any particular `Server`
/// instantiation (it doesn't know the comptime `gates` used to build it), so it can't name
/// `Server(gates).instance` — it reads this module-level global instead.
pub var active_app: ?*app_mod.App = null;

pub fn Server(comptime gates: Gates) type {
    return struct {
        const Self = @This();

        /// The comptime-assembled built-in route table for this app's gates.
        pub const routes: []const router.Route = blk: {
            var t: []const router.Route = &.{
                .{ .method = .GET, .pattern = "/api/health", .handler = healthHandler },
                .{ .method = .GET, .pattern = "/api/collections", .handler = collections_api.list },
                .{ .method = .POST, .pattern = "/api/collections", .handler = collections_api.create },
                .{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = collections_api.get },
                .{ .method = .PATCH, .pattern = "/api/collections/:idOrName", .handler = collections_api.update },
                .{ .method = .DELETE, .pattern = "/api/collections/:idOrName", .handler = collections_api.delete },
                .{ .method = .GET, .pattern = "/api/collections/:col/records", .handler = records_api.list },
                .{ .method = .GET, .pattern = "/api/collections/:col/records/:id", .handler = records_api.view },
                .{ .method = .GET, .pattern = "/api/collections/:col/records/:id/abilities", .handler = records_api.abilities },
                .{ .method = .POST, .pattern = "/api/collections/:col/records", .handler = records_api.create },
                .{ .method = .PATCH, .pattern = "/api/collections/:col/records/:id", .handler = records_api.update },
                .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id", .handler = records_api.delete },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth-with-password", .handler = auth_api.authWithPassword },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth-refresh", .handler = auth_api.authRefresh },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth-logout", .handler = auth_api.authLogout },
                .{ .method = .POST, .pattern = "/api/collections/:col/request-verification", .handler = auth_api.requestVerification },
                .{ .method = .POST, .pattern = "/api/collections/:col/confirm-verification", .handler = auth_api.confirmVerification },
                .{ .method = .POST, .pattern = "/api/collections/:col/request-password-reset", .handler = auth_api.requestPasswordReset },
                .{ .method = .POST, .pattern = "/api/collections/:col/confirm-password-reset", .handler = auth_api.confirmPasswordReset },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/initiate", .handler = auth_methods_api.initiate },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/complete", .handler = auth_methods_api.complete },
                // Per-device sessions (spec §F3). Always registered — the handlers branch on the
                // app's `session_store` mode at runtime (`.table` serves the per-device verbs;
                // `.epoch` 404s the two device routes, the DELETE-all works in BOTH), so there is
                // no optional subsystem to gate. NOTE: the `sessions` segment under /auth/ is
                // RESERVED — a custom auth-method slug named "sessions" is rejected at comptime
                // (provision.zig) so a method's /auth/:method/* routes can never shadow these.
                .{ .method = .GET, .pattern = "/api/collections/:col/auth/sessions", .handler = sessions_api.list },
                .{ .method = .DELETE, .pattern = "/api/collections/:col/auth/sessions/:sid", .handler = sessions_api.revoke },
                .{ .method = .DELETE, .pattern = "/api/collections/:col/auth/sessions", .handler = sessions_api.revokeAll },
                .{ .method = .GET, .pattern = "/api/files/:col/:rec/:name", .handler = files_api.serve },
                // HEAD mirrors GET (status/headers/Content-Length, no body) — `serve` itself branches
                // on `ctx.method == .HEAD`; without this route entry a HEAD request never reaches it
                // (router.tryDispatch requires an exact method match) and 404s before the handler runs.
                .{ .method = .HEAD, .pattern = "/api/files/:col/:rec/:name", .handler = files_api.serve },
                .{ .method = .POST, .pattern = "/api/files/token", .handler = files_api.token },
                // Realtime SSE uplink (#188): auth/subscribe/unsubscribe verbs for an EventSource stream.
                // Always registered — realtime (WS + SSE) is not an optional gated subsystem; the clientId
                // is a stream-delivered capability, so unknown/expired/closed ids 404 (non-oracle).
                .{ .method = .POST, .pattern = "/api/realtime/sse/:clientId", .handler = realtime_api.sseUplink },
                // Public, UNAUTHENTICATED feature-state projection (#130). Mounted at the default
                // "/api/state"; the handler 404s when disabled or remapped (a custom path is
                // dispatched dynamically in onRequest). NEVER exposes the superuser settings verbs.
                .{ .method = .GET, .pattern = "/api/state", .handler = state_api.handle },
                .{ .method = .GET, .pattern = "/api/settings", .handler = settings_api.list },
                .{ .method = .GET, .pattern = "/api/settings/:key", .handler = settings_api.get },
                .{ .method = .PUT, .pattern = "/api/settings/:key", .handler = settings_api.put },
                .{ .method = .DELETE, .pattern = "/api/settings/:key", .handler = settings_api.delete },
                .{ .method = .GET, .pattern = "/api/features", .handler = features_api.get },
            };
            if (gates.magic_link) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/collections/:col/auth/magic-link/consume", .handler = magic_link_consume_api.consume },
            };
            if (gates.webauthn) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/begin", .handler = webauthn_register_api.begin },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/finish", .handler = webauthn_register_api.finish },
            };
            if (gates.oauth2) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/collections/:col/auth/oauth2/providers", .handler = oauth_api.oauth2Providers },
                .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id/external-auths/:provider", .handler = oauth_api.unlinkProvider },
            };
            // Multi-tenancy (#156): activate an account scope for browser apps (sets the signed
            // `zb_account` cookie). 404s when tenancy is disabled; 403 without an active membership.
            if (gates.tenancy) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/accounts/:id/activate", .handler = accounts_api.activate },
            };
            // Email (#154): verified per-account sender identities. Tenant-scoped + fail closed (handlers
            // authenticate + resolve the active account internally, like accounts.activate).
            if (gates.senders) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/senders", .handler = senders_api.list },
                .{ .method = .POST, .pattern = "/api/senders", .handler = senders_api.create },
                .{ .method = .POST, .pattern = "/api/senders/:id/verify", .handler = senders_api.verify },
            };
            // Email (#154): inbound bounce/complaint webhook (SES/Postmark). 404 unless a webhook_secret is
            // configured; 401 on a bad signature (constant-time compare); upserts suppressions on success.
            if (gates.mail_webhook) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/mail/webhooks/:provider", .handler = mail_inbound.webhook_handler },
            };
            // Email (#154 round 2): PUBLIC one-click unsubscribe (RFC 8058). 404 unless
            // unsubscribe_base_url is configured; signed-token authorized; GET never mutates.
            if (gates.mail_unsubscribe) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/mail/unsubscribe", .handler = mail_unsub_api.post },
                .{ .method = .GET, .pattern = "/api/mail/unsubscribe", .handler = mail_unsub_api.get },
            };
            // Product analytics (#158): tenant-scoped read API. The raw activity feed and a rollup's
            // summary rows. Both authenticate + fail closed — a member never sees another account's data.
            if (gates.analytics) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/analytics/events", .handler = analytics_api.events },
                .{ .method = .GET, .pattern = "/api/analytics/rollups/:name", .handler = analytics_api.rollups },
            };
            break :blk t;
        };

        app: *app_mod.App,
        host: [:0]const u8,
        port: u16,

        pub var instance: ?*Self = null;

        pub fn listen(self: *Self) !void {
            instance = self;
            active_app = self.app;
            var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .on_upgrade = realtime_ws.handleUpgrade, .log = false, .max_body_size = @intCast(self.app.max_upload_size) });
            if (self.app.static_cache_control) |v| {
                static_cache_control_value = v;
                fio_state_callback_add(FIO_CALL_PRE_START, replaceStaticMaxAge, null);
            }
            try listener.listen();
            std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
            realtime_ws.active = true; // reactor about to run; allow broadcast to publish
            // #159, PR-6b: on Postgres, fan realtime across app instances via LISTEN/NOTIFY. A no-op
            // on SQLite (single-process) — self-gated, so no backend branch is needed here.
            realtime_ws.startRemoteListener(self.app);
            zap.start(.{ .threads = 4, .workers = 1 });
        }

        fn onRequest(r: zap.Request) !void {
            const self = Self.instance.?;
            var arena = std.heap.ArenaAllocator.init(self.app.allocator);
            defer arena.deinit();
            var ctx = http.RequestCtx{
                .method = methodFromZap(r),
                .path = r.path orelse "/",
                .query = r.query orelse "",
                .body = r.body orelse "",
                .allocator = arena.allocator(),
                .app = self.app,
            };
            ctx.authorization = r.getHeader("authorization") orelse "";
            ctx.cookie_header = r.getHeader("cookie") orelse "";
            ctx.csrf_token = r.getHeader("x-csrf-token") orelse "";
            ctx.content_type = r.getHeader("content-type") orelse "";
            ctx.if_none_match = r.getHeader("if-none-match") orelse "";
            ctx.user_agent = r.getHeader("user-agent") orelse "";
            // Client IP for rate limiting (F8). Proxy hop headers (X-Forwarded-For / X-Real-IP)
            // are spoofable on direct exposure, so they are honored ONLY when trust_proxy is set.
            // Otherwise "" — the limiter keys on the submitted identity (never header-spoofable).
            ctx.remote_ip = clientIp(r, self.app.trust_proxy);
            // Generic header lookup for the route-guard `.header` source (#139). `r` lives on this
            // frame for the whole request, so a pointer to it is valid for the lookup thunk's life.
            var zap_req = r;
            ctx.raw_header_ctx = &zap_req;
            ctx.raw_header_fn = zapHeaderLookup;
            ctx.raw_header_set_fn = zapHeaderSet;
            const multipart_err = try applyMultipart(&ctx);
            const resp = blk: {
                if (multipart_err) |er| break :blk er;
                if (comptime gates.admin) {
                    if (std.mem.startsWith(u8, ctx.path, "/_/") or std.mem.eql(u8, ctx.path, "/_"))
                        break :blk admin.serve(&ctx);
                }
                // Built-in API routes win over custom routes.
                const builtin = router.tryDispatch(routes, &ctx) catch {
                    break :blk ApiError.internal().toResponse(arena.allocator()) catch {
                        sendRawEnvelope(r, 500, "{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}");
                        return;
                    };
                };
                if (builtin) |hit| break :blk hit;
                // Public feature-state projection at a CUSTOM-configured path. The default
                // "/api/state" is already in the static table above; this covers a remapped
                // `.features = .{ .public_route = "/custom" }`. Reserved ahead of custom routes
                // so a consumer route cannot shadow it. Disabled (null) → skipped entirely.
                if (self.app.features_public_route) |fp| {
                    if ((ctx.method == .GET or ctx.method == .HEAD) and
                        !std.mem.eql(u8, fp, "/api/state") and
                        std.mem.eql(u8, ctx.path, fp))
                    {
                        break :blk state_api.handle(&ctx) catch ApiError.internal().toResponse(arena.allocator()) catch {
                            sendRawEnvelope(r, 500, "{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}");
                            return;
                        };
                    }
                }
                if (dispatchCustom(&ctx) catch null) |hit| break :blk hit;
                // The whole /api namespace stays JSON — including the bare "/api" path
                // (mirrors the exact-"/_" handling in the admin guard above).
                if (std.meta.activeTag(self.app.static_source) != .none and
                    (ctx.method == .GET or ctx.method == .HEAD) and
                    !std.mem.startsWith(u8, ctx.path, "/api/") and
                    !std.mem.eql(u8, ctx.path, "/api"))
                {
                    if (static_files.serve(self.app.io, &ctx, self.app.static_source, .{
                        .routes = self.app.static_routes,
                        .spa_roots = self.app.spa_roots,
                        .spa_marker_enabled = self.app.spa_marker_enabled,
                        .cache_control = self.app.static_cache_control,
                    }) catch null) |hit| break :blk hit;
                    // Plain-text 404, deliberately NOT the JSON ApiError envelope: static misses are browser-facing, not API responses.
                    break :blk http.Response{ .status = 404, .body = "not found", .content_type = "text/plain; charset=utf-8" };
                }
                break :blk ApiError.notFound().toResponse(arena.allocator()) catch {
                    sendRawEnvelope(r, 500, "{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}");
                    return;
                };
            };
            setZapStatus(r, resp.status);
            for (resp.cookies) |c| {
                r.setCookie(.{
                    .name = c.name,
                    .value = c.value,
                    .path = c.path,
                    .domain = c.domain,
                    .max_age_s = @intCast(c.max_age_s),
                    .secure = c.secure,
                    .http_only = c.http_only,
                    .same_site = switch (c.same_site) {
                        .default => .Default,
                        .lax => .Lax,
                        .strict => .Strict,
                        .none => .None,
                    },
                }) catch {};
            }
            for (resp.extra_headers) |h| r.setHeader(h.name, h.value) catch {};
            if (resp.file) |f| {
                if (f.len) |len| {
                    // ZigBase-owned plan (record files, §B): status + headers were set above;
                    // Content-Type comes from the handler's Response (facil.io's
                    // add_content_type is set-if-missing, so this value wins, exactly once).
                    r.setHeader("content-type", resp.content_type) catch {};
                    sendFileRange(r, self.app.io, f.path, f.offset, len) catch {
                        // Open failure => the existing 404 raw envelope (unchanged semantics).
                        sendRawEnvelope(r, 404, "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}");
                    };
                } else {
                    // Wholesale facil.io delegation (dir-mode static): mime, ETag, 304,
                    // `.gz` sidecar, Range are ALL facil.io's (§A.3) — byte-identical to today.
                    r.sendFile(f.path) catch {
                        sendRawEnvelope(r, 404, "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}");
                    };
                }
                return;
            }
            r.setHeader("content-type", resp.content_type) catch {};
            r.sendBody(resp.body) catch {};
        }
    };
}

fn methodFromZap(r: zap.Request) http.Method {
    return switch (r.methodAsEnum()) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        .HEAD => .HEAD,
        else => .UNKNOWN,
    };
}

/// Pure core of client-IP resolution (F8), testable without a zap.Request.
/// `X-Forwarded-For`/`X-Real-IP` are attacker-controlled on direct exposure, so
/// they are honored ONLY when `trust_proxy` is true. Returns "" when proxy headers
/// are not trusted or absent; the limiter then keys on the submitted identity (still
/// useful, and never spoofable via a forged header).
fn clientIpFrom(trust_proxy: bool, xff: ?[]const u8, xri: ?[]const u8) []const u8 {
    if (!trust_proxy) return "";
    if (xff) |v| {
        // "client, proxy1, proxy2" — take the first, trimmed.
        const first = if (std.mem.indexOfScalar(u8, v, ',')) |c| v[0..c] else v;
        const trimmed = std.mem.trim(u8, first, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    if (xri) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// Client IP for rate-limit keying. zap 0.10.6 exposes no socket-peer accessor on
/// Request, so proxy headers are the only source — and they're trusted only when
/// `trust_proxy` is set (see `clientIpFrom`).
fn clientIp(r: zap.Request, trust_proxy: bool) []const u8 {
    return clientIpFrom(trust_proxy, r.getHeader("x-forwarded-for"), r.getHeader("x-real-ip"));
}

test "clientIpFrom ignores X-Forwarded-For/X-Real-IP unless trust_proxy is set (F8)" {
    // Default (untrusted): spoofable headers are ignored entirely.
    try std.testing.expectEqualStrings("", clientIpFrom(false, "1.2.3.4", null));
    try std.testing.expectEqualStrings("", clientIpFrom(false, "1.2.3.4, 5.6.7.8", "9.9.9.9"));
    try std.testing.expectEqualStrings("", clientIpFrom(false, null, "9.9.9.9"));
    // Trusted proxy: first XFF hop wins, else X-Real-IP, else "".
    try std.testing.expectEqualStrings("1.2.3.4", clientIpFrom(true, "1.2.3.4, 5.6.7.8", "9.9.9.9"));
    try std.testing.expectEqualStrings("9.9.9.9", clientIpFrom(true, null, "9.9.9.9"));
    try std.testing.expectEqualStrings("1.2.3.4", clientIpFrom(true, " 1.2.3.4 ", null));
    try std.testing.expectEqualStrings("", clientIpFrom(true, null, null));
}

/// Live header lookup-by-name for `RequestCtx.header` (the route-guard `.header` source).
/// facil.io normalizes header names to lowercase, so the requested name is lowercased into a
/// bounded stack buffer before the lookup (header names are short; an over-long name falls
/// back to the raw name, which simply won't match).
fn zapHeaderLookup(p: *anyopaque, name: []const u8) ?[]const u8 {
    const req: *zap.Request = @ptrCast(@alignCast(p));
    var buf: [256]u8 = undefined;
    if (name.len <= buf.len) {
        const lower = std.ascii.lowerString(buf[0..name.len], name);
        return req.getHeader(lower);
    }
    return req.getHeader(name);
}

/// §A.2 write-back: replace a REQUEST header in facil.io's header hash.
/// fiobj_hash_set (zap fio.zig:137) dups key+value on insert and frees any replaced
/// value; it consumes our value reference, and we free our key reference ourselves.
fn zapHeaderSet(ctx: *anyopaque, name: []const u8, value: []const u8) void {
    const rp: *zap.Request = @ptrCast(@alignCast(ctx));
    const key = zap.fio.fiobj_str_new(name.ptr, name.len);
    const val = zap.fio.fiobj_str_new(value.ptr, value.len);
    _ = zap.fio.fiobj_hash_set(rp.h.*.headers, key, val);
    zap.fio.fiobj_free_wrapped(key);
}

/// Map an HTTP status code to zap's `StatusCode` enum.
///
/// `zap.http.StatusCode` is non-exhaustive, so `std.enums.fromInt`/`std.meta.intToEnum`
/// would pass *any* integer straight through (or, for the latter, no longer exists in
/// Zig 0.16). Instead we match `status` against the enum's *named* fields, so every
/// standard code zap defines is recognized — not a hand-maintained subset that silently
/// turns omitted-but-valid codes (e.g. 401 auth rejections, 307 magic-link redirects,
/// 405, 415) into 500s. Anything zap doesn't name falls back to 500.
fn statusToCode(status: u16) zap.http.StatusCode {
    inline for (std.meta.fields(zap.http.StatusCode)) |field| {
        if (field.value == status) return @field(zap.http.StatusCode, field.name);
    }
    return .internal_server_error;
}

test "statusToCode maps named codes and falls back to 500 for unknown" {
    try std.testing.expectEqual(zap.http.StatusCode.ok, statusToCode(200));
    // Previously omitted from the manual map -> regression guard.
    try std.testing.expectEqual(zap.http.StatusCode.unauthorized, statusToCode(401));
    try std.testing.expectEqual(zap.http.StatusCode.temporary_redirect, statusToCode(307));
    try std.testing.expectEqual(zap.http.StatusCode.gone, statusToCode(410));
    try std.testing.expectEqual(zap.http.StatusCode.bad_gateway, statusToCode(502));
    // Codes the manual list never had but zap names are now handled too.
    try std.testing.expectEqual(zap.http.StatusCode.method_not_allowed, statusToCode(405));
    try std.testing.expectEqual(zap.http.StatusCode.unsupported_media_type, statusToCode(415));
    // Genuinely unknown codes fall back to a safe 500.
    try std.testing.expectEqual(zap.http.StatusCode.internal_server_error, statusToCode(799));
}

fn setZapStatus(r: zap.Request, status: u16) void {
    r.setStatus(statusToCode(status));
}

fn forbiddenResp(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
}

/// Merge a Ctx's deferred `pending_cookies`/`pending_headers` onto a handler's Response.
/// Returns `resp` untouched when nothing was accumulated; otherwise arena-dups the UNION
/// of the handler-set values and the deferred ones (handler-set first, deferred appended),
/// keeping the raw `http.Response` literal fully usable alongside the ergonomic accumulators.
fn mergePending(alloc: std.mem.Allocator, cx: *Ctx, resp: http.Response) !http.Response {
    if (cx.pending_cookies.items.len == 0 and cx.pending_headers.items.len == 0) return resp;
    var out = resp;
    if (cx.pending_cookies.items.len > 0) {
        const merged = try alloc.alloc(http.Cookie, resp.cookies.len + cx.pending_cookies.items.len);
        @memcpy(merged[0..resp.cookies.len], resp.cookies);
        @memcpy(merged[resp.cookies.len..], cx.pending_cookies.items);
        out.cookies = merged;
    }
    if (cx.pending_headers.items.len > 0) {
        const merged = try alloc.alloc(http.Header, resp.extra_headers.len + cx.pending_headers.items.len);
        @memcpy(merged[0..resp.extra_headers.len], resp.extra_headers);
        @memcpy(merged[resp.extra_headers.len..], cx.pending_headers.items);
        out.extra_headers = merged;
    }
    return out;
}

/// The ordered, declarative route-guard chain (#139/#142), run for a matched custom route
/// AFTER the AuthLevel check and BEFORE the handler. Returns the FIRST guard's deny Response,
/// or null to proceed. New guard kinds slot in as additional ordered steps here, keeping the
/// chain extensible without touching `dispatchCustom`'s control flow.
///   1. AuthLevel — enforced by the caller (the existing switch in `dispatchCustom`).
///   2. path_secret — constant-time secret check; bare-404 on miss (no existence oracle).
///   3. rate_limit — per-route bucket; 429 + Retry-After on deny.
fn runRouteGuards(cx: *Ctx, ctx: *http.RequestCtx, rt: events.RuntimeRoute) !?http.Response {
    if (rt.auth_guard) |g| {
        if (try guardPathSecret(cx, ctx, g)) |deny| return deny;
    }
    if (try guardRateLimit(cx, ctx, rt)) |deny| return deny;
    return null;
}

/// Guard step (2): resolve the stored secret (kv/settings via `ctx.kv().get`, config static),
/// read the submitted value from the configured location (path/query/header), and compare in
/// CONSTANT TIME (`crypto.timingSafeEql`). On any mismatch (including an empty/absent stored
/// secret — fail closed) return a BARE 404 by default so a wrong secret is indistinguishable
/// from a non-existent route (no oracle); `.on_mismatch = .forbidden` opts into an explicit 403.
fn guardPathSecret(cx: *Ctx, ctx: *http.RequestCtx, g: events.RouteAuthGuard) !?http.Response {
    switch (g) {
        .path_secret => |ps| {
            const stored: []const u8 = switch (ps.source) {
                .config => |s| s,
                // kv/settings live in the same `_kv` store; a read error/absence ⇒ "" (fail closed).
                .kv => |k| (cx.kv().get(k) catch null) orelse "",
                .settings => |k| (cx.kv().get(k) catch null) orelse "",
            };
            const submitted: []const u8 = switch (ps.in) {
                .path => ctx.param(ps.param) orelse "",
                .query => (try cx.query()).get(ps.param) orelse "",
                .header => ctx.header(ps.param) orelse "",
            };
            // Empty stored secret never matches; constant-time compare otherwise.
            if (stored.len > 0 and crypto.timingSafeEql(submitted, stored)) return null;
            return switch (ps.on_mismatch) {
                .not_found => try ApiError.notFound().toResponse(ctx.allocator),
                .forbidden => try forbiddenResp(ctx),
            };
        },
    }
}

/// Guard step (3): per-route rate limit (#142). Only `.custom` engages a bucket — `.default`
/// and `.off` leave the route unthrottled (routes are opt-in for limiting). The bucket is
/// keyed `route:<pattern>:…` by the app-supplied `rate_limit_key(ctx)` when present, else by
/// the client IP (`ctx.remote_ip`, which honors `ZIGBASE_TRUST_PROXY` via `clientIpFrom` — a
/// spoofed X-Forwarded-For yields "" when proxies are untrusted, so it cannot evade/poison a
/// per-IP bucket). On deny: 429 + `Retry-After: <window_s>`.
fn guardRateLimit(cx: *Ctx, ctx: *http.RequestCtx, rt: events.RuntimeRoute) !?http.Response {
    const c = switch (rt.rate_limit) {
        .custom => |c| c,
        else => return null, // .default / .off ⇒ no per-route bucket
    };
    const app = ctx.app orelse return null;
    const limiter = app.rate_limiter orelse return null;
    const key = if (rt.rate_limit_key) |kf| blk: {
        if (kf(cx)) |subject| break :blk try std.fmt.allocPrint(ctx.allocator, "route:{s}:key:{s}", .{ rt.pattern, subject });
        break :blk try std.fmt.allocPrint(ctx.allocator, "route:{s}:ip:{s}", .{ rt.pattern, ctx.remote_ip });
    } else try std.fmt.allocPrint(ctx.allocator, "route:{s}:ip:{s}", .{ rt.pattern, ctx.remote_ip });
    if (limiter.allowCustom(key, clock.nowUnix(app.io), c.max, c.window_s)) return null;
    const retry = try std.fmt.allocPrint(ctx.allocator, "{d}", .{c.window_s});
    var resp = try (ApiError{ .status = 429, .message = "Too many requests. Try again later." }).toResponse(ctx.allocator);
    resp.extra_headers = try ctx.allocator.dupe(http.Header, &.{.{ .name = "Retry-After", .value = retry }});
    return resp;
}

/// Try the consumer's custom routes (after built-ins). Resolves auth on a fresh reader,
/// enforces the route's AuthLevel, then calls the handler. Returns null if no custom route
/// matches the path+method. A handler error routes to the error backstop and yields 500.
fn dispatchCustom(ctx: *http.RequestCtx) anyerror!?http.Response {
    const app = ctx.app orelse return null;
    const d = app.dispatch orelse return null;
    if (d.routes.len == 0) return null;
    for (d.routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try router.matchPath(ctx.allocator, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            // Resolve auth on a fresh read-only connection (never the writer lock).
            var reader = app.pool.acquireReader() catch return try ApiError.internal().toResponse(ctx.allocator);
            defer app.pool.releaseReader(&reader);
            const authed = auth.authenticate(app.io, ctx.allocator, app, ctx, &reader) catch null;
            switch (rt.auth) {
                .public => {},
                .authed => if (authed == null) return try (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator),
                .superuser => if (authed == null or !authed.?.is_superuser) return try forbiddenResp(ctx),
            }
            var rctx = request.RequestContext{
                .auth = if (authed) |a| a.record else null,
                .is_superuser = if (authed) |a| a.is_superuser else false,
                .collection = if (authed) |a| a.collection else "",
                .method = @tagName(ctx.method),
                .session_id = if (authed) |a| a.sid else "",
            };
            // Resolve the active tenant scope via tenancy.resolveRequest, the same
            // chokepoint api/records.zig and api/files.zig call, so a custom route's
            // `ctx.track`/`ctx.can`/any tenant-scoped ability check sees the caller's
            // verified active account instead of always stamping account "". (Note:
            // api/senders.zig and analytics/api.zig do NOT call resolveRequest — they
            // share its underlying primitives but apply their own scope policy.)
            // Anonymous requests (authed == null) still get `tenancy_enabled`/
            // `role_ranking` copied (an unresolved, fail-closed scope), matching an
            // anonymous REST request.
            if (authed) |a| {
                tenancy.resolveRequest(ctx, &reader, app, a, &rctx);
            } else {
                rctx.tenancy_enabled = app.tenancy.enabled;
                rctx.role_ranking = app.role_ranking;
            }
            var cx = Ctx{ .app = app, .arena = ctx.allocator, .rctx = rctx, .request = ctx, .bound_conn = null };
            defer cx.deinit();
            // Ordered route-guard chain (#139/#142): path-secret + per-route rate limit, run
            // AFTER the AuthLevel check above and BEFORE the handler. The first guard to deny
            // returns its response (bare-404 / 403 / 429) and the handler never runs.
            if (try runRouteGuards(&cx, ctx, rt)) |deny| return deny;
            // One chokepoint for typed thunks + untyped handlers: any cookies/headers a
            // handler accumulated via `ctx.setCookie`/`ctx.addHeader` (e.g. `ctx.subjectCookie`)
            // are merged onto the Response in BOTH the success and the error path, so a
            // deferred Set-Cookie survives even when the handler returns an error.
            const resp = rt.handler(&cx) catch |e| {
                // Map the error to a response via A1's Ctx.errorResponse (error.NotFound -> 404,
                // error.Forbidden -> 403, error.Handled -> stashed status, etc.) instead of the
                // old always-500 mapping. Only GENUINE server errors (mapped status >= 500) go to
                // the consumer onError + Sentry/log backstop: a handler returning a deliberate 4xx
                // (NotFound/Forbidden/ctx.fail) is ordinary client-error control flow, not an
                // incident, so it must not emit a Sentry event.
                const er = cx.errorResponse(e);
                if (er.status >= 500) {
                    var err_ev = events.ErrorEvent{ .app = app, .ctx = &rctx, .err = e, .phase = .request, .message = @errorName(e) };
                    events.dispatchError(app, app.dispatch, &err_ev);
                }
                return try mergePending(ctx.allocator, &cx, er);
            };
            return try mergePending(ctx.allocator, &cx, resp);
        }
    }
    return null;
}

test "dispatchCustom: deliberate 4xx is NOT reported to onError; genuine 5xx is" {
    const db = @import("db.zig");
    const App = app_mod.App;
    const sentry = @import("sentry.zig");

    const H = struct {
        var on_error_calls: usize = 0;
        // Untyped handler returning a client-error -> A1 maps to 404 (control flow, no incident).
        fn notFound(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return error.NotFound;
        }
        // Untyped handler returning an unmapped error -> A1 maps to 500 (genuine server error).
        fn boom(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return error.SomethingWeird;
        }
        fn onErr(ev: *events.ErrorEvent) void {
            _ = ev;
            on_error_calls += 1;
        }
    };
    H.on_error_calls = 0;

    // A file-backed pool so acquireReader() succeeds; the `.public` routes never query it
    // (authenticate returns null with no token before touching the DB).
    const ga = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();

    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    const a = arena.allocator();

    const route_table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/nf", .handler = H.notFound, .auth = .public },
        .{ .method = .GET, .pattern = "/api/boom", .handler = H.boom, .auth = .public },
    };
    const dispatch = events.Dispatch{ .routes = &route_table, .on_error = H.onErr };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &pool, .dispatch = &dispatch };

    // DSN-less backstop logs via std.log.err (which the test runner would count as a
    // failure); route it to a no-op sink so dispatchError stays observable-but-silent.
    sentry.log_sink = struct {
        fn sink(_: []const u8) void {}
    }.sink;
    defer sentry.log_sink = null;

    // 1. Deliberate 4xx: 404 response, onError NOT fired.
    var nf_ctx = http.RequestCtx{ .method = .GET, .path = "/api/nf", .allocator = a, .app = &app };
    const nf = (try dispatchCustom(&nf_ctx)).?;
    try std.testing.expectEqual(@as(u16, 404), nf.status);
    try std.testing.expectEqual(@as(usize, 0), H.on_error_calls);

    // 2. Genuine 5xx: 500 response, onError fired exactly once.
    var boom_ctx = http.RequestCtx{ .method = .GET, .path = "/api/boom", .allocator = a, .app = &app };
    const boom = (try dispatchCustom(&boom_ctx)).?;
    try std.testing.expectEqual(@as(u16, 500), boom.status);
    try std.testing.expectEqual(@as(usize, 1), H.on_error_calls);
}

test "dispatchCustom merges ctx.setCookie/addHeader on success AND error paths (non-exclusive)" {
    const db = @import("db.zig");
    const App = app_mod.App;

    const H = struct {
        // Success: queue a deferred cookie+header AND set a cookie on the Response literal.
        fn ok(cx: *Ctx) anyerror!http.Response {
            try cx.setCookie(.{ .name = "sid", .value = "minted", .secure = false });
            try cx.addHeader(.{ .name = "X-Test", .value = "1" });
            return .{ .status = 200, .body = "{}", .cookies = &.{.{ .name = "handler", .value = "set" }} };
        }
        // Error: a deferred cookie must still reach the mapped error Response.
        fn err(cx: *Ctx) anyerror!http.Response {
            try cx.setCookie(.{ .name = "sid", .value = "on-error", .secure = false });
            return error.NotFound;
        }
    };

    const ga = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    const a = arena.allocator();

    const route_table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/ok", .handler = H.ok, .auth = .public },
        .{ .method = .GET, .pattern = "/api/err", .handler = H.err, .auth = .public },
    };
    const dispatch = events.Dispatch{ .routes = &route_table };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &pool, .dispatch = &dispatch };

    // Success path: the handler's own cookie is kept, the deferred cookie is appended, and
    // the deferred header lands in extra_headers (union; raw Response stays usable).
    var ok_ctx = http.RequestCtx{ .method = .GET, .path = "/api/ok", .allocator = a, .app = &app };
    const ok = (try dispatchCustom(&ok_ctx)).?;
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    try std.testing.expectEqual(@as(usize, 2), ok.cookies.len);
    try std.testing.expectEqualStrings("handler", ok.cookies[0].name);
    try std.testing.expectEqualStrings("sid", ok.cookies[1].name);
    try std.testing.expectEqualStrings("minted", ok.cookies[1].value);
    try std.testing.expectEqual(@as(usize, 1), ok.extra_headers.len);
    try std.testing.expectEqualStrings("X-Test", ok.extra_headers[0].name);

    // Error path: the mapped 404 still carries the deferred Set-Cookie.
    var err_ctx = http.RequestCtx{ .method = .GET, .path = "/api/err", .allocator = a, .app = &app };
    const er = (try dispatchCustom(&err_ctx)).?;
    try std.testing.expectEqual(@as(u16, 404), er.status);
    try std.testing.expectEqual(@as(usize, 1), er.cookies.len);
    try std.testing.expectEqualStrings("sid", er.cookies[0].name);
    try std.testing.expectEqualStrings("on-error", er.cookies[0].value);
}

/// Parse a multipart/form-data body into ctx.form_fields/ctx.files.
/// Returns a 400 response for a malformed multipart body — handled here, at the
/// layer that owns body parsing, so every multipart endpoint (current and future)
/// gets the same clear error instead of falling through to the JSON parser's
/// misleading "Invalid JSON body.". OutOfMemory propagates; it must never
/// masquerade as a client error.
fn applyMultipart(ctx: *http.RequestCtx) error{OutOfMemory}!?http.Response {
    if (!std.mem.startsWith(u8, ctx.content_type, "multipart/form-data")) return null;
    // Hand-rolled parser over the raw body: facil.io's param parsing type-guesses
    // multipart values (text "123" -> int), so it must never see this body.
    const ex = files_multipart.parse(ctx.allocator, ctx.content_type, ctx.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadMultipart => return try ApiError.badRequest("Invalid multipart body.").toResponse(ctx.allocator),
    };
    ctx.form_fields = ex.form_fields;
    ctx.files = ex.files;
    return null;
}

test "applyMultipart: malformed multipart body -> 400 'Invalid multipart body.', not the JSON-body error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "multipart/form-data; boundary=XB",
        .body = "--XB\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv", // never terminated
    };
    const resp = (try applyMultipart(&ctx)).?;
    try std.testing.expectEqual(@as(u16, 400), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid multipart body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid JSON body.") == null);
    try std.testing.expect(ctx.form_fields == null);
}

test "applyMultipart: valid multipart populates ctx and returns null; non-multipart is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "multipart/form-data; boundary=XB",
        .body = "--XB\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n--XB--\r\n",
    };
    try std.testing.expect((try applyMultipart(&ctx)) == null);
    try std.testing.expectEqualStrings("v", ctx.form_fields.?.object.get("a").?.string);

    var jctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "application/json",
        .body = "{}",
    };
    try std.testing.expect((try applyMultipart(&jctx)) == null);
    try std.testing.expect(jctx.form_fields == null);
}

// ---------------------------------------------------------------------------
// Route-guard pipeline (#139 path-secret + #142 per-route rate limit) tests.
// ---------------------------------------------------------------------------

/// Minimal file-backed pool + arena harness for the guard tests. `migrate=true` runs
/// migrations so `_kv` exists (kv/settings source); config-source/rate-limit tests don't need it.
const GuardEnv = struct {
    const db = @import("db.zig");
    const migrations = @import("migrations.zig");

    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,

    fn init(migrate: bool) !GuardEnv {
        const ga = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(db_path);
        var pool = try db.Pool.init(ga, std.testing.io, db_path);
        errdefer pool.deinit();
        if (migrate) {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            try migrations.run(w);
        }
        return .{ .tmp = tmp, .db_path = db_path, .pool = pool, .arena = std.heap.ArenaAllocator.init(ga) };
    }

    fn deinit(self: *GuardEnv) void {
        const ga = std.testing.allocator;
        self.arena.deinit();
        self.pool.deinit();
        ga.free(self.db_path);
        self.tmp.cleanup();
    }
};

test "guard path_secret: correct config secret -> handler runs (200); wrong/missing -> bare 404" {
    const App = app_mod.App;
    const H = struct {
        fn ok(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return .{ .status = 200, .body = "{\"ok\":true}" };
        }
    };
    var env = try GuardEnv.init(false);
    defer env.deinit();
    const a = env.arena.allocator();

    const table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/s/:token", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "token", .source = .{ .config = "s3cr3t" } } } },
    };
    const dispatch = events.Dispatch{ .routes = &table };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool, .dispatch = &dispatch };

    // Correct secret: 200.
    var ok_ctx = http.RequestCtx{ .method = .GET, .path = "/api/s/s3cr3t", .allocator = a, .app = &app };
    const ok = (try dispatchCustom(&ok_ctx)).?;
    try std.testing.expectEqual(@as(u16, 200), ok.status);

    // Wrong secret: a BARE 404 (the canonical not-found envelope — no oracle, no 403/401).
    var bad_ctx = http.RequestCtx{ .method = .GET, .path = "/api/s/nope", .allocator = a, .app = &app };
    const bad = (try dispatchCustom(&bad_ctx)).?;
    try std.testing.expectEqual(@as(u16, 404), bad.status);
    try std.testing.expect(std.mem.indexOf(u8, bad.body, "Not found.") != null);
}

test "guard path_secret: on_mismatch=.forbidden -> 403; query and header sources" {
    const App = app_mod.App;
    const H = struct {
        fn ok(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    var env = try GuardEnv.init(false);
    defer env.deinit();
    const a = env.arena.allocator();

    const table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/forbid", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "s", .source = .{ .config = "open" }, .in = .query, .on_mismatch = .forbidden } } },
        .{ .method = .GET, .pattern = "/api/q", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "k", .source = .{ .config = "qsecret" }, .in = .query } } },
        .{ .method = .GET, .pattern = "/api/h", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "x-secret", .source = .{ .config = "hsecret" }, .in = .header } } },
    };
    const dispatch = events.Dispatch{ .routes = &table };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool, .dispatch = &dispatch };

    // Forbidden mode: a mismatch is an explicit 403, not a 404.
    var f_ctx = http.RequestCtx{ .method = .GET, .path = "/api/forbid", .query = "s=wrong", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 403), (try dispatchCustom(&f_ctx)).?.status);

    // Query source: correct value passes (200), wrong 404.
    var q_ok = http.RequestCtx{ .method = .GET, .path = "/api/q", .query = "k=qsecret", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 200), (try dispatchCustom(&q_ok)).?.status);
    var q_bad = http.RequestCtx{ .method = .GET, .path = "/api/q", .query = "k=nah", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 404), (try dispatchCustom(&q_bad)).?.status);

    // Header source (case-insensitive name match via RequestCtx.headers).
    const hdrs = [_]http.Param{.{ .key = "X-Secret", .value = "hsecret" }};
    var h_ok = http.RequestCtx{ .method = .GET, .path = "/api/h", .allocator = a, .app = &app, .headers = &hdrs };
    try std.testing.expectEqual(@as(u16, 200), (try dispatchCustom(&h_ok)).?.status);
    var h_bad = http.RequestCtx{ .method = .GET, .path = "/api/h", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 404), (try dispatchCustom(&h_bad)).?.status);
}

test "guard path_secret: kv source reads the stored secret (#139)" {
    const App = app_mod.App;
    const Data = @import("data.zig").Data;
    const H = struct {
        fn ok(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    var env = try GuardEnv.init(true); // migrate -> _kv exists
    defer env.deinit();
    const a = env.arena.allocator();

    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    // Seed the kv secret.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try (Data{ .app = &app, .conn = w, .io = app.io, .alloc = a }).kvSet("deploy_secret", "kv-value");
    }

    const table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/kv/:tok", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "tok", .source = .{ .kv = "deploy_secret" } } } },
    };
    const dispatch = events.Dispatch{ .routes = &table };
    app.dispatch = &dispatch;

    var ok_ctx = http.RequestCtx{ .method = .GET, .path = "/api/kv/kv-value", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 200), (try dispatchCustom(&ok_ctx)).?.status);
    var bad_ctx = http.RequestCtx{ .method = .GET, .path = "/api/kv/stale", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 404), (try dispatchCustom(&bad_ctx)).?.status);

    // Rotation: overwrite the secret -> the old value now 404s (old links break).
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try (Data{ .app = &app, .conn = w, .io = app.io, .alloc = a }).kvSet("deploy_secret", "rotated");
    }
    var stale = http.RequestCtx{ .method = .GET, .path = "/api/kv/kv-value", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 404), (try dispatchCustom(&stale)).?.status);
    var fresh = http.RequestCtx{ .method = .GET, .path = "/api/kv/rotated", .allocator = a, .app = &app };
    try std.testing.expectEqual(@as(u16, 200), (try dispatchCustom(&fresh)).?.status);
}

test "guard rate_limit: per-route bucket, 429 + Retry-After, IP keying, key fn (#142)" {
    const App = app_mod.App;
    const ratelimit = @import("ratelimit.zig");
    const H = struct {
        fn ok(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return .{ .status = 200, .body = "{}" };
        }
        var key_val: ?[]const u8 = null;
        fn keyFn(cx: *Ctx) ?[]const u8 {
            _ = cx;
            return key_val;
        }
    };
    var env = try GuardEnv.init(false);
    defer env.deinit();
    const a = env.arena.allocator();

    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 0, 60); // global off; per-route via allowCustom
    defer rl.deinit();

    const table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/lim", .handler = H.ok, .auth = .public, .rate_limit = .{ .custom = .{ .max = 2, .window_s = 30 } } },
        .{ .method = .GET, .pattern = "/api/keyed", .handler = H.ok, .auth = .public, .rate_limit = .{ .custom = .{ .max = 1, .window_s = 30 } }, .rate_limit_key = H.keyFn },
    };
    const dispatch = events.Dispatch{ .routes = &table };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool, .dispatch = &dispatch, .rate_limiter = &rl };

    // Two allowed for IP 1.1.1.1, the third denied with 429 + Retry-After: 30.
    const ip1 = "1.1.1.1";
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/lim", ip1)).status);
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/lim", ip1)).status);
    const denied = try dispatchIp(a, &app, "/api/lim", ip1);
    try std.testing.expectEqual(@as(u16, 429), denied.status);
    try std.testing.expectEqual(@as(usize, 1), denied.extra_headers.len);
    try std.testing.expectEqualStrings("Retry-After", denied.extra_headers[0].name);
    try std.testing.expectEqualStrings("30", denied.extra_headers[0].value);

    // A DIFFERENT IP has its own bucket (isolation) — immediately allowed.
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/lim", "2.2.2.2")).status);

    // rate_limit_key wins over IP: same key from different IPs shares ONE bucket (max=1).
    H.key_val = "tenant-A";
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/keyed", "9.9.9.9")).status);
    try std.testing.expectEqual(@as(u16, 429), (try dispatchIp(a, &app, "/api/keyed", "8.8.8.8")).status);
    // A different key -> fresh budget despite the shared route.
    H.key_val = "tenant-B";
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/keyed", "8.8.8.8")).status);
}

/// Dispatch a GET to `path` with a given remote_ip (already resolved as server.zig would,
/// post trust_proxy) and return the response. Distinct IPs prove per-IP bucket isolation; ""
/// proves the untrusted-proxy fallback (a spoofed XFF resolves to "" so it cannot evade or
/// poison another IP's bucket).
fn dispatchIp(a: std.mem.Allocator, app: *app_mod.App, path: []const u8, ip: []const u8) !http.Response {
    var c = http.RequestCtx{ .method = .GET, .path = path, .allocator = a, .app = app, .remote_ip = ip };
    return (try dispatchCustom(&c)).?;
}

test "guard chain: path_secret AND rate_limit composed on one route" {
    const App = app_mod.App;
    const ratelimit = @import("ratelimit.zig");
    const H = struct {
        fn ok(cx: *Ctx) anyerror!http.Response {
            _ = cx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    var env = try GuardEnv.init(false);
    defer env.deinit();
    const a = env.arena.allocator();
    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 0, 60);
    defer rl.deinit();

    const table = [_]events.RuntimeRoute{
        .{ .method = .GET, .pattern = "/api/both/:tok", .handler = H.ok, .auth = .public, .auth_guard = .{ .path_secret = .{ .param = "tok", .source = .{ .config = "open" } } }, .rate_limit = .{ .custom = .{ .max = 1, .window_s = 30 } } },
    };
    const dispatch = events.Dispatch{ .routes = &table };
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool, .dispatch = &dispatch, .rate_limiter = &rl };

    // Wrong secret 404s BEFORE the rate limiter is consulted (secret guard is ordered first):
    // it must not consume the budget, so a subsequent correct call still succeeds.
    try std.testing.expectEqual(@as(u16, 404), (try dispatchIp(a, &app, "/api/both/wrong", "5.5.5.5")).status);
    // Correct secret + within budget: 200.
    try std.testing.expectEqual(@as(u16, 200), (try dispatchIp(a, &app, "/api/both/open", "5.5.5.5")).status);
    // Correct secret but over the per-route budget: 429.
    try std.testing.expectEqual(@as(u16, 429), (try dispatchIp(a, &app, "/api/both/open", "5.5.5.5")).status);
}

/// §B transport: transmit `[offset, offset+len)` of `path` through facil.io's PUBLIC
/// `http_sendfile(h, fd, length, offset)` extern (zap src/fio.zig:426) — the same fd
/// primitive `http_sendfile2` itself finishes through, so ZigBase reimplements no
/// socket/streaming code. facil.io takes ownership of the fd (closes it on every path,
/// http.c:367-377) and adds Content-Length / Content-Type / Date ONLY-IF-MISSING, so
/// every header the handler set goes on the wire exactly once (the §B.1 double-header
/// analysis). The zap handle is consumed on success — mark the request finished so
/// zap's implicit-response machinery stays quiet.
fn sendFileRange(r: zap.Request, io: std.Io, path: []const u8, offset: u64, len: u64) !void {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    if (zap.fio.http_sendfile(r.h, f.handle, len, offset) != 0) return error.SendFile;
    r.markAsFinished(true);
}

/// Last-resort raw error envelope, used only when even building the normal ApiError
/// response fails (allocation failure). Sends a fixed JSON body bypassing the arena.
fn sendRawEnvelope(r: zap.Request, status: u16, body: []const u8) void {
    setZapStatus(r, status);
    r.setContentType(.JSON) catch {};
    r.sendBody(body) catch {};
}

fn hasRoute(rs: []const router.Route, method: http.Method, pattern: []const u8) bool {
    for (rs) |r| if (r.method == method and std.mem.eql(u8, r.pattern, pattern)) return true;
    return false;
}

test "R2-3: Gates assemble the built-in route table at comptime" {
    const full = Server(.{}); // all-on default == today's table
    try std.testing.expect(hasRoute(full.routes, .GET, "/api/analytics/events"));
    try std.testing.expect(hasRoute(full.routes, .GET, "/api/senders"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/mail/webhooks/:provider"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/mail/unsubscribe"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/accounts/:id/activate"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/collections/:col/auth/webauthn/register/begin"));

    const lean = Server(.{
        .admin = false,
        .analytics = false,
        .senders = false,
        .mail_webhook = false,
        .mail_unsubscribe = false,
        .tenancy = false,
        .webauthn = false,
        .magic_link = false,
        .oauth2 = false,
    });
    // Core stays.
    try std.testing.expect(hasRoute(lean.routes, .GET, "/api/health"));
    try std.testing.expect(hasRoute(lean.routes, .POST, "/api/collections/:col/auth-with-password"));
    try std.testing.expect(hasRoute(lean.routes, .GET, "/api/settings"));
    // Optional subsystems are ABSENT (not 404-at-runtime — absent from the table).
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/analytics/events"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/analytics/rollups/:name"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/senders"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/senders/:id/verify"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/mail/webhooks/:provider"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/mail/unsubscribe"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/mail/unsubscribe"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/accounts/:id/activate"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/collections/:col/auth/webauthn/register/begin"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/collections/:col/auth/webauthn/register/finish"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/collections/:col/auth/magic-link/consume"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/collections/:col/auth/oauth2/providers"));
    try std.testing.expect(!hasRoute(lean.routes, .DELETE, "/api/collections/:col/records/:id/external-auths/:provider"));
}
