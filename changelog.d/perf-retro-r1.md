### Fixes

- Shipped-binary size: fixed a code-gen accident in the bundled regex engine (`Builder`
  was materialized as a ~3 MB all-zero `.rodata` template copied at runtime on every
  `compile`) — the default ReleaseSafe binary shrinks ~40%, from ~7.6 MB to ~4.6 MB,
  with identical behavior.

### Internal

- Corrected a false load-bearing comment in `static_files.zig` (facil.io does NOT
  percent-decode request paths; the `..` check is safe because encoded traversal stays a
  literal segment) and documented why `query/params.zig` keeps its own query parser
  (fio type-guesses values; zap returns them undecoded).
