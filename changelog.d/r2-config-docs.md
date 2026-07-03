### Fixes

- The `App(.{…})` config-key table in docs/framework.md claimed to be exhaustive while omitting 9 keys (`captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features`); it is now complete, states each key's binary-size contract ("unset ⇒ excluded/data-only/always"), and documents the config-plane assignment rule + laziness contract.

### Internal

- A table↔`allowed`-tuple parity test (`tests/admin/test_docs_parity.py::test_config_key_table_matches_allowed_tuple`) guards the config-key table against future drift.
- Tightened the env-var help-parity test's text slice to end at `EXAMPLES:` instead of running to EOF — the old unbounded slice would false-pass a `ZIGBASE_*` name that only appeared in a later `std.log` message, not in the actual help text.
