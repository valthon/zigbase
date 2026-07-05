//! In-memory capture SMS sender (#224), the SMS analog of `mail/capture.zig`'s `CaptureMailer`.
//! `CaptureSms` is an `SmsSender` backend that records every outbound message into an in-memory
//! list instead of sending it. Consumer tests wire it via `App(.{ .sms_provider = ... })` (or call
//! its `sender()` directly) and then ASSERT on the captured messages — recipient, body, from — with
//! no Twilio account and no network. Pure of I/O and fully unit-testable.

const std = @import("std");
const sender_mod = @import("sender.zig");

const Sms = sender_mod.Sms;

/// Spin-acquire `m` (the `std.atomic.Mutex` idiom used elsewhere, e.g. mail/capture.zig).
fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// One captured outbound message (owned copies of the fields, freed in `deinit`).
pub const Captured = struct {
    to: []u8,
    body: []u8,
    from: ?[]u8,
};

/// An `SmsSender` backend that records messages in memory. NOT thread-safe across concurrent
/// worker sends without the internal mutex (which `record` takes); intended for single-process tests.
pub const CaptureSms = struct {
    alloc: std.mem.Allocator,
    from: []const u8 = "+15550000000",
    mutex: std.atomic.Mutex = .unlocked,
    messages: std.ArrayListUnmanaged(Captured) = .empty,

    pub fn init(alloc: std.mem.Allocator) CaptureSms {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *CaptureSms) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.to);
            self.alloc.free(m.body);
            if (m.from) |f| self.alloc.free(f);
        }
        self.messages.deinit(self.alloc);
    }

    pub fn sender(self: *CaptureSms) sender_mod.SmsSender {
        return .{ .ptr = self, .vtable = &vtable, .from = self.from };
    }

    const vtable = sender_mod.SmsSender.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, sms: Sms) anyerror!void {
        _ = io;
        _ = alloc;
        const self: *CaptureSms = @ptrCast(@alignCast(ptr));
        // Record the EFFECTIVE sender a real provider would use — the per-message `from` override
        // if set, else this backend's configured default — so a test can assert `from` on every
        // captured message (not just override-carrying ones), mirroring TwilioSender/LogSmsSender.
        var effective = sms;
        if (effective.from == null) effective.from = self.from;
        try self.record(effective);
    }

    /// Record a message under the mutex (owned copies live on `self.alloc`). Each dupe has its own
    /// `errdefer` so a later allocation failing frees the earlier copies (no partial-alloc leak).
    pub fn record(self: *CaptureSms, sms: Sms) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const to_copy = try self.alloc.dupe(u8, sms.to);
        errdefer self.alloc.free(to_copy);
        const body_copy = try self.alloc.dupe(u8, sms.body);
        errdefer self.alloc.free(body_copy);
        const from_copy: ?[]u8 = if (sms.from) |f| try self.alloc.dupe(u8, f) else null;
        errdefer if (from_copy) |f| self.alloc.free(f);
        try self.messages.append(self.alloc, .{ .to = to_copy, .body = body_copy, .from = from_copy });
    }

    pub fn count(self: *CaptureSms) usize {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    /// The most recently captured message, or null. Borrowed (valid until `deinit`/`clear`).
    pub fn last(self: *CaptureSms) ?Captured {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
    }

    /// Every captured message, oldest first. BORROWED — valid until the next `record`/`clear`/`deinit`.
    pub fn all(self: *CaptureSms) []const Captured {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.messages.items;
    }

    /// Number of captured messages addressed to exactly `to`.
    pub fn countTo(self: *CaptureSms, to: []const u8) usize {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.messages.items) |m| {
            if (std.mem.eql(u8, m.to, to)) n += 1;
        }
        return n;
    }

    /// Drop all captured messages (freeing their copies).
    pub fn clear(self: *CaptureSms) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (self.messages.items) |m| {
            self.alloc.free(m.to);
            self.alloc.free(m.body);
            if (m.from) |f| self.alloc.free(f);
        }
        self.messages.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "CaptureSms records sends without a network and is assertable" {
    var cap = CaptureSms.init(testing.allocator);
    defer cap.deinit();
    const s = cap.sender();
    try s.send(testing.io, testing.allocator, .{
        .to = "+15551234567",
        .body = "Reminder: tomorrow 10:00",
        .from = "+15550000000",
    });
    try testing.expectEqual(@as(usize, 1), cap.count());
    const last = cap.last().?;
    try testing.expectEqualStrings("+15551234567", last.to);
    try testing.expectEqualStrings("Reminder: tomorrow 10:00", last.body);
    try testing.expectEqualStrings("+15550000000", last.from.?);

    try s.send(testing.io, testing.allocator, .{ .to = "+15559999999", .body = "hi" });
    try s.send(testing.io, testing.allocator, .{ .to = "+15551234567", .body = "again" });
    try testing.expectEqual(@as(usize, 3), cap.all().len);
    try testing.expectEqual(@as(usize, 2), cap.countTo("+15551234567"));
    try testing.expectEqual(@as(usize, 1), cap.countTo("+15559999999"));
    // The second message carried no `from` override, so the captured `from` is the backend's
    // configured default sender (the effective sender a real provider would use).
    try testing.expectEqualStrings("+15550000000", cap.all()[1].from.?);

    cap.clear();
    try testing.expectEqual(@as(usize, 0), cap.count());
    try testing.expect(cap.last() == null);
}
