//! Control plane for `zigbase serve` — agent-environment detection, the
//! background-mode decision, session classification, and (Tasks 5-7) the
//! `--background` parent plus the `stop`/`status`/`logs` verbs.
//!
//! Ported from zigapagos's `src/cli/dev_control.zig` per program decision #8.
//! Consumer documentation: docs/serve.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const serve_session = @import("serve_session.zig");
const clock = @import("clock.zig");

/// Internal recursion guard: set on the background CHILD so it runs the plain
/// foreground path. Deliberately a DIFFERENT variable from the user-facing
/// opt-out below — conflating the two (as Astro does) means opting out of
/// auto-backgrounding corrupts the child's own `background` lockfile field.
pub const background_child_env = "ZIGBASE_SERVE_BACKGROUND_CHILD";
/// User-facing: "1" forces background mode; any other value — including empty,
/// so an exported-but-unset shell var does not silently enable this — disables
/// agent auto-detection.
pub const background_optout_env = "ZIGBASE_SERVE_BACKGROUND";

/// Agent-environment sniff, ported from am-i-vibing's AGENT-type table: env-var
/// checks ONLY, no process-ancestry sniffing, and no hybrid/interactive entries
/// (a Warp-the-terminal false positive was Astro's first post-release fix for
/// this feature). Deliberately conservative — heuristics keying on PAGER
/// rewrites alone, and ambient platform vars that are set for HUMAN users too,
/// are excluded. Contract 3 (caller-buffer): allocates nothing; returns a
/// literal.
pub fn detectAgent(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    const simple = [_]struct { env: []const u8, provider: []const u8 }{
        .{ .env = "CLAUDECODE", .provider = "Claude Code" },
        .{ .env = "CODEX_THREAD_ID", .provider = "OpenAI Codex" },
        .{ .env = "GEMINI_CLI", .provider = "Gemini CLI" },
        .{ .env = "CODEIUM_EDITOR_APP_ROOT", .provider = "Windsurf" },
        .{ .env = "AIDER_API_KEY", .provider = "Aider" },
        .{ .env = "OZ_RUN_ID", .provider = "Warp agent" },
        .{ .env = "AMP_CURRENT_THREAD_ID", .provider = "Amp" },
        .{ .env = "AUGMENT_AGENT", .provider = "Auggie" },
        .{ .env = "QWEN_CODE", .provider = "Qwen Code" },
        .{ .env = "ANTIGRAVITY_AGENT", .provider = "Antigravity" },
        .{ .env = "PI_CODING_AGENT", .provider = "Pi" },
        .{ .env = "OPENCODE", .provider = "OpenCode" },
        .{ .env = "CRUSH", .provider = "Crush" },
    };
    for (simple) |s| {
        if (environ_map.get(s.env)) |v| if (v.len != 0) return s.provider;
    }
    // Cursor agent = trace id AND the agent-mode PAGER rewrite; the trace id
    // alone is the interactive terminal.
    if (environ_map.get("CURSOR_TRACE_ID") != null) {
        if (environ_map.get("PAGER")) |p|
            if (std.mem.eql(u8, p, "head -n 10000 | cat")) return "Cursor agent";
    }
    // The emerging generic convention (Crush and Amp set these alongside their own).
    if (environ_map.get("AGENT")) |v| if (v.len != 0) return "agent (AGENT env)";
    if (environ_map.get("AI_AGENT")) |v| if (v.len != 0) return "agent (AI_AGENT env)";
    return null;
}

/// Whether to run backgrounded, and — only when that answer came from
/// `detectAgent` rather than a flag or env override — which provider was
/// detected, so the caller can print attribution. Whenever
/// `detected_provider != null`, `background` is true; the converse does not hold.
pub const BackgroundDecision = struct { background: bool, detected_provider: ?[]const u8 };

/// Pure background-mode decision — no I/O. See this file's five-level
/// precedence, pinned by the test above. Contract 3 (caller-buffer).
pub fn decideBackground(
    explicit_background: bool,
    is_bg_child: bool,
    ignore_lock: bool,
    environ_map: *const std.process.Environ.Map,
) BackgroundDecision {
    if (is_bg_child) return .{ .background = false, .detected_provider = null };
    if (explicit_background) return .{ .background = true, .detected_provider = null };
    if (ignore_lock) return .{ .background = false, .detected_provider = null };
    if (environ_map.get(background_optout_env)) |v| {
        return .{ .background = std.mem.eql(u8, v, "1"), .detected_provider = null };
    }
    if (detectAgent(environ_map)) |provider|
        return .{ .background = true, .detected_provider = provider };
    return .{ .background = false, .detected_provider = null };
}

pub const SessionState = enum { none, starting, running };

/// The three states a control verb can observe, from the two facts every verb
/// already resolves (`serve_session.isLive` + whether `serve_session.read`
/// found parseable facts). A pure function so the truth table has ONE place to
/// be right.
///
/// `.starting` is the real race window: the flock is acquired BEFORE the server
/// boots, and `serve.json` appears only after the readiness handshake. A live
/// flock with no readable facts is a session mid-boot, not "nothing running".
pub fn classifySession(live: bool, has_facts: bool) SessionState {
    if (!live) return .none;
    return if (has_facts) .running else .starting;
}

/// Drop the flags that must not recurse into the background child: the child
/// runs the plain foreground path (guarded by `background_child_env`), and
/// `--force` was already consumed by the parent. Everything else is copied
/// verbatim — notably `--ephemeral`, which the child still needs so it knows it
/// owns the tempdir the parent created (Task 7), and the `--data-dir` /
/// `--http-port` the parent resolved for it.
///
/// Contract 1: the caller frees the returned slice; the strings are borrowed
/// from `raw_args`.
pub fn filterBackgroundArgs(gpa: Allocator, raw_args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--background")) continue;
        if (std.mem.eql(u8, arg, "--force")) continue;
        try out.append(gpa, arg);
    }
    return out.toOwnedSlice(gpa);
}

pub const status_json_none = "{\"running\":false,\"starting\":false}\n";
pub const status_json_starting = "{\"running\":false,\"starting\":true}\n";

/// Shared explanation for `.starting`: the flock is live but `serve.json` has
/// not appeared, so the holder's pid is unknowable (`flock(2)` has no
/// owner-query API). This is a session between `openSession` and its readiness
/// handshake, not "no session". Shared between `--background --force` (which
/// must fail rather than pretend to stop something it cannot even signal) and
/// the standalone `serve stop` verb.
pub const stop_starting_detail =
    "a serve session holds the lock but has not finished starting (no serve.json " ++
    "yet) — retry in a few seconds, or find and kill the process manually\n";

/// Write to stdout and flush. The verbs route their PRIMARY payload (the human
/// answer, the JSON object, the log content) through here so
/// `zigbase serve status --json | jq .` and `zigbase serve logs | grep` have
/// something to read; every diagnostic stays on stderr via std.debug.print.
///
/// Streaming, not positional: under `cmd >f 2>&1` both fds share one open file
/// description, and a positional flush from offset zero would stomp whatever
/// stderr already committed there.
fn writeStdout(io: Io, bytes: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}

