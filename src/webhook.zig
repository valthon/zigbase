//! Outbound webhook delivery (#144, wave-2 PR5) — a built-in `"webhook"` job kind
//! that rides the generic queue engine (`src/queue/*`).
//!
//! `ctx.webhook(url, payload, .{…})` serializes the request into a durable/memory
//! job whose handler (`webhookJobHandler`) POSTs the body over `ctx.http()` and
//! classifies the response:
//!
//!   * retryable — a transport/network error, any 5xx, or a 429 (whose `Retry-After`
//!     header, when an integer count of seconds, is honored in preference to the
//!     configured backoff);
//!   * terminal  — any other 4xx (and 1xx/3xx): the receiver rejected the delivery,
//!     so hammering it is pointless.
//!
//! Retries use the queue's backoff math (`queue.backoffMs`) up to `max_attempts`.
//! When delivery is terminally rejected OR attempts are exhausted, the handler fires
//! `.onError` with phase `.webhook` (NOT `.job`) and returns success so the queue does
//! not double-retry — this module owns the full delivery lifecycle.
//!
//! Security:
//!   * Optional HMAC-SHA256 body signing — the receiver can verify authenticity by
//!     recomputing `hex(HMAC-SHA256(secret, "<timestamp>.<body>"))` and comparing it to
//!     the `X-Signature` header (timestamp in `X-Webhook-Timestamp`). A fresh timestamp
//!     (and therefore signature) is produced per attempt; the signed string binds the
//!     timestamp so a captured request cannot be replayed indefinitely.
//!   * An idempotency key (`Idempotency-Key` header) is generated ONCE by `ctx.webhook`
//!     and stored in the job payload — which, for a durable queue, lives on the
//!     `_queue_jobs` row — so every retry (and any at-least-once replay after a crash)
//!     reuses the SAME key, letting the receiver dedupe.
//!   * TLS verification stays on (the `http_client` default); do not disable it.
//!
//! NOTE: a durable, signed webhook persists the signing `secret` inside the
//! `_queue_jobs.payload` column (the consumer's own DB). Prefer a `memory` queue, a
//! short `done_ttl_s`, or DB-at-rest encryption if that is a concern.

const std = @import("std");
const events = @import("events.zig");
const queue = @import("queue/queue.zig");
const http_client = @import("http_client.zig");
const clock = @import("clock.zig");
const entropy = @import("entropy.zig");
const Ctx = @import("ctx.zig").Ctx;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The reserved job kind under which webhook deliveries are enqueued.
pub const job_kind = "webhook";

/// Errors surfaced to `.onError` (phase `.webhook`) when a delivery cannot be made.
pub const WebhookError = error{ WebhookDeliveryFailed, WebhookPayloadInvalid };

/// Optional HMAC-SHA256 signing config (the `sign` field of `WebhookOpts`). The body is
/// signed as `HMAC-SHA256(secret, "<unix_ts>.<body>")` and the hex digest placed in
/// `signature_header`; the timestamp goes in `timestamp_header`.
pub const Hmac = struct {
    secret: []const u8,
    signature_header: []const u8 = "X-Signature",
    timestamp_header: []const u8 = "X-Webhook-Timestamp",
};

/// Caller-facing options for `ctx.webhook`.
pub const WebhookOpts = struct {
    /// Queue to enqueue on; `null` → the synthesized `"default"` (memory) queue.
    queue: ?[]const u8 = null,
    /// Maximum number of delivery attempts (1 = no retry).
    retries: u16 = 5,
    /// Backoff growth between retries (`queue.backoffMs` math; base 1s, cap 5m, jitter on).
    backoff: queue.Backoff = .exponential,
    /// Per-attempt request timeout, in seconds.
    timeout_s: u32 = 10,
    /// Optional HMAC-SHA256 body signing.
    sign: ?Hmac = null,
    /// Send a stable `Idempotency-Key` header (generated once, reused across retries).
    idempotency: bool = true,
};

