const std = @import("std");
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
const dialect = @import("sql/dialect.zig");

pub const NumberMode = enum { float, int, fixed };

/// Reserved suffix for full-text search (#157) shadow tables: a searchable collection `<x>`
/// provisions an FTS5 table named `<x>_fts`. Canonical here so `schema.validate` (which reserves
/// the suffix on collection names) and `search/fts.zig` (which builds the table name) agree.
pub const fts_suffix = "_fts";

pub const FieldType = enum {
    text, email, url, editor, date, autodate, @"bool", number, json, select, relation, file,
};

pub const FieldOptions = union(FieldType) {
    text: struct { min: ?u32 = null, max: ?u32 = null, pattern: ?[]const u8 = null },
    email: struct {},
    url: struct {},
    editor: struct {},
    date: struct { min: ?[]const u8 = null, max: ?[]const u8 = null },
    autodate: struct { onCreate: bool = true, onUpdate: bool = false },
    @"bool": struct {},
    number: struct { mode: NumberMode = .float, scale: ?u8 = null, min: ?f64 = null, max: ?f64 = null },
    json: struct { maxSize: ?u32 = null },
    select: struct { values: []const []const u8, maxSelect: u32 = 1 },
    relation: struct { targetCollectionId: []const u8, cascadeDelete: bool = false, minSelect: ?u32 = null, maxSelect: u32 = 1 },
    file: struct { maxSelect: u32 = 1, maxSize: ?u64 = null, mimeTypes: ?[]const []const u8 = null },
};

pub const Field = struct {
    id: []const u8,
    name: []const u8,
    required: bool = false,
    unique: bool = false,
    hidden: bool = false,
    /// Transparent at-rest encryption (Theme B1). When true the column stores an
    /// AES-256-GCM envelope; the records layer encrypts on write and decrypts on
    /// read. Only text/editor/json fields may set this (enforced at comptime in
    /// provision.zig). Encrypted fields are non-indexable/-unique/-filterable.
    encrypted: bool = false,
    /// Full-text search (Theme A / #157). When true the field's text is mirrored into the
    /// collection's FTS5 external-content index (provisioned at startup) and becomes matchable
    /// via the `?search=` list param. Only text/editor fields may set this (enforced at comptime
    /// in provision.zig); an encrypted field can never be searchable (ciphertext is opaque).
    searchable: bool = false,
    options: FieldOptions,

    pub fn fieldType(self: Field) FieldType {
        return std.meta.activeTag(self.options);
    }

    /// The backend-independent physical storage class of this field. The single source of
    /// truth for "is this column integer / real / text storage", consumed by the dialect's
    /// `sqlType` (for DDL) and by the provisioner's backend-neutral type comparisons. Bool is
    /// stored as an integer 0/1 (kept consistent across backends so access rules compare
    /// uniformly); a float number is real; everything else (incl. int/fixed numbers, which are
    /// bound as i64) is integer or text per below.
    pub fn storageClass(self: Field) dialect.StorageClass {
        return switch (self.options) {
            .@"bool" => .integer,
            .number => |n| if (n.mode == .float) .real else .integer,
            else => .text,
        };
    }

    /// The concrete SQLite column TYPE keyword for this field ("INTEGER"/"REAL"/"TEXT"). The
    /// type *mapping* now lives in the dialect (`Dialect.sqlType`, keyed on `storageClass`);
    /// this is the SQLite-pinned accessor the existing DDL/provision call sites use unchanged,
    /// which PR-2 replaces with `dialect.sqlType(field.storageClass())` to emit Postgres types.
    pub fn sqlType(self: Field) []const u8 {
        return dialect.Dialect.sqlite.sqlType(self.storageClass());
    }

    pub fn isMultiValue(self: Field) bool {
        return switch (self.options) {
            .select => |o| o.maxSelect > 1,
            .relation => |o| o.maxSelect > 1,
            .file => |o| o.maxSelect > 1,
            else => false,
        };
    }
};

pub const CollectionType = enum { base, auth, view };

pub const Collection = struct {
    id: []const u8,
    name: []const u8,
    type: CollectionType = .base,
    system: bool = false,
    fields: []const Field,
    indexes: []const Index = &.{},
    listRule: ?[]const u8 = null,
    viewRule: ?[]const u8 = null,
    createRule: ?[]const u8 = null,
    updateRule: ?[]const u8 = null,
    deleteRule: ?[]const u8 = null,
    options: CollectionOptions = .{},
    created: []const u8 = "",
    updated: []const u8 = "",
};

pub const OAuth2Provider = struct {
    name: []const u8,
    clientId: []const u8 = "",
    clientSecret: []const u8 = "", // persisted as a "v1:" AES-GCM blob; redacted in API output
    enabled: bool = true,
    redirectUrls: []const []const u8 = &.{},
    // generic-provider overrides (ignored for presets):
    authURL: ?[]const u8 = null,
    tokenURL: ?[]const u8 = null,
    userinfoURL: ?[]const u8 = null,
    scopes: ?[]const []const u8 = null,
};

pub const OAuth2Options = struct {
    enabled: bool = false,
    providers: []const OAuth2Provider = &.{},
};

pub const RateLimitOpt = union(enum) {
    default,
    off,
    custom: struct { max: u32, window_s: i64 },
};

/// Comptime lowering of a `.rate_limit` config literal into a `RateLimitOpt`. Accepts the
/// enum-literals `.default` / `.off` or the struct form `.{ .custom = .{ .max = N, .window_s
/// = S } }`. A misshaped struct (e.g. the `.custom` wrapper forgotten) or an unknown literal
/// is a `@compileError` (loud-comptime convention) rather than a silent fallback to
/// `.default`. Shared by `provision.buildMethodsOptions` (per-auth-method limits) and
/// `events.buildRoutes` (per-route limits) so both lower `.rate_limit` identically.
pub fn buildRateLimitOpt(comptime rl: anytype) RateLimitOpt {
    const T = @TypeOf(rl);
    // Already a lowered `RateLimitOpt` (a `union(enum)`) — pass through. Without this, a
    // pre-lowered `.default`/`.off` would fall into the struct branch below where
    // `@hasField(RateLimitOpt, "custom")` is true, triggering an "access of inactive union
    // field" comptime panic on `rl.custom`.
    //
    // NOTE: the enum-literal branch below compares with `==` rather than `@tagName`
    // deliberately. Because this function also has `return rl` typed as `RateLimitOpt`
    // (the passthrough), Zig coerces a bare `.default`/`.off` enum-literal argument toward
    // the union at analysis time, after which `@tagName(rl)` no longer yields the literal's
    // name — a direct enum-literal `==` comparison is unaffected. (`@tagName` IS still safe
    // inside the unreached error `@compileError` below, which only the bad-literal path hits.)
    if (T == RateLimitOpt) return rl;
    // The struct form `.{ .custom = .{ .max = …, .window_s = … } }`: an anonymous struct
    // (NOT an enum/union), so `@tagName` would fail — match on the `custom` field instead.
    if (T != @TypeOf(.enum_literal)) {
        if (@hasField(T, "custom")) {
            const cv = rl.custom;
            return .{ .custom = .{ .max = cv.max, .window_s = cv.window_s } };
        }
        // A struct without a `custom` field is a misshaped config (e.g. forgetting the
        // `.custom` wrapper: `.{ .max = 5, .window_s = 60 }`). Fail at comptime rather than
        // silently applying `.default`.
        @compileError("rate_limit: unrecognized struct shape; expected " ++
            ".rate_limit = .{ .custom = .{ .max = N, .window_s = S } } " ++
            "(or the enum-literals .default / .off)");
    }
    // The enum-literal form `.default` / `.off`. An unknown literal (e.g. `.on`, a typo) is
    // a comptime error, not a silent `.default`.
    if (rl == .off) return .off;
    if (rl == .default) return .default;
    @compileError("rate_limit: unknown value '." ++ @tagName(rl) ++ "'; expected " ++
        ".default, .off, or .{ .custom = .{ .max = N, .window_s = S } }");
}

test "buildRateLimitOpt passes a pre-lowered RateLimitOpt through unchanged" {
    // A value that is ALREADY a `RateLimitOpt` (e.g. a const, or re-lowering) must pass
    // through — without the passthrough guard, `.default`/`.off` would hit the struct branch
    // and panic on `rl.custom` (access of inactive union field).
    const def: RateLimitOpt = .default;
    try std.testing.expect(buildRateLimitOpt(def) == .default);
    const off: RateLimitOpt = .off;
    try std.testing.expect(buildRateLimitOpt(off) == .off);
    const cust: RateLimitOpt = .{ .custom = .{ .max = 7, .window_s = 30 } };
    const out = buildRateLimitOpt(cust);
    try std.testing.expect(out == .custom);
    try std.testing.expectEqual(@as(u32, 7), out.custom.max);
    try std.testing.expectEqual(@as(i64, 30), out.custom.window_s);
    // The bare enum-literal and struct forms still lower as before.
    try std.testing.expect(buildRateLimitOpt(.default) == .default);
    try std.testing.expect(buildRateLimitOpt(.{ .custom = .{ .max = 1, .window_s = 1 } }) == .custom);
}

pub const PasswordMethodOpts = struct {
    rate_limit: RateLimitOpt = .default,
};

