#!/usr/bin/env python3
"""Generate src/backend/postgres/saslprep_tables.zig from vendored RFC 3454 / UCD extracts.

Usage:  mise exec python@3.13 -- python scripts/gen-saslprep-tables.py

Inputs (committed under vendor/unicode/, see its README.md):
  rfc3454.txt          - RFC 3454 verbatim; appendix tables are parsed structurally.
  nfkc-qc.txt          - UCD DerivedNormalizationProps lines containing NFKC_QC.
  combining-class.txt  - UCD extracted/DerivedCombiningClass lines with ccc != 0.

Output: sorted, coalesced [N]Range / [N]CccRange tables. Deterministic: same inputs ->
byte-identical output (dict/order-free, no timestamps).
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "unicode"
OUT = ROOT / "src" / "backend" / "postgres" / "saslprep_tables.zig"
UNICODE_VERSION = "16.0.0"

ENTRY_RE = re.compile(r"^([0-9A-F]{4,6})(?:-([0-9A-F]{4,6}))?$")
UCD_RANGE_RE = re.compile(r"^([0-9A-F]{4,6})(?:\.\.([0-9A-F]{4,6}))?$")


def parse_rfc_table(text: str, name: str) -> list[tuple[int, int]]:
    """Parse one RFC 3454 appendix table by its Start/End markers. Entry lines are
    `XXXX` / `XXXX-YYYY`, optionally followed by `; comment`; page headers/footers
    inside a table simply fail the entry regex and are skipped."""
    m = re.search(
        rf"----- Start Table {re.escape(name)} -----(.*?)----- End Table {re.escape(name)} -----",
        text,
        re.S,
    )
    if not m:
        raise SystemExit(f"RFC table {name} not found in rfc3454.txt")
    ranges: list[tuple[int, int]] = []
    for line in m.group(1).splitlines():
        first = line.split(";", 1)[0].strip()
        em = ENTRY_RE.fullmatch(first)
        if not em:
            continue
        lo = int(em.group(1), 16)
        hi = int(em.group(2), 16) if em.group(2) else lo
        ranges.append((lo, hi))
    if not ranges:
        raise SystemExit(f"RFC table {name} parsed to zero entries — format drift?")
    return ranges


def parse_ucd_ranges(path: Path, value_filter=None) -> list[tuple[int, int, str]]:
    """Parse `XXXX[..YYYY] ; value ...` UCD lines -> (lo, hi, value)."""
    out: list[tuple[int, int, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        rm = UCD_RANGE_RE.fullmatch(fields[0])
        if not rm:
            continue
        value = fields[-1]
        if value_filter is not None and not value_filter(fields):
            continue
        lo = int(rm.group(1), 16)
        hi = int(rm.group(2), 16) if rm.group(2) else lo
        out.append((lo, hi, value))
    if not out:
        raise SystemExit(f"{path.name} parsed to zero entries — refetch/format drift?")
    return out


def coalesce(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Sort + merge overlapping/adjacent ranges."""
    merged: list[list[int]] = []
    for lo, hi in sorted(ranges):
        if merged and lo <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return [(lo, hi) for lo, hi in merged]


def emit_range_table(name: str, doc: str, ranges: list[tuple[int, int]]) -> str:
    lines = [f"/// {doc}", f"pub const {name} = [_]Range{{"]
    for lo, hi in ranges:
        lines.append(f"    .{{ .lo = 0x{lo:04X}, .hi = 0x{hi:04X} }},")
    lines.append("};\n")
    return "\n".join(lines)


