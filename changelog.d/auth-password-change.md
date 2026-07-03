### Features

- Self-service password change via `PATCH /api/collections/:col/records/:id`: non-superusers must include a verifying `oldPassword`; on success every other session for the record is invalidated (tokenKey rotation, plus `_sessions` purge in table mode) while a self-change keeps the calling device signed in via fresh `Set-Cookie` headers. The `beforePasswordChange`/`afterPasswordChange` lifecycle hooks now fire on this path too. `@zigbase/client` gains `collection(col).changePassword(id, oldPassword, newPassword)` (transparent re-auth in token mode).

### Security

- `oldPassword` verification is non-oracle: wrong/missing values, unknown records, and passwordless targets all return the login-identical `400 "Invalid credentials."` with argon2 timing padding, and the path is rate-limited under a new `"pwchange"` scope (global limiter budget) before any argon2 work runs.