pub const MagicLinkMethodOpts = struct {
    ttl_s: i64 = 900,
    auto_create: bool = false,
    rate_limit: RateLimitOpt = .default,
    /// Where the GET consume+redirect endpoint sends the browser after a
    /// successful login when the request's `?redirect=` is absent or rejected
    /// by the allow-list. Must be a same-origin relative path ("/...") — an
    /// off-origin value here is treated as "/".
    redirect_default: []const u8 = "/",
    /// Allow-list of same-origin relative paths the `?redirect=` parameter may
    /// match. Each entry is an exact path OR a prefix ending in "/" (e.g.
    /// "/club/" allows "/club/anything"). Empty list ⇒ any same-origin relative
    /// path is accepted (the open-redirect guard — scheme/host rejection — still
    /// applies); a non-empty list restricts to matching paths, falling back to
    /// `redirect_default` otherwise.
    redirect_allow: []const []const u8 = &.{},
};

pub const OtpMethodOpts = struct {
    length: u8 = 6,
    ttl_s: i64 = 300,
    auto_create: bool = false,
    rate_limit: RateLimitOpt = .default,
};

pub const WebAuthnMethodOpts = struct {
    rp_id: []const u8 = "",
    rp_name: []const u8 = "",
    origin: []const u8 = "",
    credentials_collection: []const u8 = "",
    /// Require the User Verified (UV) authenticator flag on register + login.
    /// Default false (backward-compatible passkey behavior).
    require_uv: bool = false,
    rate_limit: RateLimitOpt = .default,
};

pub const MethodsOptions = struct {
    password: ?PasswordMethodOpts = null,
    magic_link: ?MagicLinkMethodOpts = null,
    otp: ?OtpMethodOpts = null,
    webauthn: ?WebAuthnMethodOpts = null,
    custom: []const []const u8 = &.{}, // slugs of .auth_methods to enable on this collection
};

pub const AuthOptions = struct {
    identityFields: []const []const u8 = &.{"email"},
    minPasswordLength: u8 = 8,
    /// When true, a login that resolves a record whose `verified` field is not true is
    /// rejected with 403 instead of minting a session. Default false (backward-compatible:
    /// no email-verification gate).
    require_verified: bool = false,
    oauth2: OAuth2Options = .{},
    methods: MethodsOptions = .{},
};
pub const CollectionOptions = struct {
    auth: AuthOptions = .{},
    /// When set, names an existing `date`/`autodate` field whose value is the row's
    /// expiry timestamp (ISO-8601 UTC). A framework-internal GC job periodically
    /// deletes rows whose ttl_field is in the past. Null = no expiry. Validated at
    /// comptime in `provision.buildCollection` (field must exist and be date/autodate).
    ttl_field: ?[]const u8 = null,
    /// When set, names an existing field whose column holds the OWNING ACCOUNT id for
    /// account-scoped multi-tenancy (#156). The engine auto-scopes every read/write of this
    /// collection to the request's active account (`tenancy.scopePredicate`, composed by
    /// `policy.zig`), stamps it on create, and rejects a cross-tenant move on update. Null = the
    /// collection is not tenant-owned (no scoping; byte-identical to the pre-tenancy engine).
    /// Validated at comptime in `provision.buildCollection` (the field must exist).
    tenant_field: ?[]const u8 = null,
    /// Relationship-based row abilities (#155): per-action declarative rules lowered from the
    /// top-level `App(.{ .abilities = ... })` config and composed into the guard stack by
    /// `policy.zig`. Null = no abilities (byte-identical to the pre-abilities engine). Persists
    /// alongside `tenant_field` so the chokepoints' DB-loaded collection carries it.
    abilities: ?@import("authz/abilities.zig").Abilities = null,
};

