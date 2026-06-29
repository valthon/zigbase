//! Tenant role total-order ranking (multi-tenancy, #156).
//!
//! A tenancy role is a plain string carried on a `_memberships` row (and surfaced via the
//! `@request.account.role` rule macro). Authorization that compares roles ("an editor may do
//! anything a viewer may") needs a TOTAL ORDER over the role set; this module is that order.
//!
//! The order is comptime-configurable from `.tenancy.roles` (a tuple of role-name string
//! literals, lowest privilege first). Absent it, the default ladder is
//! `viewer < editor < admin < owner`. PR3 (abilities) consumes `gte`; this file is kept small
//! and dependency-free so both the comptime config validator and the runtime resolver can use it.

const std = @import("std");

/// The default role ladder, lowest privilege first. Index = rank.
pub const default_roles = [_][]const u8{ "viewer", "editor", "admin", "owner" };

/// A role total-order: `roles[i]` outranks `roles[j]` iff `i > j`. Built at comptime from
/// `.tenancy.roles` (or the default ladder) via `buildRanking`; the runtime resolver and PR3's
/// ability checks call `rank`/`gte` against the resolved `@request.account.role` string.
pub const Ranking = struct {
    /// Role names, lowest privilege first. Static lifetime (comptime literals).
    roles: []const []const u8 = &default_roles,

    /// The 0-based rank of `role` (0 = lowest privilege), or null if `role` is not in the set.
    /// An unknown role is intentionally null so callers fail closed rather than guessing a rank.
    pub fn rank(self: Ranking, role: []const u8) ?u8 {
        for (self.roles, 0..) |r, i| {
            if (std.mem.eql(u8, r, role)) return @intCast(i);
        }
        return null;
    }

    /// True iff `a` is AT LEAST as privileged as `b` (rank(a) >= rank(b)). Any unknown role
    /// (either side) yields false — fail closed, never silently grant.
    pub fn gte(self: Ranking, a: []const u8, b: []const u8) bool {
        const ra = self.rank(a) orelse return false;
        const rb = self.rank(b) orelse return false;
        return ra >= rb;
    }

    /// True iff `role` is a member of the ladder.
    pub fn isKnown(self: Ranking, role: []const u8) bool {
        return self.rank(role) != null;
    }
};

/// Lower a comptime `.tenancy.roles` literal (a tuple/array of string-literal role names, lowest
/// privilege first) into a `Ranking`. An absent/empty set is rejected by the caller
/// (`framework.zig`); this lowering itself rejects a non-string element or a duplicate name with
/// a loud `@compileError` (the loud-comptime convention).
pub fn buildRanking(comptime roles: anytype) Ranking {
    comptime {
        const T = @TypeOf(roles);
        const info = @typeInfo(T);
        if (info != .@"struct" or !info.@"struct".is_tuple)
            @compileError(".tenancy.roles must be a tuple of role-name string literals, e.g. .{ \"viewer\", \"editor\", \"admin\", \"owner\" }");
        const fields = info.@"struct".fields;
        if (fields.len == 0) @compileError(".tenancy.roles must declare at least one role");
        // Ranks are 0-based `u8` (see `rank`/`Ranking.roles`), so the ladder may hold at most 256
        // roles (indices 0..255). A larger ladder would make `@intCast(i)` in `rank()` trap at
        // runtime — reject it loudly at comptime instead.
        if (fields.len > 256) @compileError(".tenancy.roles declares too many roles (max 256)");
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |_, i| {
            const r: []const u8 = @field(roles, fields[i].name);
            for (0..i) |j| if (std.mem.eql(u8, out[j], r))
                @compileError(".tenancy.roles contains duplicate role '" ++ r ++ "'");
            out[i] = r;
        }
        const frozen = out;
        return .{ .roles = &frozen };
    }
}

test "default ranking: order and gte" {
    const r = Ranking{};
    try std.testing.expectEqual(@as(?u8, 0), r.rank("viewer"));
    try std.testing.expectEqual(@as(?u8, 3), r.rank("owner"));
    try std.testing.expect(r.rank("nope") == null);
    try std.testing.expect(r.gte("owner", "viewer"));
    try std.testing.expect(r.gte("editor", "editor"));
    try std.testing.expect(!r.gte("viewer", "admin"));
    // Unknown role on either side -> false (fail closed).
    try std.testing.expect(!r.gte("ghost", "viewer"));
    try std.testing.expect(!r.gte("owner", "ghost"));
    try std.testing.expect(r.isKnown("admin"));
    try std.testing.expect(!r.isKnown("ghost"));
}

test "buildRanking lowers a custom ladder" {
    const r = comptime buildRanking(.{ "member", "lead", "boss" });
    try std.testing.expectEqual(@as(usize, 3), r.roles.len);
    try std.testing.expectEqual(@as(?u8, 0), r.rank("member"));
    try std.testing.expectEqual(@as(?u8, 2), r.rank("boss"));
    try std.testing.expect(r.gte("boss", "member"));
    try std.testing.expect(!r.gte("member", "lead"));
}
