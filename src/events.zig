const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;

const App = @import("app.zig").App;
const request = @import("request.zig");
const Ctx = @import("ctx.zig").Ctx;
const Data = @import("data.zig").Data;
const db = @import("db.zig");
const report_reporter = @import("report/reporter.zig");
const report_log = @import("report/log.zig");
const report_send = @import("report/send.zig");
const report_dedup = @import("report/dedup.zig");
const http = @import("http.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const route_types = @import("route_types.zig");
const rpc_ts = @import("codegen/rpc_ts.zig");
const route_path = @import("route_path.zig");

// ---------------------------------------------------------------------------
// RAII DB-access handles used where a `*Ctx` isn't already bound to a live
// connection (e.g. `Ctx.connForRead`'s lazily-cached reader, `AuthCtx`'s
// writer/reader in `auth/method.zig`). RecordEvent hooks get DB access through
// the `*Ctx` parameter their handlers receive (`ctx.records()`), whose
// `bound_conn` is the triggering write's in-transaction connection; these
// handles are for callers with no ambient connection, who must check one out
// of the pool and (crucially) hand it back:
//
//   var w: WriterData = .{ .app = app, .pool = app.pool, .conn = app.pool.acquireWriter() };
//   defer w.deinit();            // releases it back to the pool — no leak
//   _ = try w.data().create(...);
//
//   var r: ReaderData = .{ .app = app, .pool = app.pool, .conn = try app.pool.acquireReader() };
//   defer r.deinit();            // returns it to the warm pool — no leak
//   const rec = try r.data().findById(...);
//
// Asymmetry by design (mirrors db.Pool): the WRITER is a single shared,
// mutex-guarded connection, so deinit *unlocks* it (does not close). The READER
// is checked out of the pool's warm reader set, so deinit *returns* it to the
// pool (releaseReader) rather than closing.
// ---------------------------------------------------------------------------

/// RAII handle around the pool's shared writer connection. `data()` yields a
/// `Data` bound to it; `deinit()` releases the writer mutex. Hold it no longer
/// than necessary — only one writer exists pool-wide.
pub const WriterData = struct {
    app: *App,
    pool: *db.Pool,
    conn: *db.Db,
    /// Arena that backs the `Data` this handle yields, created lazily on the first
    /// `data()` call over `app.allocator` (the long-lived process GPA). Everything a
    /// record op allocates through this handle — the collection metadata, the SQL
    /// scratch, AND the returned records — lives on it and is freed together by
    /// `deinit()`, instead of being orphaned on the GPA. `ctx.records()` does NOT use
    /// this (it has its own per-request arena); this is for the standalone RAII path.
    arena: ?std.heap.ArenaAllocator = null,

    /// A `Data` bound to the acquired writer connection, allocating on this handle's
    /// arena. Results are valid until `deinit()`; a caller that must outlive the handle
    /// copies them first.
    pub fn data(self: *WriterData) Data {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(self.app.allocator);
        return .{ .app = self.app, .conn = self.conn, .io = self.app.io, .alloc = self.arena.?.allocator() };
    }

    /// Release the writer back to the pool and free this handle's arena (and everything
    /// its `data()` allocated). Call exactly once (use `defer`).
    pub fn deinit(self: *WriterData) void {
        if (self.arena) |*a| a.deinit();
        self.pool.releaseWriter();
    }
};

/// RAII handle around a pooled, read-only connection checked out via
/// `acquireReader()`. `data()` yields a `Data` bound to it; `deinit()` returns
/// the connection to the pool's warm reader set.
pub const ReaderData = struct {
    app: *App,
    pool: *db.Pool,
    conn: db.Db,
    /// See `WriterData.arena`: the handle-owned arena backing `data()`, freed by `deinit()`.
    arena: ?std.heap.ArenaAllocator = null,

    /// A `Data` bound to this reader connection, allocating on this handle's arena. Takes
    /// `*ReaderData` so the returned `Data.conn` points at this handle's own (stable) `conn`
    /// field rather than a dangling stack copy; the handle must outlive the `Data`. Results
    /// are valid until `deinit()`.
    pub fn data(self: *ReaderData) Data {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(self.app.allocator);
        return .{ .app = self.app, .conn = &self.conn, .io = self.app.io, .alloc = self.arena.?.allocator() };
    }

    /// Return the connection to the pool's warm reader set and free this handle's arena.
    /// Call exactly once (use `defer`). Passes `&self.conn` to match `Pool.releaseReader`.
    pub fn deinit(self: *ReaderData) void {
        if (self.arena) |*a| a.deinit();
        self.pool.releaseReader(&self.conn);
    }
};

// NOTE: adding a variant requires updating phaseFieldName() and the consumer-facing camelCase field name.
pub const RecordPhase = enum {
    before_create,
    after_create,
    before_update,
    after_update,
    before_delete,
    after_delete,
};

pub const RecordEvent = struct {
    /// Resolved request context (auth identity, is_superuser, method) for the
    /// triggering request. Named `rctx` to match `Ctx.rctx` — `ctx` always means
    /// `*Ctx` in a handler signature.
    rctx: *const request.RequestContext,
    /// Request-scoped allocator that owns `record`'s JSON storage. Hooks MUST use
    /// this for any allocation that becomes part of `record`. (The old `ev.app`
    /// escape to the WRONG allocator was removed — use `ctx.app` for app access.)
    arena: RequestArena,
    collection: []const u8,
    record: *std.json.Value, // mutable in before_*; the persisted record in after_*
    phase: RecordPhase,
    // DB capabilities are delivered to a record hook via its `*Ctx` parameter
    // (`ctx.records()`), whose `bound_conn` is the triggering write's in-transaction
    // connection — so a before-hook's side-write commits/rolls back atomically with it.
};

pub const ErrorPhase = enum { request, before_hook, after_hook, cron, job, file_serve, webhook, app };

pub const ErrorEvent = struct {
    app: *App,
    ctx: ?*const request.RequestContext,
    err: anyerror,
    phase: ErrorPhase,
    message: []const u8,
};

pub const RecordHandler = *const fn (ctx: *Ctx, ev: *RecordEvent) anyerror!void;
pub const ErrorHandler = *const fn (ev: *ErrorEvent) void;

/// Which kind of feature was resolved for the `ExposureEvent`.
pub const ExposureKind = enum { flag, experiment };

/// Notify-only analytics seam (#128/#129/#130): fired each time a DECLARED flag or
/// experiment is RESOLVED for a subject (the `App.flag`/`flagByName` and
/// `App.experiment` read paths). It cannot abort or write — it exists to feed an
/// analytics/exposure pipeline. For a `.flag`, `value` is the resolved boolean and
/// `subject` is empty (flags are global). For an `.experiment`, `variant` is the
/// resolved variant and `subject` is the bucketing subject.
///
/// It is ZERO-COST when no `.onFeatureExposure` handler is registered: the resolver
/// gates on `dispatch.on_feature_exposure` and never even constructs the event
/// (mirrors the `dispatchError` null-gating).
pub const ExposureEvent = struct {
    app: *App,
    kind: ExposureKind,
    name: []const u8,
    subject: []const u8 = "",
    /// Resolved value for a `.flag` exposure (unused for experiments).
    value: bool = false,
    /// Resolved variant for an `.experiment` exposure (unused for flags).
    variant: []const u8 = "",
};
pub const ExposureHandler = *const fn (ev: *ExposureEvent) void;

/// Consumer realtime subscribe predicate (#143). Consulted ONLY for a NON-collection
/// custom topic when a socket tries to subscribe (real collection topics keep their
/// own per-record viewRule authorization). `ctx` carries the socket's resolved identity
/// (`ctx.user()` / `ctx.rctx`); `topic` is the requested custom channel name. Return
/// `true` to allow the subscription, `false` to deny it. With NO predicate configured,
/// custom topics default to PUBLIC signal channels (the historical `__features` behavior).
pub const RealtimeCanSubscribeFn = *const fn (ctx: *Ctx, topic: []const u8) bool;

pub const AuthLevel = enum { public, authed, superuser };

pub const SecretParamLocation = enum { path, query, header };
pub const SecretMismatch = enum { not_found, forbidden };

// ---------------------------------------------------------------------------
// Declarative route-guard pipeline (#139 path-secret + #142 per-route rate limit).
//
// SELF-CONTAINED SECTION — types + lowering + the `RuntimeRoute` fields live together so
// sibling Wave-2 PRs that also append to events.zig rebase cleanly. The guards are ENFORCED
// in `server.zig dispatchCustom` as an ordered chain BEFORE the handler runs.
// ---------------------------------------------------------------------------

/// A `path_secret` guard (#139): the route is gated on a shared secret presented by the
/// caller (in the path/query/header) matching a server-side stored value, compared in
/// CONSTANT TIME. A mismatch returns a BARE 404 by default (no existence oracle — an
/// attacker cannot distinguish "wrong secret" from "no such route"). Rotation story: write a
/// new secret to the source and every link carrying the old one immediately 404s.
pub const PathSecretGuard = struct {
    /// Name of the path param / query key / header (per `in`) carrying the submitted secret.
    param: []const u8,
    /// Where the authoritative secret is stored.
    source: SecretSource,
    /// Where to read the submitted secret value from on the request.
    in: SecretParamLocation = .path,
    /// Response on mismatch: a bare 404 (default, no oracle) or an explicit 403.
    on_mismatch: SecretMismatch = .not_found,

    /// Where the stored secret is resolved from. `kv`/`settings` read the named key via
    /// `ctx.kv().get` (the `_kv` store — settings are KV entries); `config` is a static
    /// compile-time string baked into the route.
    pub const SecretSource = union(enum) {
        kv: []const u8,
        settings: []const u8,
        config: []const u8,
    };
};

/// An extensible route auth guard. `.auth` accepts either an `AuthLevel` literal OR one of
/// these guard structs; today the only guard is `path_secret`, but the union leaves room for
/// future kinds (e.g. an HMAC-signature guard) without changing the route-spec surface.
pub const RouteAuthGuard = union(enum) {
    path_secret: PathSecretGuard,
};

/// Export-safe path-secret metadata. It intentionally omits both the configured
/// secret and the key used to find it in KV/settings.
pub const PathSecretMeta = struct {
    param: []const u8,
    in: SecretParamLocation,
    on_mismatch: SecretMismatch,
};

/// A collection-scoped `.authed` gate (#243). `.auth = .{ .authed = "<collection>" }` requires a
/// valid token whose principal belongs to `<collection>`; a token from any OTHER collection — and a
/// superuser, UNLESS `.allow_superuser = true` — is rejected with the SAME 401 as no token at all
/// (fail-closed, no oracle). Enforced in `server.zig dispatchCustom` AFTER the `.authed` token check.
/// The referenced collection is comptime-validated (exists + is `.type = .auth`) by
/// `assertAuthedCollectionRoutes`, which the `App(cfg)` builder calls with the declared collections.
pub const AuthedCollection = struct {
    /// The auth collection a principal must belong to for the route to run.
    collection: []const u8,
    /// When true, a superuser token is additionally accepted (defaults to superusers-denied).
    allow_superuser: bool = false,
};

/// App-supplied key function for a per-route rate-limit bucket (#142). Returns the string to
/// key the bucket on (e.g. an API key or resolved user id); returning null falls back to the
/// trust_proxy-honored client IP. Receives the request-bound `*Ctx`.
pub const RateLimitKeyFn = *const fn (*Ctx) ?[]const u8;

pub const RouteHandler = *const fn (ctx: *Ctx) anyerror!http.Response;

/// Re-exported for config code that needs to name the rate-limit callback type.
pub const RateLimitFn = @import("auth_helpers.zig").RateLimitFn;

/// A custom route after comptime assembly. The framework matches method+pattern
/// (reusing router.matchPath), enforces `auth`, then calls `handler`.
pub const RuntimeRoute = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
    /// The effective AuthLevel enforced first in the guard chain. When `.auth` is a guard
    /// struct (e.g. `path_secret`), this is `.public` (the secret IS the gate) and the guard
    /// is carried in `auth_guard`.
    auth: AuthLevel,
    /// Optional declarative auth guard applied AFTER the AuthLevel check (#139). Null = none.
    auth_guard: ?RouteAuthGuard = null,
    /// Optional collection-scoped `.authed` gate (#243). Non-null ⇒ `auth` is `.authed` (a token is
    /// required) AND the principal must belong to `collection` (or be a superuser when
    /// `allow_superuser`). Null = the plain `.authed`/`.public`/`.superuser` semantics (a plain
    /// `.authed` accepts ANY authenticated principal). Enforced in `server.zig dispatchCustom`.
    authed_collection: ?AuthedCollection = null,
    /// Per-route rate limit (#142). `.default`/`.off` ⇒ no per-route bucket (routes are
    /// unthrottled by default); `.custom` ⇒ a dedicated bucket of max/window_s.
    rate_limit: schema.RateLimitOpt = .default,
    /// Optional app-supplied bucket-key function (#142); null ⇒ key on the client IP.
    rate_limit_key: ?RateLimitKeyFn = null,
};

