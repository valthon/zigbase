const std = @import("std");
const App = @import("app.zig").App;

pub const Envelope = struct {
    url: []const u8,
    auth_header: []const u8,
    body: []const u8,
};

/// Extract the public key from a DSN: the `<pub>` between "://" and "@".
fn publicKey(dsn: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.InvalidDsn;
    const after = dsn[scheme_end + 3 ..];
    const at = std.mem.indexOfScalar(u8, after, '@') orelse return error.InvalidDsn;
    if (at == 0) return error.InvalidDsn;
    return after[0..at];
}

/// Build the ingest endpoint URL from a DSN:
///   https://<pub>@<host>/<project> -> https://<host>/api/<project>/envelope/
fn ingestUrl(alloc: std.mem.Allocator, dsn: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.InvalidDsn;
    const scheme = dsn[0..scheme_end];
    const after = dsn[scheme_end + 3 ..];
    const at = std.mem.indexOfScalar(u8, after, '@') orelse return error.InvalidDsn;
    const host_and_path = after[at + 1 ..];
    const slash = std.mem.lastIndexOfScalar(u8, host_and_path, '/') orelse return error.InvalidDsn;
    const host = host_and_path[0..slash];
    const project = host_and_path[slash + 1 ..];
    if (host.len == 0 or project.len == 0) return error.InvalidDsn;
    return std.fmt.allocPrint(alloc, "{s}://{s}/api/{s}/envelope/", .{ scheme, host, project });
}

/// Build a Sentry envelope (header line + item header + payload) for a single
/// event carrying `message` at `level`. Returns owned slices allocated from `alloc`.
pub fn buildEnvelope(
    alloc: std.mem.Allocator,
    dsn: []const u8,
    message: []const u8,
    level: []const u8,
) !Envelope {
    const url = try ingestUrl(alloc, dsn);
    const pubkey = try publicKey(dsn);
    const auth_header = try std.fmt.allocPrint(
        alloc,
        "Sentry sentry_version=7, sentry_key={s}",
        .{pubkey},
    );

    // Event payload: {message, level, platform:"other"}.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "message", .{ .string = message });
    try obj.put(alloc, "level", .{ .string = level });
    try obj.put(alloc, "platform", .{ .string = "other" });
    const payload = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = obj }, .{});

    // Envelope header references the DSN; item header carries the payload length.
    const header = try std.fmt.allocPrint(alloc, "{{\"dsn\":\"{s}\"}}", .{dsn});
    const item_header = try std.fmt.allocPrint(alloc, "{{\"type\":\"event\",\"length\":{d}}}", .{payload.len});
    const body = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ header, item_header, payload });

    return .{ .url = url, .auth_header = auth_header, .body = body };
}

/// Test-only sink: when non-null, the log-mode backstop routes the message here
/// instead of `std.log.err`. Production leaves this null (real logging). It exists
/// because Zig's test runner counts every `std.log.err` as a test failure, so a
/// test exercising the DSN-less backstop needs a way to observe it without logging.
pub var log_sink: ?*const fn (message: []const u8) void = null;

/// Default error backstop: report to Sentry if a DSN is set, else log. Always swallows.
pub fn backstop(app: *App, message: []const u8) void {
    if (app.sentry_dsn.len == 0) {
        if (log_sink) |sink| sink(message) else std.log.err("zigbase error: {s}", .{message});
        return;
    }
    report(app, message) catch |e| {
        std.log.err("zigbase error (sentry report failed: {s}): {s}", .{ @errorName(e), message });
    };
}

/// POST a single event to Sentry's envelope endpoint. Mirrors src/oauth/client.zig's
/// std.http.Client usage. Bounds and discards the response. Network errors propagate.
fn report(app: *App, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try buildEnvelope(a, app.sentry_dsn, message, "error");

    var client = std.http.Client{ .allocator = a, .io = app.io };
    defer client.deinit();

    const extra = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/x-sentry-envelope" },
        .{ .name = "x-sentry-auth", .value = env.auth_header },
    };

    const MAX_RESP = 1 << 16; // 64 KiB; we discard it anyway
    const resp_buf = try a.alloc(u8, MAX_RESP);
    var fw = std.Io.Writer.fixed(resp_buf);
    _ = client.fetch(.{
        .location = .{ .url = env.url },
        .method = .POST,
        .payload = env.body,
        .extra_headers = &extra,
        .response_writer = &fw,
    }) catch |e| {
        // A response exceeding the fixed buffer surfaces as WriteFailed; ignore it
        // (delivery succeeded; we just couldn't capture the whole body).
        if (e == error.WriteFailed) return;
        return e;
    };
}

test "buildEnvelope produces a valid Sentry envelope with the message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try buildEnvelope(a, "https://pub@o1.ingest.sentry.io/42", "boom: error.HookRejected", "error");
    var it = std.mem.splitScalar(u8, out.body, '\n');
    const hdr = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, hdr, "\"dsn\"") != null);
    _ = it.next().?; // item header
    const payload = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, payload, "boom: error.HookRejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"level\":\"error\"") != null);
    try std.testing.expectEqualStrings("https://o1.ingest.sentry.io/api/42/envelope/", out.url);
}
