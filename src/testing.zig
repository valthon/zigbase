//! In-process test harness for `zigbase.App(.{...})` apps (#239).
//!
//! Boot a comptime-configured application against a throwaway TEMPDIR data dir and inject HTTP
//! requests through the REAL pipeline — the same router, access rules, auth, hooks, and custom
//! routes the socket server runs — WITHOUT binding a socket. It composes two seams extracted in
//! stages 1 and 2:
//!
//!   * `App(cfg).bootForTest` (framework.zig) — the socketless boot: opens a pool on a tempdir DB,
//!     runs migrations + comptime provisioning, fires `onBootstrap`, and returns an owned holder.
//!   * `App(cfg).routeForTest` (server.zig `Server(gates).route`) — the socketless routing/fallback
//!     chain: admin → built-in routes → feature-state → custom routes → static → 404.
//!
//! Usage:
//! ```zig
//! const MyApp = zigbase.App(.{ ... });
//! var t = try zigbase.testing.start(MyApp, .{});
//! defer t.deinit();
//!
//! const r = try t.request(.POST, "/api/things", .{ .json = .{ .name = "x" } });
//! try std.testing.expectEqual(@as(u16, 201), r.status);
//! const parsed = try r.json(ThingOut);
//!
//! const admin = try t.loginSuperuser("a@b.c", "password123"); // real endpoint → "Bearer <tok>"
//! const sess  = try t.mintSession("users", user_id);          // direct JWT mint → "Bearer <tok>"
//! const r2 = try t.request(.GET, "/api/admin/things", .{ .auth = admin });
//! ```
//!
//! The harness owns the booted `App` holder, the request arenas (each `Response` borrows one), an
//! optional `CaptureMailer`, and the tempdir. `deinit` tears all of them down; run the harness's
//! own tests under `std.testing.allocator` so a leak across boot → requests → deinit FAILS.

const std = @import("std");

const config = @import("config.zig");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const server = @import("server.zig");
const jwt = @import("jwt.zig");
const crypto = @import("crypto.zig");
const clock = @import("clock.zig");
const id_gen = @import("id.zig");
const data_mod = @import("data.zig");
const api_auth = @import("api/auth.zig");
const mail = @import("mail/mailer.zig");
const capture_mod = @import("mail/capture.zig");

/// The runtime application-context type (what `ctx.app` / `t.app()` point at).
pub const Runtime = app_mod.App;

/// True if `s` is a safe collection-table name: `[A-Za-z_][A-Za-z0-9_]*`. Permits the leading
/// underscore of system collections (`_superusers`) while keeping the charset injection-safe.
fn isCollectionName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// True when a `.headers` option value is a comptime TUPLE (e.g. `&.{ .{ "N", "V" } }`), whose
/// heterogeneous pair elements require `inline for`. A runtime `[]const [2][]const u8` slice (the
/// documented type) is NOT a tuple and iterates with a plain `for`. Distinguishes a pointer-to-
/// tuple (the `&.{...}` literal) and a bare tuple from a slice/array of homogeneous pairs.
fn isTupleHeaders(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .pointer) {
        const child = @typeInfo(info.pointer.child);
        return child == .@"struct" and child.@"struct".is_tuple;
    }
    return info == .@"struct" and info.@"struct".is_tuple;
}

/// Options for `start`. All fields default, so `start(MyApp, .{})` works; the struct stays open
/// so new knobs can be added without breaking callers.
pub const StartOptions = struct {
    /// Data dir to boot against. `null` (default) mints a fresh `std.testing.TmpDir` that
    /// `deinit` removes. A caller-supplied dir is used as-is and NOT cleaned up.
    data_dir: ?[]const u8 = null,
    /// Allocator backing the harness (holder, arenas, tempdir path). Defaults to
    /// `std.testing.allocator` so leaks fail the test. Consumers may pass their own.
    allocator: ?std.mem.Allocator = null,
    /// Async/IO handle threaded into the app. Defaults to `std.testing.io`.
    io: ?std.Io = null,
    /// Deterministic frozen clock (unix seconds), via the dev-clock override — token expiry,
    /// TTLs, and `datetime('now')` all read it. `null` = wall clock. Requires a dev-clock build
    /// (Debug/`zig build test`); a no-op on a prod build.
    fake_now_unix: ?i64 = null,
    /// Deterministic PRNG seed for id/token generation (reproducible snapshots). `null` = CSPRNG.
    fake_seed: ?u64 = null,
};

