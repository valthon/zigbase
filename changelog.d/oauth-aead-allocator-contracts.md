### Fixes

- Fix memory leaks in the shared AES-256-GCM envelope (`aead.seal`/`aead.open`) that backs every
  at-rest secret — OAuth client secrets and `.encrypted` record fields. `seal` never freed its
  ciphertext/raw/base64 scratch buffers (three allocations per call) and `open` never freed its
  decode buffer (plus the plaintext on a decrypt-verify failure). Served through a per-request
  arena the buffers were reclaimed at request end, but any non-arena caller (e.g. a batch
  re-encrypt) leaked on every encrypt/decrypt. Now contract-1: all scratch is freed, only the
  result escapes.
- Fix leaks on the OAuth login path: `oauth.client.fetchIdentity` never freed the `Bearer <token>`
  authorization header it built, and `oauth.providers.extractIdentity` never freed the JSON parse
  tree of the provider's userinfo response (leaked on every third-party login).

### Features

- `oauth.discovery.Endpoints` gains a `deinit(allocator)` that frees its three owned URL strings,
  so a non-arena caller of `resolve`/`parseDocument` can release the result.

### Internal

- Restore real leak detection for the `oauth/` subsystem and `aead.zig`: convert 23 arena-masked
  tests across `aead.zig` and `oauth/{client,discovery,providers,secrets}.zig` to run under
  `std.testing.allocator`, and remove all five files from `scripts/allocator-allowlist.txt`. The
  leaks above were found this way.
