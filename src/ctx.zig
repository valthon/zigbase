const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const App = @import("app.zig").App;
const db = @import("db.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const data_mod = @import("data.zig");
const Data = data_mod.Data;
const records_engine = @import("records.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const policy = @import("policy.zig");
const schema_gen = @import("schema_gen.zig");
const expand_mod = @import("query/expand.zig");
const http_client = @import("http_client.zig");
const captcha_mod = @import("captcha.zig");
const error_mod = @import("api/error.zig");
const error_codes = @import("error_codes.zig");
const http_mod = @import("http.zig");
const auth_helpers = @import("auth_helpers.zig");
const api_auth = @import("api/auth.zig");
const session = @import("session.zig");
const features = @import("features.zig");
const features_resolver = @import("features_resolver.zig");
const feature_cache = @import("feature_cache.zig");
const realtime_ws = @import("realtime/ws.zig");
const crypto = @import("crypto.zig");
const query_params = @import("query/params.zig");
const clock = @import("clock.zig");
const queue_mod = @import("queue/queue.zig");
const queue_memory = @import("queue/memory.zig");
const queue_durable = @import("queue/durable.zig");
const mail_send = @import("mail/send.zig");
const mail_bulk = @import("mail/bulk.zig");
const mail_unsubscribe = @import("mail/unsubscribe.zig");
const sms_send = @import("sms/send.zig");
const webhook_mod = @import("webhook.zig");
const push_send = @import("push/send.zig");
const analytics = @import("analytics/analytics.zig");
const report_reporter = @import("report/reporter.zig");

/// Allocation-free last-resort 500 for the error path when even rendering the error envelope
/// fails (OOM). Byte-for-byte the envelope `ApiError.internal().renderBody` produces, so a client
/// or SDK parsing the `{status,code,message,data}` shape sees the same body it would on any other 500.
const static_internal_response = http_mod.Response{
    .status = 500,
    .body = "{\"status\":500,\"code\":\"internal\",\"message\":\"Something went wrong.\",\"data\":{}}",
};

pub const Ctx = struct {
    app: *App,
    arena: RequestArena,
    rctx: request.RequestContext = .{},
    /// Non-null inside a record hook: the hook's in-transaction connection. When set,
    /// ALL reads and writes use it (acquiring the pool writer here would deadlock).
    bound_conn: ?*db.Db = null,
    /// Lazily checked-out reader, cached for the Ctx lifetime (route/job context only).
    reader: ?events.ReaderData = null,
    /// Stashed error from ctx.fail/ctx.invalid; consumed by errorResponse(error.Handled).
    handled: ?error_mod.ApiError = null,
    /// The raw HTTP request context. Non-null for route handlers; null for job/hook contexts
    /// where there is no HTTP request. Required by `issueSession`.
    request: ?*http_mod.RequestCtx = null,
    /// Set when a feature-override write (`writeFlagOverride`) ran on this Ctx's BOUND
    /// (in-transaction) connection. `ctx.tx` re-invalidates the feature cache AFTER the
    /// commit for such writes: the in-site `invalidate()` fires pre-commit (the write is
    /// not yet visible to pooled readers), so a post-commit bump is what makes the newly
    /// committed override visible to the next resolution on this instance. See #230.
    wrote_feature_override: bool = false,

    // --- Wave 2 ergonomics (#138/#137): deferred response mutation + builders -------------
    // These are a SELF-CONTAINED section (fields + methods + tests) so sibling Wave-2 PRs
    // that also append to ctx.zig rebase cleanly. See `setCookie`/`addHeader`/`json`/etc.
    /// Cookies accumulated via `ctx.setCookie` (e.g. by `ctx.subjectCookie`). `server.zig`'s
    /// `dispatchCustom` merges these onto the handler's Response on BOTH the success and the
    /// error path, so a deferred Set-Cookie survives even when the handler returns an error.
    pending_cookies: std.ArrayListUnmanaged(http_mod.Cookie) = .empty,
    /// Extra response headers accumulated via `ctx.addHeader`; merged like `pending_cookies`.
    pending_headers: std.ArrayListUnmanaged(http_mod.Header) = .empty,
    /// Lazily parsed + cached decoded query string (see `ctx.query`).
    query_cache: ?query_params.Params = null,

    /// The resolved identity of the authenticated principal for this request.
    /// `id` is an empty string when no auth record is present (e.g. a superuser-only
    /// token with no associated record).
    /// `collection` is the auth collection name (e.g. "users"); empty string when
    /// anonymous or when the token carries no collection claim.
    pub const User = struct {
        id: []const u8,
        is_superuser: bool,
        collection: []const u8,
    };

    /// Derive the authenticated identity from the request context.
    /// Returns null for anonymous contexts (no auth record and not a superuser).
    pub fn user(self: *Ctx) ?User {
        if (!self.rctx.is_superuser and self.rctx.auth == null) return null;
        const id: []const u8 = blk: {
            const auth_val = self.rctx.auth orelse break :blk "";
            if (auth_val != .object) break :blk "";
            const id_field = auth_val.object.get("id") orelse break :blk "";
            break :blk switch (id_field) {
                .string => |s| s,
                else => "",
            };
        };
        return .{
            .id = id,
            .is_superuser = self.rctx.is_superuser,
            .collection = self.rctx.collection,
        };
    }

    /// Mint a session for a known record via the audited seam (`.custom` method tag).
    /// Acquires the DB writer, calls `auth_helpers.issueSession`, releases the writer,
    /// and returns the signed JWT + 2 cookies.
    ///
    /// Only valid inside a route handler — panics if `request` is null (job/hook context).
    ///
    /// WARNING: this function acquires the pool writer internally. Do NOT call it while
    /// already holding the writer (e.g. inside `ctx.tx`, from a before-hook, or with a
    /// bound_conn set) — it would deadlock permanently. In those cases, call
    /// `zigbase.auth.issueSession(self.request.?, bound_conn, collection, record_id)`
    /// directly with the connection you already hold.
    ///
    /// NOTE: for full session management (clearSession, revokeAllSessions, refresh,
    /// rotate, listActiveSessions, revoke), use `ctx.auth()` — all shipped.
    pub fn issueSession(self: *Ctx, collection: []const u8, record_id: []const u8) !auth_helpers.Issued {
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        return auth_helpers.issueSession(self.request.?, conn, collection, record_id);
    }

    /// A connection suitable for reads. Bound conn wins; else lazily check out + cache a reader.
    pub fn connForRead(self: *Ctx) !*db.Db {
        if (self.bound_conn) |c| return c;
        if (self.reader == null) {
            self.reader = .{ .app = self.app, .pool = self.app.pool, .conn = try self.app.pool.acquireReader() };
        }
        return &self.reader.?.conn;
    }

    /// Release any cached reader. Call once (the accessor/handler frame owns this via defer).
    pub fn deinit(self: *Ctx) void {
        if (self.reader) |*r| {
            r.deinit();
            self.reader = null;
        }
    }

    /// Returns a Records namespace bound to this Ctx for read operations.
    pub fn records(self: *Ctx) Records {
        return .{ .ctx = self };
    }

    /// Announce that you changed collection METADATA with hand-written SQL, so every serving
    /// process drops its cached collection definitions.
    ///
    /// You do NOT need this for anything that goes through the engine: `collections.create` /
    /// `update` / `delete` / `updateRules` bump the schema-generation marker themselves, inside
    /// their own transactions. This is the escape hatch for the one path the engine cannot see —
    /// `ctx.records().queryAs()` (and friends) run unrestricted SQL on the bound writer, so a hook
    /// or custom route CAN `UPDATE "_collections" SET "listRule" = …` directly. Such a write is
    /// invisible to the cache: the stale definition (including a stale ACCESS RULE) keeps being
    /// enforced until the process restarts.
    ///
    /// Call it in the same transaction as the write. Detection is deliberately not automatic:
    /// `PRAGMA schema_version` would catch a raw DROP/ALTER but NOT a rule-only UPDATE — partial
    /// coverage for real complexity, which is worse than an explicit call.
    pub fn markSchemaChanged(self: *Ctx) !void {
        if (self.bound_conn) |c| return schema_gen.bump(c);
        const w = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        return schema_gen.bump(w);
    }

    /// Authorize `action` on a specific record (#155) through the SAME composed policy the REST
    /// chokepoints use — the access rule AND any relationship ability AND the tenant scope. Lets a
    /// custom route gate a record the way the engine would, instead of re-implementing the check.
    /// Fails closed: an unknown collection, a locked rule, or no qualifying membership → false.
    /// Uses the bound (in-transaction) connection when present, else a pooled reader.
    pub fn can(self: *Ctx, action: policy.Action, collection: []const u8, id: []const u8) !bool {
        const conn = try self.connForRead();
        const col = (try collections.get(self.arena, conn, collection)) orelse return false;
        return policy.authorizes(self.arena, conn, col, action, id, &self.rctx);
    }

    /// Returns the session-management namespace (`ctx.auth()`): `clearSession` (#86),
    /// plus the #99 session verbs — `revokeAllSessions`/`refresh`/`rotate` (epoch model,
    /// always available) and the Variant B per-device `listActiveSessions`/`revoke`.
    pub fn auth(self: *Ctx) AuthApi {
        return .{ .ctx = self };
    }

    /// Returns the key→value/settings namespace (#87) bound to this Ctx.
    /// Reads use the read connection (bound conn wins); writes use the bound
    /// connection if set, else acquire/release the pool writer — deadlock-safe
    /// inside `ctx.tx`/before-hooks and self-managing on the route/job path.
    /// KV/settings are superuser-managed: they are NOT exposed publicly by
    /// default. To publish a value, write a custom route that calls these.
    pub fn kv(self: *Ctx) KeyValue {
        return .{ .ctx = self };
    }

    // -----------------------------------------------------------------------
    // App-scoped context (#245): one explicit typed app-scoped handle, replacing
    // the "module-level globals + bootstrap setter rituals" pattern.
    //
    // A consumer declares `App(.{ .app_context = MyAppData })`, sets it ONCE in
    // `onBootstrap` (`try ctx.setAppData(MyAppData, &value)`), and reads it from any
    // handler/hook/job/cron (`const d = ctx.appData(MyAppData)`, a `*MyAppData`).
    //
    // Type safety: `App` is a concrete (non-cfg-parameterized) struct and `Ctx` lives in
    // a separate file, so a cross-file *comptime* check of `T` against the declared
    // `.app_context` type is not cleanly reachable from `appData`. The runtime `@typeName`
    // guard below IS the safety net — a wrong `T` (or a read before it is set) trips a loud
    // `std.debug.assert` in safe builds. This is a deliberate tradeoff: it keeps the shared
    // `Ctx`/`App` types uncontorted. The declared-but-never-set case is caught earlier, at
    // boot (framework.zig fails fast right after onBootstrap runs).
    // -----------------------------------------------------------------------

    /// Store the app-scoped context handle (single-set). Call ONCE from `onBootstrap`.
    /// Returns `error.AppContextAlreadySet` if a value is already installed (the caller
    /// keeps ownership of `ptr`; nothing is overwritten). The lifetime of `ptr` must
    /// outlive the app (typically a `var` owned by the consumer's boot scope / a global).
    ///
    /// NOTE: this is NOT thread-safe. It must be called only during single-threaded init
    /// (e.g. inside `onBootstrap`, before the server starts serving requests). Calling it
    /// concurrently from request handlers is a data race / UB.
    pub fn setAppData(self: *Ctx, comptime T: type, ptr: *T) error{AppContextAlreadySet}!void {
        if (self.app.app_context != null) return error.AppContextAlreadySet;
        self.app.app_context = @ptrCast(ptr);
        self.app.app_context_type = @typeName(T);
    }

    /// Read the app-scoped context handle as a `*T`. Asserts (safe builds) that a value
    /// of exactly `T` was installed via `setAppData` — a mismatched `T` or a read before
    /// any `setAppData` trips the assert loudly. The declared-but-unset case never reaches
    /// here in a running server: the boot contract fails fast first.
    pub fn appData(self: *Ctx, comptime T: type) *T {
        std.debug.assert(self.app.app_context_type != null and
            std.mem.eql(u8, self.app.app_context_type.?, @typeName(T)));
        return @ptrCast(@alignCast(self.app.app_context.?));
    }

    // -----------------------------------------------------------------------
    // Feature flags + experiments (#128/#129/#130).
    //
    // Flags are DECLARED in the `App(.{ .flags = … })` literal. The typed,
    // compile-checked accessors live on the App type (`App.flag(ctx, .name)`,
    // `App.setFlag(ctx, .name, on)`, `App.experiment(ctx, .name, subject)`) — a
    // typo'd `.name` is a compile error. The runtime escape hatches below resolve
    // by string for dynamic names; both consult the registry threaded onto
    // `app.features`. (The old v0.7 `ctx.flag("arbitrary")` KV-or-false API is
    // removed — only declared flags resolve.)
    // -----------------------------------------------------------------------

    /// Resolve a DECLARED flag's effective value: the `flag:<name>` override from
    /// `_kv` if present, else the declared default. Swallows read errors (falls back
    /// to the default) so a kill-switch check never fails the request. Used by the
    /// typed `App.flag` accessor and by `flagByName`.
    pub fn resolveDeclaredFlag(self: *Ctx, def: features.FlagDef) bool {
        const conn = self.connForRead() catch return def.default;
        const data = Data{ .app = self.app, .conn = conn, .io = self.app.io, .alloc = self.arena.a };
        const key = std.fmt.allocPrint(self.arena.a, "flag:{s}", .{def.name}) catch return def.default;
        const ov = self.readOverride(data, key) catch return def.default;
        const value = features_resolver.resolveFlag(ov, def);
        // Notify-only exposure seam (zero-cost when no .onFeatureExposure handler).
        events.dispatchFlagExposure(self.app, self.app.dispatch, def.name, value);
        return value;
    }

    /// Read a single `flag:*`/`exp:*:weights` override value from the feature-override
    /// cache (#230) when one is installed AND this is a pooled-reader read; else a direct
    /// `_kv` read. A BOUND (in-transaction) read bypasses the cache so it sees its own
    /// uncommitted writes and never publishes uncommitted state into the shared snapshot.
    /// Degrade-safe: a cache error falls back to a direct read (never fails resolution).
    fn readOverride(self: *Ctx, data: Data, key: []const u8) !?[]const u8 {
        if (self.bound_conn == null) {
            if (self.app.feature_cache) |fc|
                return fc.get(self.app.io, data, key) catch data.kvGet(key);
        }
        return data.kvGet(key);
    }

    /// Connections for **reader-first** sticky experiment resolution (#129). Inside a
    /// `ctx.tx`/before-hook the bound writer is both reader and writer (no pool borrow);
    /// otherwise reads go on a pooled reader and only a sticky MISS briefly borrows the
    /// pool writer. Shared by `resolveDeclaredExperiment` and `ctx.flags().resolveAll`,
    /// so a steady-state sticky HIT never takes the writer on either path.
    pub fn stickyConns(self: *Ctx) !features_resolver.StickyConns {
        if (self.bound_conn) |c| return .{ .read = c, .pool = null };
        return .{ .read = try self.connForRead(), .pool = self.app.pool };
    }

    /// Resolve a DECLARED experiment to a variant for `subject`: applies the
    /// `exp:<name>:weights` JSON override from `_kv` when valid, else declared
    /// weights, then deterministic bucketing. A `.sticky` experiment returns its
    /// PERSISTED assignment (reader-first — see `stickyConns`; only a first-time miss
    /// touches the writer). Used by the typed `App.experiment` accessor.
    pub fn resolveDeclaredExperiment(self: *Ctx, def: features.ExperimentDef, subject: []const u8) ![]const u8 {
        const key = try std.fmt.allocPrint(self.arena.a, "exp:{s}:weights", .{def.name});
        const sticky = def.sticky and subject.len > 0;
        const sc: ?features_resolver.StickyConns = if (sticky) try self.stickyConns() else null;
        // The weight-override read uses the sticky read conn when present (else a reader).
        const read_conn = if (sc) |s| s.read else try self.connForRead();
        const data = Data{ .app = self.app, .conn = read_conn, .io = self.app.io, .alloc = self.arena.a };
        const ov = try self.readOverride(data, key);
        const variant = try features_resolver.resolveExperiment(self.arena.a, sc, ov, def, subject);
        // Notify-only exposure seam, fired on the RESOLVED variant (after the reader-first
        // sticky lookup). Zero-cost when no .onFeatureExposure handler is registered.
        events.dispatchExperimentExposure(self.app, self.app.dispatch, def.name, subject, variant);
        return variant;
    }

    /// Write a `flag:<name>` override (`"true"`/`"false"`) into `_kv`. Used by the
    /// typed `App.setFlag` accessor (the App-side enum guarantees `name` is declared).
    pub fn writeFlagOverride(self: *Ctx, name: []const u8, enabled: bool) !void {
        const key = try std.fmt.allocPrint(self.arena.a, "flag:{s}", .{name});
        try self.kv().set(key, if (enabled) "true" else "false");
        // Invalidate the feature-override cache (#230) so the next resolution on THIS
        // instance re-scans and sees the write. Called unconditionally — NOT gated on the
        // realtime reactor — and BEFORE the reactor signal below. On the non-bound path
        // `kv().set` autocommits, so this is a post-commit bump. On the BOUND path the
        // write is still in-flight: flag it so `ctx.tx` re-invalidates AFTER the commit.
        if (self.app.feature_cache) |fc| fc.invalidate();
        if (self.bound_conn != null) self.wrote_feature_override = true;
        // Signal-only realtime push: tell subscribers to re-GET /api/state. No-op when
        // the reactor isn't running (tests/CLI). Cross-instance on Postgres (#188 theme).
        realtime_ws.broadcastFeaturesChanged(self.app);
    }

    /// Runtime escape hatch: resolve a flag by string name. Returns `null` when the
    /// name is not DECLARED (or no registry is wired), else its resolved value. Use
    /// the typed `App.flag(ctx, .name)` whenever the name is known at compile time.
    pub fn flagByName(self: *Ctx, name: []const u8) ?bool {
        const reg = self.app.features orelse return null;
        for (reg.flags) |def| {
            if (std.mem.eql(u8, def.name, name)) return self.resolveDeclaredFlag(def);
        }
        return null;
    }

    /// Runtime escape hatch: set a flag override by string name. Errors with
    /// `error.UndeclaredFlag` when the name is not declared (or no registry is
    /// wired). The typed `App.setFlag(ctx, .name, on)` is the compile-checked path.
    pub fn setFlag(self: *Ctx, name: []const u8, enabled: bool) !void {
        const reg = self.app.features orelse return error.UndeclaredFlag;
        for (reg.flags) |def| {
            if (std.mem.eql(u8, def.name, name)) return self.writeFlagOverride(name, enabled);
        }
        return error.UndeclaredFlag;
    }

    /// Returns the feature-resolution namespace (`ctx.flags()`): `resolveAll(subject)`
    /// resolves every declared flag + experiment in one batched `_kv` scan (the shape
    /// the public `/api/state` projection serves).
    pub fn flags(self: *Ctx) FlagsApi {
        return .{ .ctx = self };
    }

    /// Run `f` inside an IMMEDIATE transaction on the writer connection.
    /// All Records writes inside `f` reuse the bound connection — no deadlock.
    /// Returns error.NestedTransaction when called from an already-bound Ctx.
    ///
    /// A plain function pointer has no closure, so a callback that needs request
    /// data has nowhere to get it from — see `txWith` to thread data in directly
    /// instead of smuggling it through a `threadlocal`.
    pub fn tx(self: *Ctx, comptime T: type, f: *const fn (t: *Tx) anyerror!T) !T {
        const Adapter = struct {
            fn call(t: *Tx, inner_f: *const fn (t: *Tx) anyerror!T) anyerror!T {
                return inner_f(t);
            }
        };
        return self.txWith(T, f, Adapter.call);
    }

    /// Same as `tx`, but threads a caller-supplied `payload` into the callback —
    /// the closure-free escape hatch for a transaction that needs request data
    /// without smuggling it through a `threadlocal` global. `payload` is typically
    /// a pointer to a stack struct built in the handler; it only needs to stay
    /// valid for the (synchronous) duration of this call.
    ///
    /// Same semantics as `tx`: IMMEDIATE transaction on the writer, commit on
    /// success/rollback on error, `error.NestedTransaction` when the Ctx is
    /// already bound, and the #230 post-commit feature-cache re-invalidation.
    pub fn txWith(
        self: *Ctx,
        comptime T: type,
        payload: anytype,
        f: *const fn (t: *Tx, payload: @TypeOf(payload)) anyerror!T,
    ) !T {
        if (self.bound_conn != null) return error.NestedTransaction;
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        try conn.beginImmediate();
        var t = Tx{ .inner = .{ .app = self.app, .arena = self.arena, .rctx = self.rctx, .bound_conn = conn } };
        defer t.inner.deinit();
        const result = f(&t, payload) catch |e| {
            conn.rollback() catch {};
            return e;
        };
        conn.commit() catch |e| {
            conn.rollback() catch {};
            return e;
        };
        // #230: if a feature-override write ran inside this transaction, its in-site
        // `invalidate()` fired PRE-commit (invisible to pooled readers then). Re-invalidate
        // now that it is committed so the next resolution re-scans and sees it.
        if (t.inner.wrote_feature_override) if (self.app.feature_cache) |fc| fc.invalidate();
        return result;
    }

    /// Returns an outbound HTTP client bound to this Ctx's arena and the app's io.
    pub fn http(self: *Ctx) http_client.HttpClient {
        return .{ .alloc = self.arena.a, .io = self.app.io };
    }

    /// Returns the outbound-mail namespace (`ctx.mail()`, #141): `send` (synchronous,
    /// via the configured mailer + dev test-capture seam) and `enqueue` (durable/memory
    /// background delivery via the built-in `"mail"` job kind). The framework owns CRLF
    /// header-injection rejection + recipient address validation — see `MailApi`.
    pub fn mail(self: *Ctx) MailApi {
        return .{ .ctx = self };
    }

    /// Returns the outbound-SMS namespace (`ctx.sms()`, #224): `send` (synchronous, via the
    /// configured SMS provider) and `enqueue` (durable/memory background delivery via the built-in
    /// `"sms"` job kind). The framework owns E.164 normalization/rejection — see `SmsApi`.
    pub fn sms(self: *Ctx) SmsApi {
        return .{ .ctx = self };
    }

    /// Caller-facing options for `ctx.webhook` (re-exported from `webhook.zig`).
    pub const WebhookOpts = webhook_mod.WebhookOpts;

    /// Enqueue a managed outbound webhook delivery (#144). The `payload` is
    /// JSON-serialized into the request body and POSTed by the built-in `"webhook"`
    /// job kind on the selected queue (`opts.queue` orelse the always-present
    /// `"default"` queue). The handler classifies the response — network errors,
    /// 5xx, and 429 (honoring an integer `Retry-After`) are RETRYABLE up to
    /// `opts.retries`; any other 4xx is TERMINAL; a terminal/exhausted delivery
    /// fires `.onError` with phase `.webhook`.
    ///
    /// `opts.sign` adds an `HMAC-SHA256` body signature (`X-Signature` +
    /// `X-Webhook-Timestamp`); `opts.idempotency` (default on) attaches a stable
    /// `Idempotency-Key` minted ONCE here and frozen onto the (durable) job row so
    /// every retry/replay reuses it. Requires a wired queue registry
    /// (`error.QueuesUnavailable` otherwise).
    ///
    /// Requires `.webhooks = true` in the App config — without it the "webhook" kind
    /// is not compiled in and this call fails at enqueue with `error.UnknownJobKind`.
    pub fn webhook(self: *Ctx, url: []const u8, payload: anytype, opts: WebhookOpts) !void {
        const body = try self.serializePayload(payload);
        // 32 hex chars = 16 bytes / 128 bits — UUID-grade, collision-free at any volume.
        const idem: ?[]const u8 = if (opts.idempotency) try self.randomHex(32) else null;
        const job = webhook_mod.WebhookJob{
            .url = url,
            .body = body,
            .idempotency_key = idem,
            .sign = opts.sign,
            .max_attempts = opts.retries,
            .backoff = opts.backoff,
            .timeout_ms = std.math.mul(u32, opts.timeout_s, 1000) catch std.math.maxInt(u32),
        };
        return self.enqueueByName(opts.queue orelse "default", webhook_mod.job_kind, job);
    }

    /// Returns the Web Push namespace (`ctx.push()`, #223): `send` (synchronous — returns the
    /// tri-state `.delivered`/`.gone`/`.failed`, so the caller PRUNES its stored subscription on
    /// `.gone`) and `enqueue` (durable/background delivery via the built-in `"push"` job kind,
    /// which just stops retrying a dead endpoint). Composes an RFC 8291 encrypted body + an RFC
    /// 8292 VAPID header. Push is a network-free logging no-op until VAPID keys are configured
    /// (`ZIGBASE_VAPID_PUBLIC_KEY`/`_PRIVATE_KEY`); a failing push never throws into the
    /// triggering request.
    pub fn push(self: *Ctx) push_send.PushApi {
        return .{ .ctx = self };
    }

    // -----------------------------------------------------------------------
    // CAPTCHA verification (#140, PR6).
    //
    // `verifyCaptcha(provider, token)` POSTs the token to the provider's
    // siteverify endpoint using `app.captcha_secret`, parsing the JSON
    // response into a typed `CaptchaResult`.
    //
    // Dev-bypass: when `app.captcha_secret` is empty (default), returns
    // `.{.ok = true}` immediately — no network call. This lets local
    // development and tests work without a live CAPTCHA key. Document this
    // clearly in the handler so consumers are not surprised.
    //
    // Network / HTTP errors propagate as a Zig error. The caller chooses
    // whether to fail-open (return ok=true) or fail-closed (return 403)
    // on a transient network failure.
    // -----------------------------------------------------------------------

    /// Verify a CAPTCHA token via the given `provider`'s siteverify API.
    ///
    /// `token` is the string received from the browser (e.g. the value of
    /// `g-recaptcha-response`, `h-captcha-response`, or `cf-turnstile-response`).
    ///
    /// **Dev-bypass:** when `app.captcha_secret` is empty (the default when
    /// `.captcha` is not configured) this returns `.{.ok = true}` immediately
    /// without any network call, so local dev/tests do not need a live key.
    ///
    /// **Network errors** (transport failures, non-2xx from the provider) propagate
    /// as a Zig error — the handler decides whether to fail-open or fail-closed.
    ///
    /// **Provider mismatch:** the secret is configured for ONE provider (`app.captcha_provider`).
    /// Calling with a different `provider` would send that secret to the wrong endpoint, so it
    /// fails fast with `error.CaptchaProviderMismatch` rather than silently failing the check.
    /// (The check is skipped when no provider is configured — e.g. tests that set only a secret.)
    ///
    /// ```zig
    /// const r = try ctx.verifyCaptcha(.recaptcha_v3, token);
    /// if (!r.ok) return ctx.jsonError(403, "captcha_required", "Captcha required.");
    /// if (r.score) |score| if (score < 0.5) return ctx.jsonError(403, "suspicious_request", "Suspicious request.");
    /// ```
    pub fn verifyCaptcha(self: *Ctx, provider: captcha_mod.Provider, token: []const u8) !captcha_mod.Result {
        if (self.app.captcha_secret.len == 0) return .{ .ok = true };
        if (self.app.captcha_provider) |expected| {
            if (provider != expected) {
                std.log.warn("captcha: provider mismatch (configured {s}, called with {s})", .{ @tagName(expected), @tagName(provider) });
                return error.CaptchaProviderMismatch;
            }
        }
        return captcha_mod.verify(provider, self.app.captcha_secret, token, self.arena.a, self.http());
    }

    // -----------------------------------------------------------------------
    // Background jobs & queues (#137 PR2).
    //
    // `enqueue` is the generic public API: serialize `payload` to JSON and route
    // it to the named queue's backend (memory → the bounded in-process worker pool with
    // retry, error.QueueFull when its ring is full; durable → persisted to
    // `_queue_jobs`, drained by a worker poller). `q`/`job` are enum
    // literals (`.queue`, `.kind`). The typed, compile-checked `App.enqueue(ctx,
    // .queue, .kind, payload)` (mirroring `App.flag`) is the preferred call site — a
    // typo'd queue/kind is a compile error there; this method validates at runtime.
    // Callable from background jobs (the handler receives a fresh `*Ctx`).
    // -----------------------------------------------------------------------

    /// Enqueue a background job. `q` and `job` are enum literals; for compile-checked
    /// names use `App.enqueue(ctx, .queue, .kind, payload)`.
    pub fn enqueue(self: *Ctx, comptime q: anytype, comptime job: anytype, payload: anytype) !void {
        return self.enqueueByName(@tagName(q), @tagName(job), payload);
    }

    /// Generic, runtime-validated enqueue by string names. `error.QueuesUnavailable`
    /// when no registry is wired (tests/CLI), `error.UnknownQueue` / `error.UnknownJobKind`
    /// on a miss. `payload` is JSON-serialized (a `[]const u8`/`[]u8` is taken as raw JSON
    /// and passed through unchanged); the kind handler receives that JSON text.
    pub fn enqueueByName(self: *Ctx, queue_name: []const u8, kind: []const u8, payload: anytype) !void {
        const reg = queue_mod.registryFromApp(self.app) orelse return error.QueuesUnavailable;
        const q = reg.queueByName(queue_name) orelse return error.UnknownQueue;
        const j = reg.jobByKind(kind) orelse {
            // std.log.warn, not .err — this path is exercised by a passing test
            // (`ctx.enqueue errors on unknown queue / kind / no registry`); a real
            // `std.log.err` here would fail Zig's test runner (see events.zig:1119).
            std.log.warn("job kind '{s}' is not registered — built-ins are config-gated: \"webhook\" needs `.webhooks = true`, \"mail\" needs `.mail`/`.mailer` in App(.{{...}})", .{kind});
            return error.UnknownJobKind;
        };
        const payload_json = try self.serializePayload(payload);
        switch (q.backend) {
            .memory => try queue_memory.enqueue(self.app, q, j.handler, payload_json),
            .durable => {
                const now = clock.nowUnix(self.app.io);
                if (self.bound_conn) |c| {
                    _ = try queue_durable.enqueue(c, self.app.io, q, kind, payload_json, now);
                } else {
                    const w = self.app.pool.acquireWriter();
                    defer self.app.pool.releaseWriter();
                    _ = try queue_durable.enqueue(w, self.app.io, q, kind, payload_json, now);
                }
            },
        }
    }

    // -----------------------------------------------------------------------
    // Consumer realtime broadcast (#143). SELF-CONTAINED section (accessor + the
    // RealtimeApi struct below) so sibling Wave-2 PRs that also append to ctx.zig
    // rebase cleanly. Publishes on CUSTOM (non-collection) topics; subscription is
    // gated at subscribe time by `.realtime = .{ .canSubscribe = fn }` (default:
    // custom topics are PUBLIC signal channels). Callable from a background job
    // (no HTTP request needed). A no-op when the realtime reactor isn't running.
    // -----------------------------------------------------------------------

    /// Returns the realtime publish namespace (`ctx.realtime()`): `signal(topic)` and
    /// `broadcast(topic, payload)`.
    pub fn realtime(self: *Ctx) RealtimeApi {
        return .{ .ctx = self };
    }

    // -----------------------------------------------------------------------
    // Product analytics (#158). SELF-CONTAINED section so sibling PRs that also
    // append to ctx.zig rebase cleanly.
    //
    // `track(name, payload)` appends ONE immutable `_events` row. The actor /
    // actor_collection (from the authenticated principal) and the account (the
    // request's resolved tenant scope) are stamped SERVER-SIDE here; `occurred_at`
    // is stamped by SQLite. A client cannot forge any of them — `track` ignores its
    // own request body for context and only takes the event `name` + opaque `payload`.
    // -----------------------------------------------------------------------

    /// Emit one analytics event: persist `name` + the JSON-serialized `payload` to `_events`,
    /// with `actor`/`actor_collection` resolved from the authenticated principal and `account`
    /// from the request's active tenant scope (`""` when tenancy is disabled or unscoped). Cheap:
    /// a single INSERT. Uses the bound (in-transaction) connection inside a hook/`ctx.tx`, else
    /// acquires the pool writer. A `[]const u8`/`[]u8` payload is taken as raw JSON unchanged.
    pub fn track(self: *Ctx, name: []const u8, payload: anytype) !void {
        const payload_json = try self.serializePayload(payload);
        const u = self.user();
        const ev = analytics.EventContext{
            .name = name,
            .payload_json = payload_json,
            .actor = if (u) |uu| uu.id else "",
            .actor_collection = if (u) |uu| uu.collection else "",
            .account = self.rctx.account_id,
        };
        if (self.bound_conn) |c| return analytics.insertEvent(c, self.app.io, ev);
        const w = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        return analytics.insertEvent(w, self.app.io, ev);
    }

    fn serializePayload(self: *Ctx, payload: anytype) ![]const u8 {
        const T = @TypeOf(payload);
        // Already-serialized JSON text passes through unchanged.
        if (T == []const u8 or T == []u8) return payload;
        return std.json.Stringify.valueAlloc(self.arena.a, payload, .{});
    }

    /// Sentinel error type returned by fail/invalid so callers can propagate.
    pub const FailError = error{Handled};

    /// Stash a custom status+message error and return error.Handled for propagation.
    /// `code` is derived from `status` (`error_codes.forStatus`) since this call carries no
    /// code of its own — the same derivation `route_types.zig`'s typed-route path uses.
    pub fn fail(self: *Ctx, status: u16, message: []const u8) FailError {
        self.handled = .{ .status = status, .code = error_codes.s(error_codes.forStatus(status)), .message = message };
        return error.Handled;
    }

    /// Stash a validation error (400 with field details) and return error.Handled.
    pub fn invalid(self: *Ctx, fields: []const error_mod.FieldError) FailError {
        self.handled = error_mod.ApiError.validation(fields);
        return error.Handled;
    }

    /// Map any error to an http.Response. error.Handled renders the stashed ApiError;
    /// known errors map to canonical status codes; anything else → 500 (no detail leaked).
    pub fn errorResponse(self: *Ctx, err: anyerror) http_mod.Response {
        const ae: error_mod.ApiError = switch (err) {
            error.Handled => self.handled orelse error_mod.ApiError.internal(),
            error.NotFound => error_mod.ApiError.notFound(),
            error.BadRequest => error_mod.ApiError.badRequest("Bad request."),
            error.Conflict => error_mod.ApiError.conflict("Conflict."),
            // A DB integrity-constraint violation (e.g. a duplicate unique value) propagated out
            // of a custom route's `ctx.records()` write is a client conflict, not a server fault.
            error.Constraint => error_mod.ApiError.conflict("A record with these values already exists."),
            error.Forbidden => error_mod.ApiError.forbidden(),
            error.Unauthorized => error_mod.ApiError.unauthorized(),
            else => error_mod.ApiError.internal(),
        };
        // Rendering the envelope allocates; on OOM the retry would hit the SAME exhausted arena,
        // so `catch unreachable` here is a REACHABLE unreachable that panics the server (ReleaseSafe)
        // or is UB (ReleaseFast) on the error path of any request under memory pressure. Fall back to
        // a preallocated static 500 body — no allocation, so it cannot fail.
        return ae.toResponse(self.arena.a) catch static_internal_response;
    }

    // -----------------------------------------------------------------------
    // Error reporting (#244). SELF-CONTAINED section so sibling PRs that also
    // append to ctx.zig rebase cleanly.
    //
    // `reportError` routes a swallowed-but-notable error through the SAME backstop
    // the framework uses for its own caught errors (`events.dispatchError`): the
    // consumer `onError` handler runs first, then the pluggable reporter (Sentry or
    // the log backstop), carrying the Stage-2 TTL dedup + non-blocking queued
    // delivery. Tagged with the `.app` phase so a reporter can distinguish an
    // app-reported error from a framework-caught one.
    // -----------------------------------------------------------------------

    /// Report a swallowed-but-notable error to the configured reporter (and `onError`),
    /// tagged with the `.app` phase. Best-effort and NON-FAILING — it never blocks or
    /// fails the caller (delivery is queued off-thread, per #244). Usable from a route
    /// handler, hook, job, or cron via the same `*Ctx`. Its own allocation failure is
    /// swallowed (the message falls back to `@errorName(err)`), so it can never throw.
    pub fn reportError(self: *Ctx, err: anyerror, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena.a, fmt, args) catch @errorName(err);
        var ev = events.ErrorEvent{
            .app = self.app,
            // Attach the request identity only when there IS a request (route handler);
            // a job/hook/cron context has no meaningful request context.
            .ctx = if (self.request) |_| &self.rctx else null,
            .err = err,
            .phase = .app,
            .message = msg,
        };
        events.dispatchError(self.app, self.app.dispatch, &ev);
    }

    // =======================================================================
    // Wave 2 ergonomics (#138 + #137): deferred response mutation, response
    // builders, request reads, and the read-or-mint subject cookie.
    //
    // SELF-CONTAINED SECTION — keep methods together to ease sibling-PR rebases.
    // The raw `http.Response` literal remains fully usable; these are additive
    // conveniences, and the deferred accumulators are merged at ONE chokepoint
    // (`server.zig dispatchCustom`) on both the success and error paths.
    // =======================================================================

    /// Default length (chars) of a freshly-minted `subjectCookie` id.
    pub const subject_token_len: usize = 32;

    /// Deferred response mutation: queue a cookie to be set on whatever Response this
    /// handler ultimately returns (success OR error). Allocated/owned by the ctx arena.
    pub fn setCookie(self: *Ctx, cookie: http_mod.Cookie) !void {
        try self.pending_cookies.append(self.arena.a, cookie);
    }

    /// Deferred response mutation: queue an extra response header (merged like cookies).
    pub fn addHeader(self: *Ctx, header: http_mod.Header) !void {
        try self.pending_headers.append(self.arena.a, header);
    }

    /// Build a `200`/`status` JSON response by serializing `value` (any std.json-encodable
    /// value, incl. a `std.json.Value`) onto the ctx arena.
    pub fn json(self: *Ctx, status: u16, value: anytype) !http_mod.Response {
        const body = try std.json.Stringify.valueAlloc(self.arena.a, value, .{});
        return .{ .status = status, .content_type = "application/json", .body = body };
    }

    /// Build the canonical error envelope with a caller-supplied machine `code`
    /// (#138 / SP-1). Use this when the handler has a more specific code than the
    /// status implies, e.g. `ctx.jsonError(403, "captcha_required", "Captcha required.")`.
    /// `code` is NOT validated against ZigBase's frozen ledger — it is your vocabulary,
    /// and ZigBase never assigns meaning to a code it did not register.
    pub fn jsonError(self: *Ctx, status: u16, code: []const u8, message: []const u8) !http_mod.Response {
        return (error_mod.ApiError{ .status = status, .code = code, .message = message }).toResponse(self.arena.a);
    }

    /// Build an HTML response (`text/html; charset=utf-8`). `body` must outlive the handler
    /// return (a literal, or arena-allocated — see `ctx.arena`).
    pub fn html(self: *Ctx, status: u16, body: []const u8) http_mod.Response {
        _ = self;
        return .{ .status = status, .content_type = "text/html; charset=utf-8", .body = body };
    }

    /// Build a redirect response (e.g. `302`/`307`) with a `Location` header pointing at
    /// `location`. The header slice is arena-owned.
    pub fn redirect(self: *Ctx, status: u16, location: []const u8) !http_mod.Response {
        const headers = try self.arena.a.dupe(http_mod.Header, &.{.{ .name = "Location", .value = location }});
        return .{ .status = status, .content_type = "text/html; charset=utf-8", .body = "", .extra_headers = headers };
    }

    /// Build the canonical `404 Not found.` JSON envelope (a shortcut for the common case).
    pub fn notFound(self: *Ctx) !http_mod.Response {
        return error_mod.ApiError.notFound().toResponse(self.arena.a);
    }

    /// Constant-time check that the route path param `param` equals `stored` (#139 escape
    /// hatch). Returns false when there is no request, the param is absent, or `stored` is
    /// empty / differs. Uses `crypto.timingSafeEql`, so a wrong value leaks no byte-position
    /// timing oracle — never compare a secret with `==`/`std.mem.eql`. The declarative
    /// `.auth = .{ .path_secret = … }` route guard is the preferred path; reach for this only
    /// for ad-hoc checks (e.g. against a secret you resolved yourself). It does NOT itself
    /// 404/deny — the caller decides (return `ctx.notFound()` on false to mirror the guard's
    /// bare-404, no-oracle behavior).
    pub fn verifyPathSecret(self: *Ctx, param: []const u8, stored: []const u8) bool {
        const req = self.request orelse return false;
        const submitted = req.param(param) orelse return false;
        return stored.len > 0 and crypto.timingSafeEql(submitted, stored);
    }

    /// The request's URL query string, lazily parsed (and cached on the Ctx) into decoded
    /// key/value pairs: `+` → space, `%XX` percent-decoded (see `query/params.zig`). Returns
    /// an empty `Params` in a job/hook context (no request). `q.get("k")` is `?[]const u8`.
    pub fn query(self: *Ctx) !query_params.Params {
        if (self.query_cache) |q| return q;
        const raw = if (self.request) |r| r.query else "";
        const parsed = try query_params.parse(self.arena.a, raw);
        self.query_cache = parsed;
        return parsed;
    }

    /// A random base36 token of `n` chars (`[0-9a-z]`), arena-owned. Wraps `crypto.genToken`.
    pub fn randomToken(self: *Ctx, n: usize) ![]const u8 {
        return crypto.genToken(self.app.io, self.arena.a, n);
    }

    /// A random lowercase-hex token of `n` chars (`[0-9a-f]`), arena-owned. Wraps `crypto.genHex`.
    pub fn randomHex(self: *Ctx, n: usize) ![]const u8 {
        return crypto.genHex(self.app.io, self.arena.a, n);
    }

    /// Read-or-mint an opaque per-visitor "subject" id stored in cookie `name` (#137).
    /// If the incoming request already carries a well-formed value, it is returned verbatim
    /// (no Set-Cookie). Otherwise a fresh `randomToken` is minted and a single Set-Cookie is
    /// QUEUED via `setCookie` (applied on the response at the dispatch chokepoint). Idempotent
    /// within a request: repeat calls for the same `name` return the same id and never queue a
    /// second cookie. The id is opaque (NOT signed) — a stable handle, not an authenticator.
    ///
    /// Anonymous-friendly: works without an authenticated identity. An explicit `?subject=`
    /// query param still wins downstream (resolved in `api/state.zig`, left untouched here).
    pub fn subjectCookie(self: *Ctx, name: []const u8, opts: SubjectCookieOpts) ![]const u8 {
        // An incoming, well-formed cookie wins (read path — no mint, no Set-Cookie).
        if (self.request) |r| {
            if (r.cookie(name)) |existing| {
                if (isWellFormedSubject(existing)) return existing;
            }
        }
        // Idempotent within a request: reuse an id already minted for this name.
        for (self.pending_cookies.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        const minted = try self.randomToken(subject_token_len);
        try self.setCookie(.{
            .name = name,
            .value = minted,
            .max_age_s = opts.max_age_s,
            .secure = opts.secure,
            .same_site = opts.same_site,
            .http_only = opts.http_only,
            .domain = opts.domain,
            .path = opts.path,
        });
        return minted;
    }
};

/// Options for `ctx.subjectCookie` (#137). Defaults are a secure, lax, http-only, root-path
/// session cookie. `max_age_s = 0` is a session cookie; set it for a persistent id.
pub const SubjectCookieOpts = struct {
    max_age_s: i32 = 0,
    secure: bool = true,
    same_site: http_mod.SameSite = .lax,
    http_only: bool = true,
    domain: ?[]const u8 = null,
    path: []const u8 = "/",
};

/// A minted subject id is base36 (`crypto.genToken`); treat any non-empty, all-base36
/// incoming value as well-formed and reuse it. A malformed/empty value is re-minted.
fn isWellFormedSubject(v: []const u8) bool {
    if (v.len == 0 or v.len > 128) return false;
    for (v) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z');
        if (!ok) return false;
    }
    return true;
}

pub const GetOptions = struct { expand: ?[]const u8 = null };
pub const ListOptions = struct {
    filter: ?[]const u8 = null,
    /// Bound values for `?` placeholders in `filter` (0-based, left-to-right). Each `?` binds its
    /// value as a literal SQL parameter — never re-parsed as filter grammar — so this is the
    /// injection-safe way to splice a runtime value into a filter. The number of `?` MUST equal
    /// `filter_args.len` or `list` returns `error.BadFilter`.
    filter_args: []const records_engine.FilterArg = &.{},
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    expand: ?[]const u8 = null,
};

pub const Records = struct {
    ctx: *Ctx,

    fn dataRead(self: Records) !Data {
        return .{ .app = self.ctx.app, .conn = try self.ctx.connForRead(), .io = self.ctx.app.io, .alloc = self.ctx.arena.a };
    }

    pub fn get(self: Records, collection: []const u8, id: []const u8, opts: GetOptions) !?std.json.Value {
        const data = try self.dataRead();
        var rec = (try data.findById(collection, id)) orelse return null;
        try self.applyExpand(collection, &rec, opts.expand);
        return rec;
    }

    pub fn list(self: Records, collection: []const u8, opts: ListOptions) !records_engine.ListResult {
        const q = records_engine.ListQuery{
            .filter = opts.filter,
            .filter_args = opts.filter_args,
            .sort = opts.sort,
            .page = opts.page,
            .perPage = opts.perPage,
            .limit = opts.limit,
            .cursor = opts.cursor,
            .rctx = &self.ctx.rctx,
            .io = self.ctx.app.io,
        };
        const result = try (try self.dataRead()).list(collection, q);
        if (opts.expand) |spec| if (spec.len > 0) {
            const conn = try self.ctx.connForRead();
            if (try collections.get(self.ctx.arena.a, conn, collection)) |col| {
                // Batch the page through one PageCache (schema parsed once, view decisions memoized).
                try expand_mod.expandItems(self.ctx.arena.a, conn, col, result.items, spec, 0, &self.ctx.rctx);
            }
        };
        return result;
    }

    pub fn create(self: Records, collection: []const u8, value: std.json.Value) !std.json.Value {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).create(collection, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).create(collection, value);
    }

    pub fn update(self: Records, collection: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).update(collection, id, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).update(collection, id, value);
    }

    pub fn delete(self: Records, collection: []const u8, id: []const u8) !bool {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).delete(collection, id);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).delete(collection, id);
    }

    // --- Typed record I/O (#238) -------------------------------------------
    // Thin wrappers over the `Data.*As` methods: reflect an anon-struct literal
    // of writable fields into the write, and parse the resulting record into `T`.
    // Struct↔schema mapping is by name; optionals map to nullable/absent fields;
    // every literal field is comptime-verified to exist on `T`. The `std.json.Value`
    // methods above remain for dynamic callers. `getAs` takes no opts — expand /
    // projection over typed reads is a future addition.

    /// Create a record from an anon-struct literal of writable fields and return it as `T`.
    pub fn createAs(self: Records, comptime T: type, collection: []const u8, input: anytype) !T {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).createAs(T, collection, input);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).createAs(T, collection, input);
    }

    /// Fetch a record by id parsed into `T`, or `null` if the collection/record is missing.
    pub fn getAs(self: Records, comptime T: type, collection: []const u8, id: []const u8) !?T {
        return (try self.dataRead()).getAs(T, collection, id);
    }

    /// Run raw `sql` (with positionally-bound `args`) and decode each result row into a struct
    /// `T`, mapping fields to result columns BY NAME (#240). The escape hatch for complex reads
    /// (joins/aggregates/window scans) that outgrow the collection query API, without the
    /// positional-`columnText(n)` fragility. Uses a pooled reader + the invocation arena, so
    /// the returned `[]T` (and its string fields) live for the request/job. Bound to the ctx's
    /// active connection inside a `ctx.tx` / before-hook write. See `data.queryAs` for the full
    /// type-mapping and NULL contract.
    pub fn queryAs(self: Records, comptime T: type, sql: [:0]const u8, args: anytype) ![]T {
        const conn = if (self.ctx.bound_conn) |c| c else try self.ctx.connForRead();
        return data_mod.queryAs(T, conn, self.ctx.arena.a, sql, args);
    }

    /// Patch a record with an anon-struct literal of the changed fields and return it as `T`
    /// (or `null` if missing).
    pub fn updateAs(self: Records, comptime T: type, collection: []const u8, id: []const u8, patch: anytype) !?T {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).updateAs(T, collection, id, patch);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).updateAs(T, collection, id, patch);
    }

    /// Resolve the collection and run expand on `rec` in-place.
    /// CRUD operations in Records bypass collection rules (matching Data behaviour);
    /// expand applies the *target* collection's viewRule under the Ctx identity.
    /// A job ctx with rctx = .{} gets the anonymous view.
    fn applyExpand(self: Records, collection: []const u8, rec: *std.json.Value, spec: ?[]const u8) !void {
        const s = spec orelse return;
        if (s.len == 0) return;
        const conn = try self.ctx.connForRead();
        const col = (try collections.get(self.ctx.arena.a, conn, collection)) orelse return;
        try expand_mod.expand(self.ctx.arena.a, conn, col, rec, s, 0, &self.ctx.rctx);
    }
};

