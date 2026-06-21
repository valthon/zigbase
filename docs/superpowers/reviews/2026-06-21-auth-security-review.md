# Adversarial Security Review — ZigBase Authentication Surface

**Reviewer:** Senior application-security engineer (adversarial, code-traced)
**Scope:** The entire auth story — new pluggable-auth PR work (`8a59013`..`76d3d76`) **and** the pre-existing surface (JWT, sessions, cookies, password, OAuth2, verification/reset).
**Branch HEAD:** `76d3d76` (`refactor(auth): per-method conns, drop legacy`)
**Method:** Traced the real code; cited `file:line`. Two large self-contained subsystems (WebAuthn, OAuth2) were audited by dedicated subagents and cross-checked against the dispatch/session seam.

---

## Verdict

**The auth surface is fundamentally sound and is SAFE TO MERGE**, with the caveat that two `HIGH` OAuth2 findings should be addressed (or explicitly accepted + documented) before this is relied on for production OAuth logins. There are **no Critical findings** — no auth-bypass, no session-forgery, no signature-verification bypass, no `alg=none` vector, no SQL injection in the auth path. The cryptographic core (HS256 JWT with fixed-header pinning, per-record key derivation, argon2id, constant-time compares, CSPRNG token generation, single-use ledgers) is correct and well-tested.

The two `HIGH` items are **design consequences of the client-driven OAuth flow** (PKCE and CSRF `state` are delegated to / optional in the SDK rather than enforced server-side), not implementation bugs. Everything else is `Medium`/`Low`/`Info` hardening.

### Count by severity
- **Critical:** 0
- **High:** 2 (both OAuth2, both confirmed)
- **Medium:** 4
- **Low:** 6
- **Info:** several (documented inline)

### Top findings (ranked)
1. **HIGH** — OAuth2 PKCE is not generated/stored/verified server-side; the `code_verifier` is opaquely forwarded, so PKCE integrity is fully client-trusted. (`oauth/client.zig:52`; no `code_challenge` anywhere)
2. **HIGH** — OAuth2 CSRF `state` is opt-in and **off by default** (`oauth_state_server=false`), and even when on it is not bound to the browser session. (`app.zig:19`, `auth/methods/oauth2.zig:64,105`, `api/oauth.zig:111-124`)
3. **MEDIUM** — WebAuthn login does not bind the matched credential to the ceremony's collection (cross-collection record confusion). (`auth/methods/webauthn.zig:177,217` + `api/auth_methods.zig:160`)
4. **MEDIUM** — OAuth2 stores an unverified provider email into the `UNIQUE` email namespace (email squatting; `verified` flag propagated but not gated). (`api/oauth.zig:171-175`)
5. **MEDIUM** — WebAuthn COSE `crv` (curve) is never validated; **MEDIUM** — User Verification (UV) is hardcoded off with no policy knob. (`auth/webauthn/cose.zig:73-116`; `auth/methods/webauthn.zig:202`)
6. **LOW** — No `requireVerified` login gate: unverified accounts (incl. OAuth-created `verified=false`) can authenticate. (`schema.zig:132`)
7. **LOW** — Mailer fallback logs the raw verification/reset token to the application log when no mailer is wired. (`api/auth.zig:260`)

---

## What is solid (verified, not assumed)

These were traced and confirmed correct — they are the load-bearing parts and they hold.

