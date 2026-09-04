#!/usr/bin/env python3
"""Parity-replay harness for ZigBase migrations.

Record a backend's HTTP behaviour, replay it against its replacement, diff the results.
Deliberately source-agnostic: `record` never assumes the old backend is ZigBase, which is
the whole point — you record PocketBase/Rails/Express and replay ZigBase.

Comparison is a recursive SUBSET match, not equality: every key in the expectation must be
present and equal in the response, extra keys are fine, and volatile keys (ids, timestamps,
tokens) are stripped when recording so they never become expectations. A tool that fails on
every generated id gets ignored, and an ignored parity check makes the migration claim
dishonest.

Exit codes (`replay`): 0 every case passed; 2 the run completed and found something needing
judgment — a parity failure, or a per-case transport error (an endpoint that vanished is
itself a finding, not a tool problem); 1 a tool failure — an unreadable capture, an
unresolved `{{placeholder}}`, or every single case dying in transport (nothing was exercised,
so there is nothing to judge).
"""

import argparse
import http.client
import json
import math
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

EVIDENCE_CONTROLS = frozenset({"allowed", "denied", "journey", "validation"})


def allowed_controls_for_status(status: int) -> frozenset[str]:
    if 200 <= status < 300:
        return frozenset({"allowed"})
    if 300 <= status < 400:
        return frozenset({"allowed", "journey"})
    if status == 400:
        return frozenset({"denied", "validation"})
    if status in {401, 403, 404}:
        return frozenset({"denied"})
    if status in {409, 422}:
        return frozenset({"validation"})
    return frozenset()


CAPTURE_VERSION = 1
MAX_CAPTURE_BYTES = 32 * 1024 * 1024
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
DEFAULT_VOLATILE = [
    "id",
    "created",
    "updated",
    "token",
    "collectionId",
    "collectionName",
    "expand",
]

# Sentinel for "this key is absent from `actual`", distinct from an actual value of `None`.
# `dict.get(k)` returns `None` both when the key holds `null` and when the key is missing —
# collapsing those would let a migration that drops a nullable field (e.g. `deletedAt`)
# silently pass replay, since `{}` would satisfy an expectation of `{"deletedAt": None}`.
_MISSING = object()


class ReplayError(Exception):
    """A tool-level problem: a malformed capture, an unresolvable placeholder, a dead host."""


MAX_SUBSTITUTION_PASSES = 10
HTTP_TOKEN_CHARS = frozenset(
    "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
)
_CROSS_ORIGIN_REDIRECT_HEADERS = frozenset(
    {
        "accept",
        "accept-encoding",
        "accept-language",
        "cache-control",
        "if-match",
        "if-modified-since",
        "if-none-match",
        "if-range",
        "if-unmodified-since",
        "range",
        "user-agent",
    }
)
CASE_KEYS = frozenset(
    {"id", "method", "path", "query", "headers", "body", "expect", "followRedirects"}
)
EXPECT_KEYS = frozenset({"status", "bodySubset", "control"})


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Observe the first response; never replay credentials at a Location target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        return None


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Preserve v1 redirects without forwarding credentials to another origin."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return redirected
        try:
            same_origin = _url_origin(req.full_url) == _url_origin(newurl)
        except ValueError:
            # An invalid redirect target must never inherit credentials. The opener will
            # reject the malformed URL, and send_resolved turns that into ReplayError.
            same_origin = False
        if same_origin:
            return redirected
        # Captures may contain application-specific credentials (X-API-Key,
        # X-CSRF-Token, tenant Host overrides, and so on).  There is no reliable
        # denylist for those names, so only ordinary representation metadata may
        # cross an origin boundary.
        for header_map in (redirected.headers, redirected.unredirected_hdrs):
            for header in list(header_map):
                if header.lower() not in _CROSS_ORIGIN_REDIRECT_HEADERS:
                    del header_map[header]
        return redirected


