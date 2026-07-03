# SP3 Theme A: Postgres Production-Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three "trusted network / superuser" asterisks from the Postgres backend: real TLS server-certificate verification with **`verify-full` as the default** for `postgres://` URLs, RFC 4013 SASLprep for SCRAM passwords (minimal-correct: never silently wrong, loud rejection for the one un-normalized case), and a fully-supported non-superuser `migrate-db` path that loads cyclic/self-referential FK graphs via deferred constraints.

**Architecture:** All three items live under `src/backend/postgres/` (comptime-gated by `-Dpostgres=true`) plus `src/dumpload.zig`/`src/ddl.zig` for item 3 — the only default-build change is one `PRAGMA defer_foreign_keys=ON` in the SQLite load transaction. Item 1 is plumbing + policy over `std.crypto.tls.Client` (no new crypto): a new `tls_trust.zig` builds a CA bundle once at startup (shared by all pool connections), `connstr.zig` grows `verify-ca`/`verify-full`/`sslrootcert=` and flips the default, `conn.zig` selects per-mode TLS options and maps `InitError` to actionable startup errors. Item 2 adds `saslprep.zig` + a generated `saslprep_tables.zig` (checked-in output of a new `scripts/gen-saslprep-tables.py` over vendored RFC 3454 / UCD extracts), called from `scram.Client.clientFinal` before PBKDF2. Item 3 reworks `dumpload.collectionCreateOrder` into `planCreateOrder` (Kahn + cycle edges), provisions cycle-edge FKs as `DEFERRABLE INITIALLY IMMEDIATE`, and defers them to COMMIT inside the load transaction. Spec: `/home/valthon/.claude/jobs/85efdf24/tmp/spec-pg-hardening.md`. Baseline: `origin/main` @ `0ae3289` (the spec's `1bd02c4` has since advanced; all `src/` files referenced here are byte-identical between the two — only docs moved).

**Tech Stack:** Zig 0.16.0 (mise-pinned; `std.crypto.tls.Client`, `std.crypto.Certificate.Bundle`, `std.Io.RwLock`), Python 3.13 (table generator only, runs offline at development time), live-Postgres CI (`postgres` service container + `postgres-tls` docker with self-signed cert), vendored Unicode/RFC data under `vendor/unicode/`.

**Release-artifact note (spec Non-goals):** Postgres stays **custom-compile only**. NO `zigbase-pg-*` tarballs, NO release-matrix `variant` dimension, NO `@zigbase/server-pg-*` npm packages, and the `docs/postgres.md` line "Release tarballs are stock SQLite-only builds" is **kept unchanged** (Task 12 flips every other caveat, not that one).

## Global Constraints

- **Build/test:** `mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`. For anything under `src/backend/postgres/`, run `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` (live-PG tests SKIP when no server is reachable; the pure unit tests still run). The authoritative signal is the **`Build Summary: N/N tests passed`** line — `zig build test` prints a spurious `failed command: …` line even on success. There is no per-test filter.
- **Test discovery:** a new file under `src/backend/postgres/` must be added to the `test { _ = @import("…"); }` block at the bottom of **`src/backend/postgres/postgres.zig`** (that module is what `src/root.zig` imports under the `-Dpostgres` gate). This plan adds `tls_trust.zig`, `saslprep.zig`, `saslprep_tables.zig`, `tls_pg_test.zig`, `scram_pg_test.zig` there. No new `src/*.zig` top-level files are added (so no `src/root.zig` edit is needed — `dumpload.zig` and `ddl.zig` are already wired).
- **Changelog:** NEVER edit `CHANGELOG.md` or `site/src/content/docs/changelog.md`. This plan adds THREE fragments: `changelog.d/pg-tls-verify.md` (leads with `### Breaking` for the verify-full default + `### Security`), `changelog.d/pg-saslprep.md` (`### Fixes`/`### Security`), `changelog.d/pg-migrate-deferred-fk.md` (`### Fixes`). The 0.x+1.0 minor version bump happens at release time via `scripts/release.sh` — do NOT bump `build.zig.zon` in this plan.
- **Docs mirror:** every `docs/*.md` change must be mirrored to `site/src/content/docs/*.md`; run `cd site && npm run build` after doc/site touches (Task 12). `docs/superpowers/` is a historical archive — never rewrite it.
- **Never log the URL:** `postgres://` URLs contain credentials. Every new log/error message names `host:port`, the sslmode label, and cert-file paths ONLY. Grep your diff for `uri` inside any `std.log` call before committing.
- **CI jobs:** the `postgres` job (`pgvector/pgvector:pg16` service, SCRAM forced, no server TLS, `?sslmode=prefer` URL) and `postgres-tls` job (self-signed `docker run` postgres:16, `?sslmode=require` URL) both run `zig build test -Dpostgres=true`. **Known flake:** `realtime_pg_test.zig` occasionally fails on a NOTIFY timing race — if the `postgres` job fails inside `realtime_pg_test`, **rerun the job before debugging**; it is only real if it reproduces.
- **Live-PG fixtures:** the CI role `zbpg` IS a superuser (container initdb owner), so live tests may `CREATE ROLE`. The migrate-db tests create a `NOSUPERUSER` fixture role + a schema it owns; always `DROP SCHEMA … CASCADE` before `DROP ROLE` in cleanup.
- **Default-build impact must stay zero** except the one SQLite `PRAGMA defer_foreign_keys=ON` (Task 10). After each task, `mise exec zig@0.16.0 -- zig build test --summary all` (default, no `-Dpostgres`) must also pass.
- Commit after each task with the message given in the task. All paths are relative to the repo root. Work on a feature branch off current `origin/main` (never commit to `main`; repo is merge-commits-only via PR).

---

### Task 1: connstr — `verify-ca`/`verify-full`, `sslrootcert=`, default `verify-full`

**Files:**
- Modify: `src/backend/postgres/connstr.zig` (enum members, `Config` fields, parse loop, default flip, tests)

**Interfaces:**
- Produces: `SslMode` members `.verify_ca`, `.verify_full`; `SslMode.label(self) []const u8` (returns `"verify-full"` etc.); `SslMode.verifiesCertificate(self) bool`; `Config.sslmode` default `.verify_full`; `Config.sslmode_explicit: bool` (true iff the URL carried `sslmode=`); `Config.sslrootcert: ?[]const u8` (owned, percent-decoded, freed by `deinit`). `SslMode.requiresVerification` and `ParseError.UnsupportedSslMode` are DELETED. Consumed by Tasks 2, 3, 4.

- [ ] **Step 1: Update/add the failing tests.** In `src/backend/postgres/connstr.zig`, replace the test `"connstr: verify-ca/verify-full are rejected (not silently downgraded)"` (lines ~227–233) with:

```zig
test "connstr: verify-ca/verify-full parse to the new enum members" {
    const a = std.testing.allocator;
    var ca = try parse(a, "postgres://h/db?sslmode=verify-ca");
    defer ca.deinit();
    try std.testing.expectEqual(SslMode.verify_ca, ca.sslmode);
    try std.testing.expect(ca.sslmode_explicit);
    var full = try parse(a, "postgres://h/db?sslmode=verify-full");
    defer full.deinit();
    try std.testing.expectEqual(SslMode.verify_full, full.sslmode);
    // A bogus mode is still rejected loudly.
    try std.testing.expectError(ParseError.InvalidSslMode, parse(a, "postgres://h/db?sslmode=bogus"));
}

test "connstr: DEFAULT sslmode is verify-full; explicit modes are respected + flagged" {
    const a = std.testing.allocator;
    var bare = try parse(a, "postgres://db.example.com/mydb");
    defer bare.deinit();
    try std.testing.expectEqual(SslMode.verify_full, bare.sslmode);
    try std.testing.expect(!bare.sslmode_explicit);
    inline for (.{ "disable", "prefer", "require" }, .{ SslMode.disable, SslMode.prefer, SslMode.require }) |s, m| {
        var cfg = try parse(a, "postgres://h/db?sslmode=" ++ s);
        defer cfg.deinit();
        try std.testing.expectEqual(m, cfg.sslmode);
        try std.testing.expect(cfg.sslmode_explicit);
    }
}

test "connstr: sslrootcert path, =system, and percent-decoding" {
    const a = std.testing.allocator;
    var p = try parse(a, "postgres://h/db?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fmy-ca.pem");
    defer p.deinit();
    try std.testing.expectEqualStrings("/etc/ssl/my-ca.pem", p.sslrootcert.?);
    var sys = try parse(a, "postgres://h/db?sslmode=verify-ca&sslrootcert=system");
    defer sys.deinit();
    try std.testing.expectEqualStrings("system", sys.sslrootcert.?);
    // sslrootcert with a NON-verifying mode is accepted (ignored + warned at the pool layer, libpq parity).
    var req = try parse(a, "postgres://h/db?sslmode=require&sslrootcert=/x.pem");
    defer req.deinit();
    try std.testing.expectEqual(SslMode.require, req.sslmode);
    try std.testing.expectEqualStrings("/x.pem", req.sslrootcert.?);
    // Absent -> null.
    var none = try parse(a, "postgres://h/db");
    defer none.deinit();
    try std.testing.expect(none.sslrootcert == null);
}

test "connstr: label + verifiesCertificate round out the mode surface" {
    try std.testing.expectEqualStrings("verify-full", SslMode.verify_full.label());
    try std.testing.expectEqualStrings("verify-ca", SslMode.verify_ca.label());
    try std.testing.expectEqualStrings("require", SslMode.require.label());
    try std.testing.expect(SslMode.verify_ca.verifiesCertificate());
    try std.testing.expect(SslMode.verify_full.verifiesCertificate());
    try std.testing.expect(!SslMode.require.verifiesCertificate());
    try std.testing.expect(!SslMode.prefer.verifiesCertificate());
    try std.testing.expect(!SslMode.disable.verifiesCertificate());
}
```

Also update the existing test `"connstr: defaults + percent-decoding"` (~line 200): change its final assertion from `SslMode.prefer` to `SslMode.verify_full` (a bare URL now defaults to the strongest mode).

- [ ] **Step 2: Run to verify failure.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: **compile error** (`verify_ca` not a member of `SslMode`).

- [ ] **Step 3: Implement.** In `src/backend/postgres/connstr.zig`:

Replace the whole `SslMode` enum (lines 7–30) with:

```zig
pub const SslMode = enum {
    disable,
    /// Try TLS first, fall back to plaintext if the server refuses (SSLRequest → 'N').
    prefer,
    /// Require TLS; fail if the server will not negotiate it. The server is NOT
    /// authenticated (libpq `require` parity) — chain/hostname are not checked.
    require,
    /// Require TLS + verify the server certificate chain against the CA bundle
    /// (`sslrootcert=<path>` or the system root store).
    verify_ca,
    /// `verify_ca` + verify the certificate matches the URL host (SAN/CN).
    /// The DEFAULT for `postgres://` URLs since 0.10.0 (safe-by-default).
    verify_full,

    pub fn parse(s: []const u8) ?SslMode {
        if (std.mem.eql(u8, s, "disable")) return .disable;
        if (std.mem.eql(u8, s, "prefer")) return .prefer;
        if (std.mem.eql(u8, s, "allow")) return .prefer;
        if (std.mem.eql(u8, s, "require")) return .require;
        if (std.mem.eql(u8, s, "verify-ca")) return .verify_ca;
        if (std.mem.eql(u8, s, "verify-full")) return .verify_full;
        return null;
    }

    /// The libpq-style spelling, for log/error messages ("verify-full", not "verify_full").
    pub fn label(self: SslMode) []const u8 {
        return switch (self) {
            .disable => "disable",
            .prefer => "prefer",
            .require => "require",
            .verify_ca => "verify-ca",
            .verify_full => "verify-full",
        };
    }

    /// True when this mode verifies the server certificate chain (and, for
    /// `verify_full`, the hostname) — i.e. when a `TlsTrust` bundle must be built.
    pub fn verifiesCertificate(self: SslMode) bool {
        return self == .verify_ca or self == .verify_full;
    }
};
```

In `ParseError` (lines 32–42), DELETE the `UnsupportedSslMode` member and its doc comment (nothing references it after this task).

In `Config` (lines 46–61), change the `sslmode` default and add two fields + free `sslrootcert` in `deinit`:

```zig
    sslmode: SslMode = .verify_full,
    /// True when the URL carried an explicit `sslmode=` (drives the opted-down startup
    /// warning: the DEFAULT verify-full and explicit verify modes are silent).
    sslmode_explicit: bool = false,
    /// Percent-decoded `sslrootcert=` value: a CA-bundle PEM path, or the literal
    /// "system" (libpq-16 semantics: explicitly select the system root store).
    /// Owned (duped); null when absent.
    sslrootcert: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        if (self.sslrootcert) |rc| self.allocator.free(rc);
    }
```

In `parse` (lines 117–130), replace the query-parsing block with:

```zig
    var sslmode: SslMode = .verify_full;
    var sslmode_explicit = false;
    var sslrootcert_raw: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "sslmode")) {
            sslmode = SslMode.parse(val) orelse return ParseError.InvalidSslMode;
            sslmode_explicit = true;
        } else if (std.mem.eql(u8, key, "sslrootcert")) {
            sslrootcert_raw = val;
        } else if (std.mem.eql(u8, key, "dbname") and database.len == 0) {
            database = val;
        }
        // Unknown query keys keep today's ignore behavior.
    }
```

And extend the dup block at the bottom of `parse` (lines 137–153):

```zig
    const host_d = try pctDup(allocator, host);
    errdefer allocator.free(host_d);
    const user_d = try pctDup(allocator, user);
    errdefer allocator.free(user_d);
    const pass_d = try pctDup(allocator, password);
    errdefer allocator.free(pass_d);
    const db_d = try pctDup(allocator, database);
    errdefer allocator.free(db_d);
    const rootcert_d: ?[]u8 = if (sslrootcert_raw) |rc| try pctDup(allocator, rc) else null;

    return .{
        .allocator = allocator,
        .host = host_d,
        .port = port,
        .user = user_d,
        .password = pass_d,
        .database = db_d,
        .sslmode = sslmode,
        .sslmode_explicit = sslmode_explicit,
        .sslrootcert = rootcert_d,
    };
