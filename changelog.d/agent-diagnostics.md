### Features
- Add required-input descriptors for the tuning advisor and a dev-tools-gated `diagnostics` command that wraps doctor checks and failures in versioned JSON. Ordinary doctor NDJSON stays unchanged.

### Breaking
- Revise the unreleased capability catalog in place: `diagnostics` now invokes the single-document JSON adapter rather than doctor NDJSON, required-input operations are included in the one catalog, and there is no `--protocol-version` selector. Integer descriptor bounds use lossless decimal strings and forbidden label bytes use explicit inclusive ranges.
