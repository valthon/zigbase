//! Comptime lowering of the `.queues` / `.workers` / `.jobs` App config into the
//! runtime `queue.QueueDef` / `WorkerDef` / `JobReg` slices, plus the generated
//! `Queue` / `Job` enums that make `App.enqueue(ctx, .queue, .kind, payload)` a
//! compile-checked call (a typo'd queue or kind is a `@compileError`, never a
//! runtime miss). Every malformed declaration is a loud `@compileError`
//! (loud-comptime convention, mirroring `features.flagMeta`).

const std = @import("std");
const queue = @import("queue.zig");

const QueueDef = queue.QueueDef;
const WorkerDef = queue.WorkerDef;
const JobReg = queue.JobReg;
const RetryPolicy = queue.RetryPolicy;

/// True for a comptime type that represents a string literal/slice.
fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Reflect a `.queues` config literal into `[]const QueueDef`, always synthesizing a
/// `.default` (memory/normal) queue when one is not declared. Each field is a struct
/// `.{ .backend = .memory|.durable, .priority = .high|.normal|.low, .retry = .{…} }`;
/// every key is optional. Loud `@compileError` on an unknown sub-key or a malformed value.
pub fn queueMeta(comptime queues_cfg: anytype) []const QueueDef {
    comptime {
        const T = @TypeOf(queues_cfg);
        if (@typeInfo(T) != .@"struct")
            @compileError(".queues must be a struct literal of queue declarations");
        var list: []const QueueDef = &.{};
        var has_default = false;
        for (std.meta.fields(T)) |f| {
            if (std.mem.eql(u8, f.name, "default")) has_default = true;
            const spec = @field(queues_cfg, f.name);
            const ST = @TypeOf(spec);
            if (@typeInfo(ST) != .@"struct")
                @compileError("queue '" ++ f.name ++ "' must be a struct '.{ .backend = …, .priority = …, .retry = .{…} }'");
            for (std.meta.fields(ST)) |sf| {
                if (!std.mem.eql(u8, sf.name, "backend") and
                    !std.mem.eql(u8, sf.name, "priority") and
                    !std.mem.eql(u8, sf.name, "retry") and
                    !std.mem.eql(u8, sf.name, "visibility_timeout_s") and
                    !std.mem.eql(u8, sf.name, "done_ttl_s") and
                    !std.mem.eql(u8, sf.name, "rate"))
                    @compileError("queue '" ++ f.name ++ "': unknown key '." ++ sf.name ++ "' (recognized keys: .backend, .priority, .retry, .visibility_timeout_s, .done_ttl_s, .rate)");
            }
            var def = QueueDef{ .name = f.name };
            if (@hasField(ST, "backend")) {
                const be: queue.Backend = spec.backend;
                def.backend = be;
            }
            if (@hasField(ST, "priority")) {
                const pr: queue.Priority = spec.priority;
                def.priority = pr;
            }
            if (@hasField(ST, "retry")) def.retry = retryMeta(f.name, spec.retry);
            if (@hasField(ST, "visibility_timeout_s")) {
                if (spec.visibility_timeout_s <= 0)
                    @compileError("queue '" ++ f.name ++ "': .visibility_timeout_s must be >= 1 (set it above the queue's longest job runtime)");
                def.visibility_timeout_s = spec.visibility_timeout_s;
            }
            if (@hasField(ST, "done_ttl_s")) {
                // A non-positive TTL makes gcDoneJobs's `datetime('now','-{d} seconds')`
                // modifier malformed → SQLite yields NULL and GC silently reaps nothing.
                if (spec.done_ttl_s <= 0)
                    @compileError("queue '" ++ f.name ++ "': .done_ttl_s must be >= 1 (seconds to retain done/failed jobs; omit for the 7-day default)");
                def.done_ttl_s = spec.done_ttl_s;
            }
            if (@hasField(ST, "rate")) {
                const rs = spec.rate;
                const RST = @TypeOf(rs);
                if (@typeInfo(RST) != .@"struct" or !@hasField(RST, "per_second"))
                    @compileError("queue '" ++ f.name ++ "': .rate must be '.{ .per_second = N }'");
                if (rs.per_second == 0)
                    @compileError("queue '" ++ f.name ++ "': .rate.per_second must be >= 1");
                def.rate = .{ .per_second = rs.per_second };
            }
            if (def.rate != null and def.backend != .durable)
                @compileError("queue '" ++ f.name ++ "': .rate requires .backend = .durable (memory jobs dispatch inline and cannot be throttled)");
            list = list ++ &[_]QueueDef{def};
        }
        if (!has_default)
            list = &[_]QueueDef{.{ .name = "default" }} ++ list;
        return list;
    }
}

