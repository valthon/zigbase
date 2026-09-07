"""Agent discovery is deterministic and must not touch deployment state."""
import json
import os
import subprocess


def test_capabilities_is_offline_and_explicit(binary, tmp_path):
    data = tmp_path / "must-not-be-created"
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data),
           "ZIGBASE_DB_URL": "postgres://invalid.invalid/unreachable",
           "ZIGBASE_JWT_SECRET": "DO-NOT-PRINT-THIS-SECRET"}
    result = subprocess.run([binary, "capabilities", "--json"], env=env,
                            capture_output=True, text=True, check=True)
    manifest = json.loads(result.stdout)
    assert manifest["protocol_version"] == 1
    operations = {op["id"]: op for op in manifest["operations"]}
    assert operations["http-contract"]["effect"] == "read_only"
    assert operations["migration-status"]["effect"] == "may_write"
    assert operations["diagnostics"]["output"] == "ndjson"
    assert "DO-NOT-PRINT" not in result.stdout + result.stderr
    assert not data.exists()
    again = subprocess.run([binary, "capabilities"], env=env,
                           capture_output=True, text=True, check=True)
    assert again.stdout == result.stdout


def test_capabilities_rejects_execution_arguments(binary):
    result = subprocess.run([binary, "capabilities", "--execute"],
                            capture_output=True, text=True)
    assert result.returncode != 0


def test_capabilities_has_dedicated_help(binary, tmp_path):
    data = tmp_path / "must-not-be-created"
    for flag in ("--help", "-h"):
        result = subprocess.run(
            [binary, "capabilities", flag],
            env={**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": "invalid"},
            capture_output=True, text=True, check=True,
        )
        assert "zigbase capabilities [--json]" in result.stdout
        assert "JSON is" in result.stdout
        assert "Does not execute catalog operations" in result.stdout
        assert "-Ddev-tools=false" in result.stdout
        assert "zigbase serve" not in result.stdout
        assert not data.exists()
