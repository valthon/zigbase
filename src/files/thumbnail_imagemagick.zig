//! Bounded, caller-admitted ImageMagick subprocess transforms.
//! Pixel-cache limits are child policies, not allocator or total-RSS ceilings.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
});

pub const Format = enum {
    png,
    jpeg,
    webp,
    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }
};
pub const Profile = struct {
    width: u32,
    height: u32,
    format: Format = .png,
    fit: enum { contain, cover } = .contain,
    quality: u8 = 85,
};
pub const Config = struct {
    executable: []const u8,
    command_style: enum { magick, convert } = .magick,
    max_input_bytes: usize = 32 << 20,
    max_output_bytes: usize = 16 << 20,
    max_stderr_bytes: usize = 16 << 10,
    timeout_ms: u32 = 10_000,
    threads: u16 = 1,
    memory_bytes: usize = 128 << 20,
    map_bytes: usize = 0,
    disk_bytes: usize = 0,
    max_dimension: u32 = 16384,
    max_pixels: u64 = 40_000_000,
};
pub const Result = struct {
    storage: []u8,
    len: usize,
    format: Format,
    pub fn bytes(self: Result) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }
};

pub fn validateConfig(cfg: Config) bool {
    return std.fs.path.isAbsolute(cfg.executable) and std.mem.indexOfScalar(u8, cfg.executable, 0) == null and
        cfg.max_input_bytes > 0 and cfg.max_output_bytes > 0 and cfg.max_stderr_bytes > 0 and
        cfg.timeout_ms > 0 and cfg.threads > 0 and cfg.memory_bytes > 0 and cfg.max_dimension > 0 and cfg.max_pixels > 0;
}

pub fn validProfile(cfg: Config, profile: Profile) bool {
    return profile.width > 0 and profile.height > 0 and profile.width <= cfg.max_dimension and profile.height <= cfg.max_dimension and
        @as(u64, profile.width) * profile.height <= cfg.max_pixels and
        profile.quality > 0 and profile.quality <= 100;
}

fn valid(cfg: Config, profile: Profile) bool {
    return validateConfig(cfg) and validProfile(cfg, profile);
}