pub fn optionsToJson(alloc: std.mem.Allocator, c: Collection, redact: bool) ![]u8 {
    var root: ObjectMap = .empty;
    var auth: ObjectMap = .empty;
    var ids = std.json.Array.init(alloc);
    for (c.options.auth.identityFields) |f| try ids.append(.{ .string = f });
    try auth.put(alloc, "identityFields", .{ .array = ids });
    try auth.put(alloc, "minPasswordLength", .{ .integer = c.options.auth.minPasswordLength });
    try auth.put(alloc, "require_verified", .{ .bool = c.options.auth.require_verified });

    var oauth2: ObjectMap = .empty;
    try oauth2.put(alloc, "enabled", .{ .bool = c.options.auth.oauth2.enabled });
    var provs = std.json.Array.init(alloc);
    for (c.options.auth.oauth2.providers) |p| {
        var po: ObjectMap = .empty;
        try po.put(alloc, "name", .{ .string = p.name });
        try po.put(alloc, "clientId", .{ .string = p.clientId });
        try po.put(alloc, "clientSecret", .{ .string = if (redact) "" else p.clientSecret });
        try po.put(alloc, "enabled", .{ .bool = p.enabled });
        var rus = std.json.Array.init(alloc);
        for (p.redirectUrls) |u| try rus.append(.{ .string = u });
        try po.put(alloc, "redirectUrls", .{ .array = rus });
        if (p.authURL) |u| try po.put(alloc, "authURL", .{ .string = u });
        if (p.tokenURL) |u| try po.put(alloc, "tokenURL", .{ .string = u });
        if (p.userinfoURL) |u| try po.put(alloc, "userinfoURL", .{ .string = u });
        if (p.scopes) |sc| {
            var sa = std.json.Array.init(alloc);
            for (sc) |s| try sa.append(.{ .string = s });
            try po.put(alloc, "scopes", .{ .array = sa });
        }
        try provs.append(.{ .object = po });
    }
    try oauth2.put(alloc, "providers", .{ .array = provs });
    try auth.put(alloc, "oauth2", .{ .object = oauth2 });

    // Serialize methods
    var methods: ObjectMap = .empty;
    if (c.options.auth.methods.password) |pw| {
        var pw_obj: ObjectMap = .empty;
        try pw_obj.put(alloc, "rate_limit", try rateLimitToJsonAlloc(alloc, pw.rate_limit));
        try methods.put(alloc, "password", .{ .object = pw_obj });
    }
    if (c.options.auth.methods.magic_link) |ml| {
        var ml_obj: ObjectMap = .empty;
        try ml_obj.put(alloc, "ttl_s", .{ .integer = ml.ttl_s });
        try ml_obj.put(alloc, "auto_create", .{ .bool = ml.auto_create });
        try ml_obj.put(alloc, "rate_limit", try rateLimitToJsonAlloc(alloc, ml.rate_limit));
        try ml_obj.put(alloc, "redirect_default", .{ .string = ml.redirect_default });
        var allow_arr = std.json.Array.init(alloc);
        for (ml.redirect_allow) |p| try allow_arr.append(.{ .string = p });
        try ml_obj.put(alloc, "redirect_allow", .{ .array = allow_arr });
        try methods.put(alloc, "magic_link", .{ .object = ml_obj });
    }
    if (c.options.auth.methods.otp) |otp| {
        var otp_obj: ObjectMap = .empty;
        try otp_obj.put(alloc, "length", .{ .integer = @as(i64, otp.length) });
        try otp_obj.put(alloc, "ttl_s", .{ .integer = otp.ttl_s });
        try otp_obj.put(alloc, "auto_create", .{ .bool = otp.auto_create });
        try otp_obj.put(alloc, "rate_limit", try rateLimitToJsonAlloc(alloc, otp.rate_limit));
        try methods.put(alloc, "otp", .{ .object = otp_obj });
    }
    if (c.options.auth.methods.webauthn) |wa| {
        var wa_obj: ObjectMap = .empty;
        try wa_obj.put(alloc, "rp_id", .{ .string = wa.rp_id });
        try wa_obj.put(alloc, "rp_name", .{ .string = wa.rp_name });
        try wa_obj.put(alloc, "origin", .{ .string = wa.origin });
        try wa_obj.put(alloc, "credentials_collection", .{ .string = wa.credentials_collection });
        try wa_obj.put(alloc, "require_uv", .{ .bool = wa.require_uv });
        try wa_obj.put(alloc, "rate_limit", try rateLimitToJsonAlloc(alloc, wa.rate_limit));
        try methods.put(alloc, "webauthn", .{ .object = wa_obj });
    }
    if (c.options.auth.methods.custom.len > 0) {
        var custom_arr = std.json.Array.init(alloc);
        for (c.options.auth.methods.custom) |slug| try custom_arr.append(.{ .string = slug });
        try methods.put(alloc, "custom", .{ .array = custom_arr });
    }
    try auth.put(alloc, "methods", .{ .object = methods });

    try root.put(alloc, "auth", .{ .object = auth });

    if (c.options.ttl_field) |tf| {
        var ttl: ObjectMap = .empty;
        try ttl.put(alloc, "field", .{ .string = tf });
        try root.put(alloc, "ttl", .{ .object = ttl });
    }
    if (c.options.tenant_field) |tf| {
        var tenant: ObjectMap = .empty;
        try tenant.put(alloc, "field", .{ .string = tf });
        try root.put(alloc, "tenant", .{ .object = tenant });
    }
    if (c.options.abilities) |ab| {
        var abilities: ObjectMap = .empty;
        try abilityToJson(alloc, &abilities, "view", ab.view);
        try abilityToJson(alloc, &abilities, "update", ab.update);
        try abilityToJson(alloc, &abilities, "delete", ab.delete);
        try abilityToJson(alloc, &abilities, "create", ab.create);
        try root.put(alloc, "abilities", .{ .object = abilities });
    }
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

/// Serialize one ability rule under `key` into `obj` (omitted when null). Shape:
/// `"<key>": { "via": "<relation>", "min_role": "<role>" }`.
fn abilityToJson(alloc: std.mem.Allocator, obj: *ObjectMap, key: []const u8, ability: ?@import("authz/abilities.zig").Ability) !void {
    const ab = ability orelse return;
    var rule: ObjectMap = .empty;
    try rule.put(alloc, "via", .{ .string = ab.relationship.via });
    try rule.put(alloc, "min_role", .{ .string = ab.relationship.min_role });
    try obj.put(alloc, key, .{ .object = rule });
}

/// Parse one ability rule out of the `abilities` object (null when absent/malformed).
fn abilityFromJson(alloc: std.mem.Allocator, abilities: std.json.Value, key: []const u8) !?@import("authz/abilities.zig").Ability {
    const rv = abilities.object.get(key) orelse return null;
    if (rv != .object) return null;
    const via_v = rv.object.get("via") orelse return null;
    if (via_v != .string) return null;
    // `min_role` resolution, distinguishing three cases so malformed input fails CLOSED:
    //   - ABSENT  → "" (any active member qualifies; the DSL allows omitting `.min_role`).
    //   - STRING  → pass through (an unknown role already fails closed via ranking.gte → empty set).
    //   - PRESENT but NOT a string → the deny sentinel, so the ability filters out every membership
    //     (empty qualifying set → constant-false "0" → deny) instead of widening to "any member".
    const abilities_mod = @import("authz/abilities.zig");
    const min_role: []const u8 = if (rv.object.get("min_role")) |mr|
        (if (mr == .string) mr.string else abilities_mod.invalid_min_role)
    else
        "";
    return .{ .relationship = .{
        .via = try alloc.dupe(u8, via_v.string),
        .min_role = try alloc.dupe(u8, min_role),
    } };
}

fn rateLimitToJsonAlloc(alloc: std.mem.Allocator, rl: RateLimitOpt) !std.json.Value {
    var obj: ObjectMap = .empty;
    switch (rl) {
        .default => try obj.put(alloc, "mode", .{ .string = "default" }),
        .off => try obj.put(alloc, "mode", .{ .string = "off" }),
        .custom => |cv| {
            try obj.put(alloc, "mode", .{ .string = "custom" });
            try obj.put(alloc, "max", .{ .integer = @as(i64, cv.max) });
            try obj.put(alloc, "window_s", .{ .integer = cv.window_s });
        },
    }
    return .{ .object = obj };
}

pub fn optionsFromJson(alloc: std.mem.Allocator, s: []const u8) !CollectionOptions {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return .{};
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{};
    var opts = CollectionOptions{};
    // `ttl` lives at the options root (sibling of `auth`); parse it regardless of
    // whether the `auth` block is present.
    if (root.object.get("ttl")) |tv| if (tv == .object) if (tv.object.get("field")) |fv| if (fv == .string) {
        opts.ttl_field = try alloc.dupe(u8, fv.string);
    };
    // `tenant` lives at the options root (sibling of `auth`/`ttl`); parse it regardless of
    // whether the `auth` block is present.
    if (root.object.get("tenant")) |tv| if (tv == .object) if (tv.object.get("field")) |fv| if (fv == .string) {
        opts.tenant_field = try alloc.dupe(u8, fv.string);
    };
    // `abilities` lives at the options root (sibling of `auth`/`ttl`/`tenant`); #155.
    if (root.object.get("abilities")) |abv| if (abv == .object) {
        opts.abilities = .{
            .view = try abilityFromJson(alloc, abv, "view"),
            .update = try abilityFromJson(alloc, abv, "update"),
            .delete = try abilityFromJson(alloc, abv, "delete"),
            .create = try abilityFromJson(alloc, abv, "create"),
        };
    };
    const av = root.object.get("auth") orelse return opts;
    if (av != .object) return opts;
    if (av.object.get("identityFields")) |idv| if (idv == .array) {
        var list: std.ArrayList([]const u8) = .empty;
        for (idv.array.items) |it| if (it == .string) try list.append(alloc, try alloc.dupe(u8, it.string));
        if (list.items.len > 0) opts.auth.identityFields = try list.toOwnedSlice(alloc);
    };
    if (av.object.get("minPasswordLength")) |mv| if (mv == .integer) {
        opts.auth.minPasswordLength = std.math.cast(u8, mv.integer) orelse 8;
    };
    if (av.object.get("require_verified")) |rv| if (rv == .bool) {
        opts.auth.require_verified = rv.bool;
    };
    if (av.object.get("oauth2")) |ov| if (ov == .object) {
        opts.auth.oauth2.enabled = if (ov.object.get("enabled")) |ev| (ev == .bool and ev.bool) else false;
        if (ov.object.get("providers")) |pv| if (pv == .array) {
            var list: std.ArrayList(OAuth2Provider) = .empty;
            for (pv.array.items) |it| {
                if (it != .object) continue;
                const o = it.object;
                var p = OAuth2Provider{ .name = "" };
                if (o.get("name")) |x| if (x == .string) { p.name = try alloc.dupe(u8, x.string); };
                if (o.get("clientId")) |x| if (x == .string) { p.clientId = try alloc.dupe(u8, x.string); };
                if (o.get("clientSecret")) |x| if (x == .string) { p.clientSecret = try alloc.dupe(u8, x.string); };
                if (o.get("enabled")) |x| if (x == .bool) { p.enabled = x.bool; };
                if (o.get("redirectUrls")) |x| if (x == .array) {
                    var rl: std.ArrayList([]const u8) = .empty;
                    for (x.array.items) |ru| if (ru == .string) try rl.append(alloc, try alloc.dupe(u8, ru.string));
                    p.redirectUrls = try rl.toOwnedSlice(alloc);
                };
                if (o.get("authURL")) |x| if (x == .string) { p.authURL = try alloc.dupe(u8, x.string); };
                if (o.get("tokenURL")) |x| if (x == .string) { p.tokenURL = try alloc.dupe(u8, x.string); };
                if (o.get("userinfoURL")) |x| if (x == .string) { p.userinfoURL = try alloc.dupe(u8, x.string); };
                if (o.get("scopes")) |x| if (x == .array) {
                    var sl: std.ArrayList([]const u8) = .empty;
                    for (x.array.items) |sc| if (sc == .string) try sl.append(alloc, try alloc.dupe(u8, sc.string));
                    p.scopes = try sl.toOwnedSlice(alloc);
                };
                try list.append(alloc, p);
            }
            opts.auth.oauth2.providers = try list.toOwnedSlice(alloc);
        };
    };
    if (av.object.get("methods")) |mv| if (mv == .object) {
        const mo = mv.object;
        if (mo.get("password")) |pv| if (pv == .object) {
            var pw = PasswordMethodOpts{};
            if (pv.object.get("rate_limit")) |rlv| pw.rate_limit = rateLimitFromJson(rlv);
            opts.auth.methods.password = pw;
        };
        if (mo.get("magic_link")) |mlv| if (mlv == .object) {
            var ml = MagicLinkMethodOpts{};
            if (mlv.object.get("ttl_s")) |x| if (x == .integer) { ml.ttl_s = x.integer; };
            if (mlv.object.get("auto_create")) |x| if (x == .bool) { ml.auto_create = x.bool; };
            if (mlv.object.get("rate_limit")) |rlv| ml.rate_limit = rateLimitFromJson(rlv);
            if (mlv.object.get("redirect_default")) |x| if (x == .string) { ml.redirect_default = try alloc.dupe(u8, x.string); };
            if (mlv.object.get("redirect_allow")) |x| if (x == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (x.array.items) |it| if (it == .string) try list.append(alloc, try alloc.dupe(u8, it.string));
                ml.redirect_allow = try list.toOwnedSlice(alloc);
            };
            opts.auth.methods.magic_link = ml;
        };
        if (mo.get("otp")) |otpv| if (otpv == .object) {
            var otp = OtpMethodOpts{};
            if (otpv.object.get("length")) |x| if (x == .integer) { otp.length = std.math.cast(u8, x.integer) orelse 6; };
            if (otpv.object.get("ttl_s")) |x| if (x == .integer) { otp.ttl_s = x.integer; };
            if (otpv.object.get("auto_create")) |x| if (x == .bool) { otp.auto_create = x.bool; };
            if (otpv.object.get("rate_limit")) |rlv| otp.rate_limit = rateLimitFromJson(rlv);
            opts.auth.methods.otp = otp;
        };
        if (mo.get("webauthn")) |wav| if (wav == .object) {
            var wa = WebAuthnMethodOpts{};
            if (wav.object.get("rp_id")) |x| if (x == .string) { wa.rp_id = try alloc.dupe(u8, x.string); };
            if (wav.object.get("rp_name")) |x| if (x == .string) { wa.rp_name = try alloc.dupe(u8, x.string); };
            if (wav.object.get("origin")) |x| if (x == .string) { wa.origin = try alloc.dupe(u8, x.string); };
            if (wav.object.get("credentials_collection")) |x| if (x == .string) { wa.credentials_collection = try alloc.dupe(u8, x.string); };
            if (wav.object.get("require_uv")) |x| if (x == .bool) { wa.require_uv = x.bool; };
            if (wav.object.get("rate_limit")) |rlv| wa.rate_limit = rateLimitFromJson(rlv);
            opts.auth.methods.webauthn = wa;
        };
        if (mo.get("custom")) |cv| if (cv == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (cv.array.items) |it| if (it == .string) try list.append(alloc, try alloc.dupe(u8, it.string));
            opts.auth.methods.custom = try list.toOwnedSlice(alloc);
        };
    };
    return opts;
}

fn rateLimitFromJson(v: std.json.Value) RateLimitOpt {
    if (v != .object) return .default;
    const mode = v.object.get("mode") orelse return .default;
    if (mode != .string) return .default;
    if (std.mem.eql(u8, mode.string, "off")) return .off;
    if (std.mem.eql(u8, mode.string, "custom")) {
        const max: u32 = blk: {
            if (v.object.get("max")) |mx| if (mx == .integer) break :blk std.math.cast(u32, mx.integer) orelse 0;
            break :blk 0;
        };
        const window_s: i64 = blk: {
            if (v.object.get("window_s")) |ws| if (ws == .integer) break :blk ws.integer;
            break :blk 0;
        };
        return .{ .custom = .{ .max = max, .window_s = window_s } };
    }
    return .default;
}

/// Returns true if password-based authentication is enabled for the collection.
/// A collection must be of type `.auth`. Password is considered enabled if:
///   - `methods.password` is explicitly non-null, OR
///   - the whole `methods` is its default/empty value (all built-ins null and custom is empty).
/// This preserves backward-compat: an auth collection with no methods config allows password auth.
pub fn passwordEnabled(col: Collection) bool {
    if (col.type != .auth) return false;
    const m = col.options.auth.methods;
    if (m.password != null) return true;
    // whole methods is default (all built-ins null, no custom slugs) => backward compat
    const is_default = m.magic_link == null and m.otp == null and m.webauthn == null and m.custom.len == 0;
    return is_default;
}

/// Find a field by exact name (case-sensitive). Returns null if absent.
pub fn fieldByName(c: Collection, name: []const u8) ?Field {
    for (c.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

test "fieldByName finds and misses" {
    const fields = [_]Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const c = Collection{ .id = "c", .name = "posts", .fields = &fields };
    try std.testing.expect(fieldByName(c, "title") != null);
    try std.testing.expect(fieldByName(c, "missing") == null);
}

/// Names reserved by the engine (base + auth system columns); user fields may not use them.
pub fn isSystemFieldName(name: []const u8) bool {
    // case-insensitive: SQLite column names collide case-insensitively
    const reserved = [_][]const u8{ "id", "created", "updated", "email", "username", "passwordHash", "tokenKey", "verified", "token_epoch" };
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(name, r)) return true;
    return false;
}

/// The implicit system fields of an auth collection (beyond id/created/updated).
/// passwordHash/tokenKey are hidden (never serialized). Stable ids (leading '_').
pub fn authSystemFields() []const Field {
    const S = struct {
        const fields = [_]Field{
            .{ .id = "_email", .name = "email", .options = .{ .email = .{} } }, // uniqueness via partial unique index (see ddl.authIdentityIndexSql)
            .{ .id = "_username", .name = "username", .options = .{ .text = .{} } },
            .{ .id = "_pwhash", .name = "passwordHash", .hidden = true, .options = .{ .text = .{} } },
            .{ .id = "_tokkey", .name = "tokenKey", .hidden = true, .options = .{ .text = .{} } },
            .{ .id = "_verified", .name = "verified", .options = .{ .@"bool" = .{} } },
            // Session epoch for Variant A revocation (#99). Hidden (never serialized);
            // an INTEGER counter bumped by "revoke all sessions" and embedded in issued
            // `.auth` tokens. A NULL value (fresh row / pre-migration) is read as 0.
            .{ .id = "_tokepoch", .name = "token_epoch", .hidden = true, .options = .{ .number = .{ .mode = .int } } },
        };
    };
    return &S.fields;
}

/// Returns `col` with auth system fields prepended to `fields` (for auth collections);
/// base/view collections are returned unchanged. The slice is allocated from `alloc`.
pub fn injectAuthFields(alloc: std.mem.Allocator, col: Collection) !Collection {
    if (col.type != .auth) return col;
    const sys = authSystemFields();
    const out = try alloc.alloc(Field, sys.len + col.fields.len);
    @memcpy(out[0..sys.len], sys);
    @memcpy(out[sys.len..], col.fields);
    var c = col;
    c.fields = out;
    return c;
}

test "injectAuthFields prepends the auth system fields for auth collections only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user = [_]Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    const auth_col = try injectAuthFields(a, .{ .id = "c", .name = "users", .type = .auth, .fields = &user });
    try std.testing.expectEqual(@as(usize, 7), auth_col.fields.len); // 6 system + 1 user
    try std.testing.expectEqualStrings("email", auth_col.fields[0].name);
    try std.testing.expect(fieldByName(auth_col, "passwordHash").?.hidden);
    // token_epoch is a hidden system field (#99 session epoch).
    try std.testing.expect(fieldByName(auth_col, "token_epoch").?.hidden);
    const base_col = try injectAuthFields(a, .{ .id = "c", .name = "posts", .type = .base, .fields = &user });
    try std.testing.expectEqual(@as(usize, 1), base_col.fields.len);
}

pub const Collation = enum {
    binary,
    nocase,

    pub fn sqlSuffix(self: Collation) []const u8 {
        return switch (self) {
            .binary => "", // SQLite default; emit nothing to preserve existing DDL
            .nocase => " COLLATE NOCASE",
        };
    }
};

pub const Index = struct {
    name: []const u8,
    fields: []const []const u8,
    unique: bool = false,
    /// Collation applied to every indexed column (`COLLATE NOCASE` for
    /// case-insensitive lookups). `.binary` emits nothing.
    collation: Collation = .binary,
    /// Optional partial-index predicate emitted as `WHERE <where>`
    /// (e.g. `"deleted_at IS NULL"`). Raw SQL authored in the schema.
    where: ?[]const u8 = null,
};

pub const ValidationError = struct { field: []const u8, code: []const u8, message: []const u8 };

pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

/// Field types whose storage representation is a plain string and may therefore
/// carry an at-rest encryption envelope (Theme B1): text, editor, json. This is the
/// SINGLE SOURCE OF TRUTH for the encryptable set — the comptime guards
/// (provision.zig), the runtime validator (`validate` below), and the value layer
/// (field_policy.zig) all defer to it.
pub fn isEncryptableType(t: FieldType) bool {
    return t == .text or t == .editor or t == .json;
}

/// True if any field in `c` is `.encrypted`. Drives the fail-closed key checks
/// (startup guard over comptime collections; runtime collections-API guard).
pub fn hasEncryptedField(c: Collection) bool {
    for (c.fields) |f| if (f.encrypted) return true;
    return false;
}

/// The field types whose plaintext can be mirrored into an FTS5 full-text index (#157):
/// the free-text types text and editor. SINGLE SOURCE OF TRUTH for the searchable set —
/// the comptime guard (provision.zig), the runtime validator (`validate`), and the search
/// provisioner (search/fts.zig) all defer to it.
pub fn isSearchableType(t: FieldType) bool {
    return t == .text or t == .editor;
}

/// True if any field in `c` is `.searchable` (drives FTS5 index provisioning at startup).
pub fn hasSearchableField(c: Collection) bool {
    for (c.fields) |f| if (f.searchable) return true;
    return false;
}

/// Appends any validation problems to `errors`. Self-sizing; messages/codes are static or borrowed from `c`.
pub fn validate(alloc: std.mem.Allocator, c: Collection, errors: *std.ArrayList(ValidationError)) std.mem.Allocator.Error!void {
    if (!isValidIdentifier(c.name))
        try errors.append(alloc, .{ .field = "name", .code = "validation_invalid_name", .message = "Name must start with a letter and contain only letters, digits, and underscores." });
    // `_fts` is reserved: a searchable collection `posts` provisions an FTS5 shadow table named
    // `posts_fts`, so a user collection literally named `<x>_fts` could collide with `<x>`'s index
    // (CREATE VIRTUAL TABLE over an existing base table errors). Reserve the suffix outright (#157).
    if (std.mem.endsWith(u8, c.name, fts_suffix))
        try errors.append(alloc, .{ .field = "name", .code = "validation_reserved_suffix", .message = "Collection name may not end with '_fts' (reserved for full-text search index tables)." });

    for (c.fields, 0..) |f, i| {
        if (!isValidIdentifier(f.name)) {
            try errors.append(alloc, .{ .field = f.name, .code = "validation_invalid_name", .message = "Invalid field name." });
            continue;
        }
        if (isSystemFieldName(f.name)) {
            try errors.append(alloc, .{ .field = f.name, .code = "validation_reserved_name", .message = "Field name is reserved." });
        }
        for (c.fields[0..i]) |g| {
            if (std.ascii.eqlIgnoreCase(f.name, g.name))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_duplicate_name", .message = "Duplicate field name." });
        }
        // At-rest encryption constraints (Theme B1). The comptime `.collections` path
        // enforces these with @compileError; the runtime collections API (superuser
        // create/update) reaches here, so mirror them — otherwise `.encrypted` on a
        // non-string type would be SILENTLY STORED AS PLAINTEXT (the value layer only
        // encrypts the text/editor/json branches).
        if (f.encrypted) {
            if (!isEncryptableType(f.fieldType()))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_encrypted_type", .message = "Only text, editor, and json fields can be encrypted." });
            if (f.unique)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_encrypted_unique", .message = "An encrypted field cannot be unique." });
        }
        // Full-text search constraints (#157): only free-text types can be searchable, and an
        // encrypted field can never be (its stored bytes are per-row-nonce ciphertext). The
        // comptime `.collections` path enforces these with @compileError; the runtime API mirrors.
        if (f.searchable) {
            if (!isSearchableType(f.fieldType()))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_searchable_type", .message = "Only text and editor fields can be searchable." });
            if (f.encrypted)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_searchable_encrypted", .message = "An encrypted field cannot be searchable." });
        }
        switch (f.options) {
            .text => |o| if (o.pattern) |pat| {
                if (regex.compile(alloc, pat)) |prog| {
                    prog.deinit(alloc);
                } else |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    try errors.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Field pattern is not a valid regular expression." });
                }
            },
            .date => |o| {
                var min_secs: ?i64 = null;
                var max_secs: ?i64 = null;
                if (o.min) |mn| {
                    if (datetime.parse(mn)) |s| min_secs = s else |_|
                        try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date min is not a valid date." });
                }
                if (o.max) |mx| {
                    if (datetime.parse(mx)) |s| max_secs = s else |_|
                        try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date max is not a valid date." });
                }
                // Reject an unsatisfiable range: with both bounds enforced, min > max
                // would make every value fail, so the field could never accept input.
                if (min_secs) |lo| if (max_secs) |hi| if (lo > hi)
                    try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date min must not be after max." });
            },
            .select => |o| if (o.values.len == 0)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "select requires at least one value." }),
            .number => |o| if (o.mode == .fixed and (o.scale == null or o.scale.? < 1 or o.scale.? > 8))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_invalid_scale", .message = "fixed number requires scale 1..8." }),
            .relation => |o| if (o.targetCollectionId.len == 0)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "relation requires targetCollectionId." }),
            else => {},
        }
    }

    for (c.indexes) |idx| {
        if (!isValidIdentifier(idx.name))
            try errors.append(alloc, .{ .field = idx.name, .code = "validation_invalid_name", .message = "Invalid index name." });
        for (idx.fields) |fname| {
            if (!isValidIdentifier(fname))
                try errors.append(alloc, .{ .field = fname, .code = "validation_invalid_name", .message = "Invalid index field name." });
            // An encrypted column holds per-row-nonce ciphertext, so an index over it
            // is useless (every row's stored bytes differ). Reject rather than build a
            // dead index. (Comptime path enforces this with @compileError.)
            if (fieldByName(c, fname)) |fl| if (fl.encrypted)
                try errors.append(alloc, .{ .field = fname, .code = "validation_encrypted_index", .message = "Cannot index an encrypted field." });
        }
    }

    // Auth identity fields are interpolated into SQL/DDL, so they must be valid identifiers.
    if (c.type == .auth) {
        for (c.options.auth.identityFields) |idf| {
            if (!isValidIdentifier(idf))
                try errors.append(alloc, .{ .field = "identityFields", .code = "validation_invalid_identity_field", .message = "Identity field must be a valid identifier." });
        }
    }
}

