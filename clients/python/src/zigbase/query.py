"""Query helpers for the ZigBase API.

Port of clients/typescript/src/query.ts (`filterValue`/`filter`, `vectorSpec`),
with the named-placeholder `zbFilter('... {:key}', {...})` API and
reject-don't-coerce hardening from clients/dart/lib/src/query.dart.

`filter_value`/`zb_filter` are security-critical: the server's filter lexer
(src/query/lexer.zig) is the arbiter of the wire format, so the escaping and
number/date rendering here must byte-match the TypeScript and Dart SDKs
exactly. See `_format_number` for how JS `Number.prototype.toString()` /
`JSON.stringify()` formatting is reproduced from Python's own shortest
round-trip float `repr()`.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping, Sequence
from datetime import datetime, timezone

_ESCAPE_RE = re.compile(r"[\\'\n\t\r]")
_ESCAPE_MAP = {
    "\\": "\\\\",
    "'": "\\'",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}


def _quote_string(s: str) -> str:
    """Single-quote `s` as a filter literal, escaping backslash/quote/CRLF/tab.

    The server lexer unescapes `\\\\`, `\\'`, `\\n`, `\\t`, `\\r` inside a
    quoted string. Escaping exactly those bytes (and leaving everything else,
    including a double quote, literal) means the closing single quote can
    never appear unescaped — the literal can never be broken out of.
    """
    escaped = _ESCAPE_RE.sub(lambda m: _ESCAPE_MAP[m.group(0)], s)
    return f"'{escaped}'"


def _shortest_digits(value: float) -> tuple[str, int]:
    """Extract the shortest round-trip decimal digits of a positive finite float.

    Returns `(digits, point)` such that `value == int(digits) * 10 ** (point -
    len(digits))` and `digits` has no leading or trailing zero. Python's
    `repr()` already computes the shortest round-trip decimal representation
    (same digit sequence a JS engine's dtoa would produce for the same IEEE
    754 double) — this just re-parses it into a notation-independent form so
    `_format_number` can re-render it with JS's own notation rules, which
    differ from Python's.
    """
    r = repr(value)
    mantissa, _, exp_part = r.partition("e")
    exp = int(exp_part) if exp_part else 0
    if "." in mantissa:
        int_part, frac_part = mantissa.split(".")
    else:
        int_part, frac_part = mantissa, ""
    digits = int_part + frac_part
    point = len(int_part) + exp

    stripped = digits.lstrip("0")
    point -= len(digits) - len(stripped)
    digits = stripped

    stripped = digits.rstrip("0")
    digits = stripped if stripped else "0"
    return digits, point


def _format_number(value: float) -> str:
    """Format a finite float to match JS `Number.prototype.toString()` bytes.

    Reproduces the ECMA-262 Number::toString notation rules (fixed notation
    for a decimal-point position `n` in `(-6, 21]`, exponential otherwise) on
    top of the digit/point pair from `_shortest_digits`, so integral floats
    render bare (`1`, not `1.0`) and the exponent notation-switch boundaries
    match JS exactly.
    """
    if value == 0:
        return "0"  # collapses -0.0 -> "0", matching JS String(-0).
    sign = "-" if value < 0 else ""
    digits, n = _shortest_digits(abs(value))
    k = len(digits)

    if k <= n <= 21:
        return f"{sign}{digits}{'0' * (n - k)}"
    if 0 < n <= 21:
        return f"{sign}{digits[:n]}.{digits[n:]}"
    if -6 < n <= 0:
        return f"{sign}0.{'0' * -n}{digits}"

    exp = n - 1
    exp_str = f"{'+' if exp >= 0 else '-'}{abs(exp)}"
    mantissa = digits if k == 1 else f"{digits[0]}.{digits[1:]}"
    return f"{sign}{mantissa}e{exp_str}"


def format_date(dt: datetime) -> str:
    """Format `dt` as a UTC ISO-8601 literal clamped to millisecond precision.

    Matches JS `Date.prototype.toISOString()` byte-for-byte: always exactly a
    3-digit fraction and a trailing `Z`. A naive `dt` is assumed to already be
    UTC (no conversion); an aware `dt` is converted to UTC first. Sub-
    millisecond precision is truncated (floored), not rounded — this matches
    the Dart port and avoids a truncation that could round a boundary value
    the wrong way.
    """
    utc = dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)
    millis = utc.microsecond // 1000
    base = utc.strftime("%Y-%m-%dT%H:%M:%S")
    return f"{base}.{millis:03d}Z"


def filter_value(value: object) -> str:
    """Serialize a single interpolated value into a safe filter operand.

    `None` -> `null`; `bool` -> `true`/`false`; `int`/finite `float` -> bare
    (integral floats render bare: `1`, not `1.0`); `datetime` -> single-quoted
    `format_date`; `str` -> single-quoted and escaped (see `_quote_string`).
    Any other type — including `list`/`dict` (array/object operands are
    ambiguous; expand them yourself, e.g. into an `||` chain or a native
    `in (...)` clause) and non-finite floats — raises `TypeError` rather than
    silently coercing.
    """
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise TypeError(f"filter: non-finite number operand: {value!r}")
        return _format_number(value)
    if isinstance(value, datetime):
        return _quote_string(format_date(value))
    if isinstance(value, str):
        return _quote_string(value)
    if isinstance(value, list):
        raise TypeError(
            "filter: array operands are ambiguous; expand them yourself "
            f"(e.g. build an `||` chain): {value!r}"
        )
    raise TypeError(f"filter: unsupported operand type: {type(value).__name__}: {value!r}")


_PLACEHOLDER_RE = re.compile(r"\{:([A-Za-z_][A-Za-z0-9_]*)\}")


def zb_filter(expr: str, params: Mapping[str, object]) -> str:
    """Interpolate named `{:name}` placeholders in `expr` with `filter_value(params[name])`.

    Static text outside placeholders passes through verbatim.

        zb_filter("status = {:s} && n > {:n}", {"s": "it's", "n": 5})
        # => "status = 'it\\'s' && n > 5"

    Raises `KeyError` if `expr` references a name absent from `params`, and
    `ValueError` if `params` contains a key never referenced by `expr` — a
    stricter, reject-don't-coerce posture than the Dart port, which only
    checks the former.
    """
    used: set[str] = set()

    def _sub(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in params:
            raise KeyError(f"zb_filter: unknown placeholder {{:{name}}}")
        used.add(name)
        return filter_value(params[name])

    result = _PLACEHOLDER_RE.sub(_sub, expr)
    unused = set(params.keys()) - used
    if unused:
        raise ValueError(f"zb_filter: unused param(s): {', '.join(sorted(unused))}")
    return result


def vector_spec(field: str, embedding: Sequence[float], *, metric: str | None = None) -> str:
    """Serialize a nearest-neighbor query to the `<field>[:metric]:<json-embedding>`
    wire spec of `GET /api/collections/:col/records?vector=…`.

    Requires ZigBase >= 0.9.0 built with `-Dvector=true` (a default build
    answers 400 "Vector search is not enabled in this build."). Vector search
    is offset-only — the server rejects it in cursor mode. `metric` is
    `"cosine"` or `"l2"`; the server defaults to cosine when omitted. Raises
    `TypeError` on a non-finite or non-numeric embedding element (same
    posture as `filter_value`).

    The embedding is rendered with the same byte format as JS
    `JSON.stringify(values)` (comma-separated, no whitespace, integral floats
    bare) since the TS SDK builds this spec via `JSON.stringify` and every
    SDK must produce identical wire bytes.
    """
    parts: list[str] = []
    for v in embedding:
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise TypeError(f"vector_spec: non-numeric embedding value: {v!r}")
        fv = float(v)
        if not math.isfinite(fv):
            raise TypeError(f"vector_spec: non-finite embedding value: {v!r}")
        parts.append(_format_number(fv))
    metric_part = f":{metric}" if metric else ""
    return f"{field}{metric_part}:[{','.join(parts)}]"


def build_list_params(
    *,
    filter: str | None = None,
    sort: str | None = None,
    expand: str | None = None,
    fields: str | None = None,
    search: str | None = None,
    page: int | None = None,
    per_page: int | None = None,
    cursor: str | None = None,
    limit: int | None = None,
    skip_total: bool | None = None,
    vector: str | None = None,
) -> dict[str, str]:
    """Build the wire query-string params for `GET /api/collections/:col/records`.

    Emits wire param names (`perPage`, `skipTotal`, ...) and **omits** any
    parameter left as `None` — an empty string is a distinct, meaningful
    value (e.g. `cursor=""` means "first page" in cursor mode) and is always
    emitted. Presence of `cursor`/`limit` vs. `page`/`per_page` is what
    selects cursor vs. offset mode server-side, so callers must not pass
    default/placeholder values for the mode they are not using.
    """
    params: dict[str, str] = {}
    if filter is not None:
        params["filter"] = filter
    if sort is not None:
        params["sort"] = sort
    if expand is not None:
        params["expand"] = expand
    if fields is not None:
        params["fields"] = fields
    if search is not None:
        params["search"] = search
    if page is not None:
        params["page"] = str(page)
    if per_page is not None:
        params["perPage"] = str(per_page)
    if cursor is not None:
        params["cursor"] = cursor
    if limit is not None:
        params["limit"] = str(limit)
    if skip_total is not None:
        params["skipTotal"] = "true" if skip_total else "false"
    if vector is not None:
        params["vector"] = vector
    return params


__all__ = [
    "build_list_params",
    "filter_value",
    "format_date",
    "vector_spec",
    "zb_filter",
]
