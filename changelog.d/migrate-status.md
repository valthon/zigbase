### Features

- `zigbase migrate status` reports your comptime `.migrations` as applied (with the ledger timestamp) or pending in declared order, and separately flags orphaned ledger rows — applied migrations no longer present in the binary — with a concise `N applied, M pending, K orphaned` summary. It reads the `_migrations` ledger only and applies nothing.

### Changed

- `zigbase migrate` now applies the app's comptime `.migrations` (the consumer escape-hatch migrations) after the system migrations — the same forward pass `serve` runs at boot — so migrating from the CLI ahead of a deploy is coherent with what the server would do. Previously `migrate` applied only the built-in system migrations. It remains idempotent (already-applied migrations are skipped via the `_migrations` ledger).
