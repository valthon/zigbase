### Changed
- The S3 spool cache now bumps an entry's mtime on a cache hit, so size-triggered eviction approximates last-access LRU (a frequently-read file survives over a rarely-read newer one) instead of being purely create-time ordered. `-Ds3` builds only.