```

- [ ] **Step 4: Fix the one stale comment reference.** `src/backend/postgres/conn.zig` line ~207 mentions `ParseError.UnsupportedSslMode` inside the `startTlsHandshake` comment — leave the code alone (Task 3 rewrites that whole block), it still compiles because it is only a comment. Confirm nothing else references the deleted symbols: `grep -rn "UnsupportedSslMode\|requiresVerification" src/` must show only that conn.zig comment.

- [ ] **Step 5: Run to verify pass.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: `Build Summary: … tests passed` (live-PG tests skip without a server). Also run the default build: `mise exec zig@0.16.0 -- zig build test --summary all` — expected: pass (connstr is pg-gated; this confirms no default-build spill).

- [ ] **Step 6: Commit.**

```bash
git add src/backend/postgres/connstr.zig
git commit -m "feat(pg): connstr accepts verify-ca/verify-full + sslrootcert; default sslmode is verify-full"
```

---

### Task 2: `tls_trust.zig` — startup-built CA trust store + warning classifier

**Files:**
- Create: `src/backend/postgres/tls_trust.zig`
- Modify: `src/backend/postgres/postgres.zig` (re-export + test-block wiring)

**Interfaces:**
- Consumes: Task 1's `connstr.Config` (`sslmode`, `sslmode.label()`, `sslmode.verifiesCertificate()`, `sslrootcert`, `sslmode_explicit`).
- Produces: `pub const TrustError = error{ CaFileUnreadable, CaBundleEmpty, OutOfMemory }`; `pub const TlsTrust = struct { bundle: std.crypto.Certificate.Bundle, lock: std.Io.RwLock, gpa: std.mem.Allocator }` with `init(gpa: std.mem.Allocator, io: std.Io, cfg: *const connstr.Config) TrustError!TlsTrust` and `deinit(self: *TlsTrust) void`; `pub const StartupWarnings = struct { unverified_sslmode: bool, sslrootcert_ignored: bool }`; `pub fn startupWarnings(cfg: *const connstr.Config) StartupWarnings`. Consumed by Tasks 3, 4.

- [ ] **Step 1: Create `src/backend/postgres/tls_trust.zig` with implementation AND tests** (the tests are pure-filesystem — no live PG needed; TDD is compressed to one step because the file cannot compile half-written):

```zig
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
```

NOTE on the truncated-PEM expectation: `Bundle.addCertsFromFile` returns `error.MissingEndCertificateMarker` for a `BEGIN` without `END` (verified in the Zig 0.16 std source), which `init` maps to `CaFileUnreadable`. Empty/no-marker files parse zero certs cleanly → `CaBundleEmpty`.

- [ ] **Step 2: Wire discovery + export.** In `src/backend/postgres/postgres.zig`: add below the `pub const connstr = …` line:

```zig
pub const tls_trust = @import("tls_trust.zig");
```

and add `_ = @import("tls_trust.zig");` inside the `test { … }` block at the bottom.

- [ ] **Step 3: Run.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass, with the four new `tls_trust` tests counted in the `Build Summary` line.

- [ ] **Step 4: Commit.**

```bash
git add src/backend/postgres/tls_trust.zig src/backend/postgres/postgres.zig
git commit -m "feat(pg): startup-built TLS trust store (sslrootcert / system roots) with fail-fast errors"
```

---

### Task 3: conn/db/pool — verified handshake plumbing + failure UX

**Files:**
- Modify: `src/backend/postgres/conn.zig` (ConnError members, `connect` signature, `maybeStartTls`/`startTlsHandshake`, `mapTlsInitError`, module-doc)
- Modify: `src/backend/postgres/db.zig` (`open` builds ephemeral trust; new `openTrusted`)
- Modify: `src/backend/postgres/pool.zig` (heap-pinned shared `TlsTrust`, startup warnings)
- Modify: `src/backend/postgres/postgres.zig` (module-doc SECURITY block rewrite)

**Interfaces:**
- Consumes: Task 1 (`Config.sslmode/.sslrootcert`, `label()`, `verifiesCertificate()`), Task 2 (`TlsTrust`, `TrustError`, `startupWarnings`).
- Produces: `ConnError` gains `CertUntrusted`, `CertHostnameMismatch`, `CertExpired`, `CertNotYetValid`; `Conn.connect(gpa: std.mem.Allocator, io: std.Io, cfg: connstr.Config, trust: ?*tls_trust.TlsTrust) ConnError!*Conn` (signature change — trust must be non-null iff `cfg.sslmode.verifiesCertificate()`); `Db.openTrusted(gpa: std.mem.Allocator, io: std.Io, uri: []const u8, trust: ?*tls_trust.TlsTrust) DbError!Db`; `Db.open` keeps its `(gpa, io, uri)` signature and self-manages an ephemeral trust for verify-mode URLs; `Pool` gains `trust: ?*tls_trust.TlsTrust`. Consumed by Task 4 (live tests) and Task 7 (`doScram` edit).

- [ ] **Step 1: conn.zig — error members + import.** Add to the top imports:

```zig
const tls_trust = @import("tls_trust.zig");
```

Extend `ConnError` (lines 17–30) with four members (keep the existing ones):

```zig
    /// verify-ca/verify-full: the server certificate chain did not verify against the CA
    /// bundle. The log names the CA source and suggests sslrootcert= for private CAs.
    CertUntrusted,
    /// verify-full: the server certificate does not match the URL host.
    CertHostnameMismatch,
    CertExpired,
    CertNotYetValid,
```

- [ ] **Step 2: conn.zig — thread `trust` through the handshake.** Change `connect` (line ~98) to:

```zig
    /// Connect, negotiate TLS per `cfg.sslmode`, and complete startup + authentication.
    /// `trust` is the CA bundle for the verified modes and MUST be non-null exactly when
    /// `cfg.sslmode.verifiesCertificate()` (the Db/Pool layers uphold this).
    /// Returns a pinned, ready-to-query connection; caller owns it and must call `deinit`.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, cfg: connstr.Config, trust: ?*tls_trust.TlsTrust) ConnError!*Conn {
```

and inside it (line ~128) change `try self.maybeStartTls(cfg.sslmode);` to:

```zig
        std.debug.assert((trust != null) == cfg.sslmode.verifiesCertificate());
        try self.maybeStartTls(cfg, trust);
```

Replace `maybeStartTls` (lines 178–192) with:

```zig
    fn maybeStartTls(self: *Conn, cfg: connstr.Config, trust: ?*tls_trust.TlsTrust) ConnError!void {
        if (cfg.sslmode == .disable) return;

        // SSLRequest: int32 length(8), int32 magic(80877103). No type tag.
        self.out.writeInt(i32, 8, .big) catch return ConnError.ConnectFailed;
        self.out.writeInt(i32, 80877103, .big) catch return ConnError.ConnectFailed;
        self.flushOut() catch return ConnError.ConnectFailed;

        const reply = self.in.takeByte() catch return ConnError.ConnectFailed;
        switch (reply) {
            'S' => try self.startTlsHandshake(cfg, trust),
            'N' => switch (cfg.sslmode) {
                .require, .verify_ca, .verify_full => {
                    std.log.err(
                        "postgres: server {s}:{d} refused TLS but sslmode={s} requires it; for a trusted-network/dev setup append ?sslmode=disable (plaintext) or ?sslmode=require (encrypted, unverified) to ZIGBASE_DB_URL.",
                        .{ cfg.host, cfg.port, cfg.sslmode.label() },
                    );
                    return ConnError.TlsRequiredButRefused;
                },
                .prefer, .disable => {}, // opportunistic modes: plaintext fallback
            },
            else => return ConnError.Protocol,
        }
    }
```

Replace `startTlsHandshake` (lines 194–221) with:

```zig
    fn startTlsHandshake(self: *Conn, cfg: connstr.Config, trust: ?*tls_trust.TlsTrust) ConnError!void {
        self.tls_read_buf = self.gpa.alloc(u8, sock_buf_len) catch return ConnError.OutOfMemory;
        self.tls_write_buf = self.gpa.alloc(u8, sock_buf_len) catch return ConnError.OutOfMemory;
        const client = self.gpa.create(tls.Client) catch return ConnError.OutOfMemory;
        errdefer self.gpa.destroy(client);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);

        client.* = tls.Client.init(self.in, self.out, .{
            // verify_full: verify the certificate matches the URL host (SAN/CN).
            // Everything below verify_full: encryption without server authentication —
            // libpq parity for require/prefer; the verified modes are the safe default.
            .host = if (cfg.sslmode == .verify_full) .{ .explicit = cfg.host } else .no_verification,
            // verify_ca/verify_full: chain verification against the startup-built bundle
            // (shared across the pool; the std API takes the lock + bundle by pointer).
            .ca = if (trust) |t| .{ .bundle = .{
                .gpa = self.gpa,
                .io = self.io,
                .lock = &t.lock,
                .bundle = &t.bundle,
            } } else .no_verification,
            .write_buffer = self.tls_write_buf,
            .read_buffer = self.tls_read_buf,
            .entropy = &entropy,
            // Real wall time UNCONDITIONALLY: the verified modes need it for
            // NotBefore/NotAfter (`.zero` would make every cert "not yet valid");
            // harmless under .no_verification.
            .realtime_now = std.Io.Timestamp.now(self.io, .real),
        }) catch |e| return self.mapTlsInitError(e, cfg);

        self.tls_client = client;
        self.in = &client.reader;
        self.out = &client.writer;
        self.using_tls = true;
    }

    /// Map a TLS-handshake failure into an actionable ConnError, logging the operator-facing
    /// message HERE (the Db/Pool layers flatten everything to OpenFailed, so this is the only
    /// place the distinction exists). NEVER logs the URL — host:port, sslmode label, and the
    /// CA source only.
    fn mapTlsInitError(self: *Conn, e: anyerror, cfg: connstr.Config) ConnError {
        self.broken = true;
        const ca_src: []const u8 = cfg.sslrootcert orelse "the system root store";
        switch (e) {
            error.CertificateHostMismatch => {
                std.log.err(
                    "postgres TLS: the server certificate does not match host '{s}' (sslmode=verify-full). Connect by the name in the certificate, or use sslmode=verify-ca if you cannot.",
                    .{cfg.host},
                );
                return ConnError.CertHostnameMismatch;
            },
            error.CertificateExpired => {
                std.log.err(
                    "postgres TLS: the server certificate for {s}:{d} is EXPIRED. Renew the server certificate (and check this host's system clock).",
                    .{ cfg.host, cfg.port },
                );
                return ConnError.CertExpired;
            },
            error.CertificateNotYetValid => {
                std.log.err(
                    "postgres TLS: the server certificate for {s}:{d} is not yet valid. Check the server certificate and this host's system clock.",
                    .{ cfg.host, cfg.port },
                );
                return ConnError.CertNotYetValid;
            },
            error.TlsCertificateNotVerified,
            error.CertificateIssuerMismatch,
            error.CertificateSignatureInvalid,
            => {
                std.log.err(
                    "postgres TLS: the certificate chain for {s}:{d} could not be verified against {s} (sslmode={s}). For a private CA, pass sslrootcert=<pem-path> in ZIGBASE_DB_URL.",
                    .{ cfg.host, cfg.port, ca_src, cfg.sslmode.label() },
                );
                return ConnError.CertUntrusted;
            },
            else => {
                std.log.err("postgres TLS: handshake with {s}:{d} failed ({s}).", .{ cfg.host, cfg.port, @errorName(e) });
                return ConnError.TlsHandshakeFailed;
            },
        }
    }
```

(This replaces the old "does not (yet) verify" comment block entirely.)

- [ ] **Step 3: db.zig — `open` / `openTrusted`.** In `src/backend/postgres/db.zig`, add `const tls_trust = @import("tls_trust.zig");` to the imports, and replace `Db.open` (lines 36–46) with:

```zig
    /// Connect to `uri` (`postgres://user:pass@host:port/dbname?sslmode=...`) and complete
    /// startup + authentication. For the verified sslmodes (verify-ca / verify-full — the
    /// DEFAULT) this builds an ephemeral CA trust store for the single handshake; pooled
    /// connections share one instead via `openTrusted`. Caller owns the connection and
    /// must call `close`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, uri: []const u8) DbError!Db {
        var cfg = connstr.parse(gpa, uri) catch |e| {
            std.log.err("postgres: invalid connection URL ({s})", .{@errorName(e)});
            return DbError.OpenFailed;
        };
        defer cfg.deinit();
        if (cfg.sslmode.verifiesCertificate()) {
            // Ephemeral trust: the tls handshake completes fully inside Client.init, so the
            // bundle is not referenced after connect returns and can be freed immediately.
            var trust = tls_trust.TlsTrust.init(gpa, io, &cfg) catch return DbError.OpenFailed;
            defer trust.deinit();
            return openParsed(gpa, io, cfg, &trust);
        }
        return openParsed(gpa, io, cfg, null);
    }

    /// Pool path: connect using an already-built, shared trust store (or null for the
    /// non-verifying modes). `trust` must be non-null iff the URI's sslmode verifies.
    pub fn openTrusted(gpa: std.mem.Allocator, io: std.Io, uri: []const u8, trust: ?*tls_trust.TlsTrust) DbError!Db {
        var cfg = connstr.parse(gpa, uri) catch |e| {
            std.log.err("postgres: invalid connection URL ({s})", .{@errorName(e)});
            return DbError.OpenFailed;
        };
        defer cfg.deinit();
        return openParsed(gpa, io, cfg, trust);
    }

    fn openParsed(gpa: std.mem.Allocator, io: std.Io, cfg: connstr.Config, trust: ?*tls_trust.TlsTrust) DbError!Db {
        const conn = conn_mod.Conn.connect(gpa, io, cfg, trust) catch return DbError.OpenFailed;
        // Dev-only frozen test clock (`ZIGBASE_FAKE_NOW`) on every connection — comptime
        // no-op unless a freeze is active. Both pool writer and readers route through here.
        frozen_clock.install(conn);
        return .{ .conn = conn, .gpa = gpa };
    }
```

Also add `const std = @import("std");` is already imported — no change needed there.

- [ ] **Step 4: pool.zig — shared trust + startup warnings.** In `src/backend/postgres/pool.zig`, add imports:

```zig
const connstr = @import("connstr.zig");
const tls_trust = @import("tls_trust.zig");
```

Add a field to `Pool` (after `field_cipher`):

```zig
    /// Shared CA trust for verify-ca/verify-full (heap-pinned: the TLS handshake takes
    /// pointers into it, and `Pool` itself moves by value). Built once in `initOpts`,
    /// reused by every reader refill, destroyed in `deinit`. Null for other modes.
    trust: ?*tls_trust.TlsTrust = null,
```

Replace `initOpts` (lines 47–58) with:

```zig
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
```

In `deinit` (lines 60–68), after `self.writer.close();` add:

```zig
        if (self.trust) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
```

In `openReader` (line ~84), change `var db = try Db.open(self.allocator, self.io, self.uri);` to:

```zig
        var db = try Db.openTrusted(self.allocator, self.io, self.uri, self.trust);
