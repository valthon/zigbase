const std = @import("std");
const logging = @import("logging.zig");

pub const ServeArgs = struct {
    http_host: ?[]const u8 = null,
    http_port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    serve_static: ?[]const u8 = null,
    static_cache_control: ?[]const u8 = null,
    // Secure-by-default opt-outs / opt-ins (F8/F12). null = leave the config default.
    insecure_cookies: bool = false, // --insecure-cookies => cookie_secure=false (plain-HTTP local dev)
    trust_proxy: bool = false, // --trust-proxy => honor X-Forwarded-For/X-Real-IP
    realtime_origins: ?[]const u8 = null, // --realtime-origins CSV => allowed WS Origins
    sse_heartbeat_seconds: ?u16 = null, // --sse-heartbeat-seconds N => SSE ping interval (0 = inherit listener timeout)
    realtime_outbound_hwm: ?u32 = null, // --realtime-outbound-hwm N => slow-consumer disconnect bound in frames (0 disables); issue #203
    // Logging knobs (serve only; the env vars ZIGBASE_LOG_FORMAT/LEVEL/REQUESTS apply
    // to every subcommand — see docs/observability.md). null = leave the config default.
    log_format: ?[]const u8 = null, // --log-format text|json
    log_level: ?[]const u8 = null, // --log-level debug|info|warn|error
    log_requests: ?bool = null, // --no-request-log => false
    /// Detach: re-exec self in its own process group, wait for readiness, exit 0.
    background: bool = false,
    /// Tempdir data dir + random free port; print one JSON object when ready.
    ephemeral: bool = false,
    /// Start an UNTRACKED instance: take no flock, write no serve.json.
    ignore_lock: bool = false,
    /// --background only: stop an existing session first instead of being idempotent.
    force: bool = false,
};

pub const ServeControlVerb = enum { stop, status, logs };

pub const ServeControlArgs = struct {
    verb: ServeControlVerb,
    data_dir: ?[]const u8 = null,
    /// `status` only.
    json: bool = false,
    /// `logs` only.
    follow: bool = false,
};

pub const DoctorArgs = struct {
    data_dir: ?[]const u8 = null,
    /// Escalate severities for a production deployment.
    production: bool = false,
    /// NDJSON findings on stdout + one summary object.
    json: bool = false,
};

/// `migrate` runs one of four actions: `apply` (the default — apply pending system + consumer
/// migrations), `status` (`migrate status` — read the ledger and report applied/pending/orphaned
/// consumer migrations without changing anything), `rollback` (`migrate rollback [N]` — reverse
/// the N most-recently-applied consumer migrations, newest first; N defaults to 1), or `dump`
/// (`migrate dump [--out <file>]` — introspect the LIVE database and write a canonical, dialect-native
/// `structure.sql` for inspection/diffing/test-setup; NOT a schema source, never loaded at boot).
pub const MigrateAction = enum { apply, status, rollback, dump };

pub const MigrateArgs = struct {
    data_dir: ?[]const u8 = null,
    action: MigrateAction = .apply,
    /// Number of consumer migrations to reverse for `.rollback` (positional; default 1). Ignored by
    /// the other actions.
    rollback_count: usize = 1,
    /// Output path for `.dump` (`--out <path>`). `null` = write to stdout. Ignored by the other actions.
    out: ?[]const u8 = null,
    /// `--json` (status only, SP-1): emit one JSON object instead of the text report. An
    /// unknown flag for every other action, mirroring how `--out` is gated to `.dump`.
    json: bool = false,
};

