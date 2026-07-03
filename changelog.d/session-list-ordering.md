### Fixes
- `GET /auth/sessions` could return a principal's devices out of order when two sessions
  were created within the same second (`created` is second-resolution); the list is now
  deterministically newest-first via a portable insertion-order tiebreaker (SQLite's
  `rowid`; a new `_sessions._seq` identity column on Postgres, which has no `rowid`).