/// The durable, JSON-serialized representation of a queued webhook delivery (the queue
/// job payload). All retry/backoff parameters are frozen at enqueue time so a replay
/// after a code change still behaves as originally requested.
pub const WebhookJob = struct {
    url: []const u8,
    body: []const u8,
    idempotency_key: ?[]const u8 = null,
    idempotency_header: []const u8 = "Idempotency-Key",
    sign: ?Hmac = null,
    max_attempts: u16 = 5,
    backoff: queue.Backoff = .exponential,
    base_ms: u32 = 1000,
    max_ms: u32 = 300_000,
    jitter: bool = true,
    timeout_ms: u32 = 10_000,

    fn policy(self: WebhookJob) queue.RetryPolicy {
        return .{
            .max_attempts = self.max_attempts,
            .backoff = self.backoff,
            .base_ms = self.base_ms,
            .max_ms = self.max_ms,
            .jitter = self.jitter,
        };
    }
};

/// Disposition of a single delivery attempt.
const Disposition = union(enum) {
    /// 2xx — delivered.
    ok,
    /// A 4xx (other than 429) / 1xx / 3xx — the receiver rejected it; stop.
    terminal: u16,
    /// Transport error / 5xx / 429 — retry. The payload is the server-requested delay in
    /// ms (from a 429 `Retry-After`), or `null` to fall back to the configured backoff.
    retryable: ?u32,
};

/// The built-in `"webhook"` job handler (registered by `framework.zig`). `payload` is the
/// JSON-serialized `WebhookJob`. Always returns success (the handler owns retries and the
/// terminal `.onError`), except when the payload itself cannot be parsed.
pub fn webhookJobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    // `…Leaky` parses directly into `ctx.arena` (which owns every allocation and is freed
    // wholesale at job end) — no nested `Parsed(T)` arena to `deinit`.
    const job = std.json.parseFromSliceLeaky(WebhookJob, ctx.arena, payload, .{}) catch {
        // A malformed payload is a programmer error, not a transient delivery failure:
        // surface it on the webhook phase and do not retry.
        fireOnError(ctx, error.WebhookPayloadInvalid, "webhook job payload is not valid JSON");
        return;
    };
    return deliver(ctx, job);
}

/// Run the full delivery lifecycle for `job`: attempt, classify, back off, retry, and on a
/// terminal rejection or exhausted attempts fire `.onError` (phase `.webhook`).
pub fn deliver(ctx: *Ctx, job: WebhookJob) !void {
    const pol = job.policy();
    const max: u32 = if (job.max_attempts == 0) 1 else job.max_attempts;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        switch (try attemptOnce(ctx, job)) {
            .ok => return,
            .terminal => |status| {
                const msg = std.fmt.allocPrint(ctx.arena, "webhook POST {s} rejected with HTTP {d} (terminal)", .{ job.url, status }) catch "webhook delivery rejected (terminal)";
                fireOnError(ctx, error.WebhookDeliveryFailed, msg);
                return;
            },
            .retryable => |retry_after_ms| {
                if (attempt >= max) {
                    const msg = std.fmt.allocPrint(ctx.arena, "webhook POST {s} failed after {d} attempt(s)", .{ job.url, attempt }) catch "webhook delivery failed (attempts exhausted)";
                    fireOnError(ctx, error.WebhookDeliveryFailed, msg);
                    return;
                }
                const raw_delay = retry_after_ms orelse queue.backoffMs(pol, attempt, randomU64(ctx.app.io));
                const delay_ms = cappedDelayMs(raw_delay, job.max_ms);
                if (delay_ms > 0)
                    ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(delay_ms), .awake) catch {};
            },
        }
    }
}

/// Perform ONE POST and classify the outcome. A transport/network error is retryable.
fn attemptOnce(ctx: *Ctx, job: WebhookJob) !Disposition {
    var headers: std.ArrayList(http_client.Header) = .empty;
    try headers.append(ctx.arena, .{ .name = "Content-Type", .value = "application/json" });
    if (job.idempotency_key) |k|
        try headers.append(ctx.arena, .{ .name = job.idempotency_header, .value = k });
    if (job.sign) |s| {
        const ts = try std.fmt.allocPrint(ctx.arena, "{d}", .{clock.nowUnix(ctx.app.io)});
        const sig = try signBody(ctx.arena, s.secret, ts, job.body);
        try headers.append(ctx.arena, .{ .name = s.timestamp_header, .value = ts });
        try headers.append(ctx.arena, .{ .name = s.signature_header, .value = sig });
    }

    const res = ctx.http().request(.{
        .method = .POST,
        .url = job.url,
        .headers = headers.items,
        .body = job.body,
        .timeout_ms = job.timeout_ms,
    }) catch {
        // Network / DNS / TLS / connection error — transient; retry.
        return .{ .retryable = null };
    };
    return classify(res.status, retryAfterMs(res.headers));
}

