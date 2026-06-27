### Features

- Typed TypeScript client for built-in auth methods: `zig build gen-client` now emits
  precise input/result types for the `client.auth.<collection>.<method>.initiate/complete`
  surface of the three built-in non-password methods, replacing the previous untyped
  `Record<string, unknown>` / `unknown` stubs. `magic_link` initiate takes `{ identity }`
  and resolves `void` (204); `otp` initiate takes `{ identity }` (→ `void`) and complete
  takes `{ identity, code }`; `webauthn` initiate takes `{ identity? }` and resolves
  `{ challenge, rpId, ceremonyId, timeout }`, complete takes
  `{ ceremonyId, credentialId, authenticatorData, clientDataJSON, signature }`. Every
  built-in `complete` resolves to `{ token }` (`AuthMethodResult`). Custom methods
  (`.custom` slugs) remain on the untyped stubs for now (a typed-I/O declaration API for
  custom methods is a planned follow-up).