pub const SuperuserArgs = struct {
    data_dir: ?[]const u8 = null,
    email: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const RewrapArgs = struct {
    data_dir: ?[]const u8 = null,
    /// --dry-run: report what would change without writing anything.
    dry_run: bool = false,
};

/// `migrate-db`: copy an existing SQLite instance into a PostgreSQL target (issue #159).
pub const MigrateDbArgs = struct {
    /// Source SQLite `data.db` path (required).
    from: ?[]const u8 = null,
    /// Target `postgres://…` connection URL (required).
    to: ?[]const u8 = null,
    /// Overwrite a target that already contains a ZigBase schema.
    force: bool = false,
};

pub const TypegenArgs = struct {
    data_dir: ?[]const u8 = null,
    url: ?[]const u8 = null,
    out: ?[]const u8 = null,
    api_prefix: []const u8 = "/api",
    client_name: []const u8 = "ZbClient",
    admin_email: ?[]const u8 = null,
    admin_password: ?[]const u8 = null,
    check: bool = false,
    /// Output language: "ts" (default) or "dart".
    lang: []const u8 = "ts",
    /// Kotlin-only: the `package` declaration for the generated file.
    /// Defaults to the dating fixture's namespace (keeps the committed golden
    /// byte-stable); pass --package for a real consumer app.
    package: []const u8 = "io.github.valthon.zigbase.codegen.dating",
};

/// `import`: offline, encryption-aware bulk NDJSON record import (issue #283). Streams a
/// file (or stdin when the path is `-`) through the record engine into an existing collection.
pub const ImportArgs = struct {
    data_dir: ?[]const u8 = null,
    /// Target collection (required).
    collection: ?[]const u8 = null,
    /// Optional upsert-by-field: match each row on this field, UPDATE if present else create.
    upsert_key: ?[]const u8 = null,
    /// Rows per transaction (default 500; must be >= 1).
    batch_size: usize = 500,
    /// Positional NDJSON file path (required); `-` reads stdin.
    file: ?[]const u8 = null,
};

/// `explain-code [CODE] [--json]`: print the long form for one frozen error code,
/// or list every registered code when CODE is omitted.
pub const ExplainCodeArgs = struct {
    code: ?[]const u8 = null,
    json: bool = false,
};

/// `version [--json]`: print build provenance (SP-1). `--json` emits one JSON object
/// instead of the text report.
pub const VersionArgs = struct {
    json: bool = false,
};

/// Identifies which command a per-command `--help` request targets.
pub const HelpTopic = enum { top, serve, serve_control, migrate, superuser_create, typegen, rewrap, migrate_db, vapid_keygen, import, explain_code, doctor };

pub const Command = union(enum) {
    /// `help`/`--help`/`-h`/no-args -> top-level usage; `<cmd> --help` -> that command's usage.
    help: HelpTopic,
    /// `version`/`--version`/`-V` -> print build provenance and exit.
    version: VersionArgs,
    serve: ServeArgs,
    migrate: MigrateArgs,
    superuser_create: SuperuserArgs,
    typegen: TypegenArgs,
    rewrap: RewrapArgs,
    migrate_db: MigrateDbArgs,
    /// `vapid-keygen` -> generate a fresh VAPID (Web Push) keypair, print it, and exit.
    vapid_keygen: void,
    import: ImportArgs,
    explain_code: ExplainCodeArgs,
    /// `serve stop|status|logs` -> manage an existing `serve` session.
    serve_control: ServeControlArgs,
    /// `doctor` -> preflight checks over config/data-dir/schema.
    doctor: DoctorArgs,
};

/// True when an arg is a help flag (`--help` or `-h`).
fn isHelpFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

pub const ParseError = error{ UnknownCommand, UnknownFlag, MissingValue, BadValue, ConflictingFlags };

/// Comptime-derived parser switches. `serve_static` is true only in the default
/// static-files mode — in .disabled/.dir/.embedded the flag is rejected as unknown.
pub const ParseOpts = struct {
    serve_static: bool = true,
    /// --static-cache-control is rejected as unknown when static serving is disabled
    /// at comptime (`.static_files = .disabled`), mirroring the --serve-static gate.
    /// Unlike serve_static it stays available in .dir/.embedded modes (the knob
    /// applies to comptime-configured sources too).
    static_cache_control: bool = true,
};

/// Parse argv (excluding the program name).
pub fn parse(args: []const []const u8, popts: ParseOpts) ParseError!Command {
    if (args.len == 0) return .{ .help = .top };
    if (std.mem.eql(u8, args[0], "help") or isHelpFlag(args[0]))
        return .{ .help = .top };
    if (std.mem.eql(u8, args[0], "version") or
        std.mem.eql(u8, args[0], "--version") or
        std.mem.eql(u8, args[0], "-V"))
    {
        var va = VersionArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            // `version` has no dedicated HelpTopic (it isn't a subcommand with its own
            // usage block), so `--help`/`-h` routes to the general top-level help, same
            // as bare `--help` — additive, not a UnknownFlag exit.
            if (isHelpFlag(args[i])) {
                return .{ .help = .top };
            } else if (std.mem.eql(u8, args[i], "--json")) {
                va.json = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .version = va };
    }
    if (std.mem.eql(u8, args[0], "migrate-db")) {
        var ma = MigrateDbArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .migrate_db };
            } else if (std.mem.eql(u8, a, "--from")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.from = args[i];
            } else if (std.mem.eql(u8, a, "--to")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.to = args[i];
            } else if (std.mem.eql(u8, a, "--force")) {
                ma.force = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate_db = ma };
    }
    if (std.mem.eql(u8, args[0], "migrate")) {
        var ma = MigrateArgs{};
        var i: usize = 1;
        // Optional leading subcommand: `migrate status` or `migrate rollback [N]`. Anything else
        // non-flag is unknown.
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            if (std.mem.eql(u8, args[i], "status")) {
                ma.action = .status;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "rollback")) {
                ma.action = .rollback;
                i += 1;
                // Optional positional N (default 1). A bare integer only — a flag or another
                // non-integer word after `rollback` is not the count.
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    ma.rollback_count = std.fmt.parseInt(usize, args[i], 10) catch return ParseError.BadValue;
                    i += 1;
                }
            } else if (std.mem.eql(u8, args[i], "dump")) {
                ma.action = .dump;
                i += 1;
            } else return ParseError.UnknownCommand;
        }
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .migrate };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.data_dir = args[i];
            } else if (ma.action == .dump and std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.out = args[i];
            } else if (ma.action == .status and std.mem.eql(u8, a, "--json")) {
                ma.json = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate = ma };
    }
    if (std.mem.eql(u8, args[0], "vapid-keygen")) {
        // No flags; `--help`/`-h` routes to its help screen, anything else is unknown.
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) return .{ .help = .vapid_keygen };
            return ParseError.UnknownFlag;
        }
        return .{ .vapid_keygen = {} };
    }
    if (std.mem.eql(u8, args[0], "explain-code")) {
        var ea = ExplainCodeArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .explain_code };
            } else if (std.mem.eql(u8, a, "--json")) {
                ea.json = true;
            } else if (!std.mem.startsWith(u8, a, "-")) {
                // Positional CODE. Only one is allowed.
                if (ea.code != null) return ParseError.BadValue;
                ea.code = a;
            } else return ParseError.UnknownFlag;
        }
        return .{ .explain_code = ea };
    }
    if (std.mem.eql(u8, args[0], "import")) {
        var ia = ImportArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .import };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--collection")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.collection = args[i];
            } else if (std.mem.eql(u8, a, "--upsert-key")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.upsert_key = args[i];
            } else if (std.mem.eql(u8, a, "--batch-size")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.batch_size = std.fmt.parseInt(usize, args[i], 10) catch return ParseError.BadValue;
                if (ia.batch_size == 0) return ParseError.BadValue;
            } else if (std.mem.eql(u8, a, "-") or !std.mem.startsWith(u8, a, "-")) {
                // Positional NDJSON file path (`-` = stdin). Only one is allowed.
                if (ia.file != null) return ParseError.BadValue;
                ia.file = a;
            } else return ParseError.UnknownFlag;
        }
        return .{ .import = ia };
    }
    if (std.mem.eql(u8, args[0], "rewrap")) {
        var ra = RewrapArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .rewrap };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ra.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                ra.dry_run = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .rewrap = ra };
    }
    if (std.mem.eql(u8, args[0], "superuser")) {
        // `superuser --help` / `superuser -h` -> the superuser-create help screen.
        if (args.len >= 2 and isHelpFlag(args[1])) return .{ .help = .superuser_create };
        if (args.len < 2 or !std.mem.eql(u8, args[1], "create")) return ParseError.UnknownCommand;
        var sa = SuperuserArgs{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .superuser_create };
            } else if (std.mem.eql(u8, a, "--email")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.email = args[i];
            } else if (std.mem.eql(u8, a, "--password")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.password = args[i];
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else return ParseError.UnknownFlag;
        }
        return .{ .superuser_create = sa };
    }
    if (std.mem.eql(u8, args[0], "typegen")) {
        var ta = TypegenArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) return .{ .help = .typegen };
            if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--url")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.url = args[i];
            } else if (std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.out = args[i];
            } else if (std.mem.eql(u8, a, "--api-prefix")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.api_prefix = args[i];
            } else if (std.mem.eql(u8, a, "--client-name")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.client_name = args[i];
            } else if (std.mem.eql(u8, a, "--lang")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.lang = args[i];
            } else if (std.mem.eql(u8, a, "--package")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.package = args[i];
            } else if (std.mem.eql(u8, a, "--admin-email")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_email = args[i];
            } else if (std.mem.eql(u8, a, "--admin-password")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_password = args[i];
            } else if (std.mem.eql(u8, a, "--check")) {
                ta.check = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .typegen = ta };
    }
    if (std.mem.eql(u8, args[0], "doctor")) {
        var da = DoctorArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .doctor };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                da.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--production")) {
                da.production = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                da.json = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .doctor = da };
    }
    if (!std.mem.eql(u8, args[0], "serve")) return ParseError.UnknownCommand;

    // Optional leading control verb: `serve stop|status|logs`. Anything else
    // non-flag in that position is not a verb (mirrors `migrate status`).
    if (args.len >= 2 and !std.mem.startsWith(u8, args[1], "-")) {
        const verb: ServeControlVerb =
            if (std.mem.eql(u8, args[1], "stop"))
                .stop
            else if (std.mem.eql(u8, args[1], "status"))
                .status
            else if (std.mem.eql(u8, args[1], "logs"))
                .logs
            else
                return ParseError.UnknownCommand;
        var ca = ServeControlArgs{ .verb = verb };
        var ci: usize = 2;
        while (ci < args.len) : (ci += 1) {
            const a = args[ci];
            if (isHelpFlag(a)) {
                // `-h` is a help flag everywhere in this parser; `-f` is the
                // logs short flag, checked separately below so the two never collide.
                return .{ .help = .serve_control };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                ci += 1;
                if (ci >= args.len) return ParseError.MissingValue;
                ca.data_dir = args[ci];
            } else if ((verb == .status or verb == .logs) and std.mem.eql(u8, a, "--json")) {
                // `status --json`: one JSON object describing the session.
                // `logs --json`: keep only the NDJSON records, dropping the
                // plain-text lines facil.io writes into serve.log from C.
                // Still rejected on `stop`, which has no output to shape.
                ca.json = true;
            } else if (verb == .logs and (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f"))) {
                ca.follow = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .serve_control = ca };
    }

    var sa = ServeArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isHelpFlag(a)) {
            return .{ .help = .serve };
        } else if (std.mem.eql(u8, a, "--http-host")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.http_host = args[i];
        } else if (std.mem.eql(u8, a, "--http-port")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.http_port = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.BadValue;
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.data_dir = args[i];
        } else if (popts.serve_static and std.mem.eql(u8, a, "--serve-static")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.serve_static = args[i];
        } else if (popts.static_cache_control and std.mem.eql(u8, a, "--static-cache-control")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.static_cache_control = args[i];
        } else if (std.mem.eql(u8, a, "--insecure-cookies")) {
            sa.insecure_cookies = true;
        } else if (std.mem.eql(u8, a, "--trust-proxy")) {
            sa.trust_proxy = true;
        } else if (std.mem.eql(u8, a, "--realtime-origins")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.realtime_origins = args[i];
        } else if (std.mem.eql(u8, a, "--sse-heartbeat-seconds")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.sse_heartbeat_seconds = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.BadValue;
        } else if (std.mem.eql(u8, a, "--realtime-outbound-hwm")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.realtime_outbound_hwm = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.BadValue;
        } else if (std.mem.eql(u8, a, "--log-format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (logging.parseFormat(args[i]) == null) return ParseError.BadValue;
            sa.log_format = args[i];
        } else if (std.mem.eql(u8, a, "--log-level")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (logging.parseLevel(args[i]) == null) return ParseError.BadValue;
            sa.log_level = args[i];
        } else if (std.mem.eql(u8, a, "--no-request-log")) {
            sa.log_requests = false;
        } else if (std.mem.eql(u8, a, "--background")) {
            sa.background = true;
        } else if (std.mem.eql(u8, a, "--ephemeral")) {
            sa.ephemeral = true;
        } else if (std.mem.eql(u8, a, "--ignore-lock")) {
            sa.ignore_lock = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            sa.force = true;
        } else {
            return ParseError.UnknownFlag;
        }
    }
    // Checked AFTER the loop so the two flags conflict in either order.
    if (sa.background and sa.ignore_lock) return ParseError.ConflictingFlags;
    return .{ .serve = sa };
}

