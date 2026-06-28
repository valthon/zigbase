//! Comptime feature-flag + experiment registry (0.8.0, #128/#129/#130).
//!
//! A consumer declares flags and experiments in the `App(cfg)` literal:
//!
//! ```zig
//! App(.{
//!   .flags = .{
//!     .checkout_enabled = true,                                   // bare bool default
//!     .new_dashboard    = .{ .default = false, .description = "…" }, // struct form
//!   },
//!   .experiments = .{
//!     .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 50, 50 } },
//!   },
//! })
//! ```
//!
//! `flagMeta` / `experimentMeta` reflect those literals into `[]const FlagDef` /
//! `[]const ExperimentDef` (mirrors `events.customAuthMeta`), with every malformed
//! declaration a loud `@compileError` (loud-comptime convention). `EnumFromFields`
//! generates the `Flag` / `Experiment` enums whose members are the declared names —
//! so `App.flag(ctx, .typo)` is a real compile error, not a runtime miss.
//!
//! Resolution (override-vs-default, deterministic bucketing) lives in the pure
//! `features_resolver.zig`; this file is comptime metadata only (imports `std` only,
//! so it can be referenced from `app.zig` without an import cycle).

const std = @import("std");

/// One declared boolean flag. `default` is returned when no `_kv` override
/// (`flag:<name>`) is present.
pub const FlagDef = struct {
    name: []const u8,
    default: bool,
    description: []const u8 = "",
};

/// One declared A/B/n experiment. `variants` and `weights` are parallel and equal
/// length; `weights` need not sum to 100 (they are scaled to a 256-bucket space).
/// `sticky` (assignment persistence) is honored from PR2 onward; PR1 resolves by
/// pure deterministic hash regardless of the flag.
pub const ExperimentDef = struct {
    name: []const u8,
    variants: []const []const u8,
    weights: []const u16,
    sticky: bool = false,
    description: []const u8 = "",
};

/// The lowered registry threaded into the runtime app (`app.features`).
pub const Registry = struct {
    flags: []const FlagDef = &.{},
    experiments: []const ExperimentDef = &.{},
};

/// True for a comptime type that represents a string: `[]const u8` (slice) or a
/// string-literal `*const [N:0]u8` (pointer-to-array).
fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Reflect a `.flags` config literal into `[]const FlagDef`. Each field is either a
/// bare `bool` (shorthand default) or a struct `.{ .default = bool, .description = "" }`.
/// `@compileError`s (loud-comptime) on a non-bool/non-struct value, an unknown sub-key,
/// a non-bool `.default`, or a non-string `.description`.
pub fn flagMeta(comptime flags_cfg: anytype) []const FlagDef {
    comptime {
        const T = @TypeOf(flags_cfg);
        if (@typeInfo(T) != .@"struct")
            @compileError(".flags must be a struct literal of flag declarations");
        var list: []const FlagDef = &.{};
        for (std.meta.fields(T)) |f| {
            const name = f.name;
            const spec = @field(flags_cfg, name);
            const ST = @TypeOf(spec);
            if (ST == bool) {
                list = list ++ &[_]FlagDef{.{ .name = name, .default = spec }};
                continue;
            }
            if (@typeInfo(ST) != .@"struct")
                @compileError("flag '" ++ name ++ "' must be a bool (shorthand default) or a struct '.{ .default = <bool>, .description = \"…\" }'");
            // Loud-comptime: reject typo'd sub-keys.
            for (std.meta.fields(ST)) |sf| {
                if (!std.mem.eql(u8, sf.name, "default") and !std.mem.eql(u8, sf.name, "description"))
                    @compileError("flag '" ++ name ++ "': unknown key '." ++ sf.name ++ "' (recognized keys: .default, .description)");
            }
            if (!@hasField(ST, "default"))
                @compileError("flag '" ++ name ++ "': struct form requires a .default = <bool>");
            if (@TypeOf(spec.default) != bool)
                @compileError("flag '" ++ name ++ "': .default must be a bool");
            var def = FlagDef{ .name = name, .default = spec.default };
            if (@hasField(ST, "description")) {
                if (!isStringType(@TypeOf(spec.description)))
                    @compileError("flag '" ++ name ++ "': .description must be a string");
                def.description = spec.description;
            }
            list = list ++ &[_]FlagDef{def};
        }
        return list;
    }
}

