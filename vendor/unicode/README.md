# Vendored Unicode / RFC data for SASLprep table generation

Inputs to `scripts/gen-saslprep-tables.py`, which emits the checked-in
`src/backend/postgres/saslprep_tables.zig`. Do not edit these by hand.

- `rfc3454.txt` — RFC 3454 verbatim (https://www.rfc-editor.org/rfc/rfc3454.txt). The
  generator parses appendix tables B.1, C.1.2, C.2.1, C.2.2, C.3–C.9, D.1, D.2 out of the
  `----- Start Table X -----` / `----- End Table X -----` blocks. Frozen forever by the RFC.
- `nfkc-qc.txt` — the `NFKC_QC`-property lines of Unicode 16.0.0
  `DerivedNormalizationProps.txt` (https://www.unicode.org/Public/16.0.0/ucd/).
- `combining-class.txt` — the non-zero canonical-combining-class lines of Unicode 16.0.0
  `extracted/DerivedCombiningClass.txt`.

To bump the Unicode version: re-run the two `curl | grep` commands in
`docs`-recorded form (see the plan / script header), update `UNICODE_VERSION` in the
script, regenerate, and commit both the extracts and the regenerated tables file.