/// Startup identity/command-style check using only -version, without inheriting
/// deployment secrets. This does not probe coders or the effective image policy.
/// Requests exercise their actual input/output formats under the fixed policy;
/// an unavailable or policy-denied coder fails conversion without fallback.
pub fn probe(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !void {
    if (!validateConfig(cfg)) return error.InvalidImageMagickConfiguration;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("HOME", "/nonexistent");
    try env.put("XDG_CONFIG_HOME", "/nonexistent");
    var output: [4096]u8 = undefined;
    const len = try pump(io, &.{ cfg.executable, "-version" }, &env, "/", "", &output, cfg.max_stderr_bytes, cfg.timeout_ms);
    const prefix = switch (cfg.command_style) {
        .convert => "Version: ImageMagick 6.",
        .magick => "Version: ImageMagick 7.",
    };
    if (!std.mem.startsWith(u8, output[0..len], prefix)) return error.ImageExecutableIncompatible;
}

// Inspect bounded container chunks, not compressed image data. Some IM6 builds
// silently flatten APNG/WebP animations, so metadata probing alone is insufficient.
fn rejectAnimation(input: []const u8, format: Format) !void {
    if (format == .jpeg) return;
    var offset: usize = if (format == .png) 8 else 12;
    while (offset < input.len) {
        const overhead: usize = if (format == .png) 12 else 8;
        if (input.len - offset < overhead) return error.ImageConversionFailed;
        const kind = if (format == .png) input[offset + 4 ..][0..4] else input[offset..][0..4];
        const payload_size: usize = if (format == .png) std.mem.readInt(u32, input[offset..][0..4], .big) else std.mem.readInt(u32, input[offset + 4 ..][0..4], .little);
        if (std.mem.eql(u8, kind, "acTL") or std.mem.eql(u8, kind, "ANIM") or std.mem.eql(u8, kind, "ANMF")) return error.AnimatedImageUnsupported;
        const padding = if (format == .webp) payload_size % 2 else 0;
        if (payload_size > input.len - offset - overhead or padding > input.len - offset - overhead - payload_size) return error.ImageConversionFailed;
        offset += overhead + payload_size + padding;
    }
}

fn dimensions(text: []const u8, cfg: Config) !struct { width: u32, height: u32 } {
    var values = std.mem.tokenizeAny(u8, text, " \r\n\t");
    const width = std.fmt.parseInt(u32, values.next() orelse return error.InvalidImageOutput, 10) catch return error.InvalidImageOutput;
    const height = std.fmt.parseInt(u32, values.next() orelse return error.InvalidImageOutput, 10) catch return error.InvalidImageOutput;
    const frames = std.fmt.parseInt(u32, values.next() orelse return error.InvalidImageOutput, 10) catch return error.InvalidImageOutput;
    if (frames != 1 or values.next() != null) return error.AnimatedImageUnsupported;
    if (width == 0 or height == 0) return error.ImageConversionFailed;
    if (width > cfg.max_dimension or height > cfg.max_dimension or @as(u64, width) * height > cfg.max_pixels) return error.ImageDimensionsExceeded;
    return .{ .width = width, .height = height };
}

fn remaining(io: std.Io, deadline: std.Io.Timestamp) !u32 {
    const ns = deadline.nanoseconds - std.Io.Timestamp.now(io, .awake).nanoseconds;
    if (ns <= 0) return error.ImageProcessTimeout;
    return @intCast(@min(@as(i96, std.math.maxInt(u32)), @divTrunc(ns + 999_999, 1_000_000)));
}

fn sniff(input: []const u8) ?Format {
    if (std.mem.startsWith(u8, input, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, input, "\xff\xd8\xff")) return .jpeg;
    if (input.len >= 12 and std.mem.eql(u8, input[0..4], "RIFF") and std.mem.eql(u8, input[8..12], "WEBP")) return .webp;
    return null;
}

/// Borrow input; return one caller-owned allocation. Caller supplies admission
/// and probes the configured executable once before serving requests.
/// Installed executable/system policies are trusted deployment dependencies.
pub fn transform(allocator: std.mem.Allocator, io: std.Io, input: []const u8, cfg: Config, profile: Profile) !Result {
    if (!valid(cfg, profile)) return error.InvalidImageMagickConfiguration;
    if (input.len > cfg.max_input_bytes) return error.ImageInputTooLarge;
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(cfg.timeout_ms));
    const input_format = sniff(input) orelse return error.UnsupportedImageFormat;
    try rejectAnimation(input, input_format);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory_template = "/tmp/zigbase-imagemagick-XXXXXX".*;
    const directory_z = c.mkdtemp(&directory_template) orelse return error.ImageWorkspaceUnavailable;
    const directory = std.mem.span(directory_z);
    // A private configuration/cache directory, never a retained derivative.
    var cleanup_needed = true;
    defer if (cleanup_needed) std.Io.Dir.cwd().deleteTree(io, directory) catch |err| {
        std.log.err("ImageMagick workspace cleanup failed: {s}", .{@errorName(err)});
    };
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{});
    defer dir.close(io);
    const policy = try std.fmt.allocPrint(a, "<policymap>" ++
        "<policy domain=\"delegate\" rights=\"none\" pattern=\"*\"/>" ++
        "<policy domain=\"filter\" rights=\"none\" pattern=\"*\"/>" ++
        "<policy domain=\"path\" rights=\"none\" pattern=\"@*\"/>" ++
        "<policy domain=\"coder\" rights=\"none\" pattern=\"*\"/>" ++
        "<policy domain=\"coder\" rights=\"read|write\" pattern=\"{{PNG,JPEG,WEBP}}\"/>" ++
        "<policy domain=\"coder\" rights=\"write\" pattern=\"INFO\"/>" ++
        "<policy domain=\"resource\" name=\"width\" value=\"{d}\"/>" ++
        "<policy domain=\"resource\" name=\"height\" value=\"{d}\"/>" ++
        // Allow enough metadata to recognize a sequence, never an unbounded list.
        "<policy domain=\"resource\" name=\"list-length\" value=\"2\"/>" ++
        "</policymap>", .{ cfg.max_dimension, cfg.max_dimension });
    try dir.writeFile(io, .{ .sub_path = "policy.xml", .data = policy, .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } });
    var env = std.process.Environ.Map.init(a);
    // No inherited PATH, credentials, loader overrides, HOME or MAGICK settings.
    try env.put("HOME", directory);
    try env.put("XDG_CONFIG_HOME", directory);
    try env.put("MAGICK_CONFIGURE_PATH", directory);
    try env.put("MAGICK_TEMPORARY_PATH", directory);
    try env.put("TMPDIR", directory);
    try env.put("LC_ALL", "C");
    try env.put("OMP_NUM_THREADS", try std.fmt.allocPrint(a, "{d}", .{cfg.threads}));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, cfg.executable);
    inline for (.{ .{ "thread", cfg.threads }, .{ "memory", cfg.memory_bytes }, .{ "map", cfg.map_bytes }, .{ "disk", cfg.disk_bytes }, .{ "time", (@as(u64, cfg.timeout_ms) + 999) / 1000 } }) |limit| {
        try argv.appendSlice(a, &.{ "-limit", limit[0], try std.fmt.allocPrint(a, "{d}", .{limit[1]}) });
    }
    const source = switch (input_format) {
        .png => "PNG:-",
        .jpeg => "JPEG:-",
        .webp => "WEBP:-",
    };
    const limits_len = argv.items.len;
    try argv.appendSlice(a, &.{ "-ping", source, "-format", "%w %h %n\n", "INFO:-" });
    var metadata: [128]u8 = undefined;
    // The configured width/height policy may reject even -ping before metadata
    // is available. Such rejection remains ImageConversionFailed (HTTP 422), as
    // do installed-policy/decoder failures: stderr text is not a stable error API.
    // Only limits verified from successful metadata produce DimensionsExceeded.
    const metadata_len = try pump(io, argv.items, &env, directory, input, &metadata, cfg.max_stderr_bytes, try remaining(io, deadline));
    _ = try dimensions(metadata[0..metadata_len], cfg);
    argv.shrinkRetainingCapacity(limits_len);
    const geometry = try std.fmt.allocPrint(a, "{d}x{d}{s}", .{ profile.width, profile.height, if (profile.fit == .cover) "^" else ">" });
    try argv.appendSlice(a, &.{ source, "-auto-orient", "-strip", "-resize", geometry });
    if (profile.fit == .cover) try argv.appendSlice(a, &.{ "-gravity", "center", "-extent", try std.fmt.allocPrint(a, "{d}x{d}", .{ profile.width, profile.height }) });
    if (profile.format == .jpeg) try argv.appendSlice(a, &.{ "-background", "white", "-alpha", "remove", "-alpha", "off" });
    try argv.appendSlice(a, &.{ "-quality", try std.fmt.allocPrint(a, "{d}", .{profile.quality}), switch (profile.format) {
        .png => "PNG:-",
        .jpeg => "JPEG:-",
        .webp => "WEBP:-",
    } });
    var output = try allocator.alloc(u8, cfg.max_output_bytes);
    errdefer allocator.free(output);
    const len = try pump(io, argv.items, &env, directory, input, output, cfg.max_stderr_bytes, try remaining(io, deadline));
    if (sniff(output[0..len]) != profile.format) return error.InvalidImageOutput;
    try rejectAnimation(output[0..len], profile.format);
    argv.shrinkRetainingCapacity(limits_len);
    const output_source = switch (profile.format) {
        .png => "PNG:-",
        .jpeg => "JPEG:-",
        .webp => "WEBP:-",
    };
    try argv.appendSlice(a, &.{ "-ping", output_source, "-format", "%w %h %n\n", "INFO:-" });
    const output_metadata_len = try pump(io, argv.items, &env, directory, output[0..len], &metadata, cfg.max_stderr_bytes, try remaining(io, deadline));
    const output_dimensions = try dimensions(metadata[0..output_metadata_len], cfg);
    if (output_dimensions.width > profile.width or output_dimensions.height > profile.height or
        (profile.fit == .cover and (output_dimensions.width != profile.width or output_dimensions.height != profile.height))) return error.InvalidImageOutput;
    try std.Io.Dir.cwd().deleteTree(io, directory);
    cleanup_needed = false;
    // Hand off only encoded bytes, not the configured ceiling. On failure realloc
    // leaves the old allocation owned by the immediately registered errdefer.
    output = try allocator.realloc(output, len);
    return .{ .storage = output, .len = len, .format = profile.format };
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.ImageProcessIo;
}

