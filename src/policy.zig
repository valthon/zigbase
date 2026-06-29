const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const rules = @import("rules.zig");
const tenancy = @import("tenancy/tenancy.zig");
const compiler = @import("query/compiler.zig");

// Authorization COMPOSITION layer (foundation for #156 multi-tenancy + #155 row-level authz).
//
// `rules.zig` is the unchanged primitive: it turns a single access-rule expression into a
// Decision (locked / allow / per-record check) and compiles a `check`-state rule into a guarded
// WHERE fragment. Every enforcement chokepoint (REST list/view/create/update/delete, realtime
// delivery, subscribe-authorization) calls THROUGH this layer instead of `rules.*` directly, so a
// later PR can AND additional predicates (an ability clause, a tenant-scope clause) into the same
// guard at ONE place without touching the chokepoints again.
//
// PR1 FOUNDATION: there are no abilities and no tenancy yet, so every function here delegates to
// `rules.*` with BYTE-IDENTICAL behavior — the composition is a pass-through. The pin tests at the
// bottom assert that identity for a plain (non-tenant, non-ability) collection; they are the
// safety net for the chokepoint refactor and the regression guard for PR2/PR3.

/// The CRUD/list operations a policy decision is made for. Maps each action to its collection rule.
pub const Action = enum { list, view, create, update, delete };

/// Three-state outcome of a policy decision (re-exported from the rules primitive):
/// `deny_locked` (superuser-only), `allow` (no per-record check), `check` (evaluate a guard).
pub const Decision = rules.Decision;

/// A compiled, parameter-bound WHERE fragment + its joins, AND-able into a query. PR2/PR3 will
/// compose ability/tenant fragments into this same shape.
pub const Guard = records.Guard;

/// The error set a policy operation can fail with (identical to the rules primitive's).
pub const PolicyError = rules.RuleError;

/// `@public`-sentinel test, re-exported so subscribe-authorization (realtime) and any other
/// caller goes through the policy layer rather than reaching into `rules` directly.
pub const isPublic = rules.isPublic;

/// The access-rule expression governing `action` on `col` (null/"" = locked, "@public" = open).
pub fn ruleFor(col: schema.Collection, action: Action) ?[]const u8 {
    return switch (action) {
        .list => col.listRule,
        .view => col.viewRule,
        .create => col.createRule,
        .update => col.updateRule,
        .delete => col.deleteRule,
    };
}

/// The pure, per-collection authorization decision for `action`. Delegates to `rules.decide` on
/// the action's rule, then composes tenancy:
///   - `deny_locked` SHORT-CIRCUITS FIRST (the fail-closed floor — locked beats everything).
///   - otherwise, if tenant scoping APPLIES to `col` for `rctx` (enabled + tenant-owned +
///     non-superuser), the decision is forced to `.check` so the chokepoint compiles+evaluates a
///     per-row guard (the bound `tenant_field = account_id` predicate) even when the access rule
///     alone would `allow`. A tenant-owned collection is thus NEVER served un-scoped.
///   - else the bare rule decision (byte-identical to pre-tenancy for a non-tenant collection).
pub fn decide(col: schema.Collection, action: Action, rctx: *const request.RequestContext) Decision {
    const base = rules.decide(ruleFor(col, action), rctx);
    if (base == .deny_locked) return .deny_locked;
    if (tenancy.scopeApplies(col, rctx)) return .check;
    return base;
}

/// AND the bound tenant-scope predicate `sp` into `guard` (null = no rule predicate yet). Combines
/// the WHERE fragments with `AND`, appends the single tenant param AFTER the guard's params (so the
/// trailing `?` binds last), and preserves the guard's joins. Allocations are on `alloc`.
fn andTenant(alloc: std.mem.Allocator, guard: ?Guard, sp: tenancy.Scoped) std.mem.Allocator.Error!Guard {
    if (guard) |g| {
        const where = try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ g.where_sql, sp.sql });
        const params = try alloc.alloc(compiler.Param, g.params.len + 1);
        @memcpy(params[0..g.params.len], g.params);
        params[g.params.len] = sp.param;
        return .{ .where_sql = where, .joins = g.joins, .params = params };
    }
    const params = try alloc.alloc(compiler.Param, 1);
    params[0] = sp.param;
    return .{ .where_sql = sp.sql, .params = params };
}