/// `serve status --json` body. Field order = the contract. Contract 2 (owned
/// result): the caller frees the returned slice.
fn renderStatusJson(gpa: Allocator, lf: serve_session.LockFile, healthy: bool) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    std.json.Stringify.value(.{
        .running = true,
        .starting = false,
        .pid = lf.pid,
        .host = lf.host,
        .port = lf.port,
        .url = lf.url,
        .data_dir = lf.data_dir,
        .background = lf.background,
        .ephemeral = lf.ephemeral,
        .started_at = lf.started_at,
        .healthy = healthy,
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeAll("\n") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Human `serve status` output. Contract 2 (owned result): the caller frees
/// the returned slice.
fn renderStatusText(gpa: Allocator, lf: serve_session.LockFile, healthy: bool) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.print("zigbase serving at {s} (pid {d}{s}{s})\n", .{
        lf.url,
        lf.pid,
        if (lf.background) ", background" else "",
        if (lf.ephemeral) ", ephemeral" else "",
    }) catch return error.OutOfMemory;
    w.print("  started:  {s}\n", .{lf.started_at}) catch return error.OutOfMemory;
    w.print("  data dir: {s}\n", .{lf.data_dir}) catch return error.OutOfMemory;
    if (healthy) {
        w.print("  health:   ok\n", .{}) catch return error.OutOfMemory;
    } else {
        // Degrade, never fail: a session mid-boot or mid-shutdown is a real
        // state, not a reason to claim nothing is running.
        w.print("  health:   not answering /api/health at {s}\n", .{lf.url}) catch return error.OutOfMemory;
    }
    w.print("  logs:     zigbase serve logs --data-dir {s}\n", .{lf.data_dir}) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub const StopResult = enum { stopped, none, starting };

/// Classify a signal-0 (existence-only) probe. `ProcessNotFound` and
/// `PermissionDenied` come back as errors but mean opposite things: NotFound is
/// "gone, nothing to clean up"; PermissionDenied means a DIFFERENT process now
/// holds that pid (reuse) and must never be touched. `Unexpected` folds into
/// `.gone` — "nothing to clean up" is the safe default for a failure mode we do
/// not understand, and it never leads to killing something we are unsure about.
fn probeAlive(pid: std.posix.pid_t) enum { alive, gone, not_ours } {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => .gone,
        error.PermissionDenied => .not_ours,
        error.Unexpected => .gone,
    };
    return .alive;
}

/// The whole stop path: TERM the session pid, poll the FLOCK (not the pid — it
/// drops the instant the process dies, with no zombie or PID-reuse ambiguity)
/// for up to 5s, escalate to KILL, then sweep. Contract 1.
pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) StopResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = serve_session.read(arena_state.allocator(), io, data_dir_abs);
    const live = serve_session.isLive(io, gpa, data_dir_abs);

    if (!live) {
        // Nobody holds the lock. A serve.json left behind is a `kill -9`'d
        // session: sweep it (and check for an orphan still on the port).
        if (lf != null) {
            sweepOrphan(io, gpa, data_dir_abs);
            return .stopped;
        }
        return .none;
    }

    var pid: ?i64 = if (lf) |l| l.pid else null;
    if (pid == null) {
        // Live flock, no facts: a session between openSession and its readiness
        // handshake (a cold boot with migrations is a multi-second window).
        // Poll rather than assume — force-unwrapping here is the panic this
        // path exists to avoid. The loop also exits the moment the lock drops.
        var waited_ms: u64 = 0;
        var still_live = true;
        while (pid == null and still_live and waited_ms < 5000) {
            io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};
            waited_ms += 200;
            var poll_state = std.heap.ArenaAllocator.init(gpa);
            defer poll_state.deinit();
            if (serve_session.read(poll_state.allocator(), io, data_dir_abs)) |l| pid = l.pid;
            still_live = serve_session.isLive(io, gpa, data_dir_abs);
        }
        if (pid == null) return if (still_live) .starting else .none;
    }

    const target: std.posix.pid_t = @intCast(pid.?);
    std.posix.kill(target, .TERM) catch {};
    var waited_ms: u64 = 0;
    while (waited_ms < 5000 and serve_session.isLive(io, gpa, data_dir_abs)) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        waited_ms += 100;
    }
    if (serve_session.isLive(io, gpa, data_dir_abs)) {
        std.debug.print("serve stop: no response to SIGTERM after 5s — escalating to SIGKILL\n", .{});
        std.posix.kill(target, .KILL) catch {};
        waited_ms = 0;
        while (waited_ms < 2000 and serve_session.isLive(io, gpa, data_dir_abs)) {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            waited_ms += 100;
        }
    }
    sweepOrphan(io, gpa, data_dir_abs);
    return .stopped;
}

/// Clean up after a session whose lock is no longer held: remove `serve.json`
/// (never `serve.lock`), delete an ephemeral tempdir this session owned, and —
/// only if the recorded pid is still alive AND still answers OUR
/// `/api/health` — terminate it. No health match means we will NOT kill it:
/// with PID reuse, killing an innocent process is strictly worse than leaving a
/// squatter, and the message says so. Contract 1.
pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = serve_session.read(arena_state.allocator(), io, data_dir_abs);
    defer serve_session.remove(io, gpa, data_dir_abs);
    const l = lf orelse return;
    if (l.pid <= 0) return;
    const target: std.posix.pid_t = @intCast(l.pid);

    switch (probeAlive(target)) {
        .gone => {
            if (l.ephemeral) removeEphemeralDir(io, l.data_dir);
            return;
        },
        .not_ours => return warnNotOurs(l.pid),
        .alive => {},
    }
    if (!probeHealth(io, gpa, l.host, l.port)) {
        // Alive but not answering: most likely mid-shutdown after our own TERM.
        // Grace-poll before concluding anything — this path must stay silent on
        // a normal stop, not print a PID-reuse warning at every teardown.
        var waited: u64 = 0;
        while (waited < 2000) : (waited += 100) {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            switch (probeAlive(target)) {
                .gone => {
                    if (l.ephemeral) removeEphemeralDir(io, l.data_dir);
                    return;
                },
                .not_ours => return warnNotOurs(l.pid),
                .alive => {},
            }
        }
        if (!probeHealth(io, gpa, l.host, l.port)) {
            std.debug.print(
                "serve stop: pid {d} is alive but port {d} does not answer /api/health — " ++
                    "NOT killing it (the pid may have been reused). If a zigbase is stuck, " ++
                    "'pkill zigbase' remains the manual recovery.\n",
                .{ l.pid, l.port },
            );
            return;
        }
    }

    std.debug.print("serve stop: reaping an orphaned zigbase (pid {d})\n", .{l.pid});
    std.posix.kill(target, .TERM) catch return;
    var waited: u64 = 0;
    while (waited < 2000) : (waited += 100) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        switch (probeAlive(target)) {
            .gone => {
                if (l.ephemeral) removeEphemeralDir(io, l.data_dir);
                return;
            },
            .not_ours => return, // the pid now belongs to someone else
            .alive => {},
        }
    }
    std.posix.kill(target, .KILL) catch {};
    if (l.ephemeral) removeEphemeralDir(io, l.data_dir);
}

fn warnNotOurs(pid: i64) void {
    std.debug.print(
        "serve stop: pid {d} exists but is not ours (permission denied) — NOT killing it " ++
            "(the pid may have been reused).\n",
        .{pid},
    );
}

