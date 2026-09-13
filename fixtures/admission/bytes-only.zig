const std = @import("std");
const zigbase = @import("zigbase");

var gate_dir: []const u8 = undefined;

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

fn job(ctx: *zigbase.Ctx, _: *zigbase.JobEvent) anyerror!void {
    try hold(ctx, "job-entered");
}

fn submit(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    try ctx.app.submit("held", job);
    return .{ .status = 204, .body = "" };
}

fn holdHttp(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const marker = ctx.request.?.param("marker") orelse return error.MissingMarker;
    // The fixture only accepts its three controlled file components.
    if (!std.mem.eql(u8, marker, "one") and !std.mem.eql(u8, marker, "two") and !std.mem.eql(u8, marker, "three")) return error.InvalidMarker;
    try hold(ctx, marker);
    return .{ .status = 204, .body = "" };
}

pub fn main(init: std.process.Init) !void {
    gate_dir = init.environ_map.get("ZIGBASE_TEST_GATE") orelse ".";
    return zigbase.App(.{
        .admission = .{ .max_job_bytes = 4 },
        .pools = .{ .memory_jobs = 1 },
        .routes = .{
            .{ .method = .POST, .path = "/submit", .handler = submit, .auth = .public },
            .{ .method = .GET, .path = "/hold/:marker", .handler = holdHttp, .auth = .public },
        },
    }).runCli(init);
}
