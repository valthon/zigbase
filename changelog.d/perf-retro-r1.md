### Fixes

- Shipped-binary size: fixed a code-gen accident in the bundled regex engine (`Builder`
  was materialized as a ~3 MB all-zero `.rodata` template copied at runtime on every
  `compile`) — the default ReleaseSafe binary shrinks ~40%, from ~7.6 MB to ~4.6 MB,
  with identical behavior.
