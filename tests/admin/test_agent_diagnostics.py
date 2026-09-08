"""Real discovery -> argument construction and structured doctor adapter."""
import json
import os
import subprocess

import pytest


def run(binary, *args, env=None):
    clean = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    return subprocess.run([binary, *args], env={**clean, **(env or {})},
                          capture_output=True, text=True, timeout=15)


def test_catalog_separates_required_inputs(binary, tmp_path):
    result = run(binary, "capabilities",
                 env={"ZIGBASE_HTTP_PORT": "invalid", "ZIGBASE_DATA_DIR": str(tmp_path / "absent")})
    manifest = json.loads(result.stdout)
    assert result.returncode == 0
    assert manifest["protocol_version"] == 1
    operations = {op["id"]: op for op in manifest["operations"]}
    diagnostics = operations["diagnostics"]
    assert diagnostics["effect"] == "may_write"
    report = json.loads(run(binary, *diagnostics["argv"], "--data-dir", str(tmp_path)).stdout)
    assert report["scope"] == "development-diagnostics"
    tune, = manifest["input_operations"]
    assert "argv" not in tune
    assert tune["inputs"][0]["max_bytes"] == 1024 * 1024
    assert not (tmp_path / "absent").exists()
    # Use discovered flags, not a copied invocation or placeholder expansion.
    contract = tune["input_contract"]
    def scalar(field):
        if "constant" in field:
            return field["constant"]
        if field["type"] == "string":
            return "sample"
        if "minimum_decimal" in field:
            return int(field["minimum_decimal"])
        return field.get("minimum", field.get("exclusive_minimum", 0) + 1)
    candidate = {name: scalar(field) for name, field in contract["candidate_fields"].items()
                 if name != "resources"}
    candidate["resources"] = json.loads(run(binary, *contract["candidate_fields"]["resources"]["capture_argv"]).stdout)
    value = {name: scalar(field) for name, field in contract["fields"].items() if name != "candidates"}
    value["candidates"] = [candidate]
    path = tmp_path / "observations with spaces.json"
    path.write_text(json.dumps(value))
    result = run(binary, *tune["argv_prefix"], tune["inputs"][0]["flag"], str(path),
                 tune["inputs"][1]["flag"], "0")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["recommendation"] == "sample"


@pytest.mark.parametrize("args", [("--bad",), ("--data-dir",), ("--data-dir", ""),
                                  ("--data-dir", "--production"), ("--data-dir", "--json"),
                                  ("--data-dir", "--help"), ("--data-dir", "-h"),
                                  ("--data-dir", "--unknown"),
                                  ("--data-dir", "x", "--data-dir", "y")])
def test_argument_errors_are_one_json_document(binary, args):
    result = run(binary, "diagnostics", *args)
    report = json.loads(result.stdout)
    assert result.returncode == report["exit_code"] == 1
    assert report["failure"]["code"] == "invalid_arguments"
    assert report["failure"]["phase"] == "arguments"