/// Prefix every ephemeral data dir carries, so `removeEphemeralDir` can refuse
/// any path that does not look like one it created. Task 7 uses the same
/// constant to build the name — one source of truth for both the create and
/// the delete side.
pub const ephemeral_prefix = "zigbase-ephemeral-";

/// Delete a tempdir an ephemeral session owned. Refuses any path that does not
/// contain our own prefix, so a mis-parsed lockfile can never make `serve stop`
/// delete a real data directory. Contract 1.
///
/// `pub`: called from `framework.zig`'s `.serve` arm (Task 7) as well as
/// `sweepOrphan` above — one spelling, one visibility, no churn commit later.
pub fn removeEphemeralDir(io: Io, dir_abs: []const u8) void {
    if (std.mem.indexOf(u8, dir_abs, ephemeral_prefix) == null) {
        std.debug.print("serve: refusing to delete '{s}': it does not look like an ephemeral data dir\n", .{dir_abs});
        return;
    }
    Io.Dir.cwd().deleteTree(io, dir_abs) catch |e|
        std.debug.print("serve: could not delete the ephemeral data dir '{s}': {s}\n", .{ dir_abs, @errorName(e) });
}

/// Create a fresh temp data dir. The name pins BOTH the pid and 8 random hex
/// chars: the random half alone would collide under `ZIGBASE_FAKE_SEED` (dev
/// builds seed the entropy source deterministically), and `createDirPath`
/// succeeds on an existing directory, so two ephemeral servers could otherwise
/// silently share one SQLite file. Contract 2: the caller owns the returned
/// path and is responsible for `removeEphemeralDir`.
pub fn makeEphemeralDir(io: Io, gpa: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const base = environ.get("TMPDIR") orelse "/tmp";
    // genHex's `len` is the number of HEX CHARACTERS, not bytes (src/crypto.zig).
    const suffix = try @import("crypto.zig").genHex(io, gpa, 8);
    defer gpa.free(suffix);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}{d}-{s}", .{
        base, ephemeral_prefix, std.c.getpid(), suffix,
    });
    errdefer gpa.free(path);
    try Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// Ask the OS for a free port by binding port 0 and reading back what it
/// assigned, then releasing it.
///
/// This is inherently a TOCTOU window: another process can take the port
/// between the release here and the server's own bind. That is accepted and
/// bounded, not ignored — the loser is the server's `listen()`, which fails at
/// boot, which the `--background` parent reports with a log tail (and a
/// foreground run prints outright). Holding the socket open until the server
/// binds is not possible across the re-exec, and retry-on-collision would
/// re-open the same window one layer up.
pub fn pickFreePort(io: Io, host: []const u8) !u16 {
    const addr = try std.Io.net.IpAddress.parse(serve_session.probeHost(host), 0);
    var srv = try addr.listen(io, .{ .mode = .stream });
    defer srv.deinit(io);
    return srv.socket.address.getPort();
}

/// Named (not anonymous) so call sites can spell the type. Deliberately a
/// separate enum from `cli.ServeControlVerb`: this file must not depend on the
/// argv parser, and `serveControlImpl` maps between them in one place.
pub const Verb = enum { stop, status, logs };

pub fn runVerb(
    io: Io,
    gpa: Allocator,
    verb: Verb,
    data_dir_abs: []const u8,
    json: bool,
    follow: bool,
) noreturn {
    if (builtin.os.tag == .windows) {
        std.debug.print("error: `zigbase serve {s}` is not supported on Windows (use the official Docker image)\n", .{@tagName(verb)});
        std.process.exit(1);
    }
    switch (verb) {
        .status => statusVerb(io, gpa, data_dir_abs, json),
        .stop => stopVerb(io, gpa, data_dir_abs),
        .logs => logsVerb(io, gpa, data_dir_abs, json, follow),
    }
}

fn statusVerb(io: Io, gpa: Allocator, data_dir_abs: []const u8, json: bool) noreturn {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // ONE snapshot read each: `status` never polls or blocks. It reports what it
    // sees right now, even mid-startup, and lets the caller retry.
    const live = serve_session.isLive(io, gpa, data_dir_abs);
    const lf = serve_session.read(arena_state.allocator(), io, data_dir_abs);
    switch (classifySession(live, lf != null)) {
        .none => {
            // Only reachable when !live, so a non-null lf here is a lockfile a
            // dead session left behind — safe to sweep.
            if (lf) |l| {
                serve_session.remove(io, gpa, data_dir_abs);
                // An ephemeral session that was `kill -9`'d never ran its own
                // cleanup, so its tempdir is still on disk. docs/serve.md
                // promises the next `serve stop` OR `serve status` against that
                // data dir sweeps it, and `stop` already did — this is `status`
                // keeping the same promise.
                //
                // Deliberately NOT `sweepOrphan`, which is what `stop` uses:
                // that polls for up to 2s and can SIGNAL a live pid, and
                // `status` is contractually a non-blocking snapshot that never
                // polls. A status command that can kill a server would be a
                // worse defect than the leak it fixes. The prefix guard inside
                // `removeEphemeralDir` is what keeps this safe on a corrupted
                // lockfile.
                if (l.ephemeral) removeEphemeralDir(io, l.data_dir);
            }
            writeStdout(io, if (json) status_json_none else "No zigbase serve session is running.\n");
            std.process.exit(1);
        },
        .starting => {
            writeStdout(io, if (json)
                status_json_starting
            else
                "A serve session is starting (lock held, serve.json not yet published) — retry in a few seconds.\n");
            std.process.exit(1);
        },
        .running => {},
    }
    const healthy = probeHealth(io, gpa, lf.?.host, lf.?.port);
    const out = (if (json)
        renderStatusJson(gpa, lf.?, healthy)
    else
        renderStatusText(gpa, lf.?, healthy)) catch std.process.exit(1);
    defer gpa.free(out);
    writeStdout(io, out);
    std.process.exit(0);
}

fn stopVerb(io: Io, gpa: Allocator, data_dir_abs: []const u8) noreturn {
    switch (stopInstance(io, gpa, data_dir_abs)) {
        // Idempotent: both "stopped it" and "there was nothing to stop" are success.
        .stopped => {
            std.debug.print("Stopped.\n", .{});
            std.process.exit(0);
        },
        .none => {
            std.debug.print("No zigbase serve session is running.\n", .{});
            std.process.exit(0);
        },
        // NOT the idempotent case: a session genuinely holds the lock and
        // nothing was stopped.
        .starting => {
            std.debug.print("serve stop: " ++ stop_starting_detail, .{});
            std.process.exit(1);
        },
    }
}

/// True when a log line is a self-contained JSON object, i.e. one NDJSON
/// record. Deliberately a SHAPE test (`{` … `}`), not a full parse: this runs
/// per line on a tailed file and only needs to separate the server's own
/// structured records from the foreign plain-text lines interleaved with them.
/// A malformed line that merely looks like an object is the consumer's problem
/// to reject, exactly as it would be reading the file directly — dropping it
/// here would silently hide a real encoder bug.
fn isJsonRecord(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r\n");
    return t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}';
}

/// Write only the NDJSON records from `bytes`, dropping every foreign line.
/// Returns whether anything at all was written, so the caller can tell the
/// difference between "filtered a mixed stream" and "there was nothing to
/// filter" — the latter is worth a diagnostic, since it almost always means
/// the session was not started with `--log-format json`. Contract 3.
fn writeStdoutJsonOnly(io: Io, bytes: []const u8) bool {
    var wrote = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (!isJsonRecord(line)) continue;
        writeStdout(io, line);
        writeStdout(io, "\n");
        wrote = true;
    }
    return wrote;
}

