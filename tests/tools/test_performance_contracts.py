"""Exercise the public CLI, including generated report replay and corrupt inputs."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/performance_contracts.py"
SPEC = importlib.util.spec_from_file_location("performance_contracts", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.contract = json.loads((ROOT / "bench/contracts/release-small-linux.json").read_text())
        self.contract["benchmarks"] = {"records/findById-json": self.contract["benchmarks"]["records/findById-json"]}
        self.row = {"name": "records/findById-json", "iterations": 2000, "ns_median": 1907,
                    "ns_p95": 1960, "allocs": 38000, "bytes": 3214000, "peak_live": 1028,
                    "buckets": [26000, 10000, 2000, 0, 0]}
        (self.root / "app").write_bytes(b"generated application artifact")

    def run_cli(self, rows=None, baseline=None, raw=None):
        (self.root / "contract.json").write_text(json.dumps(self.contract))
        (self.root / "bench.jsonl").write_text(raw if raw is not None else "\n".join(json.dumps(row) for row in (rows or [self.row])))
        args = [sys.executable, str(SCRIPT), "--contract", str(self.root / "contract.json"),
                "--binary", str(self.root / "app"), "--benchmarks", str(self.root / "bench.jsonl")]
        if baseline is not None:
            (self.root / "baseline.json").write_text(json.dumps(baseline))
            args += ["--baseline", str(self.root / "baseline.json")]
        return subprocess.run(args, text=True, capture_output=True)

    def test_generated_report_and_comparison(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["checks"][0]["actual"], 30)
        self.assertEqual(len(report["binary_sha256"]), 64)
        # A huge timing change is advisory, not a performance gate.
        self.row["ns_median"] *= 100
        self.row["ns_p95"] *= 100
        result = self.run_cli(baseline=report)
        self.assertEqual(result.returncode, 0, result.stderr)
        comparison = json.loads(result.stdout)["comparison"]
        self.assertEqual(comparison["timing_advisory_only"][self.row["name"]]["delta_percent"], 9900)

    def test_budget_failures_are_machine_readable(self):
        self.contract["binary_max_bytes"] = 1
        self.contract["benchmarks"][self.row["name"]]["max"]["allocs"] = 1
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sum(not row["passed"] for row in json.loads(result.stdout)["checks"]), 2)

    def test_missing_duplicate_and_malformed_metrics_fail_closed(self):
        variants = [{key: value for key, value in self.row.items() if key != "allocs"}]
        for key, value in [("bytes", -1), ("allocs", True), ("iterations", 0),
                           ("iterations", 2001), ("peak_live", 1.5), ("ns_p95", 0),
                           ("buckets", [0] * 5), ("name", "renamed")]:
            variants.append({**self.row, key: value})
        for row in variants:
            with self.subTest(row=row):
                result = self.run_cli(rows=[row])
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(result.stdout, "")
        for raw in ("", "not json", '{"name":"a","name":"b"}', '{"bytes":NaN}'):
            self.assertEqual(self.run_cli(raw=raw).returncode, 2)
        self.assertEqual(self.run_cli(rows=[self.row, self.row]).returncode, 2)

    def test_contract_typos_and_noninteger_limits_fail(self):
        self.contract["benchmarks"][self.row["name"]]["max"] = {"ns_median": 2000}
        self.assertEqual(self.run_cli().returncode, 2)
        self.contract["benchmarks"][self.row["name"]]["max"] = {"bytes": False}
        self.assertEqual(self.run_cli().returncode, 2)

    def test_invalid_baseline_is_not_silently_compared(self):
        report = json.loads(self.run_cli().stdout)
        for key, value in [("schema_version", True), ("contract_sha256", "other"),
                           ("timing_ns_median", {}), ("checks", [])]:
            with self.subTest(key=key):
                self.assertEqual(self.run_cli(baseline={**report, key: value}).returncode, 2)
        bad = copy.deepcopy(report)
        bad["checks"][0]["actual"] = "30"
        self.assertEqual(self.run_cli(baseline=bad).returncode, 2)

    def test_missing_or_empty_binary_fails(self):
        (self.root / "app").unlink()
        self.assertEqual(self.run_cli().returncode, 2)
        (self.root / "app").touch()
        self.assertEqual(self.run_cli().returncode, 2)

    def test_sparse_oversized_artifacts_are_rejected_before_open(self):
        path = self.root / "large"
        for limit, operation in [(CHECKER.MAX_BINARY_BYTES, CHECKER.digest),
                                 (CHECKER.MAX_INPUT_BYTES, CHECKER.read),
                                 (CHECKER.MAX_INPUT_BYTES, lambda p: CHECKER.digest(p, CHECKER.MAX_INPUT_BYTES))]:
            with path.open("wb") as output:
                output.truncate(limit + 1)
            with patch.object(Path, "open", side_effect=AssertionError("oversized input was opened")):
                with self.assertRaisesRegex(CHECKER.Invalid, "input too large"):
                    operation(path)
        with (self.root / "app").open("wb") as output:
            output.truncate(CHECKER.MAX_BINARY_BYTES + 1)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_read_and_hash_cap_growth_after_preflight(self):
        path = self.root / "growing"
        small_stat = SimpleNamespace(st_mode=stat.S_IFREG, st_size=1)
        with patch.object(Path, "stat", return_value=small_stat):
            with patch.object(Path, "open", return_value=io.BytesIO(b"123456789")):
                with self.assertRaisesRegex(CHECKER.Invalid, "grew beyond limit"):
                    CHECKER.digest(path, 8)
            with patch.object(CHECKER, "MAX_INPUT_BYTES", 8):
                with patch.object(Path, "open", return_value=io.BytesIO(b"123456789")):
                    with self.assertRaisesRegex(CHECKER.Invalid, "grew beyond limit"):
                        CHECKER.read(path)

    def test_realtime_dimensions_and_units(self):
        self.contract["benchmarks"] = {"realtime/public": {"iterations": 20, "subscribers": 10,
                                                            "payload_bytes": 1024, "max": {"allocs_per_event": 10}}}
        self.row = {"name": "realtime/public", "iterations": 20, "subscribers": 10, "payload_bytes": 1024,
                    "ns_event_median": 100, "ns_event_max": 200, "ns_subscriber_median": 10,
                    "allocs_per_event": 10, "bytes_per_event": 2560, "peak_live_bytes": 256}
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.run_cli(rows=[self.row, {**self.row, "subscribers": 20}]).returncode, 0)
        self.assertEqual(self.run_cli(rows=[self.row, self.row]).returncode, 2)
        self.row["subscribers"] = 20
        self.assertEqual(self.run_cli().returncode, 2)


if __name__ == "__main__":
    unittest.main()
