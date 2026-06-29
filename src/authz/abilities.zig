//! Relationship-based row abilities (#155, PR3) — the declarative ability layer stacked on
//! account-scoped tenancy (#156).
//!
//! An *ability* authorizes a CRUD action on a collection by the principal's RELATIONSHIP to the
//! row, expressed declaratively in `App(.{ .abilities = .{ .<col> = .{ .view = <rule>, … } } })`.
//! The only rule shape today is a `.relationship`: a row is authorized when the account named by
//! the row's `.via` relation field is one the principal holds an active membership of with role
//! `>= .min_role`. It LOWERS (Option A) to a bound `IN` predicate over the principal's qualifying
//! membership account-ids — the exact shape the `in` operator + `@request.account.ids` already
//! emit (`"<col>"."<via>" IN (?,?,…)`), composed into the same guard stack as the access rule and
//! tenant scope by `policy.zig`.
//!
//! FAIL CLOSED is sacred: an empty qualifying set (no membership at/above `min_role`) lowers to the
//! constant-false predicate `0` (never SQLite's invalid `IN ()`), every account-id is BOUND (`?`,
//! never interpolated), and the `"<col>"`/`"<via>"` identifiers are gated through
//! `schema.isValidIdentifier`. A superuser bypasses abilities entirely (consistent with
//! `rules.decide`). Back-compat is sacred too: a collection with NO ability config contributes a
//! null predicate, so the composed SQL/decisions are byte-identical to PR2 (pinned in `policy.zig`).

const std = @import("std");
const schema = @import("../schema.zig");
const request = @import("../request.zig");
const compiler = @import("../query/compiler.zig");
const roles = @import("../tenancy/roles.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

/// A `min_role` sentinel that no configured role can ever equal (it embeds a NUL byte, which a
/// role-name string literal cannot contain). Used by deserialization to FAIL CLOSED on a malformed
/// (present-but-non-string) `min_role`: `ranking.gte(role, invalid_min_role)` is always false (the
/// rank lookup misses), so every membership is filtered out → empty qualifying set → constant-false
/// `"0"` → deny. This is distinct from an EMPTY `min_role` ("" = any active member qualifies).
pub const invalid_min_role = "\x00__invalid__";

/// A `.relationship` ability rule. `via` names a RELATION field on the collection whose column
/// holds an account id; `min_role` (the lowest role that qualifies; "" = any active membership) is
/// compared against the principal's membership role for that account via the configured ranking.
pub const Relationship = struct {
    via: []const u8,
    min_role: []const u8 = "",
};

/// One lowered ability rule. A tagged union so additional rule kinds (e.g. a Zig predicate escape
/// hatch) can be added without changing the per-collection/per-action shape.
pub const Ability = struct {
    relationship: Relationship,
};

/// Per-action ability rules for a collection (null = no ability for that action). `list` reuses
/// the `view` ability (a list is a filtered set of viewable rows). Lives on
/// `schema.CollectionOptions.abilities` so it round-trips through provisioning like `tenant_field`.
pub const Abilities = struct {
    view: ?Ability = null,
    update: ?Ability = null,
    delete: ?Ability = null,
    create: ?Ability = null,
};

/// A compiled, parameter-bound ability predicate: a WHERE fragment + its bound params. AND-ed into
/// the guard stack by `policy.zig`. An empty qualifying set yields `sql == "0"` (constant-false,
/// no params) so AND-ing it denies every row.
pub const Predicate = struct {
    sql: []const u8,
    params: []const compiler.Param = &.{},
};

/// True iff an ability predicate APPLIES for `rctx`: there is a rule AND the principal is not a
/// superuser (superusers bypass abilities, consistent with `rules.decide`). `policy.decide` uses
/// this to force a per-row `.check` even when the access rule alone would `allow`, so an
/// ability-guarded collection is never served unchecked.
pub fn abilityApplies(ability: ?Ability, rctx: *const request.RequestContext) bool {
    if (rctx.is_superuser) return false;
    return ability != null;
}

/// Lower `ability` into a bound predicate for `col` under `rctx`, or null when it does not apply
/// (no rule / superuser). Filters the principal's memberships by `min_role` (using `rctx`'s role
/// ranking) and emits `"<col>"."<via>" IN (?,?,…)` binding each qualifying account-id. An empty
/// qualifying set → the constant-false `0` predicate (fail closed). Invalid identifiers also fail
/// closed to `0` (defensive; identifiers are comptime-validated in `applyAbilities`).
pub fn abilityPredicate(
    alloc: std.mem.Allocator,
    col: schema.Collection,
    ability: ?Ability,
    rctx: *const request.RequestContext,
    dialect: Dialect,
) std.mem.Allocator.Error!?Predicate {
    if (!abilityApplies(ability, rctx)) return null;
    const rel = ability.?.relationship;
    if (!schema.isValidIdentifier(col.name) or !schema.isValidIdentifier(rel.via))
        return Predicate{ .sql = dialect.constFalse() }; // fail closed

    const ranking = rctx.role_ranking;
    var params: std.ArrayList(compiler.Param) = .empty;
    for (rctx.memberships) |m| {
        const qualifies = if (rel.min_role.len == 0) true else ranking.gte(m.role, rel.min_role);
        if (!qualifies) continue;
        try params.append(alloc, .{ .text = m.account });
    }
    const n = params.items.len;
    if (n == 0) return Predicate{ .sql = dialect.constFalse() }; // empty set -> constant-false, fail closed

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\" IN (", .{ col.name, rel.via }));
    for (0..n) |i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '?');
    }
    try buf.append(alloc, ')');
    return Predicate{ .sql = try buf.toOwnedSlice(alloc), .params = try params.toOwnedSlice(alloc) };
}

