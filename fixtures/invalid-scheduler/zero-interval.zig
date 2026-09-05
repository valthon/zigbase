const std = @import("std");
const zigbase = @import("zigbase");
fn handler(_: *zigbase.Ctx, _: *zigbase.JobEvent) anyerror!void {}
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .cron = .{.{ .name = "local", .schedule = zigbase.schedule.Schedule{ .interval = .{ .minutes = 0 } }, .handler = handler }} }).runCli(init);
}
