# ZigBase Sub-Project 5: Auth — Design

**Date:** 2026-06-09
**Status:** Approved (design); three implementation plans (5a, 5b, 5c) to follow.
**Depends on:** SP1–SP4 (Foundation, Collections, Records, Access Rules) — all merged to `main`.
**Fills:** the `RequestContext` auth seam established in SP4.

---

## 1. Overview & Goals

SP5 adds authentication: password-based login issuing JWTs, auth collections (users) and a
built-in `_superusers` collection, and a bearer/cookie middleware that populates the
`RequestContext` so SP4's access rules enforce real identity. Security is a first-class goal:
argon2id password hashing, per-record token-key salting, and XSS-resistant httpOnly-cookie
transport with double-submit CSRF protection alongside bearer tokens.

### Decomposition (three plans, each independently testable)
- **5a — Crypto:** `crypto.zig` (argon2id hash/verify) + `jwt.zig` (HS256 sign/verify, base64url,
  typed claims, per-record signing key) + token-key generation. Pure, unit-tested.
- **5b — Auth model:** auth-collection support in the schema/record engine (system columns,
  hidden password/token fields, configurable identity), the `options` column on `_collections`,
  the `_superusers` system collection (migration), password handling on record create/update,
  and a `superuser create` CLI command.
- **5c — Endpoints + middleware:** the auth REST endpoints, request/response header support, the
  bearer/cookie token middleware (filling `RequestContext`, enforcing CSRF), cookie issuance,
  and superuser-gating of collection management.

### In scope
- Password login (configurable identity: email and/or username) → JWT.
- `_superusers` system auth collection + `superuser create` CLI.
- argon2id hashing; HS256 JWT with per-record `tokenKey` salt (password change ⇒ token
  invalidation).
- httpOnly+Secure+SameSite cookie transport **and** `Authorization: Bearer`; double-submit CSRF
  (bound to a `csrf` JWT claim) on the cookie path for unsafe methods.
- Auth-refresh, logout, and **generated** email-verification / password-reset tokens (no email
  delivery).
- Middleware populating `RequestContext.auth`/`is_superuser`; superuser-gated `/api/collections`.

### Out of scope (deferred)
- Email/SMTP delivery (verification/reset tokens are returned in the response, not emailed).
- OAuth2 (SP6). Realtime auth (SP7). Rate limiting on login.
- Enforcing `verified == true` for login (the flag is set/cleared but not a login gate yet).

---

## 2. Crypto (`src/crypto.zig` + `src/jwt.zig`)

### Passwords — `crypto.zig`
- `hashPassword(alloc, password) ![]u8` → argon2id PHC string (via `std.crypto.pwhash.argon2.strHash`
  with interactive params), stored in `passwordHash`.
- `verifyPassword(alloc, phc, password) bool` → `std.crypto.pwhash.argon2.strVerify` (constant-time;
  returns false on mismatch, never leaks timing of the compare).
- `genTokenKey(io, alloc) ![]u8` → a 32-char random string (base62) used as the per-record salt.
- `genCsrf(io, alloc) ![]u8` → a random token for the `csrf` claim.

### JWT — `jwt.zig`
- HS256 (`std.crypto.auth.hmac.sha2.HmacSha256`), compact `header.payload.signature`, base64url
  (unpadded) for all three segments.
- `pub const TokenType = enum { auth, verification, password_reset };`
- `pub const Claims = struct { id: []const u8, collection: []const u8, type: TokenType, csrf: []const u8 = "", iat: i64, exp: i64 };`
- `sign(alloc, claims, key) ![]u8` and `verify(alloc, token, key) JwtError!Claims` (validates the
  signature, then `exp`; returns `error.Expired`/`error.BadSignature`/`error.Malformed`).
- **Per-record signing key:** the HMAC key for a record's token is
  `HMAC-SHA256(app_jwt_secret, record.tokenKey)` (a `crypto.deriveKey(app_secret, tokenKey)` helper).
  Verification therefore requires loading the record to obtain its `tokenKey` (done by the
  middleware/endpoints, not by `jwt.verify` itself — `verify` takes the already-derived key).
- The app secret comes from `Config.jwt_secret` (SP1).

All crypto is pure and unit-tested (hash/verify round-trip; sign/verify; tamper → BadSignature;
past `exp` → Expired; a different `tokenKey`-derived key → BadSignature, i.e. token invalidation).

---

## 3. Auth Collections (`type: "auth"`)

An auth collection's physical table has, beyond `id/created/updated`, fixed **auth system
columns**: `email` TEXT, `username` TEXT, `passwordHash` TEXT, `tokenKey` TEXT, `verified`
INTEGER. The schema engine's DDL emits these when `collection.type == .auth` (with unique
indexes on non-empty `email` and, when used, `username`). User-defined fields follow.