// ---------------------------------------------------------------------------
// JSON (de)serialization
//
// Serialization builds a `std.json.Value` tree and calls
// `std.json.Stringify.valueAlloc`. Parsing walks the dynamic `std.json.Value`
// tree from `parseFromSlice`. Every string/array we retain is `dupe`d into the
// caller's `alloc` (expected to be an arena), so the parsed tree may be freed
// safely — we own all retained memory.
// ---------------------------------------------------------------------------

pub const ParseError = error{ InvalidSchema, UnknownFieldType, OutOfMemory };

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

fn jStr(s: []const u8) Value {
    return .{ .string = s };
}
fn jBool(b: bool) Value {
    return .{ .bool = b };
}
fn jInt(i: anytype) !Value {
    return .{ .integer = std.math.cast(i64, i) orelse return error.InvalidSchema };
}

fn putOpt(alloc: std.mem.Allocator, obj: *ObjectMap, key: []const u8, v: ?Value) !void {
    if (v) |val| try obj.put(alloc, key, val);
}

fn fieldToValue(alloc: std.mem.Allocator, f: Field) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(alloc, "id", jStr(f.id));
    try obj.put(alloc, "name", jStr(f.name));
    try obj.put(alloc, "required", jBool(f.required));
    try obj.put(alloc, "unique", jBool(f.unique));
    try obj.put(alloc, "encrypted", jBool(f.encrypted));
    try obj.put(alloc, "searchable", jBool(f.searchable));
    try obj.put(alloc, "type", jStr(@tagName(std.meta.activeTag(f.options))));

    var opts: ObjectMap = .empty;
    switch (f.options) {
        .text => |o| {
            try putOpt(alloc, &opts, "min", if (o.min) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "pattern", if (o.pattern) |x| jStr(x) else null);
        },
        .email, .url, .editor, .@"bool" => {},
        .date => |o| {
            try putOpt(alloc, &opts, "min", if (o.min) |x| jStr(x) else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| jStr(x) else null);
        },
        .autodate => |o| {
            try opts.put(alloc, "onCreate", jBool(o.onCreate));
            try opts.put(alloc, "onUpdate", jBool(o.onUpdate));
        },
        .number => |o| {
            try opts.put(alloc, "mode", jStr(@tagName(o.mode)));
            try putOpt(alloc, &opts, "scale", if (o.scale) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "min", if (o.min) |x| Value{ .float = x } else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| Value{ .float = x } else null);
        },
        .json => |o| {
            try putOpt(alloc, &opts, "maxSize", if (o.maxSize) |x| try jInt(x) else null);
        },
        .select => |o| {
            var arr = Array.init(alloc);
            for (o.values) |v| try arr.append(jStr(v));
            try opts.put(alloc, "values", .{ .array = arr });
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
        },
        .relation => |o| {
            try opts.put(alloc, "targetCollectionId", jStr(o.targetCollectionId));
            try opts.put(alloc, "cascadeDelete", jBool(o.cascadeDelete));
            try putOpt(alloc, &opts, "minSelect", if (o.minSelect) |x| try jInt(x) else null);
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
        },
        .file => |o| {
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
            try putOpt(alloc, &opts, "maxSize", if (o.maxSize) |x| try jInt(x) else null);
            if (o.mimeTypes) |mts| {
                var arr = Array.init(alloc);
                for (mts) |m| try arr.append(jStr(m));
                try opts.put(alloc, "mimeTypes", .{ .array = arr });
            }
        },
    }
    try obj.put(alloc, "options", .{ .object = opts });
    return .{ .object = obj };
}

