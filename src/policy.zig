const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const rules = @import("rules.zig");
const tenancy = @import("tenancy/tenancy.zig");
const abilities = @import("authz/abilities.zig");
const compiler = @import("query/compiler.zig");
const fts = @import("search/fts.zig");

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

/// The ability rule governing `action` on `col` (null when none configured). `list` reuses the
/// `view` ability — a list is a filtered set of viewable rows (#155).
pub fn abilityFor(col: schema.Collection, action: Action) ?abilities.Ability {
    const ab = col.options.abilities orelse return null;
    return switch (action) {
        .list, .view => ab.view,
        .create => ab.create,
        .update => ab.update,
        .delete => ab.delete,
    };
}

/// True iff a per-ROW predicate — a tenant scope OR a relationship ability — constrains
/// `action` on `col` for `rctx`, i.e. even an `allow`/`@public` access rule must still run the
/// guarded query to narrow which rows are visible. This is the SAME condition that forces
/// `decide` to `.check` (below). The realtime hub uses it to decide whether an `@public`-rule
/// delivery may short-circuit: deriving it here — rather than re-checking only tenancy at the
/// delivery site — is what keeps realtime from diverging from `decide`'s tenant+ability
/// composition (the gap that let abilities be enforced on `records.list` but skipped on
/// realtime delivery).
pub fn rowConstrained(col: schema.Collection, action: Action, rctx: *const request.RequestContext) bool {
    return abilities.abilityApplies(abilityFor(col, action), rctx) or tenancy.scopeApplies(col, rctx);
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
    // An ability rule forces a per-row check even when the access rule alone would `allow`, so an
    // ability-guarded collection is never served unchecked (#155).
    if (abilities.abilityApplies(abilityFor(col, action), rctx)) return .check;
    if (tenancy.scopeApplies(col, rctx)) return .check;
    return base;
}

/// AND a bound predicate fragment (`sql` + its `extra` params) into `guard` (null = no rule
/// predicate yet). Combines the WHERE fragments with `AND`, appends `extra` AFTER the guard's
/// params (so the trailing `?`s bind last), and preserves the guard's joins. Used to compose both
/// the ability predicate (#155) and the tenant-scope predicate (#156) onto the access-rule guard.
/// Allocations are on `alloc`.
fn andPredicate(alloc: std.mem.Allocator, guard: ?Guard, sql: []const u8, extra: []const compiler.Param) std.mem.Allocator.Error!Guard {
    if (guard) |g| {
        const where = try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ g.where_sql, sql });
        const params = try alloc.alloc(compiler.Param, g.params.len + extra.len);
        @memcpy(params[0..g.params.len], g.params);
        @memcpy(params[g.params.len..], extra);
        return .{ .where_sql = where, .joins = g.joins, .params = params };
    }
    if (extra.len == 0) return .{ .where_sql = sql }; // e.g. the constant-false "0" fragment
    return .{ .where_sql = sql, .params = try alloc.dupe(compiler.Param, extra) };
}