/// Cap a retry wait at the policy's `max_ms`. The delivery TARGET controls the
/// `Retry-After` header AND these backoff sleeps occupy the worker thread, so an
/// unbounded server value (e.g. `Retry-After: 999999`) would otherwise let a hostile or
/// misconfigured receiver park a worker for days and starve the background pool. The
/// `backoffMs` path is already capped at `max_ms`; this clamps the `Retry-After` override
/// to the same ceiling. (Pure + separated for direct testing.)
fn cappedDelayMs(raw_delay_ms: u32, max_ms: u32) u32 {
    return @min(raw_delay_ms, max_ms);
}

/// Pure status classifier (separated for direct testing).
fn classify(status: u16, retry_after_ms: ?u32) Disposition {
    if (status >= 200 and status < 300) return .ok;
    if (status == 429) return .{ .retryable = retry_after_ms };
    if (status >= 500 and status < 600) return .{ .retryable = null };
    // 1xx / 3xx / other 4xx → terminal.
    return .{ .terminal = status };
}

/// `hex(HMAC-SHA256(secret, "<timestamp>.<body>"))`. Public so receivers/tests can
/// recompute and compare.
pub fn signBody(alloc: std.mem.Allocator, secret: []const u8, timestamp: []const u8, body: []const u8) ![]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var h = HmacSha256.init(secret);
    h.update(timestamp);
    h.update(".");
    h.update(body);
    h.final(&mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return alloc.dupe(u8, &hex);
}

/// Parse a `Retry-After` header (integer seconds form only) into ms; `null` when absent or
/// not an integer (HTTP-date form falls back to the configured backoff).
fn retryAfterMs(headers: []const http_client.Header) ?u32 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Retry-After")) {
            const trimmed = std.mem.trim(u8, h.value, " \t");
            const secs = std.fmt.parseInt(u32, trimmed, 10) catch return null;
            return std.math.mul(u32, secs, 1000) catch std.math.maxInt(u32);
        }
    }
    return null;
}

fn fireOnError(ctx: *Ctx, err: anyerror, message: []const u8) void {
    // `.ctx = null`: a webhook delivery runs as a queued BACKGROUND JOB (the queue builds
    // its Ctx with `.rctx = .{}, .request = null`), so there is no request/auth context to
    // surface — matching the `.job`/`.cron` background-error dispatches (scheduler.zig,
    // queue/durable.zig, queue/memory.zig), which all pass `null`. Passing `&ctx.rctx` here
    // would falsely advertise an empty default RequestContext to `onError` consumers.
    var ev = events.ErrorEvent{ .app = ctx.app, .ctx = null, .err = err, .phase = .webhook, .message = message };
    events.dispatchError(ctx.app, ctx.app.dispatch, &ev);
}

fn randomU64(io: std.Io) u64 {
    var b: [8]u8 = undefined;
    entropy.fill(io, &b);
    return std.mem.readInt(u64, &b, .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const App = @import("app.zig").App;
const sentry = @import("sentry.zig");

fn noopSink(_: []const u8) void {}

test "classify maps status families to dispositions" {
    try testing.expectEqual(Disposition.ok, classify(200, null));
    try testing.expectEqual(Disposition.ok, classify(204, null));
    // 4xx (not 429) is terminal.
    try testing.expectEqual(@as(u16, 404), classify(404, null).terminal);
    try testing.expectEqual(@as(u16, 400), classify(400, null).terminal);
    try testing.expectEqual(@as(u16, 401), classify(401, null).terminal);
    // 5xx is retryable (backoff).
    try testing.expect(classify(500, null).retryable == null);
    try testing.expect(classify(503, null).retryable == null);
    // 429 is retryable and honors a server delay when present.
    try testing.expectEqual(@as(?u32, null), classify(429, null).retryable);
    try testing.expectEqual(@as(?u32, 2000), classify(429, 2000).retryable);
    // 3xx is terminal (redirects are not followed for POST).
    try testing.expectEqual(@as(u16, 302), classify(302, null).terminal);
}

test "signBody is HMAC-SHA256 over '<ts>.<body>' and is deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sig1 = try signBody(a, "shh", "1700000000", "{\"x\":1}");
    const sig2 = try signBody(a, "shh", "1700000000", "{\"x\":1}");
    try testing.expectEqualStrings(sig1, sig2); // deterministic
    try testing.expectEqual(@as(usize, 64), sig1.len); // 32-byte digest, hex

    // Cross-check against a hand-computed HMAC over the exact signed string.
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, "1700000000.{\"x\":1}", "shh");
    const expect = std.fmt.bytesToHex(mac, .lower);
    try testing.expectEqualStrings(&expect, sig1);

    // A different timestamp or body changes the signature.
    const sig3 = try signBody(a, "shh", "1700000001", "{\"x\":1}");
    try testing.expect(!std.mem.eql(u8, sig1, sig3));
}