def _url_origin(url):
    parsed = urllib.parse.urlsplit(url)
    port = parsed.port
    if port is None:
        port = 443 if parsed.scheme.lower() == "https" else 80
    return parsed.scheme.lower(), (parsed.hostname or "").lower(), port


_NO_REDIRECT_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _NoRedirect()
)
_FOLLOW_REDIRECT_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _SafeRedirect()
)


def _open_url(request, *, timeout, follow_redirects=True):
    opener = _FOLLOW_REDIRECT_OPENER if follow_redirects else _NO_REDIRECT_OPENER
    return opener.open(request, timeout=timeout)


def _reject_json_constant(value):
    raise ValueError(f"non-finite JSON number {value}")


def _parse_finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"non-finite JSON number {value}")
    return number


def _capture_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def _read_bounded_regular(path, maximum):
    """Read one capture with a hard byte bound."""
    with open(path, "rb") as source:
        payload = source.read(maximum + 1)
    if len(payload) > maximum:
        raise ValueError(f"capture exceeds the {maximum}-byte limit")
    return payload


def _string_map(value, *, path, line, case_id, field):
    if value is None:
        return
    if not isinstance(value, dict) or any(
        not isinstance(key, str) or not isinstance(item, str)
        for key, item in value.items()
    ):
        raise ReplayError(
            f"{path}:{line}: case {case_id!r} {field} must be an object of strings"
        )


def _validate_request_case(case, *, where, allow_placeholders):
    """Validate the request shape at load time and again after substitution."""
    cid = case.get("id") if isinstance(case, dict) else None
    method = case.get("method") if isinstance(case, dict) else None
    request_path = case.get("path") if isinstance(case, dict) else None
    if isinstance(case, dict) and (unknown := sorted(set(case) - CASE_KEYS)):
        raise ReplayError(f"{where}: case {cid!r} has unsupported key(s): {unknown}")
    if (
        not isinstance(cid, (str, int, float, bool))
        or not cid
        or isinstance(cid, str)
        and (not cid.strip() or cid != cid.strip())
        or not isinstance(method, str)
        or not method
        or any(character not in HTTP_TOKEN_CHARS for character in method)
    ):
        raise ReplayError(
            f'{where}: every case needs a unique "id", "method", and "path"'
        )
    if (
        not isinstance(request_path, str)
        or not request_path.startswith("/")
        or any(
            ord(character) < 0x20 or ord(character) == 0x7F
            for character in request_path
        )
        or not allow_placeholders
        and "{{" in request_path
    ):
        raise ReplayError(
            f"{where}: case {cid!r} path must be an absolute path without "
            "an unresolved placeholder or control character"
        )
    if "followRedirects" in case and not isinstance(case["followRedirects"], bool):
        raise ReplayError(f"{where}: case {cid!r} followRedirects must be a boolean")
    _string_map(
        case.get("query"), path=where, line="request", case_id=cid, field="query"
    )
    _string_map(
        case.get("headers"),
        path=where,
        line="request",
        case_id=cid,
        field="headers",
    )
    for name, value in (case.get("headers") or {}).items():
        if not name or any(character not in HTTP_TOKEN_CHARS for character in name):
            raise ReplayError(f"{where}: case {cid!r} has an invalid header name")
        if any(
            ord(character) < 0x20 and character != "\t" or ord(character) == 0x7F
            for character in value
        ):
            raise ReplayError(f"{where}: case {cid!r} has an invalid header value")


