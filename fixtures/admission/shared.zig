const std = @import("std");
const zigbase = @import("zigbase");

var gate_dir: []const u8 = undefined;

fn job(ctx: *zigbase.Ctx, _: *zigbase.JobEvent) anyerror!void {
    try hold(ctx, "entered");
}

fn hold(ctx: *zigbase.Ctx, marker: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(ctx.app.io, gate_dir, .{});
    defer dir.close(ctx.app.io);
    try dir.writeFile(ctx.app.io, .{ .sub_path = marker, .data = "ready" });
    for (0..1000) |_| {
        if (dir.access(ctx.app.io, "release", .{})) |_| return else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestBarrierTimeout;
}

fn submit(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    try ctx.app.submit("held", job);
    ctx.app.submit("rejected", job) catch |err| {
        if (err != error.QueueFull) return err;
        return .{ .status = 200, .body = "second-job-rejected" };
    };
    return error.ExpectedQueueFull;
}

fn holdHttp(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    try hold(ctx, "http-entered");
    return .{ .status = 204, .body = "" };
}

pub fn main(init: std.process.Init) !void {
    gate_dir = init.environ_map.get("ZIGBASE_TEST_GATE") orelse ".";
    return zigbase.App(.{
        .admission = .{ .max_requests = 2, .max_work = 2 },
        .pools = .{ .memory_jobs = 1 },
        .routes = .{
            .{ .method = .POST, .path = "/submit", .handler = submit, .auth = .public },
            .{ .method = .GET, .path = "/hold", .handler = holdHttp, .auth = .public },
        },
    }).runCli(init);
}
