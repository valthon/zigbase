# Server-Side WebAuthn Verification — Implementation Reference (Zig 0.16, from scratch)

**Scope:** We are building a **Relying Party (RP) verifier** only — never an authenticator. This document
is the normative input to the implementation plan. The normative source is the W3C spec; everything is cited
against it.

**Primary sources consulted (fetched June 2026):**
- W3C Web Authentication: An API for accessing Public Key Credentials — **Level 2** (Recommendation, 2021-04-08):
  <https://www.w3.org/TR/webauthn-2/>. §6.1 Authenticator Data, §6.5.1 Attested Credential Data, §7.1
  Registering a New Credential, §7.2 Verifying an Authentication Assertion, §8.7 None Attestation. Step lists below
  are quoted verbatim from this document.
- W3C WebAuthn **Level 3** editor's draft: <https://www.w3.org/TR/webauthn-3/>. Consulted for flag-table deltas
  (BE/BS backup bits) and `topOrigin`/`crossOrigin` client-data handling.
- RFC 8949 (CBOR), RFC 8152 / RFC 9052 (COSE & COSE_Key), RFC 8230 (RSA keys for COSE), RFC 8809 (IANA WebAuthn
  registries), FIDO U2F message formats (§6.1.2 compatibility note).
- Sanity checks: MDN "Attestation and Assertion", Yubico WebAuthn developer guide, webauthn.guide, idura.eu
  "Verifying an ECDSA Signature" (DER-vs-raw confirmation).

> **L2 vs L3:** The §7.1/§7.2 verification *algorithms* are materially identical for what an RP verifier must do.
> L3's visible additions that matter to us: (a) the `flags` byte gains **Bit 3 = Backup Eligibility (BE, 0x08)**
> and **Bit 4 = Backup State (BS, 0x10)** (in L2 these were RFU); (b) explicit `C.topOrigin` / `C.crossOrigin`
> verification steps for credentials created inside iframes. Token Binding (`C.tokenBinding`) appears in L2 steps but
> is effectively dead — no browser implements it; we treat it as "if present, ignore/accept" (see pitfalls). Build
> against L2 numbering, but **mask flag bits by value (0x01/0x04/0x40/0x80), never by `== flagsByte`**, so BE/BS
> being set does not break us.

---

## 1. Ceremony overview

WebAuthn has two ceremonies. The RP server's job in each is to **verify a signed blob and update its own state**.

### Registration (attestation) — `navigator.credentials.create()`
The authenticator mints a new key pair, keeps the private key, and returns an **`AuthenticatorAttestationResponse`**
containing `clientDataJSON` + `attestationObject`. The RP verifies it and **stores the public key** so future
assertions can be checked. "Attestation" = optional proof of *what kind of authenticator* made the key; for v1 we
accept `fmt: "none"` (no proof) — see §2.

### Authentication (assertion) — `navigator.credentials.get()`
The authenticator signs a server challenge with an existing private key and returns an
**`AuthenticatorAssertionResponse`**: `clientDataJSON` + `authenticatorData` + `signature` + optional `userHandle`.
The RP looks up the stored public key by credential id and verifies the signature.

### What the RP stores per credential (from §7.1 final steps)
| Field | Source | Use |
|---|---|---|
| `credentialId` (bytes) | `authData.attestedCredentialData.credentialId` | lookup key on assertion; index by this |
| `credentialPublicKey` (COSE_Key) | `authData.attestedCredentialData.credentialPublicKey` | verify assertion signatures |
| `signCount` (u32) | `authData.signCount` at registration | clone detection (regression check) |
| `transports` (string set) | `response.getTransports()` (RECOMMENDED) | populate `allowCredentials.transports` later |
| `aaguid` (16 bytes) | `authData.attestedCredentialData.aaguid` | authenticator model id (metadata; can be all-zero for `none`) |
| `userHandle` / user id | `options.user.id` you supplied | bind credential → account |
| (L3) `BE`/`BS` bits | `authData.flags` | optional: track backup-eligible/backed-up state |

Practically, store `alg` (COSE alg id) and the decoded key material (EC x/y, or RSA n/e) alongside, so verification
doesn't re-parse CBOR on every assertion.