/// Session-management namespace (`ctx.auth()`). Full shipped surface (PRs #111/#112):
///
/// - `clearSession`       — return the cleared `zb_auth`+`zb_csrf` cookies; a logout
///                          handler is a single `return .{ .cookies = try ctx.auth().clearSession() }`.
/// - `revokeAllSessions`  — bump the principal's `token_epoch` so every outstanding
///                          token stops verifying immediately; in table mode also wipes
///                          the principal's `_sessions` rows ("log out everywhere").
/// - `refresh`            — re-mint a session token (new `exp`, same epoch, sliding
///                          window); in table mode rotates the current device's row.
///                          Route context only (requires `ctx.request`).
/// - `rotate`             — bump epoch + mint a fresh token in one step ("rotate
///                          credentials, keep this device, kill all others"); table mode
///                          atomically replaces the device row. Route context only.
/// - `listActiveSessions` — list the principal's active (unexpired) sessions, newest
///                          first, with `is_current` marked. Requires
///                          `session_store = .table`; returns `error.SessionStoreNotEnabled`
///                          in the default `.epoch` mode.
/// - `revoke(id)`         — revoke ONE session by id ("log out this device"); owner-or-
///                          superuser only, collapsing non-owner and absent-id into
///                          `error.NotFound`. Requires `session_store = .table`.
pub const AuthApi = struct {
    ctx: *Ctx,

    /// One active session row (Variant B), as returned by `listActiveSessions`. `is_current`
    /// marks the session this request is authenticated with.
    pub const Session = struct {
        id: []const u8,
        created: []const u8,
        last_seen: []const u8,
        user_agent: []const u8,
        ip: []const u8,
        is_current: bool,
    };

    /// Clear the `zb_auth` + `zb_csrf` session cookies (logout). Returns arena-owned
    /// cookies that slot straight into a handler's `Response.cookies`:
    ///   return .{ .status = 204, .body = "", .cookies = try ctx.auth().clearSession() };
    pub fn clearSession(self: AuthApi) ![]const http_mod.Cookie {
        const cleared = session.clearedCookies(self.ctx.app.cookie_secure);
        return self.ctx.arena.a.dupe(http_mod.Cookie, &cleared);
    }

    /// The current authenticated principal (collection + id), or error.Unauthorized.
    fn principal(self: AuthApi) !Ctx.User {
        const u = self.ctx.user() orelse return error.Unauthorized;
        if (u.collection.len == 0 or u.id.len == 0) return error.Unauthorized;
        return u;
    }

    /// "Log out everywhere" (#99): bump the principal's `token_epoch` so EVERY outstanding
    /// `.auth` token immediately stops verifying. Works in BOTH session-store modes. In table
    /// mode it ALSO clears the principal's `_sessions` rows (so the per-device list empties).
    /// Uses the bound connection inside a tx/before-hook, else acquires the pool writer.
    pub fn revokeAllSessions(self: AuthApi) !void {
        const u = try self.principal();
        const table = self.ctx.app.session_store == .table;
        if (self.ctx.bound_conn) |c| {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena.a, c, u.collection, u.id);
            if (table) try api_auth.deleteSessionsForPrincipal(c, u.collection, u.id);
            return;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        _ = try api_auth.bumpTokenEpoch(self.ctx.arena.a, w, u.collection, u.id);
        if (table) try api_auth.deleteSessionsForPrincipal(w, u.collection, u.id);
    }

    /// Re-mint a session token for the current principal (new `exp`, SAME epoch) — a sliding
    /// refresh that leaves the principal's other sessions valid. In table mode this ROTATES
    /// the current device's `_sessions` row (the old `sid` row is dropped; issuing inserts the
    /// replacement) so a device keeps exactly one row. Route context only (needs `ctx.request`).
    pub fn refresh(self: AuthApi) !auth_helpers.Issued {
        const u = try self.principal();
        const req = self.ctx.request orelse return error.NoRequestContext;
        const table = self.ctx.app.session_store == .table;
        const cur = self.ctx.rctx.session_id;
        if (self.ctx.bound_conn) |c| {
            // Carry the old row's `created` forward (session-start time) onto the new row,
            // whose `lastSeen` is set to now by issue() — see carrySessionCreated.
            const old_created = if (table and cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena.a, c, cur) else null;
            const issued = try auth_helpers.issueSession(req, c, u.collection, u.id);
            if (table) try api_auth.carrySessionCreated(c, issued.token, old_created);
            return issued;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        // Epoch mode does no pre-issue write, so no transaction is needed (issue() just
        // reads + signs). Table mode performs delete-old + insert-new (in issue) — wrap them
        // in ONE transaction so a mid-way failure never silently logs the device out.
        if (!table) return auth_helpers.issueSession(req, w, u.collection, u.id);
        try w.beginImmediate();
        errdefer w.rollback() catch {};
        const old_created = if (cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena.a, w, cur) else null;
        const issued = try auth_helpers.issueSession(req, w, u.collection, u.id);
        try api_auth.carrySessionCreated(w, issued.token, old_created);
        w.commit() catch |e| {
            w.rollback() catch {};
            return e;
        };
        return issued;
    }

    /// Rotate: bump the epoch (invalidating ALL prior tokens, including the one on THIS
    /// request) then mint a fresh token carrying the new epoch — "rotate my credentials,
    /// keep me signed in here, kill every other session". In table mode it also drops this
    /// device's old `_sessions` row and (via issue) inserts the replacement. Route context only.
    pub fn rotate(self: AuthApi) !auth_helpers.Issued {
        const u = try self.principal();
        const req = self.ctx.request orelse return error.NoRequestContext;
        const table = self.ctx.app.session_store == .table;
        const cur = self.ctx.rctx.session_id;
        if (self.ctx.bound_conn) |c| {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena.a, c, u.collection, u.id);
            const old_created = if (table and cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena.a, c, cur) else null;
            const issued = try auth_helpers.issueSession(req, c, u.collection, u.id);
            if (table) try api_auth.carrySessionCreated(c, issued.token, old_created);
            return issued;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        // Epoch mode: a single epoch bump (UPDATE) then issue() (read + sign) — no multi-write
        // to make atomic; a failed issue returns an error the caller sees. Table mode bundles
        // bump + delete-old + insert-new (in issue) into ONE transaction so a mid-way failure
        // never leaves the device's row deleted without a replacement (silent logout).
        if (!table) {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena.a, w, u.collection, u.id);
            return auth_helpers.issueSession(req, w, u.collection, u.id);
        }
        try w.beginImmediate();
        errdefer w.rollback() catch {};
        _ = try api_auth.bumpTokenEpoch(self.ctx.arena.a, w, u.collection, u.id);
        const old_created = if (cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena.a, w, cur) else null;
        const issued = try auth_helpers.issueSession(req, w, u.collection, u.id);
        try api_auth.carrySessionCreated(w, issued.token, old_created);
        w.commit() catch |e| {
            w.rollback() catch {};
            return e;
        };
        return issued;
    }

    /// Variant B (`App(.{ .session_store = .table })`): list the current principal's active
    /// (unexpired) sessions for a per-device UI, newest first, with `is_current` set on the
    /// session this request is using. Read-only (one indexed SELECT). Returns
    /// `error.SessionStoreNotEnabled` in the default `.epoch` mode (no per-session inventory).
    pub fn listActiveSessions(self: AuthApi) ![]const Session {
        if (self.ctx.app.session_store != .table) return error.SessionStoreNotEnabled;
        const u = try self.principal();
        const conn = if (self.ctx.bound_conn) |c| c else try self.ctx.connForRead();
        const rows = try api_auth.listSessions(self.ctx.arena.a, conn, u.collection, u.id);
        const cur = self.ctx.rctx.session_id;
        const out = try self.ctx.arena.a.alloc(Session, rows.len);
        for (rows, 0..) |row, i| out[i] = .{
            .id = row.id,
            .created = row.created,
            .last_seen = row.last_seen,
            .user_agent = row.user_agent,
            .ip = row.ip,
            .is_current = cur.len > 0 and std.mem.eql(u8, row.id, cur),
        };
        return out;
    }

    /// Variant B: revoke ONE session by id ("log out this device"). AUTHORIZED — a
    /// non-superuser may revoke only a session they OWN. A non-owner gets `error.NotFound`
    /// whether or not the session id exists (indistinguishable — no existence oracle on other
    /// users' session ids); a genuinely absent id is also `error.NotFound`.
    /// `error.SessionStoreNotEnabled` in `.epoch` mode.
    pub fn revoke(self: AuthApi, session_id: []const u8) !void {
        if (self.ctx.app.session_store != .table) return error.SessionStoreNotEnabled;
        const u = try self.principal();
        if (self.ctx.bound_conn) |c| return self.revokeOn(c, u, session_id);
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return self.revokeOn(w, u, session_id);
    }

    /// Authorize + delete one session row on `conn`. Owner-or-superuser only (fail closed).
    /// A non-owner is given the SAME `error.NotFound` as a missing row — collapsing the
    /// owner-mismatch and absent-row cases so revoke can't probe other users' session ids.
    fn revokeOn(self: AuthApi, conn: *db.Db, u: Ctx.User, session_id: []const u8) !void {
        const owner = (try api_auth.sessionOwner(self.ctx.arena.a, conn, session_id)) orelse return error.NotFound;
        const is_owner = std.mem.eql(u8, owner.collection, u.collection) and std.mem.eql(u8, owner.record, u.id);
        if (!u.is_superuser and !is_owner) return error.NotFound; // indistinguishable from absent
        _ = try api_auth.deleteSession(conn, session_id);
    }
};

