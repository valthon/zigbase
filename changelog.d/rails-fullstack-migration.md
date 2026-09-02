### Features

- Add the full Rails migration skill and guide, with a deterministic coordinator that reconciles Rails backend inventory, ZigBase OpenAPI and replay evidence, and Zigapagos presentation handoffs into one versioned route map.

### Changed

- Validate predeclared replay controls before `zb_replay record` sends any requests, and reject empty, non-string, or status-incompatible controls without leaving a partial capture.
- Mark exported OpenAPI collection operations with `x-zigbase-collection` and `x-zigbase-collection-type` so migration tooling can use the contract's collection identity and distinguish auth and base collections without parsing URLs.
- Require explicit reviewed route method transforms, distinguish route-local presentation blocker codes from handoff finding and decision ids, and normalize method-transform output.
- Write recorded replay captures atomically with private `0600` permissions, and lint the replay tool and tests in CI.