test "retryAfterMs parses integer seconds, ignores garbage/HTTP-date" {
    try testing.expectEqual(@as(?u32, 3000), retryAfterMs(&.{.{ .name = "Retry-After", .value = "3" }}));
    try testing.expectEqual(@as(?u32, 0), retryAfterMs(&.{.{ .name = "retry-after", .value = " 0 " }}));
    try testing.expectEqual(@as(?u32, null), retryAfterMs(&.{.{ .name = "Retry-After", .value = "Wed, 21 Oct 2015 07:28:00 GMT" }}));
    try testing.expectEqual(@as(?u32, null), retryAfterMs(&.{.{ .name = "X-Other", .value = "5" }}));
}

test "cappedDelayMs clamps a huge Retry-After to max_ms (worker-stall DoS guard)" {
    // A hostile/misconfigured Retry-After far above the ceiling is clamped to max_ms…
    try testing.expectEqual(@as(u32, 300_000), cappedDelayMs(999_999_000, 300_000));
    try testing.expectEqual(@as(u32, 5_000), cappedDelayMs(std.math.maxInt(u32), 5_000));
    // …while a value at/under the ceiling passes through unchanged.
    try testing.expectEqual(@as(u32, 2_000), cappedDelayMs(2_000, 300_000));
    try testing.expectEqual(@as(u32, 300_000), cappedDelayMs(300_000, 300_000));
    try testing.expectEqual(@as(u32, 0), cappedDelayMs(0, 300_000));
}

// --- Loopback integration ---------------------------------------------------
//
// A small HTTP server that records each request's interesting headers + body and
// replies with a scripted per-request status (clamped to the last entry), so we can
// drive retry/terminal/idempotency/signature behavior end-to-end.

const RecordedRequest = struct {
    idempotency: []u8,
    signature: []u8,
    timestamp: []u8,
    body: []u8,
};

const Recorder = struct {
    mutex: std.atomic.Mutex = .unlocked,
    alloc: std.mem.Allocator,
    statuses: []const u16,
    retry_after: []const u8, // CRLF-terminated header block sent with EVERY response (or "")
    requests: std.ArrayList(RecordedRequest) = .empty,
    stop_flag: bool = false, // set by stop(); serveLoop exits on the next accept

    fn lock(self: *Recorder) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Recorder) void {
        self.mutex.unlock();
    }

    fn count(self: *Recorder) usize {
        self.lock();
        defer self.unlock();
        return self.requests.items.len;
    }
};

