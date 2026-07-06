const std = @import("std");
const reporter = @import("reporter.zig");
const config = @import("../config.zig");
const http_client = @import("../http_client.zig");
const Reporter = reporter.Reporter;
const Report = reporter.Report;

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

/// Sentry error reporter plugin. Captures the DSN at `create` and POSTs a Sentry envelope
/// per report. Selected by `DefaultReporterPlugin` only when a DSN is configured, so `dsn`
/// is non-empty in practice (the empty-DSN guard in `report` is a defensive no-op).
///
/// Delivery is NON-BLOCKING (#244 stage 2): `dispatchError` enqueues a `"report"` job on the
/// memory queue and THIS `report` runs on a pool worker (`report/send.zig`), so the POST is off
/// the erroring thread. The POST goes through the framework `HttpClient`, which carries the
/// dev-only `testcapture.http` mock seam — so delivery is assertable in tests without a live
/// Sentry (and never hits the network in CI).
pub const SentryReporter = struct {
    dsn: []const u8,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !SentryReporter {
        _ = gpa;
        _ = io;
        return .{ .dsn = cfg.sentry_dsn };
    }

    pub fn interface(self: *SentryReporter) Reporter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *SentryReporter) void {
        _ = self;
    }

    const vtable = Reporter.VTable{ .report = report };

    /// POST a single event to Sentry's envelope endpoint via the framework `HttpClient`
    /// (TLS verification on; the `testcapture.http` mock seam applies). Runs on a queue
    /// worker, so this blocking POST is off the erroring thread. The response is discarded.
    /// A transport error propagates to `report/send.jobHandler`, which logs and swallows it
    /// (best-effort — see the loop guard). A no-op when the DSN is empty (never selected then).
    fn report(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, r: Report) anyerror!void {
        const self: *SentryReporter = @ptrCast(@alignCast(ptr));
        if (self.dsn.len == 0) return;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const env = try buildEnvelope(a, self.dsn, r.message, r.level);

        const client = http_client.HttpClient{ .alloc = a, .io = io };
        const headers = [_]http_client.Header{
            .{ .name = "content-type", .value = "application/x-sentry-envelope" },
            .{ .name = "x-sentry-auth", .value = env.auth_header },
        };
        // We discard the response body; ignore its status (Sentry ingest returns 200/429/etc.,
        // all best-effort). A TransportFailed propagates and is logged by the report job.
        _ = try client.post(env.url, .{ .headers = &headers, .body = env.body });
    }
};

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

test "SentryReporter POSTs the envelope to the ingest URL (via the testcapture.http seam)" {
    const testcapture = @import("../testcapture.zig");
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true); // block unmocked — a real network attempt would error
    testcapture.http.mock("ingest.sentry.io", .{ .status = 200 });

    var sr = try SentryReporter.create(std.testing.allocator, std.testing.io, .{ .sentry_dsn = "https://pub@o1.ingest.sentry.io/42" });
    defer sr.deinit();
    const rep = sr.interface();
    try rep.report(std.testing.io, std.testing.allocator, .{ .message = "boom: error.HookRejected", .err_name = "error.HookRejected", .phase = "request" });

    // Exactly one POST to the envelope endpoint, carrying the auth header + the message.
    try std.testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    const req = testcapture.http.requestAt(0).?;
    try std.testing.expectEqual(@import("../http_client.zig").Method.POST, req.method);
    try std.testing.expect(std.mem.indexOf(u8, req.url, "/api/42/envelope/") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body.?, "boom: error.HookRejected") != null);
    var saw_auth = false;
    for (req.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-sentry-auth")) saw_auth = true;
    }
    try std.testing.expect(saw_auth);
}

test "SentryReporter captures the DSN and no-ops on an empty DSN" {
    var sr = try SentryReporter.create(std.testing.allocator, std.testing.io, .{ .sentry_dsn = "https://pub@o1.ingest.sentry.io/42" });
    defer sr.deinit();
    try std.testing.expectEqualStrings("https://pub@o1.ingest.sentry.io/42", sr.dsn);

    // Empty DSN → report is a no-op (no network attempt), returns without error.
    var empty = try SentryReporter.create(std.testing.allocator, std.testing.io, .{});
    defer empty.deinit();
    const rep = empty.interface();
    try rep.report(std.testing.io, std.testing.allocator, .{ .message = "x", .phase = "app" });
}