---

## 2. Registration verification (§7.1, verbatim ordered steps)

The spec preamble: *"In order to perform a registration ceremony, the Relying Party MUST proceed as follows:"*
Steps 1–5 are client-side ceremony setup. **The server-side verification an RP verifier implements begins where it
receives `response.clientDataJSON` and `response.attestationObject`.** Quoted steps (numbering follows the spec list;
the first few are ceremony plumbing):

1. *"Let options be a new PublicKeyCredentialCreationOptions structure configured to the Relying Party's needs…"*
2. Call `navigator.credentials.create()` … *(client)*
3. *"Let response be credential.response. If response is not an instance of AuthenticatorAttestationResponse, abort…"*
4. *"Let clientExtensionResults be the result of calling credential.getClientExtensionResults()."*
5. **"Let JSONtext be the result of running UTF-8 decode on the value of `response.clientDataJSON`."** (Strip any
   leading BOM.)
6. **"Let C … be the result of running an implementation-specific JSON parser on JSONtext."**
7. **"Verify that the value of `C.type` is `webauthn.create`."**
8. **"Verify that the value of `C.challenge` equals the base64url encoding of `options.challenge`."**
9. **"Verify that the value of `C.origin` matches the Relying Party's origin."**
10. *"Verify that the value of `C.tokenBinding.status` matches the state of Token Binding…"* — **dead in practice;
    `tokenBinding` is absent. If present and status is `supported`/`not-supported`, accept; we never used token binding.**
    *(L3 inserts here: if `C.topOrigin` present, verify the RP expects a cross-origin create and `topOrigin` matches an
    expected ancestor origin. For a v1 first-party flow `topOrigin` is absent.)*
11. **"Let `hash` be the result of computing a hash over `response.clientDataJSON` using SHA-256."** (Hash the **raw
    bytes**, not the parsed JSON.)
12. **"Perform CBOR decoding on the `attestationObject` … to obtain the attestation statement format `fmt`, the
    authenticator data `authData`, and the attestation statement `attStmt`."**
13. **"Verify that the `rpIdHash` in `authData` is the SHA-256 hash of the RP ID expected by the Relying Party."**
14. **"Verify that the User Present bit of the flags in `authData` is set."** (UP = 0x01)
15. **"If user verification is required for this registration, verify that the User Verified bit of the flags in
    `authData` is set."** (UV = 0x04)
16. **"Verify that the `"alg"` parameter in the credential public key in `authData` matches the `alg` attribute of one
    of the items in `options.pubKeyCredParams`."** (i.e. the returned key uses an algorithm you asked for.)
17. *"Verify that the values of the client extension outputs … and the authenticator extension outputs … are as
    expected…"* — **v1: ignore extensions; ED bit (0x80) being set just means trailing CBOR we don't parse.**
18. *"Determine the attestation statement format by performing a USASCII case-sensitive match on `fmt`…"*
19. *"Verify that `attStmt` is a correct attestation statement … by using the attestation statement format `fmt`'s
    verification procedure given `attStmt`, `authData` and `hash`."*
20. *"…obtain a list of acceptable trust anchors…"*
21. *"Assess the attestation trustworthiness…  • If no attestation was provided, verify that None attestation is
    acceptable under Relying Party policy. …"*
22. **"Check that the `credentialId` is not yet registered to any other user."**
23. **"If the attestation statement `attStmt` verified successfully and is found to be trustworthy, then register the
    new credential…"** → *"Associate the user's account with the `credentialId` and `credentialPublicKey` in
    `authData.attestedCredentialData`"* and *"Associate the `credentialId` with a new stored signature counter value
    initialized to the value of `authData.signCount`."* (RECOMMENDED: also store `getTransports()`.)
24. *"If the attestation statement `attStmt` successfully verified but is not trustworthy per step 21 above, the
    Relying Party SHOULD fail the registration ceremony."*

### `attestationObject` (CBOR map, §6.5.4)
```
attestationObject = {
  "fmt":      tstr,   ; e.g. "none", "packed", "fido-u2f", "tpm", "android-key", "apple"
  "authData": bstr,   ; the raw authenticator-data byte array (parse per §6.1, below)
  "attStmt":  map     ; format-specific; for "none" it is the empty map {}
}
```

