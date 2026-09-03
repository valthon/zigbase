### Features

- Add the full Rails migration skill and guide, with a deterministic coordinator that reconciles Rails backend inventory, ZigBase OpenAPI and replay evidence, and Zigapagos presentation handoffs into one versioned route map, including explicit reviewed method transforms, exact endpoint-access declarations, fail-closed released-schema validation, route-local blocker codes, and distinct input-failure and incomplete-proof exit codes.

### Breaking

- Enforce one literal route grammar across dispatch and OpenAPI: paths must be canonical absolute ASCII paths without trailing or repeated slashes, dot segments, percent escapes, or repeated/non-identifier capture names; methods must be concrete rather than `.UNKNOWN`; and `path_secret.param` must name an actual capture. Normalize affected paths, rename captures, select a concrete method, and align the secret parameter before upgrading.
- Reserve every enabled engine, admin, feature-state, WebSocket, and SSE route during application compilation. Move a colliding custom or feature route rather than shadowing an engine-owned endpoint.
- Require explicit consumer route names to be Zig identifiers and prevent explicit or derived names from colliding with another consumer or built-in operation. Derived names sanitize ordinary URI punctuation and leading digits (for example, `/robots.txt` becomes `robotsTxt` and `/api/2fa/verify` becomes `_2faVerify`); use `.name` only to resolve a genuine collision or an otherwise empty derived name.

### Changed

- Validate predeclared replay controls before `zb_replay record` sends any requests, and reject empty, non-string, or status-incompatible controls without leaving a partial capture.
- Mark exported OpenAPI collection operations with `x-zigbase-collection` and `x-zigbase-collection-type` so migration tooling can use the contract's collection identity and distinguish auth and base collections without parsing URLs.
- Write recorded replay captures and findings atomically with private `0600` permissions, preserving the previous complete artifact when validation or serialization fails.
- Atomically replace Rails converter JSON artifacts with deterministic permissions, preserve the previous complete artifact when serialization fails, and refuse an existing symlink destination instead of silently changing its target or replacement semantics.
- Export authoritative built-in route, explicit compile-time gate, gate-aware engine prefix, and auth-operation metadata in OpenAPI; keep consumer auth gates separate from path-bound resource collection markers; and reconcile custom routes without shadowing engine handlers or the enabled admin namespace.
- Make feature-state `HEAD` responses bodyless with GET-equivalent representation metadata, export a fixed OpenAPI contract-format version, reject consumer collisions with the feature-state route at compile time, and keep draft custom routes from shadowing enabled engine handlers.

### Internal

- Lint the replay tool and its tests in CI.
