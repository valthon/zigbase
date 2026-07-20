### Fixes

- JWT signing no longer leaks its intermediate buffers when handed a non-arena allocator: `jwt.sign` now frees the payload JSON, both base64 encodings, and the signing input, leaving only the returned token allocated.

### Features

- Added `jwt.verifyInto` and `jwt.peekClaimsInto`, which decode and verify a token into a caller-provided scratch buffer with **zero heap allocation**. An over-large token fails closed with `error.TokenTooLarge`. The allocator-taking `jwt.verify`/`jwt.peekClaims` remain for callers already holding a request arena.
- `zigbase.jwt`, `zigbase.crypto`, and `zigbase.RequestArena` are now public exports of the framework module, for consumers that need to mint/verify tokens, derive keys, or take the compile-enforced request-arena contract type directly.
