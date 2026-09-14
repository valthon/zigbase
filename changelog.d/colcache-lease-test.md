### Internal

- Make the negative collection-cache invalidation regression independent of allocator address reuse by retaining its old leases while comparing the replacement entry. Runtime cache behavior is unchanged.