const WebhookTestServer = struct {
    thread: std.Thread,
    server: std.Io.net.Server,
    port: u16,
    rec: *Recorder,

    fn start(rec: *Recorder) !WebhookTestServer {
        var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(std.testing.io, .{});
        errdefer srv.deinit(std.testing.io);
        const port = srv.socket.address.getPort();
        const thread = try std.Thread.spawn(.{}, serveLoop, .{ srv, rec });
        return .{ .thread = thread, .server = srv, .port = port, .rec = rec };
    }

    fn stop(self: *WebhookTestServer) void {
        // Signal the loop, then wake the thread if it is parked in accept() by making a
        // throwaway self-connection. (Closing the listener fd alone does NOT reliably
        // unblock a concurrent blocking accept() on Linux — hence the explicit wake.)
        @atomicStore(bool, &self.rec.stop_flag, true, .release);
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (addr.connect(std.testing.io, .{ .mode = .stream })) |s| {
            s.close(std.testing.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(std.testing.io);
    }

    fn url(self: WebhookTestServer, alloc: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/hook", .{self.port});
    }

    fn serveLoop(srv: std.Io.net.Server, rec: *Recorder) void {
        var server = srv;
        while (true) {
            const stream = server.accept(std.testing.io) catch return; // listener closed → exit
            if (@atomicLoad(bool, &rec.stop_flag, .acquire)) {
                stream.close(std.testing.io); // the wake connection — drain and exit
                return;
            }
            serveConn(stream, rec);
            stream.close(std.testing.io);
        }
    }

    fn headerValue(block: []const u8, name: []const u8) []const u8 {
        var it = std.mem.splitSequence(u8, block, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name))
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return "";
    }

    fn serveConn(stream: std.Io.net.Stream, rec: *Recorder) void {
        var read_buf: [16 * 1024]u8 = undefined;
        var r = stream.reader(std.testing.io, &read_buf);
        const ri = &r.interface;

        // Phase 1: grow the buffer (by TCP segment) until the header terminator is present.
        var headers_end: usize = 0;
        var content_len: usize = 0;
        var have_headers = false;
        while (true) {
            const got = ri.peekGreedy(ri.bufferedLen() + 1) catch break; // EOF / closed
            if (std.mem.indexOf(u8, got, "\r\n\r\n")) |idx| {
                headers_end = idx + 4;
                content_len = std.fmt.parseInt(usize, headerValue(got[0..idx], "Content-Length"), 10) catch 0;
                have_headers = true;
                break;
            }
            if (ri.bufferedLen() >= read_buf.len) break; // oversized headers — give up
        }

        // Phase 2: ensure the full body is buffered (exact Content-Length); fall back to
        // whatever is buffered so a mismatch can never block the server forever.
        const need = headers_end + content_len;
        const req: []const u8 = if (have_headers) (ri.peek(need) catch ri.buffered()) else ri.buffered();

        // Record the request under the lock.
        rec.lock();
        const idx = rec.requests.items.len;
        if (have_headers) {
            const he = headers_end;
            const hdr_block = req[0..@min(he, req.len)];
            const body = if (req.len >= he + content_len) req[he .. he + content_len] else req[@min(he, req.len)..];
            rec.requests.append(rec.alloc, .{
                .idempotency = rec.alloc.dupe(u8, headerValue(hdr_block, "Idempotency-Key")) catch &.{},
                .signature = rec.alloc.dupe(u8, headerValue(hdr_block, "X-Signature")) catch &.{},
                .timestamp = rec.alloc.dupe(u8, headerValue(hdr_block, "X-Webhook-Timestamp")) catch &.{},
                .body = rec.alloc.dupe(u8, body) catch &.{},
            }) catch {};
        }
        const status = if (rec.statuses.len == 0) 200 else rec.statuses[@min(idx, rec.statuses.len - 1)];
        const extra = rec.retry_after;
        rec.unlock();

        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(std.testing.io, &write_buf);
        w.interface.print(
            "HTTP/1.1 {d} X\r\nContent-Length: 2\r\n{s}Connection: close\r\n\r\nok",
            .{ status, extra },
        ) catch return;
        w.interface.flush() catch {};
    }
};

fn deinitRecorder(rec: *Recorder) void {
    for (rec.requests.items) |q| {
        rec.alloc.free(q.idempotency);
        rec.alloc.free(q.signature);
        rec.alloc.free(q.timestamp);
        rec.alloc.free(q.body);
    }
    rec.requests.deinit(rec.alloc);
}

// onError capture
var wh_err_count: usize = 0;
fn onWhErr(ev: *events.ErrorEvent) void {
    _ = ev;
    wh_err_count += 1;
}

const DeliverEnv = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    dispatch: events.Dispatch,

    fn init() DeliverEnv {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined },
            .dispatch = .{ .on_error = onWhErr },
        };
    }
    fn ctx(self: *DeliverEnv) Ctx {
        self.app.dispatch = &self.dispatch;
        return Ctx{ .app = &self.app, .arena = self.arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
    }
    fn deinit(self: *DeliverEnv) void {
        self.arena.deinit();
    }
};