- **Engine generality:** loading an auth collection injects a synthetic `authSystemFields()`
  set (email/username = text; passwordHash/tokenKey = text **hidden**; verified = bool) into the
  field list the record engine iterates, so `get`/`list`/`create`/`update` handle them
  generically. **`passwordHash` and `tokenKey` are `hidden` and never serialized** into API
  responses (a `Field.hidden` flag is added; `rowToObject`/serialization skip hidden fields).
- **Auth options** (per collection): `identityFields: []const []const u8` (default `["email"]`;
  may include `"username"`) and `minPasswordLength: u8` (default 8). Stored in a new
  **`options` JSON column** on `_collections` (migration `0002`); `Collection` gains an
  `options: CollectionOptions` (with an `auth` sub-struct). `parseCollectionInput`/`collectionToJson`
  read/write it.

### Superusers
A system auth collection **`_superusers`** created by migration `0002`: `type=auth`,
`system=true`, identity `["email"]`, no user fields. The same machinery logs them in.
`is_superuser` ≡ the authenticated record's collection name is `_superusers`.

---

## 4. Password Handling on Record Create/Update

The auth-aware path (an `auth.zig` helper used by the record handlers for auth collections):
- **create:** require a `password` (≥ `minPasswordLength`); enforce identity uniqueness; compute
  `passwordHash = hashPassword(password)`; `tokenKey = genTokenKey()`; default `verified = 0`.
  These are injected into the record data for the synthetic system fields, then the engine
  inserts. `password` is never a stored column.
- **update with a new `password`:** re-hash **and rotate `tokenKey`** (invalidating existing
  tokens). Other field updates leave `passwordHash`/`tokenKey` untouched.
- Responses **strip** `passwordHash`/`tokenKey` (hidden fields).

(Base collections are unaffected — this path only runs for `type == .auth`.)

---

## 5. Endpoints (`src/api/auth.zig`)

All under `/api/collections/:col/...` where `:col` resolves to an auth collection (else 404).

| Method & path | Behavior | Success |
|---|---|---|
| `POST .../auth-with-password` | `{identity, password}`; find the record where any configured identity field == `identity`; `verifyPassword`; on success issue an auth JWT | 200 `{token, csrf, record}` + Set-Cookie |
| `POST .../auth-refresh` | valid bearer/cookie auth for this collection → new token (same identity) | 200 `{token, csrf, record}` + Set-Cookie |
| `POST .../logout` | clears the auth + csrf cookies | 204 |
| `POST .../request-verification` | `{identity}` → a `verification` token (NOT emailed) | 200 `{token}` |
| `POST .../confirm-verification` | `{token}` → set `verified=1` | 204 |
| `POST .../request-password-reset` | `{identity}` → a `password_reset` token | 200 `{token}` |
| `POST .../confirm-password-reset` | `{token, password}` → set new password (+ rotate tokenKey) | 204 |

- **Failed login** returns a generic `400 "Invalid credentials."` (no user-existence leak);
  argon2 verify runs on a dummy hash when the identity is unknown to avoid timing leaks.
- The auth/verification/reset JWTs use the appropriate `TokenType`; verification/reset tokens are
  short-TTL and single-purpose (the `type` claim is checked at confirm time).

---

## 6. Transport, Middleware & the `RequestContext` Seam

