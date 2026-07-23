const std = @import("std");
const testcapture = @import("testcapture.zig");

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, HEAD };
pub const Header = struct { name: []const u8, value: []const u8 };

/// Ownership: ARENA-SCOPED (contract 4). This type intentionally has no `deinit`.
///
/// `request()` allocates the response — the captured header array and its duped
/// name/value strings, plus internal scratch (the `max_response_bytes` body buffer,
/// redirect buffer, decompress buffer) — on the `HttpClient.alloc` allocator and never
/// frees any of it. `body` is a sub-slice of the single fixed `max_response_bytes`
/// buffer (see `request`), NOT an independent allocation, so it cannot be freed on its
/// own — freeing `body` would free an interior slice of the wrong length. The whole
/// graph is therefore reclaimed wholesale when the allocator is torn down.
///
/// Callers MUST pass a request-scoped / arena allocator (every in-tree caller does:
/// the request/job arena, or a per-op disposable arena). Read or copy out anything you
/// need to keep — the entire response is invalid once that allocator is reset.
pub const HttpResponse = struct {
    status: u16,
    /// Response headers captured from the server reply.
    ///
    /// Each header's `name` and `value` are allocated on the `HttpClient.alloc`
    /// allocator (duped from the connection buffer before it is torn down), so
    /// the slice is valid for the lifetime of that allocator.  Standard headers
    /// like `Content-Type`, `Location`, and `X-*` rate-limit headers are all
    /// present here.
    headers: []const Header,
    /// The response body — a sub-slice of the fixed `max_response_bytes` buffer, valid for
    /// the lifetime of `HttpClient.alloc`. Not individually freeable (see the type doc).
    body: []const u8,
};

/// Options for a generic HTTP request.
///
/// Note: `timeout_ms` is stored for caller intent but `std.http.Client` in
/// Zig 0.16 does not expose a per-call timeout on the underlying socket. The
/// field is preserved here so call-sites can express a desired timeout today;
/// it will be wired up once the upstream API provides the hook.
pub const RequestOptions = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    max_response_bytes: usize = 1 << 20,
    /// `download()`-only: when set and the response status is `>= discard_body_status`,
    /// the body is drained into a bounded scratch sink instead of `download`'s `writer`
    /// (see that function's docs). Ignored by `request()`.
    discard_body_status: ?u16 = null,
};

pub const PostOptions = struct { headers: []const Header = &.{}, body: ?[]const u8 = null };

/// Result of `HttpClient.download`: the body itself was streamed through the caller's
/// writer, not buffered here.
///
/// Ownership: ARENA-SCOPED (contract 4), same as `HttpResponse` — the captured headers
/// and `download`'s internal scratch live on the passed allocator and are never freed
/// here; there is no `deinit`. Pass a request-scoped / arena allocator.
pub const DownloadResult = struct {
    status: u16,
    headers: []const Header,
};

/// True when a response to this method/status is DEFINED to carry no body, no matter
/// what Content-Length/Transfer-Encoding header it arrives with (RFC 9110 §6.4.1): a
/// HEAD response, any 1xx, 204 No Content, or 304 Not Modified. `std.http.Client`
/// applies this same rule when framing the HEAD (`receiveHead()` stops at the blank
/// line for exactly these cases regardless of headers) but does NOT propagate it
/// anywhere else — both our own body read below AND `Request.deinit()`'s own
/// connection-reuse safety net independently decide whether to read a body from
/// `method.responseHasBody()` alone, which is TRUE for DELETE (a DELETE response CAN
/// carry a body in general). Against MinIO specifically, a 204 DELETE response has
/// neither Content-Length nor Transfer-Encoding, so whichever of those two reads a
/// "body" falls back to "read until the connection closes" — and blocks forever on
/// a keep-alive connection a spec-conforming server never closes (observed: ~30s,
/// the connection's own idle timeout finally firing, not ours). Every caller of this
/// function MUST ALSO force `connection.closing = true` on a true result — see the
/// call sites — so `deinit()`'s own drain-and-reuse attempt is skipped too.
fn responseHasNoBody(method: std.http.Method, status: std.http.Status) bool {
    return method == .HEAD or status.class() == .informational or
        status == .no_content or status == .not_modified;
}