def _expand_pass(out, variables):
    """One left-to-right sweep: replace every currently-present `{{name}}` exactly once.

    A string with many distinct placeholders (e.g. a captured URL or body with a dozen
    `{{var}}` substitutions) fully resolves in this single sweep. `{{` left unresolved
    because it lacks a closing `}}` is passed through untouched. Returns `(result,
    expanded)`, where `expanded` is False only when nothing in the string was actually
    substitutable (the unclosed-`{{` case) — distinct from `result == out`, which can
    also happen legitimately when a placeholder's value is itself literal `{{...}}` text
    (self-reference), and that case must keep looping so it hits the convergence cap.
    """
    result = []
    i = 0
    expanded = False
    while True:
        start = out.find("{{", i)
        if start < 0:
            result.append(out[i:])
            break
        end = out.find("}}", start)
        if end < 0:
            result.append(out[i:])
            break
        result.append(out[i:start])
        name = out[start + 2 : end]
        if name not in variables:
            raise ReplayError(
                f"unresolved placeholder {{{{{name}}}}} — pass --var {name}=VALUE"
            )
        result.append(variables[name])
        expanded = True
        i = end + 2
    return "".join(result), expanded


def substitute(value, variables):
    """Resolve {{name}} placeholders in strings, recursively through dicts and lists."""
    if isinstance(value, str):
        out = value
        passes = 0
        while "{{" in out:
            # Each pass expands every placeholder present in one sweep, so `passes` counts
            # nesting depth (e.g. "{{a}}" -> "{{b}}" -> "c" takes two passes), not the number
            # of distinct placeholders — a string with a dozen unrelated `{{var}}`s resolves
            # in one pass. A --var value that itself contains a "{{...}}" substring
            # (accidentally or adversarially, including self-reference) re-introduces "{{" on
            # every pass and would otherwise loop forever — cap the number of passes rather
            # than loop until the process is killed.
            passes += 1
            if passes > MAX_SUBSTITUTION_PASSES:
                raise ReplayError(
                    f"placeholder substitution did not converge after {MAX_SUBSTITUTION_PASSES} "
                    f"passes (a --var value likely contains a literal '{{{{...}}}}' placeholder): {out!r}"
                )
            new_out, expanded = _expand_pass(out, variables)
            if not expanded:
                # Nothing was actually resolvable this pass (a dangling unclosed "{{") —
                # further passes would be identical, so stop instead of spinning.
                break
            out = new_out
        return out
    if isinstance(value, dict):
        return {k: substitute(v, variables) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, variables) for v in value]
    return value


def strip_volatile(value, keys):
    """Remove volatile keys everywhere in a JSON value, so they never become expectations."""
    if isinstance(value, dict):
        return {k: strip_volatile(v, keys) for k, v in value.items() if k not in keys}
    if isinstance(value, list):
        return [strip_volatile(v, keys) for v in value]
    return value


def diff_subset(expected, actual, path=""):
    """Every key in `expected` must be present and equal in `actual`. Extra keys are fine;
    arrays compare element-wise up to the expectation's length. A key that is entirely
    absent from `actual` is always a diff — even when `expected` holds `None` — so an
    expectation of `null` still requires the key to exist, not merely be unset or missing."""
    out = []
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [{"path": path or ".", "expected": expected, "actual": actual}]
        for k, v in expected.items():
            sub = f"{path}.{k}" if path else k
            av = actual.get(k, _MISSING)
            if av is _MISSING:
                out.append(
                    {
                        "path": sub,
                        "expected": v,
                        "actual": None,
                        "message": "missing key",
                    }
                )
            else:
                out.extend(diff_subset(v, av, sub))
        return out
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [{"path": path or ".", "expected": expected, "actual": actual}]
        for i, v in enumerate(expected):
            sub = f"{path}.{i}" if path else str(i)
            av = actual[i] if i < len(actual) else _MISSING
            if av is _MISSING:
                out.append(
                    {
                        "path": sub,
                        "expected": v,
                        "actual": None,
                        "message": "missing key",
                    }
                )
            else:
                out.extend(diff_subset(v, av, sub))
        return out
    if expected != actual:
        out.append({"path": path or ".", "expected": expected, "actual": actual})
    return out


