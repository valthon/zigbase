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
const schema = @import("../schema.zig");
const request = @import("../request.zig");
const compiler = @import("../query/compiler.zig");
const db = @import("../db.zig");
const crypto = @import("../crypto.zig");

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
    var st = try conn.prepare(
        "SELECT \"account\",\"role\" FROM \"_memberships\" WHERE \"user_collection\"=?1 AND \"user\"=?2 AND \"status\"=?3;",
    );
    defer st.finalize();
    try st.bindText(1, user_collection);
    try st.bindText(2, user_id);
    try st.bindText(3, active_status);
    while (try st.step()) {
        if (list.items.len >= max_memberships) break;
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
