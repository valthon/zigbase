### Internal

- CI now runs a `-Ddev-clock=false` prod-gate test pass in the `unit` job; the five inverse-gated tests that assert `ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, and test-capture are compiled out of production builds were previously skipped in the only CI test run and were never actually executed.