/// The list rule expression to compose as a FILTER in the list read-path, or null when none
/// applies. The list handler can't reuse `compilePredicate` (the list/cursor engine rolls its own
/// composition), so this mirrors `compilePredicate`'s rule arm for the list path: a rule is returned
/// ONLY when it is ITSELF a `.check` expression. An allow/`@public`/locked rule — or a `.check`
/// forced purely by an ability or the tenant scope — yields null, so the handler never feeds a
/// non-filter sentinel like `@public` to the filter compiler (which would 400). The ability and
/// tenant predicates are composed INSIDE `records.list` independently of this. (#155)
pub fn listRuleFilter(col: schema.Collection, rctx: *const request.RequestContext) ?[]const u8 {
    if (rules.decide(col.listRule, rctx) == .check) return col.listRule;
    return null;
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
    if (base == .deny_locked) return try Guard.own(alloc, "0", &.{}, &.{}); // fail-closed: AND-ing denies all rows
    // Compose the whole predicate on a function-local scratch arena, then deep-clone the FINAL Guard
    // onto `alloc` (via `Guard.own`) so the escaping graph solely owns its bytes and aliases nothing:
    // not the joiner's scratch, not the borrowed ability/tenant param `.text` (which point into
    // `rctx`), and not a `dialect.constFalse()` literal. The intermediate composition churn dies with
    // the scratch. (In production `alloc` is a request arena, so this is a cheap extra copy reclaimed
    // at request end; correctness — a self-contained, `deinit`-able Guard — is the point, not perf.)
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // The access-rule predicate (null for `allow`; the compiled guard for `check`).
    var guard: ?Guard = if (base == .check) try rules.compileGuard(sa, conn, col, rule.?, rctx) else null;
    // Compose the ability predicate (#155), then the tenant-scope predicate (#156) — the order in
    // the brief: (rule) AND (ability) AND (tenant). Each is null when it does not apply, leaving the
    // composed SQL byte-identical to the pre-abilities/pre-tenancy guard (pinned below).
    if (try abilities.abilityPredicate(sa, col, abilityFor(col, action), rctx, db.dbDialect(conn))) |ap|
        guard = try andPredicate(sa, guard, ap.sql, ap.params);
    if (try tenancy.scopePredicate(sa, col, rctx)) |sp| guard = try andPredicate(sa, guard, sp.sql, &.{sp.param});
    const g = guard orelse return null;
    return try Guard.own(alloc, g.where_sql, g.joins, g.params);
}

/// Whether `record_id` is authorized for `action` under the composed policy. PR1: `allow` → true,
/// `deny_locked` → false, `check` → `rules.matches` (a guarded `SELECT 1`). Byte-identical to the
/// inline `decide` + `rules.matches` the chokepoints used before.
pub fn authorizes(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, action: Action, record_id: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    // Self-freeing (contract 1): the composed guard is scratch consumed to run one probe —
    // it never escapes the `bool` return — so it compiles on a function-local arena.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // Route through compilePredicate so the SAME composition (rule AND tenant-scope) governs the
    // single-record check that governs list. A null predicate is the `allow` state (true); the
    // constant-false `"0"` guard is `deny_locked` (false); anything else is a guarded SELECT 1.
    const guard = (try compilePredicate(sa, conn, col, action, rctx)) orelse return true;
    if (std.mem.eql(u8, guard.where_sql, "0")) return false;
    return records.guardPasses(sa, conn, col, record_id, guard);
}

/// Evaluate an ARBITRARY combined rule expression against `record_id` (a guarded `SELECT 1`).
/// Used by realtime delivery, which AND-s a collection's viewRule with a subscription filter into
/// one expression that is not a single action rule. A thin pass-through to the rules primitive so
/// realtime authz also funnels through the policy layer (the seam PR5 composes into).
pub fn matchesRule(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, record_id: []const u8, rule: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    // Self-freeing (contract 1): the compiled guard and its ability/tenant composition are
    // scratch consumed to run one probe — none escape the `bool` return — so the function
    // builds and frees them on a function-local arena. This makes it leak-correct under ANY
    // allocator, not only when the caller passes an arena. (When `alloc` is itself an arena —
    // the realtime delivery path — the scratch lives and dies with it as before.)
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // An EMPTY `rule` contributes no rule-clause — the realtime hub passes "" when a collection's
    // viewRule is `@public`/`allow` (no expression to compile) but an ability or the tenant scope
    // must still constrain delivery. A non-empty rule compiles to a guard as before.
    var guard: ?Guard = if (rule.len > 0) try rules.compileGuard(sa, conn, col, rule, rctx) else null;
    // Realtime delivery on an ability- or tenant-guarded collection is narrowed to what the
    // subscriber may VIEW too (the composition funnels through this one place). Each is null =
    // no-op (byte-identical to the prior `rules.matches` for a plain collection / no-tenancy app).
    if (try abilities.abilityPredicate(sa, col, abilityFor(col, .view), rctx, db.dbDialect(conn))) |ap|
        guard = try andPredicate(sa, guard, ap.sql, ap.params);
    if (try tenancy.scopePredicate(sa, col, rctx)) |sp| guard = try andPredicate(sa, guard, sp.sql, &.{sp.param});
    // No rule clause AND no ability AND no tenant scope => unconstrained (deliver). Otherwise run
    // the guarded SELECT 1.
    const g = guard orelse return true;
    return records.guardPasses(sa, conn, col, record_id, g);
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
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. The `withRule` copies below share its
    // owned fields/id/name and only overwrite rule slots with string LITERALS, so they are never
    // handed to Collection.deinit. `decide` allocates nothing (returns an enum).
    const base = try pinBase(a, &d);
    defer base.deinit(a);
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
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. The `withRule` copies share its owned
    // fields/id/name and only overwrite rule slots with string LITERALS, so they never reach
    // Collection.deinit. Every returned Guard is `Guard.own`-built (fully owned) -> free via deinit.
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    const rule = "owner = @request.auth.id";
    const col = withRule(base, rule);
    var auth: std.json.ObjectMap = .empty;
    defer auth.deinit(a);
    try auth.put(a, "id", .{ .string = "u1" });
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };

    const want = try rules.compileGuard(a, &d, col, rule, &rctx);
    defer want.deinit(a);
    const got = (try compilePredicate(a, &d, col, .update, &rctx)).?;
    defer got.deinit(a);
    try std.testing.expectEqualStrings(want.where_sql, got.where_sql);
    try std.testing.expectEqual(want.params.len, got.params.len);
    for (want.params, got.params) |w, g| try std.testing.expectEqualStrings(w.text, g.text);

    // allow state -> null predicate; locked state -> constant-false guard.
    try std.testing.expect((try compilePredicate(a, &d, withRule(base, "@public"), .update, &rctx)) == null);
    const locked = (try compilePredicate(a, &d, withRule(base, null), .update, &rctx)).?;
    defer locked.deinit(a);
    try std.testing.expectEqualStrings("0", locked.where_sql);
}

