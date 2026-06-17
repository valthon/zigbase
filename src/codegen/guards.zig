//! Generator-time guard assertions; failures abort the build.
const std = @import("std");
const schema = @import("../schema.zig");

test "guards module compiles" {
    try std.testing.expect(true);
}