pub fn fieldsToJson(alloc: std.mem.Allocator, fields: []const Field) ![]u8 {
    var arr = Array.init(alloc);
    for (fields) |f| try arr.append(try fieldToValue(alloc, f));
    const root = Value{ .array = arr };
    return std.json.Stringify.valueAlloc(alloc, root, .{});
}

pub fn indexesToJson(alloc: std.mem.Allocator, idx: []const Index) ![]u8 {
    var arr = Array.init(alloc);
    for (idx) |ix| {
        var obj: ObjectMap = .empty;
        try obj.put(alloc, "name", jStr(ix.name));
        var farr = Array.init(alloc);
        for (ix.fields) |fn_| try farr.append(jStr(fn_));
        try obj.put(alloc, "fields", .{ .array = farr });
        try obj.put(alloc, "unique", jBool(ix.unique));
        if (ix.collation != .binary)
            try obj.put(alloc, "collation", jStr(@tagName(ix.collation)));
        if (ix.where) |w| try obj.put(alloc, "where", jStr(w));
        try arr.append(.{ .object = obj });
    }
    return std.json.Stringify.valueAlloc(alloc, Value{ .array = arr }, .{});
}

// --- parsing helpers ---

fn objGet(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getStr(alloc: std.mem.Allocator, v: Value, key: []const u8) !?[]const u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    if (x != .string) return error.InvalidSchema;
    return try alloc.dupe(u8, x.string);
}

fn getBool(v: Value, key: []const u8, default: bool) bool {
    const x = objGet(v, key) orelse return default;
    return switch (x) {
        .bool => |b| b,
        else => default,
    };
}

fn asInt(x: Value) !i64 {
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.floor(f) == f and f >= -9.2233720368547758e18 and f < 9.2233720368547758e18)
            @intFromFloat(f)
        else
            error.InvalidSchema,
        else => error.InvalidSchema,
    };
}

fn getU32(v: Value, key: []const u8) !?u32 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u32, try asInt(x)) orelse return error.InvalidSchema;
}

fn getU32Default(v: Value, key: []const u8, default: u32) !u32 {
    return (try getU32(v, key)) orelse default;
}

fn getU8(v: Value, key: []const u8) !?u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u8, try asInt(x)) orelse return error.InvalidSchema;
}

fn getU64(v: Value, key: []const u8) !?u64 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u64, try asInt(x)) orelse return error.InvalidSchema;
}