// ---- Comptime lowering + validation -----------------------------------------

/// Lower the top-level `.abilities` config (keyed by collection name) onto a copy of `base`,
/// returning the augmented collection slice (each named collection gets `options.abilities` set).
/// Loud `@compileError` on: an ability naming an unknown collection, a `.via` that is not a relation
/// field, an unknown action/rule key, or a `.min_role` not in the configured `.tenancy.roles`.
pub fn applyAbilities(
    comptime base: []const schema.Collection,
    comptime abilities_cfg: anytype,
    comptime ranking: roles.Ranking,
) []const schema.Collection {
    comptime {
        @setEvalBranchQuota(50_000);
        const ACfg = @TypeOf(abilities_cfg);
        if (@typeInfo(ACfg) != .@"struct")
            @compileError(".abilities must be a struct keyed by collection name, e.g. '.{ .posts = .{ .view = ... } }'");

        var out: [base.len]schema.Collection = undefined;
        for (base, 0..) |c, i| out[i] = c;

        for (std.meta.fields(ACfg)) |cf| {
            const cname = cf.name;
            var idx: ?usize = null;
            for (out, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, cname)) idx = i;
            }
            if (idx == null)
                @compileError("abilities: unknown collection '" ++ cname ++ "' (no such collection in .collections)");

            const spec = @field(abilities_cfg, cname);
            const SpecT = @TypeOf(spec);
            if (@typeInfo(SpecT) != .@"struct")
                @compileError("abilities: collection '" ++ cname ++ "' must map to '.{ .view = ..., .update = ..., ... }'");

            var ab = Abilities{};
            for (std.meta.fields(SpecT)) |af| {
                const action = af.name;
                const known = streq(action, "view") or streq(action, "update") or
                    streq(action, "delete") or streq(action, "create");
                if (!known)
                    @compileError("abilities: collection '" ++ cname ++ "': unknown action '." ++ action ++
                        "' (recognized: .view, .update, .delete, .create)");
                const lowered = lowerRule(cname, out[idx.?], @field(spec, action), ranking);
                if (streq(action, "view")) ab.view = lowered;
                if (streq(action, "update")) ab.update = lowered;
                if (streq(action, "delete")) ab.delete = lowered;
                if (streq(action, "create")) ab.create = lowered;
            }
            out[idx.?].options.abilities = ab;
        }
        const frozen = out;
        return &frozen;
    }
}

fn streq(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Validate + lower one `.{ .relationship = .{ .via, .min_role } }` rule for collection `col`.
fn lowerRule(comptime cname: []const u8, comptime col: schema.Collection, comptime rule: anytype, comptime ranking: roles.Ranking) Ability {
    comptime {
        const RT = @TypeOf(rule);
        if (@typeInfo(RT) != .@"struct" or !@hasField(RT, "relationship"))
            @compileError("abilities: '" ++ cname ++ "' rule must be '.{ .relationship = .{ .via = \"<relation>\", .min_role = .<role> } }'");
        for (std.meta.fields(RT)) |f| {
            if (!streq(f.name, "relationship"))
                @compileError("abilities: '" ++ cname ++ "': unknown rule key '." ++ f.name ++ "' (recognized: .relationship)");
        }
        const rel = rule.relationship;
        const RelT = @TypeOf(rel);
        if (@typeInfo(RelT) != .@"struct" or !@hasField(RelT, "via"))
            @compileError("abilities: '" ++ cname ++ "': .relationship must set .via (the relation field naming the owning account)");
        for (std.meta.fields(RelT)) |f| {
            if (!streq(f.name, "via") and !streq(f.name, "min_role"))
                @compileError("abilities: '" ++ cname ++ "': unknown .relationship key '." ++ f.name ++ "' (recognized: .via, .min_role)");
        }
        const via: []const u8 = rel.via;

        // `.via` MUST name a relation field on this collection.
        var found = false;
        for (col.fields) |fld| {
            if (std.mem.eql(u8, fld.name, via)) {
                if (std.meta.activeTag(fld.options) != .relation)
                    @compileError("abilities: '" ++ cname ++ "': .via '" ++ via ++ "' must name a RELATION field (it is a " ++
                        @tagName(std.meta.activeTag(fld.options)) ++ " field)");
                found = true;
            }
        }
        if (!found)
            @compileError("abilities: '" ++ cname ++ "': .via '" ++ via ++ "' names no field on the collection");

        var min_role: []const u8 = "";
        if (@hasField(RelT, "min_role")) {
            const mr = rel.min_role;
            min_role = if (@typeInfo(@TypeOf(mr)) == .enum_literal) @tagName(mr) else mr;
            if (!ranking.isKnown(min_role))
                @compileError("abilities: '" ++ cname ++ "': .min_role '" ++ min_role ++ "' is not in the configured .tenancy.roles");
        }
        return .{ .relationship = .{ .via = via, .min_role = min_role } };
    }
}

// ---- Tests ------------------------------------------------------------------

const migrations = @import("../migrations.zig");
const collections = @import("../collections.zig");
const db = @import("../db.zig");

fn setupPosts(a: std.mem.Allocator, d: *db.Db) !schema.Collection {
    try migrations.run(d);
    const accounts = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "accounts", .fields = &[_]schema.Field{
        .{ .id = "an", .name = "name", .options = .{ .text = .{} } },
    } });
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .relation = .{ .targetCollectionId = accounts.id, .maxSelect = 1 } } },
    } });
}