/// Boot `AppType` (a `zigbase.App(.{...})` builder result type) into an in-process `Harness`.
/// Migrations run and `onBootstrap` fires before this returns.
pub fn start(comptime AppType: type, opts: StartOptions) !Harness(AppType) {
    const allocator = opts.allocator orelse std.testing.allocator;
    const io = opts.io orelse std.testing.io;

    var h = Harness(AppType){
        .allocator = allocator,
        .io = io,
        .booted = undefined,
        .tmp = undefined,
        .owns_tmp = false,
        .data_dir = "",
        .arenas = .empty,
        .capture = null,
        .capture_iface = null,
    };

    if (opts.data_dir) |d| {
        h.data_dir = try allocator.dupe(u8, d);
    } else {
        h.tmp = std.testing.tmpDir(.{});
        h.owns_tmp = true;
        errdefer h.tmp.cleanup();
        const rp = try h.tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(rp);
        h.data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{rp});
    }
    errdefer allocator.free(h.data_dir);
    errdefer if (h.owns_tmp) h.tmp.cleanup();

    const cfg = config.Config{
        .data_dir = h.data_dir,
        // Plain-HTTP in-process: cookies must not be Secure-only or the harness can't read them.
        .cookie_secure = false,
        .fake_now_unix = opts.fake_now_unix,
        .fake_seed = opts.fake_seed,
    };

    // bootForTest only READS the environ during boot (backend select, field-key resolve); it is
    // never retained by the App, so an empty map local to `start` is sufficient.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    h.booted = try AppType.bootForTest(allocator, io, cfg, &env);
    return h;
}

/// Recognized fields of the anonymous-struct `opts` accepted by `Harness.request` (all optional —
/// pass `.{}` for a bare GET). Documented as a struct for reference; `request` takes `anytype` and
/// introspects the literal so `.json` can be a true optional-anytype (present vs absent). An
/// unrecognized key is a COMPILE error, so a typo cannot silently no-op.
///
///   * `json`: anytype — serialized to the body as JSON; sets `Content-Type: application/json`.
///   * `body`: []const u8 — raw request body (ignored when `json` is present).
///   * `auth`: []const u8 — the `Authorization` header value, e.g. the `"Bearer <tok>"` an auth
///     helper returns. May be optional; a null value is skipped. Wins over an `Authorization`
///     entry in `headers`.
///   * `headers`: []const [2][]const u8 — extra request headers as `.{ name, value }` pairs. They
///     populate the generic `ctx.headers` list AND, for well-known names (Cookie, If-None-Match,
///     User-Agent, X-CSRF-Token, Content-Type, Authorization), the dedicated `RequestCtx` fields
///     the real pipeline reads — same names/fields `server.zig` uses.
///   * `query`: []const u8 — raw query string (no leading `?`); overrides a `?...` in the path.
///   * `content_type`: []const u8 — overrides the request content-type.
///   * `cookie`: []const u8 — the `Cookie` request header value (e.g. `"zb_auth=<tok>"`); the only
///     way to send a request cookie, for cookie-auth / refresh / logout / CSRF double-submit flows.
pub const RequestOptions = struct {
    json: ?void = null,
    body: ?[]const u8 = null,
    auth: ?[]const u8 = null,
    headers: []const [2][]const u8 = &.{},
    query: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
};