/// Key→value/settings namespace (#87) bound to a Ctx. A thin ergonomic layer over
/// `Data.kvGet/kvSet/kvDelete`: reads run on the read connection, writes use the
/// bound connection if present else the pool writer (mirroring `Records.create`).
pub const KeyValue = struct {
    ctx: *Ctx,

    /// Fetch `key`'s value, or null if absent. Result lives on the ctx arena.
    pub fn get(self: KeyValue, key: []const u8) !?[]const u8 {
        const data = Data{ .app = self.ctx.app, .conn = try self.ctx.connForRead(), .io = self.ctx.app.io, .alloc = self.ctx.arena.a };
        return data.kvGet(key);
    }

    /// Upsert `key`→`value` (preserves `created`).
    pub fn set(self: KeyValue, key: []const u8, value: []const u8) !void {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).kvSet(key, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).kvSet(key, value);
    }

    /// Delete `key`. Returns whether a row existed.
    pub fn delete(self: KeyValue, key: []const u8) !bool {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).kvDelete(key);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena.a }).kvDelete(key);
    }
};

/// Feature-resolution namespace (`ctx.flags()`) bound to a Ctx (#128/#129/#130).
pub const FlagsApi = struct {
    ctx: *Ctx,

    /// Resolve every DECLARED flag + experiment for `subject` in a SINGLE batched
    /// `_kv` scan (`flag:*` / `exp:*`). Returns empty when no registry is wired.
    /// Allocates on the ctx arena. This is the exact shape the public `/api/state`
    /// projection (a later PR) serves.
    pub fn resolveAll(self: FlagsApi, subject: []const u8) !features_resolver.Resolved {
        const reg = self.ctx.app.features orelse return .{};
        // Reader-first sticky conns (shared with `App.experiment`): the batched `_kv`
        // scan reads on `sc.read`, and a `.sticky` experiment returns its PERSISTED
        // variant (only a first-time miss briefly borrows the writer).
        const sc = try self.ctx.stickyConns();
        const data = Data{ .app = self.ctx.app, .conn = sc.read, .io = self.ctx.app.io, .alloc = self.ctx.arena.a };
        // Serve the `flag:*`/`exp:*` override set from the feature cache (#230) on the
        // pooled-reader path; a BOUND (in-tx) read or a cache scan error falls back to a
        // direct scan (byte-identical to the pre-cache path). The snapshot is held only
        // long enough to copy the pairs onto the ctx arena, then released.
        const pairs = try self.overridePairs(data);
        return features_resolver.resolveAll(self.ctx.arena.a, reg.*, pairs, subject, sc);
    }

    /// Build the `flag:*`/`exp:*` override pairs for `resolveAll`, from the feature cache
    /// when available (pooled-reader path), else a direct `_kv` scan. Copies key/value onto
    /// the ctx arena so the result outlives any released snapshot.
    fn overridePairs(self: FlagsApi, data: Data) ![]features_resolver.KvPair {
        return feature_cache.overridePairs(self.ctx.arena.a, self.ctx.app.io, self.ctx.app.feature_cache, self.ctx.bound_conn != null, data);
    }
};