test "abilityPredicate: binds qualifying account ids; emits an IN predicate" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setupPosts(a, &d);
    const mem = [_]request.Membership{
        .{ .account = "acc1", .role = "owner" },
        .{ .account = "acc2", .role = "viewer" },
    };
    const rctx = request.RequestContext{ .memberships = &mem };
    const ab = Ability{ .relationship = .{ .via = "account", .min_role = "editor" } };
    const p = (try abilityPredicate(a, posts, ab, &rctx, Dialect.sqlite)).?;
    // Only acc1 (owner >= editor) qualifies; acc2 (viewer) is filtered out.
    try std.testing.expectEqualStrings("\"posts\".\"account\" IN (?)", p.sql);
    try std.testing.expectEqual(@as(usize, 1), p.params.len);
    try std.testing.expectEqualStrings("acc1", p.params[0].text);
}

test "abilityPredicate: no min_role -> every membership qualifies" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setupPosts(a, &d);
    const mem = [_]request.Membership{ .{ .account = "a1", .role = "viewer" }, .{ .account = "a2", .role = "viewer" } };
    const rctx = request.RequestContext{ .memberships = &mem };
    const ab = Ability{ .relationship = .{ .via = "account" } };
    const p = (try abilityPredicate(a, posts, ab, &rctx, Dialect.sqlite)).?;
    try std.testing.expectEqualStrings("\"posts\".\"account\" IN (?,?)", p.sql);
    try std.testing.expectEqual(@as(usize, 2), p.params.len);
}

test "abilityPredicate: empty qualifying set is constant-false (fail closed)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setupPosts(a, &d);
    // No memberships at all.
    {
        const rctx = request.RequestContext{};
        const p = (try abilityPredicate(a, posts, .{ .relationship = .{ .via = "account" } }, &rctx, Dialect.sqlite)).?;
        try std.testing.expectEqualStrings("0", p.sql);
        try std.testing.expectEqual(@as(usize, 0), p.params.len);
    }
    // Memberships present but none meet min_role.
    {
        const mem = [_]request.Membership{.{ .account = "a1", .role = "viewer" }};
        const rctx = request.RequestContext{ .memberships = &mem };
        const p = (try abilityPredicate(a, posts, .{ .relationship = .{ .via = "account", .min_role = "owner" } }, &rctx, Dialect.sqlite)).?;
        try std.testing.expectEqualStrings("0", p.sql);
    }
}

test "abilityPredicate: superuser bypass -> null (no predicate)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setupPosts(a, &d);
    const rctx = request.RequestContext{ .is_superuser = true };
    try std.testing.expect((try abilityPredicate(a, posts, .{ .relationship = .{ .via = "account" } }, &rctx, Dialect.sqlite)) == null);
    // No ability rule -> null too.
    const member = request.RequestContext{};
    try std.testing.expect((try abilityPredicate(a, posts, null, &member, Dialect.sqlite)) == null);
}

test "applyAbilities: lowers config onto the matching collection's options" {
    const accounts_fields = [_]schema.Field{.{ .id = "an", .name = "name", .options = .{ .text = .{} } }};
    const posts_fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .relation = .{ .targetCollectionId = "accounts" } } },
    };
    const base = [_]schema.Collection{
        .{ .id = "ca", .name = "accounts", .fields = &accounts_fields },
        .{ .id = "cp", .name = "posts", .fields = &posts_fields },
    };
    const out = comptime applyAbilities(&base, .{
        .posts = .{
            .view = .{ .relationship = .{ .via = "account" } },
            .update = .{ .relationship = .{ .via = "account", .min_role = .editor } },
        },
    }, .{});
    // accounts untouched; posts gets view+update abilities, no delete/create.
    try std.testing.expect(out[0].options.abilities == null);
    const ab = out[1].options.abilities.?;
    try std.testing.expectEqualStrings("account", ab.view.?.relationship.via);
    try std.testing.expectEqualStrings("", ab.view.?.relationship.min_role);
    try std.testing.expectEqualStrings("editor", ab.update.?.relationship.min_role);
    try std.testing.expect(ab.delete == null and ab.create == null);
}