### `authData` byte layout — **§6.1, EXACT** (parse `authData` bytes, not the CBOR map)
*"The authenticator data structure is a byte array of 37 bytes or more"* (offsets are byte indices):

| Offset | Len | Field | Notes |
|---|---|---|---|
| 0  | 32 | `rpIdHash` | SHA-256 of RP ID |
| 32 | 1  | `flags`   | bitfield, **bit 0 = LSB** (below) |
| 33 | 4  | `signCount` | **32-bit unsigned big-endian** |
| 37 | var | `attestedCredentialData` | **present iff AT (0x40) set** |
| …  | var | `extensions` | present iff ED (0x80) set; CBOR map (ignore in v1) |

**flags byte (§6.1):**
- Bit 0 `UP` = **0x01** — User Present (required)
- Bit 1 RFU1
- Bit 2 `UV` = **0x04** — User Verified
- Bit 3 `BE` = **0x08** — Backup Eligibility *(L3; RFU in L2)*
- Bit 4 `BS` = **0x10** — Backup State *(L3; RFU in L2)*
- Bit 5 RFU2
- Bit 6 `AT` = **0x40** — Attested credential data included
- Bit 7 `ED` = **0x80** — Extension data included

**`attestedCredentialData` (§6.5.1), present when AT set — starts at offset 37:**
| Rel.off | Len | Field | Notes |
|---|---|---|---|
| 0  | 16 | `aaguid` | authenticator model GUID (all-zero allowed for `none`) |
| 16 | 2  | `credentialIdLength` (= L) | **16-bit unsigned big-endian** |
| 18 | L  | `credentialId` | the lookup key you store |
| 18+L | var | `credentialPublicKey` | **COSE_Key, CTAP2 canonical CBOR** — see §4 |

The COSE_Key is the *last* item before extensions; **its length is not given** — you learn where it ends by fully
decoding the CBOR map (the decoder reports bytes consumed). After it, if ED is set, an extensions CBOR map follows.

### What `fmt: "none"` means (§8.7 None Attestation, verbatim)
*"The none attestation statement format is used to replace any authenticator-provided attestation statement when a
WebAuthn Relying Party indicates it does not wish to receive attestation information."* Syntax: `attStmt` is the
**empty map `{}`**. Verification procedure: *"Return implementation-specific values representing attestation type None
and an empty attestation trust path."*

So for `none`, **steps 18–21 are trivial** (no signature, no cert chain, no trust anchor). **Everything else in §7.1
still applies** — you MUST still: parse and verify `clientDataJSON` (type/challenge/origin, steps 5–11), CBOR-decode
the attestation object (12), verify `rpIdHash` (13), UP (14)/UV (15), check `alg` is one you offered (16), ensure
`credentialId` is unique (22), and store the key/signCount (23). `none` removes the *attestation-trust* checks, not
the *binding* checks. **Document `packed` / `tpm` / `fido-u2f` / `android-key` / `apple` as future work** — each has
its own §8 verification procedure (signature over `authData || hash` with a cert chain to a FIDO MDS trust anchor).

> Browsers usually downgrade attestation to `none` unless the RP requested `attestation: "direct"`. Accepting only
> `none` in v1 is the common, safe starting point (this is what passkeys.dev/most passkey deployments do).

---

## 3. Authentication / assertion verification (§7.2, verbatim ordered steps)

Inputs the verifier receives: `credentialId` (= `credential.id`/`rawId`), `authenticatorData`, `clientDataJSON`,
`signature`, optional `userHandle`. Preamble: *"In order to perform an authentication ceremony, the Relying Party
MUST proceed as follows:"* Quoted (steps 1–4 are client plumbing):

5. **"If `options.allowCredentials` is not empty, verify that `credential.id` identifies one of the public key
   credentials listed in `options.allowCredentials`."** (For usernameless/discoverable flows `allowCredentials` is
   empty — skip.)
6. **"Identify the user being authenticated and verify that this user is the owner of the public key credential source
   … identified by `credential.id`."** — *If the user was pre-identified (username/cookie): if `response.userHandle`
   is present, verify it maps to the same user. If the user was NOT pre-identified: verify `response.userHandle` is
   present and identifies the credential's owner.*
