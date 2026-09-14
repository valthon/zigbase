### Features

- Support opt-in database-only idempotent custom operations on PostgreSQL, with fail-fast namespace transaction locks, strict capacity, current authorization on replay, bounded binary receipts and atomic mutation/result commits.

### Fixes

- Refuse database copies with non-empty source or target idempotency ledgers before target writes, instead of silently omitting lazy receipts. Operators must drain operations and explicitly clean verified-expired receipts before copying.
