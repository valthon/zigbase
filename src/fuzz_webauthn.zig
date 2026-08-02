//! Coverage-guided fuzz target for WebAuthn CBOR, COSE, and authenticator data.

const std = @import("std");
const authdata = @import("auth/webauthn/authdata.zig");
const cose = @import("auth/webauthn/cose.zig");

const max_input = 4096;

fn fuzzInput(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [max_input]u8 = undefined;
    const len = smith.sliceWithHash(&input_buf, @src().line);
    const input = input_buf[0..len];

    _ = cose.parseCoseKey(input) catch {};
    _ = authdata.parse(input) catch {};
}

test "fuzz WebAuthn CBOR, COSE, and authenticator data" {
    try std.testing.fuzz({}, fuzzInput, .{ .corpus = &.{
        "\xa5\x01\x02\x03\x26\x20\x01\x21\x58\x20",
        "\xbf\xff",
        "\x9f\xff",
        "",
    } });
}