7. **"Using `credential.id` … look up the corresponding credential public key and let `credentialPublicKey` be that
   credential public key."**
8. **"Let `cData`, `authData` and `sig` denote the value of `response`'s `clientDataJSON`, `authenticatorData`, and
   `signature` respectively."**
9. **"Let `JSONtext` be the result of running UTF-8 decode on the value of `cData`."** (Strip BOM.)
10. **"Let `C` … be the result of running an implementation-specific JSON parser on `JSONtext`."**
11. **"Verify that the value of `C.type` is the string `webauthn.get`."**
12. **"Verify that the value of `C.challenge` equals the base64url encoding of `options.challenge`."**
13. **"Verify that the value of `C.origin` matches the Relying Party's origin."**
14. *"Verify that the value of `C.tokenBinding.status` matches…"* — **dead; handle as in registration step 10.**
    *(L3: same optional `C.topOrigin` handling as registration.)*
15. **"Verify that the `rpIdHash` in `authData` is the SHA-256 hash of the RP ID expected by the Relying Party."**
16. **"Verify that the User Present bit of the flags in `authData` is set."** (UP = 0x01)
17. **"If user verification is required for this assertion, verify that the User Verified bit of the flags in
    `authData` is set."** (UV = 0x04)
18. *"Verify that the values of the client extension outputs … are as expected…"* — **v1: ignore.**
19. **"Let `hash` be the result of computing a hash over the `cData` using SHA-256."** (raw `clientDataJSON` bytes)
20. **"Using `credentialPublicKey`, verify that `sig` is a valid signature over the binary concatenation of `authData`
    and `hash`."**
    > **Signature base = `authenticatorData` bytes (the raw assertion `authenticatorData`, ~37 bytes, no
    > attestedCredentialData) `||` SHA-256(clientDataJSON) (32 bytes).** Order is **authData first, then the 32-byte
    > hash**. For ES256/RS256 you then SHA-256 *that* concatenation as part of the algorithm; for Ed25519 the message
    > is the concatenation itself (Ed25519 hashes internally). See §4.
21. **signCount step (verbatim):** *"Let `storedSignCount` be the stored signature counter value associated with
    `credential.id`. If `authData.signCount` is nonzero or `storedSignCount` is nonzero, then run the following
    sub-step: If `authData.signCount` is — **greater than `storedSignCount`:** Update `storedSignCount` to be the
    value of `authData.signCount`. — **less than or equal to `storedSignCount`:** This is a signal that the
    authenticator may be cloned … Relying Parties should incorporate this information into their risk scoring. Whether
    the Relying Party updates `storedSignCount` in this case, or not, or fails the authentication ceremony or not, is
    Relying Party-specific."*
22. *"If all the above steps are successful, continue … Otherwise, fail the authentication ceremony."*

**Our signCount rule (decide explicitly):** if `newCount > stored` → accept and update stored. If both are 0 → accept,
do nothing (counter unsupported by that authenticator — common for passkeys). If (`newCount != 0` or `stored != 0`)
and `newCount <= stored` → **clone signal**. v1 policy: **reject the assertion AND log/flag the credential for review**
(fail-closed is the safer default for a backend like ours; passkeys that always report 0 are unaffected because the
"both zero" branch exempts them).

---

## 4. COSE_Key formats + signature algorithms

`credentialPublicKey` is a COSE_Key (RFC 9052/8152) in CTAP2 canonical CBOR. It is a CBOR **map with integer labels**.

**Common labels:** `kty` = **1**, `alg` = **3**. Key-type values: `OKP` = 1, `EC2` = 2, `RSA` = 3.

| Alg | COSE `alg` id | kty | Type-specific labels |
|---|---|---|---|
| **ES256** | **-7** | EC2(2) | `crv` = **-1** (P-256 = 1), `x` = **-2** (bstr 32B), `y` = **-3** (bstr 32B) |
| **EdDSA/Ed25519** | **-8** | OKP(1) | `crv` = **-1** (Ed25519 = 6), `x` = **-2** (bstr 32B, compressed point) |
| **RS256** | **-257** | RSA(3) | `n` = **-1** (bstr, modulus, big-endian), `e` = **-2** (bstr, exponent, usually `01 00 01`) |
| (PS256) | -37 | RSA(3) | same n/e (RSASSA-PSS) — not in v1 |

