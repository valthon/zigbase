### Fixes

- Vector search (`-Dvector`) `build`: on an allocation failure while composing the `ORDER BY`
  distance expression, the already-allocated `WHERE` fragment is now freed (added `errdefer`),
  closing an out-of-memory-path leak.

### Internal

- Allocator-ownership test migration: gave `search/vector.zig`'s `Vector` a `deinit` that frees
  exactly its two owned SQL fragments (not the borrowed query-embedding param) and converted all 5
  of its tests to the raw leak-detecting `std.testing.allocator` (allowlist line removed).
