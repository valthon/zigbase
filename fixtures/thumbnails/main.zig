//! Test-only control endpoints are not part of ZigBase's public API.
const std = @import("std");
const zb = @import("zigbase");
var original: ?*const zb.Storage = null;
var replacement: zb.Storage = undefined;
var replacement_vtable: zb.Storage.VTable = undefined;
var before_count: std.atomic.Value(u32) = .init(0);

fn neverFetch(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !?[]const u8 {
    @panic("thumbnail must never call custom fetch");
}
fn neverPresign(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, _: u32) !?[]const u8 {
    @panic("thumbnail must never call custom presign");
}
fn bootstrap(ctx: *zb.Ctx, _: *zb.events.LifecycleEvent) !void {
    original = ctx.app.storage;
    replacement = original.?.*;
    replacement_vtable = replacement.vtable.*;
    replacement_vtable.fetch = neverFetch;
    replacement_vtable.presignGetUrl = neverPresign;
    replacement.vtable = &replacement_vtable;
}
fn before(ev: *zb.events.FileEvent) !void {
    // Reader capacity bounds idle retention, not active acquisition: a nested
    // query alone would silently open another reader. Inspect the idle slot
    // before acquisition so retaining the file-auth reader fails this fixture.
    const idle = if (@hasField(@TypeOf(ev.app.pool.*), "impl")) switch (ev.app.pool.impl) {
        inline else => |pool| pool.reader_count,
    } else ev.app.pool.reader_count;
    if (idle != 1) return error.AuthReaderStillHeld;
    var reader = try ev.app.pool.acquireReader();
    defer ev.app.pool.releaseReader(&reader);
    try reader.exec("SELECT 1;");
    _ = before_count.fetchAdd(1, .monotonic);
    if (std.mem.startsWith(u8, ev.filename, "deny")) return error.Denied;
    if (std.mem.startsWith(u8, ev.filename, "replace")) ev.app.storage = &replacement;
    // Existing original-file semantics ignore mutation of these identifiers.
    if (std.mem.startsWith(u8, ev.filename, "mutate")) {
        ev.collection = "other";
        ev.record_id = "missing";
        ev.filename = "missing.png";
    }
}
const Control = struct { mode: enum { reset, busy, release_busy, input, output, pixels, custom, missing, timeout, failfast, queue_one, status } };
fn control(req: *zb.Req(Control)) zb.RouteError!struct { before: u32, active: u32, waiting: u32 } {
    const app = req.ctx.app;
    if (req.input.mode == .status) {
        app.thumbnail_admission.mutex.lockUncancelable(app.io);
        defer app.thumbnail_admission.mutex.unlock(app.io);
        return .{ .before = before_count.load(.monotonic), .active = app.thumbnail_admission.active, .waiting = app.thumbnail_admission.waiting };
    }
    app.storage = original;
    app.files.thumbnails.imagemagick = .{ .executable = "/usr/bin/convert", .command_style = .convert };
    app.files.thumbnails.max_waiting = 32;
    app.files.thumbnails.wait_timeout_ms = 1000;
    switch (req.input.mode) {
        .reset => {},
        .busy => {
            if (!app.thumbnail_admission.acquire(app.io, app.files.thumbnails)) return error.RouteFailed;
        },
        .release_busy => {
            app.thumbnail_admission.release(app.io);
        },
        .input => app.files.thumbnails.imagemagick.max_input_bytes = 1,
        .output => app.files.thumbnails.imagemagick.max_output_bytes = 1,
        .pixels => app.files.thumbnails.imagemagick.max_pixels = 1,
        .custom => app.storage = &replacement,
        .missing => app.files.thumbnails.imagemagick.executable = "/missing/imagemagick",
        .timeout => app.files.thumbnails.imagemagick.timeout_ms = 1,
        .failfast => app.files.thumbnails.max_waiting = 0,
        .queue_one => app.files.thumbnails.max_waiting = 1,
        .status => unreachable,
    }
    app.thumbnail_admission.mutex.lockUncancelable(app.io);
    defer app.thumbnail_admission.mutex.unlock(app.io);
    return .{ .before = before_count.load(.monotonic), .active = app.thumbnail_admission.active, .waiting = app.thumbnail_admission.waiting };
}

pub fn main(init: std.process.Init) !void {
    return zb.App(.{
        .pools = .{ .readers = 1 },
        .files = .{ .thumbnails = .{ .imagemagick = .{ .executable = "/usr/bin/convert", .command_style = .convert }, .wait_timeout_ms = 1000, .profiles = .{ .tiny = .{ .width = 1, .height = 1 }, .card = .{ .width = 128, .height = 64 }, .jpeg = .{ .width = 16, .height = 16, .format = .jpeg }, .webp = .{ .width = 16, .height = 16, .format = .webp }, .cover = .{ .width = 16, .height = 16, .fit = .cover } } }, .s3_presign_redirect = true },
        .onBootstrap = bootstrap,
        .onFileServe = before,
        .tenancy = .{ .enabled = true, .auth_collection = "users" },
        .collections = .{ .users = .{ .type = .auth, .fields = .{} } },
        .routes = .{.{ .method = .POST, .path = "/api/thumbnail-test-control", .handler = control, .auth = .superuser }},
    }).runCli(init);
}
