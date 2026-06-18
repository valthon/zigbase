//! Comptime Zig-type → TypeScript emitter for route I/O types.
//!
//! Supported subset: void, bool, int, float, []const u8 (string), std.json.Value
//! (unknown), optional (?T → T | null), slices ([]T → T[]), plain structs,
//! plain enums. Anything else → @compileError at build time.
//!
//! Public surface:
//!   tsName(T)           — short TS identifier for a named struct/enum
//!   isRepresentable(T)  — true iff T is in the bounded subset
//!   tsForType(T)        — inline TS type expression for T
//!   renderNamedDecls(T) — appends export interface / export type declarations
const std = @import("std");
const json = std.json;

/// The TS identifier for a named struct/enum: its short (last-segment) Zig type name.
pub fn tsName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // @typeName is fully qualified (e.g. "module.Outer"); take the last '.'-segment.
    return comptime blk: {
        var last: []const u8 = full;
        var it = std.mem.splitScalar(u8, full, '.');
        while (it.next()) |seg| last = seg;
        break :blk last;
    };
}

/// Bounded Zig→TS subset predicate (mirrors route_types.assertRepresentable's walk).
pub fn isRepresentable(comptime T: type) bool {
    if (T == void or T == std.json.Value) return true;
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |o| isRepresentable(o.child),
        .pointer => |p| p.size == .slice and (p.child == u8 or isRepresentable(p.child)),
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (!isRepresentable(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Inline TS type expression for T. Named structs/enums return their tsName.
pub fn tsForType(comptime T: type) []const u8 {
    if (T == void) return "void";
    if (T == std.json.Value) return "unknown";
    if (T == []const u8) return "string";
    return comptime switch (@typeInfo(T)) {
        .int, .float => "number",
        .bool => "boolean",
        .@"enum" => tsName(T),
        .@"struct" => tsName(T),
        .optional => |o| tsForType(o.child) ++ " | null",
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("rpc: unsupported pointer type " ++ @typeName(T));
            if (p.child == u8) break :blk "string";
            break :blk tsForType(p.child) ++ "[]";
        },
        else => @compileError("rpc: unsupported type " ++ @typeName(T)),
    };
}

/// Append `export interface`/`export type` declarations for every named struct/enum
/// reachable from T, dependencies first, deduplicated by tsName.
pub fn renderNamedDecls(comptime T: type, w: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    try renderNamedDeclsInner(T, w, alloc, &seen);
}

fn renderNamedDeclsInner(comptime T: type, w: *std.ArrayList(u8), alloc: std.mem.Allocator, seen: *std.StringHashMap(void)) !void {
    switch (@typeInfo(T)) {
        .optional => |o| try renderNamedDeclsInner(o.child, w, alloc, seen),
        .pointer => |p| if (p.size == .slice and p.child != u8) try renderNamedDeclsInner(p.child, w, alloc, seen),
        .@"enum" => |e| {
            const nm = tsName(T);
            if (seen.contains(nm)) return;
            try seen.put(nm, {});
            try w.appendSlice(alloc, "export type ");
            try w.appendSlice(alloc, nm);
            try w.appendSlice(alloc, " = ");
            inline for (e.fields, 0..) |f, i| {
                if (i != 0) try w.appendSlice(alloc, " | ");
                try w.appendSlice(alloc, "\"");
                try w.appendSlice(alloc, f.name);
                try w.appendSlice(alloc, "\"");
            }
            try w.appendSlice(alloc, ";\n");
        },
        .@"struct" => |s| {
            const nm = tsName(T);
            if (seen.contains(nm)) return;
            try seen.put(nm, {}); // mark before recursing so cycles terminate
            // emit dependencies first
            inline for (s.fields) |f| try renderNamedDeclsInner(f.type, w, alloc, seen);
            // now emit this struct's interface
            try w.appendSlice(alloc, "export interface ");
            try w.appendSlice(alloc, nm);
            try w.appendSlice(alloc, " {\n");
            inline for (s.fields) |f| {
                try w.appendSlice(alloc, "  ");
                try w.appendSlice(alloc, f.name);
                try w.appendSlice(alloc, ": ");
                try w.appendSlice(alloc, tsForType(f.type));
                try w.appendSlice(alloc, ";\n");
            }
            try w.appendSlice(alloc, "}\n");
        },
        else => {}, // scalars/void/json.Value contribute no named decls
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tsForType scalars" {
    try std.testing.expectEqualStrings("number", tsForType(i64));
    try std.testing.expectEqualStrings("number", tsForType(u32));
    try std.testing.expectEqualStrings("number", tsForType(f64));
    try std.testing.expectEqualStrings("boolean", tsForType(bool));
    try std.testing.expectEqualStrings("string", tsForType([]const u8));
    try std.testing.expectEqualStrings("unknown", tsForType(json.Value));
    try std.testing.expectEqualStrings("void", tsForType(void));
}

test "tsForType optional and slice" {
    try std.testing.expectEqualStrings("string | null", tsForType(?[]const u8));
    try std.testing.expectEqualStrings("number | null", tsForType(?i32));
    try std.testing.expectEqualStrings("number[]", tsForType([]const i32));
}

const Color = enum { red, green, blue };
const Inner = struct { tag: []const u8, n: i32 };
const Outer = struct { name: []const u8, color: Color, inner: Inner, maybe: ?bool, nums: []const i64 };

test "tsForType named struct/enum returns the name" {
    try std.testing.expectEqualStrings("Color", tsForType(Color));
    try std.testing.expectEqualStrings("Outer", tsForType(Outer));
}

test "renderNamedDecls emits interfaces and unions, deps first, deduped" {
    const a = std.testing.allocator;
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(a);
    try renderNamedDecls(Outer, &w, a);
    const out = w.items;
    // enum → string-literal union
    try std.testing.expect(std.mem.indexOf(u8, out, "export type Color = \"red\" | \"green\" | \"blue\";") != null);
    // nested struct interface present
    try std.testing.expect(std.mem.indexOf(u8, out, "export interface Inner {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tag: string;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "n: number;") != null);
    // outer interface references named members and renders optional/array/null
    try std.testing.expect(std.mem.indexOf(u8, out, "export interface Outer {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "color: Color;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "inner: Inner;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "maybe: boolean | null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nums: number[];") != null);
    // dependency ordering: Inner before Outer
    try std.testing.expect(std.mem.indexOf(u8, out, "interface Inner").? < std.mem.indexOf(u8, out, "interface Outer").?);
}

test "isRepresentable rejects unsupported" {
    try std.testing.expect(isRepresentable(Outer));
    try std.testing.expect(!isRepresentable(union(enum) { a: i32, b: bool }));
    try std.testing.expect(!isRepresentable(*i32)); // bare single-item pointer (non-slice)
}
