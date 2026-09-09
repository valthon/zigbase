//! Database-only cancellation receipt. No email, file IO, or realtime publication
//! belongs in the transaction callback; use a transactional outbox for such work.
const std = @import("std");
const zb = @import("zigbase");
const Receipts = zb.Idempotency(.{ .namespace = "golfsim-cancellations-v1", .max_entries = 1024, .max_payload_bytes = 128, .max_result_bytes = 32 });

const Operation = struct {
    ctx: *zb.Ctx,
    id: []const u8,
    user_id: []const u8,
    fn bound(self: *Operation, conn: *zb.Db) zb.Ctx {
        return .{ .app = self.ctx.app, .arena = self.ctx.arena, .rctx = self.ctx.rctx, .bound_conn = conn };
    }
    fn authorize(conn: *zb.Db, context: *anyopaque) !void {
        const self: *Operation = @ptrCast(@alignCast(context));
        var ctx = self.bound(conn);
        defer ctx.deinit();
        const booking = (try ctx.records().get("bookings", self.id, .{})) orelse return error.NotFound;
        const guest = booking.object.get("guest") orelse return error.Forbidden;
        if (guest != .string or !std.mem.eql(u8, guest.string, self.user_id)) return error.Forbidden;
    }
    fn mutate(conn: *zb.Db, context: *anyopaque, output: []u8) !usize {
        const self: *Operation = @ptrCast(@alignCast(context));
        var ctx = self.bound(conn);
        defer ctx.deinit();
        var patch: std.json.ObjectMap = .empty;
        try patch.put(ctx.arena.a, "status", .{ .string = "cancelled" });
        _ = (try ctx.records().update("bookings", self.id, .{ .object = patch })) orelse return error.NotFound;
        const result = "{\"cancelled\":true}";
        @memcpy(output[0..result.len], result);
        return result.len;
    }
};

pub fn handle(ctx: *zb.Ctx) !zb.http.Response {
    const user = ctx.user() orelse return ctx.fail(401, "Authentication required.");
    if (!std.mem.eql(u8, user.collection, "users") or user.id.len == 0) return ctx.fail(403, "A guest account is required.");
    const request = ctx.request orelse return error.NoRequest;
    const id = request.param("id") orelse return ctx.fail(400, "Missing booking id.");
    const key = request.header("idempotency-key") orelse return ctx.fail(400, "Idempotency-Key is required.");
    if (request.body.len != 0) return ctx.fail(400, "This operation takes no body.");
    var operation = Operation{ .ctx = ctx, .id = id, .user_id = user.id };
    const conn = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.app.io, .real).nanoseconds, std.time.ns_per_s));
    const result = Receipts.execute(ctx.arena.a, conn, .{
        .principal = .{ .collection = user.collection, .record = user.id },
        .operation = "cancel-booking",
        .key = key,
        .payload = id, // Bind the target too: same key cannot cancel another booking.
        .now = now,
    }, .{ .context = &operation, .authorize = Operation.authorize, .mutate = Operation.mutate }) catch |err| return switch (err) {
        error.Forbidden => ctx.fail(403, "Only the current guest can cancel this booking."),
        error.NotFound => ctx.fail(404, "Booking not found."),
        error.PayloadConflict => ctx.fail(409, "Key already used for a different booking."),
        error.CapacityExceeded => ctx.fail(503, "Cancellation receipts are at capacity; retry later."),
        error.InvalidScope, error.PayloadTooLarge => ctx.fail(400, "Invalid key or booking id."),
        error.UnsupportedBackend => ctx.fail(501, "Idempotent cancellation requires SQLite."),
        else => err,
    };
    defer result.deinit(ctx.arena.a);
    try ctx.addHeader(.{ .name = "Idempotency-Replayed", .value = if (result.replayed) "true" else "false" });
    return .{ .status = 200, .body = try ctx.arena.a.dupe(u8, result.body()) };
}
