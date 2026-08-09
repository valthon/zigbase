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
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

CAPTURE_VERSION = 1
DEFAULT_VOLATILE = ["id", "created", "updated", "token", "collectionId", "collectionName", "expand"]

# Sentinel for "this key is absent from `actual`", distinct from an actual value of `None`.
# `dict.get(k)` returns `None` both when the key holds `null` and when the key is missing —
# collapsing those would let a migration that drops a nullable field (e.g. `deletedAt`)
# silently pass replay, since `{}` would satisfy an expectation of `{"deletedAt": None}`.
_MISSING = object()


class ReplayError(Exception):
    """A tool-level problem: a malformed capture, an unresolvable placeholder, a dead host."""


MAX_SUBSTITUTION_PASSES = 10


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
        name = out[start + 2:end]
        if name not in variables:
            raise ReplayError(f"unresolved placeholder {{{{{name}}}}} — pass --var {name}=VALUE")
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
                out.append({"path": sub, "expected": v, "actual": None, "message": "missing key"})
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
                out.append({"path": sub, "expected": v, "actual": None, "message": "missing key"})
            else:
                out.extend(diff_subset(v, av, sub))
        return out
    if expected != actual:
        out.append({"path": path or ".", "expected": expected, "actual": actual})
    return out


def load_capture(path):
    """Read an NDJSON capture. Ids must be present and unique — findings key off them."""
    cases, seen = [], set()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise ReplayError(f"cannot read {path}: {e}") from e
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as e:
            raise ReplayError(f"{path}:{n}: not JSON: {e}") from e
        cid = case.get("id")
        if not cid:
            raise ReplayError(f"{path}:{n}: every case needs a unique \"id\"")
        if cid in seen:
            raise ReplayError(f"{path}:{n}: duplicate case id {cid!r}")
        if not case.get("method") or not case.get("path"):
            raise ReplayError(f"{path}:{n}: case {cid!r} needs \"method\" and \"path\"")
        seen.add(cid)
        cases.append(case)
    return cases


def send(base_url, case, variables, timeout):
    """Issue one case. Returns (status, parsed-body-or-raw-text)."""
    case = substitute(case, variables)
    url = base_url.rstrip("/") + case["path"]
    if case.get("query"):
        url += "?" + urllib.parse.urlencode(case["query"])
    data = None
    headers = dict(case.get("headers") or {})
    if case.get("body") is not None:
        data = json.dumps(case["body"]).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, method=case["method"], data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read().decode(errors="replace"), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(errors="replace"), e.code
    except OSError as e:
        raise ReplayError(f"{case['id']}: {url}: {e}") from e
    try:
        return status, json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return status, raw


def compare(case, status, body):
    expect = case.get("expect") or {}
    finding = {"id": case["id"], "result": "pass", "diff": []}
    if expect.get("status") is not None and expect["status"] != status:
        finding["status"] = {"expected": expect["status"], "actual": status}
        finding["result"] = "fail"
    if expect.get("bodySubset") is not None:
        d = diff_subset(expect["bodySubset"], body)
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


def cmd_record(args):
    variables = parse_vars(args.var)
    volatile = DEFAULT_VOLATILE + (args.volatile or [])
    cases = load_capture(args.requests)
    with open(args.out, "w", encoding="utf-8") as out:
        for case in cases:
            status, body = send(args.base_url, case, variables, args.timeout)
            case["expect"] = {"status": status, "bodySubset": strip_volatile(body, volatile)}
            out.write(json.dumps(case) + "\n")
    summary = {"zigbaseReplay": CAPTURE_VERSION, "mode": "record", "base_url": args.base_url,
               "recorded": len(cases), "capture": args.out}
    print(json.dumps(summary))
    return 0


def cmd_replay(args):
    variables = parse_vars(args.var)
    cases = load_capture(args.capture)
    passed = failed = errors = 0
    with open(args.out, "w", encoding="utf-8") as out:
        for case in cases:
            try:
                status, body = send(args.base_url, case, variables, args.timeout)
            except ReplayError as e:
                errors += 1
                out.write(json.dumps({"id": case["id"], "result": "error", "message": str(e)}) + "\n")
                continue
            finding = compare(case, status, body)
            if finding["result"] == "pass":
                passed += 1
            else:
                failed += 1
            out.write(json.dumps(finding) + "\n")
    total = len(cases)
    summary = {"zigbaseReplay": CAPTURE_VERSION, "mode": "replay", "base_url": args.base_url,
               "total": total, "passed": passed, "failed": failed, "errors": errors,
               "findings": args.out}
    print(json.dumps(summary))
    if total > 0 and errors == total and passed == 0 and failed == 0:
        # Every case died in transport — nothing was exercised, so there is nothing for a
        # human to judge. That's a tool/environment failure (dead host, wrong --base-url),
        # not a parity finding.
        print(f"zb_replay: every case failed in transport against {args.base_url} — "
              "the replay target looks unreachable; nothing was exercised", file=sys.stderr)
        return 1
    # 2 = ran correctly, found something needing judgment: a parity failure, and/or some
    # (but not all) cases erroring in transport — a vanished endpoint is itself a finding.
    # 1 is reserved for tool failure, including the fully-unreachable case handled above.
    return 2 if (failed or errors) else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="zb_replay.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser("record", help="run requests against the OLD backend and record expectations")
    rec.add_argument("--base-url", required=True)
    rec.add_argument("--requests", required=True)
    rec.add_argument("--out", default="capture.ndjson")
    rec.add_argument("--var", action="append")
    rec.add_argument("--volatile", action="append")
    rec.add_argument("--timeout", type=float, default=30.0)
    rec.set_defaults(fn=cmd_record)

    rep = sub.add_parser("replay", help="replay a capture against the NEW backend and diff")
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
