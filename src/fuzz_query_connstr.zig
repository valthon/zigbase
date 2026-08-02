//! Coverage-guided fuzz target for URL queries and PostgreSQL connection strings.

const std = @import("std");
const query_params = @import("query/params.zig");
const connstr = @import("backend/postgres/connstr.zig");

const max_input = 4096;

fn fuzzInput(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [max_input]u8 = undefined;
    const len = smith.sliceWithHash(&input_buf, @src().line);
    const input = input_buf[0..len];

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    if (query_params.parse(alloc, input)) |params| {
        params.deinit(alloc);
    } else |_| {}

    if (connstr.parse(alloc, input)) |parsed| {
        var cfg = parsed;
        cfg.deinit();
    } else |_| {}
}

test "fuzz query parameters and PostgreSQL connection strings" {
    try std.testing.fuzz({}, fuzzInput, .{ .corpus = &.{
        "filter=name%3D%22x%22&q=a+b",
        "postgres://user:pass@localhost:5432/db?sslmode=verify-full",
        "postgresql://u%40x:p%25@[::1]/d?sslrootcert=%2Ftmp%2Fca.pem",
        "",
    } });
}
