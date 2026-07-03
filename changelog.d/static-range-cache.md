### Features
- Static serving now answers `bytes=X-` (video seek), `bytes=-n`, and overlong Range requests with correct `206` responses, and unsatisfiable ranges with `416` (previously these fell through to a full `200` or worse). Embedded static assets gain single-range `206` support.

### Fixes
- Embedded static assets now send a `Cache-Control` header (previously none — revalidation still works via the unchanged CRC32 ETag).
- `.gz` sidecar responses now carry `Vary: Accept-Encoding` (shared-cache correctness).
- The SPA fallback shell is always served `Cache-Control: no-cache` with a revalidation ETag, so a redeploy can no longer strand deep links on a stale cached shell.

### Internal
- Static Range support is a ~20-line request-header normalization shim + `HTTP_HVALUE_MAX_AGE` FIOBJ swap at `FIO_CALL_PRE_START` — facil.io keeps ALL static serving (directive 1); no owned static layer.
