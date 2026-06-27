### Fixes
- **Unknown collection/field keys now fail the build.** A typo'd key in a comptime `.collections` spec — collection-level (e.g. `.ttl_filed`), under `.rules`/`.auth` (e.g. `.viewRul`), or on a field (e.g. `.requied`, `.encrypte`) — was silently ignored; it is now a `@compileError` that lists the recognized keys for that spec.

### Security
- **Startup now fails closed for runtime-created encrypted fields.** A server with an `.encrypted` field added at runtime (via the collections API while a key was set) would previously start on a later restart *without* `ZIGBASE_FIELD_KEY`. Startup now scans the live database schema after provisioning and refuses to start (`error.FieldKeyRequired`) if any DB-resident collection declares an encrypted field while no key is configured — matching the existing comptime guard. (The value layer already failed closed on read/write, so plaintext never leaked; this just turns a silently half-broken server into a loud refusal.)
