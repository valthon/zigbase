//! TypeScript identifier helpers (camelCase, PascalCase, sanitization).
const std = @import("std");
const schema = @import("../schema.zig");

/// Convert a snake_case or plural collection name to a singular PascalCase record name.
/// e.g. "posts" -> "Post", "blog_posts" -> "BlogPost", "users" -> "User".
/// Simple heuristic: strip trailing 's' if present (but not 'ss'), then PascalCase.
pub fn recordName(alloc: std.mem.Allocator, col_name: []const u8) ![]const u8 {
    // Singularize: strip trailing 's' unless the word ends in 'ss'
    const singular = blk: {
        if (col_name.len > 1 and col_name[col_name.len - 1] == 's' and col_name[col_name.len - 2] != 's') {
            break :blk col_name[0 .. col_name.len - 1];
        }
        break :blk col_name;
    };
    return pascal(alloc, singular);
}

/// Convert a snake_case or lower_underscore string to PascalCase.
/// e.g. "status" -> "Status", "field_name" -> "FieldName", "myField" -> "MyField".
pub fn pascal(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var cap_next = true;
    for (name) |ch| {
        if (ch == '_') {
            cap_next = true;
            continue;
        }
        if (cap_next) {
            try buf.append(alloc, std.ascii.toUpper(ch));
            cap_next = false;
        } else {
            try buf.append(alloc, ch);
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Convert a string to camelCase.
/// e.g. "field_name" -> "fieldName", "MyField" -> "myField".
pub fn camel(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const p = try pascal(alloc, name);
    if (p.len == 0) return p;
    const result = try alloc.dupe(u8, p);
    result[0] = std.ascii.toLower(result[0]);
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pascal converts snake_case and simple names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Status", try pascal(a, "status"));
    try std.testing.expectEqualStrings("FieldName", try pascal(a, "field_name"));
    try std.testing.expectEqualStrings("BlogPost", try pascal(a, "blog_post"));
}

test "recordName singularizes and pascal-cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Post", try recordName(a, "posts"));
    try std.testing.expectEqualStrings("User", try recordName(a, "users"));
    try std.testing.expectEqualStrings("BlogPost", try recordName(a, "blog_posts"));
}

test "camel converts names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("status", try camel(a, "status"));
    try std.testing.expectEqualStrings("fieldName", try camel(a, "field_name"));
}