test "PIN: policy.authorizes matches rules decide+matches for allow/deny/check" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    const col = withRule(base, "owner = @request.auth.id");
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','u1');");
    var auth: std.json.ObjectMap = .empty;
    defer auth.deinit(a);
    try auth.put(a, "id", .{ .string = "u1" });
    const owner = request.RequestContext{ .auth = .{ .object = auth } };
    const su = request.RequestContext{ .is_superuser = true };
    const anon = request.RequestContext{};

    // check state: owner matches, stranger does not — identical to rules.matches.
    try std.testing.expectEqual(try rules.matches(a, &d, col, "r1", col.viewRule.?, &owner), try authorizes(a, &d, col, .view, "r1", &owner));
    try std.testing.expect(try authorizes(a, &d, col, .view, "r1", &owner));
    var stranger: std.json.ObjectMap = .empty;
    defer stranger.deinit(a);
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
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. `withRule` copies share its owned
    // fields and only overwrite rule slots with string LITERALS, so they never reach Collection.deinit.
    const base = try pinBase(a, &d); // posts: NO tenant_field
    defer base.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','u1');");
    var auth: std.json.ObjectMap = .empty;
    defer auth.deinit(a);
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
            // Compiled predicate identical (where_sql + params). Each returned Guard is `own`-built
            // (fully owned) — free per iteration whenever non-null.
            const g_off = try compilePredicate(a, &d, col, action, &off);
            defer if (g_off) |go| go.deinit(a);
            const g_on = try compilePredicate(a, &d, col, action, &on);
            defer if (g_on) |go| go.deinit(a);
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
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload (tenant_field = null) — free it once. `scoped` is an
    // unowned copy that overwrites `tenant_field` with a string LITERAL; the `withRule` copies below
    // share base's owned fields while overwriting rule/tenant slots with literals, so none reach
    // Collection.deinit. Every returned Guard is `own`-built (fully owned) — free via deinit.
    const base = try pinBase(a, &d); // posts(title, owner)
    defer base.deinit(a);
    var scoped = base;
    scoped.options.tenant_field = "owner"; // owning-account column (literal, never owned)

    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    const xt = request.RequestContext{ .tenancy_enabled = true, .cross_tenant = true, .account_id = "acc1" };

    // @public would normally `allow`; tenancy forces `.check` so the row is scoped.
    const pub_col = withRule(scoped, "@public");
    try std.testing.expectEqual(Decision.check, decide(pub_col, .list, &member));
    const g = (try compilePredicate(a, &d, pub_col, .list, &member)).?;
    defer g.deinit(a);
    try std.testing.expectEqualStrings("\"posts\".\"owner\" = ?", g.where_sql);
    try std.testing.expectEqual(@as(usize, 1), g.params.len);
    try std.testing.expectEqualStrings("acc1", g.params[0].text);

    // Superuser + crossTenant bypass scoping entirely (decision falls back to the rule => allow).
    try std.testing.expectEqual(Decision.allow, decide(pub_col, .list, &su));
    try std.testing.expect((try compilePredicate(a, &d, pub_col, .list, &su)) == null);
    try std.testing.expectEqual(Decision.allow, decide(pub_col, .list, &xt));
    try std.testing.expect((try compilePredicate(a, &d, pub_col, .list, &xt)) == null);

    // A locked rule STILL short-circuits to deny before tenancy (fail-closed floor preserved).
    const locked = withRule(scoped, null);
    try std.testing.expectEqual(Decision.deny_locked, decide(locked, .list, &member));
    const lg = (try compilePredicate(a, &d, locked, .list, &member)).?;
    defer lg.deinit(a);
    try std.testing.expectEqualStrings("0", lg.where_sql);

    // A `check` rule ANDs with the tenant predicate (both fragments present).
    const owned = withRule(scoped, "title = \"x\"");
    const g2 = (try compilePredicate(a, &d, owned, .update, &member)).?;
    defer g2.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, "\"posts\".\"owner\" = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, ") AND (") != null);
}