/// Lower a `.path_secret.source` literal (`.{ .kv = "k" }` / `.{ .settings = "k" }` /
/// `.{ .config = "secret" }`) into the `SecretSource` union. Loud-comptime on an unknown shape.
fn lowerSecretSource(comptime src: anytype, comptime path: []const u8) PathSecretGuard.SecretSource {
    const S = @TypeOf(src);
    if (S == PathSecretGuard.SecretSource) return src;
    if (@typeInfo(S) != .@"struct")
        @compileError("route '" ++ path ++ "': .path_secret.source must be one of " ++
            ".{ .kv = \"key\" } / .{ .settings = \"key\" } / .{ .config = \"secret\" }");
    for (std.meta.fields(S)) |f| {
        const ok = std.mem.eql(u8, f.name, "kv") or std.mem.eql(u8, f.name, "settings") or std.mem.eql(u8, f.name, "config");
        if (!ok) @compileError("route '" ++ path ++ "': unknown .path_secret.source variant '." ++ f.name ++ "' (recognized: .kv, .settings, .config)");
    }
    // Exactly one source variant — `.{ .kv = "a", .settings = "b" }` would otherwise compile
    // and silently use only `.kv`, dropping the rest (loud-comptime convention).
    if (std.meta.fields(S).len != 1)
        @compileError("route '" ++ path ++ "': .path_secret.source must have exactly one field (.kv, .settings, or .config)");
    if (@hasField(S, "kv")) return .{ .kv = src.kv };
    if (@hasField(S, "settings")) return .{ .settings = src.settings };
    if (@hasField(S, "config")) return .{ .config = src.config };
    @compileError("route '" ++ path ++ "': .path_secret.source is missing a variant; expected one of .kv/.settings/.config");
}

/// Lower a `.auth` guard struct (`.{ .path_secret = .{ … } }`) into a `RouteAuthGuard`.
/// Loud `@compileError` on a malformed `.path_secret` (missing `.param`/`.source`, unknown keys).
fn lowerRouteAuthGuard(comptime a: anytype, comptime path: []const u8) RouteAuthGuard {
    const A = @TypeOf(a);
    if (A == RouteAuthGuard) {
        switch (a) {
            .path_secret => |guard| {
                if (guard.in == .path and !route_path.hasCapture(path, guard.param))
                    @compileError("route '" ++ path ++ "': .path_secret.param '" ++ guard.param ++ "' must name a :capture in the route path");
            },
        }
        return a;
    }
    if (@typeInfo(A) != .@"struct")
        @compileError("route '" ++ path ++ "': .auth must be an AuthLevel (.public/.authed/.superuser) " ++
            "or a guard struct like .{ .path_secret = .{ .param = \"...\", .source = .{ .kv = \"...\" } } }");
    for (std.meta.fields(A)) |f| {
        if (!std.mem.eql(u8, f.name, "path_secret"))
            @compileError("route '" ++ path ++ "': unknown .auth guard '." ++ f.name ++ "' (recognized guard: .path_secret)");
    }
    if (!@hasField(A, "path_secret"))
        @compileError("route '" ++ path ++ "': .auth guard struct must have a .path_secret field");
    const ps = a.path_secret;
    const P = @TypeOf(ps);
    if (@typeInfo(P) != .@"struct")
        @compileError("route '" ++ path ++ "': .path_secret must be a struct .{ .param = \"...\", .source = .{ .kv|.settings|.config = \"...\" } }");
    if (!@hasField(P, "param"))
        @compileError("route '" ++ path ++ "': .path_secret is missing required '.param' (the path/query/header name carrying the secret)");
    if (!@hasField(P, "source"))
        @compileError("route '" ++ path ++ "': .path_secret is missing required '.source' (.{ .kv = \"key\" } / .{ .settings = \"key\" } / .{ .config = \"secret\" })");
    for (std.meta.fields(P)) |f| {
        const ok = std.mem.eql(u8, f.name, "param") or std.mem.eql(u8, f.name, "source") or
            std.mem.eql(u8, f.name, "in") or std.mem.eql(u8, f.name, "on_mismatch");
        if (!ok) @compileError("route '" ++ path ++ "': unknown .path_secret key '." ++ f.name ++ "' (recognized: .param, .source, .in, .on_mismatch)");
    }
    var guard = PathSecretGuard{ .param = ps.param, .source = lowerSecretSource(ps.source, path) };
    if (@hasField(P, "in")) guard.in = ps.in;
    if (@hasField(P, "on_mismatch")) guard.on_mismatch = ps.on_mismatch;
    if (guard.in == .path and !route_path.hasCapture(path, guard.param))
        @compileError("route '" ++ path ++ "': .path_secret.param '" ++ guard.param ++ "' must name a :capture in the route path");
    return .{ .path_secret = guard };
}

/// True iff `.auth` is an AuthLevel (the `AuthLevel` type itself OR a bare enum literal like
/// `.public`), as opposed to a guard struct.
fn authIsLevel(comptime A: type) bool {
    return A == AuthLevel or A == @TypeOf(.enum_literal);
}

/// True iff `.auth` is a collection-scoped `.authed` gate struct — `.{ .authed = "..." }` (with an
/// optional `.allow_superuser`) — as opposed to an AuthLevel literal or a `.path_secret` guard. The
/// discriminator is the `.authed` field name (the `.path_secret` guard carries a `.path_secret` field).
fn authIsAuthedCollection(comptime A: type) bool {
    return @typeInfo(A) == .@"struct" and @hasField(A, "authed");
}

/// True iff `T` is a string type (`[]const u8` slice or a `*const [N:0]u8` string literal).
fn authValueIsString(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const p = info.pointer;
    if (p.size == .slice) return p.child == u8;
    if (p.size == .one) {
        const c = @typeInfo(p.child);
        return c == .array and c.array.child == u8;
    }
    return false;
}

/// Lower a `.auth = .{ .authed = "<collection>" }` gate struct into an `AuthedCollection`. Loud
/// `@compileError` on an unknown sibling key (anything other than `.authed`/`.allow_superuser`), a
/// non-string `.authed`, or a non-bool `.allow_superuser`. The collection NAME is validated
/// separately by `assertAuthedCollectionRoutes` (which knows the declared collection set).
fn lowerAuthedCollection(comptime a: anytype, comptime path: []const u8) AuthedCollection {
    const A = @TypeOf(a);
    if (A == AuthedCollection) return a;
    if (@typeInfo(A) != .@"struct")
        @compileError("route '" ++ path ++ "': .auth collection gate must be a struct .{ .authed = \"<collection>\" } (optionally .allow_superuser = true)");
    for (std.meta.fields(A)) |f| {
        const ok = std.mem.eql(u8, f.name, "authed") or std.mem.eql(u8, f.name, "allow_superuser");
        if (!ok) @compileError("route '" ++ path ++ "': unknown key '." ++ f.name ++ "' on the .auth gate (recognized: .authed, .allow_superuser)");
    }
    if (!@hasField(A, "authed"))
        @compileError("route '" ++ path ++ "': .auth gate struct must have an .authed = \"<collection>\" field");
    if (!authValueIsString(@TypeOf(a.authed)))
        @compileError("route '" ++ path ++ "': .auth.authed must be a string collection name, e.g. .{ .authed = \"customers\" }");
    var gate = AuthedCollection{ .collection = a.authed };
    if (@hasField(A, "allow_superuser")) {
        if (@TypeOf(a.allow_superuser) != bool)
            @compileError("route '" ++ path ++ "': .auth.allow_superuser must be a bool (true/false)");
        gate.allow_superuser = a.allow_superuser;
    }
    return gate;
}

