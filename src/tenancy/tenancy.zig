//! Account-scoped multi-tenancy: tenant resolution + row scoping (#156, PR2).
//!
//! A collection becomes "tenant-owned" when its `.tenant_field` schema option names the column
//! that holds the owning account id (`schema.CollectionOptions.tenant_field`). Every read/write of
//! such a collection is automatically narrowed to the request's ACTIVE account via a bound
//! `"<col>"."<tenant_field>" = ?` predicate (`scopePredicate`), composed into the same guard stack
//! as the access rule and TTL filter by `policy.zig`.
//!
//! The active account is RESOLVED per request from a verified `_memberships` row (`resolve`): the
//! authenticated principal must have an `active` membership of the requested account, else there is
//! NO account context and tenant-owned data is invisible (fail closed). Resolution is ONE indexed
//! SELECT and is cached on the `RequestContext`, so there is no N+1.
//!
//! Back-compat is sacred: when the app has no tenancy (`Runtime.enabled == false`) or a collection
//! has no `tenant_field`, `scopePredicate` returns null and the composed SQL/decisions are
//! byte-identical to the pre-tenancy engine (pinned in `policy.zig`).

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const schema = @import("../schema.zig");
const request = @import("../request.zig");
const compiler = @import("../query/compiler.zig");
const db = @import("../db.zig");
const crypto = @import("../crypto.zig");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const auth = @import("../auth.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// How the active account id is resolved off an incoming request. `.header` (the default) reads
/// the `X-Account-Id` request header (or the signed `zb_account` cookie). Kept an enum so
/// `.subdomain` / `.path` can be added later WITHOUT touching the resolver call sites or the
/// scoping plumbing — only `requestedAccount` grows a new arm.
pub const Resolver = enum { header };

/// The runtime tenancy knobs threaded from the comptime `App(.{ .tenancy = ... })` config into
/// `app.App.tenancy`. `enabled == false` (the default) is the byte-identical no-tenancy path.
pub const Runtime = struct {
    enabled: bool = false,
    resolver: Resolver = .header,
    /// The auth collection whose records hold tenant memberships (the `user_collection` side of a
    /// `_memberships` row). "" when tenancy is disabled.
    auth_collection: []const u8 = "",
};

/// The membership status that grants account context. Anything else (`invited`, `suspended`, …)
/// is treated as NO active membership — fail closed.
pub const active_status = "active";

/// Request header carrying the desired active account id (`.header` resolver).
pub const account_header = "x-account-id"; // ctx.header lower-cases names
/// Signed cookie carrying the desired active account id (browser apps that called `activate`).
pub const account_cookie = "zb_account";

/// A compiled, parameter-bound tenant-scope predicate: `"<col>"."<tenant_field>" = ?` plus the
/// single bound account-id param. AND-ed into the guard stack by `policy.zig`.
pub const Scoped = struct {
    sql: []const u8,
    param: compiler.Param,
};

/// True iff a tenant-scope predicate APPLIES to `action` on `col` for `rctx` — i.e. tenancy is
/// enabled, the principal is not a superuser (superusers bypass tenancy), and the collection is
/// tenant-owned. `policy.decide` uses this to force a per-row `check` even when the access rule
/// alone would `allow`, so a tenant-owned collection is never served un-scoped.
pub fn scopeApplies(col: schema.Collection, rctx: *const request.RequestContext) bool {
    if (rctx.is_superuser) return false; // superuser bypass (consistent with rules.decide)
    if (rctx.cross_tenant) return false; // explicit superuser/admin tooling override
    if (!rctx.tenancy_enabled) return false;
    const tf = col.options.tenant_field orelse return false;
    return schema.isValidIdentifier(col.name) and schema.isValidIdentifier(tf);
}

/// Build the tenant-scope predicate for `col` under `rctx`, or null when scoping does not apply
/// (no tenancy / superuser / not tenant-owned). The bound param is the request's active
/// `account_id` (which is "" when no membership resolved — so a tenant-owned collection shows NO
/// real-tenant rows, fail closed). Identifiers are gated through `schema.isValidIdentifier`; the
/// account id is BOUND (`?`), never interpolated.
pub fn scopePredicate(alloc: std.mem.Allocator, col: schema.Collection, rctx: *const request.RequestContext) std.mem.Allocator.Error!?Scoped {
    if (!scopeApplies(col, rctx)) return null;
    const tf = col.options.tenant_field.?;
    const sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\" = ?", .{ col.name, tf });
    return .{ .sql = sql, .param = .{ .text = rctx.account_id } };
}

