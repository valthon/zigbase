# Changelog

All notable changes to `@zigbase/client` are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/), and this package adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `CollectionService.changePassword(id, oldPassword, newPassword)` — self-service password
  change via `PATCH /records/:id`; transparently re-authenticates the current device when the
  caller changes their own password (requires ZigBase >= 0.10.0).

## [0.2.0] - 2026-06-21

Tracks the server's auth overhaul. **Requires ZigBase server ≥ 0.5.0** — the legacy
OAuth2 endpoints this client used to call no longer exist server-side.

### Changed

- **BREAKING: OAuth2 retargeted to the new server contract endpoints.**
  - `authWithOAuth2()` now `POST`s to `/auth/oauth2/complete` (was `/auth-with-oauth2`)
    and resolves to `OAuth2AuthResponse` (`{ token }`) — the response no longer carries
    `record` or `meta`. The endpoint sets the `zb_auth`/`zb_csrf` cookies directly; the
    auth store now saves the token with a `null` record.
  - `oauth2Init()` now `POST`s to `/auth/oauth2/initiate` (was `/oauth2-init`) and resolves
    to `OAuth2InitResponse` (`{ authURL?, clientId?, scopes?, state? }`) instead of `{ state }`.
  - `listAuthProviders()` now `GET`s `/auth/oauth2/providers` (was `/oauth2-providers`).
- **BREAKING: `AuthStore.save(token, record)` widened to accept `record: AuthRecord | null`.**
  OAuth2 login stores a token with no record, so the signature on `AuthStore`,
  `BaseAuthStore`, and `LocalAuthStore` now permits `null`. Custom `AuthStore`
  implementations must update their `save` signature.

### Added

- `OAuth2AuthResponse` and `OAuth2InitResponse` response types.

## [0.1.0] - 2026-06-10

- Initial release of the official TypeScript client: typed records/collections,
  filter/sort/expand query builder, auth store (base + localStorage), password auth,
  and realtime over WebSocket.