/// Outbound-mail namespace (`ctx.mail()`, #141). SELF-CONTAINED section (struct +
/// re-exported message type) so sibling Wave-2 PRs that also append to ctx.zig rebase
/// cleanly.
///
/// SECURITY: the framework owns CRLF/header-injection rejection AND recipient address
/// validation here (in `mail/send.zig`) — a consumer never re-rolls them. Both `send`
/// and `enqueue` validate before any byte reaches a backend or a durable row.
///
/// - `send`    — build + deliver synchronously via the configured mailer (the same
///               `Mailer.send` vtable seam that feeds the dev-only `testcapture.mail`
///               outbox, so consumer mail is assertable like the framework's auth mail).
/// - `enqueue` — hand the message to the background queue (built-in `"mail"` job kind)
///               for durable/memory delivery; pick the queue via `.{ .queue = "…" }`.
pub const MailApi = struct {
    ctx: *Ctx,

    /// The consumer-facing message shape (`{ to, subject, text?, html?, reply_to? }`).
    /// Re-exported from `mail/send.zig` so a caller names `ctx.mail().Message` / the
    /// re-exported `zigbase.MailMessage`.
    pub const Message = mail_send.MailMessage;

    /// Options for the background-delivery verbs. `queue` routes the "mail" job;
    /// `at` (unix seconds) / `delay_s` schedule its earliest delivery — mutually
    /// exclusive (`error.ConflictingSchedule`), and scheduling requires a DURABLE
    /// queue (`error.ScheduleRequiresDurable` — a memory job cannot survive to a
    /// future time). Both null = deliver on the next poll (today's behavior).
    pub const EnqueueOpts = struct {
        queue: []const u8 = "default",
        at: ?i64 = null,
        delay_s: ?u32 = null,
    };

    /// Default `msg.account` from the request's active account scope (#154) when the caller did not
    /// set it explicitly. This is the EXPLICIT engagement point for verified-sender + suppression
    /// enforcement: a request operating inside an account scope automatically attributes its mail to
    /// that account; a job/anon context (empty scope) sends as a system send. An explicit
    /// `msg.account` always wins.
    fn withScope(self: MailApi, msg: Message) Message {
        if (msg.account != null) return msg;
        if (self.ctx.rctx.account_id.len == 0) return msg;
        var m = msg;
        m.account = self.ctx.rctx.account_id;
        return m;
    }

    /// Validate + deliver `msg` synchronously through the configured mailer (log
    /// fallback when none is wired). Errors: `error.InvalidAddress` / `error.HeaderInjection`
    /// / `error.EmptyBody` on a bad message, `error.SenderNotVerified` / `error.RecipientSuppressed`
    /// when send-time enforcement is on (#154), or a backend failure.
    pub fn send(self: MailApi, msg: Message) !void {
        return mail_send.send(self.ctx.app, self.ctx.arena.a, self.withScope(msg));
    }

    /// Validate `msg`, then enqueue it as a background `"mail"` job on `opts.queue`.
    /// Routed to the queue's backend by `ctx.enqueue` (memory → in-process retry;
    /// durable → persisted to `_queue_jobs`, drained by a worker). Validating BEFORE
    /// enqueue means a malformed message fails fast at the call site, not later in a
    /// worker. Requires a wired queue registry (`error.QueuesUnavailable` otherwise).
    ///
    /// Requires `.mail` (use `.mail = .{}` for defaults) or a `.mailer` plugin in the
    /// App config — without one the "mail" kind is not compiled in and this call fails
    /// at enqueue with `error.UnknownJobKind`.
    pub fn enqueue(self: MailApi, msg: Message, opts: EnqueueOpts) !void {
        if (opts.at != null or opts.delay_s != null) {
            _ = try self.deliverAt(msg, opts);
            return;
        }
        const scoped = self.withScope(msg);
        try mail_send.validate(scoped);
        try mail_send.checkSize(scoped, self.ctx.app.mail.max_message_bytes);
        return self.ctx.enqueueByName(opts.queue, "mail", scoped);
    }

    /// Alias for `enqueue` reading as the intent ("deliver this later, off the request path"). The
    /// async transactional-mail entry point (#154).
    pub fn deliverLater(self: MailApi, msg: Message, opts: EnqueueOpts) !void {
        return self.enqueue(msg, opts);
    }

    /// Schedule a message for (earliest) delivery at `opts.at` / now+`opts.delay_s`,
    /// returning the durable JOB ID (arena-owned). Persist that id (your own record,
    /// `ctx.kv()`, …) and hand it to `cancel` to call the send off — this pair is the
    /// drip-sequence primitive (see framework.md's recipe; there is no campaign
    /// machinery). Validates the message up front like `enqueue`.
    pub fn deliverAt(self: MailApi, msg: Message, opts: EnqueueOpts) ![]const u8 {
        if (opts.at != null and opts.delay_s != null) return error.ConflictingSchedule;
        const scoped = self.withScope(msg);
        try mail_send.validate(scoped);
        try mail_send.checkSize(scoped, self.ctx.app.mail.max_message_bytes);
        const reg = queue_mod.registryFromApp(self.ctx.app) orelse return error.QueuesUnavailable;
        const q = reg.queueByName(opts.queue) orelse return error.UnknownQueue;
        if (q.backend != .durable) return error.ScheduleRequiresDurable;
        const io = self.ctx.app.io;
        const now = clock.nowUnix(io);
        const run_at: i64 = opts.at orelse (now + @as(i64, opts.delay_s orelse 0));
        const payload = try self.ctx.serializePayload(scoped);
        const jid = blk: {
            if (self.ctx.bound_conn) |c| break :blk try queue_durable.enqueue(c, io, q, "mail", payload, run_at);
            const w = self.ctx.app.pool.acquireWriter();
            defer self.ctx.app.pool.releaseWriter();
            break :blk try queue_durable.enqueue(w, io, q, "mail", payload, run_at);
        };
        return self.ctx.arena.a.dupe(u8, &jid);
    }

    /// Cancel a still-pending scheduled job by the id `deliverAt` returned. True when
    /// it was called off; false when it already ran / is running / was canceled.
    pub fn cancel(self: MailApi, job_id: []const u8) !bool {
        if (self.ctx.bound_conn) |c| return queue_durable.cancelJob(c, job_id);
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return queue_durable.cancelJob(w, job_id);
    }

    pub const BulkSend = mail_bulk.BulkSend;
    pub const BulkRecipient = mail_bulk.BulkRecipient;
    pub const BatchReport = mail_bulk.BatchReport;

    /// Submit a bulk list send (#154 round 2): one templated message fanned out as
    /// per-recipient durable jobs with a durable send-report. Validates EVERYTHING at
    /// the call site (a bad recipient anywhere persists nothing). Requires a durable
    /// queue (`error.BulkRequiresDurable`) and a wired registry. Returns the batch id
    /// (arena-owned) — hand it to `batchStatus`/`cancelBatch`.
    pub fn sendBulk(self: MailApi, b: BulkSend) ![]const u8 {
        const account = b.account orelse self.ctx.rctx.account_id; // withScope parity: explicit wins
        const reg = queue_mod.registryFromApp(self.ctx.app) orelse return error.QueuesUnavailable;
        if (self.ctx.bound_conn) |c| return mail_bulk.sendBulk(self.ctx.app, self.ctx.arena.a, reg, c, false, b, account);
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return mail_bulk.sendBulk(self.ctx.app, self.ctx.arena.a, reg, w, true, b, account);
    }

    /// Cancel every still-pending recipient of a batch (idempotent; stray queued item
    /// jobs drain as no-ops). Returns how many recipients moved pending→canceled.
    pub fn cancelBatch(self: MailApi, batch_id: []const u8) !usize {
        if (self.ctx.bound_conn) |c| return mail_bulk.cancelBatch(self.ctx.app, c, false, batch_id);
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return mail_bulk.cancelBatch(self.ctx.app, w, true, batch_id);
    }

    /// The durable per-recipient send-report, aggregated.
    pub fn batchStatus(self: MailApi, batch_id: []const u8) !BatchReport {
        return mail_bulk.batchStatus(self.ctx.app, self.ctx.arena.a, batch_id);
    }

    /// Escape hatch for hand-rolled list mail: the signed one-click unsubscribe URL for
    /// (account, list, recipient) — set it on your MailMessage.list_unsubscribe. Errors
    /// with `error.UnsubscribeNotConfigured` when `unsubscribe_base_url` is unset.
    pub fn unsubscribeUrl(self: MailApi, account: []const u8, list: []const u8, recipient: []const u8) ![]const u8 {
        const base = self.ctx.app.mail.unsubscribe_base_url;
        if (base.len == 0) return error.UnsubscribeNotConfigured;
        return mail_unsubscribe.buildUrl(self.ctx.arena.a, base, self.ctx.app.jwt_secret, account, list, recipient);
    }
};

