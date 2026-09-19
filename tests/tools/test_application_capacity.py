"""Semantic and live checks for the application workload; no timing thresholds."""
import importlib.util
import io
from contextlib import redirect_stderr
from types import SimpleNamespace
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/application_capacity.py"
SPEC = importlib.util.spec_from_file_location("application_capacity", SCRIPT)
CAPACITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPACITY)


class Capacity(unittest.TestCase):
    def setUp(self):
        self.tenant = {"account": "a", "project": "p", "tasks": ["t"]}
        self.record = {"id": "t", "account": "a", "project": "p", "title": "changed",
                       "expand": {"project": {"id": "p", "account": "a"}}}

    def test_semantic_success_requires_tenant_relation_and_written_value(self):
        CAPACITY.checked_task(self.record, self.tenant, "t", "changed", True)
        for field, value in [("account", "b"), ("project", "foreign"), ("id", "wrong"),
                             ("title", "not persisted"), ("expand", {}),
                             ("expand", {"project": {"id": "p", "account": "b"}})]:
            with self.subTest(field=field, value=value), self.assertRaises(CAPACITY.InvalidResponse):
                CAPACITY.checked_task({**self.record, field: value}, self.tenant, "t", "changed", True)

    def test_list_does_not_count_empty_duplicate_or_foreign_rows_as_work(self):
        CAPACITY.checked_list({"items": [self.record]}, self.tenant, 1)
        for rows in [[], [self.record, self.record], [{**self.record, "id": "unknown"}]]:
            with self.assertRaises(CAPACITY.InvalidResponse):
                CAPACITY.checked_list({"items": rows}, self.tenant, len(rows) or 1)

    def test_nearest_rank_handles_small_runs_without_interpolation(self):
        self.assertIsNone(CAPACITY.distribution([]))
        self.assertEqual(CAPACITY.distribution([9]), dict(p50=9, p95=9, p99=9, max=9))
        self.assertEqual(CAPACITY.distribution(list(range(100, 0, -1))),
                         dict(p50=50, p95=95, p99=99, max=100))

    def test_environment_cannot_retarget_production_or_detach_server(self):
        with patch.dict(os.environ, {"ZIGBASE_DB_URL": "postgres://production",
                                     "ZIGBASE_SERVE_BACKGROUND": "1", "ZIGBASE_SMTP_PASSWORD": "secret"}):
            env = CAPACITY.clean_environment()
        self.assertNotIn("ZIGBASE_DB_URL", env)
        self.assertNotIn("ZIGBASE_SMTP_PASSWORD", env)
        self.assertEqual(env["ZIGBASE_SERVE_BACKGROUND"], "0")

    def test_limits_reject_unbounded_or_conflicting_workloads(self):
        for flag, value in [("--seconds", "0"), ("--seconds", "301"), ("--tasks", "1001"),
                            ("--tenants", "1"), ("--concurrency", "65"),
                            ("--max-requests", "200001"), ("--warmup", "31")]:
            with self.subTest(flag=flag), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                CAPACITY.arguments(["--binary", "/unused", flag, value])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            CAPACITY.arguments(["--binary", "/unused", "--tasks", "1", "--concurrency", "3"])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            CAPACITY.arguments(["--binary", "/unused", "--max-requests", "3"])

    def test_http_success_with_invalid_work_is_counted_as_failure(self):
        tenant = {**self.tenant, "token": "private-token"}
        args = SimpleNamespace(concurrency=1, tasks=1)
        with patch.object(CAPACITY, "process_usage", return_value=None), \
             patch.object(CAPACITY.Client, "call", return_value={}):
            report = CAPACITY.workload("http://unused", [tenant], args, 1, 3, 1, "test")
        self.assertEqual(report["successful_requests"], 0)
        self.assertEqual(report["attempts"], 3)
        self.assertEqual(sum(report["errors"].values()), 3)
        self.assertEqual(report["successful_requests_per_second"], 0)
        self.assertNotIn("private-token", json.dumps(report))

    def test_echoed_but_unpersisted_write_fails_final_check(self):
        tenant = {**self.tenant, "token": "token"}
        args = SimpleNamespace(concurrency=1, tasks=1)
        echoed = {**self.record, "title": "test-worker-0-revision-1"}
        responses = [{"items": [self.record]}, echoed, self.record, self.record]
        with patch.object(CAPACITY, "process_usage", return_value=None), \
             patch.object(CAPACITY.Client, "call", side_effect=responses), \
             self.assertRaisesRegex(CAPACITY.InvalidResponse, "write_not_observed"):
            CAPACITY.workload("http://unused", [tenant], args, 1, 3, 1, "test")

    @unittest.skipUnless(os.environ.get("ZIGBASE_TEST_CAPACITY_BINARY"), "set ZIGBASE_TEST_CAPACITY_BINARY for live app")
    def test_real_tenant_workload_and_provenance(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--binary", os.environ["ZIGBASE_TEST_CAPACITY_BINARY"],
                                 "--tasks", "4", "--seconds", "30", "--warmup", "30", "--max-requests", "24"],
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["passed"])
        self.assertEqual(report["isolation_before_and_after"], "passed")
        self.assertEqual(report["measurement"]["attempts"], 24)
        self.assertEqual(report["measurement"]["successful_requests"], 24)
        self.assertEqual(report["measurement"]["errors"], {})
        self.assertEqual(report["warmup"]["attempts"], 24)
        for row in report["measurement"]["latency_ms_including_failures"].values():
            self.assertEqual(row["count"], 8)
        self.assertEqual(len(report["binary"]["sha256"]), 64)
        self.assertEqual(report["binary"]["resources"]["schema_version"], 1)
        if sys.platform == "linux":
            self.assertGreater(report["measurement"]["server"]["peak_sampled_rss_bytes"], 0)
        self.assertTrue(any(row[0] == "capacity_tasks_account_id" for row in report["dataset"]["indexes"]))


if __name__ == "__main__":
    unittest.main()