/// A response captured from the in-process pipeline. Its `body`/`cookies`/`headers` are owned by
/// the harness request arena (freed at `Harness.deinit`), so they outlive the call.
pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8,
    cookies: []const http.Cookie,
    headers: []const http.Header,
    /// The request arena that owns `body`; `json` parses into it.
    arena: std.mem.Allocator,

    /// Value of response header `name` (case-insensitive), or null. `"content-type"` resolves to
    /// the response content-type even though it is not carried in `extra_headers`.
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, name)) return hd.value;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-type")) return self.content_type;
        return null;
    }

    /// Value of `Set-Cookie` cookie `name`, or null.
    pub fn cookie(self: Response, name: []const u8) ?[]const u8 {
        for (self.cookies) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    /// Parse the JSON body into `T` (ignoring unknown fields), allocating into the request arena.
    pub fn json(self: Response, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena, self.body, .{ .ignore_unknown_fields = true });
    }
};

/// The in-process harness owning a booted `AppType` and everything torn down with it.
/// `AppType` is a `zigbase.App(.{...})` builder result type.
pub fn Harness(comptime AppType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        /// The booted holder (owns pool/storage/mailer/registry/caches; `&booted.app` is the App).
        booted: *AppType.Booted,
        tmp: std.testing.TmpDir,
        owns_tmp: bool,
        data_dir: []const u8,
        /// One arena per request/helper call; each `Response` borrows the arena it was built in.
        arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator),
        /// Optional capture mailer swapped in by `captureMail`; owned here. BOTH the mailer and
        /// its vtable view are HEAP-allocated (not inline Harness fields), so `app.mailer` points
        /// at a stable address that survives the Harness being moved/returned by value — e.g. a
        /// `fn setup() !Harness { var t = try start(...); _ = try t.captureMail(); return t; }`.
        capture: ?*capture_mod.CaptureMailer,
        capture_iface: ?*mail.Mailer,

        /// The runtime App context (`ctx.app`). Use it to reach `app.pool`, config, etc.
        pub fn app(self: *Self) *Runtime {
            return &self.booted.app;
        }

        /// Tear down the booted app, every request arena, the capture mailer, and the tempdir.
        pub fn deinit(self: *Self) void {
            if (self.capture) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }
            if (self.capture_iface) |iface| self.allocator.destroy(iface);
            self.booted.deinit();
            for (self.arenas.items) |ap| {
                ap.deinit();
                self.allocator.destroy(ap);
            }
            self.arenas.deinit(self.allocator);
            self.allocator.free(self.data_dir);
            if (self.owns_tmp) self.tmp.cleanup();
        }

        /// Allocate a fresh tracked arena; its allocator is valid until `deinit`.
        fn newArena(self: *Self) !std.mem.Allocator {
            const ap = try self.allocator.create(std.heap.ArenaAllocator);
            ap.* = std.heap.ArenaAllocator.init(self.allocator);
            errdefer {
                ap.deinit();
                self.allocator.destroy(ap);
            }
            try self.arenas.append(self.allocator, ap);
            return ap.allocator();
        }

        /// Inject a request through the full socketless pipeline. `opts` is an anonymous struct;
        /// see `RequestOptions` for the recognized fields (all optional). An unknown key is a
        /// COMPILE error (a typo like `.jsn` can never silently send an empty body).
        pub fn request(self: *Self, method: http.Method, path: []const u8, opts: anytype) !Response {
            const O = @TypeOf(opts);
            // Comptime whitelist: reject any unrecognized option key up front, so a typo like
            // `.jsn` / `.headr` is a compile error instead of a silent no-op.
            comptime {
                const allowed = [_][]const u8{ "json", "body", "auth", "headers", "query", "content_type", "cookie" };
                for (std.meta.fields(O)) |f| {
                    var ok = false;
                    for (allowed) |name| {
                        if (std.mem.eql(u8, f.name, name)) ok = true;
                    }
                    if (!ok) @compileError("zigbase.testing request: unknown option '." ++ f.name ++
                        "' (allowed: json, body, auth, headers, query, content_type, cookie)");
                }
            }
            const a = try self.newArena();

            // Body + content-type: `.json` wins over `.body`.
            var body: []const u8 = "";
            var content_type: []const u8 = "";
            const json_present = @hasField(O, "json");
            if (json_present) {
                body = try std.json.Stringify.valueAlloc(a, opts.json, .{});
                content_type = "application/json";
            } else if (@hasField(O, "body")) {
                body = opts.body;
            }

            // Path/query split: an explicit `.query` overrides a `?...` embedded in the path.
            var req_path = path;
            var req_query: []const u8 = "";
            if (std.mem.indexOfScalar(u8, path, '?')) |q| {
                req_path = path[0..q];
                req_query = path[q + 1 ..];
            }
            if (@hasField(O, "query")) req_query = opts.query;

            // Extra headers → the generic `ctx.headers` list (the route-guard `.header` source).
            // Accept BOTH a comptime tuple literal (`.headers = &.{ .{ "N", "V" } }`, whose pairs
            // are anonymous tuples — needs `inline for`) AND a runtime `[]const [2][]const u8`
            // slice (the documented type — a plain `for`). Branch on the element type.
            var headers: []const http.Param = &.{};
            if (@hasField(O, "headers")) {
                const src = opts.headers;
                const hs = try a.alloc(http.Param, src.len);
                if (comptime isTupleHeaders(@TypeOf(src))) {
                    inline for (src, 0..) |pair, i| hs[i] = .{ .key = pair[0], .value = pair[1] };
                } else {
                    for (src, 0..) |pair, i| hs[i] = .{ .key = pair[0], .value = pair[1] };
                }
                headers = hs;
            }

            var ctx = http.RequestCtx{
                .method = method,
                .path = req_path,
                .query = req_query,
                .body = body,
                .allocator = a,
                .app = &self.booted.app,
                .headers = headers,
            };

            // Fidelity: the real `onRequest` (server.zig) reads security-relevant headers from
            // DEDICATED RequestCtx fields, not the generic list. Mirror that mapping from any
            // well-known header name the caller passed (case-insensitive, same names server.zig
            // uses). Explicit opts (`.content_type`/`.auth`/`.cookie`) win over a header entry.
            for (headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.key, "authorization")) {
                    ctx.authorization = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.key, "cookie")) {
                    ctx.cookie_header = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.key, "x-csrf-token")) {
                    ctx.csrf_token = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.key, "if-none-match")) {
                    ctx.if_none_match = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.key, "user-agent")) {
                    ctx.user_agent = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.key, "content-type")) {
                    if (!json_present) content_type = h.value;
                }
            }
            if (@hasField(O, "content_type")) content_type = opts.content_type;
            ctx.content_type = content_type;
            // Cookie opt: the only way to send a request cookie (cookie-auth / refresh / CSRF).
            if (@hasField(O, "cookie")) ctx.cookie_header = opts.cookie;
            // Authorization opt: accept a plain or optional `[]const u8` (null skipped); WINS over
            // any Authorization header entry above, matching the documented precedence.
            if (@hasField(O, "auth")) {
                const av = opts.auth;
                switch (@typeInfo(@TypeOf(av))) {
                    .optional => if (av) |v| {
                        ctx.authorization = v;
                    },
                    else => ctx.authorization = av,
                }
            }

            // Multipart pre-parse: mirror `onRequest`, which runs `applyMultipart` before `route`
            // so a `multipart/form-data` body populates ctx.form_fields/ctx.files (and a malformed
            // body short-circuits to the same 400) — off-socket file uploads behave as in prod.
            const resp = if (try server.applyMultipart(&ctx)) |multipart_err|
                multipart_err
            else
                try AppType.routeForTest(&ctx);
            return .{
                .status = resp.status,
                .body = resp.body,
                .content_type = resp.content_type,
                .cookies = resp.cookies,
                .headers = resp.extra_headers,
                .arena = a,
            };
        }

        // ---- Auth helpers -------------------------------------------------------------

        /// Mint a real signed auth JWT DIRECTLY for an existing record — deterministic, no HTTP.
        /// Reads the record's `tokenKey` AND its current `token_epoch` (the same single read the
        /// real issue path does), derives the per-record key, and signs an `.auth` token stamped
        /// with that epoch — so a token minted AFTER a "revoke all sessions" epoch bump still
        /// authenticates. Returns `"Bearer <tok>"`. For the default epoch session store (the common
        /// case); use `loginPassword` for `.session_store = .table` (which needs a `_sessions` row,
        /// so a mint-only token is rejected there).
        pub fn mintSession(self: *Self, collection: []const u8, record_id: []const u8) ![]const u8 {
            // Injection-safe collection-name gate: the epoch/tokenKey read interpolates the table
            // name, and unlike prod (which passes a resolved collection) the harness caller may pass
            // anything. `isCollectionName` permits the leading underscore of system collections
            // (`_superusers`) while keeping the charset `[A-Za-z0-9_]`.
            if (!isCollectionName(collection)) return error.InvalidCollection;
            const a = try self.newArena();
            const the_app = &self.booted.app;
            var r = try the_app.pool.acquireReader();
            defer the_app.pool.releaseReader(&r);
            const ke = (try api_auth.tokenKeyAndEpochFor(a, &r, collection, record_id)) orelse return error.RecordNotFound;
            const key = crypto.deriveKey(the_app.jwt_secret, ke.token_key);
            const now = clock.nowUnix(the_app.io);
            const tok = try jwt.sign(a, .{
                .id = record_id,
                .collection = collection,
                .type = .auth,
                .token_epoch = ke.epoch,
                .iat = now,
                .exp = now + 14 * 24 * 3600,
            }, &key);
            return std.fmt.allocPrint(a, "Bearer {s}", .{tok});
        }

        /// Drive the REAL `auth-with-password` endpoint in-process and return `"Bearer <tok>"`.
        /// Full-fidelity: runs the rate limiter, argon2 verify, verification gate, and
        /// `beforeAuthSuccess`/`onAuth` hooks exactly as a socket login does.
        pub fn loginPassword(self: *Self, collection: []const u8, identity: []const u8, password: []const u8) ![]const u8 {
            const a = try self.newArena();
            const path = try std.fmt.allocPrint(a, "/api/collections/{s}/auth-with-password", .{collection});
            const resp = try self.request(.POST, path, .{ .json = .{ .identity = identity, .password = password } });
            if (resp.status != 200) return error.LoginFailed;
            const parsed = try resp.json(struct { token: []const u8 });
            return std.fmt.allocPrint(a, "Bearer {s}", .{parsed.token});
        }

        /// `loginPassword` against the built-in `_superusers` collection.
        pub fn loginSuperuser(self: *Self, email: []const u8, password: []const u8) ![]const u8 {
            return self.loginPassword("_superusers", email, password);
        }

        // ---- Seeding ------------------------------------------------------------------

        /// Create a superuser (same shape as `zigbase superuser create`) and return its record id.
        /// The id is owned by a harness arena. Password is argon2id-hashed; a random `tokenKey` is
        /// generated so the account works with `loginSuperuser`.
        pub fn createSuperuser(self: *Self, email: []const u8, password: []const u8) ![]const u8 {
            const a = try self.newArena();
            const the_app = &self.booted.app;
            const phc = try crypto.hashPassword(the_app.io, a, password);
            const tk = try crypto.genToken(the_app.io, a, 32);
            var rid = id_gen.collectionId(the_app.io);
            const w = the_app.pool.acquireWriter();
            defer the_app.pool.releaseWriter();
            var st = try w.prepare(
                \\INSERT INTO "_superusers" ("id","created","updated","email","username","passwordHash","tokenKey","verified")
                \\ VALUES (?1, datetime('now'), datetime('now'), ?2, '', ?3, ?4, 1);
            );
            defer st.finalize();
            try st.bindText(1, &rid);
            try st.bindText(2, email);
            try st.bindText(3, phc);
            try st.bindText(4, tk);
            _ = try st.step();
            return a.dupe(u8, &rid);
        }

        /// Create a record via the `Data` facade (the same create path hooks/routes use — auth
        /// collections get a generated `tokenKey` + hashed `password`). `value` is any type
        /// serializable to a JSON object. Returns the persisted record (arena-owned).
        pub fn createRecord(self: *Self, collection: []const u8, value: anytype) !std.json.Value {
            const a = try self.newArena();
            const the_app = &self.booted.app;
            const json_bytes = try std.json.Stringify.valueAlloc(a, value, .{});
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json_bytes, .{});
            const w = the_app.pool.acquireWriter();
            defer the_app.pool.releaseWriter();
            const d = data_mod.Data{ .app = the_app, .conn = w, .io = the_app.io, .alloc = a };
            return d.create(collection, parsed);
        }

        // ---- Composable seams ---------------------------------------------------------

        /// Swap the app's mailer for an in-memory `CaptureMailer` and return it, so a test can
        /// assert on outbound mail (subject/recipient/body) with no SMTP. Idempotent — repeated
        /// calls return the same instance. The harness owns and frees it in `deinit`.
        pub fn captureMail(self: *Self) !*capture_mod.CaptureMailer {
            if (self.capture) |c| return c;
            const c = try self.allocator.create(capture_mod.CaptureMailer);
            errdefer self.allocator.destroy(c);
            c.* = capture_mod.CaptureMailer.init(self.allocator);
            // Heap-allocate the vtable view too: `app.mailer` must point at a STABLE address, not
            // an inline Harness field, so it stays valid if the Harness is moved/returned by value.
            const iface = try self.allocator.create(mail.Mailer);
            errdefer self.allocator.destroy(iface);
            iface.* = c.mailer();
            self.capture = c;
            self.capture_iface = iface;
            self.booted.app.mailer = iface;
            return c;
        }
    };
}