### Request/response header support (Foundation extension)
- `http.RequestCtx` gains `headers` access — `server.zig`'s `onRequest` copies the request's
  `Authorization`, `Cookie`, and `X-CSRF-Token` (via zap's `getHeader`) into the ctx. A small
  cookie parser extracts named cookies from the `Cookie` header.
- `http.Response` gains `extra_headers: []const Header` (supporting multiple `Set-Cookie`);
  `server.zig` writes them onto the zap response.

### Cookies (issued by login/refresh; cleared by logout)
- `zb_auth=<jwt>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=<ttl>`
- `zb_csrf=<csrf>; Secure; SameSite=Strict; Path=/; Max-Age=<ttl>` (readable — the double-submit
  value, equal to the JWT's `csrf` claim).
- **`Secure` is config-gated** (`Config.cookie_secure`, default true; disabled by a `--dev` flag
  or when bound to plain http) so cookies work in local dev.

### Middleware — `auth.authenticate(ctx) -> ?AuthedRecord`
1. Resolve the raw token: `Authorization: Bearer <t>` **or** the `zb_auth` cookie (note which
   source).
2. Decode claims (collection, id) → load that record → derive its key from `tokenKey` →
   `jwt.verify` (signature + exp). On any failure → unauthenticated (`null`), not an error.
3. **CSRF:** if the token came from the **cookie** and the method is unsafe
   (POST/PATCH/PUT/DELETE), require `X-CSRF-Token == claims.csrf`; mismatch → `error.CsrfFailed`
   (mapped to 403). The bearer path skips CSRF.
4. Returns the authenticated record + whether its collection is `_superusers`.

`buildContext` (currently empty) calls `authenticate` and sets `RequestContext.auth` = the record
object and `is_superuser`. **SP4 rules need no change** — `decide` already bypasses superusers and
`@request.auth.*` now resolves to real values.

### Superuser-gating collection management
`api/collections.zig`'s five handlers now require `is_superuser` (was `// TODO(SP5)`): build the
context, and if not a superuser return 403 (list/get may instead 404 to hide — but collections
are admin metadata, so **403** is fine here). This closes the "collections API is open" gap.

---

## 7. Security Summary

- Passwords: argon2id (memory-hard), PHC-encoded; constant-time verify; dummy-hash verify on
  unknown identity (timing).
- Tokens: HS256 signed with a **per-record** key (`HMAC(app_secret, tokenKey)`), so rotating
  `tokenKey` (password change/reset) invalidates all prior tokens for that record; short TTL +
  refresh.
- Transport: httpOnly+Secure+SameSite cookie (XSS can't read the token) **and** bearer; CSRF via
  SameSite=Strict + session-bound double-submit (`csrf` claim) on the cookie+unsafe path.
- `passwordHash`/`tokenKey` never serialized (hidden fields). Identity lookups parameterized.
- No user-existence leak on failed login.

---

## 8. Files

New: `src/crypto.zig`, `src/jwt.zig`, `src/api/auth.zig`, `src/auth.zig` (middleware +
auth-collection record helpers).
Modified: `src/schema.zig` (auth system fields, `Field.hidden`, `CollectionOptions`/auth options,
`options` (de)serialization), `src/ddl.zig` (auth columns + unique indexes for auth collections),
`src/migrations.zig` (`0002`: `options` column + `_superusers`), `src/records.zig` (hidden-field
skipping; auth-collection awareness in column list), `src/http.zig` (RequestCtx headers, Response
extra_headers, `Header`), `src/server.zig` (copy request headers in; write response headers/cookies
out; superuser-gate collections routes are handler-level), `src/api/collections.zig`
(superuser-gate), `src/api/records.zig` (auth-collection create/update password handling; populate
context via middleware), `src/cli.zig`/`src/main.zig` (`superuser create`), `src/config.zig`
(`cookie_secure`, token TTLs).

---

## 9. Testing Strategy

- **Crypto:** hash/verify round-trip + wrong-password reject; sign/verify; tampered token →
  BadSignature; expired → Expired; token signed with a different derived key (rotated tokenKey) →
  rejected (invalidation).
- **Auth model:** auth-collection DDL has the system columns + unique email index; create hashes
  the password (passwordHash present, password not stored, tokenKey set, verified=0); responses
  omit passwordHash/tokenKey; `_superusers` migration present; `superuser create` inserts a row.
- **Endpoints (temp App):** login success (right password) → token+record; wrong password → 400
  generic; unknown identity → 400 (and constant-ish time); refresh; confirm-verification sets
  verified; password-reset rotates tokenKey (old auth token then fails).
- **Middleware:** valid bearer → context populated; valid cookie + correct X-CSRF-Token (unsafe
  method) → ok; cookie + wrong/missing CSRF on unsafe method → 403; bearer on unsafe method → no
  CSRF required; expired/forged token → unauthenticated; superuser token → is_superuser.
- **Integration with SP4:** a collection with `updateRule:"id = @request.auth.id"` — owner can
  update their own record (authed), a different user gets 404; superuser bypasses.
- **Collections gating:** unauthenticated `POST /api/collections` → 403; superuser → ok.
- **Manual smoke:** create a `_superusers` via CLI; superuser-login; create a `users` auth
  collection; register a user; login (cookie + bearer); create an owner-scoped record using the
  token; verify CSRF rejection on a cookie write without the header.

---

## 10. Risks & Notes

- **`tokenKey` rotation invalidates ALL of a user's sessions** on password change — intended, but
  document it (no selective session revocation in SP5).
- **CSRF only guards the cookie path;** bearer is inherently CSRF-safe. Logout clears cookies but
  cannot revoke an outstanding bearer token before its `exp` (short TTL mitigates).
- **`verified` is set but not a login gate** in SP5 (deferred with email delivery).
- **Per-record key derivation requires a DB lookup on every authenticated request** (to get
  `tokenKey`); acceptable, and reads use the reader connection.
- The auth-system-fields injection touches the schema/record engine; existing base-collection
  behavior must remain unchanged (covered by the existing 99 tests staying green).
