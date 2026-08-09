const std = @import("std");
const clock = @import("clock.zig");
const datetime = @import("datetime.zig");

/// Log line encoding. `text` is human-first; `json` is one JSON object per line —
/// i.e. an NDJSON stream on stderr. Per the SP-1 output conventions, a consumer of
/// that stream MUST skip any line that does not parse as JSON (a panic message or a
/// linked C library's own output can land on the same fd) and must never fail the
/// run because of one.
pub const Format = enum { text, json };

/// Process-wide logging state. Single-process server, resolved once at startup
/// before any worker thread exists (see `framework.runCliImpl`), then read-only —
/// so plain globals are correct here and an atomic would only add noise.
pub var format: Format = .text;
pub var min_level: std.log.Level = .info;
pub var request_logging: bool = true;

/// Test seam: when non-null, every emitted line goes here instead of stderr. Mirrors
/// `report/log.zig`'s `log_sink` — Zig's test runner counts a real `std.log.err` as a
/// test failure, so a test exercising an error path needs somewhere else to send it.
pub var sink: ?*const fn (line: []const u8) void = null;

/// A single HTTP request record. Emitted by `request()`, NOT through `std.log`:
/// `std.Options.logFn` only ever receives an already-formatted string, so routing
/// these through it would collapse every field into one opaque `msg`.
pub const RequestRecord = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    duration_ms: u64,
};

pub fn parseFormat(v: []const u8) ?Format {
    if (std.mem.eql(u8, v, "text")) return .text;
    if (std.mem.eql(u8, v, "json")) return .json;
    return null;
}

pub fn parseLevel(v: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, v, "debug")) return .debug;
    if (std.mem.eql(u8, v, "info")) return .info;
    if (std.mem.eql(u8, v, "warn")) return .warn;
    // `error` is the spelling operators expect; `err` is the std.log.Level tag name.
    if (std.mem.eql(u8, v, "error") or std.mem.eql(u8, v, "err")) return .err;
    return null;
}

/// First statement of `runCliImpl`: set the format/level so that everything logged
/// during startup — INCLUDING the fail-fast error for a malformed env var — comes out
/// in the operator's chosen encoding. Deliberately silent on an invalid value:
/// `Config.loadDiag` validates moments later and produces the actionable message, so
/// there is exactly one validation path and no chance of the two disagreeing.
pub fn preinstallFromEnv(environ: *const std.process.Environ.Map) void {
    if (environ.get("ZIGBASE_LOG_FORMAT")) |v| {
        if (parseFormat(v)) |f| format = f;
    }
    if (environ.get("ZIGBASE_LOG_LEVEL")) |v| {
        if (parseLevel(v)) |l| min_level = l;
    }
}

/// Install the fully resolved configuration (env, then `serve` flags). Called once
/// from `serveImpl` before any worker thread exists.
pub fn apply(cfg_format: Format, cfg_level: std.log.Level, cfg_requests: bool) void {
    format = cfg_format;
    min_level = cfg_level;
    request_logging = cfg_requests;
}

/// `YYYY-MM-DDTHH:MM:SSZ` for the current instant (frozen-clock aware).
fn timestamp() [20]u8 {
    var out: [20]u8 = undefined;
    // `datetime.formatUtc` returns SQLite's own `YYYY-MM-DD HH:MM:SS` (space-separated —
    // it round-trips with `datetime.parse`/SQLite's bare-datetime reading, not ISO-8601).
    // A log line wants the `T` separator, so swap the one differing byte (index 10) after
    // copying; everything else in the 19-byte layout lines up exactly.
    out[0..19].* = datetime.formatUtc(clock.nowUnixNoIo());
    out[10] = 'T';
    out[19] = 'Z';
    return out;
}