def main() -> None:
    rfc = (VENDOR / "rfc3454.txt").read_text(encoding="utf-8")

    b1 = coalesce(parse_rfc_table(rfc, "B.1"))
    c12 = coalesce(parse_rfc_table(rfc, "C.1.2"))
    prohibited_raw: list[tuple[int, int]] = []
    for tbl in ("C.1.2", "C.2.1", "C.2.2", "C.3", "C.4", "C.5", "C.6", "C.7", "C.8", "C.9"):
        prohibited_raw += parse_rfc_table(rfc, tbl)
    prohibited = coalesce(prohibited_raw)
    d1 = coalesce(parse_rfc_table(rfc, "D.1"))
    d2 = coalesce(parse_rfc_table(rfc, "D.2"))

    # NFKC_QC = No or Maybe (field layout: cp ; NFKC_QC ; N|M).
    qc = coalesce(
        [
            (lo, hi)
            for lo, hi, _ in parse_ucd_ranges(
                VENDOR / "nfkc-qc.txt",
                value_filter=lambda f: len(f) >= 3 and f[1] == "NFKC_QC" and f[2] in ("N", "M"),
            )
        ]
    )

    # Non-zero canonical combining classes, VALUE-PRESERVING (needed for the canonical-
    # ordering half of the quick check). The ccc is field 1 of this file, so it gets its
    # own parse loop; adjacent ranges are coalesced only when their ccc is equal.
    ccc_entries: list[tuple[int, int, int]] = []
    for line in (VENDOR / "combining-class.txt").read_text(encoding="utf-8").splitlines():
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [f.strip() for f in body.split(";")]
        rm = UCD_RANGE_RE.fullmatch(fields[0])
        if not rm or len(fields) < 2 or not fields[1].isdigit():
            continue
        v = int(fields[1])
        if v == 0:
            continue
        lo = int(rm.group(1), 16)
        hi = int(rm.group(2), 16) if rm.group(2) else lo
        ccc_entries.append((lo, hi, v))
    ccc_entries.sort()
    ccc_merged: list[list[int]] = []
    for lo, hi, v in ccc_entries:
        if ccc_merged and ccc_merged[-1][2] == v and lo <= ccc_merged[-1][1] + 1:
            ccc_merged[-1][1] = max(ccc_merged[-1][1], hi)
        else:
            ccc_merged.append([lo, hi, v])
    if not ccc_merged:
        raise SystemExit("combining-class.txt parsed to zero non-zero-ccc entries")

    parts: list[str] = []
    parts.append(
        "//! GENERATED by scripts/gen-saslprep-tables.py — DO NOT EDIT.\n"
        "//! Regenerate: mise exec python@3.13 -- python scripts/gen-saslprep-tables.py\n"
        f"//! Sources: RFC 3454 appendices (vendor/unicode/rfc3454.txt, frozen) + Unicode {UNICODE_VERSION}\n"
        "//! UCD extracts (vendor/unicode/nfkc-qc.txt, combining-class.txt). RFC 3454 A.1\n"
        "//! (unassigned code points) is deliberately NOT emitted — see saslprep.zig.\n\n"
        "pub const Range = struct { lo: u21, hi: u21 };\n"
        "pub const CccRange = struct { lo: u21, hi: u21, ccc: u8 };\n\n"
        f'pub const unicode_version = "{UNICODE_VERSION}";\n\n'
    )
    parts.append(emit_range_table("map_to_nothing", "RFC 3454 B.1 — mapped to nothing (soft hyphen & friends).", b1))
    parts.append(emit_range_table("map_to_space", "RFC 3454 C.1.2 — non-ASCII spaces, mapped to U+0020.", c12))
    parts.append(emit_range_table("prohibited", "RFC 4013 §2.3 prohibited output: RFC 3454 C.1.2, C.2.1, C.2.2, C.3–C.9.", prohibited))
    parts.append(emit_range_table("rand_al_cat", "RFC 3454 D.1 — RandALCat (bidi rule inputs).", d1))
    parts.append(emit_range_table("l_cat", "RFC 3454 D.2 — LCat (bidi rule inputs).", d2))
    parts.append(emit_range_table("nfkc_qc_no_or_maybe", f"UCD {UNICODE_VERSION} NFKC_Quick_Check = No or Maybe.", qc))

    lines = [f"/// UCD {UNICODE_VERSION} non-zero canonical combining classes (value-preserving).", "pub const combining_class = [_]CccRange{"]
    for lo, hi, v in ccc_merged:
        lines.append(f"    .{{ .lo = 0x{lo:04X}, .hi = 0x{hi:04X}, .ccc = {v} }},")
    lines.append("};\n")
    parts.append("\n".join(lines))

    OUT.write_text("".join(parts))
    n_ranges = sum(len(t) for t in (b1, c12, prohibited, d1, d2, qc)) + len(ccc_merged)
    print(f"wrote {OUT.relative_to(ROOT)}: 7 tables, {n_ranges} ranges (Unicode {UNICODE_VERSION})")


if __name__ == "__main__":
    main()