/// A socket for stdin avoids SIGPIPE without changing process-wide signal state.
/// One poll loop concurrently feeds input and drains both output streams.
fn pump(io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map, cwd: []const u8, input: []const u8, output: []u8, stderr_limit: usize, timeout_ms: u32) !usize {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets) < 0) return error.ImageProcessIo;
    defer _ = c.close(sockets[0]);
    var child_socket_open = true;
    defer if (child_socket_open) {
        _ = c.close(sockets[1]);
    };
    for (sockets) |fd| if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.ImageProcessIo;
    if (builtin.os.tag == .macos) {
        var enabled: c_int = 1;
        if (c.setsockopt(sockets[0], c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int)) < 0) return error.ImageProcessIo;
    }
    try nonblocking(sockets[0]);
    const child = std.process.spawn(io, .{ .argv = argv, .environ_map = env, .cwd = .{ .path = cwd }, .pgid = 0, .stdin = .{ .file = .{ .handle = sockets[1], .flags = .{ .nonblocking = false } } }, .stdout = .pipe, .stderr = .pipe }) catch return error.ImageExecutableUnavailable;
    const pid = child.id.?;
    _ = c.close(sockets[1]);
    child_socket_open = false;
    var reaped = false;
    defer {
        // Never target group zero/the caller group. The spawn explicitly creates
        // a group whose ID is this positive child PID. Escaped descendants are
        // not contained; delegates are disabled by the image policy.
        if (!reaped and c.kill(-pid, c.SIGKILL) < 0 and std.posix.errno(-1) != .SRCH)
            std.log.err("ImageMagick process-group cleanup failed", .{});
        if (!reaped) {
            const until = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(2000));
            while (std.Io.Timestamp.now(io, .awake).nanoseconds < until.nanoseconds) {
                var status: c_int = 0;
                const waited = c.waitpid(pid, &status, c.WNOHANG);
                if (waited == pid or (waited < 0 and std.posix.errno(waited) == .CHILD)) {
                    reaped = true;
                    break;
                }
                // Cleanup must not be abandoned when request I/O is cancelled.
                // poll has no descriptors here; EINTR simply retries the deadline.
                _ = c.poll(null, 0, 1);
            }
            if (!reaped) std.log.err("ImageMagick child could not be reaped within cleanup deadline", .{});
        }
        if (child.stdout) |file| file.close(io);
        if (child.stderr) |file| file.close(io);
    }
    try nonblocking(child.stdout.?.handle);
    try nonblocking(child.stderr.?.handle);
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(timeout_ms));
    var written: usize = 0;
    var used: usize = 0;
    var stderr_used: usize = 0;
    var input_done = false;
    var stdout_done = false;
    var stderr_done = false;
    var exit_status: c_int = 0;
    var finished = false;
    while (!finished or !stdout_done or !stderr_done) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return error.ImageProcessTimeout;
        if (!finished) {
            // Keep the PID reserved until group cleanup, avoiding a recycled-PID kill.
            var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
            const waited = c.waitid(c.P_PID, @intCast(pid), &info, c.WEXITED | c.WNOHANG | c.WNOWAIT);
            if (waited < 0 and std.posix.errno(waited) != .INTR) {
                // An embedding application must not reap children it does not
                // own. If it nevertheless did, never kill a now-reusable PID.
                if (std.posix.errno(waited) == .CHILD) reaped = true;
                return error.ImageProcessIo;
            }
            finished = info.si_signo != 0;
        }
        if (!input_done and written == input.len) {
            _ = c.shutdown(sockets[0], c.SHUT_WR);
            input_done = true;
        }
        var pollers = [_]c.struct_pollfd{
            .{ .fd = if (input_done) -1 else sockets[0], .events = c.POLLOUT, .revents = 0 },
            .{ .fd = if (stdout_done) -1 else child.stdout.?.handle, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (stderr_done) -1 else child.stderr.?.handle, .events = c.POLLIN, .revents = 0 },
        };
        if (c.poll(&pollers, pollers.len, 10) < 0) {
            if (std.posix.errno(-1) == .INTR) continue;
            return error.ImageProcessIo;
        }
        if (!input_done and pollers[0].revents != 0) {
            const n = c.send(sockets[0], input[written..].ptr, @min(input.len - written, 8192), if (builtin.os.tag == .linux) c.MSG_NOSIGNAL else 0);
            if (n >= 0) written += @intCast(n) else switch (std.posix.errno(n)) {
                .AGAIN, .INTR => {},
                .PIPE, .CONNRESET => input_done = true,
                else => return error.ImageProcessIo,
            }
        }
        for (pollers[1..], 0..) |p, index| {
            if (p.fd < 0 or p.revents == 0) continue;
            var buffer: [8192]u8 = undefined;
            const n = c.read(p.fd, &buffer, buffer.len);
            if (n < 0) {
                if (std.posix.errno(n) == .AGAIN or std.posix.errno(n) == .INTR) continue;
                return error.ImageProcessIo;
            }
            if (n == 0) {
                if (index == 0) stdout_done = true else stderr_done = true;
                continue;
            }
            const count: usize = @intCast(n);
            if (index == 0) {
                if (count > output.len - used) return error.ImageOutputTooLarge;
                @memcpy(output[used..][0..count], buffer[0..count]);
                used += count;
            } else {
                if (count > stderr_limit - stderr_used) return error.ImageDiagnosticsTooLarge;
                stderr_used += count;
            }
        }
    }
    if (c.kill(-pid, c.SIGKILL) < 0 and std.posix.errno(-1) != .SRCH) return error.ImageProcessCleanupFailed;
    while (true) {
        const waited = c.waitpid(pid, &exit_status, c.WNOHANG);
        if (waited == pid) {
            reaped = true;
            break;
        }
        if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
        if (waited < 0 and std.posix.errno(waited) == .CHILD) reaped = true;
        return error.ImageProcessCleanupFailed;
    }
    if (exit_status != 0) return error.ImageConversionFailed;
    return used;
}

