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
const ddl = @import("../ddl.zig");
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
///
/// Tenant-ownership is decided by the SCHEMA ALONE (`tenant_field != null`). It deliberately does
/// NOT consult `schema.isValidIdentifier`: this predicate is the sink audit finding F18 called out
/// as structurally FAIL-OPEN, because a charset-gate failure here reads as "not tenant-owned" and
/// drops both the forced per-row check and the bound predicate — serving the collection un-scoped
/// across every tenant. An identifier problem must never be able to widen scope, so the identifier
/// is escaped where it is interpolated (`scopePredicate`) rather than gated here.
pub fn scopeApplies(col: schema.Collection, rctx: *const request.RequestContext) bool {
    if (rctx.is_superuser) return false; // superuser bypass (consistent with rules.decide)
    if (rctx.cross_tenant) return false; // explicit superuser/admin tooling override
    if (!rctx.tenancy_enabled) return false;
    return col.options.tenant_field != null;
}

/// Build the tenant-scope predicate for `col` under `rctx`, or null when scoping does not apply
/// (no tenancy / superuser / not tenant-owned). The bound param is the request's active
/// `account_id` (which is "" when no membership resolved — so a tenant-owned collection shows NO
/// real-tenant rows, fail closed). Identifiers are ESCAPED through `ddl.quoteIdent`; the account id
/// is BOUND (`?`), never interpolated.
///
/// Escaping rather than charset-gating is what makes the fail-open branch unreachable BY
/// CONSTRUCTION: there is no longer an identifier shape that silently yields "no predicate". A
/// `tenant_field` naming no column (rejected by `schema.validate`, so only reachable by writing
/// `_collections` directly) now produces a predicate that fails at `prepare` — the request errors
/// instead of quietly returning every tenant's rows.
pub fn scopePredicate(alloc: std.mem.Allocator, col: schema.Collection, rctx: *const request.RequestContext) std.mem.Allocator.Error!?Scoped {
    if (!scopeApplies(col, rctx)) return null;
    const tf = col.options.tenant_field.?;
    const qcol = try ddl.quoteIdent(alloc, col.name);
    defer alloc.free(qcol);
    const qtf = try ddl.quoteIdent(alloc, tf);
    defer alloc.free(qtf);
    const sql = try alloc.print("{s}.{s} = ?", .{ qcol, qtf });
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
/// principal belongs to (the source for `@request.account.ids`). Owned-result contract:
/// call `deinit` with the allocator passed to `resolve`.
pub const Resolution = struct {
    account_id: []const u8 = "",
    account_role: []const u8 = "",
    memberships: []const request.Membership = &.{},

    /// Free the membership list this resolution owns. `account_id`/`account_role` are never
    /// separately allocated — either "" or an alias into one of `memberships`' entries — so
    /// freeing them here would double-free; only the membership dupes + the slice are owned.
    pub fn deinit(self: Resolution, alloc: std.mem.Allocator) void {
        for (self.memberships) |m| {
            alloc.free(m.account);
            alloc.free(m.role);
        }
        alloc.free(self.memberships);
    }
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
    errdefer for (list.items) |m| {
        alloc.free(m.account);
        alloc.free(m.role);
    };
    var st = try conn.prepare(
        if (db.dbDialect(conn).kind == .postgres)
            "SELECT \"account\",\"role\" FROM \"_memberships\" WHERE \"user_collection\"=$1 AND \"user\"=$2 AND \"status\"=$3;"
        else
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
        errdefer alloc.free(account);
        const role = try alloc.dupe(u8, st.columnText(1));
        errdefer alloc.free(role);
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
    return alloc.print("{s}.{s}", .{ account_id, hex });
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

// ---- Cross-tenant relation audit (#497) ---------------------------------------

/// Stored links from a tenant-owned row to a tenant-owned record of ANOTHER account, for one
/// relation field. Since #497 a scoped request can no longer write such a link (the relation
/// check answers `validation_not_found`), but links written earlier — before tenancy was enabled,
/// by a superuser or `crossTenant` tooling, by an import, a migration or `ctx.records()` — stay in
/// place. `zigbase doctor`'s `cross-tenant-relations` check reports them: on a single relation
/// (an FK) the other account's delete of the target cascades into (`cascadeDelete`) or nulls the
/// linking row.
pub const CrossTenantLinks = struct {
    collection: []const u8,
    field: []const u8,
    target: []const u8,
    /// Stored links whose source and target rows are owned by two different accounts.
    count: usize,
    /// Multi relation only: stored values that are not a JSON array (so hold no examinable id
    /// list). Such a value can only come from a raw-SQL write; it is reported, not guessed at.
    unparseable: usize = 0,
};

/// Count cross-tenant links per relation field across `cols` (one entry per field with at least
/// one link or unparseable value). Only a tenant-owned source with a relation to a tenant-owned
/// target is examined; the target is matched by collection id or name, as `collections.get`
/// resolves it. A link whose source or target tenant value is NULL or `''` has no owning account
/// to differ from and is not counted (an empty tenant value is never an active account, so no
/// scoped request can read or write such a row either). Each field is ONE aggregate statement —
/// a JOIN for a single relation, a JOIN over the expanded JSON id array for a multi relation
/// (`json_each` on SQLite, `jsonb_array_elements` on PostgreSQL) — so the database does the work
/// and nothing is buffered here. Read-only.
///
/// On PostgreSQL a value that starts like a JSON array but is not valid JSON makes the multi
/// relation's statement fail; the caller reports the check as not run, with that error.
///
/// Contract 1: caller frees the flat result with `alloc.free`; names borrow from `cols`.
/// Query scratch is freed on every path.
pub fn findCrossTenantLinks(alloc: std.mem.Allocator, conn: *db.Db, cols: []const schema.Collection) ![]const CrossTenantLinks {
    var out: std.ArrayList(CrossTenantLinks) = .empty;
    errdefer out.deinit(alloc);
    for (cols) |src| {
        const stf = src.options.tenant_field orelse continue;
        for (src.fields) |f| {
            if (f.options != .relation) continue;
            const target_ref = f.options.relation.targetCollectionId;
            const tgt = for (cols) |c| {
                if (std.mem.eql(u8, c.id, target_ref) or std.mem.eql(u8, c.name, target_ref)) break c;
            } else continue;
            const ttf = tgt.options.tenant_field orelse continue;
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const arena = scratch.allocator();
            const q: LinkQuery = .{
                .src = try ddl.quoteIdent(arena, src.name),
                .stf = try ddl.quoteIdent(arena, stf),
                .field = try ddl.quoteIdent(arena, f.name),
                .tgt = try ddl.quoteIdent(arena, tgt.name),
                .ttf = try ddl.quoteIdent(arena, ttf),
            };
            const multi = f.isMultiValue();
            var st = try conn.prepare(if (multi) try q.multiSql(arena, db.dbBackend(conn)) else try q.singleSql(arena));
            defer st.finalize();
            if (!try st.step()) continue;
            const n: usize = @intCast(st.columnInt(0));
            const bad: usize = if (multi) @intCast(st.columnInt(1)) else 0;
            while (try st.step()) {} // drain to DONE (one aggregate row)
            if (n > 0 or bad > 0) try out.append(alloc, .{ .collection = src.name, .field = f.name, .target = tgt.name, .count = n, .unparseable = bad });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The quoted identifiers of one (source field -> target) pair. `s`/`t` aliases keep a
/// self-relation (source == target) comparing two distinct rows.
const LinkQuery = struct {
    src: []const u8,
    stf: []const u8,
    field: []const u8,
    tgt: []const u8,
    ttf: []const u8,

    /// Both rows owned (non-NULL, non-empty) and by different accounts.
    fn owners(self: LinkQuery, arena: std.mem.Allocator) ![]const u8 {
        return arena.print("s.{s} <> '' AND t.{s} <> '' AND s.{s} <> t.{s}", .{ self.stf, self.ttf, self.stf, self.ttf });
    }

    fn singleSql(self: LinkQuery, arena: std.mem.Allocator) ![:0]const u8 {
        return arena.printSentinel("SELECT COUNT(*) FROM {s} AS s JOIN {s} AS t ON t.\"id\" = s.{s} WHERE {s};", .{
            self.src, self.tgt, self.field, try self.owners(arena),
        }, 0);
    }

    fn multiSql(self: LinkQuery, arena: std.mem.Allocator, backend: db.Backend) ![:0]const u8 {
        return switch (backend) {
            // Aggregate each row's links before summing so array length cannot multiply the
            // unparseable count. CASE is lazy: json_type only sees valid JSON.
            .sqlite => arena.printSentinel("SELECT COALESCE(SUM((SELECT COUNT(*) FROM json_each(CASE WHEN json_valid(s.{s}) THEN CASE json_type(s.{s}) WHEN 'array' THEN s.{s} END END) AS j JOIN {s} AS t ON t.\"id\" = j.value WHERE j.type = 'text' AND {s})), 0), COALESCE(SUM(CASE WHEN s.{s} IS NOT NULL AND s.{s} <> '' AND NOT (CASE WHEN json_valid(s.{s}) THEN json_type(s.{s}) = 'array' ELSE 0 END) THEN 1 ELSE 0 END), 0) FROM {s} AS s;", .{
                self.field, self.field, self.field, self.tgt, try self.owners(arena), self.field, self.field, self.field, self.field, self.src,
            }, 0),
            // No portable "is valid JSON" before PostgreSQL 16: only a value that looks like an
            // array is cast (see `findCrossTenantLinks` for what a malformed one does).
            .postgres => arena.printSentinel("SELECT COALESCE(SUM((SELECT COUNT(*) FROM jsonb_array_elements(CASE WHEN s.{s} ~ '^\\s*\\[' THEN s.{s}::jsonb ELSE '[]'::jsonb END) AS j(v) JOIN {s} AS t ON t.\"id\" = (j.v #>> '{{}}') WHERE jsonb_typeof(j.v) = 'string' AND {s})), 0), COALESCE(SUM(CASE WHEN s.{s} IS NOT NULL AND s.{s} <> '' AND s.{s} !~ '^\\s*\\[' THEN 1 ELSE 0 END), 0) FROM {s} AS s;", .{
                self.field, self.field, self.tgt, try self.owners(arena), self.field, self.field, self.field, self.src,
            }, 0),
        };
    }
};

// ---- Tests ------------------------------------------------------------------

const migrations = @import("../migrations.zig");

test "scopePredicate: null unless enabled + tenant-owned + non-superuser" {
    const a = std.testing.allocator;
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
        defer a.free(sp.sql);
        try std.testing.expectEqualStrings("\"posts\".\"account\" = ?", sp.sql);
        try std.testing.expectEqualStrings("acc1", sp.param.text);
    }
}

test "scopeApplies/scopePredicate never fall open on a name the charset gate rejects" {
    // F18's documented residual. `scopeApplies` used to end in
    // `… and isValidIdentifier(col.name) and isValidIdentifier(tf)`, so a tenant-owned collection
    // whose name the charset gate rejects reported "tenant scoping does not apply" — dropping BOTH
    // the forced per-row check (policy.decide) and the bound predicate, and serving the collection
    // un-scoped across every tenant. `_`-prefixed system collections are exactly the names that
    // gate rejects, so the residual had a second route into it beyond a bad `tenant_field`.
    // Tenant-ownership is now decided by the schema alone; the identifier is ESCAPED, not gated.
    const a = std.testing.allocator;
    const fields = [_]schema.Field{.{ .id = "f1", .name = "account", .options = .{ .text = .{} } }};
    const col = schema.Collection{
        .id = "_tenantprobe__",
        .name = "_tenantprobe",
        .system = true,
        .fields = &fields,
        .options = .{ .tenant_field = "account" },
    };
    const rctx = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };

    // The collection IS tenant-owned: scoping applies, so policy.decide still forces a per-row check.
    try std.testing.expect(scopeApplies(col, &rctx));
    const sp = (try scopePredicate(a, col, &rctx)).?;
    defer a.free(sp.sql);
    try std.testing.expectEqualStrings("\"_tenantprobe\".\"account\" = ?", sp.sql);
    try std.testing.expectEqualStrings("acc1", sp.param.text);

    // The bypasses that SHOULD suppress scoping still do — this must not become "always applies".
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    try std.testing.expect(!scopeApplies(col, &su));
    const xt = request.RequestContext{ .tenancy_enabled = true, .cross_tenant = true, .account_id = "acc1" };
    try std.testing.expect(!scopeApplies(col, &xt));
    const off = request.RequestContext{ .tenancy_enabled = false, .account_id = "acc1" };
    try std.testing.expect(!scopeApplies(col, &off));
}

test "scopePredicate escapes an embedded quote instead of emitting it raw" {
    // Escaping is what replaced the charset gate, so pin that it actually escapes: a `"` in an
    // identifier must be doubled, never passed through to close the quoted identifier early.
    const a = std.testing.allocator;
    const fields = [_]schema.Field{.{ .id = "f1", .name = "ac\"ct", .options = .{ .text = .{} } }};
    const col = schema.Collection{ .id = "c", .name = "po\"sts", .fields = &fields, .options = .{ .tenant_field = "ac\"ct" } };
    const rctx = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const sp = (try scopePredicate(a, col, &rctx)).?;
    defer a.free(sp.sql);
    try std.testing.expectEqualStrings("\"po\"\"sts\".\"ac\"\"ct\" = ?", sp.sql);
}

test "resolve: only active memberships; requested account must be a member" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES " ++
        "('m1','','','acc1','users','u1','owner','active')," ++
        "('m2','','','acc2','users','u1','viewer','active')," ++
        "('m3','','','acc3','users','u1','admin','invited');");

    // Requested an account the user actively belongs to.
    const r1 = try resolve(a, &d, "users", "u1", "acc2");
    defer r1.deinit(a);
    try std.testing.expectEqualStrings("acc2", r1.account_id);
    try std.testing.expectEqualStrings("viewer", r1.account_role);
    try std.testing.expectEqual(@as(usize, 2), r1.memberships.len); // only the 2 active

    // Requested an account whose membership is not active -> no active scope (fail closed).
    const r2 = try resolve(a, &d, "users", "u1", "acc3");
    defer r2.deinit(a);
    try std.testing.expectEqualStrings("", r2.account_id);
    try std.testing.expectEqual(@as(usize, 2), r2.memberships.len);

    // No requested account -> membership list still populated, no active scope.
    const r3 = try resolve(a, &d, "users", "u1", "");
    defer r3.deinit(a);
    try std.testing.expectEqualStrings("", r3.account_id);
    try std.testing.expectEqual(@as(usize, 2), r3.memberships.len);

    // Unknown user -> empty.
    const r4 = try resolve(a, &d, "users", "ghost", "acc1");
    defer r4.deinit(a);
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
        const cookie_hdr = try std.testing.allocator.print("{s}={s}", .{ account_cookie, signed });
        defer std.testing.allocator.free(cookie_hdr);
        ctx.cookie_header = cookie_hdr;
        try std.testing.expectEqualStrings("acc-header", requestedAccount(&ctx, &app).?);
    }
    // No header, valid signed cookie -> the cookie's account.
    {
        const signed = try signAccount(std.testing.allocator, app.jwt_secret, "acc-cookie");
        defer std.testing.allocator.free(signed);
        const cookie_hdr = try std.testing.allocator.print("{s}={s}", .{ account_cookie, signed });
        defer std.testing.allocator.free(cookie_hdr);
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.forTest(std.testing.allocator), .cookie_header = cookie_hdr };
        try std.testing.expectEqualStrings("acc-cookie", requestedAccount(&ctx, &app).?);
    }
    // No header, tampered cookie (wrong secret's signature) -> null (fail closed, not the forged id).
    {
        const forged = try signAccount(std.testing.allocator, "wrong-secret", "acc-evil");
        defer std.testing.allocator.free(forged);
        const cookie_hdr = try std.testing.allocator.print("{s}={s}", .{ account_cookie, forged });
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
        const a = auth.Authed.borrowed(authed_record, "profiles", false);
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
        const a = auth.Authed.borrowed(authed_record, "profiles", true);
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expect(rctx.tenancy_enabled);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }

    // Non-superuser, requested account is an ACTIVE membership -> scope granted.
    {
        var hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "acc1" }};
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena), .headers = &hdrs };
        var rctx = request.RequestContext{};
        const a = auth.Authed.borrowed(authed_record, "profiles", false);
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
        const a = auth.Authed.borrowed(authed_record, "profiles", false);
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }

    // No header/cookie at all -> no active scope (unresolved, fail closed).
    {
        var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = RequestArena.from(&arena) };
        var rctx = request.RequestContext{};
        const a = auth.Authed.borrowed(authed_record, "profiles", false);
        resolveRequest(&ctx, &d, &app, a, &rctx);
        try std.testing.expectEqualStrings("", rctx.account_id);
    }
}