/// Return a copy of `rctx` with the explicit cross-tenant override enabled. Superuser/admin
/// tooling (an ops dashboard moving a record between accounts, a maintenance job spanning tenants)
/// uses this to suppress the tenant-scope predicate AND the write-path stamping/cross-tenant guard
/// — the deliberate, never-silent way to widen scope. Never derive this from an end-user request.
pub fn crossTenant(rctx: request.RequestContext) request.RequestContext {
    var c = rctx;
    c.cross_tenant = true;
    return c;
}

// ---- Tenant resolution ------------------------------------------------------

/// The resolved account scope for a request: the active account + role, and every account the
/// principal belongs to (the source for `@request.account.ids`). All slices are allocated on the
/// caller's (request) arena.
pub const Resolution = struct {
    account_id: []const u8 = "",
    account_role: []const u8 = "",
    memberships: []const request.Membership = &.{},
};

/// Defensive cap on memberships read per request (bounds allocation; a principal in this many
/// accounts is pathological).
const max_memberships = 1000;

/// Resolve the active account for an authenticated principal.
///
/// ONE indexed SELECT on `_memberships (user_collection, user, status)` loads every `active`
/// membership for `(user_collection, user)`. The set populates `memberships` (for the
/// `@request.account.ids` macro); the `requested` account — when present AND found among those
/// active memberships — becomes the active `account_id`/`account_role`. A `requested` account the
/// principal is NOT an active member of yields NO active scope (account_id stays "") — cross-tenant
/// access is denied, fail closed. An empty `requested` (no header/cookie) also yields no active
/// scope while still exposing the membership list.
pub fn resolve(
    alloc: std.mem.Allocator,
    conn: *db.Db,
    user_collection: []const u8,
    user_id: []const u8,
    requested: []const u8,
) !Resolution {
    if (user_collection.len == 0 or user_id.len == 0) return .{};

    var list: std.ArrayList(request.Membership) = .empty;
    defer list.deinit(alloc); // no-op after toOwnedSlice (success); frees on an OOM error path
    var st = try conn.prepare(
        "SELECT \"account\",\"role\" FROM \"_memberships\" WHERE \"user_collection\"=?1 AND \"user\"=?2 AND \"status\"=?3;",
    );
    defer st.finalize();
    try st.bindText(1, user_collection);
    try st.bindText(2, user_id);
    try st.bindText(3, active_status);
    while (try st.step()) {
        if (list.items.len >= max_memberships) {
            // Pathological (a principal in >max_memberships active accounts). Already fail-closed
            // (an omitted account just under-matches `@request.account.ids`); log for diagnosis.
            std.log.warn("tenancy: membership list truncated at {d} for user '{s}' in '{s}' — @request.account.ids may under-match", .{ max_memberships, user_id, user_collection });
            break;
        }
        const account = try alloc.dupe(u8, st.columnText(0));
        const role = try alloc.dupe(u8, st.columnText(1));
        try list.append(alloc, .{ .account = account, .role = role });
    }
    const memberships = try list.toOwnedSlice(alloc);

    var out = Resolution{ .memberships = memberships };
    if (requested.len > 0) {
        for (memberships) |m| {
            if (std.mem.eql(u8, m.account, requested)) {
                out.account_id = m.account;
                out.account_role = m.role;
                break;
            }
        }
    }
    return out;
}

// ---- Request-level tenancy resolution (shared chokepoint helper) -----------

/// The account id a request is asking to act within: the `X-Account-Id` header, else the signed
/// `zb_account` cookie (browser apps that called `activate`). The header is unsigned but safe — a
/// forged value only grants scope if `resolveRequest` finds an ACTIVE membership for it. Resolver
/// is an enum on `app.tenancy.resolver` so `.subdomain`/`.path` can be added here later without
/// touching callers.
pub fn requestedAccount(ctx: *const http.RequestCtx, app: *app_mod.App) ?[]const u8 {
    switch (app.tenancy.resolver) {
        .header => {
            if (ctx.header(account_header)) |h| if (h.len > 0) return h;
            if (ctx.cookie(account_cookie)) |c| if (c.len > 0) return verifyAccount(app.jwt_secret, c);
            return null;
        },
    }
}

