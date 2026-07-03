//! Startup-built TLS trust store for the verified sslmodes (`verify-ca` / `verify-full`).
//!
//! Built ONCE — by `pg.Pool.initOpts` before the first connection opens, or per standalone
//! `Db.open` — and shared by every pooled connection's handshake: `std.crypto.tls.Client`
//! takes `lock: *std.Io.RwLock, bundle: *Certificate.Bundle` and may re-scan/swap the bundle
//! under the lock on some platforms, which is why the pool heap-pins one `TlsTrust` rather
//! than rebuilding per connection. Because the bundle and the URL are validated HERE, at
//! startup, a lazily-opened pool reader can only fail later for *live* reasons (rotated
//! cert, network) — misconfig-class errors are impossible post-boot.
//!
//! Misconfiguration fails FAST with an error that names the fix. postgres:// URLs are
//! NEVER logged here — messages name sslmode labels and file paths only.

const std = @import("std");
const connstr = @import("connstr.zig");

pub const TrustError = error{
    /// The `sslrootcert` file is missing/unreadable, or a PEM block in it failed to parse
    /// (also: scanning the system root store failed outright).
    CaFileUnreadable,
    /// The loaded bundle (file or system store) contains zero usable CA certificates.
    CaBundleEmpty,
    OutOfMemory,
};

pub const TlsTrust = struct {
    bundle: std.crypto.Certificate.Bundle,
    lock: std.Io.RwLock,
    gpa: std.mem.Allocator,

    /// Build the CA bundle for a verified sslmode: `sslrootcert=<path>` loads that PEM
    /// file (relative paths resolve against cwd); absent or `sslrootcert=system` scans
    /// the system root store. Aborts startup (error + actionable log) on a missing/
    /// unreadable file or an empty bundle — the server never boots half-verified.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: *const connstr.Config) TrustError!TlsTrust {
        const now = std.Io.Timestamp.now(io, .real);
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(gpa);

        const file_path: ?[]const u8 = if (cfg.sslrootcert) |p|
            (if (std.mem.eql(u8, p, "system")) null else p)
        else
            null;

        if (file_path) |path| {
            const res = if (std.fs.path.isAbsolute(path))
                bundle.addCertsFromFilePathAbsolute(gpa, io, now, path)
            else
                bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), path);
            res catch |e| {
                if (e == error.OutOfMemory) return TrustError.OutOfMemory;
                std.log.err(
                    "postgres TLS: sslmode={s} requires a CA bundle, but sslrootcert '{s}' could not be read ({s}). Fix the path, or omit sslrootcert to use the system root store.",
                    .{ cfg.sslmode.label(), path, @errorName(e) },
                );
                return TrustError.CaFileUnreadable;
            };
        } else {
            bundle.rescan(gpa, io, now) catch |e| {
                if (e == error.OutOfMemory) return TrustError.OutOfMemory;
                std.log.err(
                    "postgres TLS: sslmode={s} requires CA certificates, but scanning the system root store failed ({s}). Pass sslrootcert=<pem-path> in ZIGBASE_DB_URL instead.",
                    .{ cfg.sslmode.label(), @errorName(e) },
                );
                return TrustError.CaFileUnreadable;
            };
        }

        if (bundle.map.count() == 0) {
            std.log.err(
                "postgres TLS: sslmode={s} requires a CA bundle, but {s}{s} contains no usable CA certificates.",
                .{
                    cfg.sslmode.label(),
                    if (file_path != null) "sslrootcert " else "",
                    if (file_path) |p| p else "the system root store",
                },
            );
            return TrustError.CaBundleEmpty;
        }
        return .{ .bundle = bundle, .lock = .init, .gpa = gpa };
    }

    pub fn deinit(self: *TlsTrust) void {
        self.bundle.deinit(self.gpa);
        self.* = undefined;
    }
};

pub const StartupWarnings = struct {
    /// An EXPLICIT sslmode below verify-full was configured (encrypted-unverified or
    /// plaintext). The DEFAULT (verify-full) and explicit verify modes never warn.
    unverified_sslmode: bool,
    /// `sslrootcert=` was given with a mode that ignores it (libpq parity: accepted,
    /// ignored, warned — not an error).
    sslrootcert_ignored: bool,
};

/// Pure classifier for the pool's startup warnings (unit-testable without logs).
pub fn startupWarnings(cfg: *const connstr.Config) StartupWarnings {
    const unverified = !cfg.sslmode.verifiesCertificate();
    return .{
        .unverified_sslmode = cfg.sslmode_explicit and unverified,
        .sslrootcert_ignored = cfg.sslrootcert != null and unverified,
    };
}

// --- tests (pure filesystem; no live PG) -----------------------------------------

test "tls_trust: a missing sslrootcert file aborts startup with CaFileUnreadable" {
    const a = std.testing.allocator;
    var cfg = try connstr.parse(a, "postgres://h/db?sslmode=verify-full&sslrootcert=/definitely/not/here.pem");
    defer cfg.deinit();
    try std.testing.expectError(TrustError.CaFileUnreadable, TlsTrust.init(a, std.testing.io, &cfg));
}

test "tls_trust: an empty PEM and a no-marker garbage PEM yield CaBundleEmpty" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.pem", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "garbage.pem", .data = "this is not a certificate\n" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_path);

    inline for (.{ "empty.pem", "garbage.pem" }) |name| {
        const url = try std.fmt.allocPrint(a, "postgres://h/db?sslmode=verify-ca&sslrootcert={s}/{s}", .{ dir_path, name });
        defer a.free(url);
        var cfg = try connstr.parse(a, url);
        defer cfg.deinit();
        try std.testing.expectError(TrustError.CaBundleEmpty, TlsTrust.init(a, std.testing.io, &cfg));
    }
}

test "tls_trust: a truncated PEM block (BEGIN without END) is CaFileUnreadable" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "truncated.pem",
        .data = "-----BEGIN CERTIFICATE-----\nAAAA\n",
    });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_path);
    const url = try std.fmt.allocPrint(a, "postgres://h/db?sslmode=verify-full&sslrootcert={s}/truncated.pem", .{dir_path});
    defer a.free(url);
    var cfg = try connstr.parse(a, url);
    defer cfg.deinit();
    try std.testing.expectError(TrustError.CaFileUnreadable, TlsTrust.init(a, std.testing.io, &cfg));
}

test "tls_trust: startupWarnings classification (asserted here, logged at the pool layer)" {
    const a = std.testing.allocator;
    // Explicit require -> warn unverified; sslrootcert under require -> warn ignored.
    var req = try connstr.parse(a, "postgres://h/db?sslmode=require&sslrootcert=/x.pem");
    defer req.deinit();
    try std.testing.expect(startupWarnings(&req).unverified_sslmode);
    try std.testing.expect(startupWarnings(&req).sslrootcert_ignored);
    // DEFAULT verify-full -> silent.
    var bare = try connstr.parse(a, "postgres://h/db");
    defer bare.deinit();
    try std.testing.expect(!startupWarnings(&bare).unverified_sslmode);
    try std.testing.expect(!startupWarnings(&bare).sslrootcert_ignored);
    // Explicit verify-ca with a cert -> silent.
    var vca = try connstr.parse(a, "postgres://h/db?sslmode=verify-ca&sslrootcert=/x.pem");
    defer vca.deinit();
    try std.testing.expect(!startupWarnings(&vca).unverified_sslmode);
    try std.testing.expect(!startupWarnings(&vca).sslrootcert_ignored);
}