test "no args -> top-level help" {
    // Use std.meta.activeTag for union-tag comparison; direct `== .help` on a
    // tagged union value does not compile in Zig 0.16.0.
    const cmd = try parse(&.{}, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .help);
    try std.testing.expectEqual(HelpTopic.top, cmd.help);
}

test "serve parses the logging flags; bad values are rejected at parse time" {
    const c = try parse(&.{ "serve", "--log-format", "json", "--log-level", "warn", "--no-request-log" }, .{});
    try std.testing.expectEqualStrings("json", c.serve.log_format.?);
    try std.testing.expectEqualStrings("warn", c.serve.log_level.?);
    try std.testing.expectEqual(@as(?bool, false), c.serve.log_requests);
    // Absent flags stay null so the env/default still wins.
    const bare = try parse(&.{"serve"}, .{});
    try std.testing.expectEqual(@as(?[]const u8, null), bare.serve.log_format);
    try std.testing.expectEqual(@as(?bool, null), bare.serve.log_requests);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--log-format", "ndjson" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--log-level", "trace" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--log-format" }, .{}));
}

test "--help and -h and help -> top-level help" {
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"--help"}, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"-h"}, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"help"}, .{})).help);
}

test "per-command --help routes to that command's help topic" {
    try std.testing.expectEqual(HelpTopic.serve, (try parse(&.{ "serve", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.serve, (try parse(&.{ "serve", "-h" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.migrate, (try parse(&.{ "migrate", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.superuser_create, (try parse(&.{ "superuser", "create", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.superuser_create, (try parse(&.{ "superuser", "--help" }, .{})).help);
}

test "serve with all three flags" {
    const cmd = try parse(&.{ "serve", "--http-host", "127.0.0.1", "--http-port", "9000", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqualStrings("127.0.0.1", cmd.serve.http_host.?);
    try std.testing.expectEqual(@as(u16, 9000), cmd.serve.http_port.?);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.serve.data_dir.?);
}

test "migrate command parses --data-dir (default action = apply)" {
    const cmd = try parse(&.{ "migrate", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqualStrings("/tmp/zb", cmd.migrate.data_dir.?);
    try std.testing.expectEqual(MigrateAction.apply, cmd.migrate.action);
}

test "migrate status parses to the status action (+ optional --data-dir)" {
    const bare = try parse(&.{ "migrate", "status" }, .{});
    try std.testing.expectEqual(MigrateAction.status, bare.migrate.action);
    const with_dir = try parse(&.{ "migrate", "status", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqual(MigrateAction.status, with_dir.migrate.action);
    try std.testing.expectEqualStrings("/tmp/zb", with_dir.migrate.data_dir.?);
}

test "migrate rejects an unknown subcommand and unknown flags" {
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{ "migrate", "bogus" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "--nope" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "status", "--nope" }, .{}));
}

test "migrate rollback parses to the rollback action (default N = 1)" {
    const bare = try parse(&.{ "migrate", "rollback" }, .{});
    try std.testing.expectEqual(MigrateAction.rollback, bare.migrate.action);
    try std.testing.expectEqual(@as(usize, 1), bare.migrate.rollback_count);
}

test "migrate rollback N parses the positional count (+ optional --data-dir)" {
    const three = try parse(&.{ "migrate", "rollback", "3" }, .{});
    try std.testing.expectEqual(MigrateAction.rollback, three.migrate.action);
    try std.testing.expectEqual(@as(usize, 3), three.migrate.rollback_count);
    const with_dir = try parse(&.{ "migrate", "rollback", "2", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqual(@as(usize, 2), with_dir.migrate.rollback_count);
    try std.testing.expectEqualStrings("/tmp/zb", with_dir.migrate.data_dir.?);
}

test "migrate rollback rejects a non-integer or negative count" {
    // Non-integer → BadValue; negative (leading `-`) is treated as a flag → UnknownFlag. Both reject.
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "migrate", "rollback", "abc" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "rollback", "-3" }, .{}));
}

test "migrate dump parses to the dump action (default out = stdout/null)" {
    const bare = try parse(&.{ "migrate", "dump" }, .{});
    try std.testing.expectEqual(MigrateAction.dump, bare.migrate.action);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.migrate.out);
    const with_dir = try parse(&.{ "migrate", "dump", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqual(MigrateAction.dump, with_dir.migrate.action);
    try std.testing.expectEqualStrings("/tmp/zb", with_dir.migrate.data_dir.?);
}

test "migrate dump --out parses the output path" {
    const cmd = try parse(&.{ "migrate", "dump", "--out", "db/structure.sql" }, .{});
    try std.testing.expectEqual(MigrateAction.dump, cmd.migrate.action);
    try std.testing.expectEqualStrings("db/structure.sql", cmd.migrate.out.?);
    // --out combines with --data-dir.
    const both = try parse(&.{ "migrate", "dump", "--out", "s.sql", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqualStrings("s.sql", both.migrate.out.?);
    try std.testing.expectEqualStrings("/tmp/zb", both.migrate.data_dir.?);
}

test "migrate dump rejects unknown flags and a missing --out value" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "dump", "--nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "migrate", "dump", "--out" }, .{}));
    // --out is only valid for `dump`, not for `status`/`apply`.
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "status", "--out", "x" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "--out", "x" }, .{}));
}

test "migrate dump --help routes to the migrate help topic" {
    try std.testing.expectEqual(HelpTopic.migrate, (try parse(&.{ "migrate", "dump", "--help" }, .{})).help);
}

test "migrate rollback --help routes to the migrate help topic" {
    try std.testing.expectEqual(HelpTopic.migrate, (try parse(&.{ "migrate", "rollback", "--help" }, .{})).help);
}

test "migrate status --help routes to the migrate help topic" {
    try std.testing.expectEqual(HelpTopic.migrate, (try parse(&.{ "migrate", "status", "--help" }, .{})).help);
}

test "rewrap parses --data-dir and --dry-run" {
    const cmd = try parse(&.{ "rewrap", "--data-dir", "/tmp/zb", "--dry-run" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .rewrap);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.rewrap.data_dir.?);
    try std.testing.expect(cmd.rewrap.dry_run);
}

test "rewrap --help routes to rewrap help topic" {
    try std.testing.expectEqual(HelpTopic.rewrap, (try parse(&.{ "rewrap", "--help" }, .{})).help);
}

test "rewrap rejects unknown flags" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "rewrap", "--nope" }, .{}));
}

test "migrate-db parses --from/--to/--force" {
    const cmd = try parse(&.{ "migrate-db", "--from", "/tmp/zb/data.db", "--to", "postgres://h/db", "--force" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .migrate_db);
    try std.testing.expectEqualStrings("/tmp/zb/data.db", cmd.migrate_db.from.?);
    try std.testing.expectEqualStrings("postgres://h/db", cmd.migrate_db.to.?);
    try std.testing.expect(cmd.migrate_db.force);
}

test "migrate-db --help routes to its help topic" {
    try std.testing.expectEqual(HelpTopic.migrate_db, (try parse(&.{ "migrate-db", "--help" }, .{})).help);
}

test "migrate-db rejects unknown flags and missing values" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate-db", "--nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "migrate-db", "--from" }, .{}));
}

test "vapid-keygen parses and routes --help to its topic" {
    try std.testing.expectEqual(.vapid_keygen, std.meta.activeTag(try parse(&.{"vapid-keygen"}, .{})));
    try std.testing.expectEqual(HelpTopic.vapid_keygen, (try parse(&.{ "vapid-keygen", "--help" }, .{})).help);
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "vapid-keygen", "--nope" }, .{}));
}

test "import parses positional file + flags" {
    const cmd = try parse(&.{ "import", "--collection", "posts", "--data-dir", "/tmp/zb", "--upsert-key", "slug", "--batch-size", "100", "seed.ndjson" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .import);
    try std.testing.expectEqualStrings("posts", cmd.import.collection.?);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.import.data_dir.?);
    try std.testing.expectEqualStrings("slug", cmd.import.upsert_key.?);
    try std.testing.expectEqual(@as(usize, 100), cmd.import.batch_size);
    try std.testing.expectEqualStrings("seed.ndjson", cmd.import.file.?);
}

test "import default batch size is 500 and file precedes flags" {
    const cmd = try parse(&.{ "import", "data.ndjson", "--collection", "c" }, .{});
    try std.testing.expectEqualStrings("data.ndjson", cmd.import.file.?);
    try std.testing.expectEqual(@as(usize, 500), cmd.import.batch_size);
}

test "import reads stdin via '-'" {
    const cmd = try parse(&.{ "import", "--collection", "c", "-" }, .{});
    try std.testing.expectEqualStrings("-", cmd.import.file.?);
}

test "import --help routes to its help topic" {
    try std.testing.expectEqual(HelpTopic.import, (try parse(&.{ "import", "--help" }, .{})).help);
}

test "import rejects unknown flags, missing values, bad + zero batch size, and a second positional" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "import", "--nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "import", "--collection" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "--batch-size", "abc", "f" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "--batch-size", "0", "f" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "a.ndjson", "b.ndjson" }, .{}));
}

test "unknown command errors" {
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{"frobnicate"}, .{}));
}

