### Features
- `examples/plugins` showcases the full advanced auth surface: `authors` auth collection with WebAuthn (passkeys) + a custom `ApiTokenMethod` plugin; `commenters` auth collection with magic-link (`auto_create=true`); `onAuth` hook logging all three methods; comptime `NOCASE` collation index on `authors.contact_email`; frontend magic-link comment flow; `beforeCreate` hook auto-populating `commenter` from session.

### Fixes
- Corrected false claim in `examples/plugins` migration 0002 comment: provisioned collection columns are human-named (field.name), not id-named. Raw migrations targeting migration-owned tables remain valid; the rationale is now accurate.