// ---- Abilities composition tests (#155) ------------------------------------

/// `base` with a per-action ability whose `.via` is `owner` and floor `min_role` (#155).
fn withAbility(col: schema.Collection, min_role: []const u8) schema.Collection {
    var c = col;
    const ability = abilities.Ability{ .relationship = .{ .via = "owner", .min_role = min_role } };
    c.options.abilities = .{ .view = ability, .update = ability, .delete = ability, .create = ability };
    return c;
}

// THE CRITICAL BACK-COMPAT GUARANTEE for PR3: a collection with NO ability config must produce the
// IDENTICAL decision and compiled SQL as before abilities existed. This compares a plain collection
// (no `.options.abilities`) to itself for every action/rule state and asserts byte-identical
// results — the regression guard that the abilities composition is a pure pass-through when unused.
test "PIN: abilities unset is byte-identical to no-abilities" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. `withRule` copies share its owned
    // fields and only overwrite rule slots with string LITERALS, so they never reach Collection.deinit.
    const base = try pinBase(a, &d); // posts: NO abilities
    defer base.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','acc1');");
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "owner" }};
    const states = [_]?[]const u8{ null, "", "@public", "owner = @request.auth.id" };
    for (states) |rule| {
        const col = withRule(base, rule); // abilities still null
        const rctx = request.RequestContext{ .memberships = &mem };
        inline for (.{ .list, .view, .create, .update, .delete }) |action| {
            // decide() must match the bare rule decision (no ability forcing a check).
            try std.testing.expectEqual(rules.decide(rule, &rctx), decide(col, action, &rctx));
            // compiled predicate must match rules.compileGuard exactly (or null/"0"). Every returned
            // Guard is `own`-built (fully owned) — free per iteration.
            const got = try compilePredicate(a, &d, col, action, &rctx);
            defer if (got) |gg| gg.deinit(a);
            switch (rules.decide(rule, &rctx)) {
                .allow => try std.testing.expect(got == null),
                .deny_locked => try std.testing.expectEqualStrings("0", got.?.where_sql),
                .check => {
                    const want = try rules.compileGuard(a, &d, col, rule.?, &rctx);
                    defer want.deinit(a);
                    try std.testing.expectEqualStrings(want.where_sql, got.?.where_sql);
                    try std.testing.expectEqual(want.params.len, got.?.params.len);
                },
            }
        }
    }
}

