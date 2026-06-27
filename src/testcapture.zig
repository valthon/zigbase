//! Dev-only in-memory capture of outbound MAIL and outbound `ctx.http()` calls, so an
//! e2e/integration suite can deterministically assert what the framework *sent* and inject
//! canned HTTP responses instead of hitting the network. Pairs with the determinism seam
//! (`clock.zig`): same comptime gate, same "compiled out in release" contract.
//!
//! ## Two seams
//! - **Mail outbox** — `Mailer.send` (the one vtable chokepoint every backend routes
//!   through) records each email here when capture is on. Real delivery still happens
//!   unless capture was enabled with `suppress = true`.
//! - **HTTP capture/mock** — `HttpClient.request` (what `ctx.http()` returns) consults
//!   `http.intercept` before touching the network: it records the request and, if a mock
//!   matches the URL, returns a canned response with no network at all.
//!
//! ## Production gate (hard requirement)
//! Everything here is gated by the `dev_clock` build option (the same flag that gates the
//! test clock — on in `Debug`, forced off by the release script's cross-compiles). When
//! `enabled` is `comptime false`, every call site (`if (testcapture.enabled) { … }`) is
//! comptime-dead and dead-code-eliminated, so a production binary is byte-for-byte
//! unaffected and carries no runtime branch or perf cost. The public fns also early-return
//! when `!enabled`, so even a direct call from a release-built test is a no-op.
//!
//! ## Memory model
//! Each seam keeps a process-global, mutex-guarded store backed by a lazily-created arena
//! over `std.heap.page_allocator` (NOT `std.testing.allocator`, so nothing trips leak
//! detection across tests). `record`/`mock` dupe inputs into that arena; `reset()` frees it.
//! HTTP mock *responses* are duped onto the CALLER's allocator at return time, so they share
//! the normal response lifetime (the Ctx arena) and never dangle.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const http_client = @import("http_client.zig");

/// Comptime gate. True only on a `dev_clock`-enabled build (Debug by default; never a
/// release/prod build). When false every capture branch is comptime-dead.
pub const enabled = build_options.dev_clock;

/// Spin-acquire `m` (matches the `std.atomic.Mutex` idiom used elsewhere, e.g. ratelimit.zig).
/// Contention is near-zero here — this is a dev-only, single-suite facility.
fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

// ---------------------------------------------------------------------------
// Mail outbox
// ---------------------------------------------------------------------------

/// A captured outbound email. `from` is the configured backend sender (empty for
/// `LogMailer`, which has no `from`); `to`/`subject`/`body` come from the `Email`.
pub const MailEntry = struct {
    from: []const u8,
    to: []const u8,
    subject: []const u8,
    body: []const u8,
};

const MailState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    arena: ?std.heap.ArenaAllocator = null,
    list: std.ArrayListUnmanaged(MailEntry) = .empty,
    capturing: bool = false,
    suppress: bool = false,

    /// Lazily create the backing arena (over page_allocator — untracked by leak detection).
    fn alloc(self: *MailState) std.mem.Allocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return self.arena.?.allocator();
    }
};

var g_mail: MailState = .{};