fn logsVerb(io: Io, gpa: Allocator, data_dir_abs: []const u8, json: bool, follow: bool) noreturn {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = serve_session.read(arena_state.allocator(), io, data_dir_abs);
    const live = serve_session.isLive(io, gpa, data_dir_abs);
    if (live and lf != null and !lf.?.background) {
        std.debug.print(
            "error: serve logs: this session runs in the FOREGROUND — its output is in the " ++
                "terminal that started it (only --background sessions write {s}).\n",
            .{serve_session.log_name},
        );
        std.process.exit(1);
    }

    const log_path = std.fs.path.join(gpa, &.{ data_dir_abs, serve_session.log_name }) catch std.process.exit(1);
    const contents = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("error: serve logs: {s} exceeds the 16 MiB read cap — read it directly (tail -f {s})\n", .{ log_path, log_path });
        } else {
            std.debug.print("error: serve logs: no log file at {s} (was a background session ever started?)\n", .{log_path});
        }
        std.process.exit(1);
    };
    if (json) {
        // <data-dir>/serve.log is a MIXED stream even when the server is
        // configured for JSON logging: facil.io writes its own banner
        // ("INFO: Listening on port ...", "* Root pid: ...") straight to the
        // fd from C, never through the Zig log encoder. `serve logs --json`
        // exists precisely to drop those, so `serve logs --json | jq` works on
        // a real log file instead of dying on the first banner line.
        if (!writeStdoutJsonOnly(io, contents) and contents.len > 0) {
            std.debug.print(
                "serve logs --json: {s} contains no JSON records — was this session started " ++
                    "with --log-format json (or ZIGBASE_LOG_FORMAT=json)? Re-run without --json " ++
                    "to read it as text.\n",
                .{log_path},
            );
        }
    } else {
        writeStdout(io, contents);
    }
    var offset: usize = contents.len;
    gpa.free(contents);
    if (!follow) std.process.exit(0);

    // Poll-tail: stat-and-read the delta every 200ms; exit once the session's
    // lock is no longer held. Boring and portable — no fs-events machinery for
    // a dev-log tail.
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        const now = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch break;
        defer gpa.free(now);
        if (now.len > offset) {
            const delta = now[offset..];
            if (json) _ = writeStdoutJsonOnly(io, delta) else writeStdout(io, delta);
            offset = now.len;
        } else if (now.len < offset) {
            // Truncated (a --force restart): dump the fresh file from the top.
            if (json) _ = writeStdoutJsonOnly(io, now) else writeStdout(io, now);
            offset = now.len;
        }
        if (!serve_session.isLive(io, gpa, data_dir_abs)) break;
    }
    std.process.exit(0);
}

/// Bounded tail of a file, for failure diagnostics. Contract 1.
fn printLogTail(io: Io, gpa: Allocator, log_path: []const u8) void {
    const contents = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch return;
    defer gpa.free(contents);
    const tail = contents[contents.len -| 4096..];
    if (tail.len > 0) std.debug.print("--- last {d} bytes of {s} ---\n{s}\n", .{ tail.len, log_path, tail });
}

/// Check `serve.json` for `child_pid`; on a match print the ready summary and
/// exit 0 (never returning). Otherwise return plainly — a missing lockfile and
/// one naming a different pid are the same "not ready yet" fact.
///
/// `ephemeral` comes from the PARENT's own `sa.ephemeral` — never read back off
/// the child's lockfile — because the parent must print JSON precisely because
/// *the parent* was asked for an ephemeral server; making the output shape
/// depend on the child agreeing would let a mismatched child silently change
/// what the caller of `serve --background --ephemeral` gets on stdout.
///
/// Contract 1 (self-freeing): the read is arena-scoped and the print happens
/// INSIDE that scope, before the arena — and the LockFile strings that point
/// into it — is freed.
fn checkBackgroundReady(
    io: Io,
    gpa: Allocator,
    data_dir_abs: []const u8,
    child_pid: std.posix.pid_t,
    log_path: []const u8,
    ephemeral: bool,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = serve_session.read(arena_state.allocator(), io, data_dir_abs) orelse return;
    if (lf.pid != @as(i64, child_pid)) return;
    if (ephemeral) {
        // The parent owns stdout here; the child's stdout went to the log file.
        printEphemeralJsonFromLockFile(io, lf);
    } else {
        std.debug.print(
            "serve: running in the background at {s} (pid {d})\n" ++
                "serve: admin UI: {s}/_/\n" ++
                "serve: log file: {s}\n" ++
                "serve: manage:   zigbase serve stop | status [--json] | logs [--follow]\n",
            .{ lf.url, lf.pid, lf.url, log_path },
        );
    }
    std.process.exit(0);
}

/// The background child died (or became unobservable) before publishing
/// `serve.json`: report it and exit 1. Never returns.
///
/// `owned_ephemeral_dir`: non-null only when THIS `--background` parent
/// itself allocated (or otherwise owns, per the `ephemeral_prefix` trust
/// boundary `sweepOrphan`/the `.serve` arm use) the tempdir the child was
/// given — see `background`'s doc comment. Both call sites reach this
/// function only after `waitpid` has already confirmed the child is dead (or
/// reaped out from under us, which is the same fact for our purposes), so
/// deleting here is safe immediately — unlike the 30s-timeout path in
/// `background`, which sends the TERM itself and must wait a bounded window
/// for the child to actually die first. The log tail is read BEFORE the
/// delete: the log file lives inside the dir being removed.
fn failBackgroundStartup(io: Io, gpa: Allocator, log_path: []const u8, owned_ephemeral_dir: ?[]const u8) noreturn {
    std.debug.print("error: serve: the background server exited before becoming ready\n", .{});
    printLogTail(io, gpa, log_path);
    if (owned_ephemeral_dir) |d| removeEphemeralDir(io, d);
    std.process.exit(1);
}

