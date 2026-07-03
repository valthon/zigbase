### Breaking

- `GET /api/collections` and `GET /api/settings` now return `{"items":[…]}` instead of a bare JSON array (superuser endpoints; admin SPA + typegen updated). `zigbase typegen --url` requires a server from this release.
- `GET /api/collections/:col/auth/oauth2/providers` returns `{"items":[…]}` (was `{"providers":[…]}`); `@zigbase/client`'s `listAuthProviders` types updated.

### Changed

- `GET /api/analytics/events` adopts the house cursor pagination: `?cursor=` request param and `nextCursor`/`hasNext` response keys (additive; `limit` cap 200 unchanged).