/// Test-facing mail outbox API. All ops are no-ops / empty on a prod build (gated).
pub const mail = struct {
    /// Begin capturing outbound mail. `suppress = true` records the email and SKIPS real
    /// delivery (the deterministic e2e mode — no SMTP, no log line); `false` records AND
    /// still delivers. Does not clear previously captured entries (use `reset`).
    pub fn enable(suppress: bool) void {
        if (!enabled) return;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        g_mail.capturing = true;
        g_mail.suppress = suppress;
    }

    /// Stop capturing (keep already-captured entries readable).
    pub fn disable() void {
        if (!enabled) return;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        g_mail.capturing = false;
    }

    /// Clear all captured entries, stop capturing, and free the backing arena.
    pub fn reset() void {
        if (!enabled) return;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        if (g_mail.arena) |*a| a.deinit();
        g_mail.arena = null;
        g_mail.list = .empty;
        g_mail.capturing = false;
        g_mail.suppress = false;
    }

    /// Number of captured emails.
    pub fn count() usize {
        if (!enabled) return 0;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        return g_mail.list.items.len;
    }

    /// The i-th captured email (slices live until the next `reset`), or null.
    pub fn get(i: usize) ?MailEntry {
        if (!enabled) return null;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        if (i >= g_mail.list.items.len) return null;
        return g_mail.list.items[i];
    }

    /// All captured emails (slice valid until the next `reset`/`record`).
    pub fn entries() []const MailEntry {
        if (!enabled) return &.{};
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        return g_mail.list.items;
    }

    /// First captured email whose subject contains `needle`, or null.
    pub fn find(needle: []const u8) ?MailEntry {
        if (!enabled) return null;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        for (g_mail.list.items) |e| {
            if (std.mem.indexOf(u8, e.subject, needle) != null) return e;
        }
        return null;
    }

    /// Hook called from `Mailer.send`. No-op unless capture is on. Always returns; failures
    /// to dupe (OOM) are swallowed so a test-capture hiccup never breaks a send path.
    pub fn record(from: []const u8, to: []const u8, subject: []const u8, body: []const u8) void {
        if (!enabled) return;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        if (!g_mail.capturing) return;
        const a = g_mail.alloc();
        const entry = MailEntry{
            .from = a.dupe(u8, from) catch return,
            .to = a.dupe(u8, to) catch return,
            .subject = a.dupe(u8, subject) catch return,
            .body = a.dupe(u8, body) catch return,
        };
        g_mail.list.append(a, entry) catch {};
    }

    /// Whether the active capture mode suppresses real delivery. Read by `Mailer.send`.
    pub fn suppressed() bool {
        if (!enabled) return false;
        lockMutex(&g_mail.mutex);
        defer g_mail.mutex.unlock();
        return g_mail.capturing and g_mail.suppress;
    }
};

// ---------------------------------------------------------------------------
// HTTP capture / mock
// ---------------------------------------------------------------------------

/// A captured outbound HTTP request (from `ctx.http()`).
pub const HttpRequest = struct {
    method: http_client.Method,
    url: []const u8,
    headers: []const http_client.Header,
    body: ?[]const u8,
};

/// A canned HTTP response a test registers for a URL substring.
pub const MockResponse = struct {
    status: u16 = 200,
    headers: []const http_client.Header = &.{},
    body: []const u8 = "",
};

const Mock = struct {
    url_substring: []const u8,
    resp: MockResponse,
};

/// Result of consulting the HTTP capture before a real request.
pub const Outcome = union(enum) {
    /// Not capturing (or unmocked + passthrough allowed) — caller hits the real network.
    passthrough,
    /// A canned response (already duped onto the caller's allocator).
    response: http_client.HttpResponse,
    /// Unmocked URL while `block_unmocked` is set — caller must NOT hit the network.
    blocked,
};

const HttpState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    arena: ?std.heap.ArenaAllocator = null,
    requests: std.ArrayListUnmanaged(HttpRequest) = .empty,
    mocks: std.ArrayListUnmanaged(Mock) = .empty,
    capturing: bool = false,
    block_unmocked: bool = true,

    fn alloc(self: *HttpState) std.mem.Allocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return self.arena.?.allocator();
    }
};

var g_http: HttpState = .{};

/// Dupe a header slice onto `a`.
fn dupeHeaders(a: std.mem.Allocator, headers: []const http_client.Header) ![]http_client.Header {
    const out = try a.alloc(http_client.Header, headers.len);
    for (headers, 0..) |h, i| out[i] = .{
        .name = try a.dupe(u8, h.name),
        .value = try a.dupe(u8, h.value),
    };
    return out;
}