/// The `--background` parent: spawn the child detached (own process group,
/// stdio to `<data-dir>/serve.log`), wait for `serve.json` to appear bearing
/// the child's pid, print the summary, exit 0. NEVER RETURNS; every exit path
/// is a `std.process.exit` so the exit code is exact and stderr carries no Zig
/// error trace — the code IS the contract here (see docs/serve.md).
///
/// `owned_ephemeral_dir`: pass the tempdir path when THIS process (not the
/// child) allocated it — i.e. the caller's own `ephemeral_dir` from the
/// `.serve` arm's composition-rule resolution — or `null` otherwise (no
/// `--ephemeral`, or a real user `--data-dir` was given alongside it). This
/// process only ever reaches `openSession`/`serveImpl` in the CHILD (it
/// re-execs and exits here), so on the SUCCESS path the dir is left alone —
/// the child, once ready, owns deleting it on its own graceful shutdown, same
/// as any other ephemeral session. On a FAILURE path (the child never became
/// ready, or died before it could), the child does NOT get a chance to run
/// its own cleanup defer, so this process deletes the dir itself before
/// exiting — otherwise a tempdir it alone knows about is orphaned forever
/// (this is a NEW leak surface Task 7 introduced by having the parent
/// allocate eagerly; it is not the same case as an externally `kill -9`'d
/// RUNNING server, which intentionally is NOT garbage-collected — see
/// `docs/serve.md`'s cleanup semantics #3). Passing a real user `--data-dir`
/// here would be a bug: never derive this from `sa.ephemeral` alone.
///
/// Deliberately untested at the unit level: it forks a process. Its decision
/// logic lives in `decideBackground`/`classifySession` (unit-tested above);
/// its end-to-end behavior is covered in Task 11.
///
/// Why `waitpid(WNOHANG)` and not `kill(pid, 0)`: this process does not reap
/// its child, so a child that exits becomes a zombie — and a zombie still
/// answers `kill(pid, 0)` successfully. Polling with signal 0 would therefore
/// never notice a dead child and would stall for the whole 30s. `std.posix` has
/// no `waitpid` in Zig 0.16.0; `Io.Threaded`'s own `childWaitPosix` reaps
/// through `std.c.waitpid`, so this mirrors the standard library's own idiom
/// rather than inventing one. Three outcomes, not two: `0` means still running;
/// `child_pid` means it just exited (fail); `-1` is an ERROR (almost certainly
/// `ECHILD` — something reaped the child out from under us), which is NOT the
/// same fact as "still running" and must not be treated as `0`.
pub fn background(
    io: Io,
    gpa: Allocator,
    sa: anytype,
    data_dir_abs: []const u8,
    owned_ephemeral_dir: ?[]const u8,
    raw_args: []const []const u8,
    environ_map: *std.process.Environ.Map,
) noreturn {
    if (builtin.os.tag == .windows) {
        std.debug.print("error: serve --background is not supported on Windows (use the official Docker image)\n", .{});
        std.process.exit(1);
    }

    // Fast-feedback idempotency: a live session means "already running". The
    // child re-checks under its own flock, so a race here is caught
    // authoritatively there.
    if (serve_session.isLive(io, gpa, data_dir_abs)) {
        if (sa.force) {
            switch (stopInstance(io, gpa, data_dir_abs)) {
                .stopped, .none => {},
                // Nothing was actually stopped: the flock is held by a session
                // still starting, whose pid we cannot even determine. Spawning
                // anyway would just lose the same race after paying for a spawn
                // and most of the 30s wait. Fail now, truthfully.
                .starting => {
                    std.debug.print("error: serve: " ++ stop_starting_detail, .{});
                    std.process.exit(1);
                },
            }
        } else {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            if (serve_session.read(arena_state.allocator(), io, data_dir_abs)) |lf| {
                std.debug.print("serve: already running at {s} (pid {d})\n", .{ lf.url, lf.pid });
            } else {
                std.debug.print("serve: already running (session file unreadable — try 'zigbase serve stop')\n", .{});
            }
            std.process.exit(0);
        }
    }

    const log_path = std.fs.path.join(gpa, &.{ data_dir_abs, serve_session.log_name }) catch {
        std.debug.print("error: serve: out of memory\n", .{});
        std.process.exit(1);
    };
    // Truncated at the start of each background session: `serve logs` should
    // show THIS session, not an ever-growing concatenation of every past one.
    const log_file = Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch |err| {
        std.debug.print("error: serve: unable to open the log file '{s}': {s}\n", .{ log_path, @errorName(err) });
        std.process.exit(1);
    };

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const self_path = std.process.executablePathAlloc(io, gpa) catch |err| {
        std.debug.print("error: serve: this executable's own path is unavailable ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    argv.append(gpa, self_path) catch std.process.exit(1);
    const filtered = filterBackgroundArgs(gpa, raw_args) catch std.process.exit(1);
    argv.appendSlice(gpa, filtered) catch std.process.exit(1);

    environ_map.put(background_child_env, "1") catch std.process.exit(1);
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ_map,
        .pgid = 0, // its own process group: survives our exit and terminal SIGHUP
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |err| {
        std.debug.print("error: serve: failed to spawn the background server: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const child_pid: std.posix.pid_t = child.id orelse {
        std.debug.print("error: serve: the spawned child has no pid\n", .{});
        std.process.exit(1);
    };

    // Readiness = serve.json appears bearing the child's pid, which the child
    // publishes only after answering its own /api/health (Task 4).
    var waited_ms: u64 = 0;
    while (waited_ms < 30_000) : (waited_ms += 200) {
        io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        checkBackgroundReady(io, gpa, data_dir_abs, child_pid, log_path, sa.ephemeral);

        // See this function's doc comment for waitpid vs kill(pid, 0). `-1`
        // gets ONE more readiness check (readiness can land between the check
        // above and this call) and then fails like a confirmed exit: one
        // spurious failure beats a silent 30s stall on an unobservable child.
        const wp = std.c.waitpid(child_pid, null, std.c.W.NOHANG);
        if (wp == child_pid) {
            failBackgroundStartup(io, gpa, log_path, owned_ephemeral_dir);
        } else if (wp == -1) {
            checkBackgroundReady(io, gpa, data_dir_abs, child_pid, log_path, sa.ephemeral);
            failBackgroundStartup(io, gpa, log_path, owned_ephemeral_dir);
        }
    }

    // Timeout. `-child_pid` targets the child's whole process group (it leads
    // its own); pid_t is already signed, so plain negation needs no cast.
    std.debug.print("error: serve: the background server did not become ready within 30s\n", .{});
    std.posix.kill(-child_pid, .TERM) catch {};
    // Unlike `failBackgroundStartup`'s call sites (where `waitpid` has already
    // confirmed the child is dead), the child here was alive a moment ago —
    // give it a bounded window to actually exit and release its open
    // SQLite/log files before deleting the dir out from under it. Best-effort,
    // not a hard requirement (POSIX permits unlinking files still open
    // elsewhere), mirroring the same TERM-then-poll pattern `stopInstance`/
    // `sweepOrphan` already use; if it hasn't died by the end of the window we
    // still proceed, matching `sweepOrphan`'s own KILL-then-delete-anyway
    // precedent above.
    var reap_waited_ms: u64 = 0;
    while (reap_waited_ms < 2000) : (reap_waited_ms += 100) {
        if (std.c.waitpid(child_pid, null, std.c.W.NOHANG) != 0) break;
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    serve_session.remove(io, gpa, data_dir_abs);
    // The log file lives inside the dir about to be deleted — read its tail
    // BEFORE removing it, or the diagnostic this function exists to print is
    // gone.
    printLogTail(io, gpa, log_path);
    if (owned_ephemeral_dir) |d| removeEphemeralDir(io, d);
    std.process.exit(1);
}

/// How long the verifier waits for the server's own `/api/health` to answer
/// before giving up and running the session untracked. Comfortably inside the
/// `--background` parent's 30s deadline, so a stuck boot is reported by the
/// parent (with a log tail) rather than by a silent unpublished lockfile.
const health_wait_ms: u64 = 20_000;
const health_poll_ms: u64 = 100;

pub const SessionArgs = struct {
    data_dir_abs: []const u8,
    host: []const u8,
    port: u16,
    background: bool,
    ephemeral: bool,
};

/// A tracked serve session: the held flock plus the facts published once the
/// server answers itself. Lives on `serveImpl`'s frame for the whole run.
///
/// Contract 2 (owned result): `shutdown` releases the lock and frees `url`.
/// `data_dir_abs`/`host` are BORROWED from the caller's config and are not freed.
pub const Session = struct {
    lock: serve_session.Lock,
    io: Io,
    gpa: Allocator,
    data_dir_abs: []const u8,
    host: []const u8,
    port: u16,
    url: []const u8,
    background: bool,
    ephemeral: bool,
    started_at: [20]u8,

    pub fn onListening(ctx: *anyopaque) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        s.spawnVerifier();
    }

    /// Hand a self-contained copy of the facts to a DETACHED thread, then
    /// return so the reactor can start.
    fn spawnVerifier(s: *Session) void {
        const v = Verifier.create(s) catch |e| {
            std.log.err("serve: could not start the readiness verifier: {s} — session tracking is off for this run", .{@errorName(e)});
            return;
        };
        const t = std.Thread.spawn(.{}, Verifier.run, .{v}) catch |e| {
            v.destroy();
            std.log.err("serve: could not spawn the readiness verifier: {s} — session tracking is off for this run", .{@errorName(e)});
            return;
        };
        t.detach();
    }

    pub fn shutdown(s: *Session) void {
        serve_session.remove(s.io, s.gpa, s.data_dir_abs);
        s.lock.release(s.io);
        s.gpa.free(s.url);
    }
};

/// The outcome of claiming a data dir for this process, mirroring
/// `serve_session.AcquireResult` one layer up. `.held` and `.unavailable` are
/// deliberately NOT collapsed into one "failed" case: they need different
/// messages and different remedies (see AcquireResult's doc comment).
pub const OpenResult = union(enum) {
    opened: Session,
    /// A live session already owns this data dir.
    held,
    /// The lock file itself could not be created — permissions, a read-only
    /// mount, an obstruction. No session exists here.
    unavailable: anyerror,
};

/// Acquire the flock and assemble a `Session`. Contract 2 via `Session.shutdown`.
pub fn openSession(io: Io, gpa: Allocator, args: SessionArgs) error{OutOfMemory}!OpenResult {
    const lock = switch (try serve_session.acquire(io, args.data_dir_abs, gpa)) {
        .acquired => |l| l,
        .held => return .held,
        .unavailable => |e| return .{ .unavailable = e },
    };
    var s: Session = .{
        .lock = lock,
        .io = io,
        .gpa = gpa,
        .data_dir_abs = args.data_dir_abs,
        .host = args.host,
        .port = args.port,
        .url = undefined,
        .background = args.background,
        .ephemeral = args.ephemeral,
        .started_at = undefined,
    };
    // clock.nowUnix, not std.time.timestamp (no longer exists in 0.16's std): the framework
    // clock honors the test's frozen-clock override, and every other wall-clock read in this
    // codebase routes through it.
    _ = serve_session.formatIso(&s.started_at, @intCast(clock.nowUnix(io)));
    s.url = std.fmt.allocPrint(gpa, "http://{s}:{d}", .{
        serve_session.probeHost(args.host), args.port,
    }) catch |e| {
        // The lock is already held; drop it before propagating, or a failed
        // start would leave this data dir permanently "owned" by a dead process
        // path. (It would in fact clear on exit — the kernel drops the flock —
        // but releasing explicitly keeps the failure path readable.)
        var l = lock;
        l.release(io);
        return e;
    };
    return .{ .opened = s };
}

/// The facts the verifier thread needs, and nothing else.
///
/// Contract 1 relative to its own allocations, with a deliberate allocator
/// choice: `std.heap.page_allocator`, NOT the app's gpa. The thread is DETACHED
/// and may still be polling when a short-lived server is stopped, so it must
/// borrow nothing from `serveImpl`'s frame and must not free into an allocator
/// that `main` may already have torn down. page_allocator is process-lifetime
/// and thread-safe; the few hundred bytes here are freed by the thread itself.
const Verifier = struct {
    io: Io,
    data_dir_abs: []u8,
    host: []u8,
    url: []u8,
    port: u16,
    pid: i64,
    background: bool,
    ephemeral: bool,
    started_at: [20]u8,

    fn create(s: *const Session) !*Verifier {
        const pa = std.heap.page_allocator;
        const v = try pa.create(Verifier);
        errdefer pa.destroy(v);
        const dd = try pa.dupe(u8, s.data_dir_abs);
        errdefer pa.free(dd);
        const h = try pa.dupe(u8, s.host);
        errdefer pa.free(h);
        const u = try pa.dupe(u8, s.url);
        v.* = .{
            .io = s.io,
            .data_dir_abs = dd,
            .host = h,
            .url = u,
            .port = s.port,
            // std.c.getpid(), not std.os.linux.getpid(): zigbase links libc
            // unconditionally (vendored SQLite), and this spelling resolves on
            // both Linux and Darwin.
            .pid = @intCast(std.c.getpid()),
            .background = s.background,
            .ephemeral = s.ephemeral,
            .started_at = s.started_at,
        };
        return v;
    }

    fn destroy(v: *Verifier) void {
        const pa = std.heap.page_allocator;
        pa.free(v.data_dir_abs);
        pa.free(v.host);
        pa.free(v.url);
        pa.destroy(v);
    }

    fn run(v: *Verifier) void {
        defer v.destroy();
        const pa = std.heap.page_allocator;
        var waited_ms: u64 = 0;
        while (waited_ms < health_wait_ms) : (waited_ms += health_poll_ms) {
            v.io.sleep(std.Io.Duration.fromMilliseconds(health_poll_ms), .awake) catch {};
            if (!probeHealth(v.io, pa, v.host, v.port)) continue;
            // The server answered. NOW publish — this is the whole handshake.
            serve_session.write(v.io, pa, v.data_dir_abs, .{
                .pid = v.pid,
                .host = v.host,
                .port = v.port,
                .url = v.url,
                .data_dir = v.data_dir_abs,
                .background = v.background,
                .ephemeral = v.ephemeral,
                .started_at = &v.started_at,
            }) catch |e| {
                std.log.err("serve: the server is up but publishing {s}/{s} failed: {s} — 'zigbase serve status/stop' will not find this session", .{ v.data_dir_abs, serve_session.data_name, @errorName(e) });
                return;
            };
            if (v.ephemeral) printEphemeralJson(v.io, v);
            return;
        }
        std.log.err("serve: the server did not answer GET /api/health within {d}s — session tracking is off for this run ('zigbase serve status' will report nothing)", .{health_wait_ms / 1000});
    }
};

/// One bounded HTTP GET: connect, send, strip headers, return the body. A
/// deliberately tiny client rather than `http_client.zig` — this runs on a
/// detached thread with a page allocator and must not reach into app state.
/// Contract 1: caller frees.
pub fn fetchBody(io: Io, gpa: Allocator, address: std.Io.net.IpAddress, path: []const u8) ![]u8 {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.print(
        "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\nconnection: close\r\n\r\n",
        .{ path, address.getPort() },
    );
    try writer.interface.flush();

    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(gpa);
    while (all.items.len < 64 * 1024) {
        const chunk = reader.interface.peekGreedy(1) catch break;
        try all.appendSlice(gpa, chunk);
        reader.interface.toss(chunk.len);
    }
    const split = std.mem.indexOf(u8, all.items, "\r\n\r\n") orelse return error.MalformedResponse;
    return gpa.dupe(u8, all.items[split + 4 ..]);
}

/// True iff `GET /api/health` answers with a `"status"` field — the endpoint the
/// stock binary has served since v0.12.0. Dials `probeHost(host)`, never a
/// hardcoded loopback. Contract 1.
pub fn probeHealth(io: Io, gpa: Allocator, host: []const u8, port: u16) bool {
    const addr = std.Io.net.IpAddress.parse(serve_session.probeHost(host), port) catch return false;
    const body = fetchBody(io, gpa, addr, "/api/health") catch return false;
    defer gpa.free(body);
    return std.mem.indexOf(u8, body, "\"status\"") != null;
}

/// The single JSON object a `--ephemeral` session prints on stdout when it is
/// ready: `{"url","port","data_dir","pid"}` — field order is the contract.
/// Streaming writer (not positional): under `cmd >f 2>&1` both fds share one
/// open file description, and a positional flush from offset zero would stomp
/// whatever stderr already committed there.
fn printEphemeralJson(io: Io, v: *const Verifier) void {
    var buf: [1024]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &buf);
    std.json.Stringify.value(.{
        .url = v.url,
        .port = v.port,
        .data_dir = v.data_dir_abs,
        .pid = v.pid,
    }, .{}, &fw.interface) catch return;
    fw.interface.writeAll("\n") catch return;
    fw.interface.flush() catch return;
}

/// The `--background --ephemeral` counterpart to `printEphemeralJson`: same
/// four-field object, built from a `LockFile` (the PARENT reads this off the
/// child's published `serve.json`) rather than a `Verifier` (which only exists
/// inside the child that owns the readiness handshake). The parent's own
/// stdout is free — the child's went to the log file — so the parent, not the
/// child, is the one that must print it.
fn printEphemeralJsonFromLockFile(io: Io, lf: serve_session.LockFile) void {
    var buf: [1024]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &buf);
    std.json.Stringify.value(.{
        .url = lf.url,
        .port = lf.port,
        .data_dir = lf.data_dir,
        .pid = lf.pid,
    }, .{}, &fw.interface) catch return;
    fw.interface.writeAll("\n") catch return;
    fw.interface.flush() catch return;
}

test "serve control: agent detection recognizes agent env vars, never hybrids, never empty values" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    try std.testing.expect(detectAgent(&env) == null); // clean environment

    try env.put("CLAUDECODE", "1");
    try std.testing.expectEqualStrings("Claude Code", detectAgent(&env).?);
    _ = env.swapRemove("CLAUDECODE");

    // An EMPTY value never counts: an exported-but-unset shell variable is not
    // a signal.
    try env.put("GEMINI_CLI", "");
    try std.testing.expect(detectAgent(&env) == null);
    try env.put("GEMINI_CLI", "1");
    try std.testing.expectEqualStrings("Gemini CLI", detectAgent(&env).?);
    _ = env.swapRemove("GEMINI_CLI");

    // Cursor: the trace id ALONE is the interactive terminal, not an agent
    // (Astro's Warp false-positive lesson). Only with the agent-mode PAGER
    // rewrite does it count.
    try env.put("CURSOR_TRACE_ID", "abc");
    try std.testing.expect(detectAgent(&env) == null);
    try env.put("PAGER", "head -n 10000 | cat");
    try std.testing.expectEqualStrings("Cursor agent", detectAgent(&env).?);
    _ = env.swapRemove("CURSOR_TRACE_ID");
    _ = env.swapRemove("PAGER");

    try env.put("CODEX_THREAD_ID", "t1");
    try std.testing.expectEqualStrings("OpenAI Codex", detectAgent(&env).?);
    _ = env.swapRemove("CODEX_THREAD_ID");

    try env.put("AI_AGENT", "crush");
    try std.testing.expectEqualStrings("agent (AI_AGENT env)", detectAgent(&env).?);
}