/// Resolve + fill the active tenant scope (`tenancy_enabled`/`role_ranking`/`account_id`/
/// `account_role`/`memberships`) onto `rctx` for an authenticated principal. Called directly by
/// the REST/custom-route chokepoints that need the FULL resolved scope on `RequestContext`
/// (`api/records.zig`'s `buildContext`, `server.zig`'s `dispatchCustom`, `api/files.zig`'s
/// `serve`). `api/senders.zig` and `analytics/api.zig` do NOT call this function — they share
/// the underlying `requestedAccount`/`resolve` primitives but apply their own scope policy on
/// top (e.g. broader/narrower than "the caller's active account"), so do not fold them into this
/// chokepoint as a "unification" cleanup. Semantics:
///
///   * `rctx.tenancy_enabled`/`rctx.role_ranking` are always copied from `app` (byte-identical
///     no-tenancy path when `app.tenancy.enabled == false`).
///   * A superuser bypasses resolution entirely (consistent with `rules.decide`'s superuser bypass)
///     — `account_id` stays at its zero-value `""` (global scope, not a specific tenant).
///   * Otherwise, when tenancy is enabled: the `X-Account-Id` header / `zb_account` cookie names
///     the desired account; `tenancy.resolve` grants scope ONLY if the principal has a verified
///     ACTIVE `_memberships` row for that account. No match (wrong account, no header/cookie,
///     inactive/invited/suspended membership) leaves `account_id` empty — fail closed, never an
///     error surfaced to the caller.
///   * A resolution error (e.g. a transient DB error) is swallowed the same way: the fail-closed
///     empty scope is kept and the error is logged (never account ids at error level — see the
///     no-credential-logging rule) so a bug here denies tenant-owned data rather than leaking it.
///
/// Callers that already hold an `auth.Authed` (every chokepoint authenticates first) pass it in;
/// this function does no authentication of its own.
pub fn resolveRequest(
    ctx: *const http.RequestCtx,
    conn: *db.Db,
    app: *app_mod.App,
    a: auth.Authed,
    rctx: *request.RequestContext,
) void {
    rctx.tenancy_enabled = app.tenancy.enabled;
    rctx.role_ranking = app.role_ranking; // ability `.min_role` comparisons (#155)
    if (!app.tenancy.enabled or a.is_superuser) return;
    resolveRequestInner(ctx, conn, app, a, rctx) catch |e|
        std.log.warn("tenant resolution failed (request scoped to no account): {}", .{e});
}

fn resolveRequestInner(
    ctx: *const http.RequestCtx,
    conn: *db.Db,
    app: *app_mod.App,
    a: auth.Authed,
    rctx: *request.RequestContext,
) !void {
    if (a.record != .object) return;
    const id_v = a.record.object.get("id") orelse return;
    if (id_v != .string) return;
    const requested = requestedAccount(ctx, app) orelse "";
    const res = try resolve(ctx.allocator.a, conn, a.collection, id_v.string, requested);
    rctx.account_id = res.account_id;
    rctx.account_role = res.account_role;
    rctx.memberships = res.memberships;
}

// ---- Signed `zb_account` cookie (browser activation) ------------------------

/// Sign `account_id` into the opaque `zb_account` cookie value `"<account_id>.<hex-hmac>"`, using
/// HMAC-SHA256 over the app's `jwt_secret` (the same primitive the auth tokens are signed with).
/// Domain-separated by an `account_cookie|` prefix so the MAC can never be replayed in another
/// context. Returned on the caller's arena.
pub fn signAccount(alloc: std.mem.Allocator, secret: []const u8, account_id: []const u8) ![]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    macFor(secret, account_id, &mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ account_id, hex });
}

/// Verify a `zb_account` cookie value and return the account id it carries, or null if the value
/// is malformed or the MAC does not match (constant-time compare). Fail closed.
pub fn verifyAccount(secret: []const u8, signed: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, signed, '.') orelse return null;
    const account_id = signed[0..dot];
    const sig_hex = signed[dot + 1 ..];
    if (account_id.len == 0) return null;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    macFor(secret, account_id, &mac);
    const want_hex = std.fmt.bytesToHex(mac, .lower);
    if (!crypto.timingSafeEql(&want_hex, sig_hex)) return null;
    return account_id;
}