test "deliver: 2xx on first attempt succeeds, no onError, sends idempotency key" {
    wh_err_count = 0;
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{200}, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{\"event\":\"ping\"}",
        .idempotency_key = "idem-abc",
        .max_attempts = 5,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 1), rec.count());
    try testing.expectEqual(@as(usize, 0), wh_err_count);
    try testing.expectEqualStrings("idem-abc", rec.requests.items[0].idempotency);
    try testing.expectEqualStrings("{\"event\":\"ping\"}", rec.requests.items[0].body);
}

test "deliver: 5xx retried then terminal fires .onError(.webhook)" {
    wh_err_count = 0;
    sentry.log_sink = noopSink;
    defer sentry.log_sink = null;
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{503}, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{}",
        .max_attempts = 3,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 3), rec.count()); // all attempts made
    try testing.expectEqual(@as(usize, 1), wh_err_count); // exactly one terminal onError
}

test "deliver: 4xx is immediately terminal (no retry)" {
    wh_err_count = 0;
    sentry.log_sink = noopSink;
    defer sentry.log_sink = null;
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{404}, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{}",
        .max_attempts = 5,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 1), rec.count()); // only one request
    try testing.expectEqual(@as(usize, 1), wh_err_count);
}

test "deliver: 429 with Retry-After is retried (not terminal) then succeeds" {
    wh_err_count = 0;
    // 429 (with Retry-After: 0) then 200: the 429 must be treated as retryable, not terminal,
    // and the integer Retry-After is honored as the (zero) delay. (The Retry-After *value*
    // plumbing is proven deterministically by the `classify` / `retryAfterMs` unit tests.)
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{ 429, 200 }, .retry_after = "Retry-After: 0\r\n" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{}",
        .max_attempts = 5,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 2), rec.count());
    try testing.expectEqual(@as(usize, 0), wh_err_count);
}

test "deliver: HMAC signature + timestamp are correct and verifiable" {
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{200}, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const body = "{\"id\":42}";
    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = body,
        .sign = .{ .secret = "topsecret" },
        .max_attempts = 1,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 1), rec.count());
    const got = rec.requests.items[0];
    try testing.expect(got.timestamp.len > 0);
    try testing.expect(got.signature.len == 64);
    // Recompute the signature exactly as a receiver would.
    const expect = try signBody(env.arena.allocator(), "topsecret", got.timestamp, got.body);
    try testing.expectEqualStrings(expect, got.signature);
}

test "deliver: idempotency key is stable across retries" {
    wh_err_count = 0;
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{ 503, 503, 200 }, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{}",
        .idempotency_key = "stable-key-123",
        .max_attempts = 3,
        .base_ms = 0,
        .jitter = false,
    };
    try deliver(&cx, job);
    try testing.expectEqual(@as(usize, 3), rec.count());
    try testing.expectEqual(@as(usize, 0), wh_err_count); // third attempt succeeded
    for (rec.requests.items) |q|
        try testing.expectEqualStrings("stable-key-123", q.idempotency);
}

test "webhookJobHandler parses the JSON payload and delivers" {
    var rec = Recorder{ .alloc = testing.allocator, .statuses = &.{200}, .retry_after = "" };
    defer deinitRecorder(&rec);
    var server = try WebhookTestServer.start(&rec);
    defer server.stop();

    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();

    const job = WebhookJob{
        .url = try server.url(env.arena.allocator()),
        .body = "{\"hello\":\"world\"}",
        .idempotency_key = "via-handler",
        .max_attempts = 1,
        .base_ms = 0,
        .jitter = false,
    };
    const payload = try std.json.Stringify.valueAlloc(env.arena.allocator(), job, .{});
    try webhookJobHandler(&cx, payload);
    try testing.expectEqual(@as(usize, 1), rec.count());
    try testing.expectEqualStrings("via-handler", rec.requests.items[0].idempotency);
    try testing.expectEqualStrings("{\"hello\":\"world\"}", rec.requests.items[0].body);
}

test "webhookJobHandler: a malformed payload fires .onError(.webhook), no throw" {
    wh_err_count = 0;
    sentry.log_sink = noopSink;
    defer sentry.log_sink = null;
    var env = DeliverEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    defer cx.deinit();
    try webhookJobHandler(&cx, "{ not json");
    try testing.expectEqual(@as(usize, 1), wh_err_count);
}