/// The effective AuthLevel for a route spec: the literal when `.auth` is an AuthLevel; `.authed`
/// when `.auth` is a `.{ .authed = "..." }` collection gate (the token check runs first, the
/// collection check after); else `.public` (a `.path_secret` guard-gated route is public at the
/// AuthLevel layer — the guard is the gate), defaulting to `.superuser` (safe default) when omitted.
fn routeAuthLevel(comptime s: anytype) AuthLevel {
    if (!@hasField(@TypeOf(s), "auth")) return .superuser;
    if (authIsLevel(@TypeOf(s.auth))) return s.auth;
    if (authIsAuthedCollection(@TypeOf(s.auth))) return .authed;
    return .public;
}

/// The lowered `RouteAuthGuard` for a route spec, or null when `.auth` is an AuthLevel, a
/// `.{ .authed = "..." }` collection gate, or omitted.
fn routeAuthGuard(comptime s: anytype) ?RouteAuthGuard {
    if (!@hasField(@TypeOf(s), "auth")) return null;
    if (authIsLevel(@TypeOf(s.auth))) return null;
    if (authIsAuthedCollection(@TypeOf(s.auth))) return null;
    return lowerRouteAuthGuard(s.auth, s.path);
}

/// The lowered collection-scoped `.authed` gate for a route spec, or null when `.auth` isn't a
/// `.{ .authed = "..." }` struct. See `AuthedCollection`.
fn routeAuthedCollection(comptime s: anytype) ?AuthedCollection {
    if (!@hasField(@TypeOf(s), "auth")) return null;
    if (authIsLevel(@TypeOf(s.auth))) return null;
    if (!authIsAuthedCollection(@TypeOf(s.auth))) return null;
    return lowerAuthedCollection(s.auth, s.path);
}

/// Comptime-validate that every route carrying a collection-scoped `.authed` gate (#243) names a
/// collection that is DECLARED in `.collections` AND is of `.type = .auth`. A typo, an absent
/// collection, or a non-auth (`.base`/`.view`) collection is a loud `@compileError` at build time
/// (fail-fast). Called from the `App(cfg)` builder, which threads in the lowered collection set —
/// `buildRoutes` alone can't do this (it never sees the collections). Zero runtime effect.
pub fn assertAuthedCollectionRoutes(comptime routes: []const RuntimeRoute, comptime cols: []const schema.Collection) void {
    comptime {
        for (routes) |rt| {
            const gate = rt.authed_collection orelse continue;
            var found_any = false;
            var found_auth = false;
            for (cols) |c| {
                if (std.mem.eql(u8, c.name, gate.collection)) {
                    found_any = true;
                    if (c.type == .auth) found_auth = true;
                }
            }
            if (!found_auth) {
                if (found_any)
                    @compileError("route '" ++ rt.pattern ++ "': .auth.authed references collection '" ++
                        gate.collection ++ "' which is not an auth collection (its .type must be .auth)");
                @compileError("route '" ++ rt.pattern ++ "': .auth.authed references unknown auth collection '" ++
                    gate.collection ++ "'; declare it in .collections with .type = .auth");
            }
        }
    }
}

/// Which flow minted (or is about to mint) the session. `.refresh` (new in 0.10.0) tags
/// `POST …/auth-refresh` — previously mislabeled `.password` on `onAuth`. Exhaustive
/// `switch`es over this enum must add a `.refresh` arm (compile error — the good kind).
pub const AuthMethod = enum { password, oauth2, magic_link, otp, webauthn, custom, refresh };
pub const AuthEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record: ?std.json.Value,
    method: AuthMethod,
};
/// Notify-only, post-issuance auth notification. Fires AFTER a session is minted; cannot
/// abort or transactionally write. For a writable, abortable seam use `beforeAuthSuccess`.
pub const AuthHandler = *const fn (ev: *AuthEvent) void;

/// Event for the writable, abortable, in-transaction `beforeAuthSuccess` hook (#80).
/// Fires after credentials/token are verified (and, for magic-link, the link token is
/// consumed) and the verification gate has passed, but BEFORE the session JWT is issued.
/// The hook's `ctx` is bound to the login's in-transaction writer, so its
/// `ctx.records()` writes commit atomically with the login — and roll back, with the
/// session blocked, if the hook returns an error (fail closed).
pub const AuthSuccessEvent = struct {
    app: *App,
    /// The auth collection name.
    collection: []const u8,
    /// The authenticated record's id.
    record_id: []const u8,
    /// Which method completed (`.password`/`.magic_link`/`.otp`/`.webauthn`/`.oauth2`/`.custom`),
    /// or `.refresh` on the auth-refresh path.
    method: AuthMethod,
    /// The authenticated record (always provided). The hook may also read fresh state
    /// via `ctx.records().get(collection, record_id, .{})` on the bound connection.
    record: std.json.Value,
};
/// `beforeAuthSuccess` handler: writable + abortable. Returning an error ROLLS BACK the
/// login transaction (no session issued); use `ctx.fail(status, msg)` for a chosen status,
/// `error.Forbidden`/`error.Unauthorized` for 403/401, else the response is a generic 500.
///
/// WARNING — the hook runs with a request-bound `*Ctx` whose writer connection is ALREADY
/// HELD inside the login transaction. It MUST NOT call anything that re-acquires the pool
/// writer or opens a new transaction: `ctx.issueSession()`, `ctx.tx()`, or any helper that
/// grabs the writer would attempt to take the single non-reentrant writer a second time and
/// **deadlock permanently** (`ctx.tx` is guarded and returns `error.NestedTransaction`, but
/// the writer-acquiring helpers are not). For side-writes use `ctx.records()` directly — it
/// reuses the bound transaction connection, so the writes commit atomically with the login.
pub const AuthSuccessHandler = *const fn (ctx: *Ctx, ev: *AuthSuccessEvent) anyerror!void;

// ---------------------------------------------------------------------------
// Auth lifecycle hooks (#98) — uniform before/after pairs for register, logout,
// refresh, and password-change, built on the `beforeAuthSuccess` discipline:
// before-hooks are writable + (where a write txn exists) transactional + abortable
// (fail closed); after-hooks are notify-only (errors routed to the backstop).
// ---------------------------------------------------------------------------

// NOTE: adding a variant requires updating authLifecyclePhaseFieldName() and the
// consumer-facing camelCase field name guard.
pub const AuthLifecyclePhase = enum {
    before_register,
    after_register,
    before_logout,
    after_logout,
    before_refresh,
    after_refresh,
    before_password_change,
    after_password_change,
};

/// Event for the auth lifecycle hooks (#98). One type for all eight phases; `phase`
/// discriminates. Before-phase handlers run with a `*Ctx` bound to the endpoint's
/// in-transaction writer where one exists (register/refresh/password-change), so their
/// `ctx.records()` writes commit atomically with the action and roll back on abort.
pub const AuthLifecycleEvent = struct {
    app: *App,
    /// The auth collection name (e.g. "users").
    collection: []const u8,
    /// The principal's record id. "" for `before_register` (no id yet) and for an
    /// unauthenticated logout.
    record_id: []const u8,
    phase: AuthLifecyclePhase,
    /// `before_register`: the writable to-be-created record data — mutate via the hook's
    ///   `ctx.arena` (same contract as a `before_create` RecordEvent); edits are persisted.
    /// `after_register`: the persisted record (id populated).
    /// `before_refresh` / `before_password_change`: a READ-ONLY snapshot of the existing
    ///   record. Mutating `ev.record.*` is unsupported here — the change is NOT isolated (the
    ///   same value backs `onAuth`, the after-hook, and the HTTP response body) and is NOT
    ///   persisted; for mutations use a `before*` record hook or the writable register phase.
    /// logout: null (no record is loaded).
    record: ?*std.json.Value,
};
/// Auth lifecycle handler. Before-phase: writable + abortable (returning any error fails
/// the action closed — where a write txn exists it ROLLS BACK; the response is mapped via
/// the `Ctx` error model: `ctx.fail(status,msg)`, `error.Forbidden`→403, else 500).
/// After-phase: notify-only (errors are routed to the framework error backstop).
pub const AuthLifecycleHandler = *const fn (ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void;

pub const FileEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record_id: []const u8,
    filename: []const u8,
};
/// beforeServe may return error to deny (framework -> 404); afterUpload errors -> backstop.
pub const FileServeHandler = *const fn (ev: *FileEvent) anyerror!void;
pub const FileUploadHandler = *const fn (ev: *FileEvent) void;

pub const LifecycleEvent = struct {
    app: *App,
};
/// Lifecycle handlers (onBootstrap/onBeforeServe/onBeforeTerminate) receive a
/// `*Ctx` (built by the framework from `app`, anonymous rctx, no request) plus
/// the event. DB access goes through `ctx.records()`. Returns an error union so a
/// handler can `try` (e.g. `try ctx.setAppData(...)`, #245); an error from
/// onBootstrap/onBeforeServe fails the boot (fail-fast), an onBeforeTerminate error
/// is logged (it fires in a shutdown defer).
pub const LifecycleHandler = *const fn (ctx: *Ctx, ev: *LifecycleEvent) anyerror!void;

pub const JobEvent = struct {
    app: *App,
    name: []const u8,
};
/// Cron/interval/reactive jobs and `app.submit` tasks receive a `*Ctx` (built by
/// the scheduler per invocation from `app`, anonymous rctx, no request) plus the
/// event. DB access goes through `ctx.records()`; the ctx lazily checks out a
/// pooled connection and releases it on `ctx.deinit()`. For `app.submit`, `name`
/// is queue-owned and valid only for the task invocation; do not free or retain it.
pub const JobTask = *const fn (ctx: *Ctx, ev: *JobEvent) anyerror!void;

/// `@compileError` on any route spec missing a required field (`.method`/`.path`/
/// `.handler`), mirroring `validateHooks`. `.auth` and `.name` are optional (auth
/// defaults to `.superuser`; name defaults to the path-derived name) so they are
/// intentionally not required here. The handler is the TYPED form
/// (`fn(*route_types.Req(In)) route_types.RouteError!Out`); its shape is validated by
/// `route_types.HandlerInput`/`HandlerOutput`'s own `@compileError`s when `routeMeta`
/// reflects it — so no raw-Response coercion check is performed here.
pub fn validateRouteSpecs(comptime specs: anytype) void {
    // The exact keys read by `routeMeta`/`buildRoutes` (and the auth helpers). Kept in
    // lock-step with those readers — a key read there must appear here or a valid spec
    // would falsely @compileError.
    const allowed = [_][]const u8{ "method", "path", "handler", "auth", "name", "rate_limit", "rate_limit_key" };
    inline for (std.meta.fields(@TypeOf(specs))) |f| {
        const s = @field(specs, f.name);
        if (!@hasField(@TypeOf(s), "method")) @compileError("route spec is missing '.method' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "path")) @compileError("route spec is missing '.path' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "handler")) @compileError("route spec is missing '.handler' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        const method: http.Method = s.method;
        if (method == .UNKNOWN)
            @compileError("route '" ++ s.path ++ "': .method cannot be .UNKNOWN");
        if (!route_path.isCanonicalPattern(s.path))
            @compileError("route '" ++ s.path ++ "': .path must be a canonical absolute router pattern with optional :name captures");
        // Fail loud on a typo'd optional key (e.g. `.rate_limt`, `.rate_limit_ky`) which the
        // `@hasField`-gated readers would otherwise silently ignore, shipping the route with
        // NO rate limit / default keying the developer believed they had configured.
        inline for (std.meta.fields(@TypeOf(s))) |sf| {
            comptime var ok = false;
            inline for (allowed) |a| {
                if (comptime std.mem.eql(u8, sf.name, a)) ok = true;
            }
            if (!ok) @compileError("route spec (path '" ++ s.path ++ "'): unknown key '." ++ sf.name ++
                "' (recognized keys: .method, .path, .handler, .auth, .name, .rate_limit, .rate_limit_key)");
        }
    }
}