test "ImageMagick config accepts capability tuning above embedded ceilings" {
    try std.testing.expect(valid(.{ .executable = "/usr/bin/convert", .max_input_bytes = 64 << 20, .max_output_bytes = 32 << 20 }, .{ .width = 4096, .height = 2048, .format = .webp }));
    try std.testing.expect(!valid(.{ .executable = "convert" }, .{ .width = 1, .height = 1 }));
}

test "installed ImageMagick converts PNG JPEG and WebP" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/convert", .{}) catch return error.SkipZigTest;
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
    var input: [encoded.len]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(input[0..size], encoded);
    const cfg: Config = .{ .executable = "/usr/bin/convert", .command_style = .convert, .max_output_bytes = 65536 };
    for ([_]Format{ .png, .jpeg, .webp }) |format| {
        const out = try transform(std.testing.allocator, std.testing.io, input[0..size], cfg, .{ .width = 1024, .height = 1024, .format = format });
        defer out.deinit(std.testing.allocator);
        try std.testing.expectEqual(out.len, out.storage.len);
        const back = try transform(std.testing.allocator, std.testing.io, out.bytes(), cfg, .{ .width = 1, .height = 1 });
        defer back.deinit(std.testing.allocator);
        try std.testing.expectEqual(.png, sniff(back.bytes()).?);
    }
}