// =====================================================================================
// Harness self-tests. Run under `std.testing.allocator` so any leak across
// boot → requests → deinit FAILS — the real validation of Stage 1's holder lifetime.
// =====================================================================================

const framework = @import("framework.zig");
const route_types = @import("route_types.zig");
const Ctx = @import("ctx.zig").Ctx;

const PingOut = struct { ok: bool, who: []const u8 };

fn pingHandler(req: *route_types.Req(void)) route_types.RouteError!PingOut {
    _ = req;
    return .{ .ok = true, .who = "ping" };
}

fn whoamiHandler(req: *route_types.Req(void)) route_types.RouteError!PingOut {
    _ = req;
    // The `.authed` gate rejects unauthenticated callers before this runs (401), so reaching
    // here means a principal is present (bearer OR the zb_auth cookie).
    return .{ .ok = true, .who = "authed" };
}

/// Untyped `fn(*Ctx)` handler: send one transactional email synchronously through the configured
/// mailer, so a `captureMail`-swapped harness records it.
fn sendMailHandler(ctx: *Ctx) anyerror!http.Response {
    try ctx.mail().send(.{ .to = "user@example.com", .subject = "Welcome", .text = "hello" });
    return .{ .status = 204, .body = "" };
}

/// Untyped `fn(*Ctx)` handler: echo the request's query / `X-Custom` header / `sess` cookie back
/// as JSON, and set a response cookie + header — exercises both request-input plumbing and the
/// `Response.header`/`Response.cookie` readers.
fn echoHandler(ctx: *Ctx) anyerror!http.Response {
    const rc = ctx.request.?;
    const out = .{
        .q = rc.query,
        .h = rc.header("x-custom") orelse "",
        .c = rc.cookie("sess") orelse "",
    };
    const body = try std.json.Stringify.valueAlloc(ctx.arena, out, .{});
    return .{
        .status = 200,
        .body = body,
        .cookies = &.{.{ .name = "sid", .value = "set", .secure = false }},
        .extra_headers = &.{.{ .name = "X-Echo", .value = "1" }},
    };
}

