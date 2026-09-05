### Features
- Opt-in `-Dfile-inventory=true` adds read-only `files inventory` reporting for local and S3 storage: bounded pages, page-level byte usage, and referenced/unreferenced-candidate/unknown classifications. Reports explicitly account for concurrent and in-flight uploads; there is no deletion mode.
- Storage plugins can provide the optional `inventory` capability without changing existing four-method vtables.

### Fixes
- Inventory resolves unknown filesystem entry types, supports an operator-configured root symlink without following descendant links, and reports actionable failures without stack traces. Invalid UTF-8 keys fail without partial JSON output.
