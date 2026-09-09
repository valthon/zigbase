const std = @import("std");
const zigbase = @import("zigbase");

var before_count: std.atomic.Value(u32) = .init(0);
var after_count: std.atomic.Value(u32) = .init(0);
fn before(_: *zigbase.Ctx, ev: *zigbase.RecordEvent) !void {
    _ = before_count.fetchAdd(1, .monotonic);
    if (ev.record.object.get("file")) |file| {
        if (file == .string and std.mem.indexOf(u8, file.string, "reject") != null) return error.Rejected;
    }
}
fn after(_: *zigbase.Ctx, _: *zigbase.RecordEvent) !void {
    _ = after_count.fetchAdd(1, .monotonic);
}
fn counts(_: *zigbase.Req(void)) zigbase.RouteError!struct { before: u32, after: u32 } {
    return .{ .before = before_count.load(.monotonic), .after = after_count.load(.monotonic) };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .hooks = .{ .uploads = .{ .beforeUpdate = before, .afterUpdate = after } }, .routes = .{.{ .method = .GET, .path = "/api/upload-probe", .handler = counts, .auth = .superuser }}, .files = .{ .resumable = .{
        .max_sessions = 4,
        .max_upload_bytes = 64,
        .max_total_bytes = 128,
        .max_chunk_bytes = 8,
        .max_sessions_per_principal = 2,
        .ttl_seconds = 5,
    } } }).runCli(init);
}
