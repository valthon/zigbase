### Features

- **`GET .../auth/magic_link/consume` — browser-friendly email-link login** — `GET /api/collections/:col/auth/magic_link/consume?token=…&redirect=/app` verifies and consumes the single-use link token (same replay guard as `complete`), mints the session through the shared `issueSession` seam (so `onAuth(.magic_link)` fires and the `zb_auth`/`zb_csrf` cookies are set), honors the `require_verified` gate, and `302`s to the redirect target. Two new per-method `magic_link` options shape the redirect: `redirect_default` (fallback path when `?redirect=` is absent or rejected; defaults to `/`) and `redirect_allow` (allow-list of exact paths or `/`-suffixed prefixes; an empty list permits any safe relative path).

### Security

- **Server-side open-redirect guard on magic_link consume** — the `?redirect=` target is validated server-side so consumers never re-implement the guard: only same-origin relative paths are honored. Off-origin, protocol-relative (`//host`), scheme, CRLF/control-byte, backslash, `.`/`..` path-traversal segments, and still-encoded `%2e`/`%2f`/`%5c` payloads are all rejected and fall back to `redirect_default`.
