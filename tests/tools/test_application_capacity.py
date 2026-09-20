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
import threading
import sqlite3
import tempfile
from collections import Counter
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

    def test_workbench_capture_requires_enabled_current_contract(self):
        with patch.object(CAPACITY.Client, "call", side_effect=CAPACITY.InvalidResponse("http_404_expected_200")):
            with self.assertRaisesRegex(CAPACITY.InvalidResponse, "workbench_not_enabled"):
                CAPACITY.workbench_snapshot(CAPACITY.Client("http://unused"))
        with patch.object(CAPACITY.Client, "call", return_value={"routes": []}):
            with self.assertRaisesRegex(CAPACITY.InvalidResponse, "unsupported_workbench_report"):
                CAPACITY.workbench_snapshot(CAPACITY.Client("http://unused"))

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
                            ("--max-requests", "200001"), ("--warmup", "31"),
                            ("--stress-concurrency", "1"), ("--drain-seconds", "61"),
                            ("--recovery-seconds", "301")]:
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

    def test_mixed_drain_rejects_missing_foreign_or_duplicate_delivery_and_unfinished_jobs(self):
        observer = SimpleNamespace(lock=threading.Lock(), events={"revision": ("t", 2000000)}, errors=Counter())
        updates = [("t", "revision", 1000000, "a")]
        with patch.object(CAPACITY, "queue_counts", return_value={"done": 4}), \
             patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "revision", "done"): 1})):
            result = CAPACITY.drain_mixed([observer], updates, Path("/unused"), 3, 1)
        self.assertTrue(result["passed"])
        self.assertEqual(result["realtime"]["update_start_to_delivery_ms"]["p99"], 1)
        for events, errors, counts in [({}, {}, {"done": 4}),
                                      ({"revision": ("other", 2000000)}, {}, {"done": 4}),
                                      ({"foreign": ("t", 2000000)}, {}, {"done": 4}),
                                      ({"revision": ("t", 2000000)}, {"duplicate_sse_event": 1}, {"done": 4}),
                                      ({"revision": ("t", 2000000)}, {}, {"done": 3, "pending": 1}),
                                      ({"revision": ("t", 2000000)}, {}, {"done": 4, "failed": 1})]:
            observer.events, observer.errors = events, Counter(errors)
            with patch.object(CAPACITY, "queue_counts", return_value=counts), \
                 patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "revision", "done"): 1})):
                self.assertFalse(CAPACITY.drain_mixed([observer], updates, Path("/unused"), 3, 1)["passed"])

    def test_wrong_job_kind_cannot_satisfy_digest_identity(self):
        observer = SimpleNamespace(lock=threading.Lock(), events={"test-worker-0": ("t", 2)}, errors=Counter())
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            with sqlite3.connect(data / "data.db") as db:
                db.execute("CREATE TABLE _queue_jobs (queue,kind,payload,status)")
                db.execute("INSERT INTO _queue_jobs VALUES (?,?,?,?)",
                           ("capacity", "other", json.dumps({"account": "a", "title": "test-worker-0"}), "done"))
            result = CAPACITY.drain_mixed([observer], [("t", "test-worker-0", 1, "a")], data, 0, 1)
        self.assertTrue(result["realtime"]["settled"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["jobs"]["missing_jobs"], 1)
        self.assertEqual(result["jobs"]["unexpected_jobs"], 1)

    def test_settling_observes_late_duplicate_and_unexpected_events(self):
        for late in ("duplicate", "unexpected", "none"):
            observer = SimpleNamespace(lock=threading.Lock(), events={"revision": ("t", 2)}, errors=Counter())
            clock = [0.0]
            def advance(seconds):
                clock[0] += seconds
                if clock[0] >= .1:
                    if late == "duplicate":
                        observer.errors["duplicate_sse_event"] = 1
                    elif late == "unexpected":
                        observer.events["unexpected"] = ("t", 3)
            with self.subTest(late=late), \
                 patch.object(CAPACITY.time, "monotonic", side_effect=lambda: clock[0]), \
                 patch.object(CAPACITY.time, "sleep", side_effect=advance), \
                 patch.object(CAPACITY, "queue_counts", return_value={"done": 1}), \
                 patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "revision", "done"): 1})):
                result = CAPACITY.drain_mixed([observer], [("t", "revision", 1, "a")], Path("/unused"), 0, 1)
            self.assertEqual(result["passed"], late == "none")
            self.assertTrue(result["realtime"]["settled"])

    def test_settling_includes_events_received_during_queue_poll(self):
        observer = SimpleNamespace(lock=threading.Lock(), events={"revision": ("t", 2)}, errors=Counter())
        polls = [0]
        def counts(_):
            polls[0] += 1
            if polls[0] == 2:
                observer.errors["duplicate_sse_event"] = 1
            return {"done": 1}
        with patch.object(CAPACITY.time, "monotonic", side_effect=[0, 0, .3, .3]), \
             patch.object(CAPACITY.time, "sleep"), \
             patch.object(CAPACITY, "queue_counts", side_effect=counts), \
             patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "revision", "done"): 1})):
            result = CAPACITY.drain_mixed([observer], [("t", "revision", 1, "a")], Path("/unused"), 0, 1)
        self.assertTrue(result["realtime"]["settled"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["realtime"]["errors"], {"duplicate_sse_event": 1})

    def test_completion_near_deadline_cannot_skip_settling(self):
        observer = SimpleNamespace(lock=threading.Lock(), events={"revision": ("t", 2)}, errors=Counter())
        # Completion first observed at .76; a slow poll returns at 1.02. Although
        # .26 seconds elapsed, the required window extends past the 1s deadline.
        with patch.object(CAPACITY.time, "monotonic", side_effect=[0, .76, 1.02, 1.02]), \
             patch.object(CAPACITY.time, "sleep"), \
             patch.object(CAPACITY, "queue_counts", return_value={"done": 1}), \
             patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "revision", "done"): 1})):
            result = CAPACITY.drain_mixed([observer], [("t", "revision", 1, "a")], Path("/unused"), 0, 1)
        self.assertFalse(result["passed"])
        self.assertFalse(result["realtime"]["settled"])

    def test_realtime_observer_rejects_cross_tenant_record(self):
        observer = object.__new__(CAPACITY.RealtimeObserver)
        observer.tenant = self.tenant
        observer.stopping, observer.lock = threading.Event(), threading.Lock()
        observer.events, observer.errors, observer.limit = {}, Counter(), 10
        observer.read_frame = lambda: {"type": "event", "topic": "tasks", "action": "update",
                                       "record": {**self.record, "account": "foreign"}}
        observer.read_events()
        self.assertEqual(observer.errors, {"wrong_task_account": 1})
        self.assertEqual(observer.events, {})

    def test_equal_job_count_with_wrong_revision_fails(self):
        observer = SimpleNamespace(lock=threading.Lock(), events={"revision": ("t", 2000000)}, errors=Counter())
        with patch.object(CAPACITY, "queue_counts", return_value={"done": 1}), \
             patch.object(CAPACITY, "queue_payloads", return_value=Counter({("digest", "a", "other-revision", "done"): 1})):
            result = CAPACITY.drain_mixed([observer], [("t", "revision", 1000000, "a")], Path("/unused"), 0, 1)
        self.assertFalse(result["passed"])
        self.assertEqual(result["jobs"]["missing_jobs"], 1)
        self.assertEqual(result["jobs"]["unexpected_jobs"], 1)

    def test_malformed_idle_sse_records_sticky_error(self):
        for frame in (None, [], "unexpected"):
            observer = object.__new__(CAPACITY.RealtimeObserver)
            observer.stopping, observer.lock = threading.Event(), threading.Lock()
            observer.events, observer.errors = {}, Counter()
            observer.read_frame = lambda: frame
            observer.read_events()
            observer.reset()
            self.assertEqual(observer.errors, {"unexpected_sse_frame": 1})
            with patch.object(CAPACITY, "queue_counts", return_value={}), \
                 patch.object(CAPACITY, "queue_payloads", return_value=Counter()):
                self.assertFalse(CAPACITY.drain_mixed([observer], [], Path("/unused"), 0, 0)["passed"])

    @unittest.skipUnless(os.environ.get("ZIGBASE_TEST_CAPACITY_BINARY"), "set ZIGBASE_TEST_CAPACITY_BINARY for live app")
    def test_real_tenant_workload_and_provenance(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--binary", os.environ["ZIGBASE_TEST_CAPACITY_BINARY"],
                                 "--tasks", "4", "--seconds", "30", "--warmup", "30", "--max-requests", "24", "--recovery-seconds", "1"],
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["passed"])
        self.assertEqual(report["schema_version"], 2)
        for phase in ("warmup", "measurement", "stress", "recovery"):
            self.assertTrue(report[phase]["drain"]["passed"], report[phase])
            self.assertEqual(report[phase]["drain"]["realtime"]["expected_events"], 8)
            self.assertEqual(report[phase]["drain"]["realtime"]["received_events"], 8)
            self.assertEqual(report[phase]["drain"]["jobs"]["completed"], 8)
        self.assertEqual(report["stress"]["concurrency"], 8)
        self.assertEqual(report["recovery"]["concurrency"], 4)
        self.assertFalse(report["pressure"]["rejections_observed"])
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


    @unittest.skipUnless(os.environ.get("ZIGBASE_TEST_CAPACITY_WORKBENCH_BINARY"), "set instrumented capacity binary")
    def test_live_workbench_snapshots_include_http_and_durable_attempts(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--binary",
                                 os.environ["ZIGBASE_TEST_CAPACITY_WORKBENCH_BINARY"], "--workbench",
                                 "--tasks", "4", "--concurrency", "2", "--stress-concurrency", "4",
                                 "--seconds", "2", "--warmup", "0", "--recovery-seconds", "2",
                                 "--max-requests", "24"], text=True, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["workbench"]["enabled"])
        completed = 0
        for phase in ["measurement", "stress", "recovery"]:
            snapshot = report[phase]["workbench_after"]
            jobs = [row for row in snapshot["jobs"] if row["jobName"] == "digest"]
            self.assertEqual(len(jobs), 1)
            self.assertEqual(jobs[0]["attribution"], "durable_job")
            self.assertEqual(jobs[0]["handlerErrors"], 0)
            completed += report[phase]["drain"]["jobs"]["completed"]
            self.assertEqual(jobs[0]["completedScopes"], completed)
            self.assertGreater(sum(row["responseStatusClasses"]["success"] for row in snapshot["routes"]), 0)
            self.assertTrue(any(wait["acquisitions"] > 0 for row in snapshot["routes"]
                                for wait in row["poolWaits"] if wait["role"] == "writer"))


if __name__ == "__main__":
    unittest.main()
