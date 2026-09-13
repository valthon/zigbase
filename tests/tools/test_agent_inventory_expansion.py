"""Regression driver stays outside the allowlist to avoid recursive self-runs."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "inventory_agent", ROOT / "tools/agent_tests.py"
)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

ADDITIONS = (
    "tests/tools/test_performance_contracts.py",
    "tests/tools/test_replay.py",
    "tests/tools/test_agent_tests.py",
    "tests/tools/test_agent_affected.py",
)


def wrapper_report(completed):
    diagnostics = (
        f"Wrapper return code: {completed.returncode}\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
    )
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError:
        pytest.fail(f"Wrapper did not emit JSON.\n{diagnostics}", pytrace=False)
    if not isinstance(result, dict):
        pytest.fail(
            f"Wrapper did not emit a JSON object.\n{diagnostics}", pytrace=False
        )
    return result, diagnostics


def test_expanded_inventory_is_static_and_explicit(monkeypatch):
    monkeypatch.setattr(
        agent.subprocess,
        "Popen",
        lambda *args, **kwargs: pytest.fail("inventory spawned process"),
    )
    catalog = agent.inventory()
    ids = {item["id"] for item in catalog["items"]}
    assert set(ADDITIONS) <= ids
    assert "tests/tools/test_agent_inventory_expansion.py" not in ids
    assert not any(
        identifier.startswith("tests/tools/test_performance_contracts.py::")
        for identifier in ids
    )
    assert (
        "tests/tools/test_replay.py::test_subset_matches_extra_keys_but_not_missing_or_different"
        in ids
    )
    for item in catalog["items"]:
        if item["module"] in ADDITIONS:
            assert item["requirements"]["tools"] == {"python": "3.13", "zig": None}
            assert item["requirements"]["python_packages"] == ["pytest"]
            assert item["requirements"]["browser"] is None
            assert item["requirements"]["binary"] == {
                "build_if_missing": False,
                "prebuilt_override": None,
            }
            assert item["effect"] == "may_write_and_access_network"
    assert all(
        target in agent.GROUPS
        for _, targets in agent.DEPENDENCIES
        for target in targets
    )
    assert set(agent.MODULE_NOTES) <= set(agent.MODULES)


@pytest.mark.parametrize("module", ADDITIONS)
def test_added_module_runs_through_actual_bounded_cli(module):
    # Exercise the supported public wrapper rather than invoking pytest directly.
    # This file itself is deliberately not selected by any of these modules.
    completed = subprocess.run(
        [
            sys.executable,
            ROOT / "tools/agent_tests.py",
            "run",
            "--selector",
            module,
            "--timeout-seconds",
            str(agent.DEFAULT_TIMEOUT),
        ],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=agent.DEFAULT_TIMEOUT + 10,
    )
    result, diagnostics = wrapper_report(completed)
    assert completed.returncode == result.get("exit_code") == 0, diagnostics
    assert result["protocol_version"] == 1
    assert result["scope"] == "repository-focused-tests"
    assert result["outcome"] == "passed"
    assert result["selector"] == module
    assert result["argv"] == [*agent.PREFIX, "--", module]
    assert result["limits"] == {"timeout_seconds": agent.DEFAULT_TIMEOUT, "output_limit_bytes": agent.DEFAULT_OUTPUT_BYTES}
    assert result["cleanup_failed"] is False


def test_unlisted_test_still_cannot_execute(monkeypatch):
    monkeypatch.setattr(
        agent.subprocess,
        "Popen",
        lambda *args, **kwargs: pytest.fail("unlisted module spawned process"),
    )
    with pytest.raises(agent.ContractError, match="exactly match"):
        agent.run("tests/tools/test_agent_inventory_expansion.py", 30, 65536)
