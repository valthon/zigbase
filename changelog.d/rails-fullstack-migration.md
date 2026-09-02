### Features

- Add the full Rails migration skill and guide, with a deterministic coordinator that reconciles Rails backend inventory, ZigBase OpenAPI and replay evidence, and Zigapagos presentation handoffs into one versioned route map, including explicit reviewed method transforms and route-local blocker codes.

### Breaking

- Reject same-method consumer routes whose literal and capture patterns overlap regardless of declaration order (for example, `/api/items/new` and `/api/items/:id`). Move the literal route to a non-overlapping path or handle the distinguished value inside the capture handler.
- Enforce one literal route grammar across dispatch and OpenAPI: paths must be canonical absolute ASCII paths without trailing or repeated slashes, dot segments, percent escapes, or repeated/non-identifier capture names; methods must be concrete rather than `.UNKNOWN`; and `path_secret.param` must name an actual capture. Normalize affected paths, rename captures, select a concrete method, and align the secret parameter before upgrading.
- Reserve every enabled engine, admin, feature-state, WebSocket, and SSE route during application compilation. Move a colliding custom or feature route rather than shadowing an engine-owned endpoint.

### Changed

- Validate predeclared replay controls before `zb_replay record` sends any requests, and reject empty, non-string, or status-incompatible controls without leaving a partial capture.
- Mark exported OpenAPI collection operations with `x-zigbase-collection` and `x-zigbase-collection-type` so migration tooling can use the contract's collection identity and distinguish auth and base collections without parsing URLs.
- Write recorded replay captures and findings atomically with private `0600` permissions, preserving the previous complete artifact when validation or serialization fails.
- Atomically replace Rails converter JSON artifacts with deterministic permissions and preserve the previous complete artifact when serialization fails.
- Export authoritative built-in route, explicit compile-time gate, gate-aware engine prefix, and auth-operation metadata in OpenAPI; keep consumer auth gates separate from path-bound resource collection markers; and reconcile custom routes without shadowing engine handlers or the enabled admin namespace.
- Require exact endpoint-access declarations, fail closed on nested released-schema drift, and distinguish coordinator input failures (exit `1`) from incomplete migration proof (exit `2`).
- Make feature-state `HEAD` responses bodyless with GET-equivalent representation metadata, export a fixed OpenAPI contract-format version, and reject forged feature or consumer routes that could not compile beside the enabled engine route table.

### Internal

- Lint the replay tool and its tests in CI.
