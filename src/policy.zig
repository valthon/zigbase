const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const rules = @import("rules.zig");

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

/// The pure, per-collection authorization decision for `action`. PR1: delegates to
/// `rules.decide` on the action's rule. (PR2/PR3 keep `deny_locked` as the fail-closed floor.)
pub fn decide(col: schema.Collection, action: Action, rctx: *const request.RequestContext) Decision {
    return rules.decide(ruleFor(col, action), rctx);
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
    return switch (rules.decide(rule, rctx)) {
        .allow => null,
        .deny_locked => Guard{ .where_sql = "0" }, // constant-false: AND-ing denies all rows
        .check => try rules.compileGuard(alloc, conn, col, rule.?, rctx),
    };
}

/// Whether `record_id` is authorized for `action` under the composed policy. PR1: `allow` → true,
/// `deny_locked` → false, `check` → `rules.matches` (a guarded `SELECT 1`). Byte-identical to the
/// inline `decide` + `rules.matches` the chokepoints used before.
pub fn authorizes(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, action: Action, record_id: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    const rule = ruleFor(col, action);
    return switch (rules.decide(rule, rctx)) {
        .allow => true,
        .deny_locked => false,
        .check => try rules.matches(alloc, conn, col, record_id, rule.?, rctx),
    };
}

/// Evaluate an ARBITRARY combined rule expression against `record_id` (a guarded `SELECT 1`).
/// Used by realtime delivery, which AND-s a collection's viewRule with a subscription filter into
/// one expression that is not a single action rule. A thin pass-through to the rules primitive so
/// realtime authz also funnels through the policy layer (the seam PR5 composes into).
pub fn matchesRule(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, record_id: []const u8, rule: []const u8, rctx: *const request.RequestContext) PolicyError!bool {
    return rules.matches(alloc, conn, col, record_id, rule, rctx);
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
