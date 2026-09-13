//! Allocation-free, reject-not-queue admission for synchronous HTTP work.
const std = @import("std");
const coordinated = @import("build_options").coordinated_admission;

pub const Config = struct { max_requests: u32, max_work: ?u32 = null };

pub fn resolve(comptime cfg: anytype) ?Config {
    if (!@hasField(@TypeOf(cfg), "admission")) return null;
    if (@typeInfo(@TypeOf(cfg.admission)) != .@"struct")
        @compileError(".admission must be a struct with .max_requests (positive u32)");
    for (std.meta.fields(@TypeOf(cfg.admission))) |field| {
        if (!std.mem.eql(u8, field.name, "max_requests") and !std.mem.eql(u8, field.name, "max_work"))
            @compileError("unknown .admission field: " ++ field.name);
    }
    if (!@hasField(@TypeOf(cfg.admission), "max_requests"))
        @compileError(".admission requires .max_requests (positive u32)");
    const value: u32 = cfg.admission.max_requests;
    if (value == 0) @compileError(".admission.max_requests must be positive; omit .admission to disable");
    const work: ?u32 = if (@hasField(@TypeOf(cfg.admission), "max_work")) cfg.admission.max_work else null;
    if (work != null and !coordinated) @compileError(".admission.max_work requires -Dcoordinated-admission=true");
    if (work != null and work.? == 0) @compileError(".admission.max_work must be positive; omit it to disable shared admission");
    return .{ .max_requests = value, .max_work = work };
}

pub const Snapshot = struct {
    limit: u32,
    active: u32,
    high_water: u32,
    rejected: u64,
    work_limit: ?u32 = null,
    jobs: u32 = 0,
    work_high_water: u32 = 0,
    jobs_rejected: u64 = 0,
};

/// Caller-owned state; no allocation, teardown or background thread. All fields
/// are protected together so snapshots are coherent. The short lock never covers
/// application work. Counters saturate rather than wrapping after prolonged load.
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    value: Snapshot,

    pub fn init(io: std.Io, config: Config) State {
        std.debug.assert(config.max_requests > 0);
        std.debug.assert(config.max_work == null or config.max_work.? > 0);
        return .{ .io = io, .value = .{ .limit = config.max_requests, .active = 0, .high_water = 0, .rejected = 0, .work_limit = config.max_work } };
    }

    fn lock(self: *State) void {
        // Park under contention, including on single-vCPU deployments. Permit
        // release must not be canceled after a successful acquisition.
        self.mutex.lockUncancelable(self.io);
    }

    pub fn acquire(self: *State) bool {
        self.lock();
        defer self.mutex.unlock(self.io);
        if (self.value.active == self.value.limit or self.workFull()) {
            self.value.rejected +|= 1;
            return false;
        }
        self.value.active += 1;
        self.value.high_water = @max(self.value.high_water, self.value.active);
        self.recordWorkHighWater();
        return true;
    }

    fn workFull(self: *State) bool {
        if (comptime !coordinated) return false;
        // Under this lock, both acquisition paths reject at the shared u32
        // ceiling before incrementing. Thus active + jobs <= work_limit;
        // these are not independently growing counters when sharing is on.
        return if (self.value.work_limit) |limit| self.value.active + self.value.jobs >= limit else false;
    }

    fn recordWorkHighWater(self: *State) void {
        if (comptime !coordinated) return;
        if (self.value.work_limit != null)
            self.value.work_high_water = @max(self.value.work_high_water, self.value.active + self.value.jobs);
    }

    /// Reserve before copying a queued payload; keep the reservation through
    /// retries and cleanup. Never wait: a caller may already own an HTTP permit.
    pub fn acquireJob(self: *State) bool {
        // Immutable after init: HTTP-only admission adds no lock to memory work.
        if (self.value.work_limit == null) return true;
        self.lock();
        defer self.mutex.unlock(self.io);
        if (self.workFull()) {
            self.value.jobs_rejected +|= 1;
            return false;
        }
        self.value.jobs += 1;
        self.recordWorkHighWater();
        return true;
    }

    pub fn releaseJob(self: *State) void {
        if (self.value.work_limit == null) return;
        self.lock();
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.value.jobs > 0);
        self.value.jobs -= 1;
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

