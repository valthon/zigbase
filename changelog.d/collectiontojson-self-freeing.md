### Internal

- Made `schema.collectionToJson` self-freeing (allocator ownership contract 1): the root `ObjectMap`, the per-section JSON strings, and the reparsed field/index/options value trees are all transient scratch it never freed, now built on a function-local arena; only the final serialized string escapes on the caller allocator. Correctness/contract only (its production callers pass a request arena) — it lets the `collections.zig` metadata test run under the raw leak detector, dropping that file's allocator-contract allowlist entry (1→0).