test "ability-guarded collection: decide forces check + compilePredicate binds the membership IN-set" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. The `withRule`/`withAbility` copies
    // share its owned fields and only overwrite rule/ability slots with string LITERALS, so they
    // never reach Collection.deinit. Every returned Guard is `own`-built (fully owned) — free via deinit.
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    const mem = [_]request.Membership{
        .{ .account = "acc1", .role = "owner" },
        .{ .account = "acc2", .role = "viewer" },
    };
    const member = request.RequestContext{ .memberships = &mem };
    const su = request.RequestContext{ .is_superuser = true, .memberships = &mem };

    // @public would normally `allow`; an ability forces `.check` so the row is authorized.
    const pub_col = withRule(withAbility(base, "editor"), "@public");
    try std.testing.expectEqual(Decision.check, decide(pub_col, .view, &member));
    const g = (try compilePredicate(a, &d, pub_col, .view, &member)).?;
    defer g.deinit(a);
    // Only acc1 (owner >= editor) qualifies; the predicate binds exactly that id.
    try std.testing.expectEqualStrings("\"posts\".\"owner\" IN (?)", g.where_sql);
    try std.testing.expectEqual(@as(usize, 1), g.params.len);
    try std.testing.expectEqualStrings("acc1", g.params[0].text);

    // Superuser bypasses abilities entirely (decision -> allow, predicate -> null).
    try std.testing.expectEqual(Decision.allow, decide(pub_col, .view, &su));
    try std.testing.expect((try compilePredicate(a, &d, pub_col, .view, &su)) == null);

    // A locked rule STILL short-circuits to deny before abilities (fail-closed floor preserved).
    const locked = withRule(withAbility(base, "editor"), null);
    try std.testing.expectEqual(Decision.deny_locked, decide(locked, .view, &member));
    const lg = (try compilePredicate(a, &d, locked, .view, &member)).?;
    defer lg.deinit(a);
    try std.testing.expectEqualStrings("0", lg.where_sql);

    // A `check` rule ANDs with the ability predicate (both fragments present).
    const owned = withRule(withAbility(base, ""), "title = \"x\"");
    const g2 = (try compilePredicate(a, &d, owned, .update, &member)).?;
    defer g2.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, "\"posts\".\"owner\" IN (") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2.where_sql, ") AND (") != null);
}

test "ability with no qualifying membership compiles to constant-false (fail closed)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. The `withRule`/`withAbility` copies
    // overwrite rule/ability slots with string LITERALS, so they never reach Collection.deinit. The
    // compilePredicate Guard is `own`-built (fully owned); `authorizes` self-frees (returns a bool).
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','acc1');");
    // Principal has a membership, but below the ability's role floor -> empty set -> "0".
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "viewer" }};
    const rctx = request.RequestContext{ .memberships = &mem };
    const col = withRule(withAbility(base, "owner"), "@public");
    try std.testing.expectEqual(Decision.check, decide(col, .view, &rctx));
    const cf = (try compilePredicate(a, &d, col, .view, &rctx)).?;
    defer cf.deinit(a);
    try std.testing.expectEqualStrings("0", cf.where_sql);
    // authorizes() therefore denies even though the row exists and the rule is @public.
    try std.testing.expect(!try authorizes(a, &d, col, .view, "r1", &rctx));

    // Same principal WITH a qualifying membership (owner of acc1) is authorized for that row.
    const ok = [_]request.Membership{.{ .account = "acc1", .role = "owner" }};
    const okctx = request.RequestContext{ .memberships = &ok };
    try std.testing.expect(try authorizes(a, &d, col, .view, "r1", &okctx));
}

// ---- Abilities LIST read-path regression tests (#155 CRITICAL-1) ------------
// CRITICAL-1: the bulk LIST endpoint composes filter+rule+TTL+tenant in `records.zig:list` and
// previously had ZERO ability composition, so an ability-guarded collection leaked ability-denied
// rows on `GET …/records` and 400'd the documented `@public` + view-ability config. These exercise
// the REAL `records.list` engine path (not just the policy layer the prior PIN tests covered) plus
// `policy.listRuleFilter` (the handler's rule-selection), the seam where the bug lived.

/// Owner ids present in a list result, for set assertions.
fn listOwners(items: []std.json.Value) [][]const u8 {
    var out = std.testing.allocator.alloc([]const u8, items.len) catch unreachable;
    for (items, 0..) |it, i| out[i] = it.object.get("owner").?.string;
    return out;
}