Verbatim COSE_Key examples from §6.5.1.1 confirm these labels (EC2 `{1:2, 3:-7, -1:1, -2:x, -3:y}`; RSA RS256
`{1:3, 3:-257, -1:n, -2:e}`). Note the label collision: `-1` means `crv` for EC2/OKP but `n` for RSA — **branch on
`kty` first**, then read type-specific labels.

### Signature encodings WebAuthn uses + Zig 0.16 std primitives

**ES256 (mandatory for v1).** WebAuthn ECDSA signatures are **ASN.1 DER `SEQUENCE { r INTEGER, s INTEGER }` — NOT
raw `r||s`.** This is the single most common implementation bug. Each INTEGER is minimally-encoded big-endian and may
carry a leading `0x00` if its top bit is set; `r`/`s` can therefore be 31, 32, or 33 bytes on the wire — you must
left-pad to 32 to get the raw scalar.
- **Zig handles DER natively:** `std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.fromDer(der_slice)` parses the DER
  blob straight into `{ r:[32]u8, s:[32]u8 }` (verified in `lib/std/crypto/ecdsa.zig`, Zig 0.16.0). Then build the
  public key and verify:
  ```zig
  const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
  // COSE x,y (32B each) -> uncompressed SEC1 point: 0x04 || x || y  (65 bytes)
  var sec1: [65]u8 = undefined; sec1[0] = 0x04; @memcpy(sec1[1..33], &x); @memcpy(sec1[33..65], &y);
  const pk  = try Ecdsa.PublicKey.fromSec1(&sec1);   // fromSec1 accepts the 0x04 prefix
  const sig = try Ecdsa.Signature.fromDer(der_sig);
  try sig.verify(signature_base, pk);                // signature_base = authData || sha256(clientDataJSON)
  ```
  `EcdsaP256Sha256.Signature.verify(msg, pk)` SHA-256-hashes `msg` internally, so pass the **raw concatenation**
  (authData || 32-byte hash), not a pre-hash. (`verifyPrehashed` also exists if you ever want to hash yourself.)

**EdDSA / Ed25519 (include in v1 — trivial in Zig).**
- `std.crypto.sign.Ed25519` exists. COSE OKP `x` (32 bytes) is exactly the Ed25519 public key encoding.
  ```zig
  const Ed = std.crypto.sign.Ed25519;
  const pk  = try Ed.PublicKey.fromBytes(cose_x);     // 32 bytes
  const sig = Ed.Signature.fromBytes(sig64);          // raw 64-byte signature, NOT DER
  try sig.verify(signature_base, pk);                 // Ed25519 message = the concatenation itself
  ```
  No DER, no separate hashing — the cleanest path.

**RS256 (RSASSA-PKCS1-v1_5 + SHA-256, alg -257).** Signature is a raw big-endian integer of `modulus_len` bytes
(256 for RSA-2048) — **not DER-wrapped**.
- **`std.crypto` has no public top-level RSA module.** However, Zig 0.16 ships a working PKCS#1 v1.5 RSA verifier
  inside `std.crypto.Certificate.rsa` (used by TLS cert verification, `lib/std/crypto/Certificate.zig`). It is `pub`:
  ```zig
  const rsa = std.crypto.Certificate.rsa;
  const pub_key = try rsa.PublicKey.fromBytes(cose_e, cose_n);  // (exponent, modulus) big-endian bstrs
  try rsa.PKCS1v1_5Signature.verify(modulus_len, sig.*, msg, pub_key, std.crypto.hash.sha2.Sha256);
  ```
  `verify`/`concatVerify` do EMSA-PKCS1-v1_5 encode + modular exp + constant-comparison; `max_modulus_bits = 4096`.
  `modulus_len` is comptime, so you'll branch on common sizes (256 for 2048-bit, 384 for 3072, 512 for 4096).