fn macFor(secret: []const u8, account_id: []const u8, out: *[HmacSha256.mac_length]u8) void {
    var h = HmacSha256.init(secret);
    h.update(account_cookie ++ "|");
    h.update(account_id);
    h.final(out);
}

// ---- Tests ------------------------------------------------------------------

const migrations = @import("../migrations.zig");

test "scopePredicate: null unless enabled + tenant-owned + non-superuser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{.{ .id = "f1", .name = "account", .options = .{ .text = .{} } }};
    var col = schema.Collection{ .id = "c", .name = "posts", .fields = &fields };

    // No tenant_field -> null even with tenancy on.
    {
        const rctx = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
        try std.testing.expect((try scopePredicate(a, col, &rctx)) == null);
    }
    col.options.tenant_field = "account";
    // Tenant-owned but tenancy disabled -> null (byte-identical back-compat).
    {
        const rctx = request.RequestContext{ .tenancy_enabled = false, .account_id = "acc1" };
        try std.testing.expect((try scopePredicate(a, col, &rctx)) == null);
    }
    // Superuser bypass -> null.
    {
        const rctx = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
        try std.testing.expect((try scopePredicate(a, col, &rctx)) == null);
    }
    // Enabled + tenant-owned + non-superuser -> bound predicate.
    {
        const rctx = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
        const sp = (try scopePredicate(a, col, &rctx)).?;
        try std.testing.expectEqualStrings("\"posts\".\"account\" = ?", sp.sql);
        try std.testing.expectEqualStrings("acc1", sp.param.text);
    }
}

test "resolve: only active memberships; requested account must be a member" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES " ++
        "('m1','','','acc1','users','u1','owner','active')," ++
        "('m2','','','acc2','users','u1','viewer','active')," ++
        "('m3','','','acc3','users','u1','admin','invited');");

    // Requested an account the user actively belongs to.
    const r1 = try resolve(a, &d, "users", "u1", "acc2");
    try std.testing.expectEqualStrings("acc2", r1.account_id);
    try std.testing.expectEqualStrings("viewer", r1.account_role);
    try std.testing.expectEqual(@as(usize, 2), r1.memberships.len); // only the 2 active

    // Requested an account whose membership is not active -> no active scope (fail closed).
    const r2 = try resolve(a, &d, "users", "u1", "acc3");
    try std.testing.expectEqualStrings("", r2.account_id);
    try std.testing.expectEqual(@as(usize, 2), r2.memberships.len);

    // No requested account -> membership list still populated, no active scope.
    const r3 = try resolve(a, &d, "users", "u1", "");
    try std.testing.expectEqualStrings("", r3.account_id);
    try std.testing.expectEqual(@as(usize, 2), r3.memberships.len);

    // Unknown user -> empty.
    const r4 = try resolve(a, &d, "users", "ghost", "acc1");
    try std.testing.expectEqual(@as(usize, 0), r4.memberships.len);
}

test "requestedAccount: header wins over the signed cookie; unsigned/bad cookie is ignored" {
    var app = app_mod.App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .jwt_secret = "test-secret" };

    // Neither header nor cookie -> null.
    {
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(std.testing.allocator) };
        try std.testing.expect(requestedAccount(&ctx, &app) == null);
    }
    // Header present -> wins outright (even with a cookie also present).
    {
        const signed = try signAccount(std.testing.allocator, app.jwt_secret, "acc-cookie");
        defer std.testing.allocator.free(signed);
        var hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "acc-header" }};
        var ctx = http.RequestCtx{
            .method = .GET,
            .path = "/",
            .allocator = RequestArena.forTest(std.testing.allocator),
            .headers = &hdrs,
        };
        // cookie name is "zb_account"; wrap it as "zb_account=<signed>" for the cookie parser.
        const cookie_hdr = try std.fmt.allocPrint(std.testing.allocator, "{s}={s}", .{ account_cookie, signed });
        defer std.testing.allocator.free(cookie_hdr);
        ctx.cookie_header = cookie_hdr;
        try std.testing.expectEqualStrings("acc-header", requestedAccount(&ctx, &app).?);
    }
    // No header, valid signed cookie -> the cookie's account.
    {
        const signed = try signAccount(std.testing.allocator, app.jwt_secret, "acc-cookie");
        defer std.testing.allocator.free(signed);
        const cookie_hdr = try std.fmt.allocPrint(std.testing.allocator, "{s}={s}", .{ account_cookie, signed });
        defer std.testing.allocator.free(cookie_hdr);
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(std.testing.allocator), .cookie_header = cookie_hdr };
        try std.testing.expectEqualStrings("acc-cookie", requestedAccount(&ctx, &app).?);
    }
    // No header, tampered cookie (wrong secret's signature) -> null (fail closed, not the forged id).
    {
        const forged = try signAccount(std.testing.allocator, "wrong-secret", "acc-evil");
        defer std.testing.allocator.free(forged);
        const cookie_hdr = try std.fmt.allocPrint(std.testing.allocator, "{s}={s}", .{ account_cookie, forged });
        defer std.testing.allocator.free(cookie_hdr);
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(std.testing.allocator), .cookie_header = cookie_hdr };
        try std.testing.expect(requestedAccount(&ctx, &app) == null);
    }
}

