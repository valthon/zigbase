"""Real offline CLI comparisons and reproducible measurement-helper smoke."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import MagicMock
import urllib.error

import pytest


def document(binary):
    resources = json.loads(subprocess.check_output([binary, "resources"]))
    candidate = dict(id="small", workload="w", revision="r", environment="e",
                     measured_at_unix=100, throughput_rps=10, p95_ms=5,
                     peak_rss_bytes=1000, failed_requests=0, resources=resources)
    fast = {**candidate, "id": "fast", "throughput_rps": 20, "peak_rss_bytes": 2000}
    return dict(schema_version=1, workload="w", revision="r", environment="e",
                max_age_seconds=20, memory_budget_bytes=2000, p95_budget_ms=10,
                candidates=[candidate, fast])


def run(binary, tmp_path, value, now=110):
    path = tmp_path / "measurements.json"
    path.write_text(json.dumps(value))
    return subprocess.run([binary, "tune", "--input", str(path), "--as-of", str(now)],
                          env={**os.environ, "ZIGBASE_HTTP_PORT": "invalid",
                               "ZIGBASE_DATA_DIR": str(tmp_path / "untouched")},
                          capture_output=True, text=True)


def test_tuning_accepts_older_reports_without_realtime_connection_cap(binary, tmp_path):
    value = document(binary)
    for candidate in value["candidates"]:
        candidate["resources"].pop("realtime_connection_cap", None)
    result = run(binary, tmp_path, value)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["recommendation"] == "fast"
    for item in report["items"]:
        assert item["candidate"]["resources"]["realtime_connection_cap"] == 10000


def test_tuning_ranks_only_feasible_observations(binary, tmp_path):
    value = document(binary)
    result = run(binary, tmp_path, value)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["recommendation"] == "fast"
    value["memory_budget_bytes"] = 1000
    report = json.loads(run(binary, tmp_path, value).stdout)
    assert report["recommendation"] == "small"
    assert report["items"][1]["reason"] == "memory_budget"
    value["p95_budget_ms"] = 1
    assert json.loads(run(binary, tmp_path, value).stdout)["recommendation"] is None
    assert not (tmp_path / "untouched").exists()


def test_tuning_accepts_reports_without_memory_worker_fields(binary, tmp_path):
    value = document(binary)
    for candidate in value["candidates"]:
        candidate["resources"].pop("memory_job_workers", None)
    result = run(binary, tmp_path, value)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["recommendation"] == "fast"
    for item in report["items"]:
        assert item["candidate"]["resources"]["memory_job_workers"] is None


def test_tuning_accepts_saved_reports_without_envelope(binary, tmp_path):
    value = document(binary)
    for candidate in value["candidates"]:
        candidate["resources"].pop("envelope", None)
    result = run(binary, tmp_path, value)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["recommendation"] == "fast"
    assert report["items"][0]["candidate"]["resources"]["envelope"] is None


def test_tuning_accepts_reports_predating_all_additive_resource_fields(binary, tmp_path):
    value = document(binary)
    for candidate in value["candidates"]:
        for field in ("realtime_connection_cap", "memory_job_workers", "envelope"):
            candidate["resources"].pop(field, None)
    result = run(binary, tmp_path, value)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["recommendation"] == "fast"
    for item in report["items"]:
        resources = item["candidate"]["resources"]
        assert resources["realtime_connection_cap"] == 10000
        assert resources["memory_job_workers"] is None
        assert resources["envelope"] is None


@pytest.mark.parametrize("change,reason", [
    ({"failed_requests": 1}, "failed_requests"),
    ({"revision": "old"}, "context_mismatch"),
    ({"environment": "other-machine"}, "context_mismatch"),
    ({"workload": "different-route"}, "context_mismatch"),
    ({"measured_at_unix": 89}, "stale"),
    ({"measured_at_unix": 111}, "future_measurement"),
])
def test_tuning_excludes_unusable_samples(binary, tmp_path, change, reason):
    value = document(binary)
    value["candidates"][1].update(change)
    report = json.loads(run(binary, tmp_path, value).stdout)
    assert report["recommendation"] == "small"
    assert report["items"][1]["reason"] == reason


@pytest.mark.parametrize("field,bad", [("p95_ms", float("nan")), ("throughput_rps", float("inf")),
                                     ("throughput_rps", -1), ("peak_rss_bytes", 0)])
def test_tuning_rejects_invalid_metrics(binary, tmp_path, field, bad):
    value = document(binary)
    value["candidates"][0][field] = bad
    assert run(binary, tmp_path, value).returncode != 0


def test_tuning_rejects_bad_documents_and_limits(binary, tmp_path):
    for change in ({"schema_version": 2}, {"max_age_seconds": 0},
                   {"memory_budget_bytes": 0}, {"p95_budget_ms": float("inf")},
                   {"candidates": []}, {"unexpected": True}):
        value = document(binary)
        value.update(change)
        assert run(binary, tmp_path, value).returncode != 0
    value = document(binary)
    value["candidates"].append(copy.deepcopy(value["candidates"][0]))
    assert run(binary, tmp_path, value).returncode != 0
    path = tmp_path / "large.json"
    path.write_bytes(b" " * (1024 * 1024 + 1))
    assert subprocess.run([binary, "tune", "--input", str(path)], capture_output=True).returncode != 0
    assert subprocess.run([binary, "tune", "--input"], capture_output=True).returncode != 0
    assert "--as-of" in subprocess.check_output([binary, "tune", "--help"], text=True)


def test_measurement_helper_collects_real_health_observations(binary, tmp_path):
    if not Path("/proc/self/status").exists():
        pytest.skip("Linux RSS collector")
    tool = Path(__file__).resolve().parents[2] / "tools/tuning/measure.py"
    collected = subprocess.check_output([
        "python3", str(tool), "--candidate", f"stock={binary}", "--revision", "test",
        "--environment", "test-machine", "--requests", "20", "--concurrency", "2",
        "--memory-budget-bytes", "1073741824", "--p95-budget-ms", "10000",
    ], text=True, timeout=30)
    value = json.loads(collected)
    candidate = value["candidates"][0]
    assert candidate["throughput_rps"] > 0
    assert candidate["peak_rss_bytes"] > 0
    result = run(binary, tmp_path, value, candidate["measured_at_unix"])
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["recommendation"] == "stock"


@pytest.mark.parametrize("extra", [
    ["--revision", ""], ["--environment", "x" * 257],
    ["--revision", "é" * 129], ["--environment", "line\nbreak"],
    ["--candidate", "bad\x7fid=/missing-second-binary"],
    ["--candidate", "é" * 129 + "=/missing-second-binary"],
    ["--candidate", "first=/missing-second-binary"],
    ["--candidate", "missing-equals"],
    ["--memory-budget-bytes", str(2**64)],
])
def test_measurement_helper_validates_every_input_before_launch(tmp_path, extra):
    tool = Path(__file__).resolve().parents[2] / "tools/tuning/measure.py"
    # Resolving this first binary would fail before later validation. An argparse
    # diagnostic (not FileNotFoundError) proves all arguments precede measurement.
    missing = tmp_path / "must-not-launch"
    result = subprocess.run([
        "python3", str(tool), "--candidate", f"first={missing}",
        "--revision", "test", "--environment", "machine", "--requests", "1",
        "--memory-budget-bytes", "1024", "--p95-budget-ms", "1000", *extra,
    ], capture_output=True, text=True, timeout=5)
    assert result.returncode == 2
    assert "error:" in result.stderr
    assert "Traceback" not in result.stderr
    assert str(missing) not in result.stderr
    assert result.stdout == ""


def test_measurement_helper_preflights_later_binary_before_first_launch(tmp_path):
    tool = Path(__file__).resolve().parents[2] / "tools/tuning/measure.py"
    missing = tmp_path / "missing-second"
    # Python is executable but cannot satisfy `resources`; launching it before
    # validating the second path would produce a subprocess failure instead.
    result = subprocess.run([
        "python3", str(tool), "--candidate", f"first={sys.executable}",
        "--candidate", f"second={missing}", "--revision", "r", "--environment", "e",
        "--memory-budget-bytes", "1024", "--p95-budget-ms", "1000",
    ], capture_output=True, text=True, timeout=5)
    assert result.returncode == 2
    assert f"candidate binary must be an executable file: {missing}" in result.stderr
    assert "Traceback" not in result.stderr
    assert result.stdout == ""


def mock_measurement_startup(monkeypatch, responses):
    path = Path(__file__).resolve().parents[2] / "tools/tuning/measure.py"
    spec = importlib.util.spec_from_file_location("measure_startup_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module.subprocess, "check_output", MagicMock(return_value=b"{}"))
    process = MagicMock()
    process.poll.return_value = None
    monkeypatch.setattr(module.subprocess, "Popen", MagicMock(return_value=process))
    sock = MagicMock()
    sock.__enter__.return_value.getsockname.return_value = ("127.0.0.1", 12345)
    monkeypatch.setattr(module.socket, "socket", MagicMock(return_value=sock))
    opener = MagicMock()
    opener.open.side_effect = responses
    monkeypatch.setattr(module.urllib.request, "build_opener", MagicMock(return_value=opener))
    sleep = MagicMock()
    monkeypatch.setattr(module.time, "sleep", sleep)
    return module, opener, process, sleep


def health_response(body, status=200):
    response = MagicMock()
    response.__enter__.return_value = response
    response.read.return_value = body
    response.status = status
    return response


@pytest.mark.parametrize("response", [
    health_response(b"not-json"),
    health_response(b'{"status":"bad","backend":"sqlite"}'),
    health_response(b'{"status":"ok","backend":"postgres"}'),
    health_response(b'{"status":"ok","backend":"sqlite"}', status=503),
    urllib.error.HTTPError("http://localhost/api/health", 503, "Unavailable", {}, None),
])
def test_measurement_startup_fails_immediately_on_semantic_response(monkeypatch, response):
    module, opener, process, sleep = mock_measurement_startup(monkeypatch, [response])
    with pytest.raises((ValueError, urllib.error.HTTPError)):
        module.measure(sys.executable, "c", "r", "e", 1, 1)
    assert opener.open.call_count == 1
    sleep.assert_not_called()
    process.terminate.assert_called_once()
    process.wait.assert_called_once()


@pytest.mark.parametrize("connection_error", [
    urllib.error.URLError(ConnectionRefusedError()), ConnectionRefusedError(), TimeoutError(),
])
def test_measurement_startup_retries_connection_errors_only(monkeypatch, connection_error):
    module, opener, process, sleep = mock_measurement_startup(
        monkeypatch, [connection_error, health_response(b"not-json")])
    with pytest.raises(ValueError):
        module.measure(sys.executable, "c", "r", "e", 1, 1)
    assert opener.open.call_count == 2
    sleep.assert_called_once_with(0.05)
    process.terminate.assert_called_once()


@pytest.mark.parametrize("requests,concurrency,fail", [(17, 3, False), (2, 8, False), (17, 3, True)])
def test_measurement_keeps_pending_futures_bounded(monkeypatch, requests, concurrency, fail):
    module, _, _, _ = mock_measurement_startup(monkeypatch, [])
    class TrackedFuture(module.concurrent.futures.Future):
        def result(self, timeout=None):
            executor.outstanding -= 1
            return super().result(timeout)

    class Executor:
        outstanding = 0
        peak = 0
        submitted = 0
        shutdown_args = None

        def submit(self, request):
            self.submitted += 1
            self.outstanding += 1
            self.peak = max(self.peak, self.outstanding)
            future = TrackedFuture()
            try:
                future.set_result(request())
            except ValueError as error:
                future.set_exception(error)
            return future

        def shutdown(self, **kwargs):
            self.shutdown_args = kwargs

    executor = Executor()
    monkeypatch.setattr(module.concurrent.futures, "ThreadPoolExecutor", lambda **_: executor)
    calls = 0
    def request():
        nonlocal calls
        calls += 1
        if fail and calls == 2:
            raise ValueError("workload failed")
        return calls

    if fail:
        with pytest.raises(ValueError, match="workload failed"):
            module.run_requests(request, requests, concurrency)
        # All completed batch results are checked before refill: no fourth call.
        assert executor.submitted == concurrency
    else:
        assert sorted(module.run_requests(request, requests, concurrency)) == list(range(1, requests + 1))
        assert executor.submitted == requests
    assert executor.peak <= concurrency
    assert executor.shutdown_args == {"wait": True, "cancel_futures": True}


def test_measurement_failure_terminates_child_after_worker_cleanup(monkeypatch):
    good = health_response(b'{"status":"ok","backend":"sqlite"}')
    module, _, process, _ = mock_measurement_startup(monkeypatch, [good] * 11 + [health_response(b"bad-json"), good])
    with pytest.raises(ValueError):
        module.measure(sys.executable, "c", "r", "e", 20, 2)
    process.terminate.assert_called_once()
    process.wait.assert_called_once()


@pytest.mark.parametrize("status,diagnostic", [
    (FileNotFoundError("child exited"), "status disappeared"),
    ("Name: zigbase\n", "missing or invalid VmHWM"),
    ("VmHWM: invalid kB\n", "missing or invalid VmHWM"),
])
def test_measurement_rss_failure_is_explicit_and_cleans_up(monkeypatch, status, diagnostic):
    good = health_response(b'{"status":"ok","backend":"sqlite"}')
    module, _, process, _ = mock_measurement_startup(monkeypatch, [good] * 12)
    read = MagicMock(side_effect=status) if isinstance(status, Exception) else MagicMock(return_value=status)
    monkeypatch.setattr(module.Path, "read_text", read)
    with pytest.raises(RuntimeError, match=diagnostic):
        module.measure(sys.executable, "c", "r", "e", 1, 1)
    read.assert_called_once()
    process.terminate.assert_called_once()
    process.wait.assert_called_once()