- **Feasibility verdict: RS256 IS feasible with Zig 0.16 std**, but only via this **semi-internal `Certificate.rsa`
  API** (no stability guarantee across Zig versions). **Recommendation:** keep RS256 **behind a flag / clearly
  marked as "best-effort via Certificate.rsa"**, with a fallback of "documented-unsupported" if a future Zig hides
  that namespace. Platform/roaming authenticators that use RS256 are now rare (mostly older Windows Hello TPMs);
  ES256 + Ed25519 cover the modern passkey ecosystem.

### Recommended **v1 algorithm set**
Offer in `pubKeyCredParams` and accept on verify, in order:
1. **ES256 (-7)** — mandatory; the universal default. (P-256 + DER decode via `fromDer`.)
2. **EdDSA/Ed25519 (-8)** — include; it's the easiest path in Zig std and supported by some authenticators.
3. **RS256 (-257)** — implement via `Certificate.rsa` but treat as best-effort/secondary; document the dependency.

---

## 5. The minimal CBOR decoder needed

You only decode RP-inbound structures (`attestationObject` and `COSE_Key`); you never *encode* CBOR. You need a
**bounded, definite-length-only** decoder. Required CBOR major types (RFC 8949 §3):

| Major type | Decode? | Why |
|---|---|---|
| 0 — unsigned int | **yes** | COSE labels/values (`kty`, `alg` ids ≥ 0, crv ids), map counts |
| 1 — negative int | **yes** | COSE labels are negative (`crv`=-1, `x`=-2, `y`=-3) and alg ids are negative (-7, -8, -257). Value = `-1 - n`. |
| 2 — byte string | **yes** | `authData`, COSE `x`/`y`/`n`/`e`, credentialId bytes |
| 3 — text string | **yes** | `fmt`, the COSE map has none but attestationObject keys ("fmt","authData","attStmt") are text strings |
| 4 — array | **minimal** | only to *skip* (some attStmt fields use arrays of certs; for `none` not needed). Implement skip for robustness. |
| 5 — map | **yes** | attestationObject and COSE_Key are maps |
| 6 — tag | **skip** | shouldn't appear in canonical COSE/attestation; if seen, skip the tag and decode the tagged item, or reject |
| 7 — float/simple | **no** (reject) | not used here |

**Restrictions to enforce (and that simplify the decoder):**
- **Definite-length only.** CTAP2 canonical CBOR forbids indefinite-length (no `0x5F/0x7F/0x9F/0xBF/0xFF`).
  Reject indefinite-length items.
- Argument encodings: handle the 1-byte inline (0–23), and `0x18`(u8)/`0x19`(u16)/`0x1A`(u32)/`0x1B`(u64) follow-on
  length forms. signCount/credentialIdLength are read **separately as raw big-endian from the authData byte array**,
  not via CBOR.
- The decoder must be **bounds-checked against the input slice** and **report bytes consumed** (so you can find where
  the COSE_Key ends inside `authData`). No allocation needed — return slices into the input.
- You do **not** need: floats, bignums-as-tags, indefinite strings, maps with non-int/non-text keys, canonical-order
  enforcement (accept any order; just read the labels you care about and ignore unknown ones).

This is ~150–250 lines of Zig, not a CBOR library.

---

## 6. Challenge handling

- **RP-generated**, **cryptographically random, ≥ 16 bytes** (spec §13.4.3 recommends ≥ 16 bytes of entropy; use
  32 bytes from a CSPRNG). Use `std.crypto.random` / `std.crypto.random.bytes`.
- **Single-use** and **time-limited**: issue → store in a TTL'd `ChallengeStore` keyed to the ceremony/session →
  on verify, look up, compare, **delete** (consume) regardless of outcome. Bind it to the ceremony type so a
  registration challenge can't be replayed into authentication.
- **Encoding:** the browser's `clientDataJSON.challenge` is **base64url WITHOUT padding** of the raw challenge bytes
  (RFC 4648 §5, no `=`). §7.1 step 8 / §7.2 step 12 say compare `C.challenge` to *"the base64url encoding of
  `options.challenge`."* Practically: base64url-encode your stored raw challenge (no padding) and **string-compare**
  to `C.challenge` — do NOT base64url-decode the incoming value (avoids decoder-leniency mismatches).