/// Outbound-SMS namespace (`ctx.sms()`, #224). The SMS analog of `MailApi`.
///
/// SECURITY: the framework owns E.164 normalization/rejection here (in `sms/send.zig`) — a
/// consumer never re-rolls it. Both `send` and `enqueue` normalize BEFORE any byte reaches a
/// provider or a durable queue row, so a malformed number fails fast at the call site.
///
/// - `send`    — normalize + deliver synchronously via the configured provider (log fallback when
///               none is wired, so tests/CLI need no credentials).
/// - `enqueue` — hand the message to the background queue (built-in `"sms"` job kind) for
///               durable/memory delivery with the queue's retry/backoff; pick the queue via
///               `.{ .queue = "…" }`.
pub const SmsApi = struct {
    ctx: *Ctx,

    /// The consumer-facing message shape (`{ to, body, from? }`). Re-exported from `sms/send.zig`.
    pub const Message = sms_send.SmsMessage;

    /// Options for the background-delivery verb. `queue` routes the "sms" job; `null` (the
    /// default) uses the configured `.sms.queue` (itself defaulting to the always-present
    /// `"default"` queue), so a caller opts in per-call only when overriding it.
    pub const EnqueueOpts = struct {
        queue: ?[]const u8 = null,
    };

    /// Normalize + deliver `msg` synchronously through the configured provider (log fallback when
    /// none is wired). Errors: `error.InvalidPhoneNumber` / `error.EmptyBody` on a bad message, or a
    /// backend failure.
    pub fn send(self: SmsApi, msg: Message) !void {
        return sms_send.send(self.ctx.app, self.ctx.arena.a, msg);
    }

    /// Normalize `msg`, then enqueue it as a background `"sms"` job on `opts.queue`. Normalizing
    /// BEFORE enqueue means a malformed number fails fast at the call site, not later in a worker —
    /// and never persists to a queue row. Requires `.sms` / `.sms_provider` in the App config
    /// (without one the "sms" kind is not compiled in and this fails with `error.UnknownJobKind`)
    /// and a wired queue registry (`error.QueuesUnavailable` otherwise).
    pub fn enqueue(self: SmsApi, msg: Message, opts: EnqueueOpts) !void {
        const normalized = try sms_send.normalize(self.ctx.arena.a, msg, self.ctx.app.sms.default_region);
        // Explicit per-call queue wins; otherwise the configured `.sms.queue` default.
        const queue = opts.queue orelse self.ctx.app.sms.queue;
        return self.ctx.enqueueByName(queue, "sms", normalized);
    }

    /// Alias for `enqueue` reading as the intent ("deliver this later, off the request path").
    pub fn deliverLater(self: SmsApi, msg: Message, opts: EnqueueOpts) !void {
        return self.enqueue(msg, opts);
    }
};

/// Consumer realtime publish namespace (`ctx.realtime()`, #143). Both verbs publish on a
/// CUSTOM (non-collection) `topic`; who may subscribe is decided at subscribe time by the
/// `.realtime = .{ .canSubscribe = fn }` guard (default: custom topics are PUBLIC signal
/// channels). No-op when the realtime reactor isn't running (tests/CLI). Callable from a
/// background job (the handler's `*Ctx` has `request == null`).
pub const RealtimeApi = struct {
    ctx: *Ctx,

    /// Signal-only push: subscribers of `topic` receive `{"type":"signal","topic":"<topic>"}`
    /// and should re-fetch over an authenticated GET. The RECOMMENDED default for private or
    /// per-subject state — it carries NO payload, so nothing sensitive is pushed to a channel
    /// any subscriber can join.
    ///
    /// On Postgres the signal fans out across instances (best-effort, at-most-once, unordered):
    /// every instance's subscribers of `topic` are told to re-fetch. On SQLite (single-process)
    /// it is delivered in-process only.
    pub fn signal(self: RealtimeApi, topic: []const u8) void {
        realtime_ws.signalTopic(self.ctx.app, topic);
    }

    /// Payload-carrying broadcast (EXPLICIT opt-in): subscribers of `topic` receive
    /// `{"type":"message","topic":"<topic>","data":<payload>}`. `payload` is any
    /// JSON-serializable value (an unserializable value errors HERE, at the call site —
    /// the envelope itself is applied structurally by the realtime layer). Only broadcast
    /// data that is safe for EVERY subscriber of `topic`; gate private channels with
    /// `.realtime = .{ .canSubscribe = fn }`, or prefer `signal` + an authenticated
    /// re-fetch for per-subject state.
    ///
    /// On Postgres the enveloped frame fans out across instances (best-effort, at-most-once,
    /// unordered) via a random-token side table — never payload bytes on the NOTIFY wire — so
    /// every instance's subscribers of `topic` receive it. On SQLite it is delivered in-process.
    pub fn broadcast(self: RealtimeApi, topic: []const u8, payload: anytype) !void {
        const data_json = try std.json.Stringify.valueAlloc(self.ctx.arena.a, payload, .{});
        // Thread `bound_conn` through: if this Ctx is already bound to the writer (a record
        // hook, or inside `ctx.tx`), the Postgres side-table write MUST reuse it rather than
        // acquire a second writer — the pool writer is a single non-reentrant lock.
        realtime_ws.broadcastTopic(self.ctx.app, self.ctx.bound_conn, topic, data_json);
    }
};

/// A transaction scope: wraps an inner Ctx whose bound_conn is set so that
/// all Records writes inside the callback reuse the in-progress transaction.
pub const Tx = struct {
    inner: Ctx,

    pub fn records(self: *Tx) Records {
        return .{ .ctx = &self.inner };
    }

    /// The transaction's request/invocation arena — use this to allocate values you
    /// put into records inside the callback.
    pub fn arena(self: *Tx) std.mem.Allocator {
        return self.inner.arena.a;
    }

    /// See `Ctx.markSchemaChanged`. Inside a `tx` this bumps on the transaction's own bound
    /// connection, so the marker commits or rolls back with the rest of the transaction.
    pub fn markSchemaChanged(self: *Tx) !void {
        return self.inner.markSchemaChanged();
    }
};

// ---------------------------------------------------------------------------
// Test harness (file-backed pool, posts collection) — matches TestEnv pattern
// from events.zig.
// ---------------------------------------------------------------------------

const CtxTestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
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

    /// Like init(), but also provisions an `authors` collection and a `posts.author`
    /// single-relation field so expand tests have something to resolve.
    fn initWithRelation() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
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

        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const author_fields = [_]schema.Field{
                .{ .id = "a1", .name = "name", .options = .{ .text = .{} } },
            };
            const authors = try collections.create(a, io, w, .{ .id = "", .name = "authors", .fields = &author_fields, .viewRule = "@public" });
            const post_fields = [_]schema.Field{
                .{ .id = "p1", .name = "title", .required = true, .options = .{ .text = .{} } },
                .{ .id = "p2", .name = "author", .options = .{ .relation = .{ .targetCollectionId = authors.id, .maxSelect = 1 } } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &post_fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *CtxTestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "errorResponse static 500 fallback matches the rendered internal envelope byte-for-byte" {
    // The allocation-free fallback that `errorResponse` returns when even rendering the error
    // envelope runs out of memory must be indistinguishable from a normal 500, so a client or SDK
    // parsing the `{code,message,data}` shape never chokes. Guard the two against drifting apart.
    const rendered = try error_mod.ApiError.internal().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, static_internal_response.body);
    try std.testing.expectEqual(@as(u16, 500), static_internal_response.status);
}

test "ctx.setAppData/appData round-trips a typed app-scoped handle (#245)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const AppData = struct { count: u32, label: []const u8 };
    var data = AppData{ .count = 7, .label = "hello" };
    var cx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer cx.deinit();

    try cx.setAppData(AppData, &data);
    // The guard key is the value's @typeName — proves appData compares the right key.
    try std.testing.expect(env.app.app_context_type != null);
    try std.testing.expectEqualStrings(@typeName(AppData), env.app.app_context_type.?);

    // appData returns a pointer to the SAME value.
    const got = cx.appData(AppData);
    try std.testing.expectEqual(@as(u32, 7), got.count);
    try std.testing.expectEqualStrings("hello", got.label);

    // Mutations through the handle are visible via the original var and a fresh read.
    got.count = 99;
    try std.testing.expectEqual(@as(u32, 99), data.count);
    try std.testing.expectEqual(@as(u32, 99), cx.appData(AppData).count);
    // wrong T → assert trips at runtime (a failed std.debug.assert panics and cannot be
    // caught in a Zig unit test, so it is intentionally not exercised here).
}

test "ctx.setAppData is single-set: a second call errors (#245)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const AppData = struct { n: u8 };
    var first = AppData{ .n = 1 };
    var second = AppData{ .n = 2 };
    var cx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer cx.deinit();

    try cx.setAppData(AppData, &first);
    try std.testing.expectError(error.AppContextAlreadySet, cx.setAppData(AppData, &second));
    // The first value is untouched — the second set overwrote nothing.
    try std.testing.expectEqual(@as(u8, 1), cx.appData(AppData).n);
}

test "App defaults app_context to null when unset — construct is unaffected (#245)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    try std.testing.expect(env.app.app_context == null);
    try std.testing.expect(env.app.app_context_type == null);
    // The declared-but-never-set fail-fast (error.AppContextNotSet) is enforced at boot by
    // framework.zig's `checkAppContextInitialized`, unit-tested directly there.
}

test "ctx.user() reflects the resolved auth identity; anonymous is null" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var anon = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer anon.deinit();
    try std.testing.expect(anon.user() == null);
    // A superuser rctx yields a User with is_superuser=true.
    var su = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{ .is_superuser = true } };
    defer su.deinit();
    try std.testing.expect(su.user().?.is_superuser);
    // An authed rctx with a collection forwards the collection name.
    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(std.testing.allocator, "id", .{ .string = "abc123" });
    defer auth_obj.deinit(std.testing.allocator);
    var authed = Ctx{
        .app = &env.app,
        .arena = RequestArena.from(&env.arena),
        .rctx = .{ .auth = .{ .object = auth_obj }, .is_superuser = false, .collection = "users" },
    };
    defer authed.deinit();
    const u = authed.user().?;
    try std.testing.expectEqualStrings("abc123", u.id);
    try std.testing.expectEqualStrings("users", u.collection);
    try std.testing.expect(!u.is_superuser);
}

test "#86 ctx.auth().clearSession returns arena cookies matching the framework's logout policy" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const cookies = try ctx.auth().clearSession();
    try std.testing.expectEqual(@as(usize, 2), cookies.len);

    // Identical to the shared session policy that the built-in authLogout uses — so the
    // one-line consumer logout can never drift from the framework's own clear.
    const expected = session.clearedCookies(env.app.cookie_secure);
    for (cookies, 0..) |c, i| {
        try std.testing.expectEqualStrings(expected[i].name, c.name);
        try std.testing.expectEqualStrings("", c.value);
        try std.testing.expect(c.max_age_s < 0);
        try std.testing.expectEqual(expected[i].http_only, c.http_only);
        try std.testing.expectEqual(expected[i].secure, c.secure);
        try std.testing.expect(c.same_site == .strict);
        try std.testing.expectEqualStrings("/", c.path);
    }
    // zb_auth is HttpOnly; zb_csrf is readable by JS (double-submit).
    try std.testing.expect(cookies[0].http_only and !cookies[1].http_only);

    // The zigbase.auth.clearSession(ctx) re-export delegates to the same policy.
    const via_helper = try @import("auth_helpers.zig").clearSession(&ctx);
    try std.testing.expectEqualStrings(cookies[0].name, via_helper[0].name);
    try std.testing.expectEqualStrings(cookies[1].name, via_helper[1].name);
}

test "ctx.records.list returns created rows; get fetches one by id" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    // Seed two rows directly on the writer.
    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var o1: std.json.ObjectMap = .empty;
        try o1.put(a, "title", .{ .string = "alpha" });
        const c1 = try d.create("posts", .{ .object = o1 });
        var o2: std.json.ObjectMap = .empty;
        try o2.put(a, "title", .{ .string = "beta" });
        _ = try d.create("posts", .{ .object = o2 });
        break :blk try a.dupe(u8, c1.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const page = try ctx.records().list("posts", .{ .sort = "title" });
    try std.testing.expectEqual(@as(usize, 2), page.items.len);

    const one = (try ctx.records().get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
}

test "ctx.records() allocates results on the ctx arena, not app.allocator (no GPA leak)" {
    // Regression: ctx.records() used to allocate results on app.allocator (the GPA),
    // leaking them on the job/route path. Prove results now land on the per-invocation
    // ctx arena: point app.allocator at the leak-checked testing allocator, run records
    // ops through a job-style ctx whose arena is a SEPARATE arena, then deinit ONLY that
    // arena. If any result allocated on app.allocator, std.testing.allocator would flag a
    // leak at test end; the clean exit proves nothing escaped to the GPA.
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const seed_a = env.arena.allocator();

    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = seed_a };
        var o1: std.json.ObjectMap = .empty;
        try o1.put(seed_a, "title", .{ .string = "alpha" });
        const c1 = try d.create("posts", .{ .object = o1 });
        break :blk try seed_a.dupe(u8, c1.object.get("id").?.string);
    };

    // From here, app.allocator is the raw leak-checked testing allocator: any result that
    // leaks to it (instead of the ctx arena) is caught.
    env.app.allocator = std.testing.allocator;

    var job_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&job_arena), .rctx = .{}, .request = null, .bound_conn = null };
    {
        defer ctx.deinit(); // releases the pooled reader first
        const page = try ctx.records().list("posts", .{ .sort = "title" });
        try std.testing.expectEqual(@as(usize, 1), page.items.len);
        try std.testing.expectEqualStrings("alpha", page.items[0].object.get("title").?.string);
        const one = (try ctx.records().get("posts", id, .{})).?;
        try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
    }
    job_arena.deinit(); // frees all result memory; nothing should remain on app.allocator
}

test "Ctx(bound) uses the bound connection and never acquires from the pool" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    var ctx = Ctx{
        .app = &env.app,
        .arena = RequestArena.from(&env.arena),
        .rctx = .{},
        .bound_conn = w,
        .reader = null,
    };
    defer ctx.deinit();

    // No reader is cached because bound_conn short-circuits acquisition.
    const conn = try ctx.connForRead();
    try std.testing.expect(conn == w);
    try std.testing.expect(ctx.reader == null);
}

test "ctx.records create/update/delete round-trips and releases the writer" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "draft" });
    const created = try ctx.records().create("posts", .{ .object = o });
    const id = created.object.get("id").?.string;

    var u: std.json.ObjectMap = .empty;
    try u.put(a, "title", .{ .string = "published" });
    const updated = (try ctx.records().update("posts", id, .{ .object = u })).?;
    try std.testing.expectEqualStrings("published", updated.object.get("title").?.string);

    try std.testing.expect(try ctx.records().delete("posts", id));

    // Writer was released each time: re-acquiring directly must not deadlock.
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = w2;
}

test "ctx.kv set/get round-trips; delete removes" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expect((try ctx.kv().get("k")) == null);
    try ctx.kv().set("k", "v");
    try std.testing.expectEqualStrings("v", (try ctx.kv().get("k")).?);
    try ctx.kv().set("k", "v2");
    try std.testing.expectEqualStrings("v2", (try ctx.kv().get("k")).?);
    try std.testing.expect(try ctx.kv().delete("k"));
    try std.testing.expect((try ctx.kv().get("k")) == null);
}

// A small declared registry for the ctx feature-flag tests below: `beta` (default
// off, the override case), `default_on` (the #128 kill-switch case), `intx` (the
// in-transaction write case).
const flag_test_registry = features.Registry{
    .flags = &.{
        .{ .name = "beta", .default = false },
        .{ .name = "default_on", .default = true },
        .{ .name = "intx", .default = false },
    },
    .experiments = &.{
        .{ .name = "layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 } },
    },
};

test "ctx flags: declared default returned when unset; override wins; flagByName null for undeclared" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // Unset declared flag → declared default.
    try std.testing.expect(!(ctx.flagByName("beta").?));
    // A default-ON flag stays on when unset (#128 kill-switch).
    try std.testing.expect(ctx.flagByName("default_on").?);

    // setFlag writes the flag:<name> override; override wins.
    try ctx.setFlag("beta", true);
    try std.testing.expect(ctx.flagByName("beta").?);
    try std.testing.expectEqualStrings("true", (try ctx.kv().get("flag:beta")).?);
    // Flip the kill switch off.
    try ctx.setFlag("default_on", false);
    try std.testing.expect(!(ctx.flagByName("default_on").?));

    // An undeclared name resolves to null (escape hatch), and setFlag errors.
    try std.testing.expect(ctx.flagByName("never_declared") == null);
    try std.testing.expectError(error.UndeclaredFlag, ctx.setFlag("never_declared", true));
}

test "#230 ctx feature cache: setFlag is instantly visible; flagByName/resolveAll match direct-read" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var cache = feature_cache.FeatureOverrideCache.init(std.testing.allocator);
    defer cache.deinit();
    env.app.feature_cache = &cache; // install the cache on the pooled-reader path
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // Cache-served defaults (byte-identical to the direct-read path).
    try std.testing.expect(!(ctx.flagByName("beta").?)); // declared default off
    try std.testing.expect(ctx.flagByName("default_on").?); // #128 kill-switch default on

    // setFlag invalidates → the NEXT resolution sees the write on THIS instance immediately
    // (no TTL wait). This is the anti-incident guarantee for the override cache.
    try ctx.setFlag("beta", true);
    try std.testing.expect(ctx.flagByName("beta").?);
    try ctx.setFlag("default_on", false); // flip the kill switch OFF
    try std.testing.expect(!(ctx.flagByName("default_on").?));

    // resolveAll (also cache-served) agrees with the resolved state above.
    const resolved = try ctx.flags().resolveAll("user-7");
    try std.testing.expectEqual(@as(usize, 3), resolved.flags.len);
    for (resolved.flags) |rf| {
        if (std.mem.eql(u8, rf.name, "beta")) try std.testing.expect(rf.value);
        if (std.mem.eql(u8, rf.name, "default_on")) try std.testing.expect(!rf.value);
        if (std.mem.eql(u8, rf.name, "intx")) try std.testing.expect(!rf.value);
    }
}

test "#230 ctx feature cache: setFlag inside ctx.tx is visible after commit (post-commit invalidate)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var cache = feature_cache.FeatureOverrideCache.init(std.testing.allocator);
    defer cache.deinit();
    env.app.feature_cache = &cache;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // Warm the cache (snapshot published) so a stale entry would otherwise mask the write.
    try std.testing.expect(!(ctx.flagByName("intx").?));
    // A bound-conn (in-transaction) setFlag: the in-site invalidate fires pre-commit; the
    // post-commit re-invalidate in ctx.tx makes the committed override visible next read.
    try ctx.tx(void, txnSetFlag);
    try std.testing.expect(ctx.flagByName("intx").?); // committed + visible via the cache
}

test "ctx.flags().resolveAll returns all declared flags + experiments via the batched scan" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // One flag override in _kv; everything else falls back to declared defaults.
    try ctx.setFlag("beta", true);

    const resolved = try ctx.flags().resolveAll("user-7");
    try std.testing.expectEqual(@as(usize, 3), resolved.flags.len);
    try std.testing.expectEqual(@as(usize, 1), resolved.experiments.len);
    // beta overridden on, default_on default on, intx default off.
    for (resolved.flags) |rf| {
        if (std.mem.eql(u8, rf.name, "beta")) try std.testing.expect(rf.value);
        if (std.mem.eql(u8, rf.name, "default_on")) try std.testing.expect(rf.value);
        if (std.mem.eql(u8, rf.name, "intx")) try std.testing.expect(!rf.value);
    }
    // The experiment resolves to one of its declared variants, deterministically.
    const v = resolved.experiments[0].variant;
    try std.testing.expect(std.mem.eql(u8, v, "control") or std.mem.eql(u8, v, "compact"));
    const again = try ctx.flags().resolveAll("user-7");
    try std.testing.expectEqualStrings(v, again.experiments[0].variant);
}

test "feature exposure hook fires on flag read + experiment resolve; zero-cost when unset" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;

    const H = struct {
        var flag_calls: usize = 0;
        var exp_calls: usize = 0;
        var last_flag_name: []const u8 = "";
        var last_flag_value: bool = false;
        var last_exp_name: []const u8 = "";
        var last_exp_subject: []const u8 = "";
        var last_exp_variant: []const u8 = "";
        fn onExposure(ev: *events.ExposureEvent) void {
            switch (ev.kind) {
                .flag => {
                    flag_calls += 1;
                    last_flag_name = ev.name;
                    last_flag_value = ev.value;
                },
                .experiment => {
                    exp_calls += 1;
                    last_exp_name = ev.name;
                    last_exp_subject = ev.subject;
                    last_exp_variant = ev.variant;
                },
            }
        }
    };
    H.flag_calls = 0;
    H.exp_calls = 0;

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // Zero-cost path: no dispatch wired -> resolving must NOT invoke any handler.
    try std.testing.expect(env.app.dispatch == null);
    _ = ctx.flagByName("default_on").?;
    _ = try ctx.resolveDeclaredExperiment(flag_test_registry.experiments[0], "user-7");
    try std.testing.expectEqual(@as(usize, 0), H.flag_calls);
    try std.testing.expectEqual(@as(usize, 0), H.exp_calls);

    // Wire a handler -> resolving fires exposure with the right kind/name/subject/value|variant.
    var dispatch = events.Dispatch{ .on_feature_exposure = H.onExposure };
    env.app.dispatch = &dispatch;

    const on = ctx.flagByName("default_on").?;
    try std.testing.expectEqual(@as(usize, 1), H.flag_calls);
    try std.testing.expectEqualStrings("default_on", H.last_flag_name);
    try std.testing.expectEqual(on, H.last_flag_value);
    try std.testing.expect(H.last_flag_value);

    const variant = try ctx.resolveDeclaredExperiment(flag_test_registry.experiments[0], "user-7");
    try std.testing.expectEqual(@as(usize, 1), H.exp_calls);
    try std.testing.expectEqualStrings("layout", H.last_exp_name);
    try std.testing.expectEqualStrings("user-7", H.last_exp_subject);
    try std.testing.expectEqualStrings(variant, H.last_exp_variant);

    // A STICKY experiment (persists its assignment) still fires exposure on the
    // RESOLVED variant — including on the second resolve, which reads the stored
    // assignment rather than re-bucketing.
    const sticky_def = features.ExperimentDef{
        .name = "sticky_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };
    const sv1 = try ctx.resolveDeclaredExperiment(sticky_def, "user-9");
    try std.testing.expectEqual(@as(usize, 2), H.exp_calls);
    try std.testing.expectEqualStrings("sticky_layout", H.last_exp_name);
    try std.testing.expectEqualStrings("user-9", H.last_exp_subject);
    try std.testing.expectEqualStrings(sv1, H.last_exp_variant);
    // Second resolve hits the stored assignment; exposure still fires with the same variant.
    const sv2 = try ctx.resolveDeclaredExperiment(sticky_def, "user-9");
    try std.testing.expectEqual(@as(usize, 3), H.exp_calls);
    try std.testing.expectEqualStrings(sv1, sv2);
    try std.testing.expectEqualStrings(sv1, H.last_exp_variant);
}