/// True iff `H` is the UNTYPED route handler form `fn(*Ctx) anyerror!http.Response`.
/// Untyped handlers own the full response (status, cookies, content-type, redirect, raw
/// body), so they are stored directly instead of being wrapped in a typed thunk. Anything
/// else is treated as the typed form `fn(*Req(In)) RouteError!Out`.
pub fn isUntypedHandler(comptime H: type) bool {
    // Accept either a bare `fn(...)` or a single-item function pointer `*const fn(...)`
    // — a handler written as `&myHandler` reflects as `.pointer`, not `.@"fn"`.
    comptime var T = H;
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one) {
        T = @typeInfo(T).pointer.child;
    }
    const info = @typeInfo(T);
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.params.len != 1) return false;
    const p = f.params[0].type orelse return false;
    const pi = @typeInfo(p);
    if (pi != .pointer or pi.pointer.size != .one) return false;
    return pi.pointer.child == Ctx;
}

/// Comptime route metadata for a typed route spec: the derived method name plus the
/// reflected Input/Output types (the bounded Zig→TS subset surfaces). Consumed by the
/// framework's comptime route assembly (collision + representability checks) and by the
/// codegen generator (SP2.2b) to emit the TS RPC surface.
pub const RouteMeta = struct {
    method: http.Method,
    path: []const u8,
    name: []const u8,
    auth: AuthLevel,
    Input: type,
    Output: type,
    /// Redacted declarative guard metadata for contract generators.
    path_secret: ?PathSecretMeta = null,
    /// Collection-scoped principal restriction, when present.
    authed_collection: ?AuthedCollection = null,
    /// True for untyped `fn(*Ctx) anyerror!http.Response` handlers, which own the
    /// raw response and contribute no typed RPC surface. The TS codegen skips these so it
    /// doesn't emit a client method that would mis-handle their non-JSON responses.
    untyped: bool = false,
};

/// Comptime metadata for a TYPED custom auth method: the owning collection + slug
/// plus the reflected Zig I/O types for its `initiate`/`complete` flows. Mirrors
/// `RouteMeta` — it carries comptime-only `type` fields and is consumed by the TS
/// client generator (`gen_client.generate`) to emit precise interfaces for custom
/// auth methods, exactly as `RouteMeta` drives the typed `rpc.*` surface.
///
/// Bare-string custom entries (`.custom = .{"slug"}`) produce NO `CustomAuthMeta`;
/// they remain untyped (the generator falls back to the `Record<string, unknown>`
/// stub for any enabled slug it cannot find a meta for). Defaults are `void`, which
/// the generator maps to "omit the input arg" / `Promise<void>`.
pub const CustomAuthMeta = struct {
    col_name: []const u8,
    slug: []const u8,
    InitiateInput: type = void,
    InitiateOutput: type = void,
    CompleteInput: type = void,
    CompleteOutput: type = void,
};

/// Comptime guard for a custom-auth `.Initiate`/`.Complete` sub-struct: it must be a
/// struct whose only keys are `.Input`/`.Output`. A typo'd key would otherwise be
/// silently ignored and the type would default to `void` (loud-comptime convention).
fn validateFlowKeys(comptime Flow: type, comptime col_name: []const u8, comptime which: []const u8) void {
    comptime {
        if (@typeInfo(Flow) != .@"struct")
            @compileError("collection '" ++ col_name ++ "' custom auth entry ." ++ which ++ " must be a struct of the form .{ .Input = T, .Output = U }");
        for (std.meta.fields(Flow)) |kf| {
            if (!std.mem.eql(u8, kf.name, "Input") and !std.mem.eql(u8, kf.name, "Output"))
                @compileError("collection '" ++ col_name ++ "' custom auth entry ." ++ which ++ ": unknown key '." ++ kf.name ++ "' (recognized keys: .Input, .Output)");
        }
    }
}

/// Reflect a raw `.collections` config literal into `[]const CustomAuthMeta`, one
/// entry per STRUCT custom-auth method across all collections. Walks each
/// collection's `.auth.methods.custom` tuple; bare-string elements are skipped
/// (they stay untyped via the runtime slug list lowered in `provision.zig`), struct
/// elements `.{ .slug, .Initiate = .{ .Input, .Output }, .Complete = .{ .Input,
/// .Output } }` yield a meta entry. `@compileError`s (loud-comptime convention) on a
/// struct missing `.slug`, an unknown key, or a non-representable I/O type.
pub fn customAuthMeta(comptime cols_cfg: anytype) []const CustomAuthMeta {
    comptime {
        @setEvalBranchQuota(100_000);
        const Cfg = @TypeOf(cols_cfg);
        const cinfo = @typeInfo(Cfg);
        if (cinfo != .@"struct") return &.{};
        var list: []const CustomAuthMeta = &.{};
        for (cinfo.@"struct".fields) |cf| {
            const col_name = cf.name;
            const spec = @field(cols_cfg, col_name);
            if (@typeInfo(@TypeOf(spec)) != .@"struct") continue;
            if (!@hasField(@TypeOf(spec), "auth")) continue;
            const auth = spec.auth;
            if (@typeInfo(@TypeOf(auth)) != .@"struct") continue;
            if (!@hasField(@TypeOf(auth), "methods")) continue;
            const methods = auth.methods;
            if (@typeInfo(@TypeOf(methods)) != .@"struct") continue;
            if (!@hasField(@TypeOf(methods), "custom")) continue;
            const custom = methods.custom;
            // `.custom` may be a bare tuple `.{ ... }` or a `&.{ ... }` pointer-to-tuple.
            const tup = if (@typeInfo(@TypeOf(custom)) == .pointer) custom.* else custom;
            const TT = @TypeOf(tup);
            if (@typeInfo(TT) != .@"struct")
                @compileError("collection '" ++ col_name ++ "' .auth.methods.custom must be a tuple of slug strings and/or typed-method structs");
            for (std.meta.fields(TT)) |ef| {
                const elem = @field(tup, ef.name);
                const E = @TypeOf(elem);
                switch (@typeInfo(E)) {
                    // Bare slug string (`*const [N:0]u8` or `[]const u8`) → untyped, no meta.
                    .pointer => {},
                    .@"struct" => {
                        if (!@hasField(E, "slug"))
                            @compileError("collection '" ++ col_name ++ "' custom auth entry must be a slug string or a struct with a .slug field");
                        // Loud-comptime: reject typo'd keys on the typed entry.
                        for (std.meta.fields(E)) |kf| {
                            if (!std.mem.eql(u8, kf.name, "slug") and
                                !std.mem.eql(u8, kf.name, "Initiate") and
                                !std.mem.eql(u8, kf.name, "Complete"))
                                @compileError("collection '" ++ col_name ++ "' custom auth entry: unknown key '." ++ kf.name ++ "' (recognized keys: .slug, .Initiate, .Complete)");
                        }
                        var meta = CustomAuthMeta{ .col_name = col_name, .slug = elem.slug };
                        // Loud-comptime: an `.Initiate`/`.Complete` sub-struct must be a
                        // struct whose only keys are `.Input`/`.Output` — otherwise a typo
                        // like `.input`/`.ouput` would SILENTLY fall back to `void`.
                        if (@hasField(E, "Initiate")) {
                            const ini = elem.Initiate;
                            validateFlowKeys(@TypeOf(ini), col_name, "Initiate");
                            if (@hasField(@TypeOf(ini), "Input")) meta.InitiateInput = ini.Input;
                            if (@hasField(@TypeOf(ini), "Output")) meta.InitiateOutput = ini.Output;
                        }
                        if (@hasField(E, "Complete")) {
                            const cmp = elem.Complete;
                            validateFlowKeys(@TypeOf(cmp), col_name, "Complete");
                            if (@hasField(@TypeOf(cmp), "Input")) meta.CompleteInput = cmp.Input;
                            if (@hasField(@TypeOf(cmp), "Output")) meta.CompleteOutput = cmp.Output;
                        }
                        for ([_]struct { t: type, w: []const u8 }{
                            .{ .t = meta.InitiateInput, .w = "Initiate.Input" },
                            .{ .t = meta.InitiateOutput, .w = "Initiate.Output" },
                            .{ .t = meta.CompleteInput, .w = "Complete.Input" },
                            .{ .t = meta.CompleteOutput, .w = "Complete.Output" },
                        }) |chk| {
                            if (!rpc_ts.isRepresentable(chk.t))
                                @compileError("custom auth method '" ++ meta.slug ++ "' on collection '" ++ col_name ++ "': " ++ chk.w ++ " type '" ++ @typeName(chk.t) ++ "' is not representable in the TS subset (allowed: void, bool, int, float, []const u8, enum, std.json.Value, optional, slice, and structs thereof)");
                        }
                        list = list ++ &[_]CustomAuthMeta{meta};
                    },
                    else => @compileError("collection '" ++ col_name ++ "' custom auth entry must be a slug string or a struct with a .slug field"),
                }
            }
        }
        return list;
    }
}