/// Render one log line (including its trailing newline) into `buf`, returning the
/// written slice. Pure: allocates nothing, reads no mutable global except the clock.
///
/// TRUNCATION CONTRACT: if the line does not fit, the result is shortened but stays
/// WELL-FORMED for the mode — a truncated `json` line is still one parseable object,
/// because the message is clamped first and the envelope is composed around it. A
/// half-written line that broke JSON parsing would be worse than a lossy one.
pub fn formatMessage(buf: []u8, mode: Format, comptime level: std.log.Level, scope: []const u8, msg: []const u8) []const u8 {
    const ts = timestamp();
    // Worst-case JSON escaping expands one byte to six (\uXXXX), so clamp the message
    // to a sixth of the remaining room before composing.
    const overhead = 96 + ts.len + scope.len;
    const room = if (buf.len > overhead) buf.len - overhead else 0;
    const max_msg = switch (mode) {
        .text => room,
        .json => room / 6,
    };
    const m = msg[0..@min(msg.len, max_msg)];

    // Text uses the human-readable spelling (`level.asText()`: "error"/"warning"/…);
    // JSON uses the enum's own short tag name ("err"/"warn"/…) — the machine-readable
    // spelling operators grep for and `parseLevel` round-trips. `asText()` would render
    // `.warn` as "warning" in JSON, which the wire format never emits.
    const written = switch (mode) {
        .text => if (std.mem.eql(u8, scope, "default"))
            std.fmt.bufPrint(buf, "{s} {s}: {s}\n", .{ &ts, level.asText(), m })
        else
            std.fmt.bufPrint(buf, "{s} {s}({s}): {s}\n", .{ &ts, level.asText(), scope, m }),
        .json => std.fmt.bufPrint(
            buf,
            "{{\"ts\":\"{s}\",\"level\":\"{s}\",\"scope\":{f},\"msg\":{f}}}\n",
            .{ &ts, @tagName(level), std.json.fmt(scope, .{}), std.json.fmt(m, .{}) },
        ),
    };
    // NoSpaceLeft can still occur if `scope` itself is pathological; drop to a fixed,
    // valid line rather than emitting a fragment.
    return written catch switch (mode) {
        .text => "log line too long\n",
        .json => "{\"ts\":\"\",\"level\":\"err\",\"scope\":\"default\",\"msg\":\"log line too long\"}\n",
    };
}

/// Render one request record. Same purity and truncation contract as `formatMessage`.
/// `path` is attacker-controlled, so the json branch escapes it through `std.json.fmt`
/// — a raw interpolation would let a crafted URL forge a second log record.
pub fn formatRequest(buf: []u8, mode: Format, rec: RequestRecord) []const u8 {
    const ts = timestamp();
    const written = switch (mode) {
        .text => std.fmt.bufPrint(buf, "{s} info(http): {s} {s} {d} {d}ms\n", .{
            &ts, rec.method, rec.path, rec.status, rec.duration_ms,
        }),
        .json => std.fmt.bufPrint(
            buf,
            "{{\"ts\":\"{s}\",\"level\":\"info\",\"scope\":\"http\",\"msg\":\"request\"," ++
                "\"method\":{f},\"path\":{f},\"status\":{d},\"duration_ms\":{d}}}\n",
            .{ &ts, std.json.fmt(rec.method, .{}), std.json.fmt(rec.path, .{}), rec.status, rec.duration_ms },
        ),
    };
    return written catch switch (mode) {
        .text => "log line too long\n",
        .json => "{\"ts\":\"\",\"level\":\"err\",\"scope\":\"http\",\"msg\":\"log line too long\"}\n",
    };
}

/// Write one already-formatted line to the sink (tests) or stderr (production).
fn write(line: []const u8) void {
    if (sink) |s| {
        s(line);
        return;
    }
    var lock_buf: [64]u8 = undefined;
    const locked = std.debug.lockStderr(&lock_buf);
    defer std.debug.unlockStderr();
    locked.file_writer.interface.writeAll(line) catch {};
    locked.file_writer.interface.flush() catch {};
}

/// Format into `buf`, truncating rather than failing, and return ONLY the bytes that
/// were actually written.
///
/// `std.fmt.bufPrint` throws away that length on `NoSpaceLeft`, so the idiomatic
/// `bufPrint(...) catch buf` fallback hands back the buffer's UNWRITTEN tail as if it
/// were message text — 0xAA filler on a safety build, whatever was on the stack under
/// ReleaseFast. As of Zig 0.16 `Writer.fixed`'s drain always saturates the buffer
/// before erroring, so that tail is empty in practice and nothing leaks today; but
/// that is an unpromised implementation detail of one drain function, and `buffered()`
/// is the length the writer actually tracked. Depending on the tracked length instead
/// of on a coincidence costs one line.
fn formatInto(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return w.buffered();
}

/// The `std.Options.logFn` hook: EVERY `std.log` call in the framework, in the
/// vendored dependencies' Zig code, and in consumer hooks/routes lands here.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    var msg_buf: [1024]u8 = undefined;
    const msg = formatInto(&msg_buf, fmt, args);
    var line_buf: [8192]u8 = undefined;
    write(formatMessage(&line_buf, format, level, @tagName(scope), msg));
}

/// Emit one structured request record. No-op when request logging is off or the
/// level floor is above `info`.
pub fn request(rec: RequestRecord) void {
    if (!request_logging) return;
    if (@intFromEnum(std.log.Level.info) > @intFromEnum(min_level)) return;
    var line_buf: [8192]u8 = undefined;
    write(formatRequest(&line_buf, format, rec));
}