test "process pump concurrently feeds input and drains both outputs" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/python3", .{}) catch return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var input: [65536]u8 = @splat('x');
    var output: [65536]u8 = undefined;
    const args = &.{ "/usr/bin/python3", "-c", "import os\nwhile b := os.read(0,1024):\n os.write(1,b)\n os.write(2,b'x')" };
    const len = try pump(std.testing.io, args, &env, "/tmp", &input, &output, 1024, 2000);
    try std.testing.expectEqualSlices(u8, &input, output[0..len]);
}

test "process pump bounds timeout stdout stderr and handles early input closure" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/python3", .{}) catch return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var output: [1024]u8 = undefined;
    var input: [65536]u8 = @splat('x');
    const python = "/usr/bin/python3";
    try std.testing.expectError(error.ImageProcessTimeout, pump(std.testing.io, &.{ python, "-c", "import time; time.sleep(30)" }, &env, "/tmp", &input, &output, 1024, 50));
    try std.testing.expectError(error.ImageOutputTooLarge, pump(std.testing.io, &.{ python, "-c", "import os; os.write(1,b'x'*65536)" }, &env, "/tmp", &input, &output, 1024, 2000));
    try std.testing.expectError(error.ImageDiagnosticsTooLarge, pump(std.testing.io, &.{ python, "-c", "import os; os.write(2,b'x'*65536)" }, &env, "/tmp", &input, &output, 1024, 2000));
    try std.testing.expectError(error.ImageConversionFailed, pump(std.testing.io, &.{ python, "-c", "raise SystemExit(17)" }, &env, "/tmp", &input, &output, 1024, 2000));
    try std.testing.expectEqual(@as(usize, 0), try pump(std.testing.io, &.{ python, "-c", "pass" }, &env, "/tmp", &input, &output, 1024, 2000));
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
    var input: [encoded.len]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(input[0..size], encoded);
    const result = try transform(allocator, std.testing.io, input[0..size], .{ .executable = "/usr/bin/convert", .command_style = .convert, .max_output_bytes = 1024 }, .{ .width = 1, .height = 1 });
    defer result.deinit(allocator);
}

