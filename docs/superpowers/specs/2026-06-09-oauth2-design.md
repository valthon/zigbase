# ZigBase SP6 — OAuth2 Design

**Status:** Approved design (brainstorm complete). Sub-project 6 of the ZigBase roadmap
(`docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md`).

**Goal:** Let users authenticate to a ZigBase auth collection via external OAuth2 providers,
returning the same `{token, record}` + auth cookies as `auth-with-password`. The flow is
**client-driven with PKCE**: the SDK/SPA performs the provider redirect and holds the PKCE
verifier; the backend is stateless for the handshake and only does the token exchange, identity
fetch, and account create/link/login.

**Depends on:** SP5 Auth (auth collections, `_superusers`, JWT/cookie issuance, `crypto`, `jwt`,
`auth.zig`), config, the records/collections engine, and the access-rules engine. Outbound HTTPS
uses `std.http.Client` (+ `std.crypto.tls`); secret encryption uses `std.crypto.aead.aes_gcm.Aes256Gcm`.
Both are confirmed present in Zig 0.16.0 — **no new C dependencies**.

---

## 1. Decisions (from brainstorming)

1. **Flow model: client-driven (PKCE).** Backend exposes a provider list/auth-URL helper and a
   single stateless `POST .../auth-with-oauth2`. No server-side handshake state (no `state`/verifier
   store). Rationale: best fit for our SDK-first BaaS; stateless backend with minimal attack surface;
   composes with existing JWT/cookie issuance.
2. **Account linking: explicit-only.** Never auto-link a provider login to an existing local account
   by email. Anonymous OAuth login either logs in the existing `(provider, providerId)` link or
   creates a **new** auth record. Linking a provider to an existing account is allowed **only** when
   the `auth-with-oauth2` request already carries a valid ZigBase token (you must be logged in to
   connect a provider). Eliminates the email-based account-takeover vector.
3. **Provider model: preset registry + generic; identity via the userinfo endpoint.** Built-in
   presets (authURL/tokenURL/userinfoURL/scopes + a JSON field-mapping) for a starter set, plus a
   generic shape the operator fully specifies. Identity is read from the provider's **userinfo
   endpoint** using the access token over TLS — **no `id_token` / RSA / JWKS** (Zig 0.16 std has no
   general RSA verify; this avoids vendoring crypto).
4. **Config storage: DB per-collection, client_secret encrypted at rest.** Provider config lives in
   each auth collection's `options.auth.oauth2`; `clientSecret` is AES-256-GCM encrypted with a key
   derived from the app secret. Per-collection providers, SP9-admin-manageable. The encrypted secret
   is never serialized to any API response.
5. **Provider tokens are discarded after identity fetch** (YAGNI — not stored; revisit only if a
   future feature needs ongoing provider API calls).

---

## 2. Architecture & modules

New modules (all unit-tested; handlers stay pure `(*RequestCtx) -> Response`; only `server.zig`
imports zap):