/// Compile the composed predicate for `action` into a `Guard`, or null when no predicate applies
/// (the `allow` state — superuser/@public). A `deny_locked` state yields a constant-false guard so
/// AND-ing it denies every row (fail-closed). PR1: the only contributing predicate is the access
/// rule, so a `check`-state rule compiles byte-identically to `rules.compileGuard`.
///
/// Callers that already branched on `decide()` (create/update) invoke this only in the `check`
/// state and unwrap the non-null guard; the `allow`/`deny_locked` arms exist for completeness and
/// for future composition where the decision and predicate are computed together.
pub fn compilePredicate(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, action: Action, rctx: *const request.RequestContext) PolicyError!?Guard {
    const rule = ruleFor(col, action);
    const base = rules.decide(rule, rctx);
    if (base == .deny_locked) return Guard{ .where_sql = "0" }; // fail-closed: AND-ing denies all rows
    // The access-rule predicate (null for `allow`; the compiled guard for `check`).
    var guard: ?Guard = if (base == .check) try rules.compileGuard(alloc, conn, col, rule.?, rctx) else null;
    // Compose the tenant-scope predicate when it applies (null is a no-op → byte-identical to the
    // pre-tenancy guard for a non-tenant collection / no-tenancy app).
    if (try tenancy.scopePredicate(alloc, col, rctx)) |sp| guard = try andTenant(alloc, guard, sp);
    return guard;
}

/// Whether `record_id` is authorized for `action` under the composed policy. PR1: `allow` → true,
/// `deny_locked` → false, `check` → `rules.matches` (a guarded `SELECT 1`). Byte-identical to the
/// inline `decide` + `rules.matches` the chokepoints used before.
pub fn authorizes(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, action: Action, record_id: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    // Route through compilePredicate so the SAME composition (rule AND tenant-scope) governs the
    // single-record check that governs list. A null predicate is the `allow` state (true); the
    // constant-false `"0"` guard is `deny_locked` (false); anything else is a guarded SELECT 1.
    const guard = (try compilePredicate(alloc, conn, col, action, rctx)) orelse return true;
    if (std.mem.eql(u8, guard.where_sql, "0")) return false;
    return records.guardPasses(alloc, conn, col, record_id, guard);
}

/// Evaluate an ARBITRARY combined rule expression against `record_id` (a guarded `SELECT 1`).
/// Used by realtime delivery, which AND-s a collection's viewRule with a subscription filter into
/// one expression that is not a single action rule. A thin pass-through to the rules primitive so
/// realtime authz also funnels through the policy layer (the seam PR5 composes into).
pub fn matchesRule(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, record_id: []const u8, rule: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    // An EMPTY `rule` contributes no rule-clause — the realtime hub passes "" when a tenant-owned
    // collection's viewRule is `@public`/`allow` (no expression to compile) but the tenant scope
    // must still constrain delivery. A non-empty rule compiles to a guard as before.
    var guard: ?Guard = if (rule.len > 0) try rules.compileGuard(alloc, conn, col, rule, rctx) else null;
    // Realtime delivery on a tenant-owned collection is scoped to the subscriber's active account
    // too (the composition funnels through this one place). Null = no-op (byte-identical to the
    // prior `rules.matches` for a non-tenant collection / no-tenancy app).
    if (try tenancy.scopePredicate(alloc, col, rctx)) |sp| guard = try andTenant(alloc, guard, sp);
    // No rule clause AND no tenant scope => unconstrained (deliver). Otherwise run the guarded SELECT 1.
    const g = guard orelse return true;
    return records.guardPasses(alloc, conn, col, record_id, g);
}