test "ImageMagick transform frees scratch and result across allocation failures" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/convert", .{}) catch return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
    // Force realloc's allocate/copy/free fallback, including failure while
    // shrinking the final output. The original ceiling allocation must be freed.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationWithoutResize, .{});
}

fn allocationWithoutResize(allocator: std.mem.Allocator) !void {
    var vtable = allocator.vtable.*;
    vtable.resize = std.mem.Allocator.noResize;
    vtable.remap = std.mem.Allocator.noRemap;
    try allocationExercise(.{ .ptr = allocator.ptr, .vtable = &vtable });
}

test "image metadata rejects dimensions pixels multiple frames and malformed output" {
    const cfg: Config = .{ .executable = "/usr/bin/convert", .max_dimension = 100, .max_pixels = 1000 };
    const image = try dimensions("25 40 1\n", cfg);
    try std.testing.expectEqual(@as(u32, 25), image.width);
    try std.testing.expectError(error.ImageDimensionsExceeded, dimensions("25 41 1", cfg));
    try std.testing.expectError(error.ImageDimensionsExceeded, dimensions("101 1 1", cfg));
    try std.testing.expectError(error.AnimatedImageUnsupported, dimensions("1 1 2\n1 1 2", cfg));
    try std.testing.expectError(error.AnimatedImageUnsupported, dimensions("1 1 1\n1 1 1", cfg));
    try std.testing.expectError(error.InvalidImageOutput, dimensions("4294967296 1 1", cfg));
    try std.testing.expectError(error.ImageConversionFailed, dimensions("0 1 1", cfg));
    try std.testing.expectError(error.InvalidImageOutput, dimensions("1 1", cfg));
    try std.testing.expect(!validProfile(cfg, .{ .width = 25, .height = 41 }));
}

test "container preflight rejects animation and truncated chunk arithmetic" {
    try std.testing.expectError(error.AnimatedImageUnsupported, rejectAnimation("\x89PNG\r\n\x1a\n\x00\x00\x00\x08acTL000000000000", .png));
    try std.testing.expectError(error.AnimatedImageUnsupported, rejectAnimation("RIFF0000WEBPANIM\x00\x00\x00\x00", .webp));
    try std.testing.expectError(error.ImageConversionFailed, rejectAnimation("\x89PNG\r\n\x1a\n\xff\xff\xff\xffIDAT0000", .png));
    try std.testing.expectError(error.ImageConversionFailed, rejectAnimation("RIFF0000WEBPVP8 \xff\xff\xff\xff", .webp));
    try std.testing.expectError(error.ImageConversionFailed, rejectAnimation("RIFF0000WEBPVP8 \x01\x00\x00\x00x", .webp));
}

test "executable probe distinguishes missing and incompatible style" {
    try std.testing.expectError(error.ImageExecutableUnavailable, probe(std.testing.allocator, std.testing.io, .{ .executable = "/nonexistent/zigbase-test-magick" }));
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/convert", .{}) catch return error.SkipZigTest;
    try probe(std.testing.allocator, std.testing.io, .{ .executable = "/usr/bin/convert", .command_style = .convert });
    try std.testing.expectError(error.ImageExecutableIncompatible, probe(std.testing.allocator, std.testing.io, .{ .executable = "/usr/bin/convert", .command_style = .magick }));
}

