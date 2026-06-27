const std = @import("std");

pub const Method = enum { GET, POST, PUT, PATCH, DELETE };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const HttpResponse = struct { status: u16, headers: []const Header, body: []const u8 };

/// Options for a generic HTTP request.
///
/// Note: `timeout_ms` is stored for caller intent but `std.http.Client.fetch` in
/// Zig 0.16 does not expose a per-call timeout on the underlying socket. The field
/// is preserved here so call-sites can express a desired timeout today; it will be
/// wired up once the upstream API provides the hook.
pub const RequestOptions = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    max_response_bytes: usize = 1 << 20,
};

pub const PostOptions = struct { headers: []const Header = &.{}, body: ?[]const u8 = null };

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
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        const extra = try self.alloc.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

        const resp_buf = try self.alloc.alloc(u8, opts.max_response_bytes);
        var fw = std.Io.Writer.fixed(resp_buf);

        const res = client.fetch(.{
            .location = .{ .url = opts.url },
            .method = switch (opts.method) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .PATCH => .PATCH,
                .DELETE => .DELETE,
            },
            .payload = opts.body,
            .extra_headers = extra,
            .response_writer = &fw,
        }) catch |e| return switch (e) {
            error.WriteFailed => error.ResponseTooLarge,
            else => error.TransportFailed,
        };

        // TLS certificate verification is on by default in std.http.Client;
        // do not disable it here.
        return .{
            .status = @intFromEnum(res.status),
            .headers = &.{},
            .body = fw.buffered(),
        };
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

    fn start(body: []const u8, status_code: u16) !TestHttpServer {
        // Bind to 127.0.0.1:0 — the OS assigns an ephemeral port.
        var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(std.testing.io, .{});
        errdefer srv.deinit(std.testing.io);

        // The resolved port is available immediately after listen().
        const port = srv.socket.address.getPort();

        // The thread receives a by-value copy of the listener purely to call
        // accept() on the shared fd; it never deinits it. `stop()` owns the
        // close of the listener (exactly once).
        const thread = try std.Thread.spawn(.{}, serveOne, .{ srv, body, status_code });
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
    fn serveOne(srv: std.Io.net.Server, body: []const u8, status_code: u16) void {
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

        // Write the HTTP/1.1 response.
        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(std.testing.io, &write_buf);
        w.interface.print(
            "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ status_code, body.len, body },
        ) catch return;
        w.interface.flush() catch {};
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