/// Lightweight outbound HTTP client.
///
/// Create one per request (or reuse across requests sharing the same allocator).
/// TLS certificate verification is ON by default via `std.http.Client`'s built-in
/// bundle — do **not** disable it. Pass `io = std.testing.io` in unit tests.
pub const HttpClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,

    pub fn get(self: HttpClient, url: []const u8) !HttpResponse {
        return self.request(.{ .method = .GET, .url = url });
    }

    pub fn post(self: HttpClient, url: []const u8, opts: PostOptions) !HttpResponse {
        return self.request(.{
            .method = .POST,
            .url = url,
            .headers = opts.headers,
            .body = opts.body,
        });
    }

    pub fn request(self: HttpClient, opts: RequestOptions) !HttpResponse {
        // Dev-only capture/mock seam (#96). Comptime-dead on a prod build, so no runtime
        // branch and no perf cost there. When a test has enabled capture, this records the
        // request and (if a mock matches the URL) returns a canned response duped onto our
        // allocator — no network at all. Mirrors the oauth `Transport` injection.
        if (testcapture.enabled) {
            switch (try testcapture.http.intercept(self.alloc, opts)) {
                .passthrough => {},
                .response => |r| return r,
                .blocked => return error.TransportFailed,
            }
        }

        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        // Build extra request headers.
        const extra = try self.alloc.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

        // Prepare the response body buffer (fixed-size, write-fails on overflow).
        const resp_buf = try self.alloc.alloc(u8, opts.max_response_bytes);
        var fw = std.Io.Writer.fixed(resp_buf);

        // Use the lower-level std.http.Client.request() API (instead of the
        // convenience fetch()) so we can iterate response headers from the
        // parsed head before they are invalidated when we open the body reader.
        const uri = std.Uri.parse(opts.url) catch return error.TransportFailed;
        const method: std.http.Method = switch (opts.method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
        };
        // Mirror std.http.Client.fetch: follow up to 3 redirects for bodyless
        // requests; leave redirect handling to the caller for requests with a body.
        const redirect_behavior: std.http.Client.Request.RedirectBehavior =
            if (opts.body == null) @enumFromInt(3) else .unhandled;

        var req = client.request(method, uri, .{
            .extra_headers = extra,
            .redirect_behavior = redirect_behavior,
        }) catch return error.TransportFailed;
        defer req.deinit();

        if (opts.body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var bw = req.sendBodyUnflushed(&.{}) catch return error.TransportFailed;
            bw.writer.writeAll(payload) catch return error.TransportFailed;
            bw.end() catch return error.TransportFailed;
            req.connection.?.flush() catch return error.TransportFailed;
        } else {
            req.sendBodiless() catch return error.TransportFailed;
        }

        // RFC 9110 recommends 8 KiB redirect buffer.
        const redirect_buffer = try self.alloc.alloc(u8, 8 * 1024);
        var response = req.receiveHead(redirect_buffer) catch return error.TransportFailed;

        // Capture response headers NOW, before readerDecompressing() calls
        // head.invalidateStrings(), which zeroes out head.bytes and makes all
        // string slices inside Head dangle.  We dupe each name+value onto
        // self.alloc so they remain valid after the connection is torn down.
        var header_list: std.ArrayList(Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            try header_list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, h.name),
                .value = try self.alloc.dupe(u8, h.value),
            });
        }
        const captured_headers = try header_list.toOwnedSlice(self.alloc);

        // A response DEFINED to have no body (see `responseHasNoBody`) is never read —
        // any Content-Length it carries describes what a GET would have returned, not
        // actual bytes on this wire. Force the connection closed rather than pooled:
        // `deinit()` (via `defer` above) would otherwise try its OWN body drain using
        // `method.responseHasBody()`, which doesn't know about this status/method and
        // would hang exactly the way we just avoided.
        if (responseHasNoBody(method, response.head.status)) {
            if (req.connection) |connection| connection.closing = true;
            return .{
                .status = @intFromEnum(response.head.status),
                .headers = captured_headers,
                .body = fw.buffered(),
            };
        }

        // Read and optionally decompress the response body (mirrors fetch()).
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.alloc.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.alloc.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.TransportFailed,
        };
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = body_reader.streamRemaining(&fw) catch |err| switch (err) {
            error.ReadFailed => return error.TransportFailed,
            error.WriteFailed => return error.ResponseTooLarge,
        };

        // TLS certificate verification is on by default in std.http.Client;
        // do not disable it here.
        return .{
            .status = @intFromEnum(response.head.status),
            .headers = captured_headers,
            .body = fw.buffered(),
        };
    }

    /// Like `request`, but streams the body through the caller's `writer` instead of
    /// buffering it into a fixed `max_response_bytes` allocation — no cap on this path.
    /// Used for large object downloads (e.g. the S3 backend's `getToWriter`).
    ///
    /// The response status is known (from the response head) BEFORE any body byte is
    /// read. When `opts.discard_body_status` is set and the status is `>=` it, the body
    /// is drained into a bounded scratch sink instead of `writer` — `writer` is left
    /// completely untouched. This lets a caller retry the whole request on a retryable
    /// status (e.g. a 5xx) without a prior attempt's error body ending up in `writer`
    /// (see `s3.zig`'s `getToWriter`, whose retry-once contract requires `writer` to end
    /// up holding exactly one response body, not an error body followed by a real one).
    ///
    /// Once the status is below the threshold, `writer` starts receiving real bytes —
    /// from that point on there is no safe way to retry without risking a duplicated or
    /// partial body, so a failure past this point returns `error.StreamInterrupted`
    /// (transport broke mid-body) or `error.WriteFailed` (the destination `writer`
    /// itself failed, e.g. disk full) rather than the retryable `error.TransportFailed`.
    pub fn download(self: HttpClient, opts: RequestOptions, writer: *std.Io.Writer) !DownloadResult {
        // Same capture/mock seam as request(): a mocked body is written through the
        // writer, unless the mocked status hits the discard threshold (mirrors the real
        // path below).
        if (testcapture.enabled) {
            switch (try testcapture.http.intercept(self.alloc, opts)) {
                .passthrough => {},
                .response => |r| {
                    if (opts.discard_body_status == null or r.status < opts.discard_body_status.?) {
                        try writer.writeAll(r.body);
                    }
                    return .{ .status = r.status, .headers = r.headers };
                },
                .blocked => return error.TransportFailed,
            }
        }

        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        // Build extra request headers.
        const extra = try self.alloc.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

        // Use the lower-level std.http.Client.request() API (instead of the
        // convenience fetch()) so we can iterate response headers from the
        // parsed head before they are invalidated when we open the body reader.
        const uri = std.Uri.parse(opts.url) catch return error.TransportFailed;
        const method: std.http.Method = switch (opts.method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
        };
        // Mirror std.http.Client.fetch: follow up to 3 redirects for bodyless
        // requests; leave redirect handling to the caller for requests with a body.
        const redirect_behavior: std.http.Client.Request.RedirectBehavior =
            if (opts.body == null) @enumFromInt(3) else .unhandled;

        var req = client.request(method, uri, .{
            .extra_headers = extra,
            .redirect_behavior = redirect_behavior,
        }) catch return error.TransportFailed;
        defer req.deinit();

        if (opts.body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var bw = req.sendBodyUnflushed(&.{}) catch return error.TransportFailed;
            bw.writer.writeAll(payload) catch return error.TransportFailed;
            bw.end() catch return error.TransportFailed;
            req.connection.?.flush() catch return error.TransportFailed;
        } else {
            req.sendBodiless() catch return error.TransportFailed;
        }

        // RFC 9110 recommends 8 KiB redirect buffer.
        const redirect_buffer = try self.alloc.alloc(u8, 8 * 1024);
        var response = req.receiveHead(redirect_buffer) catch return error.TransportFailed;

        // Capture response headers NOW, before readerDecompressing() calls
        // head.invalidateStrings(), which zeroes out head.bytes and makes all
        // string slices inside Head dangle.  We dupe each name+value onto
        // self.alloc so they remain valid after the connection is torn down.
        var header_list: std.ArrayList(Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            try header_list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, h.name),
                .value = try self.alloc.dupe(u8, h.value),
            });
        }
        const captured_headers = try header_list.toOwnedSlice(self.alloc);
        const status: u16 = @intFromEnum(response.head.status);

        // A response DEFINED to have no body (see `responseHasNoBody`) is never read —
        // `writer` stays untouched, same as a normal small body below the discard
        // threshold would leave it if there were nothing to write. Force the
        // connection closed (see `request()`'s identical branch for why).
        if (responseHasNoBody(method, response.head.status)) {
            if (req.connection) |connection| connection.closing = true;
            return .{ .status = status, .headers = captured_headers };
        }

        // Read and optionally decompress the response body (mirrors fetch()), streaming
        // it through the caller's writer instead of a fixed buffer.
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.alloc.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.alloc.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.TransportFailed,
        };
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        if (opts.discard_body_status) |threshold| {
            if (status >= threshold) {
                // Drain (don't buffer — bodies of any size are fine) into a sink that
                // never fails, so `writer` stays untouched and this attempt is safely
                // retryable. A read failure mid-drain is still a plain transport error.
                var discard_buf: [512]u8 = undefined;
                var discarding = std.Io.Writer.Discarding.init(&discard_buf);
                _ = body_reader.streamRemaining(&discarding.writer) catch |err| switch (err) {
                    error.ReadFailed => return error.TransportFailed,
                    error.WriteFailed => {}, // Discarding.drain() never fails; nothing to do
                };
                return .{ .status = status, .headers = captured_headers };
            }
        }

        // Below the discard threshold (or no threshold set): stream straight into the
        // caller's `writer`. From here on a failure must NOT be treated as retryable —
        // `writer` may already hold partial bytes of this response.
        _ = body_reader.streamRemaining(writer) catch |err| switch (err) {
            error.ReadFailed => return error.StreamInterrupted, // transport broke mid-body; `writer` may hold a partial body
            error.WriteFailed => return error.WriteFailed, // the caller's writer failed (e.g. disk full)
        };

        // TLS certificate verification is on by default in std.http.Client;
        // do not disable it here.
        return .{ .status = status, .headers = captured_headers };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Minimal loopback TCP server that serves exactly one fixed HTTP response.