fn hasOwner(owners: [][]const u8, want: []const u8) bool {
    for (owners) |o| if (std.mem.eql(u8, o, want)) return true;
    return false;
}

test "records.list narrows to ability-viewable rows (viewer + non-member excluded)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. The `withRule`/`withAbility`
    // copies below share its owned fields/id/name and only overwrite rule/ability slots with
    // string LITERALS, so they are never handed to Collection.deinit.
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    // Three rows owned by three different accounts.
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','x','acc1'),('r2','t','t','y','acc2'),('r3','t','t','z','acc3');");
    // view ability: editor+ of the owning account. Caller: editor of acc1, viewer of acc2, no acc3.
    const col = withRule(withAbility(base, "editor"), "@public");
    const mem = [_]request.Membership{
        .{ .account = "acc1", .role = "editor" },
        .{ .account = "acc2", .role = "viewer" },
    };
    const rctx = request.RequestContext{ .memberships = &mem };
    var res = try records.list(a, &d, col, .{ .rule = listRuleFilter(col, &rctx), .rctx = &rctx });
    defer res.deinit(a);
    const owners = listOwners(res.items);
    defer std.testing.allocator.free(owners);
    // Only acc1's row (editor >= editor). acc2 (viewer) and acc3 (non-member) are filtered out.
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expect(hasOwner(owners, "acc1"));
    try std.testing.expect(!hasOwner(owners, "acc2"));
    try std.testing.expect(!hasOwner(owners, "acc3"));
}

test "records.list ability empty-set returns zero rows (fail closed, not all rows)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','x','acc1'),('r2','t','t','y','acc2');");
    const col = withRule(withAbility(base, "editor"), "@public");
    // No qualifying membership (only a viewer of acc1, below the editor floor) -> constant-false.
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "viewer" }};
    const rctx = request.RequestContext{ .memberships = &mem };
    var res = try records.list(a, &d, col, .{ .rule = listRuleFilter(col, &rctx), .rctx = &rctx });
    defer res.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), res.items.len);
    // And a principal with no memberships at all also gets zero rows (never the full table).
    const anon = request.RequestContext{};
    var res2 = try records.list(a, &d, col, .{ .rule = listRuleFilter(col, &anon), .rctx = &anon });
    defer res2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), res2.items.len);
}

test "documented @public list rule + ability: listRuleFilter avoids the 400 and narrows" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const base = try pinBase(a, &d);
    defer base.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES ('r1','t','t','x','acc1');");
    const col = withRule(withAbility(base, ""), "@public"); // .rules.list = "@public" + view ability
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "viewer" }};
    const rctx = request.RequestContext{ .memberships = &mem };

    // FAILS-BEFORE: the pre-fix handler passed the `@public` listRule straight to `records.list` as
    // a filter; `@public` is an allow sentinel, not a boolean expression, so the compiler rejects it.
    try std.testing.expectError(error.UnexpectedToken, records.list(a, &d, col, .{ .rule = "@public", .rctx = &rctx }));

    // PASSES-AFTER: `listRuleFilter` returns null for an `@public` (allow) rule, so the handler now
    // passes no rule clause; the view ability still narrows the result (200, ability-scoped rows).
    try std.testing.expect(listRuleFilter(col, &rctx) == null);
    var res = try records.list(a, &d, col, .{ .rule = listRuleFilter(col, &rctx), .rctx = &rctx });
    defer res.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), res.items.len); // acc1 member sees acc1's row
    try std.testing.expectEqualStrings("acc1", res.items[0].object.get("owner").?.string);
}

// ---- Full-text search × access-control chokepoint tests (#157 CRITICAL) -----
// THE #1 RISK for search: a MATCH that runs as a separate, UNSCOPED query would leak rows the
// caller may not view. These exercise the REAL `records.list` engine with `?search=` set and
// assert the FTS predicate is AND-ed into the SAME composition as tenant-scope and the view
// ability — so search NEVER widens visibility. The base `posts(title, owner)` table is reused with
// `title` marked searchable; the FTS5 index + sync triggers are provisioned via `fts.ensureIndex`,
// then rows are inserted with raw SQL (the AFTER INSERT trigger populates the index).