test "serve control: decideBackground applies the five-level precedence" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    // Level 1: the recursion guard beats everything, including --background.
    try env.put(background_child_env, "1");
    try env.put("CLAUDECODE", "1");
    try env.put(background_optout_env, "1");
    {
        const d = decideBackground(true, true, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    _ = env.swapRemove(background_child_env);
    _ = env.swapRemove(background_optout_env);
    _ = env.swapRemove("CLAUDECODE");

    // Level 2: explicit --background wins, with NO provider attribution.
    {
        const d = decideBackground(true, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expect(d.detected_provider == null);
    }

    // Level 3: --ignore-lock suppresses auto-detection entirely.
    try env.put("CLAUDECODE", "1");
    {
        const d = decideBackground(false, false, true, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }

    // Level 4: the opt-out env beats detection, in both directions.
    try env.put(background_optout_env, "0");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(!d.background); // CLAUDECODE is set, but "0" wins
        try std.testing.expect(d.detected_provider == null);
    }
    try env.put(background_optout_env, "1");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expect(d.detected_provider == null); // an override is not a detection
    }
    _ = env.swapRemove(background_optout_env);

    // Level 5: detection decides, and only here is a provider attributed.
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expectEqualStrings("Claude Code", d.detected_provider.?);
    }
    // An EMPTY detection var is not a detection.
    try env.put("CLAUDECODE", "");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }
}

