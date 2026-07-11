<!--
  MANUALLY CURATED — do not auto-generate.

  This is the advisory list that `zig build audit` (scripts/audit-deps.sh) checks the
  binary's pinned dependency versions against. It is intentionally small and hand-maintained:
  security advisories are not machine-discoverable from inside this repo, so a human adds a row
  when a relevant CVE/advisory lands for a vendored/native dependency.

  How to update:
    1. When a new advisory affects SQLite, sqlite-vec, zap, or facil.io, add a row to the
       "Advisory table" below. Keep the columns in order and pipe-delimited.
    2. `Min safe version` is the comparison key the audit script uses: a pinned version STRICTLY
       BELOW it is reported as AFFECTED (non-zero exit). Use `-` for a row with no fixed version
       or a purely informational "no known advisory" row (the script skips those).
    3. `Affected range` and `Note` are for humans; the script does not parse them.
    4. Version strings are compared with `sort -V` (semver); a leading `v` is stripped.
    5. Run `zig build audit` locally to confirm the current pins are clean, then commit.

  See docs/security-audit.md → "Dependency version transparency & supply-chain auditing" for the
  full transparency + update-process story, and where the pinned versions are single-sourced from.
-->

# Dependency security advisories (curated)

This file is the curated advisory list for ZigBase's vendored/native dependencies. A ZigBase
binary bakes in a vendored SQLite C amalgamation, an optional sqlite-vec amalgamation, and the
`zap`/facil.io HTTP server; this list lets `zig build audit` flag a pinned version that falls in a
known-affected range. It is small and honest by design — only real advisories with a known
fixed-in version are actionable rows; everything else is an informational "no known advisory" line.

The pinned versions themselves are single-sourced elsewhere (see `docs/security-audit.md`):
SQLite/sqlite-vec from their vendored headers, `zap` from `build.zig.zon`, and facil.io as a
curated constant tied to the `zap` pin. Surface them at runtime with `zig build versions`,
`zigbase --version`, or `GET /api/health`.

## Advisory table

| Component  | Affected range | Min safe version | Advisory | Note |
|------------|----------------|------------------|----------|------|
| sqlite     | < 3.43.1       | 3.43.1           | [CVE-2023-7104](https://nvd.nist.gov/vuln/detail/CVE-2023-7104) | Heap buffer overflow in the `sessions` extension (`sessionReadRecord`); fixed in 3.43.1. Unaffected at the pinned 3.53.2. |
| sqlite     | < 3.34.1       | 3.34.1           | [CVE-2021-20227](https://nvd.nist.gov/vuln/detail/CVE-2021-20227) | Use-after-free when a bound parameter is reused across a schema change; fixed in 3.34.1. Unaffected at the pinned 3.53.2. |
| sqlite-vec | -              | -                | -        | No known advisory at the pinned v0.1.6 (only linked with `-Dvector`). |
| zap        | -              | -                | -        | No known advisory at the pinned 0.10.6. |
| facil.io   | -              | -                | -        | No known advisory at the pinned 0.7.4 (bundled inside the pinned `zap`). |

The two SQLite rows are real historical advisories kept as **worked examples**: they demonstrate
the audit mechanism catching an affected range, while the current pin (3.53.2) sits safely above
both fixed-in versions, so `zig build audit` reports them as OK. When a genuinely relevant advisory
lands, add a row the same way and re-pin/upgrade until `zig build audit` is clean again.
