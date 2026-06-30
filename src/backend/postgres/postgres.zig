//! Pure-Zig PostgreSQL backend (issue #159, PR-1a) — the public entry point for the
//! Postgres driver. Re-exports the `Db`/`Stmt`/`Pool` surface that mirrors `src/db.zig`,
//! so the rest of ZigBase can later run against PostgreSQL with identical call sites
//! (the tagged-union wiring lands in PR-1b — this PR ships the driver standalone).
//!
//! Driver seam (PR-1a requirement #4): the active PG driver is selected behind the
//! `DriverKind` comptime knob. Today only `.wire` (this pure-Zig wire-protocol driver,
//! built on `std.crypto.tls.Client` + `std.crypto` SCRAM — no libpq, no C, no OpenSSL)
//! exists. A future optional `.libpq` driver (probably dynamically linked, behind its own
//! build flag) can be added as an interchangeable implementation of the same interface
//! without touching callers. Not built here — just not precluded.
//!
//! Everything in this subtree is reachable only when `build_options.postgres` is true; the
//! default build never references it, so the shipped binary is byte-identical.
//!
//! ============================ SECURITY: TLS IS UN-AUTHENTICATED ============================
//! The driver encrypts transport but does NOT yet authenticate the server, in ANY sslmode:
//!   * `sslmode=disable` — plaintext.
//!   * `sslmode=prefer` (default) — opportunistic TLS, but an active MITM can strip it to
//!     plaintext (the server's "no SSL" reply is trusted).
//!   * `sslmode=require` — TLS is mandatory, but the server certificate chain and hostname are
//!     NOT verified (`host=.no_verification, ca=.no_verification`), so a MITM presenting any
//!     certificate is accepted. This matches libpq `sslmode=require` semantics.
//!   * `sslmode=verify-ca` / `verify-full` — REJECTED at parse time (the driver cannot honor
//!     them yet), rather than silently downgraded to encryption-only.
//! So the driver provides NO protection against an active man-in-the-middle today. Use it only
//! on a trusted network path (loopback, private VPC, mTLS sidecar) until verify-full lands.
//! Real certificate + hostname verification (a true `verify-full`) is the immediate tracked
//! follow-up. The user-facing security note ships with the PR-1b wiring docs.
//! ==========================================================================================

const std = @import("std");

pub const DriverKind = enum {
    /// Pure-Zig PostgreSQL v3 wire-protocol driver (the 0.9.0 deliverable).
    wire,
    /// Reserved: a future optional libpq-backed driver. Not implemented.
    libpq,
};

/// The driver in use. Selectable later via a build option; pinned to the wire driver now.
pub const driver: DriverKind = .wire;

pub const Db = @import("db.zig").Db;
pub const DbError = @import("db.zig").DbError;
pub const Stmt = @import("stmt.zig").Stmt;
pub const ColumnType = @import("stmt.zig").ColumnType;
pub const Pool = @import("pool.zig").Pool;
pub const PoolOptions = @import("pool.zig").PoolOptions;

pub const Conn = @import("conn.zig").Conn;
pub const ConnError = @import("conn.zig").ConnError;
pub const connstr = @import("connstr.zig");
pub const scram = @import("scram.zig");
pub const protocol = @import("protocol.zig");

// Reference every file so its `test {}` blocks are discovered when this module is pulled
// into the unit-test root (gated behind `build_options.postgres` in `src/root.zig`).
test {
    _ = @import("scram.zig");
    _ = @import("protocol.zig");
    _ = @import("connstr.zig");
    _ = @import("conn.zig");
    _ = @import("stmt.zig");
    _ = @import("db.zig");
    _ = @import("pool.zig");
    _ = @import("clock.zig");
    _ = @import("tests.zig");
    _ = @import("crud_tests.zig");
    // PR-5: live field-encryption + key-rotation rewrap verification (rowid→id fix). Skips if no PG.
    _ = @import("encryption_pg_test.zig");
    // PR-4: live KV store / TTL-GC / sticky-experiment dialect parity. Skips if no PG.
    _ = @import("kvttl_pg_test.zig");
    // PR-8: live typed-client codegen parity (data-dir adapter opens a postgres:// source;
    // generated client is byte-identical to SQLite). Skips if no PG.
    _ = @import("codegen_pg_test.zig");
}