fn retryMeta(comptime qname: []const u8, comptime spec: anytype) RetryPolicy {
    comptime {
        const ST = @TypeOf(spec);
        if (@typeInfo(ST) != .@"struct")
            @compileError("queue '" ++ qname ++ "': .retry must be a struct '.{ .max_attempts = …, .backoff = …, .base_ms = …, .max_ms = …, .jitter = … }'");
        for (std.meta.fields(ST)) |sf| {
            if (!std.mem.eql(u8, sf.name, "max_attempts") and
                !std.mem.eql(u8, sf.name, "backoff") and
                !std.mem.eql(u8, sf.name, "base_ms") and
                !std.mem.eql(u8, sf.name, "max_ms") and
                !std.mem.eql(u8, sf.name, "jitter"))
                @compileError("queue '" ++ qname ++ "': .retry has unknown key '." ++ sf.name ++ "' (recognized: .max_attempts, .backoff, .base_ms, .max_ms, .jitter)");
        }
        var r = RetryPolicy{};
        if (@hasField(ST, "max_attempts")) {
            if (spec.max_attempts == 0)
                @compileError("queue '" ++ qname ++ "': .retry.max_attempts must be >= 1 (a job needs at least one attempt)");
            r.max_attempts = spec.max_attempts;
        }
        if (@hasField(ST, "backoff")) {
            const b: queue.Backoff = spec.backoff;
            r.backoff = b;
        }
        if (@hasField(ST, "base_ms")) r.base_ms = spec.base_ms;
        if (@hasField(ST, "max_ms")) r.max_ms = spec.max_ms;
        if (@hasField(ST, "jitter")) {
            if (@TypeOf(spec.jitter) != bool)
                @compileError("queue '" ++ qname ++ "': .retry.jitter must be a bool");
            r.jitter = spec.jitter;
        }
        return r;
    }
}

/// Reflect a `.workers` config literal into `[]const WorkerDef`, validating every
/// referenced queue name against `queue_defs`. When `.workers` is absent (an empty
/// struct), synthesize ONE implicit worker named `default` bound to ALL declared
/// queues (strict priority). Each declared worker is `.{ .queues = .{ "a", "b" },
/// .concurrency = N }`. Loud `@compileError` on an unknown sub-key, a missing/empty
/// `.queues`, a reference to an undeclared queue, or `concurrency == 0`.
pub fn workerMeta(comptime workers_cfg: anytype, comptime queue_defs: []const QueueDef) []const WorkerDef {
    comptime {
        const T = @TypeOf(workers_cfg);
        if (@typeInfo(T) != .@"struct")
            @compileError(".workers must be a struct literal of worker declarations");
        const fields = std.meta.fields(T);
        if (fields.len == 0) {
            // Implicit single worker over every declared queue, strict priority.
            var all: []const []const u8 = &.{};
            for (queue_defs) |q| all = all ++ &[_][]const u8{q.name};
            return &[_]WorkerDef{.{ .name = "default", .queues = all, .concurrency = 1 }};
        }
        var list: []const WorkerDef = &.{};
        for (fields) |f| {
            const spec = @field(workers_cfg, f.name);
            const ST = @TypeOf(spec);
            if (@typeInfo(ST) != .@"struct")
                @compileError("worker '" ++ f.name ++ "' must be a struct '.{ .queues = .{ \"q1\", … }, .concurrency = N }'");
            for (std.meta.fields(ST)) |sf| {
                if (!std.mem.eql(u8, sf.name, "queues") and !std.mem.eql(u8, sf.name, "concurrency"))
                    @compileError("worker '" ++ f.name ++ "': unknown key '." ++ sf.name ++ "' (recognized keys: .queues, .concurrency)");
            }
            if (!@hasField(ST, "queues"))
                @compileError("worker '" ++ f.name ++ "': requires .queues = .{ \"q1\", … } (the queue names it drains)");
            var names: []const []const u8 = &.{};
            const QT = @TypeOf(spec.queues);
            if (@typeInfo(QT) != .@"struct")
                @compileError("worker '" ++ f.name ++ "': .queues must be a tuple of queue-name strings, e.g. .{ \"emails\", \"default\" }");
            for (std.meta.fields(QT)) |qf| {
                const qn = @field(spec.queues, qf.name);
                if (!isStringType(@TypeOf(qn)))
                    @compileError("worker '" ++ f.name ++ "': every .queues entry must be a queue-name string");
                var found = false;
                for (queue_defs) |q| if (std.mem.eql(u8, q.name, qn)) {
                    found = true;
                };
                if (!found)
                    @compileError("worker '" ++ f.name ++ "': references undeclared queue '" ++ qn ++ "' (declare it under .queues, or use \"default\")");
                names = names ++ &[_][]const u8{qn};
            }
            if (names.len == 0)
                @compileError("worker '" ++ f.name ++ "': .queues must list at least one queue");
            var def = WorkerDef{ .name = f.name, .queues = names };
            if (@hasField(ST, "concurrency")) {
                if (spec.concurrency == 0)
                    @compileError("worker '" ++ f.name ++ "': .concurrency must be >= 1");
                def.concurrency = spec.concurrency;
            }
            list = list ++ &[_]WorkerDef{def};
        }
        return list;
    }
}