/// `pinBase`'s posts table, re-typed with `title` searchable (the physical column is identical),
/// and its FTS5 index provisioned. Returns the collection to drive `records.list(.{ .search })`.
fn searchableBase(a: std.mem.Allocator, d: *db.Db) !schema.Collection {
    try migrations.run(d);
    // Create the `posts` table directly with `title` searchable, so the returned collection is
    // fully owned (create() dupes id/name/field names) and safe to Collection.deinit — no orphaned
    // base fields, no string-literal names reaching the free path.
    const col = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "owner", .options = .{ .text = .{} } },
    } });
    errdefer col.deinit(a); // ensureIndex failure must not leak the just-created collection.
    try fts.ensureIndex(a, d, col);
    return col;
}

test "records.list full-text search on a tenant-owned collection returns only the caller's account rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base_col` is the fully-owned create() reload; free it once. `col` is an unowned copy that
    // overwrites `tenant_field` with a string LITERAL, so it must never reach Collection.deinit.
    const base_col = try searchableBase(a, &d);
    defer base_col.deinit(a);
    var col = base_col;
    col.options.tenant_field = "owner"; // owning-account column
    // Two accounts each own a row whose title MATCHES the search term "budget".
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','quarterly budget report','acc1')," ++
        "('r2','t','t','quarterly budget summary','acc2');");

    const pub_col = withRule(col, "@public");
    // A member of acc1 searching "budget" gets ONLY acc1's matching row — acc2's match is scoped out.
    const m1 = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    var r1 = try records.list(a, &d, pub_col, .{ .search = "budget", .rule = listRuleFilter(pub_col, &m1), .rctx = &m1 });
    defer r1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), r1.items.len);
    try std.testing.expectEqualStrings("acc1", r1.items[0].object.get("owner").?.string);

    // A member of acc2 sees only acc2's row; a principal with no active account sees none.
    const m2 = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc2" };
    var r2 = try records.list(a, &d, pub_col, .{ .search = "budget", .rule = listRuleFilter(pub_col, &m2), .rctx = &m2 });
    defer r2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), r2.items.len);
    try std.testing.expectEqualStrings("acc2", r2.items[0].object.get("owner").?.string);
    const none = request.RequestContext{ .tenancy_enabled = true, .account_id = "" };
    var r0 = try records.list(a, &d, pub_col, .{ .search = "budget", .rule = listRuleFilter(pub_col, &none), .rctx = &none });
    defer r0.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), r0.items.len);
}

test "records.list full-text search respects the view ability (denied rows absent from results)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `col` is the fully-owned create() reload; free it once. The `withRule`/`withAbility` copies
    // below share its owned fields/id/name and only overwrite rule/ability slots with string
    // LITERALS, so they are never handed to Collection.deinit.
    const col = try searchableBase(a, &d);
    defer col.deinit(a);
    // Three rows owned by three accounts; ALL match the search term "report".
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','annual report','acc1')," ++
        "('r2','t','t','annual report','acc2')," ++
        "('r3','t','t','annual report','acc3');");
    // view ability: editor+ of the owning account. Caller: editor of acc1, viewer of acc2, no acc3.
    const guarded = withRule(withAbility(col, "editor"), "@public");
    const mem = [_]request.Membership{
        .{ .account = "acc1", .role = "editor" },
        .{ .account = "acc2", .role = "viewer" },
    };
    const rctx = request.RequestContext{ .memberships = &mem };
    var res = try records.list(a, &d, guarded, .{ .search = "report", .rule = listRuleFilter(guarded, &rctx), .rctx = &rctx });
    defer res.deinit(a);
    const owners = listOwners(res.items);
    defer std.testing.allocator.free(owners);
    // Only acc1's row survives BOTH the MATCH and the ability — acc2 (viewer) and acc3 (non-member)
    // match the search but are denied by the ability, so they are absent (search never widens view).
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expect(hasOwner(owners, "acc1"));
    try std.testing.expect(!hasOwner(owners, "acc2"));
    try std.testing.expect(!hasOwner(owners, "acc3"));
}

