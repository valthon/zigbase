### Internal

- Gave `query.Joiner` an internal scratch arena plus a `deinit`, so the query joiner and its consumer `query/compiler.zig` are honest under the leak-detecting test allocator. Removed both files from the allocator-contract allowlist (joiner 3 and compiler 31 tests now run on the raw `std.testing.allocator`).