/// App used across the harness tests: public + authed custom routes (typed and untyped), a
/// `@public` collection so the built-in records API is exercised end-to-end, and a `users` auth
/// collection so `createRecord` + real password login can be covered.
const HarnessTestApp = framework.App(.{
    .routes = .{
        .{ .method = .GET, .path = "/api/ping", .handler = pingHandler, .auth = .public },
        .{ .method = .GET, .path = "/api/whoami", .handler = whoamiHandler, .auth = .authed },
        .{ .method = .POST, .path = "/api/send-mail", .handler = sendMailHandler, .auth = .public },
        .{ .method = .GET, .path = "/api/echo", .handler = echoHandler, .auth = .public },
    },
    .collections = .{
        .things = .{
            .fields = .{
                .{ .name = "name", .type = .text, .max = 100 },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@public" },
        },
        // Locked rules (superuser-only) — `createRecord` uses the engine Data facade and
        // `loginPassword` uses the auth endpoint, neither of which is rule-gated.
        .users = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text, .max = 100 },
            },
        },
    },
});

test "harness: custom route round-trip + json() parse" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const r = try t.request(.GET, "/api/ping", .{});
    try std.testing.expectEqual(@as(u16, 200), r.status);
    const parsed = try r.json(PingOut);
    try std.testing.expect(parsed.ok);
    try std.testing.expectEqualStrings("ping", parsed.who);
}

