"""Compiled resource inspection must not read secrets or open deployment state."""
import json
import os
import subprocess


def test_resources_is_read_only_and_secret_free(binary, tmp_path):
    data = tmp_path / "must-not-be-created"
    result = subprocess.run(
        [binary, "resources", "--json"],
        env={
            **os.environ,
            "ZIGBASE_DATA_DIR": str(data),
            "ZIGBASE_JWT_SECRET": "resource-report-secret-marker",
            # Invalid runtime values must not matter to compiled inspection.
            "ZIGBASE_HTTP_PORT": "not-a-port",
        },
        capture_output=True,
        text=True,
        check=True,
    )
    report = json.loads(result.stdout)
    assert report["schema_version"] == 1
    assert report["profile"] is None
    assert report["reader_pool_cap"] == 16
    assert report["realtime_connection_cap"] == 10000
    assert report["job_workers"] == 2
    assert report["job_stack_bytes"] == 1048576
    assert report["memory_job_workers"] == 4
    assert report["sqlite_cache_kib_per_connection"] == 1024
    assert "resource-report-secret-marker" not in result.stdout + result.stderr
    assert not data.exists()