test "records.list full-text search ranks by bm25 and binds a basic-operator query safely" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. `col` is the `withRule` copy that
    // overwrites the rule slots with a string LITERAL, so it is never handed to Collection.deinit.
    const base = try searchableBase(a, &d);
    defer base.deinit(a);
    const col = withRule(base, "@public");
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','alpha alpha alpha','acc1')," ++ // most relevant for "alpha"
        "('r2','t','t','alpha beta','acc1')," ++
        "('r3','t','t','gamma delta','acc1');");
    const anon = request.RequestContext{};

    // Ranked ordering: the row with the densest "alpha" match comes first (bm25 via FTS `rank`).
    var ranked = try records.list(a, &d, col, .{ .search = "alpha", .rule = listRuleFilter(col, &anon), .rctx = &anon });
    defer ranked.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), ranked.items.len);
    try std.testing.expectEqualStrings("r1", ranked.items[0].object.get("id").?.string);

    // A basic-operator (OR) query parses + binds safely and returns the union of matches — no error,
    // no injection: the operator is preserved while each term is a bound, quoted token.
    var ored = try records.list(a, &d, col, .{ .search = "alpha OR gamma", .rule = listRuleFilter(col, &anon), .rctx = &anon });
    defer ored.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), ored.items.len); // r1,r2 (alpha) + r3 (gamma)

    // A search on a collection with NO searchable field is a clean error (handler -> 400), never a
    // silent full-table return. (Rejected before any query, so no backing table is needed.)
    const plain = schema.Collection{ .id = "p", .name = "plainposts", .fields = &[_]schema.Field{
        .{ .id = "g1", .name = "title", .options = .{ .text = .{} } },
    } };
    try std.testing.expectError(error.NotSearchable, records.list(a, &d, withRule(plain, "@public"), .{ .search = "alpha", .rctx = &anon }));
}

test "records.list full-text search intersects with the filter (search still constrains)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. `col` is the `withRule` copy that
    // overwrites the rule slots with a string LITERAL, so it is never handed to Collection.deinit.
    const base = try searchableBase(a, &d);
    defer base.deinit(a);
    const col = withRule(base, "@public");
    // r1: matches "budget" AND owner acc1; r2: matches "budget" but owner acc2; r3: owner acc1 but
    // does NOT match "budget".
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','budget plan','acc1')," ++
        "('r2','t','t','budget review','acc2')," ++
        "('r3','t','t','random note','acc1');");
    const anon = request.RequestContext{};

    // The result must be the INTERSECTION of search AND filter: only r1.
    // FAILS-BEFORE: the filter block ASSIGNED where_sql, clobbering the FTS MATCH (and dropping its
    // bound param), so `search=budget&filter=owner='acc1'` returned every owner=acc1 row — r1 AND r3
    // (r3 lacks "budget"). PASSES-AFTER: the filter AND-composes onto the MATCH, so r3 is excluded.
    var res = try records.list(a, &d, col, .{
        .search = "budget",
        .filter = "owner = \"acc1\"",
        .rule = listRuleFilter(col, &anon),
        .rctx = &anon,
    });
    defer res.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("r1", res.items[0].object.get("id").?.string);
}

test "records.list search that sanitizes to empty returns no rows (not the full scoped list)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // `base` is the fully-owned create() reload; free it once. `col` is the `withRule` copy that
    // overwrites the rule slots with a string LITERAL, so it is never handed to Collection.deinit.
    const base = try searchableBase(a, &d);
    defer base.deinit(a);
    const col = withRule(base, "@public");
    try d.exec("INSERT INTO posts (id,created,updated,title,owner) VALUES " ++
        "('r1','t','t','hello world','acc1'),('r2','t','t','goodbye world','acc1');");
    const anon = request.RequestContext{};

    // A non-empty search that sanitizes to nothing (operator-only) matches NOTHING — it must NOT
    // degrade to a full (scoped) list just because the user "searched".
    var empty = try records.list(a, &d, col, .{ .search = "AND", .rule = listRuleFilter(col, &anon), .rctx = &anon });
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    // Sanity: a real term still returns its match (the short-circuit is specific to empty queries).
    var real = try records.list(a, &d, col, .{ .search = "hello", .rule = listRuleFilter(col, &anon), .rctx = &anon });
    defer real.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), real.items.len);
}