/// Test-facing HTTP capture/mock API. All ops are no-ops / empty on a prod build (gated).
pub const http = struct {
    /// Begin capturing outbound HTTP. `block_unmocked = true` (recommended) makes a request
    /// to an un-mocked URL fail (`error.TransportFailed`) rather than silently hit the
    /// network, keeping tests deterministic; `false` lets un-mocked URLs pass through.
    pub fn enable(block_unmocked: bool) void {
        if (!enabled) return;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        g_http.capturing = true;
        g_http.block_unmocked = block_unmocked;
    }

    /// Stop capturing (keep recorded requests + mocks).
    pub fn disable() void {
        if (!enabled) return;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        g_http.capturing = false;
    }

    /// Clear recorded requests + mocks, stop capturing, and free the backing arena.
    pub fn reset() void {
        if (!enabled) return;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        if (g_http.arena) |*a| a.deinit();
        g_http.arena = null;
        g_http.requests = .empty;
        g_http.mocks = .empty;
        g_http.capturing = false;
        g_http.block_unmocked = true;
    }

    /// Register a canned response returned for any request whose URL contains `url_substring`.
    /// Later registrations win on overlap (matched newest-first). The response is copied into
    /// the capture arena, so callers may pass transient buffers.
    pub fn mock(url_substring: []const u8, resp: MockResponse) void {
        if (!enabled) return;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        const a = g_http.alloc();
        const m = Mock{
            .url_substring = a.dupe(u8, url_substring) catch return,
            .resp = .{
                .status = resp.status,
                .headers = dupeHeaders(a, resp.headers) catch return,
                .body = a.dupe(u8, resp.body) catch return,
            },
        };
        g_http.mocks.append(a, m) catch {};
    }

    /// Number of captured requests.
    pub fn requestCount() usize {
        if (!enabled) return 0;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        return g_http.requests.items.len;
    }

    /// The i-th captured request (slices live until the next `reset`), or null.
    pub fn requestAt(i: usize) ?HttpRequest {
        if (!enabled) return null;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        if (i >= g_http.requests.items.len) return null;
        return g_http.requests.items[i];
    }

    /// All captured requests (slice valid until the next `reset`/`intercept`).
    pub fn requests() []const HttpRequest {
        if (!enabled) return &.{};
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        return g_http.requests.items;
    }

    /// Consult the capture before a real request. Called from `HttpClient.request`.
    /// Records the request (when capturing) and returns the canned response — duped onto
    /// `caller_alloc` (the Ctx arena) so it shares the normal response lifetime.
    pub fn intercept(caller_alloc: std.mem.Allocator, opts: http_client.RequestOptions) std.mem.Allocator.Error!Outcome {
        if (!enabled) return .passthrough;
        lockMutex(&g_http.mutex);
        defer g_http.mutex.unlock();
        if (!g_http.capturing) return .passthrough;

        // Record into the capture arena.
        const ca = g_http.alloc();
        const rec = HttpRequest{
            .method = opts.method,
            .url = ca.dupe(u8, opts.url) catch opts.url,
            .headers = dupeHeaders(ca, opts.headers) catch &.{},
            .body = if (opts.body) |b| (ca.dupe(u8, b) catch null) else null,
        };
        g_http.requests.append(ca, rec) catch {};

        // Match a mock (newest-first so later registrations win on overlap).
        var idx = g_http.mocks.items.len;
        while (idx > 0) {
            idx -= 1;
            const m = g_http.mocks.items[idx];
            if (std.mem.indexOf(u8, opts.url, m.url_substring) != null) {
                return .{ .response = .{
                    .status = m.resp.status,
                    .headers = try dupeHeaders(caller_alloc, m.resp.headers),
                    .body = try caller_alloc.dupe(u8, m.resp.body),
                } };
            }
        }
        return if (g_http.block_unmocked) .blocked else .passthrough;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mail: capture records to/subject/body and suppress skips delivery" {
    if (!enabled) return error.SkipZigTest;
    mail.reset();
    defer mail.reset();

    mail.enable(true);
    try std.testing.expect(mail.suppressed());

    // Drive the real Mailer.send seam through the default LogMailer.
    const mailer_mod = @import("mail/mailer.zig");
    var lm = mailer_mod.LogMailer.init();
    const m = lm.mailer();
    try m.send(std.testing.io, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Verify your email",
        .text_body = "token: abc123",
    });

    try std.testing.expectEqual(@as(usize, 1), mail.count());
    const e = mail.get(0).?;
    try std.testing.expectEqualStrings("user@example.com", e.to);
    try std.testing.expectEqualStrings("Verify your email", e.subject);
    try std.testing.expectEqualStrings("token: abc123", e.body);
    try std.testing.expect(mail.find("Verify") != null);
    try std.testing.expect(mail.find("nope") == null);
}

