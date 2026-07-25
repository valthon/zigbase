### Internal

- Restored leak detection for `query/sort.zig`: its 4 tests now build the db-backed collections and
  the `Joiner` on the raw `std.testing.allocator` — freeing the collections via `Collection.deinit`
  and the joiner via `j.deinit()` (which the joiner gained in the wave) — instead of a setup arena
  that masked leaks, mirroring the `query/compiler.zig` conversion. `query/sort.zig` removed from
  `scripts/allocator-allowlist.txt`.
