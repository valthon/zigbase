const std = @import("std");

/// One account membership for the authenticated principal (multi-tenancy foundation, #156).
/// `account` is the account id; `role` is the principal's role within that account. The PR1
/// FOUNDATION ships the type + the `@request.account.*` macros that read it; PR2's resolver fills
/// `RequestContext.memberships` from a verified, indexed membership lookup. Until then the slice is
/// empty so every `@request.account.*` macro resolves to "" / the empty list (no behavior change).
pub const Membership = struct {
    account: []const u8 = "",
    role: []const u8 = "",
};

/// The per-request context rules evaluate against. SP4 builds an empty one (no auth yet);
/// SP5's auth middleware fills `auth`/`is_superuser`/`collection`.
pub const RequestContext = struct {
    auth: ?std.json.Value = null, // authenticated record object; null = unauthenticated
    is_superuser: bool = false,
    collection: []const u8 = "", // auth collection name; "" = unauthenticated/anonymous
    data: ?std.json.Value = null, // request body (create/update rules)
    method: []const u8 = "",
    /// Server-side session id of the current request's token (Variant B, #99); "" in epoch
    /// mode or when the token carries no `sid`. Lets `ctx.auth()` target THIS device's row
    /// (logout/revoke) and mark it `is_current` in `listActiveSessions`.
    session_id: []const u8 = "",
    /// Active account scope for the current request (multi-tenancy, #156). PR1 FOUNDATION leaves
    /// these empty — PR2's tenant resolver fills them from a verified membership. An empty
    /// `account_id` means "no tenant scope", so the `@request.account.*` macros resolve to "" and
    /// pre-tenancy behavior is preserved byte-for-byte.
    account_id: []const u8 = "",
    account_role: []const u8 = "",
    /// Every account the principal belongs to — the source for the `@request.account.ids` list
    /// macro (membership-bounded `IN (?,?,…)`). Empty in PR1; PR2 populates it from one indexed
    /// membership SELECT cached on the context.
    memberships: []const Membership = &.{},
    /// True when the app has tenancy enabled (`App(.{ .tenancy = .{ .enabled = true } })`). Gates
    /// the tenant-scope predicate (`tenancy.scopePredicate`): when false, scoping is a no-op and
    /// the composed SQL/decisions are byte-identical to the pre-tenancy engine. Default false so a
    /// directly-constructed context (tests, non-tenant apps) takes the no-tenancy path.
    tenancy_enabled: bool = false,
    /// Explicit "operate across tenants" override for superuser / admin tooling (e.g. moving a
    /// record between accounts). When true the tenant-scope predicate is suppressed (like the
    /// superuser bypass) and the write-path cross-tenant guard is skipped. Default false — never
    /// silently widens scope.
    cross_tenant: bool = false,

    /// Resolve a `@request.*` macro path to a text value. Returns null for an unknown macro.
    /// `@request.auth.<field>` and `@request.data.<field>` yield "" when absent/unauthenticated.
    /// `@request.auth.collection` returns the auth collection name (not a record field).
    /// `@request.account.id`/`@request.account.role` yield the active account scope ("" when none).
    /// The list-valued `@request.account.ids` is NOT resolved here — see `resolveMacroList`.
    pub fn resolveMacro(self: *const RequestContext, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "@request.method")) return self.method;
        if (std.mem.startsWith(u8, path, "@request.auth.")) {
            const field = path["@request.auth.".len..];
            if (std.mem.eql(u8, field, "collection")) return self.collection;
            return objField(self.auth, field);
        }
        if (std.mem.startsWith(u8, path, "@request.data.")) {
            const field = path["@request.data.".len..];
            return objField(self.data, field);
        }
        if (std.mem.startsWith(u8, path, "@request.account.")) {
            const field = path["@request.account.".len..];
            if (std.mem.eql(u8, field, "id")) return self.account_id;
            if (std.mem.eql(u8, field, "role")) return self.account_role;
            return null; // ".ids" is a list macro (resolveMacroList); anything else is unknown
        }
        return null;
    }

    /// Resolve a LIST-valued `@request.*` macro to its element strings (allocated with `alloc`).
    /// Returns null for an unknown list macro. Currently only `@request.account.ids` — the id of
    /// every account the principal belongs to, bounded by membership count. Empty in PR1 (no
    /// memberships resolved yet) → an empty slice, which the compiler emits as a constant-false
    /// `IN` predicate (fail-closed).
    pub fn resolveMacroList(self: *const RequestContext, alloc: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?[]const []const u8 {
        if (std.mem.eql(u8, path, "@request.account.ids")) {
            const out = try alloc.alloc([]const u8, self.memberships.len);
            for (self.memberships, 0..) |m, i| out[i] = m.account;
            return out;
        }
        return null;
    }
};

/// Read a string-ish field from an optional JSON object; "" when the object is null/absent or
/// the field is missing; non-string values render as "" (SP4 macros are text-only).
fn objField(obj: ?std.json.Value, field: []const u8) []const u8 {
    const o = obj orelse return "";
    if (o != .object) return "";
    const v = o.object.get(field) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

test "resolveMacro: auth absent -> empty, present -> value; data; method" {
    var ctx = RequestContext{ .method = "GET" };
    try std.testing.expectEqualStrings("", ctx.resolveMacro("@request.auth.id").?);
    try std.testing.expectEqualStrings("GET", ctx.resolveMacro("@request.method").?);
    try std.testing.expect(ctx.resolveMacro("@request.bogus") == null);

    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(std.testing.allocator, "id", .{ .string = "u1" });
    defer auth_obj.deinit(std.testing.allocator);
    ctx.auth = .{ .object = auth_obj };
    try std.testing.expectEqualStrings("u1", ctx.resolveMacro("@request.auth.id").?);
}

test "resolveMacro: account scope defaults empty, then reflects set values" {
    // PR1 default: no tenant scope -> the account macros resolve to "" (additive, no behavior change).
    const empty = RequestContext{};
    try std.testing.expectEqualStrings("", empty.resolveMacro("@request.account.id").?);
    try std.testing.expectEqualStrings("", empty.resolveMacro("@request.account.role").?);
    // ".ids" is a list macro, not a single-text macro; an unknown sub-key is null.
    try std.testing.expect(empty.resolveMacro("@request.account.ids") == null);
    try std.testing.expect(empty.resolveMacro("@request.account.bogus") == null);

    const scoped = RequestContext{ .account_id = "acc1", .account_role = "admin" };
    try std.testing.expectEqualStrings("acc1", scoped.resolveMacro("@request.account.id").?);
    try std.testing.expectEqualStrings("admin", scoped.resolveMacro("@request.account.role").?);
}

test "resolveMacroList: account.ids reflects memberships; empty by default" {
    const a = std.testing.allocator;
    const empty = RequestContext{};
    const e = (try empty.resolveMacroList(a, "@request.account.ids")).?;
    defer a.free(e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expect((try empty.resolveMacroList(a, "@request.account.role")) == null);

    const mem = [_]Membership{ .{ .account = "a1", .role = "owner" }, .{ .account = "a2", .role = "viewer" } };
    const ctx = RequestContext{ .memberships = &mem };
    const ids = (try ctx.resolveMacroList(a, "@request.account.ids")).?;
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("a1", ids[0]);
    try std.testing.expectEqualStrings("a2", ids[1]);
}