/// Comptime path→method-name (mirrors codegen `identifiers.routeMethodName`) with an
/// optional `.name` override. Strips the "/api" prefix + ":param" segments, then
/// camel-joins the remaining literal bytes into an identifier. URI punctuation acts
/// as a word separator (`robots.txt` -> `robotsTxt`), and a leading digit is prefixed
/// with `_` (`2fa/verify` -> `_2faVerify`). Comptime-friendly (no allocator) for the
/// framework-side collision check; a drift-guard pins the runtime reference helper.
pub fn comptimeRouteName(comptime path: []const u8, comptime override: ?[]const u8) []const u8 {
    if (override) |n| return n;
    return comptime blk: {
        var rest: []const u8 = path;
        const prefix = "/api";
        if (std.mem.eql(u8, rest, prefix)) {
            rest = "";
        } else if (std.mem.startsWith(u8, rest, prefix ++ "/")) {
            rest = rest[prefix.len..];
        }
        var name: []const u8 = "";
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or seg[0] == ':') continue;
            var upper_next = name.len > 0;
            for (seg) |ch| {
                if (!std.ascii.isAlphanumeric(ch)) {
                    upper_next = true;
                    continue;
                }
                if (name.len == 0 and std.ascii.isDigit(ch)) name = "_";
                const c = if (name.len == 0)
                    std.ascii.toLower(ch)
                else if (upper_next)
                    std.ascii.toUpper(ch)
                else
                    ch;
                name = name ++ &[_]u8{c};
                upper_next = false;
            }
        }
        break :blk name;
    };
}

/// Reflect a comptime tuple of typed route specs into `[]const RouteMeta`. Per spec,
/// reads `.method`/`.path`/`.auth` (auth defaults to `.superuser`), derives the method
/// name (`.name` override or `comptimeRouteName`), and reflects the handler's Input/Output
/// via `route_types.HandlerInput`/`HandlerOutput` (which `@compileError` on a wrong-shaped
/// handler). The `Holder`-const pattern gives the table static lifetime so the `[]const`
/// slice is returnable.
pub fn routeMeta(comptime specs: anytype) []const RouteMeta {
    const fields = std.meta.fields(@TypeOf(specs));
    comptime {
        @setEvalBranchQuota(10_000 + fields.len * 5_000); // scale with route count
        validateRouteSpecs(specs);
    }
    const Holder = struct {
        const table: [fields.len]RouteMeta = blk: {
            @setEvalBranchQuota(10_000 + fields.len * 5_000); // scale with route count
            var t: [fields.len]RouteMeta = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const H = @TypeOf(s.handler);
                const untyped = isUntypedHandler(H);
                const override: ?[]const u8 = if (@hasField(@TypeOf(s), "name")) s.name else null;
                const name = comptimeRouteName(s.path, override);
                if (!route_path.isIdentifier(name))
                    @compileError("route '" ++ s.path ++ "' has invalid method name '" ++ name ++ "'; set '.name' to an identifier such as 'reportV1'");
                const guard = routeAuthGuard(s);
                t[i] = .{
                    .method = s.method,
                    .path = s.path,
                    .name = name,
                    // `.auth` may be an AuthLevel literal OR a guard struct; the guard maps to
                    // a `.public` AuthLevel here (the secret is the gate). See `routeAuthLevel`.
                    .auth = routeAuthLevel(s),
                    // Untyped handlers own the raw response; they contribute no typed RPC
                    // surface, so Input/Output are void (representable + query-parseable)
                    // and `untyped` flags them out of TS RPC codegen.
                    .Input = if (untyped) void else route_types.HandlerInput(H),
                    .Output = if (untyped) void else route_types.HandlerOutput(H),
                    .path_secret = if (guard) |g| switch (g) {
                        .path_secret => |ps| .{
                            .param = ps.param,
                            .in = ps.in,
                            .on_mismatch = ps.on_mismatch,
                        },
                    } else null,
                    .authed_collection = routeAuthedCollection(s),
                    .untyped = untyped,
                };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Assemble a comptime tuple of TYPED route specs into a runtime route table. Each spec is
/// `.{ .method, .path, .handler, .auth = .public|.authed|.superuser, .name = "..." }`;
/// `.auth` defaults to `.superuser` (safe default) and `.name` defaults to the path-derived
/// name when omitted. The handler is `fn(*route_types.Req(In)) route_types.RouteError!Out`;
/// it is wrapped in `route_types.makeThunk` so the stored `.handler` is a RouteHandler.
/// Comptime-validates each route's Input/Output representability and `@compileError`s on a
/// duplicate derived method name.
pub fn buildRoutes(comptime specs: anytype) []const RuntimeRoute {
    const fields = std.meta.fields(@TypeOf(specs));
    const meta = comptime routeMeta(specs);
    // Representability + duplicate-name guards, all at comptime.
    comptime {
        @setEvalBranchQuota(10_000 + meta.len * 5_000); // scale with route count
        for (meta, 0..) |m, i| {
            if (m.name.len == 0)
                @compileError("route '" ++ m.path ++ "' derives an empty method name; add an explicit .name to the route spec");
            route_types.assertRepresentable(m.Input, m.name);
            route_types.assertRepresentable(m.Output, m.name);
            // GET/HEAD/DELETE routes communicate their Input via a query string.
            // If the Input is representable but not query-parseable (e.g. contains a
            // non-string slice or a nested struct), the server's `parseQuery` cannot
            // decode it and every call would get a misleading 400 at runtime. Catch it
            // at build time instead.
            if (route_types.inputUsesQuery(m.method)) {
                if (!route_types.isQueryParseable(m.Input))
                    @compileError("route '" ++ m.name ++ "': GET/HEAD/DELETE Input must be encodable as a query string (scalars/enums/strings/optionals only); got a type with a non-query field. Use POST/PUT/PATCH for a JSON body, or simplify the Input.");
            }
            for (meta[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, m.name))
                    @compileError("duplicate route method name '" ++ m.name ++ "' (paths '" ++ prev.path ++ "' and '" ++ m.path ++ "') — add a distinct .name");
            }
        }
    }
    // A struct-namespace const has static lifetime, so &Holder.table is a valid []const returnable at runtime (a plain comptime local is not).
    const Holder = struct {
        const table: [fields.len]RuntimeRoute = blk: {
            @setEvalBranchQuota(10_000 + fields.len * 5_000); // scale with route count
            var t: [fields.len]RuntimeRoute = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const auth: AuthLevel = routeAuthLevel(s);
                // Untyped handlers already match RouteHandler — store directly so they keep
                // full control of the response (cookies/redirect/content-type). Typed handlers
                // are wrapped in a thunk that parses Input and serializes Output as JSON.
                const handler = if (isUntypedHandler(@TypeOf(s.handler))) s.handler else route_types.makeThunk(s.handler);
                // Route-guard pipeline (#139/#142): lower the optional `.auth` guard and
                // `.rate_limit` (via the shared `schema.buildRateLimitOpt`); both are enforced
                // before the handler in `server.zig dispatchCustom`.
                const rate_limit: schema.RateLimitOpt = if (@hasField(@TypeOf(s), "rate_limit"))
                    schema.buildRateLimitOpt(s.rate_limit)
                else
                    .default;
                const rate_limit_key: ?RateLimitKeyFn = if (@hasField(@TypeOf(s), "rate_limit_key")) s.rate_limit_key else null;
                t[i] = .{
                    .method = s.method,
                    .pattern = s.path,
                    .handler = handler,
                    .auth = auth,
                    .auth_guard = routeAuthGuard(s),
                    .authed_collection = routeAuthedCollection(s),
                    .rate_limit = rate_limit,
                    .rate_limit_key = rate_limit_key,
                };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Runtime, type-erased dispatch surface stored on `App`. The comptime App(cfg)
/// builder (a later task) fills these with generated functions; null = no subscribers.
pub const Dispatch = struct {
    record: ?RecordHandler = null,
    on_error: ?ErrorHandler = null,
    routes: []const RuntimeRoute = &.{},
    on_auth: ?AuthHandler = null,
    before_auth_success: ?AuthSuccessHandler = null,
    /// Generated by `buildAuthLifecycleDispatcher(cfg.auth)`; routes by phase to the
    /// registered register/logout/refresh/password-change before/after handler.
    auth_lifecycle: ?AuthLifecycleHandler = null,
    on_file_serve: ?FileServeHandler = null,
    on_file_upload: ?FileUploadHandler = null,
    on_bootstrap: ?LifecycleHandler = null,
    on_before_serve: ?LifecycleHandler = null,
    on_before_terminate: ?LifecycleHandler = null,
    /// Generated from `cfg.onFeatureExposure`; null = no subscribers (zero-cost).
    on_feature_exposure: ?ExposureHandler = null,
    /// Consumer realtime subscribe guard (#143), from `.realtime = .{ .canSubscribe = fn }`.
    /// null = custom topics are PUBLIC signal channels (the historical `__features` default).
    realtime_can_subscribe: ?RealtimeCanSubscribeFn = null,
    /// #245 app-scoped context: `@typeName(cfg.app_context)` when the App declared
    /// `.app_context = T`, else null. Non-null activates the boot contract — `serveImpl`
    /// fails fast if `onBootstrap` never called `ctx.setAppData` (app.app_context stays null).
    /// Only used for the declared-but-unset diagnostic; the live handle lives on `App`.
    app_context_type: ?[]const u8 = null,
};

/// Map a comptime RecordPhase to its hook-config field name.
fn phaseFieldName(comptime p: RecordPhase) []const u8 {
    return switch (p) {
        .before_create => "beforeCreate",
        .after_create => "afterCreate",
        .before_update => "beforeUpdate",
        .after_update => "afterUpdate",
        .before_delete => "beforeDelete",
        .after_delete => "afterDelete",
    };
}

/// True iff `name` is one of the six canonical camelCase phase field names.
/// Kept DRY with `phaseFieldName` by deriving the set from `RecordPhase`.
fn isPhaseFieldName(comptime name: []const u8) bool {
    inline for (std.meta.fields(RecordPhase)) |p| {
        if (std.mem.eql(u8, name, phaseFieldName(@field(RecordPhase, p.name)))) return true;
    }
    return false;
}

/// `@compileError` on any hook-group field whose name is not a canonical phase
/// name, so a typo (e.g. `.beforeCreat`) fails loudly instead of silently
/// never firing. Runs over every group, including the `any` wildcard.
fn validateHooks(comptime hooks: anytype) void {
    inline for (std.meta.fields(@TypeOf(hooks))) |group| {
        const g = @field(hooks, group.name);
        switch (@typeInfo(@TypeOf(g))) {
            .@"struct" => {},
            else => @compileError("record hook group '" ++ group.name ++ "' must be a struct like .{ .beforeCreate = fn }"),
        }
        inline for (std.meta.fields(@TypeOf(g))) |f| {
            if (!isPhaseFieldName(f.name)) {
                @compileError("unknown record hook '" ++ group.name ++ "." ++ f.name ++
                    "'; expected one of beforeCreate/afterCreate/beforeUpdate/afterUpdate/beforeDelete/afterDelete");
            }
            // Assert the value coerces to RecordHandler so a wrong-typed hook fails loudly too.
            const _coerce: RecordHandler = @field(g, f.name);
            _ = _coerce;
        }
    }
}

/// Generate a record dispatcher from a comptime hook config of the shape:
///   .{ .any = .{ .beforeCreate = fn, ... }, .<collection> = .{ .afterUpdate = fn, ... } }
/// `any` (wildcard) handlers fire first, then the collection-specific group whose
/// field name equals ev.collection. Within a group, only the field matching ev.phase
/// runs. Handlers run in declaration order; errors propagate.
pub fn buildRecordDispatcher(comptime hooks: anytype) RecordHandler {
    comptime validateHooks(hooks);
    const Gen = struct {
        fn dispatch(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            // Pass 1: wildcard ("any") groups. Pass 2: collection-specific groups.
            inline for (.{ true, false }) |wildcard_pass| {
                inline for (std.meta.fields(@TypeOf(hooks))) |group| {
                    const is_wildcard = comptime std.mem.eql(u8, group.name, "any");
                    // Only the groups belonging to the current pass participate.
                    if (comptime is_wildcard == wildcard_pass) {
                        // Non-wildcard groups gate on the runtime collection name.
                        const collection_matches = is_wildcard or std.mem.eql(u8, ev.collection, group.name);
                        if (collection_matches) {
                            const g = @field(hooks, group.name);
                            switch (ev.phase) {
                                inline else => |p| {
                                    const fname = comptime phaseFieldName(p);
                                    if (@hasField(@TypeOf(g), fname)) {
                                        try @field(g, fname)(ctx, ev);
                                    }
                                },
                            }
                        }
                    }
                }
            }
        }
    };
    return Gen.dispatch;
}

/// Map a comptime AuthLifecyclePhase to its `.auth` config-group field name.
fn authLifecyclePhaseFieldName(comptime p: AuthLifecyclePhase) []const u8 {
    return switch (p) {
        .before_register => "beforeRegister",
        .after_register => "afterRegister",
        .before_logout => "beforeLogout",
        .after_logout => "afterLogout",
        .before_refresh => "beforeRefresh",
        .after_refresh => "afterRefresh",
        .before_password_change => "beforePasswordChange",
        .after_password_change => "afterPasswordChange",
    };
}

/// True iff `name` is one of the eight canonical camelCase lifecycle field names.
fn isAuthLifecycleFieldName(comptime name: []const u8) bool {
    inline for (std.meta.fields(AuthLifecyclePhase)) |p| {
        if (std.mem.eql(u8, name, authLifecyclePhaseFieldName(@field(AuthLifecyclePhase, p.name)))) return true;
    }
    return false;
}

/// `@compileError` on any `.auth` group field whose name is not a canonical phase
/// name, so a typo (e.g. `.beforeRegsiter`) fails loudly instead of silently never
/// firing. Mirrors `validateHooks`.
fn validateAuthLifecycleHooks(comptime auth_cfg: anytype) void {
    switch (@typeInfo(@TypeOf(auth_cfg))) {
        .@"struct" => {},
        else => @compileError("App cfg '.auth' must be a struct like .{ .beforeRegister = fn }"),
    }
    inline for (std.meta.fields(@TypeOf(auth_cfg))) |f| {
        if (!isAuthLifecycleFieldName(f.name)) {
            @compileError("unknown auth lifecycle hook 'auth." ++ f.name ++
                "'; expected one of beforeRegister/afterRegister/beforeLogout/afterLogout/beforeRefresh/afterRefresh/beforePasswordChange/afterPasswordChange");
        }
        // Assert the value coerces to AuthLifecycleHandler so a wrong-typed hook fails loudly too.
        const _coerce: AuthLifecycleHandler = @field(auth_cfg, f.name);
        _ = _coerce;
    }
}

/// Generate an auth-lifecycle dispatcher from a comptime `.auth` config group of the shape:
///   .{ .beforeRegister = fn, .afterRegister = fn, .beforeLogout = fn, ... }
/// Only the field matching `ev.phase` runs; an unregistered phase is a no-op. Errors
/// propagate (the firing site decides abort-vs-backstop, like `emitRecord`).
pub fn buildAuthLifecycleDispatcher(comptime auth_cfg: anytype) AuthLifecycleHandler {
    comptime validateAuthLifecycleHooks(auth_cfg);
    const Gen = struct {
        fn dispatch(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            switch (ev.phase) {
                inline else => |p| {
                    const fname = comptime authLifecyclePhaseFieldName(p);
                    if (@hasField(@TypeOf(auth_cfg), fname)) {
                        try @field(auth_cfg, fname)(ctx, ev);
                    }
                },
            }
        }
    };
    return Gen.dispatch;
}

test "auth lifecycle dispatcher fires only the matching phase; mutation sticks" {
    const H = struct {
        var before_register_calls: usize = 0;
        var after_register_calls: usize = 0;
        fn onBeforeRegister(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_register_calls += 1;
            if (ev.record) |r| try r.object.put(std.testing.allocator, "seeded", .{ .bool = true });
        }
        fn onAfterRegister(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_register_calls += 1;
        }
    };
    H.before_register_calls = 0;
    H.after_register_calls = 0;
    const dispatch = buildAuthLifecycleDispatcher(.{
        .beforeRegister = H.onBeforeRegister,
        .afterRegister = H.onAfterRegister,
    });

    var rec: std.json.Value = .{ .object = .empty };
    defer rec.object.deinit(std.testing.allocator);
    var ctx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();

    var ev = AuthLifecycleEvent{ .app = undefined, .collection = "users", .record_id = "", .phase = .before_register, .record = &rec };
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.before_register_calls);
    try std.testing.expectEqual(@as(usize, 0), H.after_register_calls);
    try std.testing.expect(rec.object.get("seeded").?.bool == true);

    // An unregistered phase is a no-op (no handler for logout here).
    ev.phase = .before_logout;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.before_register_calls);

    ev.phase = .after_register;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.after_register_calls);
}

test "auth lifecycle before-hook error propagates (abort signal)" {
    const H = struct {
        fn boom(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            return error.RegisterRejected;
        }
    };
    const dispatch = buildAuthLifecycleDispatcher(.{ .beforeRegister = H.boom });
    var ctx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    var ev = AuthLifecycleEvent{ .app = undefined, .collection = "users", .record_id = "", .phase = .before_register, .record = null };
    try std.testing.expectError(error.RegisterRejected, dispatch(&ctx, &ev));
    // A phase with no registered handler is a clean no-op even when others would error.
    ev.phase = .after_logout;
    try dispatch(&ctx, &ev);
}

// NOTE: a typo'd lifecycle hook name is rejected at COMPILE time by
// `validateAuthLifecycleHooks` — e.g. `buildAuthLifecycleDispatcher(.{ .beforeRegsiter = fn })`
// is a `@compileError`. It cannot be asserted at runtime (it would fail the build), so it is
// covered by the same mechanism the record-hook typo guard uses (`validateHooks`).

test "record dispatcher fires wildcard then specific, in order, and mutations stick" {
    const Trace = struct {
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn wild(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            try seq.append(std.testing.allocator, "wild");
            try ev.record.object.put(std.testing.allocator, "touched", .{ .bool = true });
        }
        fn specific(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            try seq.append(std.testing.allocator, "specific");
            _ = ev;
        }
    };
    defer Trace.seq.deinit(std.testing.allocator);

    const hooks = .{
        .any = .{ .beforeCreate = Trace.wild },
        .posts = .{ .beforeCreate = Trace.specific },
    };
    const dispatch = buildRecordDispatcher(hooks);

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "touched", .{ .bool = false });
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .rctx = undefined, .arena = RequestArena.forTest(std.testing.allocator), .collection = "posts", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();

    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 2), Trace.seq.items.len);
    try std.testing.expectEqualStrings("wild", Trace.seq.items[0]);
    try std.testing.expectEqualStrings("specific", Trace.seq.items[1]);
    try std.testing.expect(rec.object.get("touched").?.bool == true);
}

