//! PostgreSQL connection `Pool`, mirroring the SQLite `Pool` surface in `src/db.zig` so
//! callers are identical across backends: `init`/`initCapped`/`initOpts`/`deinit`,
//! `acquireReader`/`releaseReader`, `acquireWriter`/`releaseWriter`, plus `field_cipher`
//! stamping at acquire time.
//!
//! PostgreSQL has no single-writer constraint, but the SQLite-mirrored interface exposes a
//! single `acquireWriter() *Db` slot (mutex-guarded) plus a warm free-list of reader
//! connections. This keeps every call site byte-identical to the SQLite pool; relaxing the
//! writer to a true N-connection writer pool is a transparent future change behind the same
//! API. Connections are opened lazily; released readers are parked up to `reader_cap`.

const std = @import("std");
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const DbError = db_mod.DbError;
const connstr = @import("connstr.zig");
const tls_trust = @import("tls_trust.zig");

const reader_pool_size = 16;

pub const PoolOptions = struct {
    /// Warm-reader free-list cap (clamped to `reader_pool_size`).
    reader_cap: usize = reader_pool_size,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: []const u8, // owned copy
    writer: Db,
    writer_mutex: std.Io.Mutex = .init,

    reader_mutex: std.atomic.Mutex = .unlocked,
    readers: [reader_pool_size]Db = undefined,
    reader_count: usize = 0,
    reader_cap: usize = reader_pool_size,

    /// Type-erased field-encryption cipher pointer; stamped onto every acquired connection.
    field_cipher: ?*const anyopaque = null,

    /// Shared CA trust for verify-ca/verify-full (heap-pinned: the TLS handshake takes
    /// pointers into it, and `Pool` itself moves by value). Built once in `initOpts`,
    /// reused by every reader refill, destroyed in `deinit`. Null for other modes.
    trust: ?*tls_trust.TlsTrust = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, uri: []const u8) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, uri, .{});
    }

    pub fn initCapped(allocator: std.mem.Allocator, io: std.Io, uri: []const u8, reader_cap: usize) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, uri, .{ .reader_cap = reader_cap });
    }

    pub fn initOpts(allocator: std.mem.Allocator, io: std.Io, uri: []const u8, options: PoolOptions) (DbError || std.mem.Allocator.Error)!Pool {
        const owned = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned);

        // Parse once at startup for TLS policy: the opted-down warnings + the shared trust
        // store. (Db.openTrusted re-parses per connection — cheap, and keeps Db.open's
        // standalone contract intact.)
        var cfg = connstr.parse(allocator, owned) catch return DbError.OpenFailed;
        defer cfg.deinit();
        logStartupWarnings(&cfg);

        var trust: ?*tls_trust.TlsTrust = null;
        errdefer if (trust) |t| {
            t.deinit();
            allocator.destroy(t);
        };
        if (cfg.sslmode.verifiesCertificate()) {
            const t = try allocator.create(tls_trust.TlsTrust);
            t.* = tls_trust.TlsTrust.init(allocator, io, &cfg) catch |e| {
                allocator.destroy(t);
                return if (e == error.OutOfMemory) error.OutOfMemory else DbError.OpenFailed;
            };
            trust = t;
        }

        const writer = try Db.openTrusted(allocator, io, owned, trust);
        return .{
            .allocator = allocator,
            .io = io,
            .uri = owned,
            .writer = writer,
            .reader_cap = @min(options.reader_cap, reader_pool_size),
            .trust = trust,
        };
    }

    /// One warning per opted-down startup (mirrors the `@public` access-rule warnings): an
    /// EXPLICIT sslmode below verify-full, and an sslrootcert the mode ignores. The DEFAULT
    /// (verify-full) and the explicit verify modes are silent. Logged once, at pool init —
    /// NOT in Db.open, so lazy reader refills never re-warn.
    fn logStartupWarnings(cfg: *const connstr.Config) void {
        const w = tls_trust.startupWarnings(cfg);
        if (w.unverified_sslmode) {
            const clause: []const u8 = switch (cfg.sslmode) {
                .disable => "connection is PLAINTEXT",
                .prefer => "an active MITM can strip TLS to plaintext",
                .require => "connection is encrypted but the server is NOT authenticated",
                .verify_ca, .verify_full => unreachable,
            };
            std.log.warn("postgres: sslmode={s} — {s}; use verify-full in production", .{ cfg.sslmode.label(), clause });
        }
        if (w.sslrootcert_ignored) {
            std.log.warn("postgres: sslrootcert is ignored under sslmode={s} (it applies only to verify-ca/verify-full)", .{cfg.sslmode.label()});
        }
    }

    pub fn deinit(self: *Pool) void {
        while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
        var i: usize = 0;
        while (i < self.reader_count) : (i += 1) self.readers[i].close();
        self.reader_count = 0;
        self.reader_mutex.unlock();
        self.writer.close();
        if (self.trust) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.allocator.free(self.uri);
    }

    /// Blocks on the writer mutex and returns the writer connection. Caller MUST call
    /// `releaseWriter` when done.
    pub fn acquireWriter(self: *Pool) *Db {
        self.writer_mutex.lockUncancelable(self.io);
        self.writer.field_cipher = self.field_cipher;
        return &self.writer;
    }

    pub fn releaseWriter(self: *Pool) void {
        self.writer_mutex.unlock(self.io);
    }

    /// Opens a fresh connection. Caller owns it and must `close()` (or hand to releaseReader).
    pub fn openReader(self: *Pool) DbError!Db {
        var db = try Db.openTrusted(self.allocator, self.io, self.uri, self.trust);
        db.field_cipher = self.field_cipher;
        return db;
    }

    /// Checks out a connection, reusing a warm one when available. Returns a `Db` by value;
    /// caller MUST hand it back via `releaseReader`. Parked connections that have gone
    /// unhealthy (e.g. the DB was restarted while they sat in the free-list) are closed and
    /// skipped, so a poisoned free-list can never be handed back to a caller. (I-2.)
    pub fn acquireReader(self: *Pool) DbError!Db {
        while (true) {
            while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.reader_count > 0) {
                self.reader_count -= 1;
                var db = self.readers[self.reader_count];
                self.reader_mutex.unlock();
                if (!db.isHealthy()) {
                    db.close(); // dead parked conn → drop it and try the next / open fresh
                    continue;
                }
                db.field_cipher = self.field_cipher;
                return db;
            }
            self.reader_mutex.unlock();
            return self.openReader();
        }
    }

    /// Returns a connection from `acquireReader` to the warm pool (up to `reader_cap`),
    /// otherwise closes it. A BROKEN connection (mid-query close / desync / failed-transaction
    /// state) is always closed rather than parked, so it can never poison the free-list. (I-2.)
    /// Pass the same `*Db` you received from `acquireReader`.
    pub fn releaseReader(self: *Pool, reader: *Db) void {
        if (!reader.isHealthy()) {
            reader.close();
            return;
        }
        while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.reader_count < self.reader_cap) {
            self.readers[self.reader_count] = reader.*;
            self.reader_count += 1;
            self.reader_mutex.unlock();
            return;
        }
        self.reader_mutex.unlock();
        reader.close();
    }
};