test "serve control: classifySession covers all four live/has-facts combinations" {
    try std.testing.expectEqual(SessionState.none, classifySession(false, false));
    // A lockfile that survived a `kill -9` is still "nothing running" — the
    // caller sweeps it.
    try std.testing.expectEqual(SessionState.none, classifySession(false, true));
    // THE case worth naming: the flock is held but serve.json has not been
    // published yet (the window between `acquire` and the readiness handshake).
    // Reporting this as "not running" would be flatly wrong.
    try std.testing.expectEqual(SessionState.starting, classifySession(true, false));
    try std.testing.expectEqual(SessionState.running, classifySession(true, true));
}

test "serve control: background argv filter drops the mode flags it already consumed" {
    const gpa = std.testing.allocator;
    const filtered = try filterBackgroundArgs(gpa, &.{
        "serve", "--background", "--http-port", "9000", "--force", "--insecure-cookies",
    });
    defer gpa.free(filtered);
    try std.testing.expectEqual(@as(usize, 4), filtered.len);
    try std.testing.expectEqualStrings("serve", filtered[0]);
    try std.testing.expectEqualStrings("--http-port", filtered[1]);
    try std.testing.expectEqualStrings("9000", filtered[2]);
    try std.testing.expectEqualStrings("--insecure-cookies", filtered[3]);
}

test "serve control: background argv filter keeps --ephemeral and every unrelated flag" {
    const gpa = std.testing.allocator;
    const filtered = try filterBackgroundArgs(gpa, &.{
        "serve", "--ephemeral", "--background", "--data-dir", "/tmp/x", "--http-port", "1",
    });
    defer gpa.free(filtered);
    try std.testing.expectEqual(@as(usize, 6), filtered.len);
    try std.testing.expectEqualStrings("serve", filtered[0]);
    try std.testing.expectEqualStrings("--ephemeral", filtered[1]);
    try std.testing.expectEqualStrings("--data-dir", filtered[2]);
    try std.testing.expectEqualStrings("/tmp/x", filtered[3]);
    try std.testing.expectEqualStrings("--http-port", filtered[4]);
    try std.testing.expectEqualStrings("1", filtered[5]);
}