```

- [ ] **Step 5: postgres.zig module-doc.** Replace the `============ SECURITY: TLS IS UN-AUTHENTICATED ============` block (the whole banner through its closing `====` line) in `src/backend/postgres/postgres.zig` with:

```zig
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
```

- [ ] **Step 6: Run both builds.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass (existing live tests still run/skip; every existing call site of `Conn.connect` is covered by the `Db.open`/`openTrusted` edits — verify with `grep -rn "Conn.connect(" src/` that `db.zig` is the only caller). Then `mise exec zig@0.16.0 -- zig build test --summary all` — expected: pass (default build untouched).

- [ ] **Step 7: Commit.**

```bash
git add src/backend/postgres/conn.zig src/backend/postgres/db.zig src/backend/postgres/pool.zig src/backend/postgres/postgres.zig
git commit -m "feat(pg)!: verified TLS handshake — verify-ca/verify-full wired end-to-end, actionable failure UX, opted-down startup warnings"
```

---

### Task 4: CI TLS coverage + live verification tests + Breaking/Security fragment

**Files:**
- Create: `src/backend/postgres/tls_pg_test.zig`
- Modify: `src/backend/postgres/postgres.zig` (test-block wiring), `.github/workflows/ci.yml` (`postgres` + `postgres-tls` jobs)
- Create: `changelog.d/pg-tls-verify.md`

**Interfaces:**
- Consumes: Task 3's `Conn.connect(gpa, io, cfg, trust)`, `ConnError.{CertUntrusted, CertHostnameMismatch, TlsRequiredButRefused}`, `tls_trust.TlsTrust`, `pgtests.getEnv`/`testUrl` from `src/backend/postgres/tests.zig`.
- Produces: env-var contracts `ZIGBASE_PG_TLS_CA` (path to the CI self-signed cert; tests skip when absent) and `ZIGBASE_PG_PLAINTEXT=1` (set in the no-TLS `postgres` job; gates the refused-TLS test).

- [ ] **Step 1: Create `src/backend/postgres/tls_pg_test.zig`:**

```zig
//! Live TLS-verification tests (SP3 Theme A). They run only when CI provides the relevant
//! environment: `ZIGBASE_PG_TLS_CA=<path to the self-signed server.crt>` in the
//! `postgres-tls` job (whose cert carries `subjectAltName=DNS:localhost`), and
//! `ZIGBASE_PG_PLAINTEXT=1` in the no-server-TLS `postgres` job. Absent env -> SKIP,
//! so `zig build test -Dpostgres=true` stays runnable anywhere.

const std = @import("std");
const pg = @import("postgres.zig");
const pgtests = @import("tests.zig");

/// Rebuild a connection URL from the suite's base URL (`tests.zig#testUrl`) with an
/// overridden host and query string. CI credentials are plain ASCII, so no re-encoding
/// is needed (the base URL's user/password are spliced back VERBATIM, undecoded).
fn urlWith(a: std.mem.Allocator, host: []const u8, query: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    var cfg = try pg.connstr.parse(a, base);
    defer cfg.deinit();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    const userinfo = base[scheme_end..at]; // verbatim (still percent-encoded if it ever was)
    const bracketed = std.mem.indexOfScalar(u8, host, ':') != null; // IPv6 literal
    return std.fmt.allocPrint(a, "postgres://{s}@{s}{s}{s}:{d}/{s}{s}", .{
        userinfo,
        if (bracketed) "[" else "",
        host,
        if (bracketed) "]" else "",
        cfg.port,
        cfg.database,
        query,
    });
}

/// Connect at the Conn level (so the PRECISE ConnError is observable — Db.open flattens
/// to OpenFailed), mirroring Db.open's ephemeral-trust logic for verify modes.
fn connectUrl(a: std.mem.Allocator, io: std.Io, url: []const u8) !*pg.Conn {
    var cfg = try pg.connstr.parse(a, url);
    defer cfg.deinit();
    if (cfg.sslmode.verifiesCertificate()) {
        var trust = try pg.tls_trust.TlsTrust.init(a, io, &cfg);
        defer trust.deinit();
        return pg.Conn.connect(a, io, cfg, &trust);
    }
    return pg.Conn.connect(a, io, cfg, null);
}

test "pg tls: verify-full + sslrootcert + DNS host succeeds end-to-end" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const query = try std.fmt.allocPrint(a, "?sslmode=verify-full&sslrootcert={s}", .{ca});
    defer a.free(query);
    const url = try urlWith(a, "localhost", query);
    defer a.free(url);
    const conn = try connectUrl(a, std.testing.io, url);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg tls: verify-full with system roots rejects the self-signed server (CertUntrusted)" {
    _ = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "localhost", "?sslmode=verify-full");
    defer a.free(url);
    try std.testing.expectError(error.CertUntrusted, connectUrl(a, std.testing.io, url));
}

test "pg tls: verify-full via an IP-literal host fails hostname verification" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const query = try std.fmt.allocPrint(a, "?sslmode=verify-full&sslrootcert={s}", .{ca});
    defer a.free(query);
    const url = try urlWith(a, "127.0.0.1", query);
    defer a.free(url);
    try std.testing.expectError(error.CertHostnameMismatch, connectUrl(a, std.testing.io, url));
}

