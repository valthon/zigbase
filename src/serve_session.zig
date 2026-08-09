//! Session lockfile for `zigbase serve` — the on-disk contract behind
//! `serve --background`, `serve status|stop|logs`, and duplicate-start
//! detection. Adopted VERBATIM (field names, atomic write, flock liveness)
//! from zigapagos's `src/cli/dev_lockfile.zig`, per the AI-agents program
//! design decision #8. Consumer documentation: docs/serve.md.
//!
//! Two files under the data dir:
//!   * `serve.lock` — an empty file the serving process holds an exclusive
//!     `flock(2)` on for its whole lifetime. Liveness IS the lock: the kernel
//!     drops it the instant the holder dies, by any means, including `kill -9`.
//!     A non-blocking try-lock is therefore a race-free staleness check that
//!     sidesteps both of `kill(pid, 0)`'s failure modes — PID reuse reading as
//!     "alive", and EPERM (alive, just not ours) reading as "dead".
//!   * `serve.json` — the session facts, written atomically (temp + rename) and
//!     ONLY after the server answers its own `GET /api/health`, so its
//!     appearance doubles as the `--background` parent's readiness handshake.
//!
//! Treat `serve.json` as read-only from outside: `serve` owns it, tooling reads it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const lock_name = "serve.lock";
pub const data_name = "serve.json";
pub const log_name = "serve.log";
pub const current_version: u32 = 1;

/// Everything the control verbs and the `--background` parent need to know
/// about a running session. Serialized via `std.json.Stringify` — FIELD ORDER
/// IS DECLARATION ORDER IS THE WIRE CONTRACT; never reorder a shipped field.
///
/// Deltas from the zigapagos original: `zigbase_pid`/`control_port` are dropped
/// (zigapagos supervises a separate zigbase child and runs its own control
/// server; zigbase IS the server, so `pid` is its own pid and its control
/// endpoint is `/api/health` on `port`), and `ephemeral` is added (the shutdown
/// path and `serve stop` must know whether `data_dir` is a tempdir this session
/// owns).
pub const LockFile = struct {
    version: u32 = current_version,
    pid: i64,
    /// The session's `--http-host`. Every control verb dials `probeHost(host)`,
    /// never a hardcoded loopback — a session on a non-default host is just as
    /// reachable, and a wildcard bind is not dialable at all.
    host: []const u8,
    port: u16,
    url: []const u8,
    data_dir: []const u8,
    background: bool,
    ephemeral: bool,
    started_at: []const u8,
};

/// The held session lock. Contract 3 (caller-buffer): allocates nothing; owns
/// only the open file whose flock is the liveness signal. Held for the process
/// lifetime in production; `release` exists for tests and for the explicit
/// teardown ordering in `serveImpl`.
pub const Lock = struct {
    file: Io.File,

    pub fn release(l: *Lock, io: Io) void {
        l.file.close(io); // closing the fd drops the flock
    }
};

/// The three genuinely different outcomes of trying to claim a data dir.
///
/// These were once one `?Lock`, and collapsing the last two is what made
/// `zigbase serve` tell an operator with a read-only data dir that "another
/// zigbase serve session already owns" it — then recommend `serve status`,
/// `serve stop`, and `--ignore-lock`, none of which address a permissions
/// problem. A wrong diagnosis with confident remedies costs more than no
/// diagnosis, so the caller is now forced to tell them apart.
pub const AcquireResult = union(enum) {
    /// The flock is ours. The caller owns the `Lock` and must release it.
    acquired: Lock,
    /// A LIVE process holds the flock (`EWOULDBLOCK`). The data dir really is
    /// in use, and the session verbs are the right advice.
    held,
    /// The lock file could not be opened or created at all — a read-only
    /// mount, an unwritable dir, a stray directory in the way. NOT a busy data
    /// dir: no session exists to inspect or stop.
    unavailable: anyerror,
};

/// Open-or-create `serve.lock` and take the exclusive, non-blocking flock.
/// Contract 1 (self-freeing): the joined path is scratch, freed before return.
pub fn acquire(io: Io, data_dir_abs: []const u8, gpa: Allocator) error{OutOfMemory}!AcquireResult {
    // No background sessions on Windows. Reported as `.unavailable` rather
    // than `.held` for the same reason as any other open failure: there is no
    // session here to stop.
    if (builtin.os.tag == .windows) return .{ .unavailable = error.SessionsUnsupportedOnWindows };
    const path = try std.fs.path.join(gpa, &.{ data_dir_abs, lock_name });
    defer gpa.free(path);
    // `.truncate = false`: the file is create-once and permanent (see `remove`),
    // and truncating it would be a pointless write on every start.
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err|
        return .{ .unavailable = err };
    if (std.c.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        f.close(io);
        return .held;
    }
    return .{ .acquired = .{ .file = f } };
}

