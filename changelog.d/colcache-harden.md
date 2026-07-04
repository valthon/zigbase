### Performance

- Collection-metadata cache: `invalidate()` no longer allocates while holding the cache spinlock. Detached entries are threaded onto an intrusive list and their arenas/keys are freed only after the lock is released, removing an alloc-under-spinlock latency/contention hazard (and any re-entrant-allocator deadlock risk) on the DDL path.

### Internal

- Added a multi-threaded stress test for the collection-metadata cache: N threads hammer `lease()`/`invalidate()`/release concurrently, asserting no use-after-free, no leak (via the leak-checking test allocator), and correct post-invalidation reload.
