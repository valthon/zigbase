"""The serve path must configure the memory pool separately from the scheduler."""
import contextlib
import json
import os
import subprocess
import time
import urllib.request

import pytest
from conftest import _free_port, _wait_reachable_or_fail


def test_live_memory_pool_uses_configured_workers(tmp_path):
    binary = os.environ.get("ZIGBASE_TEST_MEMORY_JOBS_BINARY")
    if not binary:
        pytest.skip("requires memory-jobs-fixture")
    report = json.loads(subprocess.check_output([binary, "resources"]))
    assert report["memory_job_workers"] == 1
    assert report["job_stack_bytes"] == 2 << 20
    assert report["envelope"]["memory_job_stack_bytes"] == 2 << 20
    assert report["envelope"]["scheduler_stack_bytes"] == 0
    assert report["job_workers"] == 8
    assert not report["scheduler_enabled"]
    port = _free_port()
    log_path = tmp_path / "server.log"
    with log_path.open("w+") as log:
        process = subprocess.Popen([binary, "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", str(tmp_path / "data")], env={**os.environ, "ZIGBASE_SERVE_BACKGROUND": "false"}, stdout=log, stderr=log)
        base = f"http://127.0.0.1:{port}/api/test-jobs"

        def call(path, method="GET"):
            with urllib.request.urlopen(urllib.request.Request(base + path, method=method), timeout=5) as response:
                return json.loads(response.read() or b"null")

        try:
            _wait_reachable_or_fail(process, port, log_path)
            assert call("/state") == {"entered": 0, "completed": 0}
            call("/enqueue", "POST")
            deadline = time.monotonic() + 5
            while call("/state")["entered"] == 0 and time.monotonic() < deadline:
                time.sleep(0.01)
            # Keep the gate closed long enough for any unintended extra worker
            # to enter; observing the first worker alone is not sufficient.
            deadline = time.monotonic() + 0.2
            while time.monotonic() < deadline:
                assert call("/state") == {"entered": 1, "completed": 0}
                time.sleep(0.01)
            assert call("/state") == {"entered": 1, "completed": 0}
            call("/release", "POST")
            deadline = time.monotonic() + 5
            while call("/state")["completed"] < 2 and time.monotonic() < deadline:
                time.sleep(0.01)
            assert call("/state") == {"entered": 2, "completed": 2}
        finally:
            if process.poll() is None:
                with contextlib.suppress(Exception):
                    call("/release", "POST")
                process.terminate()
                process.wait(timeout=10)
