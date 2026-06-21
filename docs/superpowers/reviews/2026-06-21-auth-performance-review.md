# Auth Surface Performance Review — ZigBase

**Reviewer:** senior performance engineer
**Tree:** `.claude/worktrees/pluggable-auth-design` @ HEAD `76d3d76` (`refactor(auth): per-method conns, drop legacy`)
**Date:** 2026-06-21

## Concurrency model (the lens for everything below)

`src/db.zig`: ONE writer connection guarded by a futex-backed `std.Io.Mutex` (`writer_mutex`, db.zig:263; waiters sleep, don't spin — good). All writes serialize through it. A warm pool of **16** read-only WAL connections (`reader_pool_size = 16`, db.zig:231; runtime-capped via `.pools.readers`); excess concurrent readers fall back to a fresh `open()` and are closed on release (db.zig:283-288). WAL, `synchronous=NORMAL`, `busy_timeout=5000`, `wal_autocheckpoint=2000`.

**Consequence:** anything that holds the writer across slow work (argon2, SMTP, provider HTTP, CBOR/COSE parse + sig-verify) throttles **every write process-wide**. Holding a *reader* across slow work is milder but can exhaust the 16-slot warm pool under burst, forcing fresh opens (open cost) and eventually contention.

---

## Overall assessment

**No hard perf blocker that should stop the merge** — the headline refactor goal (get argon2 and OAuth provider-HTTP off the writer) **largely landed and is correct** for the two paths it targeted (password verify, OAuth complete). But the same writer-across-slow-work pattern the refactor was meant to eradicate **survives in two built-in methods** and should be fixed before this is sold as "the writer is never held across slow work":

- **OTP `initiate` holds the single writer across the SMTP send** (HIGH) — the exact regression class, still live.
- **WebAuthn `complete` and register-`finish` hold the writer across CBOR/COSE parse + signature verify** (HIGH) — and register also across JWT auth + collection read + body JSON parse.

Neither is a correctness bug; both are throughput cliffs under concurrent auth load. They are mechanical to fix (the in-tree template `requestVerification` already does it right). Recommend fixing F1/F2 before merge or as an immediate fast-follow; the rest are round-trip trimming and housekeeping.

### Writer-during-slow-work regression status

| Path | Slow work | Writer held across it? | Status |
|------|-----------|------------------------|--------|
| `authWithPassword` (legacy) | argon2 verify | NO — runs on a reader (api/auth.zig:174) | ✅ resolved |
| password method `complete` | argon2 verify | NO — `ac.reader()` (password.zig:61) | ✅ resolved |
| OAuth `complete` | provider token-exchange + userinfo HTTP | NO — writer released before HTTP (oauth2.zig phasing) | ✅ resolved |
| **OTP `initiate`** | **SMTP send** | **YES** (otp.zig:93 → :107) | ❌ **regression present** |
| magic_link `initiate` | SMTP send | reader (not writer) held across it (magic_link.zig:50 → :62) | ⚠️ milder, still wrong |
| **WebAuthn `complete`** | **CBOR/COSE parse + sig verify** | **YES** (webauthn.zig:160 → :192) | ❌ **regression present** |
| **WebAuthn register `finish`** | **JWT auth + col read + JSON parse + CBOR/COSE + verify** | **YES** (webauthn_register.zig:134-228) | ❌ **regression present** |

So: **the refactor resolved the paths it explicitly named (password, OAuth) but did NOT generalize the discipline to OTP, magic_link, or WebAuthn.** The claim "the writer is never held across slow work" is not yet true tree-wide.

---

## Findings, ranked by impact

### HIGH

#### H1 — OTP `initiate` holds the single writer across the SMTP send — CONFIRMED
`src/auth/methods/otp.zig:93` acquires the writer (`var w = ac.writer();`), held via `defer w.deinit()` to function end. The mail send is at **otp.zig:107** (`try ac.deliverMail(...)`), *inside* that scope. `deliverMail` → `deliverToken` (api/auth.zig:256) → `mailer.send(...)`, a blocking SMTP round-trip (connect + STARTTLS/implicit-TLS handshake + DATA) — tens-to-hundreds of ms typically, seconds on a slow/down relay.

While that one OTP request holds the writer for the SMTP exchange, **every other write process-wide blocks**: record creates/updates, session minting for every other login, every other method's `complete`. Under any concurrent OTP burst (login-screen fan-out, or an attacker POSTing `/initiate` with known emails) write throughput collapses to one-email-at-a-time, fully serialized. The writer is genuinely needed for the `ChallengeStore.put` INSERT (otp.zig:104) and the `findByIdentity` read (otp.zig:97) — but **not** for the mail send.

**Fix:** mirror `requestVerification` (api/auth.zig:326-345), which already does this correctly: do `findByIdentity` + `ChallengeStore.put` inside a scoped writer block, stash `(email, code)` in arena-allocated locals, `w.deinit()`, then `deliverMail` after the writer is released.

#### H2 — WebAuthn `complete` + register `finish` hold the writer across CBOR/COSE parse and signature verify — CONFIRMED
**Login** (`src/auth/methods/webauthn.zig:160-217`): writer acquired at :160-161, held to end. Under the lock: `cs.take` (legit UPDATE, :167), `getByCredentialId` (a SELECT — needs only a reader, :177), `b64urlDecode` (:182), `cose.parseCoseKey` (:187), and **`verifyAssertion`** (:192 → authenticate.zig:112 → verify_sig.zig:64, the P-256 verify) plus clientDataJSON/authData parse + SHA-256, then `updateSignCount` (legit UPDATE, :213). **The signature verify runs under the writer.**

**Registration** (`src/api/webauthn_register.zig:134-228`) is worse: writer held across `requireAuthed`→`auth.authenticate` (JWT verify + DB lookup, :139), `loadWebAuthnCollection`→`collections.get` (:143), body `std.json.parseFromSlice` (:154), `cs.take` (:176), two `b64urlDecode` (:181-186), `register_mod.verifyRegistration` (full CBOR decode of attestationObject + authData + COSE + SHA-256 + client-data verify, :189-199), `existsCredentialId` (:206), and `insert` (:215).

A P-256 verify is tens of µs, but the JSON+CBOR+base64+alloc churn around it is the larger tail; all of it serializes against every other write. Worse, a client can POST junk that still parses far enough to reach verify, holding the writer per malicious request.

The code comment (webauthn.zig:158-159) claims the single-writer span keeps the ceremony "atomic." It does **not** justify holding the lock across parse+verify: the single-use gate is already atomic inside `cs.take`, and the `credentialId UNIQUE` constraint enforces registration uniqueness at insert regardless of lock span. SignCount clone-detection is advisory and can be a compare-and-set UPDATE (`SET signCount=? WHERE credentialId=? AND signCount=<old>`) re-acquired after verify.

**Fix:** split both ceremonies — (1) `cs.take` under the writer, (2) release, (3) `getByCredentialId`/`collections.get` via `ac.reader()` + b64decode + COSE parse + verify with **no lock**, (4) re-acquire writer only for `updateSignCount`/`insert`. The `ac.reader()` helper (method.zig:50) already exists and is currently unused by WebAuthn. For register, also move `requireAuthed` + `collections.get` + body parse ahead of the writer.

---

### MEDIUM

#### M1 — magic_link `initiate` holds a pooled reader across the SMTP send — CONFIRMED
`src/auth/methods/magic_link.zig:50` acquires a reader; mail send at :62 inside the `defer r.deinit()` scope. Not the writer, so it does **not** throttle writes (hence MEDIUM not HIGH). But it parks one of 16 warm readers in SMTP I/O; under concurrent magic-link bursts the warm pool can be exhausted by connections sitting in mail handshakes, forcing fresh `open()`s and starving legitimate reads. The reader is only needed for `findByIdentity` (:54) and `mintLinkToken` (:56); neither must outlive the send. **Fix:** resolve identity + mint inside a scoped reader block, release, then `deliverMail`. Same shape as H1.

#### M2 — OAuth `complete`: redundant collection reloads on the writer-critical path — CONFIRMED
`collections.get` is an **uncached** DB round-trip every call (collections.zig:153-154, prepare/step, no cache). For an OAuth login that links/creates while the phase-4 writer is held, the same collection is re-loaded repeatedly:

1. dispatch loads `col` under a brief reader (auth_methods.zig:84-89) — release before method.
2. inside `authenticate`→`verifyTokenOfTypes`, **`collections.get` is called TWICE for the same collection** — once at `src/auth.zig:198`, again at `src/auth.zig:208` — a clear redundant round-trip.
3. dispatch success path then calls `issueSession`→`issueSessionExt` (auth_methods.zig:158-160 → api/auth.zig:153) which does `collections.get` *again* + `tokenKeyFor` + `records.get`.

For an already-authenticated link flow the collection is loaded ~4-5× by name in one request, several of them **while the writer is held**, extending the writer-hold window for every OAuth completion. Individually these are indexed single-row reads (cheap), but they're trivially avoidable and on the serialized path.

**Fix:** (a) dedupe the double `collections.get` in `verifyTokenOfTypes` (load once into a local, reuse for `records.get`); (b) thread the already-loaded `ac.collection` down into `issueSession`/authenticate rather than re-`get`-ting by name. `issueSessionExt` already accepts a pre-fetched record (`opt_record`, api/auth.zig:151,157); extend the same idea to a pre-loaded collection.

#### M3 — `oauth2Providers` takes the WRITER for a read-only providers list — CONFIRMED
`src/api/oauth.zig:61` (`oauth2Providers`) does `app.pool.acquireWriter()` then only reads (`collections.get` + iterate `col.options.auth.oauth2.providers` in memory, oauth.zig:62-81). This is a pure read serialized against all writes for no reason. **Fix:** use `acquireReader()`. Cheap, safe, removes a needless writer contention point on a public endpoint.

#### M4 — WebAuthn register `finish`: ~6 round-trips, auth + collection read under the writer — CONFIRMED
Per H2's trace: `auth.authenticate` (≥1 SELECT), `collections.get` (1), `cs.take` (2 statements), `existsCredentialId` (1), `insert` (1) — all under the writer. The auth + collection reads are the obvious candidates to move to a reader before acquiring the writer (subsumed by the H2 fix). `existsCredentialId` (oauth path equivalent) duplicates the `credentialId UNIQUE` constraint that `insert` already enforces — kept only to return a clean 409; acceptable, but it's an extra SELECT under the lock that could be dropped if `insert` mapped the UNIQUE violation to 409.

---

### LOW

#### L1 — No *periodic* GC for the auth ledger tables — CONFIRMED
`gcAuthChallenges` (challenge_store.zig:139-146) runs **only at startup** (framework.zig:710), once. `_consumedTokens`, `_oauthStates` have no sweep at all in the default wiring. Query latency does **not** degrade (every lookup is a PK/index point-lookup), but the tables grow unboundedly between restarts (one row per login/registration/verify attempt), bloating the DB file and the eventual restart sweep. The `OR consumed=1` predicate in the challenge sweep defeats `idx_authchallenge_expires` (full scan), fine at boot but bad if ever run on a large hot table. **Fix:** wire a default `.cron` entry calling the GC for `_authChallenges`/`_consumedTokens`/`_oauthStates`. Throughput-neutral; disk-space/housekeeping only.

#### L2 — `nowUnix` is a SQL round-trip on every mint/verify — CONFIRMED, by design
`SELECT unixepoch('now')` (api/auth.zig:55, auth.zig:220) is a full prepare/step round-trip incurred by `issue`, `mintToken`, `verifyTyped`, `ChallengeStore.put`, several under the writer. The codebase deliberately sources time from SQLite to keep pure code clock-free; `wallNowUnix` (api/auth.zig:34) already exists for the pre-conn rate-limit gate. Impact is low (trivial query, no I/O). Could switch the under-writer mints to `wallNowUnix` to shave a statement off the writer-hold window — minor, only worth it if combined with the H1/H2 restructdirection. Not worth a standalone change.

#### L3 — Redundant base64-decode + COSE re-parse of the stored key per WebAuthn login — CONFIRMED
webauthn.zig:182 decodes the stored COSE key from base64, then :187 re-walks it with `cose.parseCoseKey`, though the credential was already COSE-validated at registration. Storing the parsed x/y (or raw COSE without the base64 round-trip) saves a decode+parse per login. Minor; not worth it without a profile.

#### L4 — OTP `complete` does the identity lookup twice — CONFIRMED
otp.zig:142 `takeByIdentity` (internally SELECT-id + UPDATE + SELECT-payload) then otp.zig:155 `findByIdentity` again to resolve the rid. Both fast indexed reads under the writer. Storing the rid in the challenge payload would drop one query but is a schema change. Low priority.

---

## Per-request `authenticate()` path (every authed request) — assessment

`src/auth.zig:265` `authenticate` → `verifyToken` → `verifyTokenOfTypes` (auth.zig:188). Per authed request it does: `peekClaims` (base64 + JSON parse, arena), constant-time CSRF compare on the cookie+unsafe path, then **`collections.get` ×2 (the M2 redundancy)** + `tokenKeyFor` + `nowUnix` + `records.get`, then one HMAC-SHA256 verify (jwt.verify, auth.zig:204). So **every authenticated request issues ~4-5 DB round-trips** (2 redundant) plus JSON parsing. The JWT verify itself is cheap (single HMAC + timing-safe compare). The DB round-trips dominate; they run on whatever connection the caller passes (the API passes a reader for reads — good; `authRefresh` passes the **writer**, api/auth.zig:209-211, so an authed refresh holds the writer across `authenticate`'s 4-5 reads + issue — acceptable since refresh is a write, but the M2 dedupe directly shrinks that window). **Top per-request win: dedupe the double `collections.get` (M2).** No per-request rate-limiter or allocation hot-spot on the plain authed path (rate limiter only gates the unauthenticated login/initiate endpoints).

## Rate limiter (`src/ratelimit.zig`) — assessment

Well-designed for its job. Fixed-window, O(1) common path under a tiny spinlock (ratelimit.zig:52-57). Bounded at `max_entries=4096` (ratelimit.zig:40); when full it sweeps expired entries and otherwise **fails open** rather than evicting a live window or growing unbounded (ratelimit.zig:82-96) — correct anti-self-DoS choice. Two minor notes, both LOW/acceptable:
- The key is `allocPrint`'d per gated request (api/auth.zig:47-50; auth_methods.zig:110) on the arena — one small alloc per login/initiate. Fine.
- `sweepExpired` (ratelimit.zig:100-119) is O(n²) worst case (restart-scan-on-removal because the iterator is invalidated by removal) and runs under the spinlock. It only triggers when the 4096-cap is hit; at that size and frequency it's negligible, but worth a comment. Not worth changing.

The spinlock (`std.atomic.Mutex` busy-spin, ratelimit.zig:53) vs the writer's futex-backed `std.Io.Mutex` is intentional — the limiter critical section is O(1) and uncontended in the common case, so spinning is cheaper than a syscall. Fine.

## Comptime vs runtime — assessment

Registry assembly is comptime (`assembleTypes`/`Instances`/`build` in registry.zig run at startup, instances live for server lifetime — registry.zig:68-82). Method **lookup** is a runtime linear scan over the (tiny, ≤6+custom) method slice per request (registry.zig:17-22) — fine at that size. Provider resolution (`resolveProvider`, oauth.zig:18) is per-request but in-memory. Codegen (`src/codegen/*`) is build-time only — no runtime cost. No per-request work that obviously belongs at comptime.

## Crypto cost — assessment

argon2id uses `Params.interactive_2id` (crypto.zig:12) = m=64MiB, t=2, p=1 (~tens of ms, 64 MiB scratch per verify). Appropriate for interactive login. Critically, it **never runs under the writer** anymore (password verify is on a reader — H-table above; the timing-defense `dummyVerify`, crypto.zig:31, also runs on the reader path). The 64 MiB scratch is per-verify arena and freed; under heavy concurrent login the memory pressure (N concurrent logins × 64 MiB) is the real ceiling, but that's argon2 working as intended, not a bug. `deriveKey` (HMAC-SHA256, crypto.zig:37) and `genToken` (crypto.zig:44) are cheap.

## Index coverage — all hot lookups covered (CONFIRMED from migrations.zig)

| Lookup | Where-column | Index | Source |
|--------|--------------|-------|--------|
| `findByIdentity` | user identity field(s) | depends on user-collection indexes (not system) | api/auth.zig:64 |
| `tokenKeyFor`/`passwordHashFor` | `id` (PK) | ✅ PK | api/auth.zig:74,83 |
| `_consumedTokens` jti | `jti` (PK) | ✅ PK | migrations.zig:57 |
| `_oauthStates` state | `state` (PK) | ✅ PK | migrations.zig:69 |
| `_externalAuths` link | `(provider,providerId)` | ✅ UNIQUE idx (migrations.zig:45) | oauth.zig:129 |
| `_authChallenges` by id | `id` (PK) | ✅ PK | challenge_store.zig:63 |
| `_authChallenges` by identity | `(collectionRef,method,identity)` | ✅ idx (migrations.zig:107) | challenge_store.zig:99 |
| `_webauthnCredentials` credentialId | `credentialId` UNIQUE | ✅ UNIQUE idx (migrations.zig:123) | store.zig:68 |

**No full-scan lookups in any hot auth path.** One caveat: a user collection's identity field (`findByIdentity`, api/auth.zig:64) is only indexed if the consumer defined an index on it — worth a doc note, but not a code finding here. Dead-weight note (LOW): `idx_webauthncred_record (collectionRef,recordRef)` (migrations.zig:133) is currently unused by any query (WebAuthn is usernameless, no per-user `allowCredentials` enumeration yet) — leave it; needed the moment that feature lands.

## Allocation churn — assessment

CBOR (`cbor.zig`) and COSE (`cose.zig`) decoders are **zero-allocation** — they return slices aliasing the input (cbor.zig:18,57,159) and `parseCoseKey` only `@memcpy`s fixed 32-byte x/y onto the stack (cose.zig:109-124). `authdata.zig` is allocation-free. `verify_sig.zig` allocates nothing (stack buffers). `verifyAssertion` does one transient base-buffer alloc (`authData.len+32`, authenticate.zig:101), freed immediately. **This is genuinely well-optimized — note it.** The only churn is the per-field `b64urlDecode` allocs in the API wrappers (webauthn.zig:41-54) on the request arena — acceptable lifetime, but all happen under the writer (the H2 problem, not an allocation problem per se). JWT/JSON parsing throughout is on `ctx.allocator` (request arena) — correct.

---

## Confirmed wins vs speculative

**Confirmed (traced acquire/release sites, call chains, index DDL):** H1, H2, M1, M2, M3, M4, L1, L3, L4, and the index-coverage / zero-alloc-CBOR / writer-release-for-password-and-OAuth positives.

**Speculative (mechanism certain, magnitude unmeasured):** the *throughput impact size* of H1/H2 depends on concurrent OTP/passkey request volume, which can't be measured from source alone — the serialization mechanism is certain, the QPS at which it bites is not.

**Explicitly NOT worth doing** (micro-opts that hurt readability for negligible gain): L2 (`nowUnix`→`wallNowUnix`) as a standalone change; L3 stored-parsed-key without a profile; rewriting `sweepExpired` to avoid the rare O(n²); replacing the rate-limiter spinlock. Leave the zero-alloc CBOR/COSE and the rate limiter as-is.

## Recommended merge gate

1. **H1** (OTP writer-across-SMTP) and **H2** (WebAuthn writer-across-verify) — fix before merge or immediate fast-follow; both are mechanical and the in-tree template (`requestVerification`, api/auth.zig:326-345) shows the exact pattern.
2. **M1** (magic_link reader-across-SMTP), **M2** (double `collections.get`), **M3** (`oauth2Providers` writer→reader) — cheap, high-value-to-effort; bundle with the H-fixes.
3. **L1** (periodic GC) — file as a follow-up; not blocking.