| Module | Responsibility | Depends on |
|---|---|---|
| `src/oauth/providers.zig` | Preset registry + `Provider`/`ProviderMapping` types; generic provider construction; authURL builder | schema |
| `src/oauth/secrets.zig` | `encryptSecret`/`decryptSecret` (AES-256-GCM, key = HKDF(app_secret)) | std.crypto |
| `src/oauth/client.zig` | `exchangeCode`/`fetchIdentity` over an injectable `Transport` seam; production transport wraps `std.http.Client` | providers, std.http |
| `src/api/oauth.zig` | Endpoints: `oauth2-providers`, `auth-with-oauth2`, unlink; the create/link/login decision tree | oauth/*, auth, jwt, crypto, collections, records |

**Shared issuance:** the JWT+cookie minting currently in `api/auth.zig` `issue()` is extracted to a
shared location (e.g. `api/auth.zig` exposes `issue()` publicly, or a small `auth_session.zig`) so
`api/oauth.zig` reuses it verbatim — identical `zb_auth`/`zb_csrf` cookies and `{token, record}`
shape as `auth-with-password`.

### `Provider` shape

```
Provider = {
  name: []const u8,             // "google", "github", ...
  authURL: []const u8,          // provider authorization endpoint
  tokenURL: []const u8,         // token exchange endpoint
  userinfoURL: []const u8,      // identity endpoint
  scopes: []const []const u8,   // default scopes
  mapping: {                    // userinfo JSON field names
    id: []const u8,             // e.g. "sub" (google) / "id" (github)
    email: []const u8,          // e.g. "email"
    emailVerified: ?[]const u8, // e.g. "email_verified"; null => treat as false
    name: ?[]const u8,          // e.g. "name"
    avatar: ?[]const u8,        // e.g. "picture" / "avatar_url"
  },
}
```

Built-in presets: **Google, GitHub, Microsoft, Discord** (starter set; more later). A `generic`
provider is constructed from operator-supplied fields with the same shape. The registry is a
compile-time table of presets; per-collection config supplies `clientId`/`clientSecret`/`enabled`
and (for `generic`) the endpoint/mapping overrides.

---

## 3. Data model

### 3.1 `_externalAuths` system table (migration `0003`)

```sql
CREATE TABLE "_externalAuths" (
  "id" TEXT PRIMARY KEY,
  "collectionRef" TEXT NOT NULL,   -- auth collection name (or id) owning the record
  "recordRef" TEXT NOT NULL,       -- the auth record id
  "provider" TEXT NOT NULL,        -- "google", ...
  "providerId" TEXT NOT NULL,      -- the provider's stable user id (mapping.id)
  "created" TEXT NOT NULL,
  "updated" TEXT NOT NULL
);
CREATE UNIQUE INDEX "idx_extauth_provider_pid" ON "_externalAuths" ("provider","providerId");
CREATE UNIQUE INDEX "idx_extauth_rec_provider" ON "_externalAuths" ("collectionRef","recordRef","provider");
```

- `(provider, providerId)` unique → a given provider identity maps to at most one local record.
- `(collectionRef, recordRef, provider)` unique → a record links a given provider at most once.
- On auth-record delete, the engine deletes matching `_externalAuths` rows (handled in the record
  delete path for auth collections; `_externalAuths` is not a FK target so deletion is explicit).

### 3.2 Collection options

Extend `CollectionOptions.auth` (in `schema.zig`):

```
oauth2: {
  enabled: bool = false,
  providers: []OAuth2Provider,    // [] by default
}
OAuth2Provider = {
  name: []const u8,               // preset name or "generic"
  clientId: []const u8,
  clientSecret: []const u8,       // STORED as the AES-GCM base64url blob; decrypted on use
  enabled: bool = true,
  redirectUrls: []const []const u8, // allowlist of permitted client redirect_uri values
  // generic-only overrides (ignored for presets):
  authURL: ?[]const u8 = null, tokenURL: ?[]const u8 = null, userinfoURL: ?[]const u8 = null,
  scopes: ?[]const []const u8 = null, mapping: ?ProviderMapping = null,
}
```

- Persisted in the existing `_collections.options` column via `optionsToJson`/`optionsFromJson`
  (extended). These (in `schema.zig`) are **pure** and carry the secret value verbatim — they do
  not encrypt.
- **Encryption happens at the API/engine layer, not in pure schema parsing** (the app secret lives
  on `App`/`Config`, not in `schema.zig`). The collection create/update path in `api/collections.zig`
  (which has the app secret) walks `options.auth.oauth2.providers` and, for each `clientSecret`,
  **encrypts a plaintext value** before the collection is persisted. An already-encrypted blob
  (detected by the `"v1"` prefix from `oauth/secrets.zig`) passes through unchanged, so re-saving a
  collection does not double-encrypt; an **empty** incoming `clientSecret` on update leaves the
  stored blob untouched (so a redacted round-trip doesn't wipe the secret).
- **`clientSecret` is never emitted** to any API response: `collectionToJson` (pure) omits/redacts
  it to `""`, mirroring hidden-field handling. The encrypted blob never leaves the server.

---

## 4. Endpoints & data flow

### 4.1 `GET /api/collections/:col/oauth2-providers`

Returns the enabled providers' public redirect-building info:
```json
{ "providers": [ { "name": "google", "authURL": "https://accounts.google.com/o/oauth2/v2/auth",
                   "clientId": "...", "scopes": ["openid","email","profile"] } ] }
```
No secret is returned. The SDK builds the full redirect URL itself (appending its own
`redirect_uri`, `state`, `code_challenge`/`code_challenge_method=S256`, `response_type=code`,
`scope`). 404 if the collection is not an auth collection or `oauth2.enabled` is false.

### 4.2 `POST /api/collections/:col/auth-with-oauth2`

Body: `{ provider, code, codeVerifier, redirectUrl }`. May carry a ZigBase bearer/cookie (for
linking). Flow:

1. Resolve collection; require auth type + `oauth2.enabled` + the named provider enabled. Else 404.
2. Validate `redirectUrl` ∈ that provider's `redirectUrls` allowlist. Else `400`.
3. Decrypt `clientSecret`. `exchangeCode(provider, clientId, secret, code, codeVerifier, redirectUrl)`
   → access token. `fetchIdentity(provider, accessToken)` → `Identity{ providerUserId, email,
   emailVerified, name, avatarUrl }`. Any provider/network/parse failure → `400` (generic message;
   details logged server-side).
4. Decision tree on `_externalAuths` by `(provider, providerId)`:
   - **Link exists →** load the linked record.
     - If the request is authenticated as a **different** record → `409` ("provider already linked
       to another account").
     - Else → issue JWT+cookies for the linked record. `meta.isNew=false`.
   - **No link, request authenticated as a record in this same collection** (`authed.collection ==
     :col`) → create the link to the **authed** record → issue JWT+cookies (re-issue for that
     record). `meta.isNew=false`. (A token for a *different* collection is treated as anonymous.)
   - **No link, anonymous** → create a **new** auth record:
     - `verified` = `Identity.emailVerified` (provider's claim).
     - `email` set from identity when present; `username`/avatar populated when present.
     - **No password** (empty `passwordHash`); the partial-unique email index still applies.
     - If the email collides with an existing record → `409` ("email already registered; sign in and
       link instead") — we do **not** auto-link.
     - Create the `_externalAuths` link → issue JWT+cookies. `meta.isNew=true`.
5. Response: `{ token, record, meta: { isNew } }` + `zb_auth`/`zb_csrf` cookies (identical to
   `auth-with-password`). `record` has hidden fields stripped (no `passwordHash`/`tokenKey`).

### 4.3 `DELETE /api/collections/:col/records/:id/external-auths/:provider`

Unlink a provider from a record. Authorized for the record itself (authenticated as that record id)
or a superuser. **Refuses** (`400`) to remove a link if it is the record's last credential and the
record has no password set (`passwordHash` empty) — prevents lockout. `204` on success; `404` if no
such link.

---

## 5. Crypto & outbound HTTP

### 5.1 Secret encryption (`oauth/secrets.zig`)

- `key = HKDF-SHA256(ikm = app_secret, salt = "", info = "zigbase-oauth-secret-v1")` → 32 bytes.
- `encryptSecret(app_secret, plaintext)`: `nonce = 12 random bytes`; `ct, tag = Aes256Gcm.encrypt(key,
  nonce, plaintext, aad="")`; blob = base64url(`"v1" ‖ nonce ‖ ct ‖ tag`). The `"v1"` prefix marks an
  encrypted value (used to detect already-encrypted secrets on collection re-save).
- `decryptSecret(app_secret, blob)`: base64url-decode, check prefix, split, `Aes256Gcm.decrypt`
  (authenticated; tampered/foreign blob → `error.BadSecret`).
- App secret = the existing `jwt_secret`. The SP5 startup guard (refuse the default secret when
  `cookie_secure`) therefore also protects OAuth secrets.

### 5.2 Outbound HTTP (`oauth/client.zig`) + the `Transport` seam

```
Transport = struct {
  ctx: *anyopaque,
  call: *const fn (ctx, alloc, method, url, headers, body) TransportError!Response,  // {status, body}
};
```

- `exchangeCode(transport, alloc, provider, clientId, secret, code, verifier, redirectUrl)`:
  POST `tokenURL`, `Content-Type: application/x-www-form-urlencoded`, body =
  `grant_type=authorization_code&code=…&redirect_uri=…&code_verifier=…&client_id=…&client_secret=…`
  (URL-encoded). Parse JSON for `access_token` (and `token_type`). Non-2xx / missing token → error.
- `fetchIdentity(transport, alloc, provider, accessToken)`: GET `userinfoURL`,
  `Authorization: Bearer <token>`. Parse via `provider.mapping`; `providerId` is **required**
  (missing → error); email/emailVerified/name/avatar optional. `emailVerified` is coerced (bool or
  the strings "true"/"1") → bool; null mapping or absent → false.
- **Production transport** wraps `std.http.Client{ .allocator, .io }` via `fetch(.{ .location =
  .{ .url = url }, .method, .payload, .extra_headers, .response_writer = &buf })`, response body
  written into a bounded `Writer` (cap ~64 KB → `error.ResponseTooLarge`). TLS via `std.crypto.tls`.
- **Test transport** returns canned token/userinfo responses (no network), enabling full
  decision-tree tests.

---

## 6. Security model (consolidated)

- **PKCE S256** end-to-end; `state` (redirect CSRF) is the SDK's responsibility (stateless backend).
- **`redirectUrl` allowlisted** per provider (defense-in-depth; the provider also enforces its
  registered redirect URIs).
- **client_secret** AES-256-GCM encrypted at rest; decrypted only transiently for the exchange;
  never serialized to any response.
- **Explicit-only linking**; no email auto-link; cross-account link attempts → `409`.
- **Provider tokens discarded** after identity fetch.
- **OAuth-only accounts have no password**; unlink refuses to remove the last credential of a
  password-less account.
- **Generic-error responses** for all provider/network failures (`400`); provider internals logged
  server-side only, never returned. No `clientSecret`/token values are ever logged.
- **SSRF mitigation:** all provider endpoints (`authURL`/`tokenURL`/`userinfoURL`, including
  generic-provider overrides) must be **`https://` scheme** — reject otherwise at config-save time
  and at use. Generic provider URLs are superuser-controlled (privilege-limited), but the https-only
  rule plus the fact that only superusers can configure providers bounds the SSRF surface. (A host
  allowlist is a possible future hardening; out of scope here.)

---

## 7. Error handling

| Condition | Status | Notes |
|---|---|---|
| Collection not auth / oauth2 disabled / provider not enabled | 404 | Hide existence |
| `redirectUrl` not allowlisted | 400 | Generic "invalid redirect" |
| Invalid JSON body / missing `provider`/`code`/`codeVerifier`/`redirectUrl` | 400 | Field message |
| Token exchange or userinfo failure (network, non-2xx, parse, missing providerId) | 400 | Generic; logged server-side |
| Provider already linked to a different account | 409 | "linked to another account" |
| Anonymous create where email already exists | 409 | "email already registered; sign in and link" |
| Unlink last credential of a password-less account | 400 | "cannot remove last credential" |
| Unlink not authorized (not self / not superuser) | 403 | |
| No such link on unlink | 404 | |
| Success (login/link/create) | 200 | `{token, record, meta:{isNew}}` + cookies |
| Unlink success | 204 | |

---

## 8. Testing strategy

- **`oauth/secrets.zig`:** AES-GCM round-trip; tamper detection (flip a byte → `BadSecret`); wrong
  key → `BadSecret`; prefix detection for already-encrypted blobs.
- **`oauth/providers.zig`:** preset lookup; authURL builder; generic provider construction; mapping
  extraction from sample userinfo JSON (Google/GitHub shapes).
- **`oauth/client.zig`:** `exchangeCode`/`fetchIdentity` against the **stub transport** with canned
  provider responses (success, non-2xx, malformed JSON, missing providerId).
- **`api/oauth.zig`:** the full decision tree with the stub transport — link-exists login,
  authenticated link, anonymous create (verified from claim), email-collision 409, cross-account
  409, unlink (self/superuser/last-credential-refusal), provider-not-enabled 404, redirect-not-
  allowlisted 400. Secret-leak assertion: no `clientSecret`/`passwordHash`/`tokenKey` in any response.
- **Optional env-gated live test** (skipped in CI): real `std.http.Client` against a real token
  endpoint, to smoke the production transport once.
- **Holistic review** before merge: trace forgery/leakage/SSRF-via-userinfoURL/redirect-allowlist/
  linking-takeover/secret-at-rest, then merge SP6 as a unit.

---

## 9. Build slicing — two plans

**6a — foundation (no endpoints):**
- `_externalAuths` migration `0003`.
- `oauth/secrets.zig` (AES-GCM + HKDF).
- `oauth/providers.zig` (registry + presets + authURL builder + mapping).
- `CollectionOptions.auth.oauth2` schema + `optionsToJson`/`optionsFromJson` + secret
  encrypt-on-input / redact-on-output / no-double-encrypt-on-update.
- `oauth/client.zig` `Transport` seam + `exchangeCode`/`fetchIdentity` against the **stub**.
- All unit-tested.

**6b — endpoints & wiring:**
- Extract shared `issue()`; `api/oauth.zig` (`oauth2-providers`, `auth-with-oauth2`, unlink) + routes.
- Production `std.http.Client` transport.
- The full create/link/login decision tree; `_externalAuths` cleanup on auth-record delete.
- Holistic security review; merge SP6 (6a+6b) as a unit to `main`.

---

## 10. Out of scope (deferred)

- Backend-driven redirect flow (no-JS turnkey) — add later if needed.
- Storing/refreshing provider access/refresh tokens for ongoing provider API calls.
- OIDC `id_token` signature validation / JWKS (needs RSA not in std).
- Email auto-linking by verified email.
- Rate limiting on `auth-with-oauth2` (folds into a global rate-limit effort).
- Admin SPA management UI for provider config (SP9).