test "harness: records API round-trip through the full router (create -> list)" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const created = try t.request(.POST, "/api/collections/things/records", .{ .json = .{ .name = "widget" } });
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const crec = try created.json(struct { id: []const u8, name: []const u8 });
    try std.testing.expect(crec.id.len > 0);
    try std.testing.expectEqualStrings("widget", crec.name);

    const listed = try t.request(.GET, "/api/collections/things/records", .{});
    try std.testing.expectEqual(@as(u16, 200), listed.status);
    const page = try listed.json(struct { items: []struct { name: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("widget", page.items[0].name);
}

test "harness: mintSession authorizes an .authed route; missing/invalid auth is 401" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const su_id = try t.createSuperuser("mint@b.c", "password123");
    const bearer = try t.mintSession("_superusers", su_id);

    const ok = try t.request(.GET, "/api/whoami", .{ .auth = bearer });
    try std.testing.expectEqual(@as(u16, 200), ok.status);

    const no_auth = try t.request(.GET, "/api/whoami", .{});
    try std.testing.expectEqual(@as(u16, 401), no_auth.status);

    const bad = try t.request(.GET, "/api/whoami", .{ .auth = "Bearer not.a.jwt" });
    try std.testing.expectEqual(@as(u16, 401), bad.status);
}

test "harness: createSuperuser + real loginSuperuser authorizes a superuser-only route" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    _ = try t.createSuperuser("admin@b.c", "password123");
    const admin = try t.loginSuperuser("admin@b.c", "password123");

    // Listing collections is superuser-gated: the real login token authorizes it, no token 401s.
    const ok = try t.request(.GET, "/api/collections", .{ .auth = admin });
    try std.testing.expectEqual(@as(u16, 200), ok.status);

    // Superuser-gated endpoints reject an unauthenticated caller (403 here, not 401).
    const denied = try t.request(.GET, "/api/collections", .{});
    try std.testing.expectEqual(@as(u16, 403), denied.status);

    // A wrong password fails the real endpoint.
    try std.testing.expectError(error.LoginFailed, t.loginSuperuser("admin@b.c", "wrong-password"));
}