test "shared admission counts requests and jobs without overcommitting or waiting" {
    if (!coordinated) return error.SkipZigTest;
    var state = State.init(std.testing.io, .{ .max_requests = 2, .max_work = 3 });
    try std.testing.expect(state.acquire());
    try std.testing.expect(state.acquireJob());
    try std.testing.expect(state.acquireJob());
    try std.testing.expect(!state.acquire());
    try std.testing.expect(!state.acquireJob());
    state.releaseJob();
    try std.testing.expect(state.acquire());
    try std.testing.expect(!state.acquire());
    const value = state.snapshot();
    try std.testing.expectEqual(@as(u32, 2), value.active);
    try std.testing.expectEqual(@as(u32, 1), value.jobs);
    try std.testing.expectEqual(@as(u32, 3), value.work_high_water);
    try std.testing.expectEqual(@as(u64, 2), value.rejected);
    try std.testing.expectEqual(@as(u64, 1), value.jobs_rejected);
    state.release();
    state.release();
    state.releaseJob();
    try std.testing.expectEqual(@as(u32, 0), state.snapshot().jobs);
    try std.testing.expectEqual(@as(u32, 0), state.snapshot().active);
}

test "HTTP-only admission does not count or limit jobs" {
    var state = State.init(std.testing.io, .{ .max_requests = 1 });
    try std.testing.expect(state.acquire());
    try std.testing.expect(state.acquireJob());
    state.releaseJob();
    try std.testing.expectEqual(@as(u32, 0), state.snapshot().jobs);
    state.release();
}

test "shared admission preserves its invariant at the u32 ceiling" {
    if (!coordinated) return error.SkipZigTest;
    const limit = std.math.maxInt(u32);
    var state = State.init(std.testing.io, .{ .max_requests = limit, .max_work = limit });
    // Seed a valid near-ceiling state instead of performing 2^32 acquisitions.
    state.value.active = limit - 1;
    state.value.high_water = limit - 1;
    state.value.work_high_water = limit - 1;
    try std.testing.expect(state.acquireJob());
    try std.testing.expectEqual(limit, state.snapshot().work_high_water);
    try std.testing.expect(!state.acquire());
    try std.testing.expect(!state.acquireJob());
    state.releaseJob();
    try std.testing.expect(state.acquire());
    try std.testing.expectEqual(limit, state.snapshot().active);
    try std.testing.expect(!state.acquireJob());
    try std.testing.expect(!state.acquire());
    state.release();
    try std.testing.expect(state.acquireJob());
    try std.testing.expectEqual(limit, state.snapshot().work_high_water);
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

test "concurrent HTTP and job admission share one atomic ceiling" {
    if (!coordinated) return error.SkipZigTest;
    const Harness = struct {
        state: State = State.init(std.testing.io, .{ .max_requests = 3, .max_work = 3 }),
        attempted: std.atomic.Value(u32) = .init(0),
        finish: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), job: bool) void {
            const admitted = if (job) self.state.acquireJob() else self.state.acquire();
            _ = self.attempted.fetchAdd(1, .release);
            if (!admitted) return;
            defer if (job) self.state.releaseJob() else self.state.release();
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
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Harness.run, .{ &harness, i % 2 == 0 });
        started += 1;
    }
    while (harness.attempted.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    const value = harness.state.snapshot();
    try std.testing.expectEqual(@as(u32, 3), value.active + value.jobs);
    try std.testing.expectEqual(@as(u32, 3), value.work_high_water);
    try std.testing.expectEqual(@as(u64, 13), value.rejected + value.jobs_rejected);
}
