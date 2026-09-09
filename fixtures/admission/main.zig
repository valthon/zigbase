const std = @import("std");
const zigbase = @import("zigbase");

// Test-only filesystem barrier controlled by the parent, not another HTTP
// request (which must itself be rejected while the sole permit is occupied).
var gate_dir: []const u8 = undefined;

fn hold(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    var dir = try std.Io.Dir.cwd().openDir(ctx.app.io, gate_dir, .{});
    defer dir.close(ctx.app.io);
    try dir.writeFile(ctx.app.io, .{ .sub_path = "entered", .data = "ready" });
    for (0..1000) |_| {
        if (dir.access(ctx.app.io, "release", .{})) |_| {
            return .{ .status = 200, .body = "released" };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestBarrierTimeout;
}

fn fail(_: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return error.TestHandlerFailure;
}

fn file(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    // Response.file borrows this path until the HTTP callback drops its arena.
    const path = try std.fmt.allocPrint(ctx.arena.a, "{s}/payload", .{gate_dir});
    return .{ .status = 200, .file = .{ .path = path, .len = 3 }, .body = "" };
}

pub fn main(init: std.process.Init) !void {
    gate_dir = init.environ_map.get("ZIGBASE_TEST_GATE") orelse ".";
    return zigbase.App(.{
        .admission = .{ .max_requests = 1 },
        .collections = .{ .members = .{ .type = .auth, .fields = .{} } },
        .routes = .{
            .{ .method = .GET, .path = "/hold", .handler = hold, .auth = .public },
            .{ .method = .GET, .path = "/fail", .handler = fail, .auth = .public },
            .{ .method = .GET, .path = "/file", .handler = file, .auth = .public },
            .{ .method = .HEAD, .path = "/file", .name = "fileHead", .handler = file, .auth = .public },
        },
    }).runCli(init);
}