/// True when a live process holds the session flock. Contract 1.
pub fn isLive(io: Io, gpa: Allocator, data_dir_abs: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const path = std.fs.path.join(gpa, &.{ data_dir_abs, lock_name }) catch return false;
    defer gpa.free(path);
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    if (std.c.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) return true;
    _ = std.c.flock(f.handle, std.posix.LOCK.UN);
    return false;
}

/// Parse `serve.json`. `null` on missing/corrupt/version-mismatch — a broken
/// lockfile must read as "no session", never crash a control verb.
///
/// Contract 4 (arena-scoped): the returned strings point into `arena`; nothing
/// here frees. Callers pass an arena they already own.
pub fn read(arena: Allocator, io: Io, data_dir_abs: []const u8) ?LockFile {
    const path = std.fs.path.join(arena, &.{ data_dir_abs, data_name }) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const lf = std.json.parseFromSliceLeaky(LockFile, arena, bytes, .{}) catch return null;
    if (lf.version != current_version) return null;
    return lf;
}

/// Atomically publish `serve.json` (temp file + rename), so a concurrent reader
/// sees the whole old file or the whole new one, never a torn write.
/// Contract 1 (self-freeing).
pub fn write(io: Io, gpa: Allocator, data_dir_abs: []const u8, lf: LockFile) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(lf, .{ .whitespace = .indent_2 }, &aw.writer);

    const path = try std.fs.path.join(gpa, &.{ data_dir_abs, data_name });
    defer gpa.free(path);
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var w = af.file.writer(io, &.{});
    try w.interface.writeAll(aw.writer.buffered());
    try af.replace(io);
}

/// Best-effort removal of `serve.json` (clean shutdown, stale-session sweep).
/// Contract 1.
///
/// Deliberately does NOT unlink `serve.lock`. Unlinking a file another process
/// still holds an `flock` on does not release that lock — it detaches the name
/// from the still-locked inode — so a `create` racing right behind the unlink
/// opens a brand-new inode and takes a SECOND, independent lock on it. Two
/// "live" locks under one name defeats the entire liveness scheme. `serve.lock`
/// is therefore create-once and permanent: an empty file left in the data dir
/// after a session ends is harmless, and `acquire` already handles "file exists,
/// nobody holds it".
pub fn remove(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ data_dir_abs, data_name }) catch return;
    defer gpa.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// `YYYY-MM-DDTHH:MM:SSZ` from UTC epoch seconds. Contract 3 (caller-buffer).
pub fn formatIso(buf: *[20]u8, epoch_secs: u64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Map an unspecified bind address to the loopback a client can actually dial;
/// pass anything else through verbatim. A session started with
/// `--http-host 0.0.0.0` legitimately LISTENS on every interface, but nothing
/// can CONNECT "to" an unspecified address — the OS also answers on loopback,
/// which is what the health probe, the printed URL, and every control verb need.
/// A specific non-loopback host (a LAN IP) passes through: it IS dialable.
/// Contract 3 (caller-buffer): allocates nothing; returns a literal or a slice
/// of the input.
pub fn probeHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "[::]")) return "127.0.0.1";
    return host;
}

test "serve session: iso timestamp formatting" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIso(&buf, 0));
    // 1786106096 == 2026-08-07T12:34:56Z (`date -u -d @1786106096`).
    try std.testing.expectEqualStrings("2026-08-07T12:34:56Z", formatIso(&buf, 1786106096));
}