test "before hook error aborts (propagates) and unrelated collection is skipped" {
    const H = struct {
        fn boom(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            return error.HookRejected;
        }
    };
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .beforeCreate = H.boom } });

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .rctx = undefined, .arena = RequestArena.forTest(std.testing.allocator), .collection = "comments", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    try dispatch(&ctx, &ev); // "comments" not registered -> no-op, no error

    ev.collection = "posts";
    try std.testing.expectError(error.HookRejected, dispatch(&ctx, &ev));
}

/// Route a framework-caught error: run the consumer onError handler (if any), then hand the
/// report to the pluggable error reporter (the terminal backstop). Never propagates.
///
/// Delivery is NON-BLOCKING (#244 stage 2): instead of calling `app.reporter.report(...)`
/// inline (a `SentryReporter` would do a synchronous HTTPS POST on the erroring thread), the
/// report is enqueued as a `"report"` job on the MEMORY queue and delivered on a pool worker
/// (`report/send.zig`) — off the erroring thread, never touching the DB writer. With no pool
/// installed (unit tests / CLI) the handler runs inline, deterministically.
///
/// Optional TTL DEDUP (#244 stage 2): when `app.report_dedup` is installed (the default; the
/// `.reporter_dedup` comptime knob), an identical `(message, phase)` seen within the window is
/// suppressed — one delivery per window instead of a flood. When `.off`, `app.report_dedup`
/// is null and this is a single null-pointer branch (no map, no cost).
///
/// A booted app always has a reporter wired (SentryReporter when a DSN is set, else
/// LogReporter); the null-reporter branch is the log fallback for un-booted test/CLI apps,
/// emitting the same structured backstop line `[phase] err_name: message` (see
/// `report_log.formatLine`).
pub fn dispatchError(app: *App, dispatch: ?*const Dispatch, ev: *ErrorEvent) void {
    if (dispatch) |d| {
        if (d.on_error) |h| h(ev);
    }
    const r = report_reporter.Report{
        .message = ev.message,
        .err_name = @errorName(ev.err),
        .phase = @tagName(ev.phase),
    };
    // TTL dedup: suppress a repeat of the same (message, phase) within the window. Comptime-
    // gated to zero cost when `.reporter_dedup = .off` (app.report_dedup stays null).
    if (app.report_dedup) |dd| {
        if (!dd.shouldReport(app.io, r.message, r.phase)) return;
    }
    if (app.reporter != null) {
        // Non-blocking: hand off to the memory queue; the "report" job POSTs on a worker.
        report_send.enqueueReport(app, r);
    } else {
        // Un-booted app (no reporter wired) — preserve the log-only backstop.
        report_log.emit(r);
    }
}