- TTL suggestion: 60–300 s. Reject expired/unknown/already-consumed challenges fail-closed.

---

## 7. Security pitfalls / MUST-checks (turn each line into a test)

- [ ] **Hash the RAW `clientDataJSON` bytes**, not a re-serialized/parsed copy (byte-for-byte; JSON re-encoding
      changes the hash → signature fails or, worse, a forged-field passes if you hash your own re-encoding).
- [ ] **`type`** must equal `"webauthn.create"` (reg) / `"webauthn.get"` (auth). Mismatch = reject (prevents
      cross-ceremony token reuse).
- [ ] **Challenge** verified, single-use, TTL-bounded, ceremony-bound. Never skip; never reuse. Compare base64url
      strings, constant-time.
- [ ] **Origin** exact-match against your expected RP origin(s) (scheme+host+port). No prefix/substring matching.
- [ ] **`rpIdHash` == SHA-256(rpId)** in authData — both ceremonies.
- [ ] **UP (0x01) set.** Mask the bit; never compare the whole flags byte to a constant (BE/BS/ED set legitimately).
- [ ] **UV (0x04)** checked when your policy requires user verification.
- [ ] **ECDSA signature is DER**, decode r/s (use `Signature.fromDer`); never feed raw 64 bytes to a P-256 verifier
      (and never feed DER to Ed25519, which wants raw 64 bytes).
- [ ] **Signature base order = `authData || SHA-256(clientDataJSON)`** — authData first, 32-byte hash second. Wrong
      order or hashing authData too = silent verification failure (or a vector for confusion).
- [ ] **`alg` returned matches one you offered** (reg step 16) and the **stored `alg` is used on verify** — don't let
      the client pick the algorithm at verify time.
- [ ] **signCount regression / clone detection** implemented per §6 rule; don't silently accept a decreasing counter.
- [ ] **credentialId confusion:** look up by the *exact* credentialId bytes; ensure the credential belongs to the
      claimed user (assertion step 6 / userHandle binding); enforce uniqueness at registration (step 22).
- [ ] **Constant-time compare** for challenge and any secret-ish equality (`std.crypto.timing_safe.eql`).
- [ ] **Reject indefinite-length CBOR / unexpected major types**; bounds-check every read; cap input sizes
      (credentialIdLength ≤ 1023 per CTAP, modulus ≤ 4096 bits, authData length sane).
- [ ] **Fail closed** on any parse/verify error (mirrors our `rules.zig` philosophy: errors → deny, never allow).
- [ ] **Don't trust attestation you didn't verify:** for v1 only `fmt:"none"` is accepted; reject other `fmt`
      values rather than silently treating them as `none`.

---

## 8. Test-vector strategy (TDD the ES256 path first)

Goal: a known-good ES256 assertion the Zig verifier must accept, plus negative cases.

1. **Generate a deterministic fixture (recommended, fully in-repo).** Write a tiny Python/Node helper (build-time
   only, not shipped) that:
   - generates a P-256 key pair;
   - builds `authenticatorData` = `sha256(rpId) || flags(0x05 = UP|UV) || signCount(=1, BE u32)` (no
     attestedCredentialData for assertion);
   - builds a realistic `clientDataJSON` = `{"type":"webauthn.get","challenge":"<b64url>","origin":"https://example.test"}`;
   - computes `signature = ECDSA_SHA256_sign(privkey, authData || sha256(clientDataJSON))` and emits it **DER-encoded**;
   - dumps: COSE_Key bytes (CBOR), authData (hex), clientDataJSON (raw bytes), signature (DER hex), the raw challenge.
   Commit these as a fixture. The Zig test asserts `verify(...) == ok`, then mutates one byte of the signature /
   flips UP off / corrupts the challenge / truncates DER and asserts each is **rejected**. This gives full control of
   every field and exercises the DER decode + `authData||hash` path. Cross-check the *same fixture* verifies green in
   a reference lib (e.g. Python `fido2`/`webauthn`, or `node @simplewebauthn/server`) before trusting it.