test "unknown flag errors" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--nope" }, .{}));
}

test "missing flag value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--http-port" }, .{}));
}

test "non-numeric port errors with BadValue" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--http-port", "abc" }, .{}));
}

test "superuser create parses email and password" {
    const cmd = try parse(&.{ "superuser", "create", "--email", "a@b.c", "--password", "secret123" }, .{});
    try std.testing.expectEqualStrings("a@b.c", cmd.superuser_create.email.?);
    try std.testing.expectEqualStrings("secret123", cmd.superuser_create.password.?);
}

test "serve parses --serve-static when enabled" {
    const cmd = try parse(&.{ "serve", "--serve-static", "public" }, .{});
    try std.testing.expectEqualStrings("public", cmd.serve.serve_static.?);
}

test "serve --sse-heartbeat-seconds parses; bad/missing values rejected" {
    const c = try parse(&.{ "serve", "--sse-heartbeat-seconds", "2" }, .{});
    try std.testing.expectEqual(@as(?u16, 2), c.serve.sse_heartbeat_seconds);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--sse-heartbeat-seconds", "abc" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--sse-heartbeat-seconds" }, .{}));
}

test "serve --realtime-outbound-hwm parses; bad/missing values rejected (issue #203)" {
    const c = try parse(&.{ "serve", "--realtime-outbound-hwm", "16" }, .{});
    try std.testing.expectEqual(@as(?u32, 16), c.serve.realtime_outbound_hwm);
    // 0 is a valid value (disables the bound); not the same as absent (null).
    const z = try parse(&.{ "serve", "--realtime-outbound-hwm", "0" }, .{});
    try std.testing.expectEqual(@as(?u32, 0), z.serve.realtime_outbound_hwm);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--realtime-outbound-hwm", "nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--realtime-outbound-hwm" }, .{}));
}