/// Fire the feature-exposure hook for a resolved FLAG, but ONLY when a handler is
/// registered — the `orelse return` short-circuits before the `ExposureEvent` is
/// even constructed, so an app without `.onFeatureExposure` pays nothing on the read
/// path (mirrors `dispatchError`'s null-gating).
pub fn dispatchFlagExposure(app: *App, dispatch: ?*const Dispatch, name: []const u8, value: bool) void {
    const d = dispatch orelse return;
    const h = d.on_feature_exposure orelse return;
    var ev = ExposureEvent{ .app = app, .kind = .flag, .name = name, .subject = "", .value = value };
    h(&ev);
}

/// Fire the feature-exposure hook for a resolved EXPERIMENT, zero-cost when unset
/// (see `dispatchFlagExposure`).
pub fn dispatchExperimentExposure(app: *App, dispatch: ?*const Dispatch, name: []const u8, subject: []const u8, variant: []const u8) void {
    const d = dispatch orelse return;
    const h = d.on_feature_exposure orelse return;
    var ev = ExposureEvent{ .app = app, .kind = .experiment, .name = name, .subject = subject, .variant = variant };
    h(&ev);
}

test "dispatchError runs consumer handler before the backstop" {
    const H = struct {
        // Records the order in which the consumer handler and the backstop ran.
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn onErr(ev: *ErrorEvent) void {
            _ = ev;
            seq.append(std.testing.allocator, "handler") catch {};
        }
        fn sink(_: []const u8) void {
            seq.append(std.testing.allocator, "backstop") catch {};
        }
    };
    H.seq = .empty;
    defer H.seq.deinit(std.testing.allocator);

    var app: App = undefined;
    app.allocator = std.testing.allocator;
    app.reporter = null; // un-booted app -> dispatchError takes the log fallback path
    app.report_dedup = null; // dedup disabled for this test
    // Route the log-mode fallback into our sink so it is observable and does not
    // emit a real std.log.err (which Zig's test runner would count as a failure).
    report_log.log_sink = H.sink;
    defer report_log.log_sink = null;

    var d = Dispatch{ .on_error = H.onErr };
    var ev = ErrorEvent{ .app = &app, .ctx = null, .err = error.Boom, .phase = .after_hook, .message = "x" };
    dispatchError(&app, &d, &ev);

    try std.testing.expectEqual(@as(usize, 2), H.seq.items.len);
    try std.testing.expectEqualStrings("handler", H.seq.items[0]);
    try std.testing.expectEqualStrings("backstop", H.seq.items[1]);
}

test "dispatchError dedup: identical errors within the window report once; .off reports each" {
    // A lightweight counting reporter; report delivery runs inline (no memory pool) so each
    // non-suppressed dispatchError increments the counter synchronously.
    const R = struct {
        var count: usize = 0;
        fn report(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, r: report_reporter.Report) anyerror!void {
            _ = ptr;
            _ = io;
            _ = alloc;
            _ = r;
            count += 1;
        }
        const vt = report_reporter.Reporter.VTable{ .report = report };
    };
    R.count = 0;
    var rep_ctx: u8 = 0;
    var iface = report_reporter.Reporter{ .ptr = &rep_ctx, .vtable = &R.vt };

    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    app.reporter = &iface;

    // Dedup ON (60s window): a repeat (message,phase) within the window is suppressed.
    var dd = report_dedup.Dedup.init(std.testing.allocator, 60);
    defer dd.deinit();
    app.report_dedup = &dd;

    var ev1 = ErrorEvent{ .app = &app, .ctx = null, .err = error.Boom, .phase = .request, .message = "same" };
    dispatchError(&app, null, &ev1);
    dispatchError(&app, null, &ev1); // identical, within window → suppressed
    try std.testing.expectEqual(@as(usize, 1), R.count);

    var ev2 = ErrorEvent{ .app = &app, .ctx = null, .err = error.Boom, .phase = .request, .message = "different" };
    dispatchError(&app, null, &ev2); // distinct message → reports
    try std.testing.expectEqual(@as(usize, 2), R.count);

    // Dedup OFF (app.report_dedup == null) → EVERY error reports, even identical ones.
    app.report_dedup = null;
    R.count = 0;
    dispatchError(&app, null, &ev1);
    dispatchError(&app, null, &ev1);
    try std.testing.expectEqual(@as(usize, 2), R.count);
}

test "dispatch*Exposure fires the handler with the right fields and is zero-cost when unset" {
    const H = struct {
        var calls: usize = 0;
        var last: ExposureEvent = undefined;
        fn onExposure(ev: *ExposureEvent) void {
            calls += 1;
            last = ev.*;
        }
    };
    H.calls = 0;
    var app: App = undefined;

    // No handler registered (or no dispatch at all) -> never invoked (zero-cost path).
    dispatchFlagExposure(&app, null, "beta", true);
    var empty = Dispatch{};
    dispatchFlagExposure(&app, &empty, "beta", true);
    dispatchExperimentExposure(&app, &empty, "layout", "user-1", "compact");
    try std.testing.expectEqual(@as(usize, 0), H.calls);

    // Handler registered -> fired with the resolved kind/name/subject/value|variant.
    var d = Dispatch{ .on_feature_exposure = H.onExposure };
    dispatchFlagExposure(&app, &d, "beta", true);
    try std.testing.expectEqual(@as(usize, 1), H.calls);
    try std.testing.expectEqual(ExposureKind.flag, H.last.kind);
    try std.testing.expectEqualStrings("beta", H.last.name);
    try std.testing.expectEqualStrings("", H.last.subject);
    try std.testing.expect(H.last.value);

    dispatchExperimentExposure(&app, &d, "layout", "user-1", "compact");
    try std.testing.expectEqual(@as(usize, 2), H.calls);
    try std.testing.expectEqual(ExposureKind.experiment, H.last.kind);
    try std.testing.expectEqualStrings("layout", H.last.name);
    try std.testing.expectEqualStrings("user-1", H.last.subject);
    try std.testing.expectEqualStrings("compact", H.last.variant);
}

test "only the matching phase's handler runs" {
    const H = struct {
        var after_calls: usize = 0;
        fn onAfter(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_calls += 1;
        }
    };
    H.after_calls = 0;
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .afterCreate = H.onAfter } });
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .rctx = undefined, .arena = RequestArena.forTest(std.testing.allocator), .collection = "posts", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    try dispatch(&ctx, &ev); // before_create fired, but only afterCreate is registered -> no call
    try std.testing.expectEqual(@as(usize, 0), H.after_calls);
    ev.phase = .after_create;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.after_calls);
}