/// The reserved key inside `.jobs` carrying the legacy scheduler worker-pool size
/// (`.jobs = .{ .pool_size = N }`); it is NOT a job-kind handler and is skipped by the
/// registry lowering. `.pools.jobs` is the preferred lever and takes precedence.
pub const reserved_pool_size_key = "pool_size";

/// Reflect a `.jobs` config literal into `[]const JobReg`. Each field is `name =
/// handlerFn` where the handler coerces to `fn(*Ctx, []const u8) anyerror!void`. The
/// reserved `.pool_size` key (legacy scheduler pool size) is skipped — `.jobs` thus
/// carries both the worker-pool size AND the job-kind registry. Loud `@compileError`
/// on a non-coercible handler.
pub fn jobsMeta(comptime jobs_cfg: anytype) []const JobReg {
    comptime {
        const T = @TypeOf(jobs_cfg);
        if (@typeInfo(T) != .@"struct")
            @compileError(".jobs must be a struct literal of kind = handlerFn bindings");
        var list: []const JobReg = &.{};
        for (std.meta.fields(T)) |f| {
            if (std.mem.eql(u8, f.name, reserved_pool_size_key)) continue;
            const h = @field(jobs_cfg, f.name);
            const HT = @TypeOf(h);
            const is_fn = switch (@typeInfo(HT)) {
                .@"fn" => true,
                .pointer => |ptr| ptr.size == .one and @typeInfo(ptr.child) == .@"fn",
                else => false,
            };
            if (!is_fn)
                @compileError("job '" ++ f.name ++ "' must be a handler fn 'fn(*Ctx, []const u8) anyerror!void'");
            const handler: queue.JobHandler = h; // coerces or fails loudly with the contract type
            list = list ++ &[_]JobReg{.{ .kind = f.name, .handler = handler }};
        }
        return list;
    }
}

/// Loud comptime guard: a consumer `.jobs` field name may not collide with a
/// framework-reserved built-in job kind (e.g. `"mail"`, and the upcoming `"webhook"`).
/// A collision is dead config — `Registry.jobByKind` resolves the built-in first, so the
/// consumer's handler would never run while still minting a misleading `Job.<kind>` enum
/// member. We reject it instead (matching the subsystem's loud-`@compileError` philosophy
/// for unknown keys / undeclared queues / the reserved `pool_size` key). `reserved` is the
/// list of built-in kinds (derive it from `builtin_job_regs` so this stays general as more
/// built-ins are added). The reserved `pool_size` key is skipped (it is not a job kind).
pub fn assertNoReservedJobKinds(comptime jobs_cfg: anytype, comptime reserved: []const []const u8) void {
    comptime {
        const T = @TypeOf(jobs_cfg);
        if (@typeInfo(T) != .@"struct") return; // jobsMeta validates shape; nothing to check here
        for (std.meta.fields(T)) |f| {
            if (std.mem.eql(u8, f.name, reserved_pool_size_key)) continue;
            for (reserved) |r| {
                if (std.mem.eql(u8, f.name, r))
                    @compileError("job kind '" ++ f.name ++ "' is reserved by the framework (use ctx." ++ f.name ++ "().enqueue) — rename your .jobs entry");
            }
        }
    }
}

