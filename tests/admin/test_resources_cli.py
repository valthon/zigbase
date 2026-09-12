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
            "ZIGBASE_MAX_UPLOAD_SIZE": "not-a-size",
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
    envelope = report["envelope"]
    assert envelope["basis"] == "compiled_configuration_not_rss"
    assert envelope["http_admission_max_requests"] is None
    assert envelope["http_body_limit_source"] == "runtime_ZIGBASE_MAX_UPLOAD_SIZE"
    assert envelope["retained_reader_cap"] == 16
    assert envelope["sqlite_cache_target_bytes_per_connection"] == 1024 * 1024
    assert envelope["sqlite_writer_and_retained_readers_cache_target_bytes"] == 17 * 1024 * 1024
    assert envelope["scheduler_stack_bytes"] == 0
    assert envelope["memory_job_stack_bytes"] == 4 * 1048576
    assert "resumable_metadata_and_storage" in envelope["exclusions"]
    assert "resource-report-secret-marker" not in result.stdout + result.stderr
    assert not data.exists()