test "buildRoutes assembles a runtime route table preserving order, method, pattern, auth" {
    const H = struct {
        fn a(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
        fn b(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/x", .handler = H.a, .auth = .public },
        .{ .method = .POST, .path = "/api/y", .handler = H.b, .auth = .superuser },
    });
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expect(table[0].method == .GET);
    try std.testing.expectEqualStrings("/api/x", table[0].pattern);
    try std.testing.expect(table[0].auth == .public);
    try std.testing.expect(table[1].method == .POST);
    try std.testing.expect(table[1].auth == .superuser);
}

test "buildRoutes builds thunks + metadata with derived names" {
    const In = struct { n: u32 };
    const Out = struct { doubled: u32 };
    const Specs = struct {
        fn confirm(req: *route_types.Req(In)) route_types.RouteError!Out {
            return .{ .doubled = req.input.n * 2 };
        }
        fn health(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const specs = .{
        .{ .method = http.Method.POST, .path = "/api/items/:id/confirm", .handler = Specs.confirm, .auth = AuthLevel.authed },
        .{ .method = http.Method.GET, .path = "/api/health", .handler = Specs.health },
    };
    const routes = buildRoutes(specs);
    try std.testing.expectEqual(@as(usize, 2), routes.len);
    try std.testing.expectEqual(http.Method.POST, routes[0].method);

    const meta = comptime routeMeta(specs);
    try std.testing.expectEqualStrings("itemsConfirm", meta[0].name);
    try std.testing.expectEqualStrings("health", meta[1].name);
    try std.testing.expectEqual(AuthLevel.authed, meta[0].auth);
    try std.testing.expect(meta[0].Input == In);
    try std.testing.expect(meta[0].Output == Out);
    try std.testing.expect(meta[1].Input == void);
}

test "route metadata derives identifiers from ordinary literal URI paths" {
    const H = struct {
        fn run(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const meta = comptime routeMeta(.{
        .{ .method = .GET, .path = "/robots.txt", .handler = H.run, .auth = .public },
        .{ .method = .POST, .path = "/api/2fa/verify", .handler = H.run, .auth = .public },
        .{ .method = .GET, .path = "/apian/status", .handler = H.run, .auth = .public },
    });
    try std.testing.expectEqualStrings("robotsTxt", meta[0].name);
    try std.testing.expectEqualStrings("_2faVerify", meta[1].name);
    try std.testing.expectEqualStrings("apianStatus", meta[2].name);
}

test "buildRoutes defaults auth to .superuser when omitted" {
    const H = struct {
        fn a(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/secret", .handler = H.a },
    });
    try std.testing.expect(table[0].auth == .superuser);
}

test "buildRoutes lowers a path_secret guard: .auth=.public + carried guard (#139)" {
    const H = struct {
        fn h(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    const specs = .{
        .{ .method = .POST, .path = "/api/hooks/deploy", .handler = H.h, .auth = .{ .path_secret = .{
            .param = "secret",
            .source = .{ .kv = "deploy_secret" },
            .in = .query,
            .on_mismatch = .forbidden,
        } } },
    };
    const table = buildRoutes(specs);
    try std.testing.expectEqual(@as(usize, 1), table.len);
    // A guard-gated route is `.public` at the AuthLevel layer; the secret is the gate.
    try std.testing.expect(table[0].auth == .public);
    const g = table[0].auth_guard.?;
    try std.testing.expect(g == .path_secret);
    try std.testing.expectEqualStrings("secret", g.path_secret.param);
    try std.testing.expect(g.path_secret.in == .query);
    try std.testing.expect(g.path_secret.on_mismatch == .forbidden);
    try std.testing.expect(g.path_secret.source == .kv);
    try std.testing.expectEqualStrings("deploy_secret", g.path_secret.source.kv);
    const meta = comptime routeMeta(specs);
    try std.testing.expectEqualStrings("secret", meta[0].path_secret.?.param);
    try std.testing.expect(meta[0].path_secret.?.in == .query);
    try std.testing.expect(meta[0].path_secret.?.on_mismatch == .forbidden);
    try std.testing.expect(!@hasField(PathSecretMeta, "source"));
    // Defaults: rate_limit .default, no key fn.
    try std.testing.expect(table[0].rate_limit == .default);
    try std.testing.expect(table[0].rate_limit_key == null);
}

test "buildRoutes path_secret defaults: in=.path, on_mismatch=.not_found, config source" {
    const H = struct {
        fn h(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/x/:token", .handler = H.h, .auth = .{ .path_secret = .{
            .param = "token",
            .source = .{ .config = "s3cr3t" },
        } } },
    });
    const g = table[0].auth_guard.?;
    try std.testing.expect(g.path_secret.in == .path); // default
    try std.testing.expect(g.path_secret.on_mismatch == .not_found); // default (bare-404)
    try std.testing.expect(g.path_secret.source == .config);
    try std.testing.expectEqualStrings("s3cr3t", g.path_secret.source.config);
}

test "buildRoutes lowers a per-route rate_limit + rate_limit_key (#142)" {
    const H = struct {
        fn h(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return .{ .status = 200, .body = "{}" };
        }
        fn key(ctx: *Ctx) ?[]const u8 {
            _ = ctx;
            return "k";
        }
    };
    const table = buildRoutes(.{
        .{ .method = .POST, .path = "/api/limited", .handler = H.h, .auth = .public, .rate_limit = .{ .custom = .{ .max = 3, .window_s = 60 } }, .rate_limit_key = H.key },
    });
    try std.testing.expect(table[0].auth == .public);
    try std.testing.expect(table[0].auth_guard == null);
    try std.testing.expect(table[0].rate_limit == .custom);
    try std.testing.expectEqual(@as(u32, 3), table[0].rate_limit.custom.max);
    try std.testing.expectEqual(@as(i64, 60), table[0].rate_limit.custom.window_s);
    try std.testing.expect(table[0].rate_limit_key != null);
}

test "buildRoutes accepts a pre-lowered RateLimitOpt for .rate_limit" {
    const H = struct {
        fn h(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return .{ .status = 200, .body = "{}" };
        }
    };
    // A consumer may pass a const `RateLimitOpt` straight through (it must not re-enter the
    // struct-lowering branch — see schema.buildRateLimitOpt's passthrough guard).
    const limit: schema.RateLimitOpt = .{ .custom = .{ .max = 4, .window_s = 120 } };
    const table = buildRoutes(.{
        .{ .method = .POST, .path = "/api/pre", .handler = H.h, .auth = .public, .rate_limit = limit },
    });
    try std.testing.expect(table[0].rate_limit == .custom);
    try std.testing.expectEqual(@as(u32, 4), table[0].rate_limit.custom.max);
}

// NOTE: a malformed `.path_secret` (missing `.param`/`.source`, an unknown key, an unknown
// `.source` variant, or MORE THAN ONE `.source` variant) is rejected at COMPILE time by
// `lowerRouteAuthGuard`/`lowerSecretSource` — e.g. `.auth = .{ .path_secret = .{ .source =
// .{ .kv = "k" } } }` (no `.param`) and `.source = .{ .kv = "a", .config = "b" }` (two
// variants) are both `@compileError`s. They cannot be asserted at runtime (they would fail
// the build), matching the loud-comptime convention used for hooks and `.rate_limit`.

test "AuthMethod enumerates all method tags" {
    try std.testing.expectEqualStrings("magic_link", @tagName(AuthMethod.magic_link));
    try std.testing.expectEqualStrings("custom", @tagName(AuthMethod.custom));
    try std.testing.expectEqualStrings("otp", @tagName(AuthMethod.otp));
    try std.testing.expectEqualStrings("webauthn", @tagName(AuthMethod.webauthn));
    try std.testing.expectEqualStrings("refresh", @tagName(AuthMethod.refresh));
}

test "isUntypedHandler detects raw-response handlers and routeMeta flags them out of codegen" {
    const H = struct {
        // Untyped: owns the raw http.Response (cookies/redirect/non-JSON body).
        fn raw(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return error.Unexpected;
        }
        // Typed: reflected into the RPC surface.
        fn typed(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };

    // Detection accepts both a bare `fn` and a single-item function pointer; a typed
    // `fn(*Req(...))` handler is not untyped.
    try std.testing.expect(isUntypedHandler(@TypeOf(H.raw)));
    try std.testing.expect(isUntypedHandler(*const @TypeOf(H.raw)));
    try std.testing.expect(!isUntypedHandler(@TypeOf(H.typed)));

    const specs = .{
        .{ .method = http.Method.GET, .path = "/api/raw", .handler = H.raw, .auth = AuthLevel.public },
        .{ .method = http.Method.GET, .path = "/api/health", .handler = H.typed },
    };
    const meta = comptime routeMeta(specs);
    // Untyped route: flagged out of codegen, contributes no typed Input/Output.
    try std.testing.expect(meta[0].untyped);
    try std.testing.expect(meta[0].Input == void);
    try std.testing.expect(meta[0].Output == void);
    // Typed route is unaffected.
    try std.testing.expect(!meta[1].untyped);
    try std.testing.expect(meta[1].Input == void); // its declared *Req(void)

    // buildRoutes still assembles a runnable table for both forms.
    const table = buildRoutes(specs);
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expect(table[0].method == .GET);
}

// ---------------------------------------------------------------------------
// writer()/reader() data-accessor tests.
//
// A file-backed Pool (WAL) so a reader can see the writer's committed rows,
// mirroring the db.zig pool tests and the data.zig Data round-trip test. The
// no-leak assertions re-acquire the writer/reader *directly* off the pool after
// the handle's deinit: if deinit failed to release, acquireWriter would deadlock
// (spinlock) and acquireReader would not see the warm connection back in the
// pool.
// ---------------------------------------------------------------------------

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*TestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(TestEnv);
        errdefer ga.destroy(env);

        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();

        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);

        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();

        env.arena = std.heap.ArenaAllocator.init(ga);
        errdefer env.arena.deinit();
        const a = env.arena.allocator();
        const io = std.testing.io;

        // Migrate + create a collection on the writer so create/findById work.
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const fields = [_]schema.Field{
                .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *TestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "WriterData create round-trips and releases the writer (no leak)" {
    const env = try TestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var id_buf: [64]u8 = undefined;
    var id_len: usize = 0;
    {
        var w: WriterData = .{ .app = &env.app, .pool = &env.pool, .conn = env.pool.acquireWriter() };
        defer w.deinit();
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "title", .{ .string = "hello" });
        const created = try w.data().create("posts", .{ .object = obj });
        const id = created.object.get("id").?.string;
        @memcpy(id_buf[0..id.len], id);
        id_len = id.len;

        const found = (try w.data().findById("posts", id)).?;
        try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);
    }

    // Prove deinit released the writer: re-acquiring it directly must not
    // deadlock (the spinlock would hang forever if still held).
    {
        const w2 = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = w2;
    }
}

test "WriterData record ops free col + scratch + results on deinit (no leak on a raw-GPA app)" {
    // The GPA-path leak regression: a WriterData whose `app.allocator` is the RAW
    // `std.testing.allocator` (a leak-checking GPA — NOT an arena). Everything the five record
    // methods allocate through the handle — the fully-owned collection metadata `collections.get`
    // dupes, the record engine's SQL scratch, and the returned records — must be freed by the
    // handle's arena on `deinit()`. Pre-fix (`data()` bound `Data.alloc` straight to the process
    // GPA with no arena) every op orphaned all of that on the GPA → this test leaks; post-fix the
    // handle-owned arena reclaims it → clean.
    const env = try TestEnv.init();
    defer env.deinit();

    // A raw-GPA app (NOT env.arena) so the handle's arena is a direct child of the leak checker.
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };

    {
        var w: WriterData = .{ .app = &app, .pool = &env.pool, .conn = env.pool.acquireWriter() };
        defer w.deinit(); // frees the handle arena (col + scratch + results) AND releases the writer
        const d = w.data(); // one Data over the handle's arena; conn + alloc are stable across calls

        var obj: std.json.ObjectMap = .empty;
        try obj.put(d.alloc, "title", .{ .string = "hello" });
        const created = try d.create("posts", .{ .object = obj });
        const id = created.object.get("id").?.string;
        try std.testing.expectEqualStrings("hello", created.object.get("title").?.string);

        const found = (try d.findById("posts", id)).?;
        try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);

        var patch: std.json.ObjectMap = .empty;
        try patch.put(d.alloc, "title", .{ .string = "world" });
        const updated = (try d.update("posts", id, .{ .object = patch })).?;
        try std.testing.expectEqualStrings("world", updated.object.get("title").?.string);

        const res = try d.list("posts", .{});
        try std.testing.expectEqual(@as(usize, 1), res.items.len);

        try std.testing.expect(try d.delete("posts", id));
        try std.testing.expect((try d.findById("posts", id)) == null);
    }

    // deinit released the writer: re-acquiring directly must not deadlock.
    {
        const w2 = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = w2;
    }
}

test "job Ctx writes then reads a committed record and releases the conn on deinit (no leak)" {
    // Mirrors how the scheduler now hands a job its DB capabilities: a Ctx built
    // from app with anonymous rctx and no bound connection. Writes go through the
    // pool writer (released immediately); reads lazily check out a pooled reader
    // that ctx.deinit() returns to the warm pool.
    const env = try TestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var cx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = null, .bound_conn = null };
    defer cx.deinit();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "world" });
    const created = try cx.records().create("posts", .{ .object = obj });
    const id = created.object.get("id").?.string;

    // No reader is checked out until the first read.
    try std.testing.expectEqual(@as(usize, 0), db.poolReaderCount(&env.pool));
    const found = (try cx.records().get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("world", found.object.get("title").?.string);

    // ctx.deinit() (via defer) returns the cached reader to the warm pool — prove
    // it by deiniting explicitly here and checking the warm count, then null it so
    // the deferred deinit is a no-op.
    cx.deinit();
    try std.testing.expectEqual(@as(usize, 1), db.poolReaderCount(&env.pool));

    // Re-acquiring reuses that exact warm connection.
    var r2 = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r2);
    try std.testing.expectEqual(@as(usize, 0), db.poolReaderCount(&env.pool));
}