test "serve control: openSession refuses a data dir another live session owns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    const args: SessionArgs = .{
        .data_dir_abs = dir_abs,
        .host = "127.0.0.1",
        .port = 8090,
        .background = false,
        .ephemeral = false,
    };
    var first = switch (try openSession(io, gpa, args)) {
        .opened => |s| s,
        else => return error.TestUnexpectedResult,
    };
    // A second acquire against the SAME live flock is refused as HELD — not as
    // `.unavailable`, which would send an operator after a permissions problem
    // that does not exist. (flock lives on the open file description, so one
    // process can prove this.)
    try std.testing.expect((try openSession(io, gpa, args)) == .held);
    first.shutdown();
    // Once released, the data dir is claimable again.
    var again = switch (try openSession(io, gpa, args)) {
        .opened => |s| s,
        else => return error.TestUnexpectedResult,
    };
    again.shutdown();
}

test "serve control: a session's shutdown removes serve.json but never serve.lock" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    var s = switch (try openSession(io, gpa, .{
        .data_dir_abs = dir_abs,
        .host = "127.0.0.1",
        .port = 8090,
        .background = true,
        .ephemeral = false,
    })) {
        .opened => |sess| sess,
        else => return error.TestUnexpectedResult,
    };

    // Publishing is the verifier's job in production; call the same write here
    // so shutdown has something to clean up.
    try serve_session.write(io, gpa, dir_abs, .{
        .pid = 4242,
        .host = s.host,
        .port = s.port,
        .url = s.url,
        .data_dir = dir_abs,
        .background = true,
        .ephemeral = false,
        .started_at = &s.started_at,
    });
    _ = try tmp.dir.statFile(io, serve_session.data_name, .{});

    s.shutdown();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, serve_session.data_name, .{}));
    _ = try tmp.dir.statFile(io, serve_session.lock_name, .{}); // permanent, by design
}

test "serve control: probeHealth is false for a port nothing listens on" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Bind and immediately release a port, then probe it: nothing is listening,
    // so the probe must return false rather than hang or error out.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .mode = .stream });
    const port = srv.socket.address.getPort();
    srv.deinit(io);
    try std.testing.expect(!probeHealth(io, gpa, "127.0.0.1", port));
}

test "serve control: renderStatusJson emits both state keys and the lockfile facts" {
    const gpa = std.testing.allocator;
    const lf: serve_session.LockFile = .{
        .pid = 4242,
        .host = "127.0.0.1",
        .port = 8090,
        .url = "http://127.0.0.1:8090",
        .data_dir = "/abs/zb",
        .background = true,
        .ephemeral = false,
        .started_at = "2026-08-08T12:34:56Z",
    };
    const json = try renderStatusJson(gpa, lf, true);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"running\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"starting\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pid\":4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"healthy\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ephemeral\":false") != null);
    // Exactly one object, one trailing newline, nothing else.
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '\n'), json[json.len - 1]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 2]);

    const unhealthy = try renderStatusJson(gpa, lf, false);
    defer gpa.free(unhealthy);
    try std.testing.expect(std.mem.indexOf(u8, unhealthy, "\"healthy\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, unhealthy, "\"running\":true") != null);
}

test "serve control: the negative status objects are stable and machine-readable" {
    try std.testing.expectEqualStrings("{\"running\":false,\"starting\":false}\n", status_json_none);
    try std.testing.expectEqualStrings("{\"running\":false,\"starting\":true}\n", status_json_starting);
}

test "serve control: renderStatusText names the url, pid, mode, and health" {
    const gpa = std.testing.allocator;
    const lf: serve_session.LockFile = .{
        .pid = 4242,
        .host = "0.0.0.0",
        .port = 8090,
        .url = "http://127.0.0.1:8090",
        .data_dir = "/abs/zb",
        .background = true,
        .ephemeral = true,
        .started_at = "2026-08-08T12:34:56Z",
    };
    const text = try renderStatusText(gpa, lf, true);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "http://127.0.0.1:8090") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pid 4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "background") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ephemeral") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/abs/zb") != null);

    const degraded = try renderStatusText(gpa, lf, false);
    defer gpa.free(degraded);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "not answering /api/health") != null);
}

test "serve control: stopInstance reports .starting for a live flock with no facts yet" {
    // Simulates the window between openSession and the readiness handshake:
    // the flock is held, serve.json has not been published. Force-unwrapping
    // the (null) read here is exactly the panic zigapagos shipped and fixed.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    var lock = switch (try serve_session.acquire(io, dir_abs, gpa)) {
        .acquired => |l| l,
        else => return error.TestUnexpectedResult,
    };
    defer lock.release(io);
    try std.testing.expectEqual(StopResult.starting, stopInstance(io, gpa, dir_abs));
}

test "serve control: makeEphemeralDir creates a fresh, prefixed, writable dir under TMPDIR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("TMPDIR", base);

    const a = try makeEphemeralDir(io, gpa, &env);
    defer gpa.free(a);
    const b = try makeEphemeralDir(io, gpa, &env);
    defer gpa.free(b);

    try std.testing.expect(std.mem.indexOf(u8, a, ephemeral_prefix) != null);
    try std.testing.expect(std.mem.startsWith(u8, a, base));
    // Two calls never collide (the pid pins one half, random hex the other).
    try std.testing.expect(!std.mem.eql(u8, a, b));
    // It exists and is writable.
    const probe_path = try std.fs.path.join(gpa, &.{ a, "probe" });
    defer gpa.free(probe_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = probe_path,
        .data = "x",
    });

    std.Io.Dir.cwd().deleteTree(io, a) catch {};
    std.Io.Dir.cwd().deleteTree(io, b) catch {};
}

test "serve control: pickFreePort returns a port that is actually bindable" {
    const io = std.testing.io;
    const port = try pickFreePort(io, "127.0.0.1");
    try std.testing.expect(port != 0);
    // The port is free right now: binding it must succeed.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var srv = try addr.listen(io, .{ .mode = .stream });
    srv.deinit(io);
}

test "serve control: removeEphemeralDir refuses a path without the ephemeral prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    // A real-looking data dir must survive: a corrupted lockfile must never be
    // able to turn `serve stop` into an rm -rf of someone's database.
    const decoy = try std.fs.path.join(gpa, &.{ base, "zb_data" });
    defer gpa.free(decoy);
    try std.Io.Dir.cwd().createDirPath(io, decoy);
    removeEphemeralDir(io, decoy);
    _ = try std.Io.Dir.cwd().statFile(io, decoy, .{});
}

test "serve control: stopInstance is a no-op on an untouched dir and sweeps a stale one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    // Nothing at all: idempotent no-op.
    try std.testing.expectEqual(StopResult.none, stopInstance(io, gpa, dir_abs));

    // A serve.json left behind by a `kill -9`'d session, with nobody holding
    // the lock: swept, and reported as stopped (something WAS cleaned up).
    try serve_session.write(io, gpa, dir_abs, .{
        // pid 0 is never a real process here, so the orphan probe stays inert
        // and this test asserts the sweep, not signal delivery.
        .pid = 0,
        .host = "127.0.0.1",
        .port = 1,
        .url = "u",
        .data_dir = dir_abs,
        .background = true,
        .ephemeral = false,
        .started_at = "s",
    });
    try std.testing.expectEqual(StopResult.stopped, stopInstance(io, gpa, dir_abs));
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    try std.testing.expect(serve_session.read(arena_state.allocator(), io, dir_abs) == null);
}