fn txnSetFlag(t: *Tx) anyerror!void {
    try t.inner.setFlag("intx", true);
    try std.testing.expectEqualStrings("true", (try t.inner.kv().get("flag:intx")).?);
}

test "ctx.setFlag works inside ctx.tx (bound_conn path)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try ctx.tx(void, txnSetFlag);
    // committed and visible after the transaction.
    try std.testing.expect(ctx.flagByName("intx").?);
}

test "#129 ctx sticky experiment persists + survives a weight change (writer path)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const sticky_def = features.ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve persists the assignment (acquires the writer internally).
    const first = try ctx.resolveDeclaredExperiment(sticky_def, "user-42");

    // A weight override that would force the OTHER variant must not move the subject.
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    try ctx.kv().set("exp:checkout_layout:weights", opposite);
    const after = try ctx.resolveDeclaredExperiment(sticky_def, "user-42");
    try std.testing.expectEqualStrings(first, after);

    // An empty subject still resolves (variant 0) and is never persisted.
    try std.testing.expectEqualStrings("control", try ctx.resolveDeclaredExperiment(sticky_def, ""));
    const conn = try ctx.connForRead();
    var st = try conn.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}

test "ctx.http() returns a client bound to the ctx arena and io" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    const client = ctx.http();
    // Assert the client is bound to the app's io (same userdata pointer).
    try std.testing.expect(client.io.userdata == env.app.io.userdata);
    // Assert two successive calls return clients with the same arena allocator pointer.
    const client2 = ctx.http();
    try std.testing.expect(client.alloc.ptr == client2.alloc.ptr);
    // Assert the allocator pointer matches the ctx's arena allocator.
    try std.testing.expect(client.alloc.ptr == ctx.arena.a.ptr);
}

test "errorResponse maps known errors to status codes, unknown to 500" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 404), ctx.errorResponse(error.NotFound).status);
    try std.testing.expectEqual(@as(u16, 403), ctx.errorResponse(error.Forbidden).status);
    try std.testing.expectEqual(@as(u16, 400), ctx.errorResponse(error.BadRequest).status);
    try std.testing.expectEqual(@as(u16, 409), ctx.errorResponse(error.Conflict).status);
    try std.testing.expectEqual(@as(u16, 401), ctx.errorResponse(error.Unauthorized).status);
    try std.testing.expectEqual(@as(u16, 500), ctx.errorResponse(error.SomethingWeird).status);

    // ctx.fail stashes a custom message that errorResponse(error.Handled) renders. The code is
    // derived from status (422 has no specific mapping, so it falls back to "internal" — see
    // the next case for a status that DOES have a specific code).
    const e = ctx.fail(422, "nope");
    try std.testing.expectError(error.Handled, @as(error{Handled}!void, e));
    const r = ctx.errorResponse(error.Handled);
    try std.testing.expectEqual(@as(u16, 422), r.status);

    // A status error_codes DOES map (403) must not silently ship "internal" — this is the
    // exact regression the {status,code,message,data} unification must not reintroduce.
    const e2 = ctx.fail(403, "nope");
    try std.testing.expectError(error.Handled, @as(error{Handled}!void, e2));
    const r2 = ctx.errorResponse(error.Handled);
    try std.testing.expectEqualStrings(
        "{\"status\":403,\"code\":\"forbidden\",\"message\":\"nope\",\"data\":{}}",
        r2.body,
    );
}

test "ctx.records expand nests the related record under \"expand\"" {
    const env = try CtxTestEnv.initWithRelation();
    defer env.deinit();
    const a = env.arena.allocator();

    const post_id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var ao: std.json.ObjectMap = .empty;
        try ao.put(a, "name", .{ .string = "Ada" });
        const author = try d.create("authors", .{ .object = ao });
        const aid = try a.dupe(u8, author.object.get("id").?.string);
        var po: std.json.ObjectMap = .empty;
        try po.put(a, "title", .{ .string = "p" });
        try po.put(a, "author", .{ .string = aid });
        const post = try d.create("posts", .{ .object = po });
        break :blk try a.dupe(u8, post.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const post = (try ctx.records().get("posts", post_id, .{ .expand = "author" })).?;
    const exp = post.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}

test "ctx.records list expand nests the related record under \"expand\" for each item" {
    const env = try CtxTestEnv.initWithRelation();
    defer env.deinit();
    const a = env.arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var ao: std.json.ObjectMap = .empty;
        try ao.put(a, "name", .{ .string = "Grace" });
        const author = try d.create("authors", .{ .object = ao });
        const aid = try a.dupe(u8, author.object.get("id").?.string);
        inline for (.{ "Post One", "Post Two" }) |title| {
            var po: std.json.ObjectMap = .empty;
            try po.put(a, "title", .{ .string = title });
            try po.put(a, "author", .{ .string = aid });
            _ = try d.create("posts", .{ .object = po });
        }
    }

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const page = try ctx.records().list("posts", .{ .expand = "author" });
    try std.testing.expect(page.items.len >= 2);
    for (page.items) |item| {
        const exp = item.object.get("expand").?.object;
        try std.testing.expectEqualStrings("Grace", exp.get("author").?.object.get("name").?.string);
    }
}

fn txnTwoInserts(t: *Tx) anyerror!void {
    const a = t.arena();
    var o1: std.json.ObjectMap = .empty;
    try o1.put(a, "title", .{ .string = "one" });
    _ = try t.records().create("posts", .{ .object = o1 });
    var o2: std.json.ObjectMap = .empty;
    try o2.put(a, "title", .{ .string = "two" });
    _ = try t.records().create("posts", .{ .object = o2 });
}

test "ctx.tx commits all writes atomically" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try ctx.tx(void, txnTwoInserts);

    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

fn txnInsertThenFail(t: *Tx) anyerror!void {
    const a = t.arena();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "doomed" });
    _ = try t.records().create("posts", .{ .object = o });
    return error.Boom;
}

fn txnNested(t: *Tx) anyerror!void {
    // Attempting a tx inside a tx must be rejected.
    return t.inner.tx(void, txnInsertThenFail);
}

test "ctx.tx rolls back on error and rejects nesting" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectError(error.Boom, ctx.tx(void, txnInsertThenFail));
    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 0), page.items.len); // rolled back

    try std.testing.expectError(error.NestedTransaction, ctx.tx(void, txnNested));
}

const TxWithPayload = struct { title: []const u8 };

fn txnInsertFromPayload(t: *Tx, payload: *const TxWithPayload) anyerror!void {
    const a = t.arena();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = payload.title });
    _ = try t.records().create("posts", .{ .object = o });
}

test "#237 ctx.txWith threads a payload into the callback; the write commits and is readable" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const payload = TxWithPayload{ .title = "from-payload" };
    try ctx.txWith(void, &payload, txnInsertFromPayload);

    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("from-payload", page.items[0].object.get("title").?.string);
}

fn txnInsertFromPayloadThenFail(t: *Tx, payload: *const TxWithPayload) anyerror!void {
    const a = t.arena();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = payload.title });
    _ = try t.records().create("posts", .{ .object = o });
    return error.Boom;
}

test "#237 ctx.txWith rolls back on error; the payload-sourced write is not visible" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const payload = TxWithPayload{ .title = "doomed" };
    try std.testing.expectError(error.Boom, ctx.txWith(void, &payload, txnInsertFromPayloadThenFail));
    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 0), page.items.len); // rolled back
}

fn txnWithNested(t: *Tx, payload: *const TxWithPayload) anyerror!void {
    return t.inner.txWith(void, payload, txnInsertFromPayloadThenFail);
}

test "#237 ctx.txWith rejects nesting" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const payload = TxWithPayload{ .title = "x" };
    try std.testing.expectError(error.NestedTransaction, ctx.txWith(void, &payload, txnWithNested));
}

// ---------------------------------------------------------------------------
// Wave 2 ergonomics (#138/#137) tests.
// ---------------------------------------------------------------------------

test "#138 ctx response builders: shapes + content-types" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // json: serialized body + application/json.
    const j = try ctx.json(201, .{ .ok = true, .n = 7 });
    try std.testing.expectEqual(@as(u16, 201), j.status);
    try std.testing.expectEqualStrings("application/json", j.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true,\"n\":7}", j.body);

    // jsonError: the canonical envelope carrying a consumer-defined machine code.
    const e = try ctx.jsonError(400, "bad_token", "The token is not valid.");
    try std.testing.expectEqual(@as(u16, 400), e.status);
    try std.testing.expectEqualStrings(
        "{\"status\":400,\"code\":\"bad_token\",\"message\":\"The token is not valid.\",\"data\":{}}",
        e.body,
    );

    // html: text/html passthrough body.
    const h = ctx.html(200, "<h1>hi</h1>");
    try std.testing.expectEqualStrings("text/html; charset=utf-8", h.content_type);
    try std.testing.expectEqualStrings("<h1>hi</h1>", h.body);

    // redirect: status + Location header, empty body.
    const r = try ctx.redirect(302, "/login");
    try std.testing.expectEqual(@as(u16, 302), r.status);
    try std.testing.expectEqual(@as(usize, 1), r.extra_headers.len);
    try std.testing.expectEqualStrings("Location", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("/login", r.extra_headers[0].value);
    try std.testing.expectEqualStrings("", r.body);

    // notFound: canonical 404 envelope.
    const nf = try ctx.notFound();
    try std.testing.expectEqual(@as(u16, 404), nf.status);
    try std.testing.expect(std.mem.indexOf(u8, nf.body, "Not found.") != null);
}

test "#138 ctx.setCookie/addHeader accumulate on the Ctx" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try ctx.setCookie(.{ .name = "a", .value = "1" });
    try ctx.setCookie(.{ .name = "b", .value = "2" });
    try ctx.addHeader(.{ .name = "X-One", .value = "y" });
    try std.testing.expectEqual(@as(usize, 2), ctx.pending_cookies.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_headers.items.len);
    try std.testing.expectEqualStrings("a", ctx.pending_cookies.items[0].name);
    try std.testing.expectEqualStrings("X-One", ctx.pending_headers.items[0].name);
}

test "#138 ctx.query() lazily decodes (+ and %XX) and caches" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var req = http_mod.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&env.arena), .query = "q=a+b&pct=%41&n=2" };
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = &req };
    defer ctx.deinit();

    const q = try ctx.query();
    try std.testing.expectEqualStrings("a b", q.get("q").?); // '+' -> space
    try std.testing.expectEqualStrings("A", q.get("pct").?); // %41 -> 'A'
    try std.testing.expectEqualStrings("2", q.get("n").?);
    try std.testing.expect(q.get("missing") == null);

    // Cached: a second call returns the same parsed pairs (same backing slice).
    const q2 = try ctx.query();
    try std.testing.expect(q.pairs.ptr == q2.pairs.ptr);

    // No request -> empty params, no error.
    var jobctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer jobctx.deinit();
    try std.testing.expect((try jobctx.query()).get("q") == null);
}

test "#138 ctx.randomToken length + base36 charset; randomHex hex charset" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const t = try ctx.randomToken(24);
    try std.testing.expectEqual(@as(usize, 24), t.len);
    for (t) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z'));

    const hx = try ctx.randomHex(16);
    try std.testing.expectEqual(@as(usize, 16), hx.len);
    for (hx) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
}

test "#137 ctx.subjectCookie mints once, is idempotent, and reads back an existing value" {
    const env = try CtxTestEnv.init();
    defer env.deinit();

    // Mint path: no incoming cookie -> a fresh id + exactly one queued Set-Cookie.
    {
        var req = http_mod.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&env.arena) };
        var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = &req };
        defer ctx.deinit();

        const id1 = try ctx.subjectCookie("sid", .{});
        try std.testing.expectEqual(Ctx.subject_token_len, id1.len);
        for (id1) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z'));
        try std.testing.expectEqual(@as(usize, 1), ctx.pending_cookies.items.len);
        const ck = ctx.pending_cookies.items[0];
        try std.testing.expectEqualStrings("sid", ck.name);
        try std.testing.expectEqualStrings(id1, ck.value);
        // Default opts: secure, lax, http-only, root path.
        try std.testing.expect(ck.secure and ck.http_only and ck.same_site == .lax);
        try std.testing.expectEqualStrings("/", ck.path);

        // Idempotent within the request: same id, no second cookie queued.
        const id2 = try ctx.subjectCookie("sid", .{});
        try std.testing.expectEqualStrings(id1, id2);
        try std.testing.expectEqual(@as(usize, 1), ctx.pending_cookies.items.len);
    }

    // Read-back path: a well-formed incoming cookie wins (no mint, no Set-Cookie).
    {
        var req = http_mod.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&env.arena), .cookie_header = "sid=abc123xyz" };
        var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = &req };
        defer ctx.deinit();
        const id = try ctx.subjectCookie("sid", .{});
        try std.testing.expectEqualStrings("abc123xyz", id);
        try std.testing.expectEqual(@as(usize, 0), ctx.pending_cookies.items.len);
    }

    // Malformed incoming value (contains a space) -> re-mint.
    {
        var req = http_mod.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&env.arena), .cookie_header = "sid=bad value" };
        var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = &req };
        defer ctx.deinit();
        const id = try ctx.subjectCookie("sid", .{});
        try std.testing.expectEqual(Ctx.subject_token_len, id.len);
        try std.testing.expectEqual(@as(usize, 1), ctx.pending_cookies.items.len);
    }
}

test "#139 ctx.verifyPathSecret constant-time path param check" {
    const env = try CtxTestEnv.init();
    defer env.deinit();

    const params = [_]http_mod.Param{.{ .key = "token", .value = "s3cr3t" }};
    var req = http_mod.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&env.arena), .params = &params };
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{}, .request = &req };
    defer ctx.deinit();

    // Correct secret matches; wrong secret and empty stored fail.
    try std.testing.expect(ctx.verifyPathSecret("token", "s3cr3t"));
    try std.testing.expect(!ctx.verifyPathSecret("token", "wrong"));
    try std.testing.expect(!ctx.verifyPathSecret("token", "")); // empty stored never matches
    try std.testing.expect(!ctx.verifyPathSecret("missing", "s3cr3t")); // absent param

    // No request context -> false (no panic).
    var jobctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer jobctx.deinit();
    try std.testing.expect(!jobctx.verifyPathSecret("token", "s3cr3t"));
}

// ---------------------------------------------------------------------------
// Background jobs & queues (#137 PR2) — ctx.enqueue round-trips.
// ---------------------------------------------------------------------------

const queue_test = struct {
    var mem_runs: usize = 0;
    var mem_payload_buf: [256]u8 = undefined;
    var mem_payload_len: usize = 0;

    fn durableHandler(c: *Ctx, payload: []const u8) anyerror!void {
        _ = c;
        _ = payload;
    }
    fn memHandler(c: *Ctx, payload: []const u8) anyerror!void {
        _ = c;
        @memcpy(mem_payload_buf[0..payload.len], payload);
        mem_payload_len = payload.len;
        mem_runs += 1;
    }
};