def load_capture(path, *, mode="capture"):
    """Read and validate replay NDJSON before any network I/O.

    ``requests`` mode permits a producer control without a recorded status because record
    mode is about to replace the response expectation. ``capture`` mode additionally
    validates every recorded status/control pair so all consumers share one wire contract.
    An explicit JSON ``null`` expectation retains the original replay meaning: no
    expectation, the same as omitting the key.
    """
    if mode not in {"capture", "requests"}:
        raise ValueError(f"unsupported capture mode {mode!r}")
    cases, seen = [], set()
    try:
        payload = _read_bounded_regular(path, MAX_CAPTURE_BYTES)
    except (OSError, ValueError) as e:
        raise ReplayError(f"cannot read {path}: {e}") from e
    try:
        text = payload.decode("utf-8")
    except UnicodeError as e:
        raise ReplayError(f"cannot read {path}: capture is not UTF-8: {e}") from e
    # NDJSON records are separated by the physical LF byte. ``splitlines()`` also
    # treats Unicode separators inside otherwise valid JSON strings as boundaries.
    for n, line in enumerate(text.split("\n"), 1):
        line = line.strip()
        if not line:
            continue
        try:
            case = json.loads(
                line,
                parse_constant=_reject_json_constant,
                parse_float=_parse_finite_float,
                object_pairs_hook=_capture_object,
            )
        except (json.JSONDecodeError, ValueError) as e:
            raise ReplayError(f"{path}:{n}: not JSON: {e}") from e
        if not isinstance(case, dict):
            raise ReplayError(f"{path}:{n}: every case must be a JSON object")
        cid = case.get("id")
        if (
            not isinstance(cid, (str, int, float, bool))
            or not cid
            or (isinstance(cid, str) and (not cid.strip() or cid != cid.strip()))
        ):
            raise ReplayError(f'{path}:{n}: every case needs a unique "id"')
        identity = (type(cid).__name__, cid)
        if identity in seen:
            raise ReplayError(f"{path}:{n}: duplicate case id {cid!r}")
        _validate_request_case(
            case,
            where=f"{path}:{n}",
            allow_placeholders=True,
        )
        if case.get("expect") is not None and not isinstance(case["expect"], dict):
            raise ReplayError(f"{path}:{n}: case {cid!r} expect must be an object")
        expect = case.get("expect") or {}
        if unknown := sorted(set(expect) - EXPECT_KEYS):
            raise ReplayError(
                f"{path}:{n}: case {cid!r} expect has unsupported key(s): {unknown}"
            )
        status = expect.get("status", _MISSING)
        if (
            status is not _MISSING
            and status is not None
            and (not isinstance(status, int) or isinstance(status, bool))
        ):
            raise ReplayError(
                f"{path}:{n}: case {cid!r} expect.status must be an integer"
            )
        if status is not _MISSING and status is not None and not 100 <= status <= 599:
            raise ReplayError(
                f"{path}:{n}: case {cid!r} expect.status must be between 100 and 599"
            )
        if "control" in expect:
            control = expect["control"]
            if not isinstance(control, str) or not control.strip():
                raise ReplayError(
                    f"{path}:{n}: case {cid!r} expect.control must be a non-empty string"
                )
            if control not in EVIDENCE_CONTROLS:
                raise ReplayError(
                    f"{path}:{n}: case {cid!r} expect.control {control!r} is unsupported"
                )
            if mode == "capture":
                if status is _MISSING or status is None:
                    raise ReplayError(
                        f"{path}:{n}: case {cid!r} expect.control requires expect.status"
                    )
                _validate_control_for_status(
                    cid, status, control, where=f"{path}:{n}: "
                )
        seen.add(identity)
        cases.append(case)
    return cases


