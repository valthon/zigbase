# Schema hardening backlog

Checked items describe work included in this branch, not a release.
Development-workflow, realtime/scaling, and storage work is tracked by its own PRs.


- [x] Reconcile index-only comptime schema changes transactionally without table rebuilds.
- [x] Preserve unrelated migration-owned indexes and adopt matching ordinary indexes.
- [x] Log authoritative index changes and diagnose startup failures by collection/index.
- [x] Validate prospective access-rule field/relation references in schema apply and REST.
- [x] Cover retained cross-collection rules and explain whole-snapshot validation.
- [ ] Explicit collection rename spanning tables, relations, FTS, storage keys, and URLs.

## System migrations (#398)

- [x] Serialize system migrations and public ledger bootstrap across PostgreSQL replicas.
- [x] Preserve caller transactions on refusal and release locks on failure.
- [x] Coordinate PostgreSQL consumer apply/rollback batches, including non-transactional callbacks.
- [ ] Older binaries and multi-process SQLite migration workflows still require a single leader.

## Realtime fanout (#403)

- [x] Measure actual delivery authorization, allocations, and subscriber fanout.
- [x] Exercise benchmark correctness under ReleaseSafe in CI.
- [ ] Design bounded replay/backfill with current authorization and explicit gap semantics.

## Analytics batching (#401)

- [x] Capture explicit atomic batches with server-stamped identity and bounded inputs.
- [x] Preserve outer transaction ownership and provide a nameable runtime input type.