2. **Registration fixture:** similarly emit an `attestationObject` with `fmt:"none"`, `attStmt:{}`, and an `authData`
   that has AT set (0x41) carrying aaguid(0) + credentialIdLength + credentialId + the COSE_Key. Assert the verifier
   extracts the same COSE key bytes you generated.

3. **Real-authenticator capture (optional cross-check).** Use a public WebAuthn tester (e.g.
   psteniusubi/webauthn-tester, or a local SimpleWebAuthn demo) with a platform authenticator/virtual authenticator
   in Chrome DevTools, and capture one real registration + assertion JSON. Feed those exact bytes through the Zig
   verifier as an integration test — this catches base64url/encoding-edge mismatches the synthetic fixture might miss.

4. **COSE/CBOR unit vectors:** take the verbatim COSE_Key example from spec §6.5.1.1 (`A5 01 02 03 26 20 01 21 58 20
   <x32> 22 58 20 <y32>`) as a decoder known-answer test: assert your CBOR decoder yields kty=2, alg=-7, crv=1, and
   the right 32-byte x/y. For negative ints, assert `0x26` decodes to -7 and `0x39 01 00` (RS256, -257) decodes
   correctly.

5. **Ed25519 & RS256:** generate analogous fixtures with the same harness (Ed25519 raw-64 sig; RS256 raw
   `modulus_len` sig + `n`/`e` COSE bytes) once those code paths exist.

---

## Implementation checklist (summary)

1. Write a **bounded definite-length CBOR decoder** (major types 0,1,2,3,5; skip 4/6; reject 7/indefinite; report
   bytes-consumed; no alloc). Unit-test with spec §6.5.1.1 COSE vectors.
2. Write a **COSE_Key parser**: branch on `kty`, read ES256(EC2 x/y), EdDSA(OKP x), RS256(RSA n/e); reject unknown
   `alg`; store `alg` + key material.
3. Write an **authData byte parser** (rpIdHash[32], flags[1], signCount[4 BE], optional attestedCredentialData =
   aaguid[16]+credIdLen[2 BE]+credId[L]+COSE_Key); mask flags by value.
4. Implement a **TTL'd, single-use, ceremony-bound ChallengeStore**; 32 random bytes; compare as no-pad base64url
   strings, constant-time.
5. **Registration verify (§7.1):** UTF-8 decode clientDataJSON → JSON; check type=`webauthn.create`,
   challenge, origin; SHA-256 raw clientDataJSON; CBOR-decode attestationObject; require `fmt:"none"` (v1);
   verify rpIdHash, UP(, UV); check `alg` offered; ensure credentialId unique; **store** credentialId/COSE key/
   signCount/transports/aaguid/user.
6. **Authentication verify (§7.2):** look up credential by id; verify owner/userHandle; check type=`webauthn.get`,
   challenge, origin; SHA-256 raw clientDataJSON; parse assertion authData; verify rpIdHash, UP(, UV);
   **signature base = authData || hash**; verify with stored key per `alg`.
7. **ES256:** `Signature.fromDer` → `PublicKey.fromSec1(0x04||x||y)` → `verify(base, pk)`.
8. **Ed25519:** `PublicKey.fromBytes(x)` + raw-64 `Signature.fromBytes` → `verify(base, pk)`.
9. **RS256 (best-effort):** `std.crypto.Certificate.rsa.PublicKey.fromBytes(e,n)` + `PKCS1v1_5Signature.verify(len,
   sig, base, pk, Sha256)`; gate behind a flag; document the `Certificate.rsa` dependency. (No top-level std RSA.)
10. **signCount clone check:** if either count nonzero and new ≤ stored → fail + flag; else update stored; both-zero
    is a no-op pass.
11. **Fail closed** on every parse/verify/CBOR error. Reject non-`none` attestation formats explicitly.
12. **TDD:** synthetic ES256 fixture (positive + tampered negatives), cross-checked against a reference lib; then
    registration fixture; then a real-browser capture integration test; then Ed25519/RS256 fixtures.
13. **Mask flag bits by value** (0x01/0x04/0x40/0x80; tolerate BE 0x08 / BS 0x10 from L3) — never `flags == const`.
14. Keep docs/examples and `site/src/content/` in sync if this surfaces in framework config (per repo conventions).
