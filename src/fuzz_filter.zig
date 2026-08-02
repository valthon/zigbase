//! Coverage-guided fuzz target for the filter lexer and parser.

const std = @import("std");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");

const max_input = 4096;

fn fuzzInput(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [max_input]u8 = undefined;
    const len = smith.sliceWithHash(&input_buf, @src().line);
    const input = input_buf[0..len];

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const toks = lexer.lex(alloc, input) catch return;
    defer lexer.freeTokens(alloc, input, toks);
    const root = parser.parse(alloc, toks) catch return;
    defer parser.freeNode(alloc, root);
}

test "fuzz filter lexer and parser" {
    try std.testing.fuzz({}, fuzzInput, .{ .corpus = &.{
        "title = 'hello' && score >= 10",
        "status in ('draft', 'published')",
        "name = 'escaped\\nvalue'",
        "",
    } });
}
