const std = @import("std");
const zb = @import("zigbase");

fn enqueue(ctx: *zb.Ctx) !zb.http.Response {
    const request = ctx.request.?;
    ctx.enqueueByName(request.param("queue").?, "noop", request.body) catch |err| switch (err) {
        error.QueueFull, error.QueueAdmissionBusy => return ctx.jsonError(503, "queue_full", "Durable queue capacity is unavailable."),
        else => return err,
    };
    return .{ .status = 204, .body = "" };
}
fn snapshot(ctx: *zb.Ctx) !zb.http.Response {
    return ctx.json(200, try ctx.queueCapacityByName(ctx.request.?.param("queue").?));
}
fn noop(_: *zb.Ctx, _: []const u8) !void {}

pub fn main(init: std.process.Init) !void {
    return zb.App(.{
        .queues = .{
            .counted = .{ .backend = .durable, .capacity = .{ .max_jobs = 4, .max_payload_bytes = 32 } },
            .bytes = .{ .backend = .durable, .capacity = .{ .max_jobs = 8, .max_payload_bytes = 8 } },
        },
        .jobs = .{ .noop = noop },
        .routes = .{
            .{ .method = .POST, .path = "/job-budget/:queue", .name = "enqueueBudget", .auth = .superuser, .handler = enqueue },
            .{ .method = .GET, .path = "/job-budget/:queue", .name = "inspectBudget", .auth = .superuser, .handler = snapshot },
        },
    }).runCli(init);
}