fn getF64(v: Value, key: []const u8) !?f64 {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .null => null,
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.InvalidSchema,
    };
}

fn getStrArray(alloc: std.mem.Allocator, v: Value, key: []const u8) !?[]const []const u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    if (x != .array) return error.InvalidSchema;
    const items = x.array.items;
    const out = try alloc.alloc([]const u8, items.len);
    for (items, 0..) |it, i| {
        if (it != .string) return error.InvalidSchema;
        out[i] = try alloc.dupe(u8, it.string);
    }
    return out;
}

fn optionsFromValue(alloc: std.mem.Allocator, t: FieldType, opts: Value) !FieldOptions {
    return switch (t) {
        .text => .{ .text = .{
            .min = try getU32(opts, "min"),
            .max = try getU32(opts, "max"),
            .pattern = try getStr(alloc, opts, "pattern"),
        } },
        .email => .{ .email = .{} },
        .url => .{ .url = .{} },
        .editor => .{ .editor = .{} },
        .date => .{ .date = .{
            .min = try getStr(alloc, opts, "min"),
            .max = try getStr(alloc, opts, "max"),
        } },
        .autodate => .{ .autodate = .{
            .onCreate = getBool(opts, "onCreate", true),
            .onUpdate = getBool(opts, "onUpdate", false),
        } },
        .@"bool" => .{ .@"bool" = .{} },
        .number => blk: {
            var mode: NumberMode = .float;
            if (objGet(opts, "mode")) |m| {
                if (m == .string) mode = std.meta.stringToEnum(NumberMode, m.string) orelse return error.InvalidSchema;
            }
            break :blk .{ .number = .{
                .mode = mode,
                .scale = try getU8(opts, "scale"),
                .min = try getF64(opts, "min"),
                .max = try getF64(opts, "max"),
            } };
        },
        .json => .{ .json = .{ .maxSize = try getU32(opts, "maxSize") } },
        .select => .{ .select = .{
            .values = (try getStrArray(alloc, opts, "values")) orelse &.{},
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
        } },
        .relation => .{ .relation = .{
            .targetCollectionId = (try getStr(alloc, opts, "targetCollectionId")) orelse "",
            .cascadeDelete = getBool(opts, "cascadeDelete", false),
            .minSelect = try getU32(opts, "minSelect"),
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
        } },
        .file => .{ .file = .{
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
            .maxSize = try getU64(opts, "maxSize"),
            .mimeTypes = try getStrArray(alloc, opts, "mimeTypes"),
        } },
    };
}

fn fieldFromValue(alloc: std.mem.Allocator, v: Value) !Field {
    if (v != .object) return error.InvalidSchema;
    const id = (try getStr(alloc, v, "id")) orelse return error.InvalidSchema;
    const name = (try getStr(alloc, v, "name")) orelse return error.InvalidSchema;
    const type_v = objGet(v, "type") orelse return error.InvalidSchema;
    if (type_v != .string) return error.InvalidSchema;
    const t = std.meta.stringToEnum(FieldType, type_v.string) orelse return error.UnknownFieldType;
    const opts = objGet(v, "options") orelse Value{ .object = .empty };
    return .{
        .id = id,
        .name = name,
        .required = getBool(v, "required", false),
        .unique = getBool(v, "unique", false),
        .encrypted = getBool(v, "encrypted", false),
        .searchable = getBool(v, "searchable", false),
        .options = try optionsFromValue(alloc, t, opts),
    };
}

pub fn fieldsFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Field {
    var parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.InvalidSchema;
    const items = root.array.items;
    const out = try alloc.alloc(Field, items.len);
    for (items, 0..) |it, i| out[i] = try fieldFromValue(alloc, it);
    return out;
}

pub fn indexesFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Index {
    var parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.InvalidSchema;
    const items = root.array.items;
    const out = try alloc.alloc(Index, items.len);
    for (items, 0..) |it, i| {
        const collation: Collation = if (objGet(it, "collation")) |cv| blk: {
            if (cv == .null) break :blk .binary;
            if (cv != .string) return error.InvalidSchema;
            break :blk std.meta.stringToEnum(Collation, cv.string) orelse return error.InvalidSchema;
        } else .binary;
        out[i] = .{
            .name = (try getStr(alloc, it, "name")) orelse return error.InvalidSchema,
            .fields = (try getStrArray(alloc, it, "fields")) orelse &.{},
            .unique = getBool(it, "unique", false),
            .collation = collation,
            .where = try getStr(alloc, it, "where"),
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Collection request parse / response serialize
// ---------------------------------------------------------------------------

/// Non-allocating: returns the `.string` payload of `v.object.get(key)` if present.
fn objGetStr(v: Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn optStrValue(v: ?[]const u8) Value {
    return if (v) |s| .{ .string = s } else .null;
}
fn dupOptStr(alloc: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
    return if (v) |s| try alloc.dupe(u8, s) else null;
}

/// Parse a request body into a Collection (id left empty; create/update assign it).
pub fn parseCollectionInput(alloc: std.mem.Allocator, s: []const u8) !Collection {
    const parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit(); // everything retained is duped into `alloc` before return
    const obj = parsed.value;
    if (obj != .object) return error.InvalidSchema;

    const name = try alloc.dupe(u8, (objGetStr(obj, "name")) orelse return error.InvalidSchema);
    const ctype = std.meta.stringToEnum(CollectionType, objGetStr(obj, "type") orelse "base") orelse .base;

    const raw_fields = if (obj.object.get("fields")) |fv| blk: {
        const fs = try std.json.Stringify.valueAlloc(alloc, fv, .{});
        break :blk try fieldsFromJson(alloc, fs);
    } else &[_]Field{};
    var kept: std.ArrayList(Field) = .empty;
    for (raw_fields) |f| if (!isSystemFieldName(f.name)) try kept.append(alloc, f);
    const fields = try kept.toOwnedSlice(alloc);

    const empty_indexes: []const Index = &.{};
    const indexes = if (obj.object.get("indexes")) |iv| blk: {
        const is = try std.json.Stringify.valueAlloc(alloc, iv, .{});
        break :blk try indexesFromJson(alloc, is);
    } else empty_indexes;

    return .{
        .id = "",
        .name = name,
        .type = ctype,
        .fields = fields,
        .indexes = indexes,
        .listRule = try dupOptStr(alloc, objGetStr(obj, "listRule")),
        .viewRule = try dupOptStr(alloc, objGetStr(obj, "viewRule")),
        .createRule = try dupOptStr(alloc, objGetStr(obj, "createRule")),
        .updateRule = try dupOptStr(alloc, objGetStr(obj, "updateRule")),
        .deleteRule = try dupOptStr(alloc, objGetStr(obj, "deleteRule")),
        .options = if (obj.object.get("options")) |ov|
            try optionsFromJson(alloc, try std.json.Stringify.valueAlloc(alloc, ov, .{}))
        else
            .{},
    };
}

/// Serialize a Collection to its API JSON shape.
pub fn collectionToJson(alloc: std.mem.Allocator, c: Collection) ![]u8 {
    var root: ObjectMap = .empty;
    try root.put(alloc, "id", .{ .string = c.id });
    try root.put(alloc, "name", .{ .string = c.name });
    try root.put(alloc, "type", .{ .string = @tagName(c.type) });
    try root.put(alloc, "system", .{ .bool = c.system });
    // Embed fields/indexes as arrays by reparsing their JSON. The parse trees stay alive
    // until after Stringify reads them (defers run after the return expression evaluates).
    var visible: std.ArrayList(Field) = .empty;
    for (c.fields) |f| if (!f.hidden) try visible.append(alloc, f);
    const fields_str = try fieldsToJson(alloc, visible.items);
    const fparsed = try std.json.parseFromSlice(Value, alloc, fields_str, .{});
    defer fparsed.deinit();
    try root.put(alloc, "schema", fparsed.value);
    const idx_str = try indexesToJson(alloc, c.indexes);
    const iparsed = try std.json.parseFromSlice(Value, alloc, idx_str, .{});
    defer iparsed.deinit();
    try root.put(alloc, "indexes", iparsed.value);
    try root.put(alloc, "listRule", optStrValue(c.listRule));
    try root.put(alloc, "viewRule", optStrValue(c.viewRule));
    try root.put(alloc, "createRule", optStrValue(c.createRule));
    try root.put(alloc, "updateRule", optStrValue(c.updateRule));
    try root.put(alloc, "deleteRule", optStrValue(c.deleteRule));
    try root.put(alloc, "created", .{ .string = c.created });
    try root.put(alloc, "updated", .{ .string = c.updated });
    const oparsed = try std.json.parseFromSlice(std.json.Value, alloc, try optionsToJson(alloc, c, true), .{});
    defer oparsed.deinit();
    try root.put(alloc, "options", oparsed.value);
    return std.json.Stringify.valueAlloc(alloc, Value{ .object = root }, .{});
}

test "parseCollectionInput then collectionToJson round-trips the essentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"name":"posts","fields":[
        \\  {"id":"f1","name":"title","required":true,"type":"text","options":{}},
        \\  {"id":"f2","name":"price","type":"number","options":{"mode":"fixed","scale":2}}
        \\]}
    ;
    const col = try parseCollectionInput(a, input);
    try std.testing.expectEqualStrings("posts", col.name);
    try std.testing.expectEqual(CollectionType.base, col.type);
    try std.testing.expectEqual(@as(usize, 2), col.fields.len);
    try std.testing.expectEqualStrings("", col.id);

    var full = col;
    full.id = "abc123def456ghi";
    full.created = "2026-01-01 00:00:00";
    full.updated = "2026-01-01 00:00:00";
    const out = try collectionToJson(a, full);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"abc123def456ghi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\"") != null);
}

