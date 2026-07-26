### Internal

- Postgres full-text search now concatenates its text-search configuration into the emitted SQL at
  **comptime** (`++`) instead of formatting it with `{s}`. The value lands inside a single-quoted
  SQL literal — an escaping context `schema.isValidIdentifier` does not cover — so making it
  configurable later now fails to *compile* rather than silently opening an injection. A comptime
  guard additionally rejects a quote or backslash in the literal. The emitted SQL is byte-identical
  (verified by running the new test against the previous implementation).
- Added the first unit coverage for the Postgres full-text lowering: `buildPostgres` is pure, but
  nothing asserted its emitted SQL, so the read-side lowering was exercised only by the
  live-Postgres suites (skipped in a default build).
- `jwt.peekClaims` now rejects a token carrying a 4th segment, matching `jwt.verify`. Not a
  vulnerability (`verify` is authoritative and always refused such a token), but the two parsers
  read the same bytes and should not disagree about what a well-formed token is.
- `NO_SLOP.md` §4 records the outcome of a data-oriented-design audit of the four structures it
  names: none is currently high-cardinality enough for §4 to apply, so the guidance is now "do not
  'fix' these without a profile" rather than an open invitation to reflexive DoD.