def send_resolved(base_url, case, timeout):
    """Issue one resolved case, preserving binary bodies for status-only evidence."""
    _validate_request_case(
        case,
        where=f"resolved case {case.get('id')!r}",
        allow_placeholders=False,
    )
    url = base_url.rstrip("/") + case["path"]
    if case.get("query"):
        url += ("&" if "?" in case["path"] else "?") + urllib.parse.urlencode(
            case["query"]
        )
    # urllib's HTTP layer requires an ASCII request target. Preserve existing
    # percent escapes while encoding raw Unicode accepted by v1 captures.
    url = urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%")
    data = None
    headers = dict(case.get("headers") or {})
    if case.get("body") is not None:
        try:
            data = json.dumps(case["body"], allow_nan=False).encode()
        except (TypeError, ValueError) as exc:
            raise ReplayError(
                f"case {case['id']!r} body is not strict JSON: {exc}"
            ) from exc
        headers.setdefault("Content-Type", "application/json")
    try:
        req = urllib.request.Request(
            url, method=case["method"], data=data, headers=headers
        )
        with _open_url(
            req,
            timeout=timeout,
            follow_redirects=case.get("followRedirects", True),
        ) as response:
            raw, status = _read_response(response, case["id"]), response.status
    except urllib.error.HTTPError as e:
        with e:
            raw, status = _read_response(e, case["id"]), e.code
    except (OSError, ValueError, http.client.HTTPException) as e:
        raise ReplayError(f"{case['id']}: {url}: {e}") from e
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError:
        return status, raw
    try:
        return (
            status,
            json.loads(
                decoded,
                parse_constant=_reject_json_constant,
                parse_float=_parse_finite_float,
                object_pairs_hook=_capture_object,
            )
            if decoded
            else None,
        )
    except (json.JSONDecodeError, ValueError):
        return status, decoded


def _read_response(response, case_id):
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ReplayError(
            f"{case_id}: response exceeds the {MAX_RESPONSE_BYTES}-byte limit"
        )
    return payload


def send(base_url, case, variables, timeout):
    """Substitute and issue one case. Returns (status, parsed body or raw text)."""
    return send_resolved(base_url, substitute(case, variables), timeout)


def compare(case, status, body):
    expect = case.get("expect") or {}
    finding = {"id": case["id"], "result": "pass", "diff": []}
    if expect.get("status") is not None and expect["status"] != status:
        finding["status"] = {"expected": expect["status"], "actual": status}
        finding["result"] = "fail"
    if expect.get("bodySubset") is not None:
        d = (
            [
                {
                    "path": ".",
                    "expected": expect["bodySubset"],
                    "actual": f"<binary response: {len(body)} bytes>",
                }
            ]
            if isinstance(body, bytes)
            else diff_subset(expect["bodySubset"], body)
        )
        if d:
            finding["diff"] = d
            finding["result"] = "fail"
    return finding


def parse_vars(pairs):
    out = {}
    for p in pairs or []:
        if "=" not in p:
            raise ReplayError(f"--var expects NAME=VALUE, got {p!r}")
        k, v = p.split("=", 1)
        out[k] = v
    return out


def _validate_control_for_status(
    case_id, status, control, *, where="", status_label="status"
):
    if control is _MISSING:
        return
    allowed = allowed_controls_for_status(status)
    if control not in allowed:
        raise ReplayError(
            f"{where}{case_id}: expect.control {control!r} is incompatible with "
            f"{status_label} "
            f"{status}; expected one of {sorted(allowed)}"
        )


def validate_recorded_control(case_id, status, control):
    """Validate a pre-parsed optional producer control against a live response."""
    _validate_control_for_status(
        case_id, status, control, status_label="recorded status"
    )