test "serve session: write/read round-trip; corrupt and future-version read as absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    // A page-backed arena, NOT an arena over std.testing.allocator: `read` is
    // contract 4 (it never frees), and wrapping the testing allocator would
    // disable Zig's leak detector for this whole test and trip
    // scripts/check-allocator-contracts.sh.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(read(arena, io, dir_abs) == null); // nothing written yet

    try write(io, gpa, dir_abs, .{
        .pid = 1234,
        .host = "127.0.0.1",
        .port = 8090,
        .url = "http://127.0.0.1:8090",
        .data_dir = dir_abs,
        .background = true,
        .ephemeral = false,
        .started_at = "2026-08-07T12:34:56Z",
    });
    const lf = read(arena, io, dir_abs) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1234), lf.pid);
    try std.testing.expectEqualStrings("127.0.0.1", lf.host);
    try std.testing.expectEqual(@as(u16, 8090), lf.port);
    try std.testing.expectEqualStrings("http://127.0.0.1:8090", lf.url);
    try std.testing.expect(lf.background);
    try std.testing.expect(!lf.ephemeral);

    // Corrupt content parses as absent, never as a crash: a broken lockfile
    // must read as "no session" to every control verb.
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data = "{not json" });
    try std.testing.expect(read(arena, io, dir_abs) == null);

    // A future/unknown version is absent too (forward compatibility).
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data =
        \\{"version":999,"pid":1,"host":"h","port":1,"url":"u","data_dir":"d",
        \\ "background":false,"ephemeral":false,"started_at":"s"}
    });
    try std.testing.expect(read(arena, io, dir_abs) == null);
}

test "serve session: remove deletes serve.json only, never serve.lock, and is idempotent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    try write(io, gpa, dir_abs, .{
        .pid = 1,
        .host = "127.0.0.1",
        .port = 1,
        .url = "u",
        .data_dir = dir_abs,
        .background = false,
        .ephemeral = false,
        .started_at = "s",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = "" });

    remove(io, gpa, dir_abs);
    // serve.json is gone...
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, data_name, .{}));
    // ...and serve.lock survives. Unlinking a file another process still holds
    // an flock on does NOT release that lock; it detaches the name, letting a
    // racing `create` take a SECOND independent lock on a new inode of the same
    // name. Two "live" locks under one name defeats the whole liveness scheme.
    _ = try tmp.dir.statFile(io, lock_name, .{});
    remove(io, gpa, dir_abs); // idempotent
    _ = try tmp.dir.statFile(io, lock_name, .{});
}

test "serve session: flock liveness — held reads live, released reads stale" {
    // flock(2) locks belong to the OPEN FILE DESCRIPTION, so two independent
    // opens in ONE process conflict exactly as two processes do. No child
    // process is needed to test this.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    try std.testing.expect(!isLive(io, gpa, dir_abs)); // no lock file at all

    var lock = switch (try acquire(io, dir_abs, gpa)) {
        .acquired => |l| l,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(isLive(io, gpa, dir_abs));
    // A second acquire is refused as HELD — specifically not `.unavailable`,
    // which is the whole point of the distinction.
    try std.testing.expect((try acquire(io, dir_abs, gpa)) == .held);

    lock.release(io);
    try std.testing.expect(!isLive(io, gpa, dir_abs));
    // The file itself outlives the lock, and re-acquiring it works.
    var again = switch (try acquire(io, dir_abs, gpa)) {
        .acquired => |l| l,
        else => return error.TestUnexpectedResult,
    };
    again.release(io);
}

test "serve session: an unopenable lock file is .unavailable, never .held" {
    // THE distinction this type exists for. A data dir we cannot create the
    // lock file in (read-only mount, wrong owner, a stray directory in the
    // way) used to be indistinguishable from "another session owns this dir",
    // so the CLI told operators to run `serve stop` against a session that did
    // not exist while the real cause — permissions — went unmentioned.
    //
    // The obstruction here is a DIRECTORY named `serve.lock` rather than a
    // chmod: `createFile` fails deterministically on it for every user
    // INCLUDING root, whereas a 0500 parent dir is silently writable by root
    // and would make this test pass vacuously in a container.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    const blocker = try std.fs.path.join(gpa, &.{ dir_abs, lock_name });
    defer gpa.free(blocker);
    try Io.Dir.cwd().createDirPath(io, blocker);

    const res = try acquire(io, dir_abs, gpa);
    try std.testing.expect(res == .unavailable);
    // `isLive` must not report a phantom session for the same directory.
    try std.testing.expect(!isLive(io, gpa, dir_abs));
}

test "serve session: probeHost maps unspecified binds to loopback, passes everything else through" {
    // A session bound to an unspecified address listens everywhere but cannot
    // be DIALED there; loopback is where the OS also answers, and that is what
    // every control verb and every printed URL actually needs.
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("0.0.0.0"));
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("::"));
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("[::]"));
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("127.0.0.1"));
    try std.testing.expectEqualStrings("192.168.1.5", probeHost("192.168.1.5"));
}
