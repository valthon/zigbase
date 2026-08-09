### Features

- **Two new frozen error codes.** `payload_too_large` replaces a generic `internal` on the 413 an over-size upload returns — a client fixes that by sending less data, so it must never be indistinguishable from a server fault. `email_not_verified` replaces a generic `forbidden` when login succeeds against an account whose email is unverified, so a client can route to its verify-email flow by matching a code instead of the message text.
- **The error code is now exposed on every SDK's error type** — `ZigbaseError.code` (TypeScript, Python) and `ZigbaseException.code` (Dart, Kotlin). This is the handle that makes the frozen registry usable from a client: branch on `code`, never on `message`. It is empty when the server sent no code, and a pre-unification integer `code` is ignored rather than surfaced as one.

### Fixes

- **An unverified-email login and an over-size upload are no longer reported with a code that contradicts their status.** Both previously shipped a code (`forbidden`, `internal`) that told a client nothing actionable.
- **A 5xx from an auth method no longer forwards its internal message to the caller.** The frozen registry documents `internal` as leaking no detail; the detail now goes to the log, and the response carries the generic body. The same applies to WebAuthn's misconfiguration responses, which previously told an anonymous caller whether a collection's `rp_id`/`origin` were set.
- **A static-file read that fails for an internal reason (OOM) is now reported as a 500 incident instead of a silent 404.** Genuine filesystem misses still return 404 without raising an incident, unchanged.
- **A request that runs out of memory while parsing a multipart body now answers 500** instead of dropping the connection with no response at all (which also logged a status the client never received).
- **`--log-format json` no longer emits a plain-text line into the JSON stream.** The unknown-environment-variable warning was written before the logging configuration from `serve`'s flags was installed, so under the flag form (not the env form) the first line of an otherwise-NDJSON stream was text, and `--log-level` could not suppress it.
- `zigbase explain-code` corrections: `validation_max` no longer claims to cover select/relation "too many values" (those are `validation_select`/`validation_relation`), `validation_min` now documents that it also covers date minimums, and `validation_relation` no longer claims to cover a schema that omits `targetCollectionId` (that is `validation_required`).
