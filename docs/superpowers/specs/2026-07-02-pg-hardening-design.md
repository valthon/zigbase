# SP3 Theme A — Postgres Production-Hardening (Design Spec)

Baseline: `origin/main` @ `1bd02c4`. Backend code under `src/backend/postgres/` (comptime-gated
by `-Dpostgres=true`); all three items below close caveats that shipped with the 0.9.0 backend.

## Goal

Remove the three "trusted network / superuser" asterisks that keep the Postgres backend from
being recommendable for production:

1. Real TLS server-certificate verification (`verify-ca` / `verify-full`, CA bundles, hostname
   checks) — and make **`verify-full` the default** for `postgres://` URLs.
2. RFC 4013 SASLprep for SCRAM passwords, minimal-correct (never silently wrong; loud,
   actionable rejection for the one case we don't normalize).
3. A correct non-superuser `migrate-db` path: cyclic and self-referential FK graphs load
   correctly via deferred constraints, with live-PG CI fixtures.

Standing constraints honored throughout: misconfiguration fails **at startup** with an error that
names the fix (never post-boot); everything fails **closed**; `postgres://` URLs (credentials) are
**never logged** — errors name `host:port`, `sslmode`, and file paths only; every item ships a
`changelog.d/` fragment; docs and the `site/src/content/` mirror move together.

## Default-build impact

**Zero.** All three items live entirely under `src/backend/postgres/` (TLS trust store, SASLprep
tables, `dumpload.zig`'s cycle-detection/deferred-constraint path for the Postgres arm), which is
already comptime-gated by `-Dpostgres=true` and absent from the default build. Item 3's SQLite-arm
change (`PRAGMA defer_foreign_keys=ON` in the load transaction) is the one line that touches the
default binary — it is a `PRAGMA`, not new code, and is exercised by the existing SQLite dumpload
path unconditionally. No new default-build dependency, no new default-build binary size, no new
default-build attack surface. Postgres itself remains **custom-compile only**: there is no
prebuilt `-pg` release artifact and no `@zigbase/server-pg-*` npm package (see Non-goals) — the
only way to run ZigBase against Postgres is `-Dpostgres=true` from source, which is also the only
way any of this code enters a binary at all.

## Non-goals

- Client certificates (`sslcert`/`sslkey`, mTLS), `sslcrl`, OCSP, channel binding
  (`SCRAM-SHA-256-PLUS`). Each is rejected/absent with a clear error or documented as unsupported.
- A full Unicode NFKC normalizer in the driver (see item 2's quick-check design instead).
- **Postgres-enabled release artifacts (`zigbase-pg-*` tarballs, a release-matrix `variant`
  dimension, download-page pg links).** Owner's stance: **custom compile only, for now.**
  Postgres support stays a `-Dpostgres=true` source build; there is no prebuilt binary that links
  the Postgres backend, and none is planned this pass. This was scoped as item 4 in an earlier
  draft of this spec and is cut entirely — not deferred as an open question, but a standing
  decision until an owner revisits it. Rationale: a prebuilt pg tarball is a second binary variant
  with its own release-matrix jobs, SHA256SUMS entries, and download-page surface — real ongoing
  maintenance weight — for a backend most operators will custom-compile alongside their own
  deployment tooling anyway (managed PG users already have a build/deploy pipeline). Revisit if
  demand materializes; until then the existing `docs/postgres.md` guidance ("release tarballs are
  SQLite-only — build from source for Postgres") stays **true and stays in place** (see Docs
  checklist below — this is the one caveat-flip candidate that does *not* flip).
- Publishing `@zigbase/server-pg-*` npm packages — same stance as above; no npm package can exist
  without a corresponding release artifact, so this falls out of the tarball cut rather than being
  a separate decision.
- Windows anything; `-Dvector` in release artifacts (out of scope — no release-artifact work is in
  this theme at all now).
- Rewriting the historical 0.9.0 changelog entry or `docs/superpowers/` archives.

---

## 1. TLS certificate verification

### What Zig 0.16 std actually provides (grounding)

`std.crypto.tls.Client.Options` (`lib/std/crypto/tls/Client.zig:87`):
- `host: union { no_verification, explicit: []const u8 }` — hostname verification against the
  server cert (SAN/CN), exactly what `verify-full` needs.
- `ca: union { no_verification, self_signed, bundle: { gpa, io, lock: *std.Io.RwLock, bundle: *Certificate.Bundle } }`
  — chain verification against a caller-owned bundle, exactly what `verify-ca` needs.
- `realtime_now: std.Io.Timestamp` — used for NotBefore/NotAfter checks. `conn.zig` currently
  passes `.zero`; verified modes **must** pass real wall time (`std.Io.Timestamp.now(io, .real)`)
  or every cert is "not yet valid". Pass real time unconditionally (harmless under
  `no_verification`).
- `InitError` distinguishes the cases we need for UX: `CertificateHostMismatch`,
  `CertificateExpired`, `CertificateNotYetValid`, `TlsCertificateNotVerified`, `TlsAlert`, etc.

`std.crypto.Certificate.Bundle`:
- `rescan(gpa, io, now)` — loads system roots (Linux distro paths, macOS keychain, BSDs).
- `addCertsFromFilePathAbsolute(...)` / `addCertsFromFilePath(...)` — load a PEM file (the
  `sslrootcert=<path>` case). `bundle.map.count() == 0` after load ⇒ file had no usable certs.

Conclusion: no new crypto code is needed; this is plumbing + policy + UX.

### sslmode matrix (`connstr.zig`)

`SslMode` grows two members; `parse` stops rejecting them; `requiresVerification` is deleted:

| sslmode       | SSLRequest | server says 'N'          | chain check | hostname check |
|---------------|-----------|---------------------------|-------------|----------------|
| `disable`     | no        | —                         | —           | —              |
| `allow`/`prefer` | yes    | plaintext fallback        | no          | no             |
| `require`     | yes       | error                     | no          | no             |
| `verify-ca`   | yes       | error                     | **yes**     | no             |
| `verify-full` | yes       | error                     | **yes**     | **yes** (URL host) |

New URL query param: `sslrootcert=<path>` (percent-decoded) or `sslrootcert=system` (libpq-16
semantics). Stored on `connstr.Config` as `sslrootcert: ?[]const u8` (owned, freed in `deinit`).
`sslrootcert` given with a non-verifying sslmode is accepted and ignored with a startup **warning**
(libpq parity), not an error. Unknown query keys keep today's ignore behavior.

### Trust store: built once, at startup, shared by all connections

New file `src/backend/postgres/tls_trust.zig` (wired into `backend/postgres/tests.zig` for test
discovery), owning:

```zig
pub const TlsTrust = struct {
    bundle: std.crypto.Certificate.Bundle,
    lock: std.Io.RwLock,
    pub fn init(gpa, io, cfg: connstr.Config) TrustError!TlsTrust { ... }
};
```

- Built by `pg.Pool.initOpts` **iff** `cfg.sslmode` is `verify_ca`/`verify_full`, before the first
  connection is opened. `sslrootcert=<path>` ⇒ `addCertsFromFilePathAbsolute` (relative paths
  resolved against cwd via `addCertsFromFilePath`); absent or `=system` ⇒ `rescan` system roots.
- **Fail fast, actionable:** missing/unreadable file ⇒
  `postgres TLS: sslmode=verify-full requires a CA bundle, but sslrootcert '<path>' could not be read (<errname>). Fix the path, or omit sslrootcert to use the system root store.`
  Empty bundle after load (`map.count()==0`, incl. an empty system store) ⇒
  `... contains no usable CA certificates.` These abort startup — the server never boots
  half-verified.
- `Conn.connect` gains `trust: ?*TlsTrust`; `startTlsHandshake` selects options per mode:
  `require` ⇒ `.host = .no_verification, .ca = .no_verification` (today's behavior);
  `verify_ca` ⇒ `.ca = .{ .bundle = ... }, .host = .no_verification`;
  `verify_full` ⇒ both, `.host = .{ .explicit = cfg.host }`.
- Runtime pool refills reuse the same `TlsTrust` (pointer + RwLock per the std API), so a
  lazily-opened reader can only fail for *live* reasons (rotated cert, network), which the pool
  already treats as a broken-connection open failure — misconfig class errors are impossible
  post-boot because the bundle and the URL were validated at startup.

### Failure UX (first handshake happens at startup — the writer opens in `Pool.initOpts`)

Map `tls.Client.InitError` into new `ConnError` members instead of the current blanket
`TlsHandshakeFailed`: `CertUntrusted` (chain didn't verify — message names the CA source and
suggests `sslrootcert=` for private CAs), `CertHostnameMismatch` (message names the URL host and
says "connect by the name in the certificate, or use sslmode=verify-ca if you cannot"),
`CertExpired` / `CertNotYetValid` (message says to check server cert and system clock). A server
answering 'N' to SSLRequest under any verify/require mode ⇒
`server refused TLS but sslmode=<mode> requires it; for a trusted-network/dev setup append ?sslmode=disable (plaintext) or ?sslmode=require (encrypted, unverified) to ZIGBASE_DB_URL.`
All of these bubble out of `Db.open` → `pg.Pool.initOpts` → fatal startup error. **Never** include
the URL in any of these messages — `host:port`, mode, and cert-file paths only.

Known std limitation, documented (not worked around): host verification matches DNS names; a URL
with an IP-literal host under `verify-full` will generally fail hostname matching even if the cert
carries an iPAddress SAN. Guidance in docs: use the DNS name for `verify-full`, or `verify-ca`
when you must dial an IP on an otherwise-trusted path.

### Default sslmode: **`verify-full`** (recommended, with rationale)

Today the default is `prefer` (libpq parity). Evaluated options:

- **Keep `prefer`/adopt `require` default:** zero upgrade friction; but `require` still hands an
  unauthenticated session to anyone who didn't read the docs, and `prefer` silently downgrades to
  plaintext — both contradict the project's own safe-by-default record (blank rule ⇒ locked,
  cookies `Secure` unless `--insecure-cookies`).
- **`verify-full` default (chosen):** an unqualified `postgres://` URL gets the strongest mode.
  The trusted-network/dev install base (docker-compose PG with no TLS at all) breaks with a
  **startup** error whose text contains the exact one-parameter fix (`?sslmode=disable` or
  `?sslmode=require`) — the same shape as the `--insecure-cookies` opt-down, and pre-1.0 breaking
  appetite is explicitly high. Managed-PG users (RDS/Cloud SQL/Neon...) mostly get *correct
  security silently* since public CAs or documented CA files are the norm there. `require` as
  default would remove only the plaintext downgrade while keeping MITM exposure — a half-measure
  that would itself need a second breaking change later; take the whole step once.

Accompanying loudness: when an **explicit** sslmode below `verify-full` is configured, startup
logs one warning (`postgres: sslmode=require — connection is encrypted but the server is NOT
authenticated; use verify-full in production`), mirroring the `@public` rule warnings. Ships as a
`### Breaking` fragment + minor bump (0.x → 0.(x+1).0). CI URLs already pin explicit sslmodes, so
CI models the opted-down user; new CI coverage pins the default path (see Test plan).

---

## 2. SCRAM SASLprep (RFC 4013) — minimal-correct

Scope note: PostgreSQL ignores the SASL `n=` username (it comes from the startup packet — and
`scram.zig` already sends `n=` empty), so SASLprep applies to the **password only**, inside
`scram.Client.clientFinal` before PBKDF2.

New `src/backend/postgres/saslprep.zig` (`pub fn prepare(allocator, password) Result`):

1. **ASCII fast path:** all bytes in `0x20..0x7E` ⇒ return the input slice verbatim (SASLprep is
   the identity on printable ASCII; zero allocation — the overwhelmingly common case is untouched).
2. Otherwise decode UTF-8 (invalid ⇒ `fallback_verbatim`, see 5).
3. **Mapping:** RFC 3454 B.1 map-to-nothing (soft hyphen etc., ~27 code points) and C.1.2
   non-ASCII spaces → U+0020 (~18 code points).
4. **Prohibited output:** C.2.1/C.2.2 control chars, C.3–C.9 (private use, non-chars, surrogates,
   inappropriate/tagging chars) and the RFC 3454 §6 bidi rules (D.1 RandALCat mixing / positional
   checks). Violation ⇒ `fallback_verbatim`.
5. **PG-parity fallback (`fallback_verbatim`):** PostgreSQL's own `pg_saslprep` (server *and*
   libpq) uses the password **as-is** whenever prep fails (invalid UTF-8, prohibited char, empty
   result). We mirror that exactly — hard-erroring here would break auth against verifiers PG
   itself created from such passwords. This is not a security downgrade: the bytes feed PBKDF2
   either way.
6. **NFKC — the one deliberate gap:** we do not normalize. Instead run an **NFKC quick-check**:
   if every code point has `NFKC_QC = Yes` and combining-class ordering is already canonical, the
   string is definitionally NFKC-normal ⇒ the prepped string is correct as-is. If the quick-check
   says No/Maybe, the *correct* output would require real normalization ⇒ hard error
   `ScramError.PasswordNeedsNormalization`, surfaced at (startup-time) connect as:
   `postgres auth: the password contains Unicode that requires NFKC normalization (RFC 4013 SASLprep), which this driver does not perform. Supply the password pre-normalized to NFKC, or change it to an ASCII password.`
   Never wrong, always loud, names the fix — vs. today's behavior (verbatim bytes ⇒ mysterious
   `password authentication failed`).

**Tables: vendored-generated, not algorithmic.** The B.1/C.*/D.* sets come straight from the RFC
3454 appendices (frozen forever); NFKC_QC(No|Maybe) and `ccc != 0` come from the current UCD.
All are emitted as sorted `[N]struct { lo: u21, hi: u21 }` range tables into a checked-in
generated file `src/backend/postgres/saslprep_tables.zig` (~3–5 KB) by a new
`scripts/gen-saslprep-tables.py` (reads two vendored UCD text extracts under
`vendor/unicode/`, header records the Unicode version). Rationale: binary-search over ranges is
trivial to audit, the generator makes future Unicode bumps mechanical, and no algorithmic subset
can express these sets. Explicitly **skipped**: RFC 3454 A.1 "unassigned code points" — RFC 3454
§7 permits unassigned in *query* strings, the assigned-set has grown enormously since Unicode 3.2
(rejecting emoji passwords would be a self-inflicted footgun), and PG interops fine without it.

Unsupported-with-clear-error summary: needs-NFKC passwords (error above). Everything else is
either correctly prepped or intentionally PG-parity verbatim. `scram.zig`'s header "Limitation"
comment is rewritten to state the new contract.

---

## 3. `migrate-db` non-superuser fallback hardening (`src/dumpload.zig`)

Today: superuser targets get `SET session_replication_role = replica`; non-superuser targets fall
back to `tableLoadOrder`/`collectionCreateOrder`, whose cycle handling is "append leftovers in
declaration order and let the FK fail loudly". Two distinct problems: (a) DDL — cyclic inline
`REFERENCES` can't be created in any order on Postgres; (b) DML — row order can't satisfy cyclic
or self-referential FKs.

### Design: cycle detection + deferred constraints (chosen over NULL-then-UPDATE)

**Cycle detection (pure, unit-testable):** rework `collectionCreateOrder` into
`planCreateOrder(a, cols) → { order: []usize, cycle_edges: []Edge }` using Kahn's algorithm; the
leftover nodes after Kahn form the cyclic core, and every relation edge *between two leftover
nodes* is conservatively a `cycle_edge` (`Edge = { col_idx, field_idx }`). A self-relation field
is always a cycle edge. Cycles are logged at info level with member collection names.

**DDL phase (`provisionRecordTables`, Postgres target):** create cycle-member tables with the
cycle-edge FK clauses **omitted** from `ddl.createTableSql` (new optional
`skip_fk_fields` parameter), then after all tables exist, add each omitted edge back:

```sql
ALTER TABLE "child" ADD CONSTRAINT "fk_<table>_<field>"
  FOREIGN KEY ("<field>") REFERENCES "parent"("id") <on-delete parity with ddl.zig>
  DEFERRABLE INITIALLY IMMEDIATE;
```

`DEFERRABLE INITIALLY IMMEDIATE` behaves identically to a plain FK outside explicit
`SET CONSTRAINTS`, so there is no semantic drift for the running server; it exists purely so the
load transaction can defer it. Non-cycle FKs keep today's inline, non-deferrable form — no change
to ordinary schemas. (Handles **non-nullable** cycles too, which NULL-then-UPDATE cannot; that is
why deferred-constraints is the primary strategy, and NULL-then-UPDATE is rejected.)

**Load phase (when `suspendForeignKeys` returned false):** inside the existing single
transaction, issue `SET CONSTRAINTS ALL DEFERRED;` (no privileges required; affects only
deferrable constraints, i.e. exactly the cycle edges). Keep the topological table order for all
non-deferrable FKs. Cyclic and self-referential rows now validate once, at `COMMIT`.

**SQLite target parity:** the SQLite writer runs with `PRAGMA foreign_keys=ON`
(`src/backend/sqlite/db.zig:365`); add `PRAGMA defer_foreign_keys=ON;` inside the load
transaction (auto-resets at commit) — same order-independence, and SQLite permits
forward/cyclic inline FK DDL natively, so no DDL change is needed on that arm.

**Hard error (the only one left):** deferred FK violation at `COMMIT` (dangling reference in the
source data) rolls back — wrap the commit error as:
`migrate-db: foreign-key cycle across collections [a, b] could not be satisfied at commit — a row references a missing target. The target was rolled back; fix the dangling reference in the source (or use a superuser target role) and re-run.`
An `ALTER ... ADD CONSTRAINT` failure during provisioning gets the same actionable treatment
(names table, field, and referenced table). The "lightly tested topological fallback" caveat in
docs/KNOWN_LIMITATIONS flips to a supported claim.

---

## Test plan

**Unit (default build, `zig build test`)**
- `connstr`: `verify-ca`/`verify-full` parse to the new enum members (rejection test inverted);
  `sslrootcert=` path + `=system` + percent-decoding; **default sslmode is `verify_full`** when
  the URL has none; explicit `prefer`/`require`/`disable` respected; `sslrootcert` with
  `sslmode=require` accepted (warn behavior asserted at the pool layer).
- `saslprep`: RFC 4013 §3 vectors — `I\u{00AD}X` → `IX`; `user`/`USER` unchanged; `\u{00AA}` and
  `\u{2168}` ⇒ `PasswordNeedsNormalization`; `\u{0007}` and the bidi-violating `\u{0627}1` ⇒
  PG-parity verbatim result; NBSP → space; ASCII fast path is alias-identical (no alloc);
  invalid UTF-8 ⇒ verbatim; table sanity (sorted, non-overlapping ranges).
- `scram`: exchange test with a non-ASCII NFC password proving prep feeds PBKDF2.
- `dumpload`: `planCreateOrder` on synthetic collections — acyclic (order respected, zero cycle
  edges), self-relation, 2-cycle, 3-cycle, and a cycle with a diamond feeding it; SQLite→SQLite
  round-trip with a self-referential nullable relation (exercises `defer_foreign_keys`).
- `tls_trust`: missing file / empty PEM / garbage PEM produce the named startup errors.

**Live Postgres (`postgres` CI job, `-Dpostgres=true`)**
- SCRAM: superuser conn creates roles with (a) a non-ASCII already-NFC password — login succeeds;
  (b) a needs-NFKC password — client fails with `PasswordNeedsNormalization` (asserting message
  shape, not a raw auth failure).
- dumpload: superuser conn creates a `NOSUPERUSER` role + grants; migrations run into a temp
  schema owned by it; fixtures: self-referential (nullable), mutual A⇄B with one non-nullable
  edge, fully non-nullable 2-cycle — all migrate with correct row counts and FK integrity
  verified post-commit; dangling-reference fixture asserts rollback + the actionable cycle error.

**Live Postgres over TLS (`postgres-tls` CI job)**
- Cert generation gains `-addext subjectAltName=DNS:localhost`; job exports
  `ZIGBASE_PG_TLS_CA=$PWD/pgtls/server.crt`. New live tests (skipped when the env is absent):
  `verify-full` + `sslrootcert=$ZIGBASE_PG_TLS_CA` + host `localhost` succeeds end-to-end;
  `verify-full` with system roots ⇒ `CertUntrusted`; host `127.0.0.1` + the CA ⇒
  `CertHostnameMismatch`; default-mode URL (no sslmode) ⇒ fails against the self-signed server
  and succeeds with `sslrootcert` — pinning the new default; `sslmode=require` still passes
  (opt-down keeps working). Existing suite keeps running under `sslmode=require`.
- `postgres` job (no server TLS): a default-mode URL test asserts the actionable
  "server refused TLS" startup error text.

## Docs & release checklist

Caveat text that **flips** (each with its `site/src/content/` mirror kept in sync):
- [ ] `docs/postgres.md` ~54–58 + `site/src/content/docs/postgres.md` ~59–63 — "TLS does not yet
      verify the server" caveat → replaced by the sslmode matrix, `sslrootcert=`, the
      `verify-full` default, and the opt-down instructions (item 1).
- [ ] `site/src/content/docs/configuration.md` ~100–101 (no `docs/` twin exists) — "NOT
      authenticated / verify-ca/verify-full rejected" paragraph + `ZIGBASE_DB_URL` table row
      rewritten; document the new default + startup warning for opted-down modes.
- [ ] `site/src/content/docs/overview.md:109` — drop "(TLS is encrypted but not yet
      certificate-verified)".