test "--serve-static is an unknown flag when disabled at comptime" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--serve-static", "public" }, .{ .serve_static = false }));
}

test "--serve-static without a value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--serve-static" }, .{}));
}

test "--static-cache-control parses, requires a value, and is gated by ParseOpts" {
    const c = try parse(&.{ "serve", "--static-cache-control", "public, max-age=86400" }, .{});
    try std.testing.expectEqualStrings("public, max-age=86400", c.serve.static_cache_control.?);
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--static-cache-control" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(
        &.{ "serve", "--static-cache-control", "x" },
        .{ .static_cache_control = false },
    ));
}

test "serve parses the four session-mode flags" {
    const c = try parse(&.{ "serve", "--background", "--ephemeral", "--force" }, .{});
    try std.testing.expect(c.serve.background);
    try std.testing.expect(c.serve.ephemeral);
    try std.testing.expect(c.serve.force);
    try std.testing.expect(!c.serve.ignore_lock);

    const d = try parse(&.{"serve"}, .{});
    try std.testing.expect(!d.serve.background);
    try std.testing.expect(!d.serve.ephemeral);
    try std.testing.expect(!d.serve.force);
    try std.testing.expect(!d.serve.ignore_lock);
}

test "serve --ignore-lock parses alone but conflicts with --background" {
    const c = try parse(&.{ "serve", "--ignore-lock" }, .{});
    try std.testing.expect(c.serve.ignore_lock);
    // An untracked instance writes no lockfile, so --background's readiness
    // handshake would have nothing to poll. Refuse the pair up front.
    try std.testing.expectError(ParseError.ConflictingFlags, parse(&.{ "serve", "--background", "--ignore-lock" }, .{}));
    try std.testing.expectError(ParseError.ConflictingFlags, parse(&.{ "serve", "--ignore-lock", "--background" }, .{}));
}