test "ctx.enqueue durable round-trips: serializes payload into a _queue_jobs row" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{.{ .kind = "echo", .handler = queue_test.durableHandler }},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try ctx.enqueue(.default, .echo, .{ .n = 7 });

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT queue, kind, payload, status FROM \"_queue_jobs\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("default", st.columnText(0));
    try std.testing.expectEqualStrings("echo", st.columnText(1));
    try std.testing.expectEqualStrings("{\"n\":7}", st.columnText(2));
    try std.testing.expectEqualStrings("pending", st.columnText(3));
}

test "ctx.enqueue memory round-trips: runs the handler on the bounded pool" {
    queue_test.mem_runs = 0;
    queue_test.mem_payload_len = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } }},
        .jobs = &.{.{ .kind = "echo", .handler = queue_test.memHandler }},
    };
    app.queues = @ptrCast(&reg);
    var pool = queue_memory.Pool.init(&app);
    pool.install(&app);

    var ctx = Ctx{ .app = &app, .arena = RequestArena.from(&arena), .rctx = .{} };
    defer ctx.deinit();
    try ctx.enqueueByName("default", "echo", .{ .v = "hi" });

    pool.stop(); // drain + join: deterministic
    try std.testing.expectEqual(@as(usize, 1), queue_test.mem_runs);
    try std.testing.expectEqualStrings("{\"v\":\"hi\"}", queue_test.mem_payload_buf[0..queue_test.mem_payload_len]);
}

test "ctx.enqueue errors on unknown queue / kind / no registry" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    // No registry wired.
    try std.testing.expectError(error.QueuesUnavailable, ctx.enqueueByName("default", "echo", .{}));

    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{.{ .kind = "echo", .handler = queue_test.durableHandler }},
    };
    env.app.queues = @ptrCast(&reg);
    try std.testing.expectError(error.UnknownQueue, ctx.enqueueByName("nope", "echo", .{}));
    try std.testing.expectError(error.UnknownJobKind, ctx.enqueueByName("default", "nope", .{}));
}

// ---------------------------------------------------------------------------
// ctx.mail() (#141) — send via the mailer/test-capture seam; enqueue via the
// built-in "mail" job kind (memory + durable round-trips).
// ---------------------------------------------------------------------------

const mailer_mod = @import("mail/mailer.zig");
const testcapture = @import("testcapture.zig");

/// The framework-owned built-in "mail" job kind registry entry (mirrors what
/// framework.zig prepends), so the queue can drain a "mail" job in these tests.
const mail_job_reg = queue_mod.JobReg{ .kind = "mail", .handler = mail_send.jobHandler };

test "#141 ctx.mail().send delivers via the mailer and is captured by testcapture.mail" {
    if (!testcapture.enabled) return error.SkipZigTest;
    const env = try CtxTestEnv.init();
    defer env.deinit();

    var lm = mailer_mod.LogMailer.init();
    const m = lm.mailer();
    env.app.mailer = &m;

    testcapture.mail.reset();
    defer testcapture.mail.reset();
    testcapture.mail.enable(true); // capture + suppress real delivery

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try ctx.mail().send(.{
        .to = "user@example.com",
        .subject = "Welcome",
        .text = "hello there",
        .html = "<b>hello there</b>",
    });

    try std.testing.expectEqual(@as(usize, 1), testcapture.mail.count());
    const e = testcapture.mail.get(0).?;
    try std.testing.expectEqualStrings("user@example.com", e.to);
    try std.testing.expectEqualStrings("Welcome", e.subject);
    try std.testing.expectEqualStrings("hello there", e.body); // text part captured
}

test "#141 ctx.mail().send rejects a malformed address / header injection up front" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try std.testing.expectError(error.InvalidAddress, ctx.mail().send(.{ .to = "not-an-email", .subject = "s", .text = "b" }));
    try std.testing.expectError(error.HeaderInjection, ctx.mail().send(.{ .to = "u@x.io\r\nBcc: e@evil.io", .subject = "s", .text = "b" }));
    try std.testing.expectError(error.EmptyBody, ctx.mail().send(.{ .to = "u@x.io", .subject = "s" }));
}

test "ctx.mail().unsubscribeUrl builds a token that verifies to (account, list, recipient); errors when unconfigured" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.jwt_secret = "s";
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectError(error.UnsubscribeNotConfigured, ctx.mail().unsubscribeUrl("acc1", "news", "u@x.io"));

    env.app.mail.unsubscribe_base_url = "https://app.example";
    const url = try ctx.mail().unsubscribeUrl("acc1", "news", "u@x.io");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://app.example/api/mail/unsubscribe?t="));
    const marker = "?t=";
    const token = url[std.mem.indexOf(u8, url, marker).? + marker.len ..];
    const parts = mail_unsubscribe.verify(env.arena.allocator(), "s", token) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("acc1", parts.account);
    try std.testing.expectEqualStrings("news", parts.list);
    try std.testing.expectEqualStrings("u@x.io", parts.recipient);
}

test "#141 ctx.mail().enqueue durable round-trips into a _queue_jobs 'mail' row" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try ctx.mail().enqueue(.{ .to = "user@example.com", .subject = "Hi", .text = "body" }, .{});

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT kind, payload, status FROM \"_queue_jobs\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("mail", st.columnText(0));
    // The payload is the serialized MailMessage (round-trippable by the job handler).
    try std.testing.expect(std.mem.indexOf(u8, st.columnText(1), "\"to\":\"user@example.com\"") != null);
    try std.testing.expectEqualStrings("pending", st.columnText(2));
}

test "#141 ctx.mail().enqueue validates before enqueueing (bad address never persists)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try std.testing.expectError(error.InvalidAddress, ctx.mail().enqueue(.{ .to = "bad", .subject = "s", .text = "b" }, .{}));

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT COUNT(*) FROM \"_queue_jobs\";");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0)); // nothing persisted
}

test "#141 ctx.mail().enqueue memory round-trips: built-in handler delivers + is captured" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lm = mailer_mod.LogMailer.init();
    const m = lm.mailer();
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .mailer = &m };
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } }},
        .jobs = &.{mail_job_reg},
    };
    app.queues = @ptrCast(&reg);
    var pool = queue_memory.Pool.init(&app);
    pool.install(&app);

    testcapture.mail.reset();
    defer testcapture.mail.reset();
    testcapture.mail.enable(true);

    var ctx = Ctx{ .app = &app, .arena = RequestArena.from(&arena), .rctx = .{} };
    defer ctx.deinit();
    try ctx.mail().enqueue(.{ .to = "queued@example.com", .subject = "Async", .text = "later" }, .{});

    pool.stop(); // drain + join: deterministic
    try std.testing.expectEqual(@as(usize, 1), testcapture.mail.count());
    try std.testing.expectEqualStrings("queued@example.com", testcapture.mail.get(0).?.to);
}

// ---------------------------------------------------------------------------
// ctx.mail().deliverAt / .cancel (#154 round 2) — scheduling primitives.
// ---------------------------------------------------------------------------

test "ctx.mail().deliverAt on a durable queue returns the job id + persists run_at" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    const now = clock.nowUnix(env.app.io);
    const jid = try ctx.mail().deliverAt(.{ .to = "user@example.com", .subject = "Hi", .text = "body" }, .{ .at = now + 3600 });
    try std.testing.expectEqual(@as(usize, 15), jid.len);

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT run_at, status FROM \"_queue_jobs\" WHERE \"id\"=?1;");
    defer st.finalize();
    try st.bindText(1, jid);
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(now + 3600, st.columnInt(0));
    try std.testing.expectEqualStrings("pending", st.columnText(1));
}

test "ctx.mail().deliverAt requires a durable queue and rejects a conflicting schedule" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    try std.testing.expectError(error.ScheduleRequiresDurable, ctx.mail().deliverAt(
        .{ .to = "user@example.com", .subject = "Hi", .text = "body" },
        .{ .delay_s = 60 },
    ));
    try std.testing.expectError(error.ConflictingSchedule, ctx.mail().deliverAt(
        .{ .to = "user@example.com", .subject = "Hi", .text = "body" },
        .{ .at = 1, .delay_s = 60 },
    ));
}

test "ctx.mail().cancel: pending -> true, then already-canceled -> false" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    const now = clock.nowUnix(env.app.io);
    const jid = try ctx.mail().deliverAt(.{ .to = "user@example.com", .subject = "Hi", .text = "body" }, .{ .at = now + 3600 });
    try std.testing.expect(try ctx.mail().cancel(jid));
    try std.testing.expect(!try ctx.mail().cancel(jid));
}

test "ctx.mail().enqueue with .delay_s schedules a future run_at" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{mail_job_reg},
    };
    env.app.queues = @ptrCast(&reg);

    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();
    const now = clock.nowUnix(env.app.io);
    try ctx.mail().enqueue(.{ .to = "user@example.com", .subject = "Hi", .text = "body" }, .{ .delay_s = 60 });

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT run_at FROM \"_queue_jobs\" WHERE kind='mail';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expect(st.columnInt(0) > now);
}

// ---------------------------------------------------------------------------
// CAPTCHA (#140, PR6) — ctx.verifyCaptcha tests.
// ---------------------------------------------------------------------------

test "#140 ctx.verifyCaptcha dev-bypass: empty captcha_secret returns ok=true without network" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    // Default app has captcha_secret = "" (dev-bypass active).
    try std.testing.expectEqualStrings("", env.app.captcha_secret);
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // All four providers bypass when secret is empty — no network, no error.
    const r1 = try ctx.verifyCaptcha(.recaptcha_v2, "any-token");
    try std.testing.expect(r1.ok);
    const r2 = try ctx.verifyCaptcha(.recaptcha_v3, "any-token");
    try std.testing.expect(r2.ok);
    const r3 = try ctx.verifyCaptcha(.hcaptcha, "any-token");
    try std.testing.expect(r3.ok);
    const r4 = try ctx.verifyCaptcha(.turnstile, "any-token");
    try std.testing.expect(r4.ok);
}

test "#140 ctx.verifyCaptcha with mock: uses app.captcha_secret and forwards to provider" {
    if (!@import("testcapture.zig").enabled) return error.SkipZigTest;
    @import("testcapture.zig").http.reset();
    defer @import("testcapture.zig").http.reset();

    @import("testcapture.zig").http.enable(true);
    @import("testcapture.zig").http.mock("google.com/recaptcha", .{
        .status = 200,
        .body = "{\"success\":true,\"score\":0.7,\"action\":\"submit\",\"hostname\":\"test.example.com\"}",
    });

    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.captcha_secret = "my-server-secret";
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    const r = try ctx.verifyCaptcha(.recaptcha_v3, "user-token");
    try std.testing.expect(r.ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), r.score.?, 0.001);
    try std.testing.expectEqualStrings("submit", r.action.?);
    try std.testing.expectEqualStrings("test.example.com", r.hostname.?);

    // Verify secret was sent in the POST body.
    const req = @import("testcapture.zig").http.requestAt(0).?;
    const body = req.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "secret=my-server-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response=user-token") != null);
}

test "#140 ctx.verifyCaptcha network error propagates (fails-closed by default)" {
    if (!@import("testcapture.zig").enabled) return error.SkipZigTest;
    @import("testcapture.zig").http.reset();
    defer @import("testcapture.zig").http.reset();

    // Capture with block_unmocked=true so all requests fail.
    @import("testcapture.zig").http.enable(true);

    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.captcha_secret = "real-secret";
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    // Network failure propagates — handler can catch and decide fail-open vs fail-closed.
    try std.testing.expectError(error.TransportFailed, ctx.verifyCaptcha(.turnstile, "token"));
}

test "#140 ctx.verifyCaptcha errors on a provider that differs from the configured one" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    // Both a secret AND a provider are configured: a mismatched call must fail fast.
    env.app.captcha_secret = "real-secret";
    env.app.captcha_provider = .recaptcha_v3;
    var ctx = Ctx{ .app = &env.app, .arena = RequestArena.from(&env.arena), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectError(error.CaptchaProviderMismatch, ctx.verifyCaptcha(.hcaptcha, "token"));

    // The dev-bypass wins even over a mismatch: an empty secret never verifies, so no error.
    env.app.captcha_secret = "";
    const r = try ctx.verifyCaptcha(.hcaptcha, "token");
    try std.testing.expect(r.ok);
}

test "#143 ctx.realtime(): signal + broadcast serialize and are safe no-ops when the reactor is inactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cx = Ctx{ .app = undefined, .arena = RequestArena.from(&arena), .rctx = .{} };
    cx.realtime().signal("availability");
    // Serialization happens at the call site; the publish itself is a no-op (inactive reactor).
    try cx.realtime().broadcast("orders", .{ .kind = "order.shipped", .id = "r1" });
}

// ---------------------------------------------------------------------------
// #244: ctx.reportError routes a consumer-swallowed error through the same
// pluggable backstop the framework uses, tagged with the `.app` phase.
// ---------------------------------------------------------------------------

// Capturing reporter for the reportError tests: copies the delivered report's phase +
// message into static buffers so they can be asserted after the (inline) job arena is freed.
const ReportCapture = struct {
    var phase_buf: [32]u8 = undefined;
    var msg_buf: [256]u8 = undefined;
    var phase: []const u8 = "";
    var msg: []const u8 = "";
    var count: usize = 0;

    fn reset() void {
        phase = "";
        msg = "";
        count = 0;
    }
    fn report(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, r: report_reporter.Report) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        // Bounded copy: truncate rather than panic/OOB if a future phase/message exceeds
        // the fixed-size capture buffers (test helper only — not on any production path).
        const phase_n = @min(r.phase.len, phase_buf.len);
        @memcpy(phase_buf[0..phase_n], r.phase[0..phase_n]);
        phase = phase_buf[0..phase_n];
        const msg_n = @min(r.message.len, msg_buf.len);
        @memcpy(msg_buf[0..msg_n], r.message[0..msg_n]);
        msg = msg_buf[0..msg_n];
        count += 1;
    }
    const vtable = report_reporter.Reporter.VTable{ .report = report };
};

test "#244 ctx.reportError routes through dispatchError to the reporter tagged .app" {
    ReportCapture.reset();
    var rep_ctx: u8 = 0;
    var iface = report_reporter.Reporter{ .ptr = &rep_ctx, .vtable = &ReportCapture.vtable };

    // No memory pool → dispatchError's enqueue runs the "report" job INLINE (deterministic).
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    app.reporter = &iface;
    app.report_dedup = null;
    app.memory_pool = null;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cx = Ctx{ .app = &app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
    defer cx.deinit();

    cx.reportError(error.WidgetExploded, "widget {d} failed: {s}", .{ 7, "overheat" });

    try std.testing.expectEqual(@as(usize, 1), ReportCapture.count);
    try std.testing.expectEqualStrings("app", ReportCapture.phase); // the .app phase tag is carried
    try std.testing.expectEqualStrings("widget 7 failed: overheat", ReportCapture.msg);
}

test "#244 ctx.reportError never fails even on a pathological/failing arena (falls back to @errorName)" {
    ReportCapture.reset();
    var rep_ctx: u8 = 0;
    var iface = report_reporter.Reporter{ .ptr = &rep_ctx, .vtable = &ReportCapture.vtable };

    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    app.reporter = &iface;
    app.report_dedup = null;
    app.memory_pool = null;

    // A failing arena makes the message allocPrint fail; reportError must swallow it and
    // fall back to @errorName(err) rather than propagate — it returns void and cannot throw.
    var cx = Ctx{ .app = &app, .arena = RequestArena.forTest(std.testing.failing_allocator), .rctx = .{}, .request = null, .bound_conn = null };
    defer cx.deinit();

    cx.reportError(error.Boom, "this needs {d} allocation(s)", .{42});

    try std.testing.expectEqual(@as(usize, 1), ReportCapture.count);
    try std.testing.expectEqualStrings("app", ReportCapture.phase);
    try std.testing.expectEqualStrings("Boom", ReportCapture.msg); // fell back to @errorName
}
