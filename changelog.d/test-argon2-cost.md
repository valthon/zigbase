### Internal

- Use deliberately weak argon2id parameters in **test builds only** (keyed on `builtin.is_test`). The unit suite hashes/verifies passwords across ~700 tests; at production cost (`interactive_2id`, 64 MiB) that KDF work alone was ~25 s of every `zig build test`. A warm `zig build test` now runs in ~6 s (was ~32 s). The shipped server binary and the Playwright browser suite (which drives the real binary) are unaffected and keep full-strength params.
