"""Inventory/selection boundary and real subprocess lifecycle regressions."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "agent_tests", ROOT / "tools/agent_tests.py"
)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def child(code, tmp_path, *, timeout=2, output_limit=4096):
    return agent.execute(
        [sys.executable, "-c", code],
        cwd=tmp_path,
        env=dict(os.environ),
        timeout=timeout,
        output_limit=output_limit,
    )


def test_inventory_is_static_and_has_exact_runnable_selectors(tmp_path, monkeypatch):
    source = tmp_path / "test_example.py"
    marker = tmp_path / "imported"
    source.write_text(f"open({str(marker)!r}, 'w').close()\ndef test_example(): pass\n")
    monkeypatch.setattr(agent, "ROOT", tmp_path)
    monkeypatch.setattr(agent, "MODULES", ("test_example.py",))
    monkeypatch.setattr(agent, "SDK_SUITES", ())
    inventory = agent.inventory()
    assert [item["id"] for item in inventory["items"]] == [
        "test_example.py",
        "test_example.py::test_example",
    ]
    assert not marker.exists()
    for item in inventory["items"]:
        assert item["argv"] == [*agent.RUN_PREFIX, "--selector", item["id"]]
    assert inventory["execution"]["shell"] is False


def test_checkout_inventory_cli():
    result = subprocess.run(
        [sys.executable, ROOT / "tools/agent_tests.py", "inventory"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    report = json.loads(result.stdout)
    assert result.returncode == report["exit_code"] == 0
    assert report["scope"] == "repository-focused-tests"
    items = report["items"]
    assert len({item["id"] for item in items}) == len(items)
    assert any(item["requirements"]["browser"] == "chromium" for item in items)
    assert any(item["kind"] == "module" for item in items)
    assert any(item["kind"] == "function" for item in items)
    suite = next(item for item in items if item["id"] == "clients/typescript::unit")
    assert suite["kind"] == "suite" and suite["runner"] == "vitest"
    assert suite["cwd"] == "clients/typescript"
    assert suite["requirements"]["tools"]["node"] == "24"
    assert not suite["requirements"]["binary"]["build_if_missing"]


@pytest.mark.parametrize(
    "selector",
    [
        "--help",
        "../test.py",
        "/tmp/test.py",
        "test_*",
        "tests/admin/test_schema.py;touch x",
        "tests/admin/test_schema.py::test_missing",
        "tests/admin/test_schema.py -k foo",
        "clients/typescript::unit --watch",
        "clients/typescript::integration",
    ],
)
def test_unknown_selector_never_starts_process(selector, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("invalid selector spawned a process")

    monkeypatch.setattr(agent.subprocess, "Popen", forbidden)
    with pytest.raises(agent.ContractError, match="exactly match"):
        agent.run(selector, 1, 1024)


@pytest.mark.parametrize("timeout,limit", [(0, 1), (901, 1), (1, 0), (1, 1048577)])
def test_limits_validated_before_spawn(timeout, limit, monkeypatch):
    monkeypatch.setattr(
        agent.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("spawned")
    )
    with pytest.raises(agent.ContractError, match="bounds"):
        agent.run(agent.MODULES[0], timeout, limit)


def test_argument_errors_are_json(capsys):
    assert agent.main(["run", "--selector", "missing", "--extra"]) == 2
    report = json.loads(capsys.readouterr().out)
    assert report["failure"]["code"] == "invalid_arguments"
    assert agent.main(["run", "--selector", "missing"]) == 2
    report = json.loads(capsys.readouterr().out)
    assert report["failure"]["code"] == "invalid_selector"


def test_real_child_success_and_failure(tmp_path):
    passed = child("print('passed')", tmp_path)
    assert passed["outcome"] == "passed" and passed["child_exit_code"] == 0
    assert passed["stdout"] == "passed\n" and passed["test_counts"] is None
    failed = child(
        "import sys; print('assertion failed', file=sys.stderr); sys.exit(7)", tmp_path
    )
    assert failed["outcome"] == "failed" and failed["child_exit_code"] == 7
    assert failed["stderr"] == "assertion failed\n"


def test_real_timeout_kills_grandchild(tmp_path):
    marker = tmp_path / "escaped"
    grandchild = f"import time; time.sleep(1); open({str(marker)!r}, 'w').close()"
    code = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{grandchild!r}]); print('ready',flush=True); time.sleep(30)"
    result = child(code, tmp_path, timeout=0.4)
    assert result["outcome"] == "timed_out"
    assert result["stdout"] == "ready\n"
    assert result["duration_ms"] < 3000
    time.sleep(1)
    assert not marker.exists()


def test_combined_output_limit_and_exact_boundary(tmp_path):
    result = child(
        "import os; os.write(1,b'x'*500); os.write(2,b'y'*500)",
        tmp_path,
        output_limit=600,
    )
    assert result["outcome"] == "output_limit"
    assert result["captured_bytes"] == 600
    assert len(result["stdout"]) + len(result["stderr"]) == 600
    assert result["output_truncated"]
    exact = child("import os; os.write(1,b'x'*600)", tmp_path, output_limit=600)
    assert exact["outcome"] == "passed" and not exact["output_truncated"]


@pytest.mark.parametrize("keep_pipes", [True, False])
def test_exited_parent_does_not_strand_grandchild(tmp_path, keep_pipes):
    marker = tmp_path / "stranded"
    grandchild = f"import time; time.sleep(1); open({str(marker)!r}, 'w').close()"
    redirect = (
        "" if keep_pipes else ",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL"
    )
    code = f"import subprocess,sys; subprocess.Popen([sys.executable,'-c',{grandchild!r}]{redirect}); print('ready',flush=True)"
    result = child(code, tmp_path, timeout=0.4)
    assert result["outcome"] == ("timed_out" if keep_pipes else "passed")
    assert result["stdout"] == "ready\n"
    assert result["duration_ms"] < 3000
    time.sleep(1)
    assert not marker.exists()


def test_spawn_error_is_structured(tmp_path):
    result = agent.execute(
        [str(tmp_path / "missing")],
        cwd=tmp_path,
        env=dict(os.environ),
        timeout=1,
        output_limit=10,
    )
    assert result["outcome"] == "execution_error"
    assert result["failure"]["code"] == "spawn_failed"
    assert result["child_exit_code"] is None


@pytest.mark.parametrize(
    "mode", ["timed_out", "output_limit", "execution_error", "failed", "completed"]
)
def test_cleanup_failure_preserves_primary_outcome(tmp_path, monkeypatch, mode):
    real_killpg = agent.os.killpg

    def failed_cleanup(pid, sig):
        # Reap the real process tree, then simulate a reported cleanup failure.
        try:
            real_killpg(pid, sig)
        except ProcessLookupError:
            pass
        raise PermissionError("simulated cleanup failure")

    monkeypatch.setattr(agent.os, "killpg", failed_cleanup)
    if mode == "execution_error":
        def failed_capture(*args):
            raise PermissionError("simulated capture failure")

        monkeypatch.setattr(agent.os, "set_blocking", failed_capture)
    code = {
        "timed_out": "import time; time.sleep(30)",
        "output_limit": "print('x' * 1000)",
        "execution_error": "pass",
        "failed": "import sys; sys.exit(7)",
        "completed": "pass",
    }[mode]
    result = child(code, tmp_path, timeout=0.3, output_limit=100)
    assert result["outcome"] == ("cleanup_error" if mode == "completed" else mode)
    assert result["cleanup_failed"] is True
    assert result["output_truncated"] == (mode == "output_limit")
    if mode == "execution_error":
        assert result["failure"]["code"] == "capture_failed"
    if mode == "failed":
        assert result["child_exit_code"] == 7


def test_inventory_refuses_symlink_escape(tmp_path, monkeypatch):
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    source = tmp_path / "outside.py"
    source.write_text("def test_outside(): pass\n")
    (checkout / "test_outside.py").symlink_to(source)
    monkeypatch.setattr(agent, "ROOT", checkout)
    monkeypatch.setattr(agent, "MODULES", ("test_outside.py",))
    with pytest.raises(agent.ContractError, match="escapes"):
        agent.inventory()


def test_child_environment_is_explicit(monkeypatch):
    monkeypatch.setenv("PYTEST_ADDOPTS", "--collect-only")
    monkeypatch.setenv("PYTEST_PLUGINS", "surprise")
    monkeypatch.setenv("ZIGBASE_SERVE_BACKGROUND", "1")
    monkeypatch.setenv("MISE_AUTO_INSTALL", "true")
    monkeypatch.setenv("NODE_OPTIONS", "--require surprise")
    env = agent.child_environment()
    assert "PYTEST_ADDOPTS" not in env and "PYTEST_PLUGINS" not in env
    assert env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] == "1"
    assert env["ZIGBASE_SERVE_BACKGROUND"] == "0"
    assert env["MISE_AUTO_INSTALL"] == "false"
    assert "NODE_OPTIONS" not in env


def test_sdk_suite_uses_fixed_command_and_package_directory(monkeypatch):
    calls = []

    def execute(argv, **kwargs):
        calls.append((argv, kwargs))
        return {"outcome": "passed"}

    monkeypatch.setattr(agent, "execute", execute)
    result = agent.run("clients/typescript::unit", 17, 1234)
    argv, options = calls[0]
    assert argv == [
        "mise", "exec", "node@24", "--", "node",
        "node_modules/vitest/vitest.mjs", "run", "--config", "vitest.config.ts",
        "--maxWorkers=2", "--minWorkers=1",
    ]
    assert options["cwd"] == ROOT / "clients/typescript"
    assert options["timeout"] == 17 and options["output_limit"] == 1234
    assert result["cwd"] == "clients/typescript"


def test_sdk_directory_escape_never_starts_process(tmp_path, monkeypatch):
    checkout = tmp_path / "checkout"
    (checkout / "clients").mkdir(parents=True)
    (checkout / "clients/typescript").symlink_to(tmp_path, target_is_directory=True)
    monkeypatch.setattr(agent, "ROOT", checkout)
    monkeypatch.setattr(agent, "MODULES", ())
    monkeypatch.setattr(agent, "execute", lambda *a, **kw: pytest.fail("spawned"))
    with pytest.raises(agent.ContractError, match="escapes"):
        agent.run("clients/typescript::unit", 1, 1024)


def test_actual_allowlisted_pytest_execution():
    result = agent.run(
        "tests/tools/test_bin_resolver.py::test_resolve_binary_uses_existing_env_override",
        30,
        65536,
    )
    assert result["outcome"] == "passed", result
    assert result["child_exit_code"] == 0
    assert result["argv"] == [*agent.PREFIX, "--", result["selector"]]