/// Build an exhaustive enum whose members are the declared queue names (plus the
/// synthesized `default`). Order-independent: `App.enqueue` maps the enum to a name
/// via `@tagName`, so this is purely a compile-time spelling check.
pub fn QueueEnum(comptime queues_cfg: anytype) type {
    comptime {
        const fields = std.meta.fields(@TypeOf(queues_cfg));
        var has_default = false;
        for (fields) |f| if (std.mem.eql(u8, f.name, "default")) {
            has_default = true;
        };
        const extra: usize = if (has_default) 0 else 1;
        const n = fields.len + extra;
        var names: [n][:0]const u8 = undefined;
        for (fields, 0..) |f, i| names[i] = f.name;
        if (!has_default) names[fields.len] = "default";
        return enumFromNames(n, names);
    }
}

/// Build an exhaustive enum whose members are the declared job kinds (empty enum
/// when there are no `.jobs`).
pub fn JobEnum(comptime jobs_cfg: anytype) type {
    comptime {
        const all = std.meta.fields(@TypeOf(jobs_cfg));
        var names: [all.len][:0]const u8 = undefined;
        var n: usize = 0;
        for (all) |f| {
            if (std.mem.eql(u8, f.name, reserved_pool_size_key)) continue;
            names[n] = f.name;
            n += 1;
        }
        return enumFromNames(n, names[0..n].*);
    }
}

fn enumFromNames(comptime n: usize, comptime names: [n][:0]const u8) type {
    const IntTag = std.math.IntFittingRange(0, if (n == 0) 0 else n - 1);
    var values: [n]IntTag = undefined;
    for (0..n) |i| values[i] = @intCast(i);
    const frozen_names = names;
    const frozen_values = values;
    return @Enum(IntTag, .exhaustive, &frozen_names, &frozen_values);
}

// ---------------------------------------------------------------------------
// Tests — comptime lowering. (Loud `@compileError` paths can't be asserted as
// runtime tests; they are verified by inspection / temporary compile checks.)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "queueMeta synthesizes a default queue when absent" {
    const defs = comptime queueMeta(.{});
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("default", defs[0].name);
    try testing.expectEqual(queue.Backend.memory, defs[0].backend);
    try testing.expectEqual(queue.Priority.normal, defs[0].priority);
    try testing.expectEqual(@as(u16, 5), defs[0].retry.max_attempts);
    // Timeout defaults.
    try testing.expectEqual(@as(i64, 300), defs[0].visibility_timeout_s);
    try testing.expectEqual(@as(i64, 7 * 24 * 3600), defs[0].done_ttl_s);
}

test "queueMeta lowers per-queue visibility_timeout_s / done_ttl_s" {
    const defs = comptime queueMeta(.{
        .slow = .{ .backend = .durable, .visibility_timeout_s = 1800, .done_ttl_s = 86400 },
    });
    // defs[0] is the synthesized default (defaults intact); defs[1] is 'slow'.
    try testing.expectEqual(@as(i64, 300), defs[0].visibility_timeout_s);
    try testing.expectEqualStrings("slow", defs[1].name);
    try testing.expectEqual(@as(i64, 1800), defs[1].visibility_timeout_s);
    try testing.expectEqual(@as(i64, 86400), defs[1].done_ttl_s);
}

