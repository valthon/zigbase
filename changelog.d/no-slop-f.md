### Security

- Closed an account-enumeration oracle on `request-verification` / `request-password-reset`: the token email is now delivered on a background queue, so the endpoint returns `204` with identical status and timing whether or not the email matches a record. Previously a synchronous SMTP send made an existing account observable by response latency, and a mailer outage turned the endpoint into a boolean existence oracle (`500` = registered).
- The WebAuthn challenge check now uses the shared constant-time `crypto.timingSafeEql` helper instead of a private byte-for-byte copy, so future hardening of the constant-time primitive reaches the ceremony verification.

### Fixes

- S3 storage: the spool cache-fill path no longer leaks the joined cache path for a non-arena caller when the spool directory is unwritable or full; a failed per-object remote delete (orphaning a billed object after its record is gone) and a cache directory that becomes unlistable at runtime (silently disabling spool eviction) are now logged instead of swallowed.
- SMTP mailer: a partially-built CA bundle is freed when a system-trust-store rescan fails mid-load, closing a leak on hosts with a malformed or unreadable certificate.
- `GET /api/features`: an out-of-memory error while rendering the `403 Forbidden` body now propagates to the `500` backstop instead of hitting an `unreachable` (a panic in safe builds).

### Internal

- Consolidated three byte-identical RFC 3986 percent-encoders (captcha, Twilio SMS, OAuth token exchange) into one `url.percentEncode` helper, and the copy-pasted JSON body plumbing (`parseBody`/`strField`/`jsonResponse`) shared across the auth/OAuth handlers into `api/common.zig`.
- Deduplicated the near-identical `request-verification` / `request-password-reset` handlers and the `findByEmail` / `findByIdentity` lookup loop, preserving the subtle nocase / guarded-free memory semantics in a single `findByField` helper.