test "signAccount/verifyAccount round-trip; tamper fails closed" {
    const a = std.testing.allocator;
    const secret = "app-jwt-secret";
    const signed = try signAccount(a, secret, "acc-123");
    defer a.free(signed);
    try std.testing.expectEqualStrings("acc-123", verifyAccount(secret, signed).?);
    // Wrong secret -> null.
    try std.testing.expect(verifyAccount("other", signed) == null);
    // Tampered account id -> null (MAC no longer matches).
    const tampered = try a.print("acc-999.{s}", .{signed[std.mem.lastIndexOfScalar(u8, signed, '.').? + 1 ..]});
    defer a.free(tampered);
    try std.testing.expect(verifyAccount(secret, tampered) == null);
    // Malformed (no dot) -> null.
    try std.testing.expect(verifyAccount(secret, "nodothere") == null);
}

test "PostgreSQL membership resolution uses bound parameters inside a transaction" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var conn = try db.Db.openPostgres(a, std.testing.io, url);
    defer conn.close();
    const token = try @import("../crypto.zig").genHex(std.testing.io, a, 24);
    defer a.free(token);
    const create = try a.printSentinel("CREATE SCHEMA tenant_retry_{s};", .{token}, 0);
    defer a.free(create);
    const drop = try a.printSentinel("DROP SCHEMA tenant_retry_{s} CASCADE;", .{token}, 0);
    defer a.free(drop);
    const path = try a.printSentinel("SET search_path TO tenant_retry_{s};", .{token}, 0);
    defer a.free(path);
    try conn.exec(create);
    defer conn.exec(drop) catch |err| std.log.err("tenant resolution test schema cleanup failed: {s}", .{@errorName(err)});
    try conn.exec(path);
    try conn.exec("CREATE TABLE _memberships (account TEXT NOT NULL, user_collection TEXT NOT NULL, \"user\" TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL);");
    try conn.exec("INSERT INTO _memberships VALUES ('account-a','users','user-a','owner','active'),('account-b','users','user-a','viewer','invited'),('account-c','other-users','user-a','owner','active');");
    try conn.beginImmediate();
    defer if (conn.inTransaction()) conn.rollback() catch |err| std.log.err("tenant resolution test rollback failed: {s}", .{@errorName(err)});
    const active = try resolve(a, &conn, "users", "user-a", "account-a");
    defer active.deinit(a);
    try std.testing.expectEqualStrings("account-a", active.account_id);
    try std.testing.expectEqualStrings("owner", active.account_role);
    try std.testing.expectEqual(@as(usize, 1), active.memberships.len);
    const invited = try resolve(a, &conn, "users", "user-a", "account-b");
    defer invited.deinit(a);
    try std.testing.expectEqualStrings("", invited.account_id);
    try conn.exec("UPDATE _memberships SET status='suspended' WHERE user_collection='users';");
    const revoked = try resolve(a, &conn, "users", "user-a", "account-a");
    defer revoked.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), revoked.memberships.len);
    try std.testing.expectEqualStrings("", revoked.account_id);
    try conn.rollback();
    const restored = try resolve(a, &conn, "users", "user-a", "account-a");
    defer restored.deinit(a);
    try std.testing.expectEqualStrings("account-a", restored.account_id);
}

