### Breaking

- The dev-only build option `-Ddev-clock` is renamed `-Ddev-mode` (it already gated the frozen clock, seeded entropy, and test-capture; it now also gates the new fake field-crypto). Update any CI/e2e invocation of `-Ddev-clock=…` to `-Ddev-mode=…`.

### Features

- `zigbase.testing` can now boot apps that declare `.encrypted` fields (#260): pass `StartOptions.field_key` for real AES-GCM, or let it default to a dev-only **fake-encrypt** mode that stores readable `fake:<key>:<value>` at rest (label defaults to `@test@`) so encrypted values are eyeball-able while debugging. Also selectable on `zigbase serve` via `ZIGBASE_FIELD_CRYPTO=fake`. Fake crypto is compiled out of release binaries (the `dev_mode` gate) and its envelopes are mutually unreadable with real ciphertext, so a fake DB can never be served by a production binary.