test "serve stop/status/logs parse to the control verbs" {
    const stop = try parse(&.{ "serve", "stop" }, .{});
    try std.testing.expect(std.meta.activeTag(stop) == .serve_control);
    try std.testing.expectEqual(ServeControlVerb.stop, stop.serve_control.verb);

    const status = try parse(&.{ "serve", "status", "--json", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqual(ServeControlVerb.status, status.serve_control.verb);
    try std.testing.expect(status.serve_control.json);
    try std.testing.expectEqualStrings("/tmp/zb", status.serve_control.data_dir.?);

    const logs = try parse(&.{ "serve", "logs", "--follow" }, .{});
    try std.testing.expectEqual(ServeControlVerb.logs, logs.serve_control.verb);
    try std.testing.expect(logs.serve_control.follow);
    const logs_short = try parse(&.{ "serve", "logs", "-f" }, .{});
    try std.testing.expect(logs_short.serve_control.follow);

    // `logs --json` filters serve.log down to its NDJSON records; it composes
    // with --follow so a tail stays machine-readable too.
    const logs_json = try parse(&.{ "serve", "logs", "--json" }, .{});
    try std.testing.expectEqual(ServeControlVerb.logs, logs_json.serve_control.verb);
    try std.testing.expect(logs_json.serve_control.json);
    try std.testing.expect(!logs_json.serve_control.follow);
    const logs_both = try parse(&.{ "serve", "logs", "--json", "--follow" }, .{});
    try std.testing.expect(logs_both.serve_control.json and logs_both.serve_control.follow);
}

test "serve control verbs reject flags that belong to another verb" {
    // --json shapes OUTPUT, so it is accepted by the two verbs that produce
    // some (status, logs) and rejected by `stop`, which produces none.
    // --follow/-f is logs-only. Silently ignoring a misplaced flag would let a
    // caller believe it took effect.
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "stop", "--json" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "status", "--follow" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "stop", "-f" }, .{}));
    // Server flags are not control-verb flags either.
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "status", "--http-port", "1" }, .{}));
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{ "serve", "bogus" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "status", "--data-dir" }, .{}));
}