/// Reflect a `.experiments` config literal into `[]const ExperimentDef`. Each field is a
/// struct `.{ .variants = .{…}, .weights = .{…}, .sticky = false, .description = "" }`.
/// `@compileError`s (loud-comptime) on: a non-struct value; an unknown sub-key; a missing
/// `.variants`/`.weights`; a non-string variant; `variants.len != weights.len`; empty
/// variants; duplicate variant names; all-zero weights; a non-string `.description`;
/// a non-bool `.sticky`.
pub fn experimentMeta(comptime exps_cfg: anytype) []const ExperimentDef {
    comptime {
        const T = @TypeOf(exps_cfg);
        if (@typeInfo(T) != .@"struct")
            @compileError(".experiments must be a struct literal of experiment declarations");
        var list: []const ExperimentDef = &.{};
        for (std.meta.fields(T)) |f| {
            const name = f.name;
            const spec = @field(exps_cfg, name);
            const ST = @TypeOf(spec);
            if (@typeInfo(ST) != .@"struct")
                @compileError("experiment '" ++ name ++ "' must be a struct '.{ .variants = .{…}, .weights = .{…} }'");
            for (std.meta.fields(ST)) |sf| {
                if (!std.mem.eql(u8, sf.name, "variants") and
                    !std.mem.eql(u8, sf.name, "weights") and
                    !std.mem.eql(u8, sf.name, "sticky") and
                    !std.mem.eql(u8, sf.name, "description"))
                    @compileError("experiment '" ++ name ++ "': unknown key '." ++ sf.name ++ "' (recognized keys: .variants, .weights, .sticky, .description)");
            }
            if (!@hasField(ST, "variants"))
                @compileError("experiment '" ++ name ++ "': requires .variants = .{ \"v1\", \"v2\", … }");
            if (!@hasField(ST, "weights"))
                @compileError("experiment '" ++ name ++ "': requires .weights = .{ n1, n2, … } (parallel to .variants)");

            // Lower the .variants tuple → []const []const u8.
            var variants: []const []const u8 = &.{};
            const VT = @TypeOf(spec.variants);
            if (@typeInfo(VT) != .@"struct")
                @compileError("experiment '" ++ name ++ "': .variants must be a tuple of strings");
            for (std.meta.fields(VT)) |vf| {
                const v = @field(spec.variants, vf.name);
                if (!isStringType(@TypeOf(v)))
                    @compileError("experiment '" ++ name ++ "': every variant must be a string");
                variants = variants ++ &[_][]const u8{v};
            }
            if (variants.len == 0)
                @compileError("experiment '" ++ name ++ "': .variants must declare at least one variant");

            // Lower the .weights tuple → []const u16.
            var weights: []const u16 = &.{};
            const WT = @TypeOf(spec.weights);
            if (@typeInfo(WT) != .@"struct")
                @compileError("experiment '" ++ name ++ "': .weights must be a tuple of integers");
            for (std.meta.fields(WT)) |wf| {
                const w = @field(spec.weights, wf.name);
                weights = weights ++ &[_]u16{@as(u16, w)};
            }

            if (variants.len != weights.len)
                @compileError("experiment '" ++ name ++ "': .variants and .weights must have the same length");

            // Duplicate variant names.
            for (variants, 0..) |a, ai| {
                for (variants, 0..) |b, bi| {
                    if (ai < bi and std.mem.eql(u8, a, b))
                        @compileError("experiment '" ++ name ++ "': duplicate variant '" ++ a ++ "'");
                }
            }
            // All-zero weights.
            var total: u64 = 0;
            for (weights) |w| total += w;
            if (total == 0)
                @compileError("experiment '" ++ name ++ "': .weights must not all be zero");

            var def = ExperimentDef{ .name = name, .variants = variants, .weights = weights };
            if (@hasField(ST, "sticky")) {
                if (@TypeOf(spec.sticky) != bool)
                    @compileError("experiment '" ++ name ++ "': .sticky must be a bool");
                def.sticky = spec.sticky;
            }
            if (@hasField(ST, "description")) {
                if (!isStringType(@TypeOf(spec.description)))
                    @compileError("experiment '" ++ name ++ "': .description must be a string");
                def.description = spec.description;
            }
            list = list ++ &[_]ExperimentDef{def};
        }
        return list;
    }
}

/// Generate an exhaustive enum whose members are the field names of `cfg_struct`
/// (in declaration order). Used for `App.Flag` / `App.Experiment`: a typo'd `.name`
/// at a call site is a compile error, and `@intFromEnum` indexes the parallel
/// `flagMeta`/`experimentMeta` slice (same iteration order). An empty literal
/// yields an empty enum (tag type `u0`).
pub fn EnumFromFields(comptime cfg_struct: anytype) type {
    const fields = std.meta.fields(@TypeOf(cfg_struct));
    const IntTag = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1);
    var names: [fields.len][:0]const u8 = undefined;
    var values: [fields.len]IntTag = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        values[i] = @intCast(i);
    }
    const frozen_names = names;
    const frozen_values = values;
    return @Enum(IntTag, .exhaustive, &frozen_names, &frozen_values);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "flagMeta lowers bare-bool and struct forms" {
    const defs = comptime flagMeta(.{
        .checkout_enabled = true,
        .new_dashboard = .{ .default = false, .description = "Ship dark" },
    });
    try std.testing.expectEqual(@as(usize, 2), defs.len);
    try std.testing.expectEqualStrings("checkout_enabled", defs[0].name);
    try std.testing.expect(defs[0].default);
    try std.testing.expectEqualStrings("", defs[0].description);
    try std.testing.expectEqualStrings("new_dashboard", defs[1].name);
    try std.testing.expect(!defs[1].default);
    try std.testing.expectEqualStrings("Ship dark", defs[1].description);
}

test "flagMeta on empty literal yields no flags" {
    const defs = comptime flagMeta(.{});
    try std.testing.expectEqual(@as(usize, 0), defs.len);
}

test "experimentMeta lowers variants/weights/sticky/description" {
    const defs = comptime experimentMeta(.{
        .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 90, 10 }, .sticky = true, .description = "layout test" },
    });
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    const e = defs[0];
    try std.testing.expectEqualStrings("checkout_layout", e.name);
    try std.testing.expectEqual(@as(usize, 2), e.variants.len);
    try std.testing.expectEqualStrings("control", e.variants[0]);
    try std.testing.expectEqualStrings("compact", e.variants[1]);
    try std.testing.expectEqual(@as(u16, 90), e.weights[0]);
    try std.testing.expectEqual(@as(u16, 10), e.weights[1]);
    try std.testing.expect(e.sticky);
    try std.testing.expectEqualStrings("layout test", e.description);
}

test "EnumFromFields generates members in declaration order" {
    const Flag = EnumFromFields(.{ .a = true, .b = false, .c = true });
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(Flag).len);
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(@field(Flag, "a")));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(@field(Flag, "b")));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(@field(Flag, "c")));

    const Empty = EnumFromFields(.{});
    try std.testing.expectEqual(@as(usize, 0), std.meta.fields(Empty).len);
}
