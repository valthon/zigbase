### Internal

- Make the codegen "acquire" adapters own their result. `acquire_datadir.acquireFromDb`/
  `acquire`, `acquire_http.acquire`, and `acquire_http.parseCollections` now return an
  `Acquired` handle — a `{ arena, collections }` value with a `deinit()`, mirroring
  `std.json.Parsed` (contract-2). The whole interlinked collection graph lives in one arena,
  so a single `deinit()` reclaims it. This replaces a proposed piecewise `freeCollections`
  deep-free that would have had to mirror every schema parser (fields, indexes, and the full
  auth/oauth2/methods options graph) and stay coupled to it forever. The acquire adapters'
  tests now run under `std.testing.allocator` via the handle, restoring real leak detection
  on that path (the graph was previously arena-masked). Generated client output is unchanged.