/// The listening socket is created (and its port resolved) before the server
/// thread is spawned, so there is no race between the test issuing a request
/// and the server being ready to accept.
///
/// The listener lives in this struct (NOT the thread). `stop()` closes the
/// listener first to unblock a thread parked in `accept()`, then joins — so
/// the test never deadlocks even if `client.get()` errors before connecting.
/// The thread owns only the accepted stream.
const TestHttpServer = struct {
    thread: std.Thread,
    server: std.Io.net.Server,
    port: u16,

    /// Start a server that emits `status_code` with `body` and no extra headers.
    fn start(body: []const u8, status_code: u16) !TestHttpServer {
        return startFull(body, status_code, "");
    }

    /// Start a server with additional response headers.
    ///
    /// `extra_headers` must be a pre-formatted CRLF-terminated header block,
    /// e.g. `"X-Foo: bar\r\nX-Baz: qux\r\n"`.  The backing memory must be
    /// valid for the lifetime of the server thread (string literals are fine).
    fn startFull(body: []const u8, status_code: u16, extra_headers: []const u8) !TestHttpServer {
        // Bind to 127.0.0.1:0 — the OS assigns an ephemeral port.
        var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(std.testing.io, .{});
        errdefer srv.deinit(std.testing.io);

        // The resolved port is available immediately after listen().
        const port = srv.socket.address.getPort();

        // The thread receives a by-value copy of the listener purely to call
        // accept() on the shared fd; it never deinits it. `stop()` owns the
        // close of the listener (exactly once).
        const thread = try std.Thread.spawn(.{}, serveOne, .{ srv, body, status_code, extra_headers });
        return .{ .thread = thread, .server = srv, .port = port };
    }

    fn stop(self: *TestHttpServer) void {
        // Close the listener first: this unblocks the thread if it is still
        // parked in accept() (e.g. the client errored before connecting),
        // then join so the thread has fully exited.
        self.server.deinit(std.testing.io);
        self.thread.join();
    }

    fn url(self: TestHttpServer, alloc: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{self.port});
    }

    /// Thread function: accept one connection, write the fixed HTTP response, close.
    /// `srv` is a by-value copy of the listener used only to accept; the thread
    /// must NOT deinit it (the listener is owned and closed by `stop()`). An
    /// accept() error (e.g. the listener closed during shutdown) is the normal
    /// shutdown path — the thread just returns cleanly.
    fn serveOne(srv: std.Io.net.Server, body: []const u8, status_code: u16, extra_headers: []const u8) void {
        var server = srv;

        const stream = server.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);

        // Drain the incoming request headers so the client does not see a
        // connection reset while it is still writing (even though for a small
        // GET this is usually fine, draining makes the fixture robust).
        var read_buf: [4096]u8 = undefined;
        var r = stream.reader(std.testing.io, &read_buf);
        var total: usize = 0;
        while (total < read_buf.len) {
            // peek(total + 1) tries to fill at least one more byte into the
            // internal buffer; on EndOfStream it returns what is available.
            const data = r.interface.peek(total + 1) catch break;
            total = data.len;
            if (std.mem.indexOf(u8, data, "\r\n\r\n") != null) break;
            if (total >= read_buf.len) break;
        }

        // Write the HTTP/1.1 response.  extra_headers is already CRLF-terminated
        // (or empty), so it slots in before the blank line.
        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(std.testing.io, &write_buf);
        w.interface.print(
            "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n{s}",
            .{ status_code, body.len, extra_headers, body },
        ) catch return;
        w.interface.flush() catch {};
    }

    /// Like `serveOne`, but for `responseHasNoBody` regression coverage: emits ONLY the
    /// status line + `extra_headers` (no `Content-Length`, no `Connection: close`, no
    /// blank-line body) and then holds the connection open for `hold_ms` before closing
    /// — mimicking a keep-alive server (MinIO) that never closes on its own. A correct
    /// client returns as soon as the headers are parsed, without waiting on `hold_ms`;
    /// a regressed client (trying to read a body this response is defined not to have)
    /// blocks until this forced close unblocks it — bounding the failure mode to
    /// `hold_ms`, not a real hang, so a regression fails the test slowly rather than
    /// wedging the suite.
    fn serveOneNoBodyThenHold(status_code: u16, extra_headers: []const u8, hold_ms: i64) !TestHttpServer {
        var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(std.testing.io, .{});
        errdefer srv.deinit(std.testing.io);
        const port = srv.socket.address.getPort();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(s: std.Io.net.Server, code: u16, headers: []const u8, ms: i64) void {
                var server = s;
                const stream = server.accept(std.testing.io) catch return;
                defer stream.close(std.testing.io);
                var read_buf: [4096]u8 = undefined;
                var r = stream.reader(std.testing.io, &read_buf);
                var total: usize = 0;
                while (total < read_buf.len) {
                    const data = r.interface.peek(total + 1) catch break;
                    total = data.len;
                    if (std.mem.indexOf(u8, data, "\r\n\r\n") != null) break;
                    if (total >= read_buf.len) break;
                }
                var write_buf: [4096]u8 = undefined;
                var w = stream.writer(std.testing.io, &write_buf);
                w.interface.print("HTTP/1.1 {d} OK\r\n{s}\r\n", .{ code, headers }) catch return;
                w.interface.flush() catch {};
                std.testing.io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
            }
        }.run, .{ srv, status_code, extra_headers, hold_ms });
        return .{ .thread = thread, .server = srv, .port = port };
    }
};

