### Internal

- CI now runs a `-Ddev-clock=false` prod-gate test pass in the `unit` job. Previously, the five inverse-gated tests asserting that `ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, and test-capture are compiled out of production builds were skipped in the only CI test run and never executed.
