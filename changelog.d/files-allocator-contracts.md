### Fixes

- Fix a memory leak in stored-filename sanitization (`files/naming.zig`): `sanitizeBase` freed its
  scratch `ArrayList` only via `errdefer`, so every successful call leaked the buffer, and
  `storedName` never freed the sanitized intermediate. Latent behind the upload request-arena, a
  real leak under any non-arena allocator. Now contract-1 (`defer`-freed; the return is always a
  fresh copy).

### Internal

- Restore leak detection for the `files/` subsystem: convert the arena-masked tests in
  `naming`/`storage`/`serve_file` (and 10 of 17 in `s3`) to `std.testing.allocator`, removing three
  files from `scripts/allocator-allowlist.txt`. `plan.zig` (11 tests) is confirmed a genuine
  contract-4 — its `json.Value` plan tree aliases caller-owned inputs and freshly-allocated
  `PlannedWrite`s, so it is reclaimed wholesale by the request arena — and relabeled accordingly.
  The remaining 7 `s3` tests exercise the raw `HttpClient` response, which has no `deinit` (house
  convention); they stay arena-scoped pending the `http_client` batch's decision on that type.