test "harness: captureMail records mail sent from a handler (the composed-seam example)" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const mailbox = try t.captureMail(); // swap in the in-memory mailer BEFORE the request

    const r = try t.request(.POST, "/api/send-mail", .{});
    try std.testing.expectEqual(@as(u16, 204), r.status);

    try std.testing.expectEqual(@as(usize, 1), mailbox.messages.items.len);
    try std.testing.expectEqualStrings("user@example.com", mailbox.messages.items[0].to);
    try std.testing.expectEqualStrings("Welcome", mailbox.messages.items[0].subject);
}

test "harness: captureMail survives the Harness being returned by value (heap-stable mailer)" {
    // A consumer helper that installs the capture mailer and RETURNS the Harness by value. With an
    // inline vtable field `app.mailer` would dangle into this dead frame; the heap-allocated iface
    // keeps it valid across the move.
    const Setup = struct {
        fn make() !Harness(HarnessTestApp) {
            var t = try start(HarnessTestApp, .{});
            errdefer t.deinit();
            _ = try t.captureMail();
            return t; // Harness MOVES here.
        }
    };
    var t = try Setup.make();
    defer t.deinit();

    const r = try t.request(.POST, "/api/send-mail", .{});
    try std.testing.expectEqual(@as(u16, 204), r.status);

    const mailbox = try t.captureMail(); // idempotent — same instance
    try std.testing.expectEqual(@as(usize, 1), mailbox.messages.items.len);
    try std.testing.expectEqualStrings("user@example.com", mailbox.messages.items[0].to);
}