fn collectErrors(c: Collection) !std.ArrayList(ValidationError) {
    var list: std.ArrayList(ValidationError) = .empty;
    try validate(std.testing.allocator, c, &list);
    return list;
}

test "valid collection produces no errors" {
    const fields = [_]Field{
        .{ .id = "aaaaaaaa", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "bbbbbbbb", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    var errs = try collectErrors(.{ .id = "c1", .name = "posts", .fields = &fields });
    defer errs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

test "invalid name, reserved field, duplicate, bad scale, empty select are caught" {
    const fields = [_]Field{
        .{ .id = "a", .name = "id", .options = .{ .text = .{} } },
        .{ .id = "b", .name = "x", .options = .{ .number = .{ .mode = .fixed, .scale = null } } },
        .{ .id = "c", .name = "x", .options = .{ .text = .{} } },
        .{ .id = "d", .name = "tags", .options = .{ .select = .{ .values = &.{}, .maxSelect = 2 } } },
    };
    var errs = try collectErrors(.{ .id = "c1", .name = "1bad", .fields = &fields });
    defer errs.deinit(std.testing.allocator);
    try std.testing.expect(errs.items.len >= 5);
}

test "validate reserves the _fts collection-name suffix (#157 shadow-table collision)" {
    const fields = [_]Field{.{ .id = "a", .name = "title", .options = .{ .text = .{} } }};
    var errs = try collectErrors(.{ .id = "c1", .name = "posts_fts", .fields = &fields });
    defer errs.deinit(std.testing.allocator);
    var saw = false;
    for (errs.items) |e| if (std.mem.eql(u8, e.code, "validation_reserved_suffix")) {
        saw = true;
    };
    try std.testing.expect(saw);
    // A normal name is unaffected.
    var ok = try collectErrors(.{ .id = "c2", .name = "posts", .fields = &fields });
    defer ok.deinit(std.testing.allocator);
    for (ok.items) |e| try std.testing.expect(!std.mem.eql(u8, e.code, "validation_reserved_suffix"));
}

test "sqlType mapping" {
    const tf = Field{ .id = "a", .name = "t", .options = .{ .text = .{} } };
    const nf = Field{ .id = "b", .name = "n", .options = .{ .number = .{ .mode = .float } } };
    const nif = Field{ .id = "c", .name = "m", .options = .{ .number = .{ .mode = .int } } };
    const bf = Field{ .id = "d", .name = "b", .options = .{ .@"bool" = .{} } };
    try std.testing.expectEqualStrings("TEXT", tf.sqlType());
    try std.testing.expectEqualStrings("REAL", nf.sqlType());
    try std.testing.expectEqualStrings("INTEGER", nif.sqlType());
    try std.testing.expectEqualStrings("INTEGER", bf.sqlType());
}

test "round-trip fields through json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Field{
        .{ .id = "aaaaaaaa", .name = "title", .required = true, .options = .{ .text = .{ .max = 200 } } },
        .{ .id = "bbbbbbbb", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "cccccccc", .name = "tags", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } },
        .{ .id = "dddddddd", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .cascadeDelete = true } } },
    };
    const jsonStr = try fieldsToJson(a, &fields);
    const back = try fieldsFromJson(a, jsonStr);
    try std.testing.expectEqual(fields.len, back.len);
    try std.testing.expectEqualStrings("title", back[0].name);
    try std.testing.expect(back[0].required);
    try std.testing.expectEqual(@as(?u32, 200), back[0].options.text.max);
    try std.testing.expectEqual(NumberMode.fixed, back[1].options.number.mode);
    try std.testing.expectEqual(@as(?u8, 2), back[1].options.number.scale);
    try std.testing.expectEqual(@as(usize, 2), back[2].options.select.values.len);
    try std.testing.expectEqualStrings("a", back[2].options.select.values[0]);
    try std.testing.expectEqualStrings("b", back[2].options.select.values[1]);
    try std.testing.expectEqualStrings("users", back[3].options.relation.targetCollectionId);
    try std.testing.expect(back[3].options.relation.cascadeDelete);
}

test "searchable field flag round-trips through fieldsToJson/fieldsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Field{
        .{ .id = "aaaaaaaa", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "bbbbbbbb", .name = "slug", .options = .{ .text = .{} } }, // default: not searchable
        .{ .id = "cccccccc", .name = "body", .searchable = true, .options = .{ .editor = .{} } },
    };
    const back = try fieldsFromJson(a, try fieldsToJson(a, &fields));
    try std.testing.expect(back[0].searchable);
    try std.testing.expect(!back[1].searchable);
    try std.testing.expect(back[2].searchable);
    try std.testing.expect(hasSearchableField(.{ .id = "c", .name = "posts", .fields = &fields }));

    // A searchable flag on a non-text type, or on an encrypted field, is a validation error.
    var errs: std.ArrayList(ValidationError) = .empty;
    const bad = Collection{ .id = "c", .name = "posts", .fields = &[_]Field{
        .{ .id = "n1234567", .name = "count", .searchable = true, .options = .{ .number = .{} } },
        .{ .id = "e1234567", .name = "secret", .searchable = true, .encrypted = true, .options = .{ .text = .{} } },
    } };
    try validate(a, bad, &errs);
    var saw_type = false;
    var saw_enc = false;
    for (errs.items) |e| {
        if (std.mem.eql(u8, e.code, "validation_searchable_type")) saw_type = true;
        if (std.mem.eql(u8, e.code, "validation_searchable_encrypted")) saw_enc = true;
    }
    try std.testing.expect(saw_type);
    try std.testing.expect(saw_enc);
}

test "indexes round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const idx = [_]Index{.{ .name = "idx_title", .fields = &.{"title"}, .unique = true }};
    const s = try indexesToJson(a, &idx);
    const back = try indexesFromJson(a, s);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("idx_title", back[0].name);
    try std.testing.expect(back[0].unique);
    // defaults: no collation, no partial predicate
    try std.testing.expectEqual(Collation.binary, back[0].collation);
    try std.testing.expect(back[0].where == null);
}

test "indexes round-trip collation and where predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const idx = [_]Index{
        .{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase },
        .{ .name = "idx_active", .fields = &.{"slug"}, .unique = true, .where = "deleted_at IS NULL" },
    };
    const s = try indexesToJson(a, &idx);
    const back = try indexesFromJson(a, s);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(Collation.nocase, back[0].collation);
    try std.testing.expect(back[0].where == null);
    try std.testing.expectEqual(Collation.binary, back[1].collation);
    try std.testing.expectEqualStrings("deleted_at IS NULL", back[1].where.?);
}

test "collection options round-trip identity fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .identityFields = &.{ "email", "username" }, .minPasswordLength = 10 } } };
    const s = try optionsToJson(a, c, false);
    const back = try optionsFromJson(a, s);
    try std.testing.expectEqual(@as(usize, 2), back.auth.identityFields.len);
    try std.testing.expectEqualStrings("username", back.auth.identityFields[1]);
    try std.testing.expectEqual(@as(u8, 10), back.auth.minPasswordLength);
}

test "require_verified round-trips through optionsToJson/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // default false
    const d = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{} };
    const back_d = try optionsFromJson(a, try optionsToJson(a, d, false));
    try std.testing.expectEqual(false, back_d.auth.require_verified);
    // explicit true
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .require_verified = true } } };
    const back = try optionsFromJson(a, try optionsToJson(a, c, false));
    try std.testing.expectEqual(true, back.auth.require_verified);
}

test "ttl_field round-trips through optionsToJson/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // default: no ttl_field => omitted from JSON, parses back as null
    const d = Collection{ .id = "c", .name = "posts", .fields = &.{} };
    const back_d = try optionsFromJson(a, try optionsToJson(a, d, false));
    try std.testing.expect(back_d.ttl_field == null);
    // explicit ttl_field is emitted and parsed back
    const c = Collection{ .id = "c", .name = "posts", .fields = &.{}, .options = .{ .ttl_field = "expires_at" } };
    const s = try optionsToJson(a, c, false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"ttl\"") != null);
    const back = try optionsFromJson(a, s);
    try std.testing.expect(back.ttl_field != null);
    try std.testing.expectEqualStrings("expires_at", back.ttl_field.?);
}

test "tenant_field round-trips through optionsToJson/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // default: no tenant_field => omitted from JSON, parses back as null
    const d = Collection{ .id = "c", .name = "posts", .fields = &.{} };
    const back_d = try optionsFromJson(a, try optionsToJson(a, d, false));
    try std.testing.expect(back_d.tenant_field == null);
    // explicit tenant_field is emitted and parsed back, alongside an unrelated ttl_field
    const c = Collection{ .id = "c", .name = "posts", .fields = &.{}, .options = .{ .tenant_field = "account", .ttl_field = "expires_at" } };
    const s = try optionsToJson(a, c, false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tenant\"") != null);
    const back = try optionsFromJson(a, s);
    try std.testing.expect(back.tenant_field != null);
    try std.testing.expectEqualStrings("account", back.tenant_field.?);
    try std.testing.expectEqualStrings("expires_at", back.ttl_field.?);
}