/// Drop this into your binary's root: `pub const std_options = zigbase.std_options;`.
/// `log_level` is `.debug` so nothing is filtered at COMPILE time — the runtime floor
/// is `min_level`, which `--log-level` / `ZIGBASE_LOG_LEVEL` set at startup.
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

/// The instant the timestamped assertions below pin, and its rendering.
const frozen_unix: i64 = 1_754_654_400;
const frozen_ts = "2025-08-08T12:00:00Z";

/// Assert `actual` is exactly `prefix ++ <timestamp> ++ rest`.
///
/// The frozen-clock override is compiled in ONLY on a dev build (`clock.enabled`),
/// so under `-Ddev-mode=false` these lines carry the real wall clock and the exact
/// timestamp cannot be asserted. Rather than skip the test there — which would drop
/// the format contract from the prod-mode suite entirely — the timestamp is checked
/// for SHAPE and every other byte is still compared exactly. Dev-mode coverage is
/// unchanged: it is this, plus the exact instant.
fn expectTimestampedLine(actual: []const u8, prefix: []const u8, rest: []const u8) !void {
    try std.testing.expectEqual(prefix.len + frozen_ts.len + rest.len, actual.len);
    try std.testing.expectEqualStrings(prefix, actual[0..prefix.len]);
    const ts = actual[prefix.len..][0..frozen_ts.len];
    if (clock.enabled) {
        try std.testing.expectEqualStrings(frozen_ts, ts);
    } else {
        try expectTimestampShape(ts);
    }
    try std.testing.expectEqualStrings(rest, actual[prefix.len + frozen_ts.len ..]);
}

/// `YYYY-MM-DDTHH:MM:SSZ` — the shape every log timestamp must have regardless of build.
fn expectTimestampShape(ts: []const u8) !void {
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |i| {
        if (!std.ascii.isDigit(ts[i])) {
            std.debug.print("timestamp '{s}' has a non-digit at index {d}\n", .{ ts, i });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectEqualStrings("-", ts[4..5]);
    try std.testing.expectEqualStrings("-", ts[7..8]);
    try std.testing.expectEqualStrings("T", ts[10..11]);
    try std.testing.expectEqualStrings(":", ts[13..14]);
    try std.testing.expectEqualStrings(":", ts[16..17]);
    try std.testing.expectEqualStrings("Z", ts[19..20]);
}

test "logging: text format is timestamped, leveled, and scope-tagged" {
    clock.setForTest(frozen_unix); // no-op on a prod build; see expectTimestampedLine
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;

    // The default scope is omitted; a named scope is parenthesized.
    try expectTimestampedLine(
        formatMessage(&buf, .text, .info, "default", "listening on 127.0.0.1:8090"),
        "",
        " info: listening on 127.0.0.1:8090\n",
    );
    try expectTimestampedLine(
        formatMessage(&buf, .text, .err, "http", "boom"),
        "",
        " error(http): boom\n",
    );
}

test "logging: json format escapes the message and keeps a fixed key order" {
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    try expectTimestampedLine(
        formatMessage(&buf, .json, .warn, "http", "a \"quoted\" thing\nand a newline"),
        "{\"ts\":\"",
        "\",\"level\":\"warn\",\"scope\":\"http\"," ++
            "\"msg\":\"a \\\"quoted\\\" thing\\nand a newline\"}\n",
    );
}

test "logging: a request record carries its fields separately, not crammed into msg" {
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    const rec = RequestRecord{ .method = "GET", .path = "/api/health", .status = 200, .duration_ms = 3 };
    try expectTimestampedLine(
        formatRequest(&buf, .text, rec),
        "",
        " info(http): GET /api/health 200 3ms\n",
    );
    try expectTimestampedLine(
        formatRequest(&buf, .json, rec),
        "{\"ts\":\"",
        "\",\"level\":\"info\",\"scope\":\"http\",\"msg\":\"request\"," ++
            "\"method\":\"GET\",\"path\":\"/api/health\",\"status\":200,\"duration_ms\":3}\n",
    );
}

test "logging: a path with a quote is escaped, never breaking the JSON line" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    const rec = RequestRecord{ .method = "GET", .path = "/api/x\"y", .status = 404, .duration_ms = 0 };
    const line = formatRequest(&buf, .json, rec);
    // Parse it back: the only real proof that an attacker-controlled path can't
    // forge a log record. A substring check would not catch a broken escape.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/api/x\"y", parsed.value.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 404), parsed.value.object.get("status").?.integer);
}

test "logging: a log call larger than the message buffer emits no uninitialized bytes" {
    // Pins the invariant `formatInto` exists to guarantee: an over-long log call emits
    // only formatted bytes, never the message buffer's unwritten tail.
    //
    // HONEST NOTE ON WHAT THIS PROVES: it does NOT go red against the previous
    // `bufPrint(...) catch msg_buf[0..]` spelling, because Zig 0.16's `fixedDrain`
    // copies `@min(bytes.len, dest.len)` and only THEN returns WriteFailed — the
    // buffer is always saturated before NoSpaceLeft, so the old fallback returned
    // 1024 fully-written bytes. Probed four shapes (long string, trailing integer,
    // width-padded integer, float) and none left an unwritten byte. So this is a
    // regression guard on an invariant currently upheld by a coincidence of std's
    // internals, not a reproduction of a live leak.
    const H = struct {
        var last: [16384]u8 = undefined;
        var len: usize = 0;
        fn s(line: []const u8) void {
            const n = @min(line.len, last.len);
            @memcpy(last[0..n], line[0..n]);
            len = n;
        }
    };
    H.len = 0;
    const prev_sink = sink;
    sink = H.s;
    defer sink = prev_sink;
    const prev_level = min_level;
    const prev_format = format;
    defer {
        min_level = prev_level;
        format = prev_format;
    }
    min_level = .debug;
    format = .text;

    var huge: [4096]u8 = undefined;
    @memset(&huge, 'x');
    logFn(.err, .default, "{s}", .{&huge});

    const line = H.last[0..H.len];
    try std.testing.expect(H.len > 0);
    // 0xAA is Zig's `undefined` fill on a safety build, so an unwritten tail is
    // detectable here. Under ReleaseFast the fill is absent and this assertion is
    // weaker — but the fix removes the unwritten region entirely either way.
    if (std.mem.indexOfScalar(u8, line, 0xAA)) |i| {
        std.debug.print("log line carries an uninitialized byte at index {d} of {d}\n", .{ i, line.len });
        return error.TestExpectedEqual;
    }
    // Whatever survived truncation must still be the real message, not garbage.
    try std.testing.expect(std.mem.indexOf(u8, line, "xxxxxxxx") != null);
}

test "logging: an oversized message truncates and still yields ONE valid JSON line" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var huge: [4096]u8 = undefined;
    @memset(&huge, 'x');
    var buf: [512]u8 = undefined; // deliberately too small for the message
    const line = formatMessage(&buf, .json, .err, "default", &huge);
    try std.testing.expect(line.len <= buf.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("msg") != null);
    try std.testing.expectEqual(@as(?std.json.Value, null), parsed.value.object.get("nope"));
}

