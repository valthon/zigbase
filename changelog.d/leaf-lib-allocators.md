### Fixes

- Fix a memory leak in captcha response parsing. `captcha.parseResponse` (reached via
  `ctx.verifyCaptcha`) parsed the provider's JSON with a leaky parser and never freed the
  tree, and returned `Result` fields that borrowed it — including an `errors` slice that was
  an un-freeable sub-slice of a larger allocation. It now frees the parse tree and returns
  independently-owned dupes. Requests served through a per-request arena were unaffected in
  practice (arena teardown reclaimed the tree); the leak bit any caller using a
  general-purpose allocator.

### Features

- `captcha.Result` gains a `deinit(allocator)` method that frees its owned strings, so a
  `Result` produced with a non-arena allocator can be released. Callers on the request-arena
  path (the usual `ctx.verifyCaptcha`) do not need it.

### Internal

- Convert 22 leak-detector-masked tests in `crypto.zig`, `values.zig`, and `captcha.zig` to
  run under `std.testing.allocator`, restoring real leak detection (the captcha leak above
  was found this way). Five tests legitimately remain arena-scoped where the value under test
  is a genuine request-lifetime graph (a `std.json.Value` tree from a discarded `Parsed`
  wrapper; an `HttpClient` response body that is a sub-slice of a fixed buffer); each now
  carries a contract-4 justification in `scripts/allocator-allowlist.txt`.