test "abilities round-trip through optionsToJson/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // default: no abilities => omitted from JSON, parses back as null
    const d = Collection{ .id = "c", .name = "posts", .fields = &.{} };
    const back_d = try optionsFromJson(a, try optionsToJson(a, d, false));
    try std.testing.expect(back_d.abilities == null);
    // explicit per-action abilities are emitted and parsed back
    const ab = @import("authz/abilities.zig").Abilities{
        .view = .{ .relationship = .{ .via = "account" } },
        .update = .{ .relationship = .{ .via = "account", .min_role = "editor" } },
    };
    const c = Collection{ .id = "c", .name = "posts", .fields = &.{}, .options = .{ .abilities = ab } };
    const s = try optionsToJson(a, c, false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"abilities\"") != null);
    const back = (try optionsFromJson(a, s)).abilities.?;
    try std.testing.expectEqualStrings("account", back.view.?.relationship.via);
    try std.testing.expectEqualStrings("", back.view.?.relationship.min_role);
    try std.testing.expectEqualStrings("editor", back.update.?.relationship.min_role);
    try std.testing.expect(back.delete == null and back.create == null);
}

test "abilities deserialization fails closed on a malformed (non-string) min_role" {
    const abilities_mod = @import("authz/abilities.zig");
    const request = @import("request.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = Collection{ .id = "c", .name = "posts", .fields = &.{} };
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "owner" }}; // a top-rank member
    const rctx = request.RequestContext{ .memberships = &mem };

    // `min_role` PRESENT but a number (malformed): must NOT widen to "any member" — it parses to the
    // deny sentinel so even a top-rank member is filtered out → constant-false "0" → deny.
    const bad = (try optionsFromJson(a, "{\"abilities\":{\"view\":{\"via\":\"account\",\"min_role\":3}}}")).abilities.?.view.?;
    try std.testing.expectEqualStrings(abilities_mod.invalid_min_role, bad.relationship.min_role);
    const pbad = (try abilities_mod.abilityPredicate(a, col, bad, &rctx, dialect.Dialect.sqlite)).?;
    try std.testing.expectEqualStrings("0", pbad.sql);

    // Control — `min_role` ABSENT still means "any active member qualifies" (a real IN predicate,
    // not a deny). This is the legitimate omit-the-floor case and must stay green.
    const ok = (try optionsFromJson(a, "{\"abilities\":{\"view\":{\"via\":\"account\"}}}")).abilities.?.view.?;
    try std.testing.expectEqualStrings("", ok.relationship.min_role);
    const pok = (try abilities_mod.abilityPredicate(a, col, ok, &rctx, dialect.Dialect.sqlite)).?;
    try std.testing.expectEqualStrings("\"posts\".\"account\" IN (?)", pok.sql);
}

test "validate rejects an auth collection with a non-identifier identity field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var errs: std.ArrayList(ValidationError) = .empty;
    const c = Collection{
        .id = "c", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .identityFields = &.{ "email", "x\") WHERE 1=1; --" } } },
    };
    try validate(a, c, &errs);
    var found = false;
    for (errs.items) |e| if (std.mem.eql(u8, e.code, "validation_invalid_identity_field")) {
        found = true;
    };
    try std.testing.expect(found);
}

test "validate accepts an auth collection with valid identity fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var errs: std.ArrayList(ValidationError) = .empty;
    const c = Collection{
        .id = "c", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .identityFields = &.{ "email", "username" } } },
    };
    try validate(a, c, &errs);
    for (errs.items) |e| try std.testing.expect(!std.mem.eql(u8, e.code, "validation_invalid_identity_field"));
}

test "oauth2 options round-trip through optionsToJson(false)/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:blob", .enabled = true, .redirectUrls = &.{"https://app/cb"} }};
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const s = try optionsToJson(a, c, false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientSecret\":\"v1:blob\"") != null);
    const back = try optionsFromJson(a, s);
    try std.testing.expectEqual(true, back.auth.oauth2.enabled);
    try std.testing.expectEqual(@as(usize, 1), back.auth.oauth2.providers.len);
    try std.testing.expectEqualStrings("cid", back.auth.oauth2.providers[0].clientId);
    try std.testing.expectEqualStrings("v1:blob", back.auth.oauth2.providers[0].clientSecret);
    try std.testing.expectEqualStrings("https://app/cb", back.auth.oauth2.providers[0].redirectUrls[0]);
}

test "validate rejects an uncompilable pattern and an unparseable date bound" {
    var errs: std.ArrayList(ValidationError) = .empty;
    defer errs.deinit(std.testing.allocator);
    const fields = [_]Field{
        .{ .id = "f1", .name = "slug", .options = .{ .text = .{ .pattern = "(" } } },
        .{ .id = "f2", .name = "when", .options = .{ .date = .{ .min = "nope" } } },
    };
    const c = Collection{ .id = "c", .name = "things", .fields = &fields };
    try validate(std.testing.allocator, c, &errs);
    var saw_pattern = false;
    var saw_date = false;
    for (errs.items) |e| {
        if (std.mem.eql(u8, e.code, "validation_pattern")) saw_pattern = true;
        if (std.mem.eql(u8, e.code, "validation_date")) saw_date = true;
    }
    try std.testing.expect(saw_pattern);
    try std.testing.expect(saw_date);
}

test "validate rejects a date field whose min is after max" {
    var errs: std.ArrayList(ValidationError) = .empty;
    defer errs.deinit(std.testing.allocator);
    const fields = [_]Field{
        .{ .id = "f1", .name = "when", .options = .{ .date = .{ .min = "2026-12-31", .max = "2026-01-01" } } },
    };
    const c = Collection{ .id = "c", .name = "things", .fields = &fields };
    try validate(std.testing.allocator, c, &errs);
    var saw_date = false;
    for (errs.items) |e| {
        if (std.mem.eql(u8, e.code, "validation_date")) saw_date = true;
    }
    try std.testing.expect(saw_date);
}

test "optionsToJson(true) redacts clientSecret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:blob", .redirectUrls = &.{} }};
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const s = try optionsToJson(a, c, true);
    try std.testing.expect(std.mem.indexOf(u8, s, "v1:blob") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientSecret\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientId\":\"cid\"") != null);
}

test "collectionToJson redacts oauth2 clientSecret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:topsecret", .redirectUrls = &.{} }};
    const c = Collection{ .id = "id1", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const out = try collectionToJson(a, c);
    try std.testing.expect(std.mem.indexOf(u8, out, "topsecret") == null);
}

test "AuthOptions.methods serializes + parses (magic_link ttl, password default)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const allow = [_][]const u8{ "/club/", "/dashboard" };
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .methods = .{
        .password = .{},
        .magic_link = .{ .ttl_s = 1200, .auto_create = true, .redirect_default = "/club/welcome", .redirect_allow = &allow },
    } } } };
    const json = try optionsToJson(a, c, false);
    const back = try optionsFromJson(a, json);
    try std.testing.expect(back.auth.methods.password != null);
    try std.testing.expect(back.auth.methods.magic_link != null);
    try std.testing.expectEqual(@as(i64, 1200), back.auth.methods.magic_link.?.ttl_s);
    try std.testing.expect(back.auth.methods.magic_link.?.auto_create);
    // redirect_default + redirect_allow survive the JSON round-trip (key names + list handling).
    try std.testing.expectEqualStrings("/club/welcome", back.auth.methods.magic_link.?.redirect_default);
    try std.testing.expectEqual(@as(usize, 2), back.auth.methods.magic_link.?.redirect_allow.len);
    try std.testing.expectEqualStrings("/club/", back.auth.methods.magic_link.?.redirect_allow[0]);
    try std.testing.expectEqualStrings("/dashboard", back.auth.methods.magic_link.?.redirect_allow[1]);
}

test "AuthOptions.methods custom slugs round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slugs = [_][]const u8{ "sso_saml", "passkey_corp" };
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .methods = .{
        .custom = &slugs,
    } } } };
    const json = try optionsToJson(a, c, false);
    const back = try optionsFromJson(a, json);
    try std.testing.expectEqual(@as(usize, 2), back.auth.methods.custom.len);
    try std.testing.expectEqualStrings("sso_saml", back.auth.methods.custom[0]);
    try std.testing.expectEqualStrings("passkey_corp", back.auth.methods.custom[1]);
}

test "passwordEnabled backward compat and explicit opt-in" {
    const base_col = Collection{ .id = "c", .name = "posts", .type = .base, .fields = &.{} };
    try std.testing.expect(!passwordEnabled(base_col));
    // auth collection with no methods config => password enabled (backward compat)
    const auth_col_default = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{} };
    try std.testing.expect(passwordEnabled(auth_col_default));
    // auth collection with explicit password opt-in
    const auth_col_pw = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .methods = .{ .password = .{} } } } };
    try std.testing.expect(passwordEnabled(auth_col_pw));
    // auth collection with only magic_link (no password) => not enabled
    const auth_col_ml = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .methods = .{ .magic_link = .{} } } } };
    try std.testing.expect(!passwordEnabled(auth_col_ml));
}
