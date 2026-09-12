const std = @import("std");
const zigbase = @import("zigbase");

var before_count: std.atomic.Value(u32) = .init(0);
var after_count: std.atomic.Value(u32) = .init(0);
extern "c" fn raise(c_int) c_int;
extern "c" fn sqlite3_set_authorizer(?*anyopaque, ?*const fn (?*anyopaque, c_int, [*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8) callconv(.c) c_int, ?*anyopaque) c_int;
fn denyRollback(_: ?*anyopaque, action: c_int, detail: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    // SQLITE_TRANSACTION=22, SQLITE_DENY=1, SQLITE_OK=0.
    return if (action == 22 and detail != null and std.mem.eql(u8, std.mem.span(detail), "ROLLBACK")) 1 else 0;
}
fn before(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) !void {
    _ = before_count.fetchAdd(1, .monotonic);
    if (ev.record.object.get("file")) |file| {
        if (file == .string and std.mem.indexOf(u8, file.string, "rollbackfail") != null) {
            const w = ctx.bound_conn.?;
            try w.exec("UPDATE \"_upload_sessions\" SET offset=0 WHERE state='committing';");
            const handle = if (@hasField(@TypeOf(w.*), "sqlite")) w.sqlite.handle else w.handle;
            if (sqlite3_set_authorizer(@ptrCast(handle), denyRollback, null) != 0) return error.FaultInjectionFailed;
            return error.Rejected;
        }
        if (file == .string and std.mem.indexOf(u8, file.string, "crashbefore") != null) {
            if (raise(9) != 0) return error.CrashProbeFailed;
        }
        if (file == .string and std.mem.indexOf(u8, file.string, "reject") != null) return error.Rejected;
    }
}
fn after(_: *zigbase.Ctx, ev: *zigbase.RecordEvent) !void {
    _ = after_count.fetchAdd(1, .monotonic);
    if (ev.record.object.get("file")) |file| {
        if (file == .string and std.mem.indexOf(u8, file.string, "crashafter") != null) {
            if (raise(9) != 0) return error.CrashProbeFailed;
        }
    }
}
fn counts(_: *zigbase.Req(void)) zigbase.RouteError!struct { before: u32, after: u32 } {
    return .{ .before = before_count.load(.monotonic), .after = after_count.load(.monotonic) };
}
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .uploads = .{ .beforeUpdate = before, .afterUpdate = after } },
        .routes = .{.{ .method = .GET, .path = "/api/upload-probe", .handler = counts, .auth = .superuser }},
        .files = .{ .resumable = .{
            .durable = true,
            .max_sessions = 4,
            .max_sessions_per_principal = 2,
            .max_upload_bytes = 64,
            .max_total_bytes = 128,
            .max_chunk_bytes = 8,
            .ttl_seconds = 60,
        } },
    }).runCli(init);
}
