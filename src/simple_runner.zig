//! A `.simple`-mode test runner for apps built on ZigBase, handed to consumers by
//! `zigbase.addTest` in build.zig.
//!
//! `zig build test` normally runs the test binary in SERVER mode (`--listen=-`) and
//! reads results off its stdio. An app booted by `zigbase.testing` does real work at
//! process exit (closing sqlite, removing a tempdir), and Zig 0.16's build runner can
//! mis-read that exit-time output as a crash — printing `failed command: … --listen=-`
//! and intermittently failing the build under load. A `.simple` runner runs the tests
//! when spawned and communicates only through its exit code, so the race cannot occur.
//!
//! It still fails the build on a real failure, a leaked allocation, or a logged
//! `.err`-or-worse message: every test gets a fresh `std.testing.allocator` whose leak
//! check runs on teardown, and `std_options.logFn` routes through this file's `log`,
//! which both counts errors and suppresses chatter below `std.testing.log_level`
//! (default `.warn`) — otherwise a booted app's routine `info:` startup lines would
//! spam every run.
//!
//! Structure follows Zig 0.16's own `mainTerminal`, minus the progress/fuzz/tty paths.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

/// Mirrors the stock test runner's mechanism (`lib/compiler/test_runner.zig`): the
/// runner's `log` below is only reachable at all because `std_options.logFn` points
/// at it — without this, `std.log.*` calls fall through to the default `logFn`, which
/// prints unconditionally and never touches `log_err_count`, so the boot-time `info:`
/// chatter from an app booted by `zigbase.testing` would spam every test run and a
/// genuine `.err` log would silently NOT fail the build.
pub const std_options: std.Options = .{
    .logFn = log,
};

/// Counts `.err`-level (and worse) log messages across the WHOLE run (never reset —
/// this process runs once), mirroring the stock runner's `mainTerminal` treatment.
/// Nonzero at the end fails the build, same as a leak.
var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    const tests = builtin.test_functions;
    var ok: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;

    for (tests, 0..) |t, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        std.debug.print("{d}/{d} {s}... ", .{ i + 1, tests.len, t.name });
        if (t.func()) |_| {
            ok += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                failed += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }

        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) {
            leaks += 1;
            std.debug.print("    ^ LEAKED memory in {s}\n", .{t.name});
        }
    }

    std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked.\n", .{ ok, skipped, failed, leaks });
    if (log_err_count != 0) {
        std.debug.print("{d} error(s) were logged.\n", .{log_err_count});
    }
    if (failed != 0 or leaks != 0 or log_err_count != 0) std.process.exit(1);
}

/// Same shape as the stock runner's `log` (`lib/compiler/test_runner.zig`): count every
/// `.err`-or-worse message regardless of `testing.log_level`, but only PRINT messages at
/// or above `testing.log_level` (default `.warn`) — so an app's routine `info:` boot
/// chatter is suppressed while warnings/errors still surface.
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