fn resolveAllocationProbe(alloc: std.mem.Allocator, conn: *db.Db) !void {
    const res = try resolve(alloc, conn, "users", "u1", "acc1");
    defer res.deinit(alloc);
    try std.testing.expectEqualStrings("editor", res.account_role);
    try std.testing.expectEqual(@as(usize, 2), res.memberships.len);
}

test "resolve frees partial memberships on every allocation failure" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE _memberships (account TEXT, role TEXT, user_collection TEXT, user TEXT, status TEXT);");
    try conn.exec("INSERT INTO _memberships VALUES ('acc1','editor','users','u1','active'),('acc2','viewer','users','u1','active');");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, resolveAllocationProbe, .{&conn});
}

const collections_mod = @import("../collections.zig");
const records_mod = @import("../records.zig");
const codes_mod = @import("../error_codes.zig");

fn linkFor(found: []const CrossTenantLinks, collection: []const u8, field: []const u8) ?CrossTenantLinks {
    for (found) |l| if (std.mem.eql(u8, l.collection, collection) and std.mem.eql(u8, l.field, field)) return l;
    return null;
}

/// Shared SQLite + PostgreSQL body for #497: `findCrossTenantLinks` counts exactly the stored
/// cross-tenant links (single + multi, a self-relation, a target named by collection NAME; rows
/// whose tenant value is NULL or '', dangling multi ids, non-string array items and non-tenant
/// sources excluded) and counts multi values that are not a JSON array, and a scoped relation
/// write refuses another account's id as `validation_not_found` on this backend.
/// The audit result is flat and freed independently of query scratch.
fn exerciseCrossTenantLinks(gpa: std.mem.Allocator, conn: *db.Db) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try migrations.run(conn);
    const notes = try collections_mod.create(arena, std.testing.io, conn, .{
        .id = "",
        .name = "notes",
        .fields = &[_]schema.Field{
            .{ .id = "n1", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "n2", .name = "account", .options = .{ .text = .{} } },
            // Self-relation, its target given by collection NAME (as `collections.get` accepts).
            .{ .id = "n3", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "notes", .maxSelect = 1 } } },
        },
        .options = .{ .tenant_field = "account" },
    });
    const tasks = try collections_mod.create(arena, std.testing.io, conn, .{ .id = "", .name = "tasks", .fields = &[_]schema.Field{
        .{ .id = "t1", .name = "account", .options = .{ .text = .{} } },
        .{ .id = "t2", .name = "note", .options = .{ .relation = .{ .targetCollectionId = notes.id, .maxSelect = 1 } } },
        .{ .id = "t3", .name = "notes", .options = .{ .relation = .{ .targetCollectionId = notes.id, .maxSelect = 5 } } },
    }, .options = .{ .tenant_field = "account" } });
    _ = try collections_mod.create(arena, std.testing.io, conn, .{ .id = "", .name = "shared", .fields = &[_]schema.Field{
        .{ .id = "s1", .name = "note", .options = .{ .relation = .{ .targetCollectionId = notes.id, .maxSelect = 1 } } },
    } });
    try conn.exec("INSERT INTO notes (id,created,updated,title,account) VALUES ('na','t','t','a','acc1'),('nb','t','t','b','acc2');");
    try conn.exec("INSERT INTO notes (id,created,updated,title,account,parent) VALUES " ++
        "('nc','t','t','c','acc1','nb')," ++ // self-relation across accounts: counted
        "('nd','t','t','d','acc1','na')," ++ // self-relation, same account: not counted
        "('ne','t','t','e','','nb');"); // '' owner: no account to differ from
    try conn.exec("INSERT INTO tasks (id,created,updated,account,note,notes) VALUES " ++
        "('t1','t','t','acc1','na','[\"na\"]')," ++ // same account: not counted
        "('t2','t','t','acc1','nb','[\"na\",\"nb\"]')," ++ // cross: single + one multi id
        "('t3','t','t','acc2','na',NULL)," ++ // cross: single
        "('t4','t','t',NULL,'nb','[\"nb\"]')," ++ // un-owned row: no account to differ from
        "('t5','t','t','acc1','ne','[\"ghost\",\"nb\"]')," ++ // '' target owner: no; dangling id: no; nb: counted
        "('t6','t','t','','nb','not-json')," ++ // '' source owner: no; unparseable multi value
        "('t7','t','t','acc1',NULL,'{\"a\":1}')," ++ // a JSON value that is not an array: unparseable
        "('t8','t','t','acc1',NULL,'')," ++ // empty: no value, not unparseable
        "('t9','t','t','acc1',NULL,'[1,\"nb\"]');"); // non-string item ignored; nb: counted
    try conn.exec("INSERT INTO shared (id,created,updated,note) VALUES ('s1','t','t','nb');"); // not tenant-owned

    const cols = try collections_mod.list(arena, conn);
    try std.testing.checkAllAllocationFailures(gpa, checkCrossTenantLinkAllocations, .{ conn, cols });
    const found = try findCrossTenantLinks(gpa, conn, cols);
    defer gpa.free(found);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    const single = linkFor(found, "tasks", "note") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("notes", single.target);
    try std.testing.expectEqual(@as(usize, 2), single.count);
    try std.testing.expectEqual(@as(usize, 0), single.unparseable);
    const multi = linkFor(found, "tasks", "notes") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), multi.count);
    try std.testing.expectEqual(@as(usize, 2), multi.unparseable);
    // Both backends must return both counts from the same prepared statement.
    const q: LinkQuery = .{ .src = "\"tasks\"", .stf = "\"account\"", .field = "\"notes\"", .tgt = "\"notes\"", .ttf = "\"account\"" };
    var aggregate = try conn.prepare(try q.multiSql(arena, db.dbBackend(conn)));
    defer aggregate.finalize();
    try std.testing.expect(try aggregate.step());
    try std.testing.expectEqual(@as(i64, 3), aggregate.columnInt(0));
    try std.testing.expectEqual(@as(i64, 2), aggregate.columnInt(1));
    try std.testing.expect(!try aggregate.step());
    try conn.exec("DELETE FROM tasks;");
    var empty = try conn.prepare(try q.multiSql(arena, db.dbBackend(conn)));
    defer empty.finalize();
    try std.testing.expect(try empty.step());
    try std.testing.expectEqual(@as(i64, 0), empty.columnInt(0));
    try std.testing.expectEqual(@as(i64, 0), empty.columnInt(1));
    try std.testing.expect(!try empty.step());
    const self = linkFor(found, "notes", "parent") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("notes", self.target);
    try std.testing.expectEqual(@as(usize, 1), self.count);

    // The scoped relation check on this backend: another account's id is refused like a missing one.
    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    var data: std.json.ObjectMap = .empty;
    try data.put(arena, "note", .{ .string = "nb" });
    try std.testing.expectError(error.Validation, records_mod.createInTxnOpts(arena, std.testing.io, conn, tasks, .{ .object = data }, .{ .relation_scope = &member }));
    const errs = records_mod.last_errors orelse return error.TestExpectedEqual;
    records_mod.last_errors = null; // arena-owned; freed with the arena
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(codes_mod.s(.validation_not_found), errs[0].code);
    try data.put(arena, "note", .{ .string = "na" });
    _ = try records_mod.createInTxnOpts(arena, std.testing.io, conn, tasks, .{ .object = data }, .{ .relation_scope = &member });
}

