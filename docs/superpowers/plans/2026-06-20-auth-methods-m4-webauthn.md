# Milestone 4 — WebAuthn/passkeys (full, research-backed) + consolidated docs

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Implement a from-scratch, spec-correct WebAuthn Relying-Party verifier (registration + authentication) on the M2 AuthMethod contract, supporting ES256 (mandatory) + Ed25519, with RS256 best-effort. Then a consolidated docs pass covering the whole pluggable-auth system (M1–M4).

**Architecture:** Layered, each layer independently TDD'd against vectors: (1) a bounded CBOR decoder, (2) a COSE_Key parser, (3) an authenticatorData byte parser, (4) signature verification per algorithm, (5) clientDataJSON + challenge validation, (6) the registration ceremony (§7.1, fmt:"none"), (7) the authentication ceremony (§7.2) + signCount clone detection, (8) a `_webauthnCredentials` store + the `WebAuthnMethod` on the contract (login via initiate/complete) plus authed registration endpoints. **Fail closed on every parse/verify error.**

**THE NORMATIVE INPUT:** `.superpowers/sdd/webauthn-research.md` — every implementer task MUST read the relevant section. It quotes the W3C L2 §7.1/§7.2 step lists, the §6.1/§6.5.1 byte layouts, COSE labels, the exact Zig std primitives, the CBOR subset, the pitfall checklist, and the test-vector strategy.

**Scope decision (surfaced):** OAuth2 is NOT refactored onto the contract in this PR. It already routes session minting through the M1 seam (fires `onAuth`) and is covered by browser tests; a full initiate/complete rewrite is regression risk for little gain (password already proves the contract as a built-in). OAuth2 remains via its dedicated, battle-tested endpoints. Noted in the consolidated docs.

## Global Constraints