test "resolveRequest: shared chokepoint for records/files/dispatchCustom" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES " ++
        "('m1','','','acc1','profiles','u1','editor','active')," ++
        "('m2','','','acc2','profiles','u1','admin','invited');"); // acc2's membership is NOT active

    // Everything the resolution path allocates (memberships, account/role dupes) is arena-scoped —
    // matches how a real request's `ctx.allocator` is request-arena-backed, and avoids per-case
    // manual frees in this test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = app_mod.App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .jwt_secret = "s" };
    app.tenancy = .{ .enabled = true, .auth_collection = "profiles" };

    const authed_record = std.json.Value{ .object = blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(alloc, "id", .{ .string = "u1" });
        break :blk o;
    } };

    // Tenancy disabled -> byte-identical no-tenancy path: no resolution query, scope untouched,
    // but tenancy_enabled/role_ranking are still copied from `app` (both false/default here).
    {
        var off = app;
        off.tenancy = .{};
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena) };
        var rctx = request.RequestContext{};
        const a = auth.Authed{ .record = authed_record, .collection = "profiles", .is_superuser = false };
        resolveRequest(&ctx, &d, &off, a, &rctx);
        try std.testing.expect(!rctx.tenancy_enabled);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }

    // Superuser bypasses resolution entirely (no query, account_id stays "" = global scope) even
    // when a matching X-Account-Id header is present — the superuser bypass never LEAKS a specific
    // scope by accident; callers that want a superuser to target an account read the header
    // themselves (as senders.zig does), this helper's contract is just "don't force a query".
    {
        var hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "acc1" }};
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena), .headers = &hdrs };
        var rctx = request.RequestContext{};
        const a = auth.Authed{ .record = authed_record, .collection = "profiles", .is_superuser = true };
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expect(rctx.tenancy_enabled);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }

    // Non-superuser, requested account is an ACTIVE membership -> scope granted.
    {
        var hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "acc1" }};
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena), .headers = &hdrs };
        var rctx = request.RequestContext{};
        const a = auth.Authed{ .record = authed_record, .collection = "profiles", .is_superuser = false };
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expectEqualStrings("acc1", rctx.account_id);
        try std.testing.expectEqualStrings("editor", rctx.account_role);
    }

    // Non-superuser, requested account exists but membership is NOT active -> fail closed (empty
    // scope), never an error surfaced.
    {
        var hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "acc2" }};
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena), .headers = &hdrs };
        var rctx = request.RequestContext{};
        const a = auth.Authed{ .record = authed_record, .collection = "profiles", .is_superuser = false };
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }

    // No header/cookie at all -> no active scope (unresolved, fail closed).
    {
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena) };
        var rctx = request.RequestContext{};
        const a = auth.Authed{ .record = authed_record, .collection = "profiles", .is_superuser = false };
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }
}

test "signAccount/verifyAccount round-trip; tamper fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "app-jwt-secret";
    const signed = try signAccount(a, secret, "acc-123");
    try std.testing.expectEqualStrings("acc-123", verifyAccount(secret, signed).?);
    // Wrong secret -> null.
    try std.testing.expect(verifyAccount("other", signed) == null);
    // Tampered account id -> null (MAC no longer matches).
    const tampered = try std.fmt.allocPrint(a, "acc-999.{s}", .{signed[std.mem.lastIndexOfScalar(u8, signed, '.').? + 1 ..]});
    try std.testing.expect(verifyAccount(secret, tampered) == null);
    // Malformed (no dot) -> null.
    try std.testing.expect(verifyAccount(secret, "nodothere") == null);
}