fn checkCrossTenantLinkAllocations(a: std.mem.Allocator, conn: *db.Db, cols: []const schema.Collection) !void {
    const found = try findCrossTenantLinks(a, conn, cols);
    defer a.free(found);
    try std.testing.expectEqual(@as(usize, 3), found.len);
}

test "findCrossTenantLinks + scoped relation check on SQLite (#497)" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try exerciseCrossTenantLinks(std.testing.allocator, &conn);
}

test "findCrossTenantLinks + scoped relation check on PostgreSQL (#497)" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var conn = try db.Db.openPostgres(a, std.testing.io, url);
    defer conn.close();
    const token = try @import("../crypto.zig").genHex(std.testing.io, a, 24);
    defer a.free(token);
    const create = try a.printSentinel("CREATE SCHEMA tenant_links_{s};", .{token}, 0);
    defer a.free(create);
    const drop = try a.printSentinel("DROP SCHEMA tenant_links_{s} CASCADE;", .{token}, 0);
    defer a.free(drop);
    const path = try a.printSentinel("SET search_path TO tenant_links_{s};", .{token}, 0);
    defer a.free(path);
    try conn.exec(create);
    defer conn.exec(drop) catch |err| std.log.err("tenant links test schema cleanup failed: {s}", .{@errorName(err)});
    try conn.exec(path);
    try exerciseCrossTenantLinks(a, &conn);
}