test "harness: createRecord on an auth collection + real loginPassword authorizes a request" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    // Seed a non-superuser user through the Data facade (hashes the password, gens a tokenKey).
    _ = try t.createRecord("users", .{ .email = "u@example.com", .password = "hunter2xyz", .name = "U" });

    // Real auth-with-password against that collection returns a token that authorizes a request.
    const token = try t.loginPassword("users", "u@example.com", "hunter2xyz");
    const ok = try t.request(.GET, "/api/whoami", .{ .auth = token });
    try std.testing.expectEqual(@as(u16, 200), ok.status);
}

test "harness: query + headers + cookie opts reach the handler; Response.header/cookie read back" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const r = try t.request(.GET, "/api/echo", .{
        .query = "k=v",
        .headers = &.{.{ "X-Custom", "hdr-val" }},
        .cookie = "sess=cookie-val",
    });
    try std.testing.expectEqual(@as(u16, 200), r.status);

    const echoed = try r.json(struct { q: []const u8, h: []const u8, c: []const u8 });
    try std.testing.expectEqualStrings("k=v", echoed.q);
    try std.testing.expectEqualStrings("hdr-val", echoed.h);
    try std.testing.expectEqualStrings("cookie-val", echoed.c);

    // Response readers.
    try std.testing.expectEqualStrings("1", r.header("X-Echo").?);
    try std.testing.expectEqualStrings("application/json", r.header("content-type").?);
    try std.testing.expectEqualStrings("set", r.cookie("sid").?);
    try std.testing.expect(r.cookie("nope") == null);

    // `.headers` must ALSO accept a RUNTIME `[]const [2][]const u8` slice (not just a comptime
    // tuple literal) — exercises the plain-`for` branch of the header builder.
    const runtime_headers: []const [2][]const u8 = &.{.{ "X-Custom", "from-slice" }};
    const r2 = try t.request(.GET, "/api/echo", .{ .headers = runtime_headers });
    try std.testing.expectEqual(@as(u16, 200), r2.status);
    const echoed2 = try r2.json(struct { h: []const u8 });
    try std.testing.expectEqualStrings("from-slice", echoed2.h);
}

test "harness: a cookie-authenticated request (zb_auth) authorizes an .authed route" {
    var t = try start(HarnessTestApp, .{});
    defer t.deinit();

    const su_id = try t.createSuperuser("cookie@b.c", "password123");
    const bearer = try t.mintSession("_superusers", su_id);
    // The auth COOKIE carries the raw token (no "Bearer " prefix).
    const raw = bearer["Bearer ".len..];
    const cookie = try std.fmt.allocPrint(std.testing.allocator, "zb_auth={s}", .{raw});
    defer std.testing.allocator.free(cookie);

    const ok = try t.request(.GET, "/api/whoami", .{ .cookie = cookie });
    try std.testing.expectEqual(@as(u16, 200), ok.status);
}

test "harness: boot -> deinit twice is leak-clean and free of double-free (std.testing.allocator)" {
    // Two full boot/deinit cycles under the leak-checking allocator validate the holder lifetime
    // (Stage 1's bootApp/BootedApp.deinit) under repeated use — the harness's core use case.
    {
        var t = try start(HarnessTestApp, .{});
        defer t.deinit();
        const r = try t.request(.GET, "/api/ping", .{});
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
    {
        var t = try start(HarnessTestApp, .{});
        defer t.deinit();
        const r = try t.request(.GET, "/api/ping", .{});
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
}