def test_descriptor_integer_bounds_and_byte_ranges(binary, tmp_path):
    manifest = json.loads(run(binary, "capabilities").stdout)
    tune, = manifest["input_operations"]
    timestamp = tune["inputs"][1]
    assert timestamp["minimum_decimal"] == "0"
    assert timestamp["maximum_decimal"] == "9223372036854775807"
    contract = tune["input_contract"]
    assert contract["fields"]["memory_budget_bytes"]["maximum_decimal"] == "18446744073709551615"
    ranges = contract["fields"]["workload"]["forbidden_byte_ranges"]
    assert ranges == [{"minimum": 0, "maximum": 31}, {"minimum": 127, "maximum": 127}]
    resources = json.loads(run(binary, "resources").stdout)
    candidate = {"id": "sample", "workload": "sample", "revision": "sample", "environment": "sample",
                 "measured_at_unix": 0, "throughput_rps": 1, "p95_ms": 1,
                 "peak_rss_bytes": 1, "failed_requests": 0, "resources": resources}
    value = {"schema_version": 1, "workload": "sample", "revision": "sample", "environment": "sample",
             "max_age_seconds": 1, "memory_budget_bytes": 1, "p95_budget_ms": 1, "candidates": [candidate]}
    path = tmp_path / "inputs.json"
    path.write_text(json.dumps(value))
    args = [*tune["argv_prefix"], "--input", str(path), timestamp["flag"]]
    # The largest advertised timestamp parses; the next integer is a CLI error.
    result = run(binary, *args, timestamp["maximum_decimal"])
    assert json.loads(result.stdout)["schema_version"] == 1
    rejected = run(binary, *args, str(int(timestamp["maximum_decimal"]) + 1))
    assert rejected.returncode == 1 and not rejected.stdout
    assert "BadValue" in rejected.stderr
    for byte in range(128):
        forbidden = any(item["minimum"] <= byte <= item["maximum"] for item in ranges)
        value["workload"] = candidate["workload"] = "label" + chr(byte)
        path.write_text(json.dumps(value))
        result = run(binary, *args, "0")
        assert (result.returncode != 0) == forbidden, (byte, result.stdout, result.stderr)


@pytest.mark.parametrize("version", ["1", "2"])
def test_capabilities_rejects_removed_protocol_selector(binary, version):
    assert run(binary, "capabilities", "--protocol-version", version).returncode == 1


def test_configuration_errors_omit_supplied_value(binary, tmp_path):
    result = run(binary, "diagnostics", env={"ZIGBASE_HTTP_PORT": "secret-do-not-print",
                                             "ZIGBASE_DATA_DIR": str(tmp_path / "absent")})
    report = json.loads(result.stdout)
    assert result.returncode == 1
    assert report["failure"] == {"phase": "configuration", "code": "invalid_environment",
                                  "subject": "ZIGBASE_HTTP_PORT", "expected": "u16 (decimal integer)"}
    assert "secret-do-not-print" not in result.stdout + result.stderr
    assert not (tmp_path / "absent").exists()


def test_adapter_matches_doctor_findings_and_exit(binary, tmp_path):
    for flags in ([], ["--production"]):
        args = [*flags, "--data-dir", str(tmp_path)]
        doctor = run(binary, "doctor", "--json", *args)
        adapter = run(binary, "diagnostics", *args)
        report = json.loads(adapter.stdout)
        lines = [json.loads(line) for line in doctor.stdout.splitlines()]
        assert report["status"] == "complete"
        assert report["protocol_version"] == 1
        assert report["findings"] == lines[:-1]
        assert report["summary"] == lines[-1]
        assert adapter.returncode == doctor.returncode == report["exit_code"]


def test_diagnostics_help_is_explicit(binary):
    result = run(binary, "diagnostics", "--help")
    assert result.returncode == 0
    assert "migration ledger" in result.stdout
    assert "-Ddev-tools=true" in result.stdout


@pytest.mark.parametrize("mode", ["success", "arguments", "configuration", "capabilities"])
def test_json_respects_redirected_stdout_offset(binary, tmp_path, mode):
    args = ["diagnostics", "--data-dir", str(tmp_path / "data")]
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    if mode == "arguments":
        args = ["diagnostics", "--bad"]
    elif mode == "configuration":
        env["ZIGBASE_HTTP_PORT"] = "invalid"
    elif mode == "capabilities":
        args = ["capabilities"]
    prefix = b"existing output must remain\n"
    with (tmp_path / "stdout").open("w+b") as output:
        output.write(prefix)
        output.flush()
        output.seek(len(prefix))
        result = subprocess.run([binary, *args], env=env, stdout=output,
                                stderr=subprocess.PIPE, timeout=15)
        output.seek(0)
        content = output.read()
    assert content.startswith(prefix)
    report = json.loads(content[len(prefix):])
    if mode == "capabilities":
        assert result.returncode == 0
        assert report["protocol_version"] == 1
    else:
        assert result.returncode == report["exit_code"]
        if mode == "success":
            assert report["status"] == "complete"
        else:
            assert report["failure"]["phase"] == mode