test "queueMeta lowers backend/priority/retry and keeps an explicit default" {
    const defs = comptime queueMeta(.{
        .default = .{ .backend = .durable },
        .emails = .{ .backend = .durable, .priority = .high, .retry = .{ .max_attempts = 3, .backoff = .fixed, .base_ms = 500, .max_ms = 9000, .jitter = false } },
    });
    try testing.expectEqual(@as(usize, 2), defs.len);
    // explicit default is NOT duplicated
    try testing.expectEqualStrings("default", defs[0].name);
    try testing.expectEqual(queue.Backend.durable, defs[0].backend);
    try testing.expectEqualStrings("emails", defs[1].name);
    try testing.expectEqual(queue.Priority.high, defs[1].priority);
    try testing.expectEqual(queue.Backoff.fixed, defs[1].retry.backoff);
    try testing.expectEqual(@as(u16, 3), defs[1].retry.max_attempts);
    try testing.expectEqual(@as(u32, 500), defs[1].retry.base_ms);
    try testing.expect(!defs[1].retry.jitter);
}

test "queueMeta lowers .rate on a durable queue and defaults to null" {
    const defs = comptime queueMeta(.{
        .ses_mail = .{ .backend = .durable, .rate = .{ .per_second = 14 } },
    });
    try testing.expect(defs[0].rate == null); // synthesized default
    try testing.expectEqualStrings("ses_mail", defs[1].name);
    try testing.expectEqual(@as(u16, 14), defs[1].rate.?.per_second);
}

test "workerMeta default = one implicit worker over all queues" {
    const qdefs = comptime queueMeta(.{ .emails = .{ .backend = .durable } });
    const wdefs = comptime workerMeta(.{}, qdefs);
    try testing.expectEqual(@as(usize, 1), wdefs.len);
    try testing.expectEqualStrings("default", wdefs[0].name);
    try testing.expectEqual(@as(u8, 1), wdefs[0].concurrency);
    try testing.expectEqual(@as(usize, 2), wdefs[0].queues.len); // default + emails
}

test "workerMeta lowers explicit workers + concurrency" {
    const qdefs = comptime queueMeta(.{ .emails = .{ .backend = .durable }, .low = .{ .priority = .low } });
    const wdefs = comptime workerMeta(.{
        .mailer = .{ .queues = .{"emails"}, .concurrency = 4 },
        .general = .{ .queues = .{ "default", "low" } },
    }, qdefs);
    try testing.expectEqual(@as(usize, 2), wdefs.len);
    try testing.expectEqualStrings("mailer", wdefs[0].name);
    try testing.expectEqual(@as(u8, 4), wdefs[0].concurrency);
    try testing.expectEqualStrings("emails", wdefs[0].queues[0]);
    try testing.expectEqual(@as(usize, 2), wdefs[1].queues.len);
}

fn testHandler(ctx: *@import("../ctx.zig").Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
}

test "jobsMeta lowers kind=handler bindings" {
    const regs = comptime jobsMeta(.{ .resize = testHandler, .reindex = testHandler });
    try testing.expectEqual(@as(usize, 2), regs.len);
    try testing.expectEqualStrings("resize", regs[0].kind);
    try testing.expectEqualStrings("reindex", regs[1].kind);
}

test "assertNoReservedJobKinds passes for non-colliding kinds (incl. pool_size + empty)" {
    // Non-colliding consumer kinds compile; the reserved pool_size key is ignored; an
    // empty `.jobs` is fine. (The collision case is a @compileError, not unit-testable.)
    const reserved: []const []const u8 = &.{ "mail", "webhook" };
    comptime assertNoReservedJobKinds(.{ .resize = testHandler, .pool_size = 3 }, reserved);
    comptime assertNoReservedJobKinds(.{}, reserved);
}

test "QueueEnum includes synthesized default + declared queues" {
    const Q = QueueEnum(.{ .emails = .{}, .reports = .{} });
    try testing.expectEqualStrings("emails", @tagName(@as(Q, .emails)));
    try testing.expectEqualStrings("default", @tagName(@as(Q, .default)));
    try testing.expectEqual(@as(usize, 3), std.meta.fields(Q).len);
}

test "JobEnum members are the declared kinds" {
    const J = JobEnum(.{ .resize = testHandler });
    try testing.expectEqualStrings("resize", @tagName(@as(J, .resize)));
    try testing.expectEqual(@as(usize, 1), std.meta.fields(J).len);
}