test "serve control --help routes to the serve_control help topic" {
    try std.testing.expectEqual(HelpTopic.serve_control, (try parse(&.{ "serve", "status", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.serve_control, (try parse(&.{ "serve", "stop", "-h" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.serve_control, (try parse(&.{ "serve", "logs", "--help" }, .{})).help);
    // A bare `serve --help` still routes to the SERVE topic, not the control one.
    try std.testing.expectEqual(HelpTopic.serve, (try parse(&.{ "serve", "--help" }, .{})).help);
}

test "doctor parses --production/--json/--data-dir and routes --help" {
    const bare = try parse(&.{"doctor"}, .{});
    try std.testing.expect(std.meta.activeTag(bare) == .doctor);
    try std.testing.expect(!bare.doctor.production);
    try std.testing.expect(!bare.doctor.json);

    const full = try parse(&.{ "doctor", "--production", "--json", "--data-dir", "/var/zb" }, .{});
    try std.testing.expect(full.doctor.production);
    try std.testing.expect(full.doctor.json);
    try std.testing.expectEqualStrings("/var/zb", full.doctor.data_dir.?);

    try std.testing.expectEqual(HelpTopic.doctor, (try parse(&.{ "doctor", "--help" }, .{})).help);
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "doctor", "--nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "doctor", "--data-dir" }, .{}));
}

test "parse typegen: data-dir + out + flags" {
    const args = [_][]const u8{ "typegen", "--data-dir", "./zb_data", "--out", "c.ts", "--client-name", "Api", "--check" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expect(cmd == .typegen);
    try std.testing.expectEqualStrings("./zb_data", cmd.typegen.data_dir.?);
    try std.testing.expectEqualStrings("c.ts", cmd.typegen.out.?);
    try std.testing.expectEqualStrings("Api", cmd.typegen.client_name);
    try std.testing.expect(cmd.typegen.check);
}

test "parse typegen: url + admin creds" {
    const args = [_][]const u8{ "typegen", "--url", "http://x", "--admin-email", "a@b.c", "--admin-password", "pw", "--out", "c.ts" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expectEqualStrings("http://x", cmd.typegen.url.?);
    try std.testing.expectEqualStrings("a@b.c", cmd.typegen.admin_email.?);
}

test "parse typegen: missing flag value errors" {
    const args = [_][]const u8{ "typegen", "--out" };
    try std.testing.expectError(ParseError.MissingValue, parse(&args, .{ .serve_static = true }));
}

test "version / --version / -V -> version command" {
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"version"}, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"--version"}, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"-V"}, .{})));
}

test "version accepts --json in every spelling" {
    try std.testing.expectEqual(false, (try parse(&.{"version"}, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "version", "--json" }, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "--version", "--json" }, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "-V", "--json" }, .{})).version.json);
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "version", "--nope" }, .{}));
}