- [ ] `site/src/components/landing/DualBackend.astro:75–80` — `dual__caveat` footnote rewritten
      to the positive claim ("verified TLS by default since 0.x").
- [ ] `site/src/pages/compare.astro:29` — ZigBase database cell's self-caveat framing updated
      (the "(new in 0.9.0)" hedge ages out; keep the honesty stance, drop the TLS asterisk).
- [ ] `KNOWN_LIMITATIONS.md` "## Postgres backend" + `site/src/content/docs/known-limitations.md`
      — the "lightly tested topological fallback" bullet is deleted/replaced by the supported
      deferred-constraint behavior (item 3); the migrate-db caveat in `docs/postgres.md` ~87–90
      + mirror softens to "superuser fast path is faster; non-superuser path is fully supported".
- [ ] `src/backend/postgres/scram.zig` header "Limitation" comment rewritten (item 2).

Caveat text that **stays put** (do not touch — still true after this theme):
- [ ] `docs/postgres.md` ~40 + `site/src/content/docs/postgres.md` mirror — "Release tarballs are
      stock SQLite-only builds — build from source for Postgres" is **unchanged**. This spec ships
      no release artifacts (see Non-goals: custom-compile only, for now); flipping this line would
      be false.

Process:
- [ ] One `changelog.d/<slug>.md` fragment per PR; item 1 carries `### Breaking` (default
      sslmode) + `### Security`; items 2–3 `### Fixes`/`### Security`.
- [ ] Version: the item-1 PR's release train bumps the minor (0.x+1.0) per pre-1.0 policy.
- [ ] CI: extend `postgres` / `postgres-tls` jobs as above.
- [ ] `cd site && npm run build` after every doc/site touch; PR-template sync checklist honored.
