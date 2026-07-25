### Internal

- Allocator-ownership test migration: un-masked the pure Data-facade `auth_helpers.zig`
  "data.create on a non-auth collection" test to the raw leak-detecting `std.testing.allocator`
  (the returned record freed via `records.freeRecord`, the fetched collection via `Collection.deinit`);
  the 4 remaining auth-helper tests are genuine RequestArena (contract-4) and stay justified in the
  allowlist.
