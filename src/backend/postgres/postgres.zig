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
//! ================================ SECURITY: TLS ================================
//! Since 0.10.0 the driver verifies the server by DEFAULT: an unqualified
//! `postgres://` URL gets `sslmode=verify-full` (chain verified against the system
//! root store or `sslrootcert=<pem>`, hostname checked against the URL host, cert
//! validity checked against real wall time). Explicit opt-downs remain available —
//! `require` (encrypted, unverified — libpq parity), `prefer`/`allow` (opportunistic,
//! MITM-strippable), `disable` (plaintext) — and each logs a startup warning when
//! chosen explicitly. Misconfiguration (missing/empty CA bundle, refused TLS,
//! untrusted chain, hostname mismatch) fails AT STARTUP with an error naming the fix.
//! Not supported: client certificates (mTLS), sslcrl/OCSP, and SCRAM channel binding
//! (`SCRAM-SHA-256-PLUS`). Hostname verification matches DNS names — an IP-literal
//! host under verify-full generally fails even with an iPAddress SAN (use the DNS
//! name, or verify-ca on an otherwise-trusted path).
//! ===============================================================================

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
pub const tls_trust = @import("tls_trust.zig");
pub const scram = @import("scram.zig");
pub const protocol = @import("protocol.zig");

// Reference every file so its `test {}` blocks are discovered when this module is pulled
// into the unit-test root (gated behind `build_options.postgres` in `src/root.zig`).
test {
    _ = @import("scram.zig");
    _ = @import("saslprep.zig");
    // SP3-A item 2: live SASLprep/SCRAM coverage (NFC pass-through + needs-NFKC hard
    // error). Skips without PG.
    _ = @import("scram_pg_test.zig");
    _ = @import("protocol.zig");
    _ = @import("connstr.zig");
    _ = @import("tls_trust.zig");
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
    // PR-10: live full-text-search parity (tsvector/@@/ts_rank) + tenant/ability-scoped search
    // chokepoint composition. Skips if no PG.
    _ = @import("fts_pg_test.zig");
    // PR-6/6b: live realtime authz parity (create/update/delete delivery + snapshot authz) and
    // cross-instance LISTEN/NOTIFY (NOTIFY on conn A received by a listener on conn B). Skips if no PG.
    _ = @import("realtime_pg_test.zig");
    // PR-9: live SQLite -> Postgres dump/load round-trip (counts, encrypted field, relation). Skips if no PG.
    _ = @import("dumpload_pg_test.zig");
    // PR-11: live pgvector KNN parity (?vector= → <=>/<->) + tenant/ability-scoped vector-search
    // chokepoint composition. Skips if no PG or if -Dvector is off.
    _ = @import("vector_pg_test.zig");
    // SP3-A: live TLS-verification coverage. Skips without ZIGBASE_PG_TLS_CA / ZIGBASE_PG_PLAINTEXT.
    _ = @import("tls_pg_test.zig");
}
