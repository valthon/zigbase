//! Allocation-free, reject-not-queue admission for synchronous HTTP work.
const std = @import("std");

pub const Config = struct { max_requests: u32 };

pub fn resolve(comptime cfg: anytype) ?Config {
    if (!@hasField(@TypeOf(cfg), "admission")) return null;
    if (@typeInfo(@TypeOf(cfg.admission)) != .@"struct")
        @compileError(".admission must be a struct with .max_requests (positive u32)");
    for (std.meta.fields(@TypeOf(cfg.admission))) |field| {
        if (!std.mem.eql(u8, field.name, "max_requests"))
            @compileError("unknown .admission field: " ++ field.name);
    }
    if (!@hasField(@TypeOf(cfg.admission), "max_requests"))
        @compileError(".admission requires .max_requests (positive u32)");
    const value: u32 = cfg.admission.max_requests;
    if (value == 0) @compileError(".admission.max_requests must be positive; omit .admission to disable");
    return .{ .max_requests = value };
}

pub const Snapshot = struct { limit: u32, active: u32, high_water: u32, rejected: u64 };

/// Caller-owned state; no allocation, teardown or background thread. All fields
/// are protected together so snapshots are coherent. The short lock never covers
/// application work. Counters saturate rather than wrapping after prolonged load.
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    value: Snapshot,

    pub fn init(io: std.Io, config: Config) State {
        std.debug.assert(config.max_requests > 0);
        return .{ .io = io, .value = .{ .limit = config.max_requests, .active = 0, .high_water = 0, .rejected = 0 } };
    }

    fn lock(self: *State) void {
        // Park under contention, including on single-vCPU deployments. Permit
        // release must not be canceled after a successful acquisition.
        self.mutex.lockUncancelable(self.io);
    }

    pub fn acquire(self: *State) bool {
        self.lock();
        defer self.mutex.unlock(self.io);
        if (self.value.active == self.value.limit) {
            self.value.rejected +|= 1;
            return false;
        }
        self.value.active += 1;
        self.value.high_water = @max(self.value.high_water, self.value.active);
        return true;
    }

    /// Exactly once per successful acquire, after synchronous response handling.
    pub fn release(self: *State) void {
        self.lock();
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.value.active > 0);
        self.value.active -= 1;
    }

    pub fn snapshot(self: *State) Snapshot {
        self.lock();
        defer self.mutex.unlock(self.io);
        return self.value;
    }
};

test "admission rejects without queuing, recovers, and saturates diagnostics" {
    var state = State.init(std.testing.io, .{ .max_requests = 1 });
    try std.testing.expect(state.acquire());
    try std.testing.expect(!state.acquire());
    state.release();
    try std.testing.expectEqual(@as(u64, 1), state.snapshot().rejected);
    try std.testing.expect(state.acquire());
    state.value.rejected = std.math.maxInt(u64);
    try std.testing.expect(!state.acquire());
    try std.testing.expectEqual(std.math.maxInt(u64), state.snapshot().rejected);
    try std.testing.expectEqual(@as(u32, 1), state.snapshot().high_water);
    state.release();
    try std.testing.expectEqual(@as(u32, 0), state.snapshot().active);
}

test "concurrent admission never exceeds its limit" {
    const Harness = struct {
        state: State = State.init(std.testing.io, .{ .max_requests = 3 }),
        attempted: std.atomic.Value(u32) = .init(0),
        finish: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            const admitted = self.state.acquire();
            _ = self.attempted.fetchAdd(1, .release);
            if (!admitted) return;
            defer self.state.release();
            while (!self.finish.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    var harness: Harness = .{};
    var threads: [16]std.Thread = undefined;
    var started: usize = 0;
    defer {
        harness.finish.store(true, .release);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Harness.run, .{&harness});
        started += 1;
    }
    while (harness.attempted.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    const snapshot = harness.state.snapshot();
    try std.testing.expectEqual(@as(u32, 3), snapshot.active);
    try std.testing.expectEqual(@as(u32, 3), snapshot.high_water);
    try std.testing.expectEqual(@as(u64, 13), snapshot.rejected);
}