test "HttpClient.get returns status and body from a loopback server" {
    var server = try TestHttpServer.start("HELLO", 200);
    defer server.stop();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
    const res = try client.get(try server.url(arena.allocator()));
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("HELLO", res.body);
}

test "HttpClient.get captures response headers" {
    // The server emits an X-Test header alongside the body.
    var server = try TestHttpServer.startFull("WORLD", 200, "X-Test: hi\r\n");
    defer server.stop();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
    const res = try client.get(try server.url(arena.allocator()));

    // Status and body must still work.
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("WORLD", res.body);

    // Find the X-Test header and verify its value.
    var found = false;
    for (res.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Test")) {
            try std.testing.expectEqualStrings("hi", h.value);
            found = true;
        }
    }
    try std.testing.expect(found); // header must be present
}

test "HttpClient.download streams the body through the caller's writer" {
    var server = try TestHttpServer.start("STREAMED-BYTES", 200);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
    var buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    const res = try client.download(.{ .url = try server.url(arena.allocator()) }, &fw);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("STREAMED-BYTES", fw.buffered());
}

// Regression coverage for the ~30s MinIO DELETE/HEAD stall (see `responseHasNoBody`'s
// doc comment): a 204 with a misleadingly-present Content-Length, and a 204 with none
// at all, must both return near-instantly — NOT wait for the server to close the
// connection (`serveOneNoBodyThenHold`'s `hold_ms` — a correct client never sees it).