// ---- Back-compat PIN tests --------------------------------------------------
// These assert that, for a PLAIN collection (no tenancy / no abilities), routing authorization
// through `policy.*` yields the IDENTICAL compiled SQL and the IDENTICAL allow/deny decisions as
// the pre-refactor `rules.*` calls did. They are the safety net for the chokepoint refactor and
// will catch any future composition that accidentally changes the no-tenancy/no-ability baseline.

const migrations = @import("migrations.zig");
const collections = @import("collections.zig");

/// Create the one backing `posts` table for the pin tests.
fn pinBase(a: std.mem.Allocator, d: *db.Db) !schema.Collection {
    try migrations.run(d);
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "owner", .options = .{ .text = .{} } },
    } });
}

/// A copy of `col` with the SAME rule on every action, so each action's parity is checkable.
fn withRule(col: schema.Collection, rule: ?[]const u8) schema.Collection {
    var c = col;
    c.listRule = rule;
    c.viewRule = rule;
    c.createRule = rule;
    c.updateRule = rule;
    c.deleteRule = rule;
    return c;
}

test "PIN: policy.decide matches rules.decide for every action and rule state" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try pinBase(a, &d);
    const states = [_]?[]const u8{ null, "", "@public", "owner = @request.auth.id" };
    const ctxs = [_]request.RequestContext{ .{}, .{ .is_superuser = true } };
    for (states) |rule| {
        const col = withRule(base, rule);
        for (ctxs) |rctx| {
            inline for (.{ .list, .view, .create, .update, .delete }) |action| {
                try std.testing.expectEqual(rules.decide(rule, &rctx), decide(col, action, &rctx));
            }
        }
    }
}

test "PIN: policy.compilePredicate byte-identical to rules.compileGuard for a check rule" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try pinBase(a, &d);
    const rule = "owner = @request.auth.id";
    const col = withRule(base, rule);
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };

    const want = try rules.compileGuard(a, &d, col, rule, &rctx);
    const got = (try compilePredicate(a, &d, col, .update, &rctx)).?;
    try std.testing.expectEqualStrings(want.where_sql, got.where_sql);
    try std.testing.expectEqual(want.params.len, got.params.len);
    for (want.params, got.params) |w, g| try std.testing.expectEqualStrings(w.text, g.text);

    // allow state -> null predicate; locked state -> constant-false guard.
    try std.testing.expect((try compilePredicate(a, &d, withRule(base, "@public"), .update, &rctx)) == null);
    try std.testing.expectEqualStrings("0", (try compilePredicate(a, &d, withRule(base, null), .update, &rctx)).?.where_sql);
}

test "PIN: policy.authorizes matches rules decide+matches for allow/deny/check" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try pinBase(a, &d);
    const col = withRule(base, "owner = @request.auth.id");
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','u1');");
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const owner = request.RequestContext{ .auth = .{ .object = auth } };
    const su = request.RequestContext{ .is_superuser = true };
    const anon = request.RequestContext{};

    // check state: owner matches, stranger does not — identical to rules.matches.
    try std.testing.expectEqual(try rules.matches(a, &d, col, "r1", col.viewRule.?, &owner), try authorizes(a, &d, col, .view, "r1", &owner));
    try std.testing.expect(try authorizes(a, &d, col, .view, "r1", &owner));
    var stranger: std.json.ObjectMap = .empty;
    try stranger.put(a, "id", .{ .string = "u2" });
    const other = request.RequestContext{ .auth = .{ .object = stranger } };
    try std.testing.expect(!try authorizes(a, &d, col, .view, "r1", &other));

    // allow (superuser) -> true without a query; locked (anon) -> false.
    try std.testing.expect(try authorizes(a, &d, col, .delete, "r1", &su));
    try std.testing.expect(!try authorizes(a, &d, withRule(base, null), .delete, "r1", &anon));
}

// ---- Tenancy composition tests (#156) --------------------------------------

