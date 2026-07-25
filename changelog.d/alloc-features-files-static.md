### Fixes

- Static-file range handling: `normalizeRange` no longer leaks its scratch `bytes=a-b`
  string on the already-canonical passthrough path (returned `null` without freeing the
  freshly allocated buffer). A no-op under the request arena every production caller
  passes, but a genuine leak under any non-arena allocator.

### Internal

- Allocator-ownership test migration across three files, un-masking arena-wrapped tests to
  the raw leak-detecting `std.testing.allocator`:
  - `features_resolver.zig`: gave `Resolved` a `deinit` (frees its two owned slices; the
    flag/experiment names + variants alias static declaration data) and converted all 14
    tests off their convenience arenas — the allowlist entry is removed.
  - `api/files.zig` (3 → 1): the policy-parity and `recordReferencesFile` tests now free
    their created `Collection`/`ObjectMap`/`Array` directly; only the `fileIdentity` test
    (a real `RequestArena` request ctx) remains a justified contract-4 entry.
  - `static_files.zig` (24 → 22): the `normalizeRange` and `validateRouteTargetsDir`
    pure-builder tests now free their returned strings directly; the 22 `serve`/handler
    tests remain justified contract-4 (request-arena `http.Response` graphs).