test "pg tls: the DEFAULT mode is verify-full — a bare URL fails vs self-signed, succeeds with the CA" {
    const ca = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    // No sslmode at all -> the new default (verify-full) -> untrusted self-signed chain.
    const bare = try urlWith(a, "localhost", "");
    defer a.free(bare);
    try std.testing.expectError(error.CertUntrusted, connectUrl(a, std.testing.io, bare));
    // Same bare-mode URL + the CA -> the default verifies and connects. Pins the default.
    const query = try std.fmt.allocPrint(a, "?sslrootcert={s}", .{ca});
    defer a.free(query);
    const with_ca = try urlWith(a, "localhost", query);
    defer a.free(with_ca);
    const conn = try connectUrl(a, std.testing.io, with_ca);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg tls: sslmode=require opt-down still connects (encrypted, unverified)" {
    _ = pgtests.getEnv("ZIGBASE_PG_TLS_CA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "127.0.0.1", "?sslmode=require");
    defer a.free(url);
    const conn = try connectUrl(a, std.testing.io, url);
    defer conn.deinit();
    try std.testing.expect(conn.using_tls);
}

test "pg plaintext: the default mode refuses a no-TLS server with the actionable error" {
    // Set only in the `postgres` CI job (service container without server TLS).
    _ = pgtests.getEnv("ZIGBASE_PG_PLAINTEXT") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = try urlWith(a, "127.0.0.1", ""); // no sslmode -> default verify-full
    defer a.free(url);
    try std.testing.expectError(error.TlsRequiredButRefused, connectUrl(a, std.testing.io, url));
}
```

- [ ] **Step 2: Wire discovery.** Add `_ = @import("tls_pg_test.zig");` to the `test {}` block in `src/backend/postgres/postgres.zig` (with a `// SP3-A: live TLS-verification coverage. Skips without ZIGBASE_PG_TLS_CA / ZIGBASE_PG_PLAINTEXT.` comment).

- [ ] **Step 3: Run locally.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass; all six new tests SKIP (env absent locally).

- [ ] **Step 4: CI — `postgres-tls` job.** In `.github/workflows/ci.yml`, in the `postgres-tls` job:

(a) add the CA env var to the job `env:` block (after `ZIGBASE_PG_TEST_URL`):

```yaml
      # Points the live verify-full tests at the self-signed server cert generated below.
      ZIGBASE_PG_TLS_CA: ${{ github.workspace }}/pgtls/server.crt
```

(b) in the "Start PostgreSQL with server TLS + SCRAM" step, add a SAN to the openssl invocation so hostname verification of `localhost` can succeed:

```yaml
          openssl req -new -x509 -days 2 -nodes -text \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost" \
            -out "$PWD/pgtls/server.crt" -keyout "$PWD/pgtls/server.key"
```

(c) leave `ZIGBASE_PG_TEST_URL` on `?sslmode=require` — the whole existing suite running under `require` IS the opt-down regression pin.

NOTE: the `sudo chown 999:999` step keeps mode 644 on `server.crt`, so the runner user can still read it for `sslrootcert=`.

- [ ] **Step 5: CI — `postgres` job.** Add to that job's `env:` block:

```yaml
      # No server TLS in this job: gates the live test asserting the DEFAULT (verify-full)
      # refuses a plaintext-only server with the actionable "server refused TLS" error.
      ZIGBASE_PG_PLAINTEXT: "1"
```

Also update the comment above `ZIGBASE_PG_TEST_URL` in that job: the third line `# TLS-handshake coverage runs against a TLS-enabled local PostgreSQL during development.` becomes `# TLS-handshake + verification coverage runs in the postgres-tls job.`

- [ ] **Step 6: Changelog fragment.** Create `changelog.d/pg-tls-verify.md`:

```markdown
### Breaking
- Postgres backend (`-Dpostgres` builds): the default `sslmode` for `postgres://` URLs is now **`verify-full`** — the server certificate chain AND hostname are verified against the system root store (or `sslrootcert=<pem-path>`). A server without TLS (e.g. a docker-compose dev database) now fails **at startup** with an error naming the one-parameter fix: append `?sslmode=disable` (plaintext) or `?sslmode=require` (encrypted, unverified) to `ZIGBASE_DB_URL`. Explicitly configured modes below `verify-full` keep working and log one startup warning.

### Security
- Postgres TLS supports real server-certificate verification: `sslmode=verify-ca` / `verify-full` are accepted (previously rejected at parse time), a new `sslrootcert=<path|system>` URL parameter selects the CA bundle (built once at startup, shared by all pooled connections, fail-fast on a missing/empty bundle), certificate validity is checked against real wall-clock time, and handshake failures surface actionable startup errors (untrusted chain, hostname mismatch, expired / not-yet-valid certificate, server refused TLS) that never include the connection URL.
```

- [ ] **Step 7: Run + commit.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass (new tests skip locally; CI exercises them). Then:

```bash
git add src/backend/postgres/tls_pg_test.zig src/backend/postgres/postgres.zig .github/workflows/ci.yml changelog.d/pg-tls-verify.md
git commit -m "test(pg): live verify-full/verify-ca TLS coverage + CI SAN cert + default-mode pins; changelog fragment"
```

---

### Task 5: SASLprep range-table generator + vendored sources + generated tables

**Files:**
- Create: `scripts/gen-saslprep-tables.py`
- Create: `vendor/unicode/README.md`, `vendor/unicode/rfc3454.txt`, `vendor/unicode/nfkc-qc.txt`, `vendor/unicode/combining-class.txt` (fetched once, committed)
- Create: `src/backend/postgres/saslprep_tables.zig` (GENERATED — committed output)
- Modify: `src/backend/postgres/postgres.zig` (test-block wiring for the tables file is NOT needed — it has no tests; Task 6's `saslprep.zig` imports it and carries the sanity test)

**Interfaces:**
- Produces (in `saslprep_tables.zig`): `pub const Range = struct { lo: u21, hi: u21 };`, `pub const CccRange = struct { lo: u21, hi: u21, ccc: u8 };`, sorted non-overlapping arrays `map_to_nothing` (RFC 3454 B.1), `map_to_space` (C.1.2), `prohibited` (C.1.2 ∪ C.2.1 ∪ C.2.2 ∪ C.3–C.9), `rand_al_cat` (D.1), `l_cat` (D.2), `nfkc_qc_no_or_maybe` (UCD `NFKC_QC=N|M`), `combining_class: [N]CccRange` (UCD ccc≠0), and `pub const unicode_version = "16.0.0";`. Consumed by Task 6. RFC 3454 A.1 (unassigned) is deliberately NOT generated (spec: rejecting post-3.2 assignments like emoji would be a footgun; PG interops fine without it).

- [ ] **Step 1: Vendor the sources** (one-time fetch; the files are committed so regeneration is offline and deterministic):

```bash
mkdir -p vendor/unicode
curl -fsSL https://www.rfc-editor.org/rfc/rfc3454.txt -o vendor/unicode/rfc3454.txt
curl -fsSL https://www.unicode.org/Public/16.0.0/ucd/DerivedNormalizationProps.txt | grep "NFKC_QC" > vendor/unicode/nfkc-qc.txt
curl -fsSL https://www.unicode.org/Public/16.0.0/ucd/extracted/DerivedCombiningClass.txt | grep -E "^[0-9A-F]" | grep -vE "; +0 +#" > vendor/unicode/combining-class.txt
wc -l vendor/unicode/*.txt
```

Expected: `rfc3454.txt` ≈ 5,000 lines; `nfkc-qc.txt` a few hundred to ~1,300 lines (N + M property lines, plus `#`-comment lines containing "NFKC_QC" which the generator skips); `combining-class.txt` several hundred lines, all with a non-zero ccc.

- [ ] **Step 2: Create `vendor/unicode/README.md`:**

```markdown
# Vendored Unicode / RFC data for SASLprep table generation

Inputs to `scripts/gen-saslprep-tables.py`, which emits the checked-in
`src/backend/postgres/saslprep_tables.zig`. Do not edit these by hand.

- `rfc3454.txt` — RFC 3454 verbatim (https://www.rfc-editor.org/rfc/rfc3454.txt). The
  generator parses appendix tables B.1, C.1.2, C.2.1, C.2.2, C.3–C.9, D.1, D.2 out of the
  `----- Start Table X -----` / `----- End Table X -----` blocks. Frozen forever by the RFC.
- `nfkc-qc.txt` — the `NFKC_QC`-property lines of Unicode 16.0.0
  `DerivedNormalizationProps.txt` (https://www.unicode.org/Public/16.0.0/ucd/).
- `combining-class.txt` — the non-zero canonical-combining-class lines of Unicode 16.0.0
  `extracted/DerivedCombiningClass.txt`.

To bump the Unicode version: re-run the two `curl | grep` commands in
`docs`-recorded form (see the plan / script header), update `UNICODE_VERSION` in the
script, regenerate, and commit both the extracts and the regenerated tables file.
```

- [ ] **Step 3: Create `scripts/gen-saslprep-tables.py`:**

```python
#!/usr/bin/env python3
"""Generate src/backend/postgres/saslprep_tables.zig from vendored RFC 3454 / UCD extracts.

Usage:  mise exec python@3.13 -- python scripts/gen-saslprep-tables.py

Inputs (committed under vendor/unicode/, see its README.md):
  rfc3454.txt          - RFC 3454 verbatim; appendix tables are parsed structurally.
  nfkc-qc.txt          - UCD DerivedNormalizationProps lines containing NFKC_QC.
  combining-class.txt  - UCD extracted/DerivedCombiningClass lines with ccc != 0.

Output: sorted, coalesced [N]Range / [N]CccRange tables. Deterministic: same inputs ->
byte-identical output (dict/order-free, no timestamps).
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "unicode"
OUT = ROOT / "src" / "backend" / "postgres" / "saslprep_tables.zig"
UNICODE_VERSION = "16.0.0"

ENTRY_RE = re.compile(r"^([0-9A-F]{4,6})(?:-([0-9A-F]{4,6}))?$")
UCD_RANGE_RE = re.compile(r"^([0-9A-F]{4,6})(?:\.\.([0-9A-F]{4,6}))?$")


def parse_rfc_table(text: str, name: str) -> list[tuple[int, int]]:
    """Parse one RFC 3454 appendix table by its Start/End markers. Entry lines are
    `XXXX` / `XXXX-YYYY`, optionally followed by `; comment`; page headers/footers
    inside a table simply fail the entry regex and are skipped."""
    m = re.search(
        rf"----- Start Table {re.escape(name)} -----(.*?)----- End Table {re.escape(name)} -----",
        text,
        re.S,
    )
    if not m:
        raise SystemExit(f"RFC table {name} not found in rfc3454.txt")
    ranges: list[tuple[int, int]] = []
    for line in m.group(1).splitlines():
        first = line.split(";", 1)[0].strip()
        em = ENTRY_RE.fullmatch(first)
        if not em:
            continue
        lo = int(em.group(1), 16)
        hi = int(em.group(2), 16) if em.group(2) else lo
        ranges.append((lo, hi))
    if not ranges:
        raise SystemExit(f"RFC table {name} parsed to zero entries — format drift?")
    return ranges


def parse_ucd_ranges(path: Path, value_filter=None) -> list[tuple[int, int, str]]:
    """Parse `XXXX[..YYYY] ; value ...` UCD lines -> (lo, hi, value)."""
    out: list[tuple[int, int, str]] = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        rm = UCD_RANGE_RE.fullmatch(fields[0])
        if not rm:
            continue
        value = fields[-1]
        if value_filter is not None and not value_filter(fields):
            continue
        lo = int(rm.group(1), 16)
        hi = int(rm.group(2), 16) if rm.group(2) else lo
        out.append((lo, hi, value))
    if not out:
        raise SystemExit(f"{path.name} parsed to zero entries — refetch/format drift?")
    return out


def coalesce(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Sort + merge overlapping/adjacent ranges."""
    merged: list[list[int]] = []
    for lo, hi in sorted(ranges):
        if merged and lo <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return [(lo, hi) for lo, hi in merged]


def emit_range_table(name: str, doc: str, ranges: list[tuple[int, int]]) -> str:
    lines = [f"/// {doc}", f"pub const {name} = [_]Range{{"]
    for lo, hi in ranges:
        lines.append(f"    .{{ .lo = 0x{lo:04X}, .hi = 0x{hi:04X} }},")
    lines.append("};\n")
    return "\n".join(lines)


def main() -> None:
    rfc = (VENDOR / "rfc3454.txt").read_text()

    b1 = coalesce(parse_rfc_table(rfc, "B.1"))
    c12 = coalesce(parse_rfc_table(rfc, "C.1.2"))
    prohibited_raw: list[tuple[int, int]] = []
    for tbl in ("C.1.2", "C.2.1", "C.2.2", "C.3", "C.4", "C.5", "C.6", "C.7", "C.8", "C.9"):
        prohibited_raw += parse_rfc_table(rfc, tbl)
    prohibited = coalesce(prohibited_raw)
    d1 = coalesce(parse_rfc_table(rfc, "D.1"))
    d2 = coalesce(parse_rfc_table(rfc, "D.2"))

    # NFKC_QC = No or Maybe (field layout: cp ; NFKC_QC ; N|M).
    qc = coalesce(
        [
            (lo, hi)
            for lo, hi, _ in parse_ucd_ranges(
                VENDOR / "nfkc-qc.txt",
                value_filter=lambda f: len(f) >= 3 and f[1] == "NFKC_QC" and f[2] in ("N", "M"),
            )
        ]
    )

    # Non-zero canonical combining classes, VALUE-PRESERVING (needed for the canonical-
    # ordering half of the quick check). The ccc is field 1 of this file, so it gets its
    # own parse loop; adjacent ranges are coalesced only when their ccc is equal.
    ccc_entries: list[tuple[int, int, int]] = []
    for line in (VENDOR / "combining-class.txt").read_text().splitlines():
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [f.strip() for f in body.split(";")]
        rm = UCD_RANGE_RE.fullmatch(fields[0])
        if not rm or len(fields) < 2 or not fields[1].isdigit():
            continue
        v = int(fields[1])
        if v == 0:
            continue
        lo = int(rm.group(1), 16)
        hi = int(rm.group(2), 16) if rm.group(2) else lo
        ccc_entries.append((lo, hi, v))
    ccc_entries.sort()
    ccc_merged: list[list[int]] = []
    for lo, hi, v in ccc_entries:
        if ccc_merged and ccc_merged[-1][2] == v and lo <= ccc_merged[-1][1] + 1:
            ccc_merged[-1][1] = max(ccc_merged[-1][1], hi)
        else:
            ccc_merged.append([lo, hi, v])
    if not ccc_merged:
        raise SystemExit("combining-class.txt parsed to zero non-zero-ccc entries")

    parts: list[str] = []
    parts.append(
        "//! GENERATED by scripts/gen-saslprep-tables.py — DO NOT EDIT.\n"
        "//! Regenerate: mise exec python@3.13 -- python scripts/gen-saslprep-tables.py\n"
        f"//! Sources: RFC 3454 appendices (vendor/unicode/rfc3454.txt, frozen) + Unicode {UNICODE_VERSION}\n"
        "//! UCD extracts (vendor/unicode/nfkc-qc.txt, combining-class.txt). RFC 3454 A.1\n"
        "//! (unassigned code points) is deliberately NOT emitted — see saslprep.zig.\n\n"
        "pub const Range = struct { lo: u21, hi: u21 };\n"
        "pub const CccRange = struct { lo: u21, hi: u21, ccc: u8 };\n\n"
        f'pub const unicode_version = "{UNICODE_VERSION}";\n\n'
    )
    parts.append(emit_range_table("map_to_nothing", "RFC 3454 B.1 — mapped to nothing (soft hyphen & friends).", b1))
    parts.append(emit_range_table("map_to_space", "RFC 3454 C.1.2 — non-ASCII spaces, mapped to U+0020.", c12))
    parts.append(emit_range_table("prohibited", "RFC 4013 §2.3 prohibited output: RFC 3454 C.1.2, C.2.1, C.2.2, C.3–C.9.", prohibited))
    parts.append(emit_range_table("rand_al_cat", "RFC 3454 D.1 — RandALCat (bidi rule inputs).", d1))
    parts.append(emit_range_table("l_cat", "RFC 3454 D.2 — LCat (bidi rule inputs).", d2))
    parts.append(emit_range_table("nfkc_qc_no_or_maybe", f"UCD {UNICODE_VERSION} NFKC_Quick_Check = No or Maybe.", qc))

    lines = [f"/// UCD {UNICODE_VERSION} non-zero canonical combining classes (value-preserving).", "pub const combining_class = [_]CccRange{"]
    for lo, hi, v in ccc_merged:
        lines.append(f"    .{{ .lo = 0x{lo:04X}, .hi = 0x{hi:04X}, .ccc = {v} }},")
    lines.append("};\n")
    parts.append("\n".join(lines))

    OUT.write_text("".join(parts))
    n_ranges = sum(len(t) for t in (b1, c12, prohibited, d1, d2, qc)) + len(ccc_merged)
    print(f"wrote {OUT.relative_to(ROOT)}: 7 tables, {n_ranges} ranges (Unicode {UNICODE_VERSION})")


if __name__ == "__main__":
    main()
```

FORMAT NOTES for the executor: (1) the `parse_ucd_ranges` helper is used only for `nfkc-qc.txt` (whose value is field 2, matched by the `value_filter`); the ccc file has its value in field 1 and gets the dedicated loop above. (2) If the RFC's `Start Table` marker spelling differs by a space or capitalization from what the regex expects, adjust the regex to the actual vendored file — the `raise SystemExit` guards make any drift loud rather than silent.

- [ ] **Step 4: Generate.** Run:

```bash
mise exec python@3.13 -- python scripts/gen-saslprep-tables.py
```

Expected output: `wrote src/backend/postgres/saslprep_tables.zig: 7 tables, <N> ranges (Unicode 16.0.0)` where N is on the order of 1,500–3,000. Spot-check the file: `grep -c "\.lo = " src/backend/postgres/saslprep_tables.zig` matches N; `grep "0x00AD" src/backend/postgres/saslprep_tables.zig` shows the soft hyphen in `map_to_nothing`. Re-run the script and `git diff --stat` — expected: no diff (determinism).

- [ ] **Step 5: Compile-check.** The tables file is not imported yet; force a compile with `mise exec zig@0.16.0 -- zig ast-check src/backend/postgres/saslprep_tables.zig` — expected: no output (clean). (Full semantic compilation happens in Task 6.)

- [ ] **Step 6: Commit** (generated output IS committed — goldens are never hand-edited, and the build must not depend on Python):

```bash
git add scripts/gen-saslprep-tables.py vendor/unicode/ src/backend/postgres/saslprep_tables.zig
git commit -m "feat(pg): vendored-generated SASLprep range tables (RFC 3454 appendices + UCD 16.0.0 NFKC_QC/ccc)"
```

---

### Task 6: `saslprep.zig` — RFC 4013 prepare() with PG-parity fallback + NFKC quick-check

**Files:**
- Create: `src/backend/postgres/saslprep.zig`
- Modify: `src/backend/postgres/postgres.zig` (test-block wiring)

**Interfaces:**
- Consumes: Task 5's `saslprep_tables.zig` decls (`Range`, `CccRange`, the seven tables).
- Produces: `pub const PrepareError = error{ OutOfMemory, PasswordNeedsNormalization };`, `pub const Prepared = struct { bytes: []const u8, owned: bool, pub fn deinit(self: Prepared, allocator: std.mem.Allocator) void }`, `pub fn prepare(allocator: std.mem.Allocator, password: []const u8) PrepareError!Prepared`. Consumed by Task 7 (`scram.Client.clientFinal`).

- [ ] **Step 1: Create `src/backend/postgres/saslprep.zig`** (implementation + the full unit-vector suite; the RFC vectors ARE the failing tests — write the file, run, and iterate until green):

```zig
//! RFC 4013 SASLprep for SCRAM passwords — minimal-correct (SP3 Theme A, item 2).
//!
//! Contract (mirrors the spec exactly):
//!   1. ASCII fast path: all bytes 0x20..0x7E -> the input slice VERBATIM, zero alloc
//!      (SASLprep is the identity on printable ASCII — the overwhelmingly common case).
//!   2. Invalid UTF-8 -> PG-parity verbatim (PostgreSQL's own pg_saslprep uses the
//!      password as-is whenever prep fails, on the server AND in libpq; hard-erroring
//!      would break auth against verifiers PG itself created from such passwords).
//!   3. Mapping: RFC 3454 B.1 map-to-nothing; C.1.2 non-ASCII spaces -> U+0020.
//!      Empty result after mapping -> PG-parity verbatim.
//!   4. Prohibited output (C.1.2, C.2.1, C.2.2, C.3–C.9) or an RFC 3454 §6 bidi
//!      violation -> PG-parity verbatim. RFC 3454 A.1 (unassigned) is deliberately
//!      NOT checked: §7 permits unassigned in query strings, the assigned set has
//!      grown enormously since Unicode 3.2 (rejecting emoji passwords would be a
//!      self-inflicted footgun), and PG interops fine without it.
//!   5. NFKC — the one deliberate gap: we do NOT normalize. An NFKC quick-check
//!      (every code point NFKC_QC=Yes AND combining classes canonically ordered)
//!      proves the string is definitionally NFKC-normal, in which case the prepped
//!      string is correct as-is. Quick-check No/Maybe -> error.PasswordNeedsNormalization
//!      (never silently wrong, always loud, names the fix at the connect site).
//!
//! The bytes feed PBKDF2 either way, so the verbatim fallback is not a security
//! downgrade — it is bug-for-bug interop with PostgreSQL.

const std = @import("std");
const tables = @import("saslprep_tables.zig");

pub const PrepareError = error{
    OutOfMemory,
    /// The password's SASLprep output would require real NFKC normalization, which this
    /// driver does not perform. Surfaced at connect with an actionable message.
    PasswordNeedsNormalization,
};

pub const Prepared = struct {
    bytes: []const u8,
    /// True when `bytes` was allocated (mapping changed the string); false when it
    /// aliases the caller's input (ASCII fast path / PG-parity verbatim).
    owned: bool,

    pub fn deinit(self: Prepared, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

fn verbatim(password: []const u8) Prepared {
    return .{ .bytes = password, .owned = false };
}

fn inRanges(ranges: []const tables.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Canonical combining class of `cp` (0 for starters / anything not in the table).
fn combiningClass(cp: u21) u8 {
    const ranges = &tables.combining_class;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return ranges[mid].ccc;
    }
    return 0;
}

/// SASLprep `password`. See the module doc for the exact contract. The returned
/// `Prepared` must be `deinit`ed with the same allocator (a no-op for unowned results).
pub fn prepare(allocator: std.mem.Allocator, password: []const u8) PrepareError!Prepared {
    // 1. ASCII fast path — alias the input, zero allocation.
    var ascii = true;
    for (password) |b| {
        if (b < 0x20 or b > 0x7E) {
            ascii = false;
            break;
        }
    }
    if (ascii) return verbatim(password);

    // 2. Decode; invalid UTF-8 -> PG-parity verbatim.
    const view = std.unicode.Utf8View.init(password) catch return verbatim(password);

    // 3. Mapping (B.1 delete, C.1.2 -> space) into a code-point list.
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (inRanges(&tables.map_to_nothing, cp)) continue;
        if (inRanges(&tables.map_to_space, cp)) {
            try cps.append(allocator, ' ');
            continue;
        }
        try cps.append(allocator, cp);
    }
    if (cps.items.len == 0) return verbatim(password); // PG parity: empty result -> as-is

    // 4a. Prohibited output -> PG-parity verbatim.
    for (cps.items) |cp| {
        if (inRanges(&tables.prohibited, cp)) return verbatim(password);
    }

    // 4b. Bidi (RFC 3454 §6): with any RandALCat present, LCat is forbidden and the
    // first AND last characters must be RandALCat. Violation -> PG-parity verbatim.
    var has_ral = false;
    var has_l = false;
    for (cps.items) |cp| {
        if (inRanges(&tables.rand_al_cat, cp)) has_ral = true;
        if (inRanges(&tables.l_cat, cp)) has_l = true;
    }
    if (has_ral) {
        if (has_l) return verbatim(password);
        if (!inRanges(&tables.rand_al_cat, cps.items[0]) or
            !inRanges(&tables.rand_al_cat, cps.items[cps.items.len - 1]))
            return verbatim(password);
    }

    // 5. NFKC quick-check: any NFKC_QC No/Maybe code point, or a combining mark that is
    // not canonically ordered, means the CORRECT output requires real normalization.
    var last_ccc: u8 = 0;
    for (cps.items) |cp| {
        const c = combiningClass(cp);
        if (c != 0 and last_ccc > c) return PrepareError.PasswordNeedsNormalization;
        if (inRanges(&tables.nfkc_qc_no_or_maybe, cp)) return PrepareError.PasswordNeedsNormalization;
        last_ccc = c;
    }

    // 6. Re-encode the mapped result.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    for (cps.items) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable; // decoded above -> valid
        try out.appendSlice(allocator, buf[0..n]);
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .owned = true };
}

// --- tests: RFC 4013 §3 vectors + spec-mandated cases -----------------------------

test "saslprep: ASCII fast path is alias-identical (no alloc)" {
    const input = "correct horse battery staple";
    const p = try prepare(std.testing.allocator, input);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(!p.owned);
    try std.testing.expectEqual(input.ptr, p.bytes.ptr);
    try std.testing.expectEqualStrings(input, p.bytes);
}

test "saslprep: RFC 4013 — I<SOFT HYPHEN>X maps to IX; user/USER unchanged" {
    const a = std.testing.allocator;
    const p = try prepare(a, "I\u{00AD}X");
    defer p.deinit(a);
    try std.testing.expect(p.owned);
    try std.testing.expectEqualStrings("IX", p.bytes);

    const u1 = try prepare(a, "user");
    defer u1.deinit(a);
    try std.testing.expectEqualStrings("user", u1.bytes);
    const u2 = try prepare(a, "USER");
    defer u2.deinit(a);
    try std.testing.expectEqualStrings("USER", u2.bytes);
}

test "saslprep: NBSP maps to plain space" {
    const a = std.testing.allocator;
    const p = try prepare(a, "a\u{00A0}b");
    defer p.deinit(a);
    try std.testing.expectEqualStrings("a b", p.bytes);
}

test "saslprep: needs-NFKC code points are a HARD error (never silently wrong)" {
    const a = std.testing.allocator;
    // U+00AA FEMININE ORDINAL INDICATOR (NFKC -> "a") and U+2168 ROMAN NUMERAL NINE
    // (NFKC -> "IX"): both NFKC_QC=No.
    try std.testing.expectError(error.PasswordNeedsNormalization, prepare(a, "\u{00AA}"));
    try std.testing.expectError(error.PasswordNeedsNormalization, prepare(a, "\u{2168}"));
}

test "saslprep: prohibited output and bidi violations fall back to PG-parity verbatim" {
    const a = std.testing.allocator;
    // U+0007 BEL is C.2.1-prohibited (and outside the ASCII fast path's 0x20..0x7E).
    const bel = try prepare(a, "pass\u{0007}word");
    defer bel.deinit(a);
    try std.testing.expect(!bel.owned);
    try std.testing.expectEqualStrings("pass\u{0007}word", bel.bytes);
    // U+0627 ARABIC LETTER ALEF (RandALCat) followed by '1': last char is not RandALCat
    // -> RFC 3454 §6 violation -> verbatim (RFC 4013 §3's own failing vector).
    const bidi = try prepare(a, "\u{0627}1");
    defer bidi.deinit(a);
    try std.testing.expect(!bidi.owned);
    try std.testing.expectEqualStrings("\u{0627}1", bidi.bytes);
}

test "saslprep: invalid UTF-8 and an all-mapped-away password are verbatim" {
    const a = std.testing.allocator;
    const bad = try prepare(a, "\xff\xfe");
    defer bad.deinit(a);
    try std.testing.expect(!bad.owned);
    try std.testing.expectEqualStrings("\xff\xfe", bad.bytes);
    // Only soft hyphens -> empty mapped result -> PG parity: as-is.
    const empty = try prepare(a, "\u{00AD}\u{00AD}");
    defer empty.deinit(a);
    try std.testing.expect(!empty.owned);
}

test "saslprep: already-NFC non-ASCII passes prep unchanged (owned copy)" {
    const a = std.testing.allocator;
    const p = try prepare(a, "crème-brûlée");
    defer p.deinit(a);
    try std.testing.expectEqualStrings("crème-brûlée", p.bytes);
}

test "saslprep: generated tables are sorted and non-overlapping" {
    inline for (.{
        tables.map_to_nothing,
        tables.map_to_space,
        tables.prohibited,
        tables.rand_al_cat,
        tables.l_cat,
        tables.nfkc_qc_no_or_maybe,
    }) |table| {
        var prev_hi: u21 = 0;
        var first = true;
        for (table) |r| {
            try std.testing.expect(r.lo <= r.hi);
            if (!first) try std.testing.expect(r.lo > prev_hi);
            prev_hi = r.hi;
            first = false;
        }
    }
    var prev_hi: u21 = 0;
    var first = true;
    for (tables.combining_class) |r| {
        try std.testing.expect(r.lo <= r.hi);
        try std.testing.expect(r.ccc != 0);
        if (!first) try std.testing.expect(r.lo > prev_hi);
        prev_hi = r.hi;
        first = false;
    }
}
```

- [ ] **Step 2: Wire discovery.** Add to the `test {}` block in `src/backend/postgres/postgres.zig`:

```zig
    _ = @import("saslprep.zig");
```

- [ ] **Step 3: Run.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass with all new saslprep tests counted. If the `"crème-brûlée"` vector fails: NFC `é`/`û` must be NFKC_QC=Yes with ccc=0 — a failure here means the generator emitted a wrong table (fix Task 5's script, regenerate, re-commit the tables), NOT this file.

- [ ] **Step 4: Commit.**

```bash
git add src/backend/postgres/saslprep.zig src/backend/postgres/postgres.zig
git commit -m "feat(pg): RFC 4013 SASLprep — mapping, prohibited/bidi PG-parity fallback, NFKC quick-check hard error"
```

---

### Task 7: SCRAM integration + live SASLprep tests + fragment

**Files:**
- Modify: `src/backend/postgres/scram.zig` (header, `ScramError`, `clientFinal`, new exchange test)
- Modify: `src/backend/postgres/conn.zig` (`ConnError.PasswordNeedsNormalization`, `doScram` mapping)
- Create: `src/backend/postgres/scram_pg_test.zig`
- Modify: `src/backend/postgres/postgres.zig` (test-block wiring)
- Create: `changelog.d/pg-saslprep.md`

**Interfaces:**
- Consumes: Task 6's `saslprep.prepare(allocator, password) PrepareError!Prepared`.
- Produces: `ScramError.PasswordNeedsNormalization`; `ConnError.PasswordNeedsNormalization` (asserted by the live test at the `Conn.connect` level — `Db.open` still flattens to `OpenFailed` after the actionable log).

- [ ] **Step 1: Failing unit test first.** In `src/backend/postgres/scram.zig`, add at the bottom:

```zig
test "scram: SASLprep feeds PBKDF2 — a soft-hyphen password authenticates as its prepped form" {
    // Client uses "I\u{00AD}X"; the server stub derives its verifier from "IX" (what a
    // SASLprep-conformant PostgreSQL stores). The exchange only verifies if clientFinal
    // ran the password through prepare() before PBKDF2.
    const a = std.testing.allocator;
    var seed: [24]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i +% 11);
    var client = try Client.init(a, seed);
    defer client.deinit();

    const salt = "W22ZaJ0SNY7soEsUEjb6gQ==";
    var salt_raw: [64]u8 = undefined;
    const salt_len = try b64.Decoder.calcSizeForSlice(salt);
    try b64.Decoder.decode(salt_raw[0..salt_len], salt);
    const server_first = try std.fmt.allocPrint(a, "r={s}servernonce,s={s},i=4096", .{ client.client_nonce, salt });
    defer a.free(server_first);

    const cfinal = try client.clientFinal("I\u{00AD}X", server_first);
    defer a.free(cfinal);

    // Server side: SaltedPassword from the PREPPED password "IX".
    var server_sig: [32]u8 = undefined;
    {
        var salted: [32]u8 = undefined;
        try pbkdf2(&salted, "IX", salt_raw[0..salt_len], 4096, HmacSha256);
        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        const cfnp = try std.fmt.allocPrint(a, "c=biws,r={s}servernonce", .{client.client_nonce});
        defer a.free(cfnp);
        const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ client.client_first_bare, server_first, cfnp });
        defer a.free(auth_message);
        HmacSha256.create(&server_sig, auth_message, &server_key);
    }
    var sig_b64: [b64.Encoder.calcSize(32)]u8 = undefined;
    _ = b64.Encoder.encode(&sig_b64, &server_sig);
    const server_final = try std.fmt.allocPrint(a, "v={s}", .{&sig_b64});
    defer a.free(server_final);
    try client.verifyServerFinal(server_final);
}

test "scram: a needs-NFKC password fails clientFinal loudly" {
    const a = std.testing.allocator;
    var seed: [24]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i +% 13);
    var client = try Client.init(a, seed);
    defer client.deinit();
    const server_first = try std.fmt.allocPrint(a, "r={s}zz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", .{client.client_nonce});
    defer a.free(server_first);
    try std.testing.expectError(ScramError.PasswordNeedsNormalization, client.clientFinal("\u{2168}", server_first));
}
```

- [ ] **Step 2: Run to verify failure.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: **compile error** (`PasswordNeedsNormalization` not in `ScramError`), then after adding only the error member, the soft-hyphen test FAILS with `ServerSignatureMismatch`.

- [ ] **Step 3: Implement.** In `src/backend/postgres/scram.zig`:

(a) add the import: `const saslprep = @import("saslprep.zig");`

(b) REPLACE the header "Limitation" paragraph (lines 11–13) with:

```zig
//! Passwords are SASLprep-prepared (RFC 4013) before PBKDF2 — see `saslprep.zig` for the
//! exact contract: printable-ASCII passwords are untouched (zero-alloc identity), mapping
//! (soft hyphen removal, non-ASCII space -> space) is applied, prohibited/bidi-invalid and
//! non-UTF-8 passwords use PostgreSQL's own use-verbatim parity, and a password that would
//! require real NFKC normalization fails loudly with `ScramError.PasswordNeedsNormalization`
//! (surfaced at connect with a message naming the fix) instead of a mysterious
//! `password authentication failed`.
```

(c) add to `ScramError`:

```zig
    /// The password requires NFKC normalization (RFC 4013 SASLprep), which this driver
    /// does not perform. Supply it pre-normalized to NFKC, or use an ASCII password.
    PasswordNeedsNormalization,
```

(d) in `clientFinal`, immediately before the `// SaltedPassword = PBKDF2…` comment (line ~96), insert the prep and change the `pbkdf2` call to use it:

```zig
        // RFC 4013 SASLprep (see module header). ASCII passwords alias straight through.
        const prepped = saslprep.prepare(self.allocator, password) catch |e| switch (e) {
            error.PasswordNeedsNormalization => return ScramError.PasswordNeedsNormalization,
            error.OutOfMemory => return ScramError.OutOfMemory,
        };
        defer prepped.deinit(self.allocator);

        // SaltedPassword = PBKDF2-HMAC-SHA256(SASLprep(password), salt, i, 32)
        pbkdf2(&self.salted_password, prepped.bytes, salt, iterations, HmacSha256) catch
            return ScramError.MalformedServerFirst;
```

(The prep runs after the iteration-count guard — order within `clientFinal` before PBKDF2 is all that matters; placing it right at the PBKDF2 site keeps the DoS guard first.)

- [ ] **Step 4: conn.zig mapping.** Add to `ConnError` in `src/backend/postgres/conn.zig`:

```zig
    /// SCRAM: the password requires NFKC normalization the driver does not perform
    /// (RFC 4013). The log at the failure site names the fix.
    PasswordNeedsNormalization,
```

and in `doScram` (line ~321) replace `const client_final = client.clientFinal(cfg.password, server_first) catch return ConnError.AuthFailed;` with:

```zig
        const client_final = client.clientFinal(cfg.password, server_first) catch |e| switch (e) {
            error.PasswordNeedsNormalization => {
                std.log.err(
                    "postgres auth: the password contains Unicode that requires NFKC normalization (RFC 4013 SASLprep), which this driver does not perform. Supply the password pre-normalized to NFKC, or change it to an ASCII password.",
                    .{},
                );
                return ConnError.PasswordNeedsNormalization;
            },
            else => return ConnError.AuthFailed,
        };
```

- [ ] **Step 5: Run to verify pass.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass, including both new scram tests and every pre-existing scram test (`"pencil"` vectors are ASCII → fast-path identity, unchanged).

- [ ] **Step 6: Live tests.** Create `src/backend/postgres/scram_pg_test.zig`:

```zig
//! Live SASLprep/SCRAM tests (SP3 Theme A item 2). Require a reachable PostgreSQL whose
//! host auth is scram-sha-256 (both CI jobs force it via POSTGRES_HOST_AUTH_METHOD /
//! --auth-host); the superuser suite role creates throwaway login roles. Skips without PG.

const std = @import("std");
const pg = @import("postgres.zig");
const pgtests = @import("tests.zig");

fn adminOrSkip(a: std.mem.Allocator, io: std.Io) !?pg.Db {
    return pg.Db.open(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

/// The suite URL with the userinfo swapped for `user:pass` (verbatim splice; the fixture
/// credentials below are chosen URL-safe — no ':' '@' '/' '%').
fn urlAs(a: std.mem.Allocator, user: []const u8, pass: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(a, "{s}{s}:{s}@{s}", .{ base[0..scheme_end], user, pass, base[at + 1 ..] });
}

test "pg scram: a non-ASCII already-NFC password authenticates end-to-end" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    try admin.exec("DROP ROLE IF EXISTS zb_sasl_nfc;");
    // NFC é/è/û are SASLprep-identity (QC=Yes, ccc=0): PG stores the same bytes we send.
    try admin.exec("CREATE ROLE zb_sasl_nfc LOGIN PASSWORD 'crème-brûlée';");
    defer admin.exec("DROP ROLE IF EXISTS zb_sasl_nfc;") catch {};

    const url = try urlAs(a, "zb_sasl_nfc", "crème-brûlée");
    defer a.free(url);
    var db = try pg.Db.open(a, io, url);
    defer db.close();
    var st = try db.prepare("SELECT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
}

test "pg scram: a needs-NFKC password fails with PasswordNeedsNormalization, not a raw auth failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    try admin.exec("DROP ROLE IF EXISTS zb_sasl_nfkc;");
    // U+00AA: PG's pg_saslprep normalizes it to 'a' in the stored verifier; our client
    // refuses to guess and errors BEFORE PBKDF2 with the actionable message.
    try admin.exec("CREATE ROLE zb_sasl_nfkc LOGIN PASSWORD 'x\u{00AA}y';");
    defer admin.exec("DROP ROLE IF EXISTS zb_sasl_nfkc;") catch {};

    const url = try urlAs(a, "zb_sasl_nfkc", "x\u{00AA}y");
    defer a.free(url);
    var cfg = try pg.connstr.parse(a, url);
    defer cfg.deinit();
    // Conn level, so the PRECISE error is observable (Db.open flattens to OpenFailed).
    // Non-verifying CI sslmodes (prefer/require) -> trust=null is correct here.
    try std.testing.expect(!cfg.sslmode.verifiesCertificate());
    try std.testing.expectError(error.PasswordNeedsNormalization, pg.Conn.connect(a, io, cfg, null));
}
```

Wire it: add `_ = @import("scram_pg_test.zig");` to the `test {}` block in `src/backend/postgres/postgres.zig`.

- [ ] **Step 7: Changelog fragment.** Create `changelog.d/pg-saslprep.md`:

```markdown
### Fixes
- Postgres SCRAM authentication now applies RFC 4013 SASLprep to passwords: soft hyphens are stripped and non-ASCII spaces map to space before PBKDF2, prohibited/bidi-invalid and non-UTF-8 passwords keep PostgreSQL's own use-verbatim parity, and a password that would require NFKC normalization fails loudly at connect with a message naming the fix (previously: verbatim bytes and a mysterious `password authentication failed`). Printable-ASCII passwords are byte-identical fast-path (zero allocation).

### Security
- The SASLprep mapping/prohibited/bidi/NFKC-quick-check sets are vendored-generated range tables (`scripts/gen-saslprep-tables.py` over the frozen RFC 3454 appendices + Unicode 16.0.0 UCD extracts) — auditable binary-search tables, mechanical to bump.
```

- [ ] **Step 8: Run + commit.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` (live tests skip without PG; CI's `postgres` job exercises them) and `mise exec zig@0.16.0 -- zig build test --summary all` — expected: both pass.

```bash
git add src/backend/postgres/scram.zig src/backend/postgres/conn.zig src/backend/postgres/scram_pg_test.zig src/backend/postgres/postgres.zig changelog.d/pg-saslprep.md
git commit -m "feat(pg): SASLprep wired into SCRAM clientFinal + live NFC/needs-NFKC coverage; changelog fragment"
```

---

### Task 8: dumpload — `planCreateOrder` (Kahn + cycle edges), pure + unit-tested

**Files:**
- Modify: `src/dumpload.zig` (rework `collectionCreateOrder` → `planCreateOrder`; update `tableLoadOrder`; tests)

**Interfaces:**
- Consumes: existing `schema.Collection` / `schema.Field` shapes (relation options: `targetCollectionId`, `cascadeDelete`, `maxSelect`).
- Produces: `pub const CycleEdge = struct { col_idx: usize, field_idx: usize };`, `pub const CreatePlan = struct { order: []usize, cycle_edges: []CycleEdge };`, `fn planCreateOrder(a: std.mem.Allocator, cols: []const schema.Collection) Error!CreatePlan` (arena-allocated, no free needed). `collectionCreateOrder` is DELETED (both former call sites move to `planCreateOrder`). Consumed by Tasks 9, 10.

- [ ] **Step 1: Write the failing tests.** Append to `src/dumpload.zig`'s test section:

```zig
// --- planCreateOrder (pure cycle detection) ---------------------------------------

fn relField(comptime id: []const u8, comptime name: []const u8, comptime target: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .relation = .{ .targetCollectionId = target, .maxSelect = 1 } } };
}

test "dumpload: planCreateOrder — acyclic graph orders dependencies first, zero cycle edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const post_fields = [_]schema.Field{relField("f1", "author", "authors")};
    const cols = [_]schema.Collection{
        .{ .id = "c_posts", .name = "posts", .fields = &post_fields },
        .{ .id = "c_auth", .name = "authors", .fields = &.{} },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges.len);
    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    try std.testing.expectEqual(@as(usize, 1), plan.order[0]); // authors first
    try std.testing.expectEqual(@as(usize, 0), plan.order[1]); // then posts
}

test "dumpload: planCreateOrder — a self-relation is ALWAYS a cycle edge (but places normally)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const node_fields = [_]schema.Field{relField("f1", "parent", "nodes")};
    const cols = [_]schema.Collection{
        .{ .id = "c_nodes", .name = "nodes", .fields = &node_fields },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 1), plan.order.len);
    try std.testing.expectEqual(@as(usize, 1), plan.cycle_edges.len);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges[0].col_idx);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges[0].field_idx);
}

test "dumpload: planCreateOrder — 2-cycle and 3-cycle mark every in-cycle edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    {
        const af = [_]schema.Field{relField("f1", "buddy", "beta")};
        const bf = [_]schema.Field{relField("f2", "buddy", "alpha")};
        const cols = [_]schema.Collection{
            .{ .id = "c_a", .name = "alpha", .fields = &af },
            .{ .id = "c_b", .name = "beta", .fields = &bf },
        };
        const plan = try planCreateOrder(al, &cols);
        try std.testing.expectEqual(@as(usize, 2), plan.order.len); // both still created
        try std.testing.expectEqual(@as(usize, 2), plan.cycle_edges.len);
    }
    {
        const xf = [_]schema.Field{relField("f1", "next", "y")};
        const yf = [_]schema.Field{relField("f2", "next", "z")};
        const zf = [_]schema.Field{relField("f3", "next", "x")};
        const cols = [_]schema.Collection{
            .{ .id = "c_x", .name = "x", .fields = &xf },
            .{ .id = "c_y", .name = "y", .fields = &yf },
            .{ .id = "c_z", .name = "z", .fields = &zf },
        };
        const plan = try planCreateOrder(al, &cols);
        try std.testing.expectEqual(@as(usize, 3), plan.cycle_edges.len);
    }
}

test "dumpload: planCreateOrder — a diamond feeding a cycle only defers the in-cycle edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    // base <- x, base <- y (acyclic diamond); a -> {x, b}, b -> {y, a} (a/b cycle).
    const xf = [_]schema.Field{relField("f1", "root", "base")};
    const yf = [_]schema.Field{relField("f2", "root", "base")};
    const af = [_]schema.Field{ relField("f3", "via", "x"), relField("f4", "pair", "b") };
    const bf = [_]schema.Field{ relField("f5", "via", "y"), relField("f6", "pair", "a") };
    const cols = [_]schema.Collection{
        .{ .id = "c_base", .name = "base", .fields = &.{} },
        .{ .id = "c_x", .name = "x", .fields = &xf },
        .{ .id = "c_y", .name = "y", .fields = &yf },
        .{ .id = "c_a", .name = "a", .fields = &af },
        .{ .id = "c_b", .name = "b", .fields = &bf },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 5), plan.order.len);
    // ONLY a.pair and b.pair are cycle edges — a.via/b.via point at placed (acyclic) nodes.
    try std.testing.expectEqual(@as(usize, 2), plan.cycle_edges.len);
    for (plan.cycle_edges) |e| {
        const f = cols[e.col_idx].fields[e.field_idx];
        try std.testing.expectEqualStrings("pair", f.name);
    }
}
```

- [ ] **Step 2: Run to verify failure.** `mise exec zig@0.16.0 -- zig build test --summary all` — expected: compile error (`planCreateOrder` undefined).

- [ ] **Step 3: Implement.** In `src/dumpload.zig`, REPLACE `collectionCreateOrder` (lines 211–231) with:

```zig
pub const CycleEdge = struct { col_idx: usize, field_idx: usize };

pub const CreatePlan = struct {
    /// Collection indices in creation order. Every collection appears exactly once;
    /// cycle members are appended in declaration order after the acyclic prefix.
    order: []usize,
    /// Single-relation fields that participate in a dependency cycle — every relation
    /// edge between two Kahn leftovers (conservative) plus EVERY self-relation (its DDL
    /// is legal inline, but its rows still need COMMIT-time deferral):
    /// `cols[e.col_idx].fields[e.field_idx]`. Empty for an acyclic graph.
    cycle_edges: []CycleEdge,
};

/// Kahn-style creation plan over the collection relation graph. Pure (arena-allocating,
/// no I/O) so cycle handling is unit-testable. The nodes Kahn cannot place form the
/// cyclic core; on Postgres their in-cycle FK edges are provisioned as deferrable
/// `ALTER TABLE ADD CONSTRAINT`s instead of inline REFERENCES (see provisionRecordTables).
fn planCreateOrder(a: std.mem.Allocator, cols: []const schema.Collection) Error!CreatePlan {
    const n = cols.len;
    const placed = try a.alloc(bool, n);
    @memset(placed, false);
    var order: std.ArrayList(usize) = .empty;
    var progress = true;
    while (order.items.len < n and progress) {
        progress = false;
        for (cols, 0..) |c, i| {
            if (placed[i]) continue;
            if (depsPlaced(cols, c, placed)) {
                try order.append(a, i);
                placed[i] = true;
                progress = true;
            }
        }
    }

    // Cycle edges: FK-bearing (single) relations where BOTH endpoints are Kahn leftovers,
    // plus every self-relation regardless of placement.
    var cycle_edges: std.ArrayList(CycleEdge) = .empty;
    for (cols, 0..) |c, i| {
        for (c.fields, 0..) |f, fi| switch (f.options) {
            .relation => |r| {
                if (r.maxSelect != 1) continue; // multi-relations carry no FK
                const j = findCollection(cols, r.targetCollectionId) orelse continue;
                if (i == j) {
                    try cycle_edges.append(a, .{ .col_idx = i, .field_idx = fi });
                } else if (!placed[i] and !placed[j]) {
                    try cycle_edges.append(a, .{ .col_idx = i, .field_idx = fi });
                }
            },
            else => {},
        };
    }

    // Append the cyclic core in declaration order (its tables are still created — only
    // the in-cycle FK clauses are handled specially) and log the members once.
    var had_cycle = false;
    for (0..n) |i| {
        if (!placed[i]) {
            if (!had_cycle) {
                had_cycle = true;
                std.log.info("migrate-db: relation cycle detected; deferring its FK edges to COMMIT. Members:", .{});
            }
            std.log.info("migrate-db:   cycle member '{s}'", .{cols[i].name});
            try order.append(a, i);
        }
    }
    return .{
        .order = try order.toOwnedSlice(a),
        .cycle_edges = try cycle_edges.toOwnedSlice(a),
    };
}

/// Index of the collection whose id OR name equals `target` (relation targets are stored
/// either way), or null for out-of-set targets (e.g. system `_superusers`).
fn findCollection(cols: []const schema.Collection, target: []const u8) ?usize {
    for (cols, 0..) |c, j| {
        if (std.mem.eql(u8, c.id, target) or std.mem.eql(u8, c.name, target)) return j;
    }
    return null;
}
```

(`depsPlaced` is unchanged.) Update the two former call sites of `collectionCreateOrder`:

- `provisionRecordTables` line ~165: `const order = try collectionCreateOrder(a, src_cols);` → `const plan = try planCreateOrder(a, src_cols);` and the loop header `for (order) |idx|` → `for (plan.order) |idx|` (Task 9 rewrites this function further — for THIS task just keep it compiling with inline FKs as before).
- `tableLoadOrder` line ~467: `const order = try collectionCreateOrder(a, src_cols);` → `const order = (try planCreateOrder(a, src_cols)).order;`

- [ ] **Step 4: Run to verify pass.** `mise exec zig@0.16.0 -- zig build test --summary all` — expected: pass (all four new tests + all pre-existing dumpload tests; behavior is unchanged so far). Also `-Dpostgres=true` variant — expected: pass.

- [ ] **Step 5: Commit.**

```bash
git add src/dumpload.zig
git commit -m "refactor(dumpload): planCreateOrder — Kahn ordering with explicit, unit-tested cycle edges"
```

---

### Task 9: DDL — `skip_fk_fields` + deferrable ALTER for cycle edges (Postgres arm)

**Files:**
- Modify: `src/ddl.zig` (`createTableSql` signature + `addDeferrableFkSql` + tests)
- Modify: `src/collections.zig` (call-site update, line ~55)
- Modify: `src/dumpload.zig` (`provisionRecordTables` restructure)

**Interfaces:**
- Consumes: Task 8's `CreatePlan`/`CycleEdge`.
- Produces: `ddl.createTableSql(alloc: std.mem.Allocator, c: schema.Collection, single_rel_target: ?[]const u8, d: dialect.Dialect, skip_fk_fields: []const []const u8) ![]u8` (pass `&.{}` for "no skips" — ALL existing call sites); `pub fn addDeferrableFkSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8, target: []const u8, cascade_delete: bool) ![]u8`. Consumed by Task 10/11 behavior.

- [ ] **Step 1: Failing tests.** In `src/ddl.zig`, add:

```zig
test "createTableSql omits the FK clause for skip_fk_fields (cycle edges) but keeps the column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
        .{ .id = "b", .name = "pair", .options = .{ .relation = .{ .targetCollectionId = "twins", .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    const sql = try createTableSql(a, col, null, .postgres, &.{"pair"});
    // The skipped edge keeps its COLUMN (data still loads) but loses the inline FK.
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"pair\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"pair\")") == null);
    // The non-cycle FK is unchanged.
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"author\") REFERENCES \"users\" (\"id\") ON DELETE SET NULL") != null);
}

test "addDeferrableFkSql matches rebuildPlanPg naming and emits DEFERRABLE INITIALLY IMMEDIATE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_pair\" FOREIGN KEY (\"pair\") REFERENCES \"twins\" (\"id\") ON DELETE SET NULL DEFERRABLE INITIALLY IMMEDIATE;",
        try addDeferrableFkSql(a, "posts", "pair", "twins", false),
    );
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_pair\" FOREIGN KEY (\"pair\") REFERENCES \"twins\" (\"id\") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;",
        try addDeferrableFkSql(a, "posts", "pair", "twins", true),
    );
}
```

- [ ] **Step 2: Run to verify failure.** `mise exec zig@0.16.0 -- zig build test --summary all` — expected: compile error (`createTableSql` arity / `addDeferrableFkSql` undefined).

- [ ] **Step 3: Implement ddl.zig.** Change `createTableSql`'s signature and FK loop (lines 62–88):

```zig
fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn createTableSql(alloc: std.mem.Allocator, c: schema.Collection, single_rel_target: ?[]const u8, d: dialect.Dialect, skip_fk_fields: []const []const u8) ![]u8 {
```

…body unchanged until the FK loop, which becomes:

```zig
    for (c.fields) |f| {
        switch (f.options) {
            // skip_fk_fields (migrate-db cycle edges, Postgres target): the COLUMN was
            // already emitted above — only the inline FK clause is omitted; the caller
            // adds it back post-creation via `addDeferrableFkSql`.
            .relation => |r| if (r.maxSelect == 1 and !nameIn(skip_fk_fields, f.name)) {
                const target = single_rel_target orelse r.targetCollectionId;
                const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"id\") ON DELETE {s}", .{ f.name, target, on_delete }));
            },
            else => {},
        }
    }
```

Add after `authIdentityIndexSql`:

```zig
/// A deferrable FK added AFTER table creation for a relation edge that participates in a
/// dependency cycle (migrate-db, Postgres target — cyclic inline REFERENCES cannot be
/// created in any order there). `DEFERRABLE INITIALLY IMMEDIATE` behaves identically to a
/// plain FK outside an explicit `SET CONSTRAINTS`, so the running server sees no semantic
/// drift; it exists purely so the load transaction can defer it to COMMIT. The constraint
/// name matches `rebuildPlanPg`'s `fk_<table>_<field>` convention.
pub fn addDeferrableFkSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8, target: []const u8, cascade_delete: bool) ![]u8 {
    const on_delete = if (cascade_delete) "CASCADE" else "SET NULL";
    return std.fmt.allocPrint(
        alloc,
        "ALTER TABLE \"{s}\" ADD CONSTRAINT \"fk_{s}_{s}\" FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"id\") ON DELETE {s} DEFERRABLE INITIALLY IMMEDIATE;",
        .{ table, table, field, field, target, on_delete },
    );
}
```

Update the OTHER `createTableSql` call sites to pass `&.{}` (no skips):
- `src/ddl.zig` line ~150 (inside `rebuildPlan`): `try stmts.append(alloc, try createTableSql(alloc, tmp_col, null, d, &.{}));`
- `src/ddl.zig` existing tests (two `createTableSql(…)` calls at lines ~277 and ~298): append `, &.{}`.
- `src/collections.zig` line ~55: `try w.exec(try alloc.dupeZ(u8, try ddl.createTableSql(alloc, ddl_col, null, d, &.{})));`
- `src/dumpload.zig` line ~174 — handled in Step 4.
- Confirm coverage: `grep -rn "createTableSql(" src/` must show only these files.

- [ ] **Step 4: Restructure `provisionRecordTables`** in `src/dumpload.zig` (replace the whole function):

```zig
/// Create, on `target`, the physical record table for every source collection whose table
/// does not yet exist (system collections' tables come from the migrations), in
/// dependency order. On a POSTGRES target, relation-cycle FK edges are OMITTED from
/// CREATE TABLE (cyclic inline REFERENCES cannot be created in any order there) and added
/// back afterwards as `DEFERRABLE INITIALLY IMMEDIATE` constraints — identical to a plain
/// FK outside explicit SET CONSTRAINTS, deferrable by the load transaction. SQLite permits
/// forward/cyclic inline FK DDL natively, so its DDL is unchanged. Returns the count created.
fn provisionRecordTables(a: std.mem.Allocator, target: *db.Db, src_cols: []const schema.Collection) Error!usize {
    const d = db.dbDialect(target);
    var id_to_name = std.StringHashMap([]const u8).init(a);
    for (src_cols) |c| try id_to_name.put(c.id, c.name);

    const plan = try planCreateOrder(a, src_cols);
    const defer_cycle_fks = db.dbBackend(target) == .postgres;
    const created_flags = try a.alloc(bool, src_cols.len);
    @memset(created_flags, false);

    var created: usize = 0;
    for (plan.order) |idx| {
        const col = src_cols[idx];
        if (try tableExists(a, target, col.name)) continue; // system tables already exist
        const full = try schema.injectAuthFields(a, col);
        const ddl_col = try resolveRelationTargets(a, full, id_to_name);
        const skip: []const []const u8 = if (defer_cycle_fks) try cycleFieldNames(a, plan.cycle_edges, src_cols, idx) else &.{};
        try target.exec(try a.dupeZ(u8, try ddl.createTableSql(a, ddl_col, null, d, skip)));
        for (col.indexes) |ix| target.exec(try a.dupeZ(u8, try ddl.createIndexSql(a, col.name, ix, d))) catch |e| {
            std.log.warn("migrate-db: index '{s}' on '{s}' skipped ({s})", .{ ix.name, col.name, @errorName(e) });
        };
        if (col.type == .auth) {
            for (col.options.auth.identityFields) |idf|
                try target.exec(try a.dupeZ(u8, try ddl.authIdentityIndexSql(a, col.name, idf)));
        }
        created_flags[idx] = true;
        created += 1;
    }

    // Add the omitted cycle-edge FKs back, deferrable, now that every table exists.
    // Only for tables created THIS run — a pre-existing table keeps its constraints.
    if (defer_cycle_fks) {
        for (plan.cycle_edges) |e| {
            if (!created_flags[e.col_idx]) continue;
            const col = src_cols[e.col_idx];
            const f = col.fields[e.field_idx];
            const r = f.options.relation;
            const tgt = id_to_name.get(r.targetCollectionId) orelse r.targetCollectionId;
            const sql = try ddl.addDeferrableFkSql(a, col.name, f.name, tgt, r.cascadeDelete);
            target.exec(try a.dupeZ(u8, sql)) catch |err| {
                std.log.err(
                    "migrate-db: could not add deferrable FK \"fk_{s}_{s}\" on \"{s}\"(\"{s}\") -> \"{s}\"(\"id\"): {s}. Fix the target schema (or use a superuser target role) and re-run.",
                    .{ col.name, f.name, col.name, f.name, tgt, @errorName(err) },
                );
                return err;
            };
        }
    }
    return created;
}

/// Field names of `col_idx`'s cycle edges — the FK clauses `createTableSql` must omit.
fn cycleFieldNames(a: std.mem.Allocator, edges: []const CycleEdge, cols: []const schema.Collection, col_idx: usize) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (edges) |e| {
        if (e.col_idx == col_idx) try out.append(a, cols[col_idx].fields[e.field_idx].name);
    }
    return out.toOwnedSlice(a);
}
```

- [ ] **Step 5: Run.** `mise exec zig@0.16.0 -- zig build test --summary all` then the `-Dpostgres=true` variant — expected: both pass (SQLite round-trips are unaffected: `defer_cycle_fks` is false there; existing live-PG dumpload test still passes — its authors/notes fixture is acyclic).

- [ ] **Step 6: Commit.**

```bash
git add src/ddl.zig src/collections.zig src/dumpload.zig
git commit -m "feat(dumpload): provision cycle-edge FKs as DEFERRABLE INITIALLY IMMEDIATE on Postgres targets"
```

---

### Task 10: dumpload load phase — defer constraints to COMMIT + actionable cycle error

**Files:**
- Modify: `src/dumpload.zig` (`run`, new `deferForeignKeys` + `logDeferredFkCommitFailure`, SQLite round-trip test)

**Interfaces:**
- Consumes: Tasks 8–9.
- Produces: `fn deferForeignKeys(d: *db.Db) Error!void` (Postgres: `SET CONSTRAINTS ALL DEFERRED;`, SQLite: `PRAGMA defer_foreign_keys=ON;` — the ONE default-binary line in this whole theme). Commit failures with a cyclic schema log the actionable rollback message naming the cycle members.

- [ ] **Step 1: Failing test.** Add to `src/dumpload.zig`:

```zig
test "dumpload: self-referential relation rows load in any order (defer_foreign_keys)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    const col = schema.Collection{ .id = "_", .name = "nodes", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "nodes", .maxSelect = 1 } } },
    } };
    _ = try collections.create(al, io, &source, col);
    // r1 references the LATER row r2: with foreign_keys=ON and no deferral, copying in
    // natural order would fail at the first INSERT. defer_foreign_keys validates at COMMIT.
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"title\",\"parent\") VALUES ('r1','t','t','child','r2');");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"title\",\"parent\") VALUES ('r2','t','t','root',NULL);");

    var target = try db.Db.openMemory();
    defer target.close();
    // The production pool writer runs with foreign_keys=ON (backend/sqlite/db.zig); the
    // bare test handle does not, so enable it here or the test proves nothing.
    try target.exec("PRAGMA foreign_keys=ON;");

    const report = try run(a, &source, &target, .{});
    defer report.deinit(a);

    var st = try target.prepare("SELECT \"parent\" FROM \"nodes\" WHERE \"id\"='r1';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("r2", st.columnText(0));
}
```

- [ ] **Step 2: Run to verify failure.** `mise exec zig@0.16.0 -- zig build test --summary all` — expected: the new test FAILS inside `run` (FK violation on the r1 INSERT — `copyTable` returns an exec/step error), because nothing defers FK checks yet.

- [ ] **Step 3: Implement.** In `src/dumpload.zig`:

(a) after `restoreForeignKeys` (line ~456), add:

```zig
/// The non-superuser path: instead of suspending FK enforcement, defer constraint
/// checking to COMMIT inside the (already-open) load transaction. Postgres:
/// `SET CONSTRAINTS ALL DEFERRED` — no privilege required, affects only DEFERRABLE
/// constraints, i.e. exactly the cycle-edge FKs provisioned by provisionRecordTables.
/// SQLite: `PRAGMA defer_foreign_keys=ON` — transaction-scoped, auto-resets at COMMIT
/// (SQLite's inline FK DDL is already cycle-capable; only row order needs this).
fn deferForeignKeys(d: *db.Db) Error!void {
    switch (db.dbBackend(d)) {
        .postgres => try d.exec("SET CONSTRAINTS ALL DEFERRED;"),
        .sqlite => try d.exec("PRAGMA defer_foreign_keys=ON;"),
    }
}

/// A COMMIT failure on the deferred-constraint path means a dangling reference in the
/// source data — the ONLY hard error left in the non-superuser design. Name the cycle
/// members so the operator can find it. (Errors are logged here, then the DbError
/// propagates; the CLI wrapper prints its usual abort message.)
fn logDeferredFkCommitFailure(a: std.mem.Allocator, src_cols: []const schema.Collection) void {
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(a);
    if (planCreateOrder(a, src_cols)) |plan| {
        for (plan.cycle_edges) |e| {
            const n = src_cols[e.col_idx].name;
            if (std.mem.indexOf(u8, names.items, n) != null) continue;
            if (names.items.len > 0) names.appendSlice(a, ", ") catch break;
            names.appendSlice(a, n) catch break;
        }
    } else |_| {}
    std.log.err(
        "migrate-db: foreign-key cycle across collections [{s}] could not be satisfied at commit — a row references a missing target. The target was rolled back; fix the dangling reference in the source (or use a superuser target role) and re-run.",
        .{names.items},
    );
}
```

(b) in `run`, after `const fk_suspended = suspendForeignKeys(target);` (line ~104) add:

```zig
    if (!fk_suspended) try deferForeignKeys(target);
```

(c) replace the commit tail (lines ~134–135):

```zig
    if (fk_suspended) restoreForeignKeys(target);
    target.commit() catch |e| {
        if (!fk_suspended) logDeferredFkCommitFailure(a, src_cols);
        return e;
    };
```

(The existing `errdefer target.rollback() catch {};` already covers the rollback.)

- [ ] **Step 4: Run to verify pass.** `mise exec zig@0.16.0 -- zig build test --summary all` — expected: pass (new self-ref test green; all prior dumpload tests unchanged — `deferForeignKeys` on SQLite is a no-op for acyclic data). Then `-Dpostgres=true` variant — expected: pass.

- [ ] **Step 5: Commit.**

```bash
git add src/dumpload.zig
git commit -m "feat(dumpload): defer FK validation to COMMIT on the non-superuser path (SET CONSTRAINTS / defer_foreign_keys)"
```

---

### Task 11: Live-PG NOSUPERUSER migrate-db fixtures + fragment

**Files:**
- Modify: `src/backend/postgres/dumpload_pg_test.zig` (append the new tests; reuse its `enterTempSchema` helpers where noted)
- Create: `changelog.d/pg-migrate-deferred-fk.md`

**Interfaces:**
- Consumes: Tasks 8–10; `dbm.Db.openPostgres(a, io, url)` and the existing helpers in `dumpload_pg_test.zig` (`openTargetOrSkip`, `countPg`); `pgtests.testUrl()`.
- Produces: CI-verified behavior only (no new API).

- [ ] **Step 1: Append the fixtures to `src/backend/postgres/dumpload_pg_test.zig`.** Add near the top (after the existing helpers):

```zig
/// The suite URL with the userinfo swapped for `user:pass` (fixture credentials are
/// URL-safe ASCII; the rest of the URL — host/port/db/sslmode — is spliced verbatim so
/// the test works under both CI jobs' sslmodes).
fn urlAs(a: std.mem.Allocator, user: []const u8, pass: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(a, "{s}{s}:{s}@{s}", .{ base[0..scheme_end], user, pass, base[at + 1 ..] });
}

/// Create a NOSUPERUSER login role + a schema it owns; connect as it; pin search_path.
/// Caller must run `dropNosuper(admin, al, schema_name, role)` in a defer.
fn openNosuperTarget(al: std.mem.Allocator, admin: *dbm.Db, io: std.Io, schema_name: []const u8, role: []const u8) !dbm.Db {
    try admin.exec(try std.fmt.allocPrintSentinel(al, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{schema_name}, 0));
    try admin.exec(try std.fmt.allocPrintSentinel(al, "DROP ROLE IF EXISTS \"{s}\";", .{role}, 0));
    try admin.exec(try std.fmt.allocPrintSentinel(al, "CREATE ROLE \"{s}\" LOGIN PASSWORD 'zb_dl_pw' NOSUPERUSER;", .{role}, 0));
    try admin.exec(try std.fmt.allocPrintSentinel(al, "CREATE SCHEMA \"{s}\" AUTHORIZATION \"{s}\";", .{ schema_name, role }, 0));
    const url = try urlAs(al, role, "zb_dl_pw");
    var target = try dbm.Db.openPostgres(std.testing.allocator, io, url);
    errdefer target.close();
    try target.exec(try std.fmt.allocPrintSentinel(al, "SET search_path TO \"{s}\";", .{schema_name}, 0));
    return target;
}

fn dropNosuper(admin: *dbm.Db, al: std.mem.Allocator, schema_name: []const u8, role: []const u8) void {
    // Schema (owned objects) must go before the role.
    const s1 = std.fmt.allocPrintSentinel(al, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{schema_name}, 0) catch return;
    admin.exec(s1) catch {};
    const s2 = std.fmt.allocPrintSentinel(al, "DROP ROLE IF EXISTS \"{s}\";", .{role}, 0) catch return;
    admin.exec(s2) catch {};
}

/// Source SQLite with a self-referential collection ("nodes": r1.parent -> r2) and a
/// mutual 2-cycle ("alpha" <-> "beta": a1.buddy -> b1, b1.buddy -> a1 — both non-NULL,
/// which NULL-then-UPDATE could never load). `dangling` additionally points a1.buddy at
/// a missing id to exercise the COMMIT-time rollback.
fn buildCyclicSource(al: std.mem.Allocator, io: std.Io, dangling: bool) !dbm.Db {
    var source = try dbm.Db.openMemory();
    errdefer source.close();
    try migrations.run(&source);

    const nodes = schema.Collection{ .id = "_", .name = "nodes", .fields = &[_]schema.Field{
        .{ .id = "n1", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "nodes", .maxSelect = 1 } } },
    } };
    _ = try collections.create(al, io, &source, nodes);
    const alpha = schema.Collection{ .id = "_", .name = "alpha", .fields = &[_]schema.Field{
        .{ .id = "a1", .name = "buddy", .options = .{ .relation = .{ .targetCollectionId = "beta", .maxSelect = 1 } } },
    } };
    const created_alpha = try collections.create(al, io, &source, alpha);
    const beta = schema.Collection{ .id = "_", .name = "beta", .fields = &[_]schema.Field{
        .{ .id = "b1", .name = "buddy", .options = .{ .relation = .{ .targetCollectionId = created_alpha.id, .maxSelect = 1 } } },
    } };
    _ = try collections.create(al, io, &source, beta);

    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"parent\") VALUES ('r1','t','t','r2');");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"parent\") VALUES ('r2','t','t',NULL);");
    if (dangling) {
        try source.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a1','t','t','b_missing');");
    } else {
        try source.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a1','t','t','b1');");
    }
    try source.exec("INSERT INTO \"beta\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('b1','t','t','a1');");
    return source;
}
```

(If `collections.create` in the current tree resolves relation targets by NAME as well as id — it does for the by-name case per `depsPlaced`'s dual matching — the `created_alpha.id` indirection for `beta.buddy` keeps the fixture honest for the stored-id form; `nodes`/`alpha` use the by-name form, so both resolutions are covered. Read `collections.create` before adapting if it rejects one of the forms.)

Then the tests:

```zig
test "pg dumpload: NOSUPERUSER target loads self-referential + mutual non-nullable cycles via deferred FKs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var admin = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    var target = try openNosuperTarget(al, &admin, io, "zb_dl_ns1", "zb_dl_nosuper1");
    defer target.close();
    defer dropNosuper(&admin, al, "zb_dl_ns1", "zb_dl_nosuper1");

    var source = try buildCyclicSource(al, io, false);
    defer source.close();

    // As NOSUPERUSER, `SET session_replication_role = replica` fails -> the deferred path
    // runs (a warning is logged; the report is the observable contract here).
    const report = try dumpload.run(a, &source, &target, .{});
    defer report.deinit(a);

    try std.testing.expectEqual(@as(i64, 2), try countPg(al, &target, "nodes"));
    try std.testing.expectEqual(@as(i64, 1), try countPg(al, &target, "alpha"));
    try std.testing.expectEqual(@as(i64, 1), try countPg(al, &target, "beta"));

    // The cycle-edge constraints exist AND are deferrable…
    var st = try target.prepare("SELECT count(*) FROM pg_constraint WHERE conname IN ('fk_alpha_buddy','fk_beta_buddy','fk_nodes_parent') AND condeferrable;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0));

    // …and INITIALLY IMMEDIATE: outside the load transaction they enforce like plain FKs.
    try std.testing.expectError(
        dbm.DbError.ExecFailed,
        target.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a2','t','t','nope');"),
    );
}

test "pg dumpload: a dangling cyclic reference rolls the whole load back at COMMIT" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var admin = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    var target = try openNosuperTarget(al, &admin, io, "zb_dl_ns2", "zb_dl_nosuper2");
    defer target.close();
    defer dropNosuper(&admin, al, "zb_dl_ns2", "zb_dl_nosuper2");

    var source = try buildCyclicSource(al, io, true);
    defer source.close();

    // a1.buddy -> 'b_missing': every INSERT succeeds (deferred), COMMIT fails, run() logs
    // the actionable cycle message and propagates the DbError.
    try std.testing.expectError(dbm.DbError.ExecFailed, dumpload.run(a, &source, &target, .{}));

    // Rolled back: schema provisioned (pre-transaction), zero migrated rows.
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "alpha"));
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "beta"));
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "nodes"));
}
```

NOTE: `dumpload.run`'s error set unions `db.DbError`, so `expectError(dbm.DbError.ExecFailed, …)` compiles; if the seam maps the commit failure to a different `DbError` member in practice, assert THAT member — the contract under test is "run fails + target has zero rows + the log names the cycle", not the exact member name.

- [ ] **Step 2: Run locally.** `mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true` — expected: pass (both tests SKIP without a live PG; with a local PG they run for real). If a local PG is available, also eyeball the log for `migrate-db: relation cycle detected` + the member lines and, in the dangling case, the `foreign-key cycle across collections [alpha, beta, nodes] could not be satisfied at commit` error.

- [ ] **Step 3: Changelog fragment.** Create `changelog.d/pg-migrate-deferred-fk.md`:

```markdown
### Fixes
- `migrate-db` onto a **non-superuser** Postgres role (AWS RDS, Cloud SQL, Neon, …) now loads cyclic and self-referential relation graphs correctly: cycle-edge foreign keys are provisioned as `DEFERRABLE INITIALLY IMMEDIATE` and the load transaction defers them to COMMIT (`SET CONSTRAINTS ALL DEFERRED`; SQLite targets use `PRAGMA defer_foreign_keys=ON`), so rows load in any order — including fully non-nullable cycles. A dangling reference rolls the whole load back with an error naming the cycle members. The non-superuser path is now fully supported and CI-verified (previously a lightly-tested topological fallback); the superuser fast path is unchanged and remains the fastest route.
```

- [ ] **Step 4: Commit.**

```bash
git add src/backend/postgres/dumpload_pg_test.zig changelog.d/pg-migrate-deferred-fk.md
git commit -m "test(pg): NOSUPERUSER migrate-db fixtures — deferred-FK cycles, INITIALLY IMMEDIATE enforcement, dangling-ref rollback"
```

---

### Task 12: Docs, site mirrors, KNOWN_LIMITATIONS — the caveat flips

**Files:**
- Modify: `docs/postgres.md` (~55–58 TLS caveat; ~87–90 migrate-db caveat) + `site/src/content/docs/postgres.md` (same content at ~60–63 / ~92–95; the site file has 5 lines of frontmatter offset)
- Modify: `site/src/content/docs/configuration.md` (line ~58 `ZIGBASE_DB_URL` table row; ~102–105 "not yet authenticated" sentence) — no `docs/` twin exists
- Modify: `site/src/content/docs/overview.md` (~108–109), `site/src/components/landing/DualBackend.astro` (~75–80), `site/src/pages/compare.astro` (~29)
- Modify: `KNOWN_LIMITATIONS.md` ("## Postgres backend", line ~48–49) and `site/src/content/docs/known-limitations.md` (which currently has NO Postgres section — add one, fixing the pre-existing sync gap)

**Interfaces:** none (prose). "0.10.0" below assumes the next release bumps the minor per pre-1.0 policy — if the release train has moved past that, substitute the actual next version consistently.

- [ ] **Step 1: `docs/postgres.md` — TLS caveat → matrix.** Replace the four-line blockquote at ~55–58 (`> **Caveat — TLS does not yet verify the server.** …This is new in 0.9.0.`) with:

```markdown
**TLS is verified by default** (since 0.10.0): an unqualified `postgres://` URL gets
`sslmode=verify-full` — the server certificate chain is verified against the system root
store and the certificate must match the URL's host name. The full matrix:

| sslmode | TLS | Server refuses TLS | Chain verified | Hostname verified |
|---|---|---|---|---|
| `disable` | no | — | — | — |
| `allow` / `prefer` | opportunistic | plaintext fallback | no | no |
| `require` | required | startup error | no | no |
| `verify-ca` | required | startup error | **yes** | no |
| `verify-full` (default) | required | startup error | **yes** | **yes** |

For a private CA, pass the bundle in the URL: `?sslmode=verify-full&sslrootcert=/etc/ssl/my-ca.pem`
(`sslrootcert=system` explicitly selects the system store). A missing/empty bundle, an untrusted
chain, a hostname mismatch, or a server that refuses TLS all fail **at startup** with an error
that names the fix; connection URLs are never logged. For a trusted-network/dev setup (e.g. a
docker-compose Postgres without TLS), opt down explicitly — `?sslmode=disable` (plaintext) or
`?sslmode=require` (encrypted, unverified) — and expect one startup warning for any explicit
mode below `verify-full`.

> **Known limitation:** hostname verification matches DNS names — a URL that dials an IP
> literal under `verify-full` will generally fail even if the certificate carries an iPAddress
> SAN. Use the DNS name, or `verify-ca` when you must dial an IP on an otherwise-trusted path.
> Client certificates (mTLS), `sslcrl`/OCSP, and SCRAM channel binding are not supported.
```

Also update the example URL at ~50 from `?sslmode=require` to plain `postgres://user:pass@host:5432/db` (the default is now the recommended mode). **Do NOT touch line ~40** ("Release tarballs are stock SQLite-only builds…") — still true, release artifacts were cut from this theme.

- [ ] **Step 2: `docs/postgres.md` — migrate-db caveat softens.** Replace the blockquote at ~87–90 (`> **Caveat — FK suspension needs a superuser target role.** …`) with:

```markdown
> **Note — superuser fast path vs. deferred constraints.** With a superuser target role the
> loader suspends FK enforcement wholesale (`SET session_replication_role = replica`) — the
> fastest path. A non-superuser target role (AWS RDS, Cloud SQL, Neon, …) is **fully
> supported**: relation cycles and self-references are provisioned as `DEFERRABLE INITIALLY
> IMMEDIATE` foreign keys and the load transaction defers them to `COMMIT`, so rows load in
> any order; a dangling reference rolls the whole load back with an error naming the cycle.
```

- [ ] **Step 3: Mirror both edits** into `site/src/content/docs/postgres.md` (identical text; the caveats sit ~5 lines lower because of the frontmatter). Diff-check afterwards: `diff <(sed 1,5d site/src/content/docs/postgres.md) docs/postgres.md` should show only pre-existing intentional divergences (link forms), not the new sections.

- [ ] **Step 4: `site/src/content/docs/configuration.md`.** (a) Table row line ~58: replace with:

```markdown
| `ZIGBASE_DB_URL` | — | `""` (SQLite) | **Opt-in.** A `postgres://…` URL selects the PostgreSQL backend instead of SQLite. TLS defaults to `sslmode=verify-full` (certificate chain + hostname verified; `sslrootcert=<pem-path>` for private CAs) — append `?sslmode=require` or `?sslmode=disable` to opt down (logged at startup). Only honored in a binary built with `-Dpostgres=true` (see below); ignored otherwise |
```

(b) In the paragraph at ~98–105, replace the sentence starting `Transport is also **not yet authenticated** — …trusted network path for now.` with:

```markdown
Transport is **verified by default** since 0.10.0 — an unqualified URL gets
`sslmode=verify-full` (chain + hostname verification, `sslrootcert=` for private CAs), a
server that refuses TLS fails at startup with the exact opt-down instruction, and any
explicit mode below `verify-full` logs a startup warning.
```

- [ ] **Step 5: `site/src/content/docs/overview.md` ~108.** In the known-limitations sentence, change `…and the PostgreSQL backend is new in 0.9.0 (TLS is encrypted but not yet certificate-verified).` to `…and the PostgreSQL backend is opt-in (build from source with -Dpostgres).`

- [ ] **Step 6: `site/src/components/landing/DualBackend.astro` ~75–80.** Replace the `dual__caveat` paragraph content with the positive claim:

```html
    <p class="dual__caveat">
      Postgres support is opt-in (build from source with -Dpostgres). Connections are
      TLS-verified by default since 0.10.0 — sslmode=verify-full checks the certificate
      chain and hostname. Details in the
      <a href={`${base}docs/postgres`}>PostgreSQL guide</a>.
    </p>
```

- [ ] **Step 7: `site/src/pages/compare.astro` ~29.** Change the ZigBase Database cell from `'Embedded SQLite; PostgreSQL opt-in (new in 0.9.0)'` to `'Embedded SQLite; PostgreSQL opt-in (verified TLS by default)'` (drops the aging "(new in 0.9.0)" hedge and the implicit TLS asterisk; keeps the honesty framing).

- [ ] **Step 8: `KNOWN_LIMITATIONS.md`.** Replace the single bullet under `## Postgres backend` (line ~49, the "SUPERUSER target for the fast path… lightly tested… 0.9.x follow-up" bullet) with:

```markdown
- **`verify-full` hostname checks match DNS names only.** Dialing an IP literal under the default `sslmode=verify-full` generally fails hostname verification even when the certificate carries an iPAddress SAN — connect by DNS name, or use `sslmode=verify-ca` on an otherwise-trusted path. Client certificates (mTLS), CRL/OCSP, and SCRAM channel binding (`SCRAM-SHA-256-PLUS`) are not supported.
- **SCRAM passwords that require NFKC normalization are rejected.** The driver implements RFC 4013 SASLprep except full NFKC normalization: a password whose SASLprep output would need NFKC fails at connect with an actionable error — supply it pre-normalized to NFKC, or use an ASCII password. (Everything else is correctly prepped or intentionally matches PostgreSQL's own use-verbatim behavior.)
- **`migrate-db`: the superuser fast path is faster; the non-superuser path is fully supported.** A superuser target suspends FK enforcement wholesale; a non-superuser target provisions cycle-edge FKs as deferrable and defers them to COMMIT — correct for cyclic and self-referential graphs, verified against live Postgres in CI.
```

- [ ] **Step 9: `site/src/content/docs/known-limitations.md`.** This mirror currently has NO `## Postgres backend` section (a pre-existing sync gap). Add the same three bullets under a new `## Postgres backend` heading, placed to match the root file's section order (before `## Other deferred work` if the mirror has it, else before the final section).

- [ ] **Step 10: Build the site.** `cd site && npm run build` — expected: build succeeds (Astro exits 0). Fix any MDX/markdown syntax complaints (tables inside blockquotes are the usual culprit — the matrix above is deliberately NOT inside a blockquote).

- [ ] **Step 11: Full verification.** From the repo root:

```bash
mise exec zig@0.16.0 -- zig build test --summary all
mise exec zig@0.16.0 -- zig build test --summary all -Dpostgres=true
```

Expected: both print `Build Summary: N/N tests passed`. Confirm no `postgres://` string appears in any new log call: `git diff origin/main -- src | grep -n "log\." | grep -i "uri\|url" ` — expected: no credential-bearing values (message TEXT may say "ZIGBASE_DB_URL"/"URL" as instruction words, but no `{s}`-interpolated uri).

- [ ] **Step 12: Commit.**

```bash
git add docs/postgres.md site/src/content/docs/postgres.md site/src/content/docs/configuration.md site/src/content/docs/overview.md site/src/components/landing/DualBackend.astro site/src/pages/compare.astro KNOWN_LIMITATIONS.md site/src/content/docs/known-limitations.md
git commit -m "docs: flip the Postgres TLS + migrate-db caveats (verify-full default, supported non-superuser path); sync site mirrors"
```

---

## Post-plan checklist (for the executor's final review before PR)

- [ ] `grep -rn "not yet verify\|not yet certificate-verified\|lightly.tested" docs/ site/src KNOWN_LIMITATIONS.md` → no hits outside `docs/superpowers/` (historical archive — untouched) and the changelog history.
- [ ] The `docs/postgres.md` "Release tarballs are stock SQLite-only builds" line is UNCHANGED (spec Non-goals: no release artifacts).
- [ ] Three fragments exist in `changelog.d/`; `CHANGELOG.md` untouched.
- [ ] CI: `postgres` and `postgres-tls` jobs green. If `postgres` fails inside `realtime_pg_test`, rerun once before investigating (known NOTIFY flake).
- [ ] Browser suite is NOT touched by this theme (no admin-UI/server-route changes) — no `tests/admin/` run required, but note it in the PR body per the template checklist.





