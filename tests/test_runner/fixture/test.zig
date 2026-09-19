const std = @import("std");

test "runner contract" {
    switch (@import("repro_options").case) {
        .assertion => try std.testing.expect(false),
        .leak => {
            // Deliberate leak: both runners must reject the successful test body.
            _ = try std.testing.allocator.alloc(u8, 16);
        },
        .error_log => std.log.err("runner-contract-error", .{}),
        .skip => return error.SkipZigTest,
        else => {},
    }
}
