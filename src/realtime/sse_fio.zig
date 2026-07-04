//! Typed wrapper over facil.io's SSE API as bound by zap 0.10.6's public `fio` module —
//! the `websockets.zig` shape without the comptime generics (spike §2/§5). Zero zap or
//! facil.io changes: zap already declares every extern we need ($ZAP/src/fio.zig:505-535),
//! verified field-for-field against the C definitions (facil.io http.h:625-654, :685-696,
//! :730-735); `http_upgrade2sse` takes the settings struct BY VALUE (http.c:1342) and
//! facil.io copies it into its internal refcounted sse object, so no settings-outlives-frame
//! concern (unlike the WS handler's `&settings`). The ABI smoke test below pins the layouts.
const std = @import("std");
const zap = @import("zap");
pub const fio = zap.fio;

/// A facil.io SSE stream handle (the pointer the callbacks receive — facil.io's internal,
/// refcounted copy of the upgrade settings). Retain across threads with dup/free.
pub const Handle = [*c]fio.http_sse_s;

pub const LifecycleFn = *const fn (sse: Handle) callconv(.c) void;
pub const OnMessageFn = *const fn (sse: Handle, channel: fio.fio_str_info_s, message: fio.fio_str_info_s, udata: ?*anyopaque) callconv(.c) void;

fn str(s: []const u8) fio.fio_str_info_s {
    return .{ .capa = 0, .len = s.len, .data = @constCast(s.ptr) };
}
const empty_str = fio.fio_str_info_s{ .capa = 0, .len = 0, .data = null };

/// A []const u8 view of a callback-scoped fio string (valid only for the callback's duration).
pub fn sliceOf(s: fio.fio_str_info_s) []const u8 {
    if (s.len == 0) return "";
    return s.data[0..s.len];
}

/// Upgrade a live request to an SSE stream (http1_upgrade2sse sends the `200 text/event-stream`
/// headers itself and swaps the socket protocol — the request object is dead afterwards, spike
/// §4.5). Returns false on failure — the caller does NOT clean up or finish the request itself:
/// facil.io has already invoked `on_close` (and produced/closed the response) before returning,
/// so the caller's teardown already ran via that callback. See `sse.zig`'s `openStream` for the
/// full explanation (this was a double-free/double-release bug before the fix).
pub fn upgrade(h: [*c]fio.http_s, on_open: LifecycleFn, on_close: LifecycleFn, udata: ?*anyopaque) bool {
    return fio.http_upgrade2sse(h, .{
        .on_open = on_open,
        .on_ready = null,
        .on_shutdown = null,
        .on_close = on_close,
        .udata = udata,
    }) == 0;
}

/// Per-connection protocol-timeout override (upstream typo: `http_sse_set_timout`). facil.io's
/// SSE protocol writes the comment `: ping\n\n` on every timeout tick (http1_sse_ping,
/// http1.c:449-453) — the free heartbeat.
pub fn setTimeout(sse: Handle, seconds: u8) void {
    fio.http_sse_set_timout(sse, seconds);
}

/// Subscribe this stream to a pub/sub channel (the same fio_subscribe engine WS rides,
/// http.c:1294-1319). Returns a subscription id (0 on failure) — identical bookkeeping to
/// WS.subscribe. Thread-safe (internal sse->lock spinlock, http.c:1313).
pub fn subscribe(sse: Handle, channel: []const u8, on_message: OnMessageFn, udata: ?*anyopaque) usize {
    return fio.http_sse_subscribe(sse, .{
        .channel = str(channel),
        .on_message = on_message,
        .on_unsubscribe = null,
        .udata = udata,
        .match = null,
    });
}

pub fn unsubscribe(sse: Handle, sub_id: usize) void {
    fio.http_sse_unsubscribe(sse, sub_id);
}

/// Write one `data: <bytes>\n\n` event (http_sse_write formats + `fiobj_send_free` — a
/// thread-safe, non-blocking enqueue onto fio's outgoing buffer, http.c:1365-1389). No `id:`,
/// no `event:`, no `retry:` in v1 (spec §1.1). Returns false when the stream is gone.
pub fn writeData(sse: Handle, data: []const u8) bool {
    return fio.http_sse_write(sse, .{ .id = empty_str, .event = empty_str, .data = str(data), .retry = 0 }) == 0;
}

/// Refcount the handle for out-of-band retention (registry/uplink) — http.c:1416+.
pub fn dup(sse: Handle) Handle {
    return fio.http_sse_dup(sse);
}
pub fn free(sse: Handle) void {
    fio.http_sse_free(sse);
}
/// Schedule the stream closed (on_close will fire).
pub fn close(sse: Handle) void {
    _ = fio.http_sse_close(sse);
}

/// The underlying socket uuid for this SSE stream (http.h:749) — the key `fio_pending` wants for
/// the slow-consumer outbound high-water-mark (issue #203).
pub fn uuid(sse: Handle) isize {
    return fio.http_sse2uuid(sse);
}

// ---- ABI smoke test ---------------------------------------------------------
// The spike verified zap's extern structs field-for-field against facil.io's headers; this
// test pins those layouts so a zap upgrade that changes them fails HERE, not at runtime.
test "ABI: zap fio SSE extern struct layouts match the spike-verified facil.io shapes" {
    // fio_str_info_s = { capa: usize, len: usize, data: [*c]u8 } (fio.zig:120-124).
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(fio.fio_str_info_s));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(fio.fio_str_info_s, "capa"));
    try std.testing.expectEqual(@sizeOf(usize), @offsetOf(fio.fio_str_info_s, "len"));
    try std.testing.expectEqual(2 * @sizeOf(usize), @offsetOf(fio.fio_str_info_s, "data"));

    // struct_http_sse_s = 4 callbacks + udata (http.h:625-654 / fio.zig:506-512).
    try std.testing.expectEqual(5 * @sizeOf(usize), @sizeOf(fio.struct_http_sse_s));
    inline for (.{ "on_open", "on_ready", "on_shutdown", "on_close", "udata" }, 0..) |name, i| {
        try std.testing.expectEqual(i * @sizeOf(usize), @offsetOf(fio.struct_http_sse_s, name));
    }

    // subscribe args = channel + on_message + on_unsubscribe + udata + match (http.h:685-696).
    try std.testing.expectEqual(@sizeOf(fio.fio_str_info_s) + 4 * @sizeOf(usize), @sizeOf(fio.struct_http_sse_subscribe_args));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(fio.struct_http_sse_subscribe_args, "channel"));

    // write args = 3 strings + retry: isize (http.h:730-735).
    try std.testing.expectEqual(3 * @sizeOf(fio.fio_str_info_s) + @sizeOf(isize), @sizeOf(fio.struct_http_sse_write_args));
    try std.testing.expectEqual(2 * @sizeOf(fio.fio_str_info_s), @offsetOf(fio.struct_http_sse_write_args, "data"));

    // The extern fns exist with the bound signatures (compile-time reference is the assertion).
    const T1: *const @TypeOf(fio.http_upgrade2sse) = &fio.http_upgrade2sse;
    const T2: *const @TypeOf(fio.http_sse_write) = &fio.http_sse_write;
    const T3: *const @TypeOf(fio.http_sse_dup) = &fio.http_sse_dup;
    _ = .{ T1, T2, T3 };
}

test "str/sliceOf round-trip a Zig slice through fio_str_info_s" {
    const s = "data-bytes";
    const info = str(s);
    try std.testing.expectEqual(s.len, info.len);
    try std.testing.expectEqualStrings(s, sliceOf(info));
    try std.testing.expectEqualStrings("", sliceOf(empty_str));
}