def _write_ndjson_atomic(path, rows, *, label):
    """Replace one complete NDJSON artifact without truncating a prior result."""
    destination = os.path.abspath(path)
    parent = os.path.dirname(destination)
    descriptor = -1
    temporary = None
    try:
        os.makedirs(parent, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            dir=parent, prefix=f".{os.path.basename(destination)}.", suffix=".tmp"
        )
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as out:
            descriptor = -1
            for row in rows:
                out.write(json.dumps(row, allow_nan=False) + "\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, destination)
        temporary = None
    except (OSError, TypeError, ValueError) as exc:
        raise ReplayError(f"cannot write {label} {path}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def _write_capture_atomic(path, cases):
    """Flush and atomically replace one complete private capture."""
    _write_ndjson_atomic(path, cases, label="capture")


def _write_findings_atomic(path, findings):
    """Flush and atomically replace one complete private findings file."""
    _write_ndjson_atomic(path, findings, label="findings")


def cmd_record(args):
    variables = parse_vars(args.var)
    volatile = DEFAULT_VOLATILE + (args.volatile or [])
    cases = load_capture(args.requests, mode="requests")
    if not cases:
        raise ReplayError(
            "requests capture contains no cases; nothing would be recorded"
        )
    recorded = []
    for case in cases:
        status, body = send(args.base_url, case, variables, args.timeout)
        control = (case.get("expect") or {}).get("control", _MISSING)
        validate_recorded_control(case["id"], status, control)
        case["expect"] = {"status": status}
        if not isinstance(body, bytes):
            case["expect"]["bodySubset"] = strip_volatile(body, volatile)
        if control is not _MISSING:
            case["expect"]["control"] = control
        recorded.append(case)
    _write_capture_atomic(args.out, recorded)
    summary = {
        "zigbaseReplay": CAPTURE_VERSION,
        "mode": "record",
        "base_url": args.base_url,
        "recorded": len(recorded),
        "capture": args.out,
    }
    print(json.dumps(summary))
    return 0


def cmd_replay(args):
    variables = parse_vars(args.var)
    cases = load_capture(args.capture)
    if not cases:
        raise ReplayError(
            "replay capture contains no cases; nothing would be exercised"
        )
    passed = failed = errors = 0
    findings = []
    for case in cases:
        try:
            status, body = send(args.base_url, case, variables, args.timeout)
        except ReplayError as e:
            errors += 1
            findings.append({"id": case["id"], "result": "error", "message": str(e)})
            continue
        finding = compare(case, status, body)
        if finding["result"] == "pass":
            passed += 1
        else:
            failed += 1
        findings.append(finding)
    _write_findings_atomic(args.out, findings)
    total = len(cases)
    summary = {
        "zigbaseReplay": CAPTURE_VERSION,
        "mode": "replay",
        "base_url": args.base_url,
        "total": total,
        "passed": passed,
        "failed": failed,
        "errors": errors,
        "findings": args.out,
    }
    print(json.dumps(summary))
    if total > 0 and errors == total and passed == 0 and failed == 0:
        # Every case died in transport — nothing was exercised, so there is nothing for a
        # human to judge. That's a tool/environment failure (dead host, wrong --base-url),
        # not a parity finding.
        print(
            f"zb_replay: every case failed in transport against {args.base_url} — "
            "the replay target looks unreachable; nothing was exercised",
            file=sys.stderr,
        )
        return 1
    # 2 = ran correctly, found something needing judgment: a parity failure, and/or some
    # (but not all) cases erroring in transport — a vanished endpoint is itself a finding.
    # 1 is reserved for tool failure, including the fully-unreachable case handled above.
    return 2 if (failed or errors) else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="zb_replay.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser(
        "record", help="run requests against the OLD backend and record expectations"
    )
    rec.add_argument("--base-url", required=True)
    rec.add_argument("--requests", required=True)
    rec.add_argument("--out", default="capture.ndjson")
    rec.add_argument("--var", action="append")
    rec.add_argument("--volatile", action="append")
    rec.add_argument("--timeout", type=float, default=30.0)
    rec.set_defaults(fn=cmd_record)

    rep = sub.add_parser(
        "replay", help="replay a capture against the NEW backend and diff"
    )
    rep.add_argument("capture")
    rep.add_argument("--base-url", required=True)
    rep.add_argument("--out", default="findings.ndjson")
    rep.add_argument("--var", action="append")
    rep.add_argument("--timeout", type=float, default=30.0)
    rep.set_defaults(fn=cmd_replay)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except ReplayError as e:
        print(f"zb_replay: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
