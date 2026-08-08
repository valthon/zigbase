const std = @import("std");
const zigbase = @import("zigbase");

extern fn fio_is_master() c_int;

test "linked zigbase test without harness boot" {
    // Reference the public HTTP surface so zigbase remains a real dependency,
    // while deliberately avoiding testing.start and all app boot work.
    const response: zigbase.http.Response = .{ .status = 200, .body = "" };
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(fio_is_master() == 0 or fio_is_master() == 1);
}