test "logging: parseFormat and parseLevel accept only the documented spellings" {
    try std.testing.expectEqual(@as(?Format, .json), parseFormat("json"));
    try std.testing.expectEqual(@as(?Format, .text), parseFormat("text"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat("JSON"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat("ndjson"));
    try std.testing.expectEqual(@as(?std.log.Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?std.log.Level, .info), parseLevel("info"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warn"));
    // Both spellings of the highest level are accepted; `std.log.Level` calls it `err`.
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("err"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel("trace"));
}

test "logging: min_level suppresses lower-severity records at the sink" {
    const H = struct {
        var seen: usize = 0;
        var last: [256]u8 = undefined;
        var last_len: usize = 0;
        fn s(line: []const u8) void {
            seen += 1;
            const n = @min(line.len, last.len);
            @memcpy(last[0..n], line[0..n]);
            last_len = n;
        }
    };
    H.seen = 0;
    sink = H.s;
    defer sink = null;
    const prev = min_level;
    defer min_level = prev;

    min_level = .warn;
    logFn(.info, .default, "quiet", .{});
    try std.testing.expectEqual(@as(usize, 0), H.seen);
    logFn(.warn, .default, "loud", .{});
    try std.testing.expectEqual(@as(usize, 1), H.seen);
    try std.testing.expect(std.mem.indexOf(u8, H.last[0..H.last_len], "loud") != null);
}

test "logging: request() honors request_logging and min_level" {
    const H = struct {
        var seen: usize = 0;
        fn s(_: []const u8) void {
            seen += 1;
        }
    };
    H.seen = 0;
    sink = H.s;
    defer sink = null;
    const prev_req = request_logging;
    const prev_lvl = min_level;
    defer {
        request_logging = prev_req;
        min_level = prev_lvl;
    }
    const rec = RequestRecord{ .method = "GET", .path = "/", .status = 200, .duration_ms = 1 };

    min_level = .info;
    request_logging = false;
    request(rec);
    try std.testing.expectEqual(@as(usize, 0), H.seen);

    request_logging = true;
    request(rec);
    try std.testing.expectEqual(@as(usize, 1), H.seen);

    // Request lines are `info`; raising the floor above info silences them too.
    min_level = .warn;
    request(rec);
    try std.testing.expectEqual(@as(usize, 1), H.seen);
}
