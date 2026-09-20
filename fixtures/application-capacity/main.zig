const std = @import("std");
const zb = @import("zigbase");

// A project/task application for tools/application_capacity.py. All measured
// traffic uses ordinary records APIs as tenant members, never a privileged route.
// Each update atomically schedules a bounded synthetic digest job. This models
// queue/database contention, not an external email or webhook service.
fn enqueueDigest(ctx: *zb.Ctx, ev: *zb.RecordEvent) !void {
    try ctx.enqueue(.capacity, .digest, .{ .account = ctx.rctx.account_id, .title = ev.record.object.get("title") orelse return error.MissingTitle });
}

fn digest(_: *zb.Ctx, payload: []const u8) !void {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &result, .{});
    for (0..64) |_| std.crypto.hash.sha2.Sha256.hash(&result, &result, .{});
    std.mem.doNotOptimizeAway(result);
}
pub fn main(init: std.process.Init) !void {
    const member = "@request.auth.id != \"\"";
    return zb.App(.{
        .hooks = .{ .tasks = .{ .beforeUpdate = enqueueDigest } },
        .queues = .{ .capacity = .{ .backend = .durable, .capacity = .{ .max_jobs = 1000000, .max_payload_bytes = 256 << 20 } } },
        // Durable worker concurrency is the serial claim batch per scheduler tick.
        // Keep the cheap digest workload from being dominated by a two-job batch.
        .workers = .{ .capacity = .{ .queues = .{"capacity"}, .concurrency = 128 } },
        .jobs = .{ .digest = digest },
        .tenancy = .{ .enabled = true, .auth_collection = "users" },
        .collections = .{
            .users = .{ .type = .auth, .fields = .{} },
            .projects = .{
                .fields = .{
                    .{ .name = "account", .type = .text, .required = true },
                    .{ .name = "title", .type = .text, .required = true, .max = 128 },
                },
                .tenant_field = "account",
                .rules = .{ .list = member, .view = member },
            },
            .tasks = .{
                .fields = .{
                    .{ .name = "account", .type = .text, .required = true },
                    .{ .name = "project", .type = .relation, .target = "projects", .required = true },
                    .{ .name = "title", .type = .text, .required = true, .max = 128 },
                },
                .tenant_field = "account",
                .rules = .{ .list = member, .view = member, .update = member },
                .indexes = .{.{ .name = "capacity_tasks_account_id", .fields = .{ "account", "id" } }},
            },
        },
    }).runCli(init);
}