test "HttpClient.request: a 204 with a (misleading) Content-Length returns instantly, not after the server closes" {
    var server = try TestHttpServer.serveOneNoBodyThenHold(204, "Content-Length: 10\r\n", 2000);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const res = try client.request(.{ .method = .DELETE, .url = try server.url(arena.allocator()) });
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - t0.nanoseconds, std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 204), res.status);
    try std.testing.expectEqualStrings("", res.body);
    // Generous margin over near-instant; the server's forced close is 2000ms away, so
    // a regression (waiting for it) fails this by roughly 40x, never flakily.
    try std.testing.expect(elapsed_ms < 500);
}

test "HttpClient.request: a HEAD 200 with a real Content-Length returns instantly, not after the server closes" {
    var server = try TestHttpServer.serveOneNoBodyThenHold(200, "Content-Length: 12345\r\n", 2000);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const res = try client.request(.{ .method = .HEAD, .url = try server.url(arena.allocator()) });
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - t0.nanoseconds, std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(elapsed_ms < 500);
}

test "HttpClient.download: a 204 with no Content-Length at all returns instantly, not after the server closes" {
    var server = try TestHttpServer.serveOneNoBodyThenHold(204, "", 2000);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
    var buf: [16]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const res = try client.download(.{ .method = .DELETE, .url = try server.url(arena.allocator()) }, &fw);
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - t0.nanoseconds, std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 204), res.status);
    try std.testing.expectEqual(@as(usize, 0), fw.buffered().len);
    try std.testing.expect(elapsed_ms < 500);
}