// THE CRITICAL BACK-COMPAT GUARANTEE: turning tenancy ON app-wide must NOT change the decision or
// the compiled SQL for a collection that is NOT tenant-owned (no `tenant_field`). The pin compares
// a `tenancy_enabled = true` context against the `false` baseline for every action/rule state on a
// plain collection and asserts byte-identical results.
test "PIN: tenancy enabled but no tenant_field is byte-identical to no-tenancy" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try pinBase(a, &d); // posts: NO tenant_field
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','u1');");
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const states = [_]?[]const u8{ null, "", "@public", "owner = @request.auth.id" };
    for (states) |rule| {
        const col = withRule(base, rule);
        // Same principal, one with tenancy off, one with tenancy on + an active account scope.
        const off = request.RequestContext{ .auth = .{ .object = auth }, .tenancy_enabled = false, .account_id = "acc1" };
        const on = request.RequestContext{ .auth = .{ .object = auth }, .tenancy_enabled = true, .account_id = "acc1" };
        inline for (.{ .list, .view, .create, .update, .delete }) |action| {
            // Decision identical.
            try std.testing.expectEqual(decide(col, action, &off), decide(col, action, &on));
            // Compiled predicate identical (where_sql + params).
            const g_off = try compilePredicate(a, &d, col, action, &off);
            const g_on = try compilePredicate(a, &d, col, action, &on);
            try std.testing.expectEqual(g_off == null, g_on == null);
            if (g_off) |go| {
                try std.testing.expectEqualStrings(go.where_sql, g_on.?.where_sql);
                try std.testing.expectEqual(go.params.len, g_on.?.params.len);
            }
            // authorizes identical.
            try std.testing.expectEqual(
                try authorizes(a, &d, col, action, "r1", &off),
                try authorizes(a, &d, col, action, "r1", &on),
            );
        }
    }
}

// A TENANT-OWNED collection: tenancy forces a per-row `.check` (even for an `@public` rule) and
// composes the bound `tenant_field = account_id` predicate; a superuser bypasses scoping.
test "tenant-owned collection: decide forces check + compilePredicate binds the account scope" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = try pinBase(a, &d); // posts(title, owner)
    base.options.tenant_field = "owner"; // owning-account column

    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    const xt = request.RequestContext{ .tenancy_enabled = true, .cross_tenant = true, .account_id = "acc1" };

    // @public would normally `allow`; tenancy forces `.check` so the row is scoped.
    const pub_col = withRule(base, "@public");
    try std.testing.expectEqual(Decision.check, decide(pub_col, .list, &member));
    const g = (try compilePredicate(a, &d, pub_col, .list, &member)).?;
    try std.testing.expectEqualStrings("\"posts\".\"owner\" = ?", g.where_sql);
    try std.testing.expectEqual(@as(usize, 1), g.params.len);
    try std.testing.expectEqualStrings("acc1", g.params[0].text);

    // Superuser + crossTenant bypass scoping entirely (decision falls back to the rule => allow).
    try std.testing.expectEqual(Decision.allow, decide(pub_col, .list, &su));
    try std.testing.expect((try compilePredicate(a, &d, pub_col, .list, &su)) == null);
    try std.testing.expectEqual(Decision.allow, decide(pub_col, .list, &xt));
    try std.testing.expect((try compilePredicate(a, &d, pub_col, .list, &xt)) == null);

    // A locked rule STILL short-circuits to deny before tenancy (fail-closed floor preserved).
    const locked = withRule(base, null);
    try std.testing.expectEqual(Decision.deny_locked, decide(locked, .list, &member));
    try std.testing.expectEqualStrings("0", (try compilePredicate(a, &d, locked, .list, &member)).?.where_sql);

    // A `check` rule ANDs with the tenant predicate (both fragments present).
    const owned = withRule(base, "title = \"x\"");
    const g2 = (try compilePredicate(a, &d, owned, .update, &member)).?;
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, "\"posts\".\"owner\" = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, ") AND (") != null);
}
