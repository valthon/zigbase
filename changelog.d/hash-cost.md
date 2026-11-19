### Internal
- Test harnesses opt into cheap Argon2id password hashing with `ZIGBASE_FAKE_HASH=1` on dev-mode builds, keeping password work out of short timeout and TTL budgets. Login misses use the matching dummy cost; production builds compile out the override.