test "mail: capture records the backend's from address" {
    if (!enabled) return error.SkipZigTest;
    mail.reset();
    defer mail.reset();

    mail.enable(true);
    const mailer_mod = @import("mail/mailer.zig");
    // SmtpMailer carries a configured `from`; capture must surface it.
    var sm = mailer_mod.SmtpMailer.init("smtp.example.com", 587, "u", "p", "noreply@app.io");
    const m = sm.mailer();
    try m.send(std.testing.io, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Hi",
        .text_body = "body",
    });
    try std.testing.expectEqual(@as(usize, 1), mail.count());
    try std.testing.expectEqualStrings("noreply@app.io", mail.get(0).?.from);
}

test "mail: not capturing is a no-op" {
    if (!enabled) return error.SkipZigTest;
    mail.reset();
    defer mail.reset();
    // capture not enabled
    const mailer_mod = @import("mail/mailer.zig");
    var lm = mailer_mod.LogMailer.init();
    try lm.mailer().send(std.testing.io, std.testing.allocator, .{
        .to = "u@x.io",
        .subject = "s",
        .text_body = "b",
    });
    try std.testing.expectEqual(@as(usize, 0), mail.count());
}

test "http: mock returns a canned response with no network and records the request" {
    if (!enabled) return error.SkipZigTest;
    http.reset();
    defer http.reset();

    http.enable(true);
    http.mock("example.com", .{
        .status = 201,
        .headers = &.{.{ .name = "X-Mock", .value = "yes" }},
        .body = "{\"ok\":true}",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const res = try client.post("https://api.example.com/things", .{ .body = "payload" });
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.body);
    var found = false;
    for (res.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Mock")) found = true;
    }
    try std.testing.expect(found);

    // The request was recorded.
    try std.testing.expectEqual(@as(usize, 1), http.requestCount());
    const rq = http.requestAt(0).?;
    try std.testing.expectEqual(http_client.Method.POST, rq.method);
    try std.testing.expectEqualStrings("https://api.example.com/things", rq.url);
    try std.testing.expectEqualStrings("payload", rq.body.?);
}

test "http: unmocked URL is blocked (no network) when block_unmocked is set" {
    if (!enabled) return error.SkipZigTest;
    http.reset();
    defer http.reset();

    http.enable(true); // block unmocked
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    try std.testing.expectError(error.TransportFailed, client.get("https://nowhere.invalid/x"));
    // Still recorded for assertion.
    try std.testing.expectEqual(@as(usize, 1), http.requestCount());
    try std.testing.expectEqualStrings("https://nowhere.invalid/x", http.requestAt(0).?.url);
}

test "http: not capturing returns passthrough" {
    if (!enabled) return error.SkipZigTest;
    http.reset();
    defer http.reset();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const oc = try http.intercept(arena.allocator(), .{ .url = "https://x.io/" });
    try std.testing.expectEqual(Outcome.passthrough, oc);
}

test "prod gate: capture is comptime-eliminated when dev_clock is off" {
    if (enabled) return error.SkipZigTest; // only meaningful when built with -Ddev-clock=false
    // Even when a test tries to enable capture, the gate refuses: every op is a no-op.
    mail.enable(true);
    mail.record("f", "t", "s", "b");
    try std.testing.expectEqual(@as(usize, 0), mail.count());
    try std.testing.expectEqual(false, mail.suppressed());

    http.enable(true);
    http.mock("x", .{ .status = 500 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const oc = try http.intercept(arena.allocator(), .{ .url = "https://x.io/" });
    try std.testing.expectEqual(Outcome.passthrough, oc);
    try std.testing.expectEqual(@as(usize, 0), http.requestCount());
}