- Build/test ONLY via `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all`; signal `Build Summary: N/N tests passed`. Baseline at M4 start: **586/586**.
- New `src/*.zig` files → add to `src/root.zig` test block.
- Disk is tight on this host; KEEP temp-file usage minimal in every task.
- **Security discipline (from the research §7 pitfalls — every item is a test):** hash RAW clientDataJSON bytes; `type` exact-match; challenge single-use/TTL/ceremony-bound/base64url-nopad string compare; origin exact-match; `rpIdHash == SHA-256(rpId)`; UP bit masked-by-value (never `flags == const`); UV when required; **ECDSA sig is DER** (use `Signature.fromDer`, NOT raw 64); **signature base = `authData || SHA-256(clientDataJSON)`** (authData first); stored `alg` used on verify (client can't pick); signCount clone detection fail-closed; credentialId uniqueness + owner binding; reject indefinite-length CBOR + bounds-check every read; reject non-`none` attestation formats explicitly; **fail closed** on any error.
- Docs deferred to the final consolidated task (Task 9); do NOT write docs mid-milestone.

**Reuse:** `ChallengeStore` (`src/auth/challenge_store.zig`, from M3) for WebAuthn challenges. The M2 contract (`src/auth/method.zig`, `AuthCtx`, `Resolution`, `InitiateResult`) and registry. `schema.WebAuthnMethodOpts{ rp_id, rp_name, origin, credentials_collection, rate_limit }`.

---

## Task 1: Bounded CBOR decoder + COSE_Key parser

**Files:** Create `src/auth/webauthn/cbor.zig`, `src/auth/webauthn/cose.zig`; modify `src/root.zig` (test imports). Test: in both files.

**Read:** research §4 (COSE labels) + §5 (CBOR subset) + §8.4 (COSE KAT).

**Interfaces:**
```zig
// cbor.zig — definite-length only, no alloc, returns slices into input, reports bytes consumed.
pub const Value = union(enum) { uint: u64, nint: i64, bytes: []const u8, text: []const u8, map: Map, array: Array };
pub const Decoder = struct { data: []const u8, pos: usize, pub fn next(self: *Decoder) !Value; ... };
// reject indefinite-length (0x5F/0x7F/0x9F/0xBF/0xFF), major type 7, tags (or skip); bounds-check every read.
// cose.zig:
pub const CoseKey = union(enum) {
    ec2: struct { alg: i64, crv: i64, x: [32]u8, y: [32]u8 },     // ES256: alg -7, crv 1
    okp: struct { alg: i64, crv: i64, x: [32]u8 },                // Ed25519: alg -8, crv 6
    rsa: struct { alg: i64, n: []const u8, e: []const u8 },       // RS256: alg -257
};
pub fn parseCoseKey(alloc, bytes: []const u8) !struct { key: CoseKey, consumed: usize };
```

- [ ] **Step 1: Failing tests** — (a) decode the spec §6.5.1.1 EC2 COSE KAT `A5 01 02 03 26 20 01 21 58 20 <x..> 22 58 20 <y..>` → assert kty=2, alg=-7(decoded from `0x26`), crv=1, x/y 32 bytes each. (b) `0x39 01 00` decodes to nint -257 (RS256). (c) an indefinite-length item (`0x5F`) → error. (d) a truncated map → error (bounds check).
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** the decoder (handle inline 0–23 + `0x18/0x19/0x1A/0x1B` argument forms; nint value = `-1 - n`; reject indefinite + major 7) and `parseCoseKey` (branch on `kty` label 1; ES256/EdDSA read `crv`(-1)/`x`(-2)/`y`(-3); RSA reads `n`(-1)/`e`(-2) — note the `-1` label collision, branch on kty FIRST). Cap sizes (credentialId ≤ 1023, modulus ≤ 512 bytes).
- [ ] **Step 4: root.zig imports; run, pass.**
- [ ] **Step 5: Commit** — `feat(webauthn): bounded CBOR decoder + COSE_Key parser (ES256/Ed25519/RS256)`

---

## Task 2: authenticatorData byte parser

**Files:** Create `src/auth/webauthn/authdata.zig`; modify `src/root.zig`. Test: in-file.

**Read:** research §2 (`authData` byte layout §6.1, attestedCredentialData §6.5.1) + the flag-mask pitfall.

**Interfaces:**
```zig
pub const Flags = struct { up: bool, uv: bool, at: bool, ed: bool, be: bool, bs: bool };
pub const AuthData = struct {
    rp_id_hash: [32]u8,
    flags: Flags,
    sign_count: u32,                              // 32-bit BE
    cred: ?struct { aaguid: [16]u8, credential_id: []const u8, cose_key: []const u8 }, // present iff AT
    raw: []const u8,                              // the full authData bytes (for the signature base)
};
pub fn parse(alloc, bytes: []const u8) !AuthData;  // bounds-checked; flags masked by value (0x01/0x04/0x40/0x80, tolerate 0x08/0x10)
```

- [ ] **Step 1: Failing tests** — (a) a 37-byte assertion authData `sha256||0x05||00000001` → up=true, uv=true, at=false, sign_count=1. (b) flags `0x45` (UP|UV|AT|BE... actually 0x45=0x01|0x04|0x40) → at=true and parse attestedCredentialData (aaguid + credIdLen BE + credId + cose_key slice). (c) flags `0x0D` (UP|UV|BE 0x08) → up/uv true, NOT broken by BE bit (mask-by-value). (d) truncated (< 37 bytes) → error.
- [ ] **Step 2–4: TDD.** Parse rpIdHash[0..32], flags byte (mask each bit by value), signCount as BE u32 (`std.mem.readInt(u32, .., .big)`), and when AT set, aaguid[16] + credIdLen (BE u16) + credId[L] + the remaining bytes are the COSE key (its exact end is found by `cose.parseCoseKey`'s `consumed` — but for the AuthData struct, expose the cose_key as the slice from offset to end-or-extensions; if ED set, the COSE decoder's consumed length delimits it).
- [ ] **Step 5: Commit** — `feat(webauthn): authenticatorData byte parser (flags masked by value, BE signCount, attestedCredentialData)`

---

## Task 3: Signature verification (ES256 + Ed25519 + RS256 best-effort) — THE critical task

**Files:** Create `src/auth/webauthn/verify_sig.zig`; create a committed test fixture (generated deterministically in a Zig test using std crypto); modify `src/root.zig`. Test: in-file + fixture.

**Read:** research §4 (signature encodings + exact Zig std primitives) + §7 (DER-vs-raw + base-order pitfalls) + §8 (test-vector strategy).

**Interfaces:**
```zig
// signature_base = authData_bytes ++ sha256(clientDataJSON)
pub fn verify(key: cose.CoseKey, signature_base: []const u8, sig: []const u8) !bool; // dispatch on key alg
// ES256: Signature.fromDer(sig) → PublicKey.fromSec1(0x04||x||y) → sig.verify(base, pk)
// Ed25519: PublicKey.fromBytes(x) → Signature.fromBytes(sig[0..64]) → verify(base, pk)
// RS256 (best-effort, behind a comptime/runtime flag): Certificate.rsa.PublicKey.fromBytes(e,n) + PKCS1v1_5Signature.verify(len, sig, base, pk, Sha256)
```

- [ ] **Step 1: Failing tests using an IN-REPO deterministic fixture.** Generate the ES256 fixture INSIDE a Zig test (no external deps): create a `EcdsaP256Sha256` key pair from a fixed seed, build `authData` (`[32]u8 rpIdHash filler || 0x05 || BE u32 signCount=1`), build a `clientDataJSON` byte string, compute `base = authData ++ sha256(clientDataJSON)`, **sign** `base` with the private key and **DER-encode** the signature (std's `sign` returns a `Signature`; use its `.toDer()` if available, else encode r||s to DER — read `lib/std/crypto/ecdsa.zig` for the exact API). Derive the COSE EC2 key (x,y from the public key's SEC1 encoding). Then assert `verify(cose_key, base, der_sig) == true`. NEGATIVE cases (each must return false / error): flip one signature byte; flip one authData byte (base changes); pass the raw 64-byte r||s instead of DER (must NOT verify as a valid DER → error or false); truncated DER. Also add the spec §6.5.1.1 COSE KAT from Task 1 as the key-parse anchor.
   - Ed25519: analogous fixture with `std.crypto.sign.Ed25519` (raw-64 sig, no DER). Positive + tampered-negative.
   - RS256: if feasible with `Certificate.rsa` in this Zig build, a fixture; else a test asserting RS256 keys are cleanly REJECTED with a clear "unsupported" error (document the gate). Decide based on whether `std.crypto.Certificate.rsa.PublicKey.fromBytes` / `PKCS1v1_5Signature.verify` compile.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** `verify` dispatching on `key`'s alg. ES256: `EcdsaP256Sha256.Signature.fromDer` (reject raw), `PublicKey.fromSec1(&[_]u8{0x04} ++ x ++ y)`, `sig.verify(base, pk)` (it SHA-256s internally — pass the raw base, NOT a prehash). Ed25519: `PublicKey.fromBytes`, `Signature.fromBytes`, `verify`. RS256: behind a flag via `Certificate.rsa` or reject-with-error.
- [ ] **Step 4: root.zig import; run, pass.**
- [ ] **Step 5: Commit** — `feat(webauthn): signature verification (ES256 DER + Ed25519; RS256 best-effort) with in-repo fixtures`

---

## Task 4: clientDataJSON + challenge validation helpers

**Files:** Create `src/auth/webauthn/client_data.zig`; modify `src/root.zig`. Test: in-file.

**Read:** research §6 (challenge handling) + §7 (type/origin/challenge pitfalls).

**Interfaces:**
```zig
pub const ClientData = struct { type: []const u8, challenge: []const u8, origin: []const u8 };
pub fn parseClientData(alloc, json_bytes: []const u8) !ClientData;     // raw bytes also returned by caller for hashing
/// Verify type == expected ("webauthn.create"/"webauthn.get"), origin exact-match, and
/// challenge (base64url-NOPAD of the stored raw challenge) constant-time string-equals C.challenge.
pub fn verifyClientData(cd: ClientData, expected_type, expected_origin, stored_challenge_raw: []const u8, alloc) !void; // error on any mismatch
pub fn b64urlNoPad(alloc, raw: []const u8) ![]const u8;
```

- [ ] **Step 1: Failing tests** — parse a `{"type":"webauthn.get","challenge":"<b64url>","origin":"https://x.test"}`; `verifyClientData` passes with matching type/origin/challenge; fails on wrong type, wrong origin (exact-match, not prefix), wrong challenge. b64url encoding has no `=` padding. Constant-time challenge compare.
- [ ] **Step 2–4: TDD.** Compare the stored raw challenge by base64url-encoding it (no pad) and string-comparing to `C.challenge` (do NOT decode the incoming value — avoids decoder leniency). Use the constant-time slice compare from the OTP task (extract it to a shared util if clean).
- [ ] **Step 5: Commit** — `feat(webauthn): clientDataJSON parse + type/origin/challenge verification (base64url-nopad, constant-time)`

---

## Task 5: `_webauthnCredentials` store

**Files:** Modify `src/migrations.zig` (`init_0008`), create `src/auth/webauthn/store.zig`, modify `src/root.zig`. Test: in-file.

**Read:** research §1 ("what the RP stores") + the `_externalAuths` precedent (oauth.zig) for the table shape.

**Interfaces:**
```zig
// _webauthnCredentials: "id" TEXT PK (random row id), "collectionRef" TEXT, "recordRef" TEXT (user id),
//   "credentialId" TEXT UNIQUE (base64url of raw cred id), "publicKey" TEXT (base64 of COSE bytes),
//   "alg" INTEGER, "signCount" INTEGER, "aaguid" TEXT, "transports" TEXT, "created"/"updated" TEXT
pub const CredentialStore = struct {
    conn: *db.Db,
    pub fn insert(self, alloc, io, collection, record_ref, credential_id_b64, cose_pubkey_b64, alg: i64, sign_count: u32, ...) !void;
    pub fn getByCredentialId(self, alloc, credential_id_b64) !?Credential; // for assertion lookup
    pub fn updateSignCount(self, credential_id_b64, new_count: u32) !void;
    pub fn existsCredentialId(self, credential_id_b64) !bool;             // uniqueness check at registration
};
```

- [ ] **Step 1: Failing tests** — insert a credential, `getByCredentialId` returns it (recordRef, publicKey, alg, signCount); `existsCredentialId` true; `updateSignCount` updates; a second insert of the same credentialId fails (UNIQUE).
- [ ] **Step 2–4: TDD.** Migration `init_0008` (next number after 0007) — register it in the migrations list. Mirror `_externalAuths` insert/lookup patterns.
- [ ] **Step 5: Commit** — `feat(webauthn): _webauthnCredentials store (per-credential pubkey/signCount, unique credentialId)`

---

## Task 6: Registration ceremony verification (§7.1, fmt:"none")

**Files:** Create `src/auth/webauthn/register.zig`; modify `src/root.zig`. Test: in-file with a registration fixture.

**Read:** research §2 (the verbatim §7.1 steps + attestationObject + fmt:"none").

**Interfaces:**
```zig
pub const RegistrationResult = struct { credential_id: []const u8, cose_pubkey: []const u8, alg: i64, sign_count: u32, aaguid: [16]u8 };
/// Verify a registration: CBOR-decode attestationObject {fmt,authData,attStmt}; require fmt=="none" (reject others);
/// parse authData (AT must be set); verify rpIdHash==sha256(rp_id), UP set (UV per policy); verify C.type=="webauthn.create",
/// challenge, origin; verify the credential public key alg is in the offered set. Returns the credential to store.
pub fn verifyRegistration(alloc, rp_id, origin, expected_challenge_raw, client_data_json, attestation_object: []const u8, require_uv: bool) !RegistrationResult;
```

- [ ] **Step 1: Failing test** — build a registration fixture (in Zig): an `attestationObject` = CBOR map `{"fmt":"none","attStmt":{},"authData":<authData with AT set carrying aaguid(0)+credIdLen+credId+COSE_Key>}` (reuse the ES256 COSE key from Task 3's fixture), a matching `clientDataJSON` (type webauthn.create, the challenge, origin). Assert `verifyRegistration` returns the credentialId + cose key + alg matching what you built. NEGATIVE: wrong rpIdHash → error; UP not set → error; `fmt:"packed"` → error (non-none rejected); wrong challenge/origin/type → error.
- [ ] **Step 2–4: TDD** following the §7.1 step list exactly. Hash the RAW clientDataJSON bytes. Fail closed.
- [ ] **Step 5: Commit** — `feat(webauthn): registration ceremony verification (§7.1, fmt:none, ES256/Ed25519)`

---

## Task 7: Authentication ceremony verification (§7.2) + signCount clone detection

**Files:** Create `src/auth/webauthn/authenticate.zig`; modify `src/root.zig`. Test: in-file with an assertion fixture.

**Read:** research §3 (verbatim §7.2 steps) + the signCount rule.

**Interfaces:**
```zig
pub const AssertionResult = struct { new_sign_count: u32, clone_suspected: bool };
/// Verify an assertion against a stored credential: parse assertion authData; rpIdHash==sha256(rp_id); UP (UV per policy);
/// C.type=="webauthn.get", challenge, origin; signature_base = authData || sha256(clientDataJSON); verify sig with stored key.
/// signCount: if newCount>stored → ok(update); both 0 → ok(no-op); else (new<=stored, either nonzero) → clone_suspected=true.
pub fn verifyAssertion(alloc, rp_id, origin, expected_challenge_raw, stored_key: cose.CoseKey, stored_sign_count: u32,
                       client_data_json, authenticator_data, signature: []const u8, require_uv: bool) !AssertionResult;
```
v1 policy: a `clone_suspected` result is treated by the CALLER (the method) as a FAILURE (fail-closed) per research §3.

- [ ] **Step 1: Failing test** — reuse Task 3's ES256 fixture (it IS an assertion: authData+clientDataJSON+DER sig over the base). Assert `verifyAssertion` succeeds with `stored_sign_count=0`, `new_sign_count=1`. NEGATIVE: tampered signature → error; UP off → error; wrong challenge/origin → error; `stored_sign_count=5` with assertion count=1 → `clone_suspected=true`.
- [ ] **Step 2–4: TDD** following §7.2 exactly. **Signature base order = authData || sha256(clientDataJSON)** — get this exactly right (it's the #1 bug).
- [ ] **Step 5: Commit** — `feat(webauthn): authentication ceremony verification (§7.2) + signCount clone detection`

---

## Task 8: `WebAuthnMethod` on the contract + registration endpoints + wiring

**Files:** Create `src/auth/methods/webauthn.zig`; modify `src/auth/registry.zig` (built-in), `src/server.zig` (2 authed registration routes), `src/api/auth_methods.zig` or a small webauthn api file for the registration handlers, `src/root.zig`. Test: in-file.

**Read:** the M2 contract + `password.zig`/`magic_link.zig` scaffolding; research §6 (challenge issuance).

**Design:**
- **Login (the contract's initiate/complete):**
  - `initiate`: read optional `{identity}`; generate 32 random challenge bytes; `ChallengeStore.put(collection, "webauthn", identity-or-"", challenge_b64url, ttl)`; return `InitiateResult{ .status=200, .body = JSON { challenge, rpId, allowCredentials? } }` (the PublicKeyCredentialRequestOptions the browser needs). Enumeration note: for usernameless, identity may be empty.
  - `complete`: read `{credentialId, authenticatorData, clientDataJSON, signature}` (all base64url); look up the stored credential via `CredentialStore.getByCredentialId`; recover the ceremony challenge for this identity/credential from `ChallengeStore.takeByIdentity` (or by an id echoed back); `verifyAssertion(...)`; on `clone_suspected` → `.fail{401,...}`; on success `updateSignCount`, return `Resolution{ .record = credential.recordRef }`.
- **Registration (authed, NOT via the generic contract):** two static routes (auth=.authed) `/api/collections/:col/auth/webauthn/register/begin` and `/register/finish`:
  - begin: requires an authenticated user (the rctx identity); issue a challenge (ChallengeStore, keyed to the user), return `PublicKeyCredentialCreationOptions` JSON (rp, user, challenge, pubKeyCredParams=[ES256,-7; EdDSA,-8], etc.).
  - finish: `verifyRegistration(...)`; ensure `existsCredentialId` is false (uniqueness); `CredentialStore.insert(... recordRef = authed user id ...)`; return 200.
  - Config: `rp_id`/`rp_name`/`origin` from `col.options.auth.methods.webauthn.?`; if unset, 500 with a clear "webauthn not configured" message.
- Register `WebAuthnMethod` in `registry.zig` built-ins (its initiate/complete handle login; registration routes are separate).

- [ ] **Step 1: Failing test** — over `TestEnv` with a webauthn-configured collection + a user + a pre-inserted credential (from the Task 3 fixture key): drive `complete` (the login assertion) with the fixture's credentialId/authData/clientDataJSON/signature → `Resolution{ .record == user_rid }`. `initiate` returns a 200 body containing `challenge` + `rpId`. (Registration-route tests can be lighter: `verifyRegistration` is already unit-tested in Task 6; assert the finish handler stores a credential given a registration fixture + an authed ctx.)
- [ ] **Step 2–4: TDD.** Wire the method + the two registration routes. The login challenge round-trip uses ChallengeStore; be careful binding the challenge to the right ceremony so a registration challenge can't be used for login (use distinct `method` keys: "webauthn" for login, "webauthn_reg" for registration, in the ChallengeStore).
- [ ] **Step 5: Run full suite + main binary build + examples build green.**
- [ ] **Step 6: Commit** — `feat(auth): WebAuthnMethod on the contract (passkey login) + authed registration endpoints`

---

## Task 9: Consolidated docs (M1–M4) + examples + changelog + site

**Files:** `docs/framework.md` (the full Auth methods section: contract, config, built-ins password/magic_link/otp/webauthn, auto-mounted endpoints, custom `.auth_methods`, the seam guarantee), `docs/api.md` (the new endpoints), `docs/recipes.md` (already has magic-link; add a webauthn note + a custom-method sketch), `CHANGELOG.md`; all `site/src/content/docs/` mirrors. Optionally an `examples/` collection enabling a method.

- [ ] **Step 1:** Write the consolidated "Auth methods" documentation in `docs/framework.md`: the `AuthMethod` contract (`initiate`/`complete` + `AuthCtx` helpers + `Resolution`), `.auth.methods` per-collection config with the rate-limit knobs, `.auth_methods` custom-type registration (create/method/deinit), the auto-mounted `/api/collections/:col/auth/:method/{initiate,complete}` endpoints, WebAuthn's extra `register/begin`+`register/finish` endpoints, the multi-collection example (spec §6), the ChallengeStore note, and the seam/`onAuth` guarantee. State the OAuth2 scope decision (stays on its dedicated endpoints, already seam-integrated).
- [ ] **Step 2:** Update `docs/api.md` (endpoint reference) + `docs/recipes.md` (webauthn + a custom `.auth_methods` sketch). Mirror ALL into `site/src/content/docs/`.
- [ ] **Step 3:** CHANGELOG `[Unreleased]` (both copies) — the AuthMethod contract, built-in magic_link/otp/webauthn, ChallengeStore, auto-mounted endpoints, rpc-gen for auth methods.
- [ ] **Step 4:** `cd site && npm run build` passes.
- [ ] **Step 5: Commit** — `docs(auth): consolidated pluggable-auth-methods documentation (contract, built-ins, webauthn)`

---

## Self-Review

**Spec coverage (M4):** WebAuthn crypto stack T1–T4; storage T5; ceremonies T6–T7; contract method + registration + wiring T8; docs T9. **Explicitly out of scope (surfaced):** OAuth2-onto-contract refactor (stays on dedicated endpoints); WebAuthn attestation formats beyond `none` (documented future work, per research §2); a real-browser-capture integration vector (recommended follow-up — T3 uses in-repo deterministic fixtures + the spec COSE KAT).

**Highest risks:** the signature-base order + DER-vs-raw (T3/T7 — the research flags these as the #1 bugs; the in-repo fixtures + tampered-negatives are the guard); CBOR bounds-safety (T1 — reject indefinite, bounds-check every read); challenge ceremony-binding (T8 — distinct ChallengeStore method keys for login vs registration); credentialId uniqueness + owner binding (T5/T6/T8). Every pitfall in research §7 must have a corresponding test.
