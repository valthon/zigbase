### Security

- Bound JWT token length before any allocation. `jwt.verify` and `jwt.peekClaims` now
  reject a token longer than `jwt.max_token_len` (4096 bytes) as `error.TokenTooLarge`
  as their first statement. Previously nothing on the request path bounded token length,
  while a request body may be `max_upload_size` (50 MiB by default) and a realtime frame
  256 KiB — and because a token is decoded *before* its signature is checked, an
  unauthenticated request could drive allocation proportional to the token it supplied.

### Breaking

- `jwt.sign` now returns `error.TokenTooLarge` rather than minting a token that exceeds
  `jwt.max_token_len`, so this module can never produce a token it would itself refuse.
  An application putting more than ~3 KB into the caller-supplied `pl` claim now fails at
  sign time instead of at the next request. Applications within that budget are unaffected.

### Fixes

- Correct `jwt.scratch_size` to 16384 (from 8192) and document its derivation. The
  previous value and its comment were both wrong: measured consumption is ~1.74x token
  length for ordinary claims, but escape-heavy claims force `std.json` to copy rather
  than borrow and the ratio *rises* with size (>4x at ~5.7 KB). 8192 admitted only a
  ~2.3 KB token, not the "~3-4 KB" claimed. 16384 covers the measured worst case
  (14800 bytes) for any token within `max_token_len`.