### JWT / crypto core (`jwt.zig`, `crypto.zig`)
- **HS256 only, header pinned.** `verify` rejects any token whose header segment != the fixed `header_b64` (`jwt.zig:58`), defeating `alg=none` and alg-substitution. Negative test at `jwt.zig:161`.
- **Signature compare is constant-time** (`std.crypto.timing_safe.eql`, `jwt.zig:66`) and length-checked (`:65`).
- **Expiry enforced** (`claims.exp <= now`, `jwt.zig:71`); `now` is sourced from SQLite `unixepoch('now')`, clock-injected.
- **Per-record key derivation is sound:** `deriveKey = HMAC-SHA256(app_secret, token_key)` (`crypto.zig:37`). Rotating `token_key` (on password change / reset) invalidates all prior tokens for that record — `applyUpdate` rotates it (`auth.zig:62`). Tested at `jwt.zig:125`.
- **`peekClaims` is used only to locate the record; the claims are always re-verified** with the record's derived key before trust (`auth.zig:189-204`, `api/auth.zig:308-314`). The attacker-controlled `collection`/`id` in the peeked claims only select *which* record's key is used; a forged token then fails the HMAC check.
- **Token-type confusion is closed:** `verifyToken` requires `type==.auth` (`auth.zig:183`); the file endpoint opts into `{.auth,.file}` explicitly; `verifyTyped` requires the exact `want` type **and** `claims.collection == col.name` (`api/auth.zig:309-310`). A `magic_link` token is rejected by `verifyLinkToken` if it is actually a `.verification` token, and vice-versa (tested at `auth_helpers.zig:127`).
- **argon2id** with `interactive_2id` params (`crypto.zig:10-13`); verify is constant-time and fails closed on parse error (`crypto.zig:18-21`).
- **CSPRNG tokens.** `id.generate` uses `io.random` (OS getrandom via `std.process.Init`'s IO) with rejection sampling to avoid modulo bias (`id.zig:10-20`). `tokenKey`/`csrf`/`jti` are 32 base36 chars (~165 bits); OAuth `state` and WebAuthn challenge ids likewise. OTP codes use a separate unbiased `generateCode` (`otp.zig:41-53`).

### Session issuance seam (`api/auth.zig`)
- **There is exactly one mint path.** Every login — password, refresh, the auto-mounted method dispatch, and the consumer escape hatch — funnels through `issueSession`/`issueSessionExt` (`api/auth.zig:132-160`), which (a) requires the collection be `type==.auth`, (b) resolves the real `tokenKey` from the DB, (c) signs an `.auth` JWT via `issue()`, (d) fires `emitAuth(method)` exactly once. No path mints a session that skips the tokenKey lookup or the type check. The dispatch maps the method slug → auth tag and mints with the **URL** collection name (`auth_methods.zig:142-160`).
- **The `zigbase.auth.issueSession` escape hatch is NOT dangerous as exposed** (`auth_helpers.zig:29-36`): it requires a `conn`, a `collection`, and a `record_id`, and delegates to the same seam — it still enforces `type==.auth` and resolves the real tokenKey. A consumer can only mint a session for a record that actually exists in an auth collection. It tags `.custom`. (It does, by design, let a consumer mint a session for any record without a credential check — that is the intended "I have already authenticated this user out-of-band" primitive, equivalent to PocketBase's `authStore` server-side. Document it as such.)

### Cookies / CSRF (`api/auth.zig`, `http.zig`, `server.zig`)
- `zb_auth`: `http_only=true`, `secure=app.cookie_secure`, `same_site=.strict` (`api/auth.zig:112`). `zb_csrf`: `http_only=false` (JS must read it), same `secure`/`SameSite` (`:113`). The `SameSite` value is correctly translated to zap (`server.zig:326-331`) — i.e. `.strict` actually reaches the wire, not silently dropped.
- **Double-submit CSRF** is enforced on the cookie-auth + unsafe-method path: `authenticate` requires a non-empty `X-CSRF-Token` header that constant-time-matches the `csrf` claim (`auth.zig:273-276`). Bearer-token requests skip CSRF (correct — no ambient credential). Tested at `auth.zig:324-348`.
- **No session fixation:** the CSRF value is freshly generated per issuance (`api/auth.zig:96`) and bound into the signed JWT, so it cannot be pre-seeded by an attacker.
- `--insecure-cookies` only drops the `Secure` flag for plain-HTTP local dev; **default is `secure=true`** (`app.zig:13`, `config.zig:23`). `SameSite=Strict` + `HttpOnly` still apply, so even insecure-cookies dev retains CSRF/XSS defenses.

### Single-use ledgers
- **`_consumedTokens` (verification / password-reset / magic-link):** `consumeToken` does a `SELECT`-then-`INSERT` under the single writer lock (race-free), classifies replay by jti **presence** (not by INSERT failure, so disk-full ≠ "already consumed"), and **rejects empty jti** (`api/auth.zig:279-296`). Tested incl. the regression at `api/auth.zig:664`.
- **`_authChallenges` (OTP / WebAuthn):** atomic conditional `UPDATE ... SET consumed=1 WHERE id AND method AND consumed=0 AND expires>now`, with `changesCount()` read **before finalize** to gate single-use (`challenge_store.zig:54-80`). Method-scoped (a `webauthn_reg` challenge can't be consumed by a `webauthn` login, tested at `:190`). TTL enforced in the WHERE clause. GC sweeps consumed/expired rows.
- **`_oauthStates`:** single atomic `DELETE ... RETURNING` (`api/oauth.zig:113-123`); consumed **before** the code exchange (`oauth2.zig:105` precedes `:117`). Replay finds no row.

### Password (`auth.zig`, `api/auth.zig`, `methods/password.zig`)
- **Enumeration timing defense:** on unknown identity AND on a record with a missing hash, `dummyVerify` runs a real argon2 against a fixed valid PHC so the response time matches the hit path (`api/auth.zig:183,187`; `methods/password.zig:66,72`). Uniform `"Invalid credentials."` 400 in all miss cases.
- **Server-managed fields are stripped** from create/update — `password`/`passwordHash`/`tokenKey`/`verified` are never copied from client input (`auth.zig:19-22,36,54`); `verified` is forced `false` on create and only changes via confirm-verification. Extensively tested (`auth.zig:109-164`).
- **Reader-vs-writer split is correct and not a security regression:** password verify runs under a pooled **reader** (so argon2 doesn't serialize all writes), then the session mint acquires the writer briefly. The read→issue window is benign — the worst case is a session minted for a record being concurrently deleted, which the next request's `verifyToken` (which re-loads the record) would reject.

### OAuth2 (confirmed-solid parts)
- **HTTPS-only providers** enforced for authorize/token/userinfo, including generic-provider overrides (`api/oauth.zig:36-42`); an `http://` override is dropped (tested `:322`).
- **redirect_uri exact-match allow-list** — `std.mem.eql`, no prefix/wildcard (`api/oauth.zig:53-56,217`) — no open redirect.
- **clientSecret encryption at rest:** AES-256-GCM, **fresh random 12-byte nonce per encryption**, prepended to the blob, authenticated tag verified on decrypt (`oauth/secrets.zig:25-59`). Key = HKDF-SHA256 of the app secret with domain separation `"zigbase-oauth-secret-v1"` (`:12-17`). Versioned `v1:` prefix gives a rotation path.
- **Account-link decision tree is safe-by-default:** provider-identity already linked to a *different* record → **409** (`api/oauth.zig:246-248`); anonymous + email collides with an existing user → insert fails on the `email UNIQUE` constraint → **409** "sign in and link instead" (`:259-260`, `migrations.zig:25`). **No silent email-collision auto-link → no email-collision takeover.** GitHub's unverified-email accounts create `verified=false` records.
- **`_externalAuths` UNIQUE indexes** on `(provider, providerId)` and `(collectionRef, recordRef, provider)` (`migrations.zig:45-46`) prevent double-linking the same provider identity. Tested at `migrations.zig:212`.
- **No secret/token/code logged** in the OAuth path; `client_secret` is sent in the POST **body**, not the URL (`oauth/client.zig:52-58`); `collectionToJson` redacts `clientSecret` to `""` (`schema.zig:157`).
- **unlink last-credential guard:** authZ requires superuser-or-self; refuses to unlink the last external credential when no password is set (`api/oauth.zig:298-302`). Never touches `passwordHash` → no takeover-via-unlink.

### WebAuthn (confirmed-solid parts)
- **DER-vs-raw ES256:** uses `Ecdsa.Signature.fromDer`; raw 64-byte r‖s is rejected (`verify_sig.zig:53`, negative test `:204`).
- **Signature base** is `authenticatorData ‖ SHA-256(clientDataJSON)` in the correct order; swapped-order negative test (`verify_sig.zig:256`). RS256 → `UnsupportedAlgorithm` → reject (fail-closed).
- **Every verify path fails closed:** `verify(...) catch false; if (!ok) reject` (`authenticate.zig:112`).
- **Challenge** single-use + method-scoped + TTL (via ChallengeStore, above); origin is **exact-match** (`client_data.zig:122`), type-per-ceremony exact (`:118`), `rpIdHash == SHA256(rp_id)` enforced on both register and authenticate.
- **signCount clone detection ENFORCED** (not merely logged): `clone_suspected` → 401, skips the signCount update (`webauthn.zig:208-210`); test asserts the stored count stays put.
- **Registration is bound to the authenticated user** (`record_ref = requireAuthed()`, never body-supplied; the register routes require auth) — an attacker cannot register a passkey onto a victim's account (`api/webauthn_register.zig:139,219`).
- **credentialId UNIQUE** constraint (`migrations.zig:123`) is the real uniqueness gate; the `existsCredentialId` pre-check is a benign TOCTOU mitigated by the writer lock.
- **CBOR decoder is DoS-hardened:** definite-length only (indefinite-length + major-7 rejected), `max_depth=16`, every length bound-checked against remaining buffer, nint overflow guarded (`cbor.zig:73,97,113,117,131`). No unbounded recursion or huge-allocation vector found.

### Rate limiting (`ratelimit.zig`)
- Fixed-window, per-key, mutex-guarded, **fails open under table saturation rather than evicting live entries** (so it can't be used to OOM the process nor to reset another victim's window) (`ratelimit.zig:82-96`). Gated *before* the writer lock on the email endpoints so a limited request never holds the lock.
- **`trust_proxy` defaults false** (`app.zig:25`, `config.zig:34`): `X-Forwarded-For`/`X-Real-IP` are ignored unless explicitly trusted (`server.zig:91-92`), so a direct attacker can't spoof the rate-limit key. When untrusted-and-no-IP, the limiter falls back to keying on the submitted identity.

### JWT secret handling (`framework.zig`)
- Operator-supplied secret must be **≥32 bytes or the server refuses to start** (`framework.zig:632-635`). When unset, a 64-char CSPRNG secret is generated and persisted to `<data_dir>/.jwt_secret` with **mode `0600`** (`framework.zig:658-663`), then reused. A too-short persisted secret is regenerated.

---

## Findings

### F-OAUTH-1 — PKCE not enforced/bound server-side — **HIGH (confirmed)**
**Where:** `oauth/client.zig:52-58` forwards an opaque `code_verifier`; `code_challenge`/`S256` appears nowhere in server code. `auth/methods/oauth2.zig:71-81` `initiate` returns only `{authURL, clientId, scopes}`.
**Attack/impact:** In this client-driven flow the SDK both generates the verifier and builds the authorize URL's challenge; the server has no record binding challenge↔verifier and cannot tell whether any challenge was sent or whether `S256` (vs `plain`) was used. For public-client/generic-provider configs this removes PKCE's anti-code-injection guarantee. For confidential clients (Google/MS with `client_secret`) the secret still gates the exchange, limiting impact.
**Fix:** Move the verifier server-side — `initiate` generates `code_verifier`, stores it in `_oauthStates` keyed by `state`, returns only the `S256` `code_challenge`; `complete` looks the verifier up by `state` instead of trusting the body. This binds challenge↔verifier and makes `state` mandatory, closing F-OAUTH-1 and F-OAUTH-2 together. At minimum, document the delegation and require `oauth_state_server`.
**Needs follow-up:** Confirm the shipped SDK actually computes `S256` (spec says so; nothing enforces it).

### F-OAUTH-2 — CSRF `state` opt-in, off by default, not session-bound — **HIGH (confirmed)**
**Where:** `app.zig:19` (`oauth_state_server: bool = false`); `auth/methods/oauth2.zig:64-68` skips minting and `:105` skips verification when disabled; even when enabled, state is bound only to `(collection, provider)` and returned in the `initiate` JSON body (`api/oauth.zig:111-124`, `oauth2.zig:77-79`), not to the user's browser/session.
**Attack/impact:** With the default off, login-CSRF / forced-login / code-injection is unmitigated server-side. With it on but no session binding, anyone who obtains the `state` value can complete the flow.
**Fix:** Default `oauth_state_server` **on**; reject when state is enabled-but-absent; bind state to a session identifier (e.g. a value also set as an `HttpOnly` cookie at `initiate` and re-checked at `complete`).

### F-WA-1 — WebAuthn login not bound to ceremony collection — **MEDIUM (confirmed)**
**Where:** `auth/methods/webauthn.zig:177` (`getByCredentialId` is a **global** lookup, no collection filter), `:217` returns `cred.record_ref`; `api/auth_methods.zig:160` mints with the **URL** `col.name`. `cred.collection_ref` is read (`store.zig:75`) but never compared to `ac.collection.name`.
**Attack/impact:** A credential registered against collection A is accepted by a `webauthn` ceremony pointed at collection B; the session is minted for B. Exploitation requires a record with the *same* opaque 15-char id to exist in B (else `tokenKeyFor` fails), so it is practically improbable today — but it is a real authorization-scoping defect and becomes directly exploitable if record ids ever become shared/deterministic across auth collections.
**Fix:** After `getByCredentialId`, require `std.mem.eql(u8, cred.collection_ref, ac.collection.name)` (fail 400 otherwise); ideally scope the credential lookup and the challenge `take` by collection too.

### F-OAUTH-3 — Unverified provider email squats the UNIQUE email namespace — **MEDIUM (confirmed)**
**Where:** `api/oauth.zig:171-175` — new OAuth records are inserted with the provider-returned `email` and `verified = identity.emailVerified`, but the email is written **regardless** of `emailVerified`.
**Attack/impact:** A provider returning `email_verified:false` (or an attacker-controlled generic provider) can claim an email they don't own into a new `verified=false` record, occupying the `UNIQUE` email slot and blocking the real owner from self-registering with that address. The `(provider, providerId)` link is then trusted forever on subsequent logins.
**Fix:** When `identity.emailVerified == false`, do not store the email in the canonical `email` column (use a separate unverified slot or require a verification step) so it never occupies the UNIQUE namespace.

### F-WA-2 — COSE `crv` (curve) never validated — **MEDIUM (confirmed, low exploitability)**
**Where:** `auth/webauthn/cose.zig:73-116` — EC2 requires `alg==-7` but never asserts `crv==1` (P-256); OKP requires `alg==-8` but never asserts `crv==6` (Ed25519).
**Attack/impact:** A registering client can present a mismatched `crv`; `verify_sig` ignores `crv` and builds a P-256 key. The downstream `fromSec1`/`fromBytes` constrains the point to the implied curve, so this is contained to a spec-conformance/robustness gap, not a confirmed key-confusion bypass — but relying on the downstream library to reject is fragile.
**Fix:** Reject `crv != 1` for EC2 and `crv != 6` for OKP in `cose.zig`.

### F-WA-3 — User Verification (UV) hardcoded off, no policy knob — **MEDIUM (confirmed)**
**Where:** `auth/methods/webauthn.zig:202` and `api/webauthn_register.zig:196` pass `require_uv=false`; `schema.zig WebAuthnMethodOpts` exposes no UV option.
**Attack/impact:** RPs that want passkey-as-2nd-factor / step-up assurance cannot require UV; presence (UP) alone is accepted. Acceptable as a passkey-login default, but the absence of any opt-in is a policy gap.
**Fix:** Add `require_uv: bool` (or a `user_verification` enum) to `WebAuthnMethodOpts` and thread it into both ceremonies and the begin-response `authenticatorSelection`.

### F-AUTH-VERIFIED — No `requireVerified` login gate — **LOW (confirmed)**
**Where:** `schema.zig:132` `AuthOptions` has no verified-login option; no method checks `verified` before resolving a record. `verified` is set by confirm-verification (`api/auth.zig:361`) and OAuth create (`:175`) but never read as a gate.
**Attack/impact:** Unverified accounts — including OAuth-created `verified=false` records (see F-OAUTH-3) — can authenticate via password/magic_link/otp. This matches PocketBase's advisory-by-default stance (rules may check `verified`), but it surprises operators who assume email verification blocks login.
**Fix:** Add an optional `requireVerified` auth option that fails login (uniform 400) when `verified=0`; document that, absent it, `verified` is advisory and should be enforced in access rules.

### F-MAIL-LOG — Token logged on mailer fallback — **LOW (confirmed)**
**Where:** `api/auth.zig:256-261` — when `app.mailer == null`, `deliverToken` logs `to/subject/body` (the body contains the verification/reset token) at `info`.
**Attack/impact:** In production a mailer is normally wired; but a misconfiguration that leaves `mailer == null` writes live single-use tokens to the application log, where they may be shipped to log aggregation. The same fallback path is exposed to consumers via `zigbase.auth.deliverAuthMail`.
**Fix:** Log only `to`/`subject` (omit the body), or downgrade to `debug`, or refuse to "send" (error) when no mailer is configured in a non-dev build.

### F-RL-METHOD — Per-method rate-limit opts not honored — **LOW (confirmed)**
**Where:** `api/auth_methods.zig:103-113` — `.custom`/`.default` both fall back to the global limiter; the typed `RateLimitOpt{max,window_s}` is a documented TODO(M3).
**Attack/impact:** A collection that configures a *stricter* per-method limit silently gets the global default instead. No bypass of the global limiter; just weaker-than-configured throttling on specific methods.
**Fix:** Wire a per-method limiter keyed by `(slug, ip/ident)` honoring the typed opt.

### F-WA-4 — UNIQUE credentialId violation surfaces as 500 — **LOW (confirmed)**
**Where:** `api/webauthn_register.zig:206` + `store.zig:56` — a duplicate `credentialId` insert propagates `error.StepFailed` → 500 rather than a clean 409.
**Fix:** Map the UNIQUE-constraint failure to 409 "credential already registered".

### F-OAUTH-4 — clientSecret key shares fate with `jwt_secret` — **LOW / Info (confirmed)**
**Where:** `oauth/secrets.zig:12-17` derives the encryption key from the app/JWT secret.
**Attack/impact:** Rotating `jwt_secret` invalidates all stored client secrets; compromise of `jwt_secret` compromises both JWT signing and client-secret confidentiality (shared blast radius). Not a vuln on its own.
**Fix (optional):** Allow a separate `oauth_secret_key` to compartmentalize.

### F-OAUTH-5 — last-credential guard ignores passkey/OTP — **LOW (confirmed)**
**Where:** `api/oauth.zig:301` counts only `_externalAuths` links + `passwordHash`.
**Attack/impact:** A user whose only credentials are OAuth + a passkey is **incorrectly blocked** from unlinking OAuth (availability annoyance, not a security hole). No takeover path.
**Fix:** Make the credential count holistic (include WebAuthn), or document the guard's scope.

### F-TLS — verify token/userinfo TLS chain — **Info / needs-follow-up**
**Where:** `oauth/client.zig:92-118` uses `std.http.Client.fetch` with no insecure flag; combined with HTTPS-only this is over verified TLS. Confirm the 0.16 `std.http.Client` validates chain + hostname by default (it fails closed if the CA bundle is missing).

---

## Concurrency / atomicity notes
- All single-use redemptions (consumedTokens, authChallenges, oauthStates) run under the **single global writer mutex** (`db.zig`), so the SELECT-then-INSERT / SELECT-then-UPDATE patterns are race-free; each uses `changesCount`/`RETURNING`/PK to gate exactly-once. Verified for OTP, magic-link, WebAuthn, OAuth state.
- The **per-method connection model** (each method acquires its own reader/writer and releases before the dispatch mints) is correct: nothing holds the non-reentrant writer across a method call, so the post-`complete` `acquireWriter()` in the dispatch cannot deadlock (`auth_methods.zig:155-159`). The WebAuthn read→verify→updateSignCount window is held under one writer for the whole ceremony (`webauthn.zig:160-213`) — clone detection is atomic.

## Recommended pre-merge actions
1. Decide on F-OAUTH-1 / F-OAUTH-2: either implement server-side PKCE + default-on session-bound `state`, **or** explicitly document the SDK-delegated trust model and ship `oauth_state_server=true` as the recommended config. (Highest leverage.)
2. Add the one-line collection check in WebAuthn `complete` (F-WA-1) and the `crv` checks (F-WA-2) — cheap, fail-closed hardening.
3. Trim the mailer-fallback log (F-MAIL-LOG).
4. Consider a `requireVerified` option (F-AUTH-VERIFIED), especially given OAuth `verified=false` record creation.

Everything else (Low/Info) can be tracked as follow-ups without blocking merge.
