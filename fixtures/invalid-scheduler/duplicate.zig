const std = @import("std");
const zigbase = @import("zigbase");
fn handler(_: *zigbase.Ctx, _: *zigbase.JobEvent) anyerror!void {}
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .cron = .{ .{ .name = "shared", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .distributed = .{}, .handler = handler }, .{ .name = "shared", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = handler } } }).runCli(init);
}
