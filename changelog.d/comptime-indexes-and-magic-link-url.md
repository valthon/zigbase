### Features

- **Comptime `.indexes` on collection literals** — a `zigbase.App(.{ .collections = … })` collection may now declare `.indexes = .{ .{ .name, .fields, .unique?, .collation?, .where? }, … }`, lowered into the provisioned schema and emitted as `CREATE INDEX` DDL (case-insensitive via `.collation = .nocase`; conditional-unique via `.where`). Index `.fields` reference fields by their declared name.
- **`ZIGBASE_PUBLIC_URL` → clickable magic-link emails** — set `public_url` (env `ZIGBASE_PUBLIC_URL`) and the built-in `magic_link` method emails an absolute link to its consume endpoint (which sets the session cookie and redirects) instead of a bare token. Unset preserves the previous raw-token email. Lets a stock binary offer real magic-link login by configuration alone.

### Fixed

- **Comptime `.indexes` is no longer silently ignored** — the documented `.indexes` key on collection literals was never lowered by the provisioner; it is now applied.

### Internal

- Corrected the "provisioned columns are named by a stable field id" claim in `CLAUDE.md` and `docs/framework.md`: physical SQLite columns use the human field name; the stable field id only matches columns across additive rebuilds.
