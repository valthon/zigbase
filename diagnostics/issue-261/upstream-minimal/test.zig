const std = @import("std");

test "pass" {
    try std.testing.expect(!@import("repro_options").fail_test);
}