test "process pump uses only explicit environment and closes input without SIGPIPE" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/python3", .{}) catch return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EXPLICIT", "present");
    var output: [1024]u8 = undefined;
    const len = try pump(std.testing.io, &.{ "/usr/bin/python3", "-c", "import os; assert os.environ.get('EXPLICIT') == 'present'; assert set(os.environ) <= {'EXPLICIT','LC_CTYPE'}; os.write(1,b'ok')" }, &env, "/tmp", "", &output, 1024, 2000);
    try std.testing.expectEqualStrings("ok", output[0..len]);
}

test "real transforms enforce pixel input output limits and recover after rejection" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/convert", .{}) catch return error.SkipZigTest;
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
    var input: [encoded.len]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(input[0..size], encoded);
    var cfg: Config = .{ .executable = "/usr/bin/convert", .command_style = .convert, .max_output_bytes = 65536 };
    const expanded = try transform(std.testing.allocator, std.testing.io, input[0..size], cfg, .{ .width = 4, .height = 3, .fit = .cover });
    defer expanded.deinit(std.testing.allocator);
    cfg.max_dimension = 3;
    try std.testing.expectError(error.ImageConversionFailed, transform(std.testing.allocator, std.testing.io, expanded.bytes(), cfg, .{ .width = 1, .height = 1 }));
    cfg.max_dimension = 16384;
    cfg.max_pixels = 11;
    try std.testing.expectError(error.ImageDimensionsExceeded, transform(std.testing.allocator, std.testing.io, expanded.bytes(), cfg, .{ .width = 1, .height = 1 }));
    cfg.max_pixels = 12;
    cfg.max_input_bytes = expanded.len - 1;
    try std.testing.expectError(error.ImageInputTooLarge, transform(std.testing.allocator, std.testing.io, expanded.bytes(), cfg, .{ .width = 1, .height = 1 }));
    cfg.max_input_bytes = expanded.len;
    cfg.max_output_bytes = 1;
    try std.testing.expectError(error.ImageOutputTooLarge, transform(std.testing.allocator, std.testing.io, expanded.bytes(), cfg, .{ .width = 1, .height = 1 }));
    cfg.max_output_bytes = 65536;
    const recovered = try transform(std.testing.allocator, std.testing.io, expanded.bytes(), cfg, .{ .width = 1, .height = 1 });
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(.png, recovered.format);
    try std.testing.expectError(error.UnsupportedImageFormat, transform(std.testing.allocator, std.testing.io, "<svg/>", cfg, .{ .width = 1, .height = 1 }));
}

test "transform shares deadline across stages and validates returned dimensions" {
    std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/python3", .{}) catch return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        "#!/usr/bin/python3\n" ++
        "import sys,time,base64,os\n" ++
        "assert not ({'PATH','LD_PRELOAD','AWS_SECRET_ACCESS_KEY'} & set(os.environ))\n" ++
        "assert os.environ['HOME']==os.getcwd()\n" ++
        "assert sys.argv[1:3]==['-limit','thread']\n" ++
        "data=sys.stdin.buffer.read()\n" ++
        "time.sleep(0.08)\n" ++
        "if '-ping' in sys.argv: print('1 1 1')\n" ++
        "else: sys.stdout.buffer.write(data)\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-magick", .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
    const executable = try tmp.dir.realPathFileAlloc(io, "fake-magick", a);
    defer a.free(executable);
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
    var input: [encoded.len]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(input[0..size], encoded);
    var cfg: Config = .{ .executable = executable, .timeout_ms = 120, .max_output_bytes = 1024 };
    try std.testing.expectError(error.ImageProcessTimeout, transform(a, io, input[0..size], cfg, .{ .width = 1, .height = 1 }));
    cfg.timeout_ms = 2000;
    const recovered = try transform(a, io, input[0..size], cfg, .{ .width = 1, .height = 1 });
    defer recovered.deinit(a);
    // Fake executable claims a 1x1 result, so it must not satisfy a 2x2 cover.
    try std.testing.expectError(error.InvalidImageOutput, transform(a, io, input[0..size], cfg, .{ .width = 2, .height = 2, .fit = .cover }));
}
