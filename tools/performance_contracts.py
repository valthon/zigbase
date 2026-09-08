#!/usr/bin/env python3
"""Offline, opt-in binary/allocation budgets; timing comparisons are advisory."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import sys

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_BINARY_BYTES = 256 * 1024 * 1024


class Invalid(ValueError):
    pass


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(text):
    return json.loads(text, object_pairs_hook=unique,
                      parse_constant=lambda value: fail(f"non-finite number: {value}"))


def fail(message):
    raise Invalid(message)


def keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(f"{label}: expected keys {sorted(expected)}")


def integer(value, label, minimum=0):
    if type(value) is not int or not minimum <= value <= 2**64 - 1:
        fail(f"{label}: expected unsigned 64-bit integer >= {minimum}")
    return value


def preflight(path, limit):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        fail(f"not a regular file: {path}")
    if info.st_size > limit:
        fail(f"input too large: {path}")


def read(path):
    preflight(path, MAX_INPUT_BYTES)
    with path.open("rb") as source:
        data = source.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        fail(f"input grew beyond limit: {path}")
    return data.decode("utf-8")


def digest(path, max_bytes=MAX_BINARY_BYTES):
    preflight(path, max_bytes)
    value = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        while chunk := source.read(min(1024 * 1024, max_bytes - total + 1)):
            total += len(chunk)
            if total > max_bytes:
                fail(f"input grew beyond limit: {path}")
            value.update(chunk)
    return value.hexdigest()


TOTAL = {"allocs", "bytes", "peak_live"}
EVENT = {"allocs_per_event", "bytes_per_event", "peak_live_bytes"}
TOTAL_FIELDS = TOTAL | {"name", "iterations", "ns_median", "ns_p95", "buckets"}
EVENT_FIELDS = EVENT | {"name", "iterations", "subscribers", "payload_bytes",
                        "ns_event_median", "ns_event_max", "ns_subscriber_median"}


def measurements(text):
    rows = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        row = decode(line)
        if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not row["name"]:
            fail("benchmark row needs a nonempty name")
        name = row["name"]
        keys(row, EVENT_FIELDS if name.startswith("realtime/") else TOTAL_FIELDS, name)
        for key, value in row.items():
            if key not in {"name", "buckets"}:
                integer(value, f"{name}.{key}", 1 if key in {"iterations", "subscribers", "payload_bytes"} else 0)
        if "buckets" in row:
            if not isinstance(row["buckets"], list) or len(row["buckets"]) != 5:
                fail(f"{name}: expected five allocation buckets")
            for value in row["buckets"]:
                integer(value, f"{name}.buckets")
            if sum(row["buckets"]) != row["allocs"] or row["ns_p95"] < row["ns_median"]:
                fail(f"{name}: inconsistent allocation buckets or timing quantiles")
        elif row["ns_event_max"] < row["ns_event_median"]:
            fail(f"{name}: inconsistent event timings")
        identity = (name, row["subscribers"], row["payload_bytes"]) if name.startswith("realtime/") else name
        if identity in rows:
            fail(f"duplicate benchmark: {identity}")
        rows[identity] = row
    if not rows:
        fail("empty benchmark input")
    return rows


def check(contract, binary, rows):
    keys(contract, {"schema_version", "build", "binary_max_bytes", "benchmarks"}, "contract")
    if type(contract["schema_version"]) is not int or contract["schema_version"] != 1:
        fail("unsupported contract schema_version")
    keys(contract["build"], {"target", "binary_optimize", "benchmark_optimize", "zig_version", "workload"}, "build")
    for key, value in contract["build"].items():
        if not isinstance(value, str) or not value.strip():
            fail(f"build.{key}: expected nonempty label")
    budget = integer(contract["binary_max_bytes"], "binary_max_bytes", 1)
    specs = contract["benchmarks"]
    if not isinstance(specs, dict) or not specs:
        fail("benchmarks: expected nonempty object")
    checks = [{"name": "binary", "metric": "bytes", "actual": binary.stat().st_size, "limit": budget}]
    timings = {}
    for name, spec in sorted(specs.items()):
        dimensions = {"iterations", "subscribers", "payload_bytes"} if name.startswith("realtime/") else {"iterations"}
        keys(spec, dimensions | {"max"}, name)
        iterations = integer(spec["iterations"], f"{name}.iterations", 1)
        for dimension in dimensions - {"iterations"}:
            integer(spec[dimension], f"{name}.{dimension}", 1)
        identity = (name, spec["subscribers"], spec["payload_bytes"]) if name.startswith("realtime/") else name
        if identity not in rows:
            fail(f"missing benchmark: {name}")
        row = rows[identity]
        if iterations != row["iterations"]:
            fail(f"{name}: iteration count changed; review workload and budgets")
        allowed = EVENT if name.startswith("realtime/") else TOTAL
        limits = spec["max"]
        if not isinstance(limits, dict) or not limits or not set(limits) <= allowed:
            fail(f"{name}: max must select allocation metrics from {sorted(allowed)}")
        for metric, limit in sorted(limits.items()):
            integer(limit, f"{name}.{metric}")
            checks.append({"name": name, "metric": metric, "actual": row[metric], "limit": limit})
        timings[name] = row["ns_event_median"] if name.startswith("realtime/") else row["ns_median"]
    for entry in checks:
        entry["passed"] = entry["actual"] <= entry["limit"]
    return checks, timings


def compare(report, baseline):
    # Baselines are reports from this exact contract/build, not arbitrary metric bags.
    keys(baseline, report.keys(), "baseline report")
    integer(baseline["schema_version"], "baseline schema_version", 1)
    for key in ("contract_sha256", "binary_sha256", "benchmarks_sha256"):
        value = baseline[key]
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            fail(f"invalid baseline {key}")
    for key in ("schema_version", "contract_sha256", "build"):
        if baseline[key] != report[key]:
            fail(f"incompatible baseline {key}")
    previous = baseline["checks"]
    if not isinstance(previous, list) or len(previous) != len(report["checks"]):
        fail("baseline checks differ")
    deltas = []
    for old, new in zip(previous, report["checks"]):
        keys(old, new.keys(), "baseline check")
        for key in ("name", "metric", "limit"):
            if old[key] != new[key]:
                fail(f"baseline check differs: {key}")
        integer(old["actual"], "baseline actual")
        if type(old["passed"]) is not bool or old["passed"] != (old["actual"] <= old["limit"]):
            fail("baseline check result inconsistent")
        deltas.append({"name": new["name"], "metric": new["metric"], "delta": new["actual"] - old["actual"]})
    keys(baseline["timing_ns_median"], report["timing_ns_median"].keys(), "baseline timings")
    timing = {}
    for name, value in report["timing_ns_median"].items():
        old = integer(baseline["timing_ns_median"][name], "baseline timing")
        timing[name] = {"delta_ns": value - old, "delta_percent": (value - old) * 100 / old if old else None}
    return {"allocation_and_size_deltas": deltas, "timing_advisory_only": timing}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--benchmarks", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args(argv)
    try:
        contract = decode(read(args.contract))
        checks, timings = check(contract, args.binary, measurements(read(args.benchmarks)))
        integer(args.binary.stat().st_size, "binary size", 1)
        binary_hash = digest(args.binary)
        report = {"schema_version": 1, "contract_sha256": digest(args.contract, MAX_INPUT_BYTES),
                  "build": contract["build"], "binary_sha256": binary_hash,
                  "benchmarks_sha256": digest(args.benchmarks, MAX_INPUT_BYTES), "checks": checks,
                  "timing_ns_median": timings, "comparison": None}
        if args.baseline:
            report["comparison"] = compare(report, decode(read(args.baseline)))
        print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
        return 0 if all(entry["passed"] for entry in checks) else 1
    except (Invalid, OSError, ValueError, TypeError, RecursionError) as exc:
        print(f"performance contracts: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