test "version --help / -h -> top-level help, not UnknownFlag" {
    // `version` has no dedicated HelpTopic, so its `--help` falls through to the same
    // top-level usage as bare `--help` — it must not be treated as an unrecognized flag.
    const cmd = try parse(&.{ "version", "--help" }, .{});
    try std.testing.expectEqual(.help, std.meta.activeTag(cmd));
    try std.testing.expectEqual(HelpTopic.top, cmd.help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{ "version", "-h" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{ "--version", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{ "-V", "-h" }, .{})).help);
}

test "migrate status accepts --json; the other actions reject it" {
    const s = try parse(&.{ "migrate", "status", "--json" }, .{});
    try std.testing.expectEqual(MigrateAction.status, s.migrate.action);
    try std.testing.expectEqual(true, s.migrate.json);
    try std.testing.expectEqual(false, (try parse(&.{ "migrate", "status" }, .{})).migrate.json);
    // --json is a status-only flag: it means nothing for apply/rollback/dump.
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "--json" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "dump", "--json" }, .{}));
}

test "explain-code parses a bare code, --json, and both" {
    const bare = try parse(&.{"explain-code"}, .{});
    try std.testing.expect(std.meta.activeTag(bare) == .explain_code);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.explain_code.code);
    try std.testing.expectEqual(false, bare.explain_code.json);

    const one = try parse(&.{ "explain-code", "not_found" }, .{});
    try std.testing.expectEqualStrings("not_found", one.explain_code.code.?);

    const j = try parse(&.{ "explain-code", "--json" }, .{});
    try std.testing.expectEqual(true, j.explain_code.json);

    // Flag order is irrelevant; both forms carry the code AND the flag.
    const both = try parse(&.{ "explain-code", "--json", "not_found" }, .{});
    try std.testing.expectEqualStrings("not_found", both.explain_code.code.?);
    try std.testing.expectEqual(true, both.explain_code.json);
    const both_rev = try parse(&.{ "explain-code", "not_found", "--json" }, .{});
    try std.testing.expectEqualStrings("not_found", both_rev.explain_code.code.?);
    try std.testing.expectEqual(true, both_rev.explain_code.json);
}

test "explain-code rejects a second positional and unknown flags; --help routes" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "explain-code", "a", "b" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "explain-code", "--nope" }, .{}));
    try std.testing.expectEqual(HelpTopic.explain_code, (try parse(&.{ "explain-code", "--help" }, .{})).help);
}
