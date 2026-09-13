"""Changed-file selection against real Git state, without running selected tests."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "affected_agent", ROOT / "tools/agent_tests.py"
)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def git(root, *args):
    return (
        subprocess.run(
            ["git", *args], cwd=root, check=True, capture_output=True, timeout=10
        )
        .stdout.decode()
        .strip()
    )


@pytest.fixture
def repo(tmp_path, monkeypatch):
    git(tmp_path, "init", "-q")
    git(tmp_path, "config", "user.email", "fixture@example.invalid")
    git(tmp_path, "config", "user.name", "Fixture")
    for module in agent.MODULES:
        path = tmp_path / module
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("def test_example(): pass\n")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/agent_tests.py").write_bytes(
        (ROOT / "tools/agent_tests.py").read_bytes()
    )
    (tmp_path / ".gitignore").write_text("ignored\n")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-qm", "Fixture")
    monkeypatch.setattr(agent, "ROOT", tmp_path)
    return tmp_path


def test_no_changes_is_empty_not_complete_coverage(repo):
    result = agent.affected("HEAD")
    assert result["items"] == result["changes"] == []
    assert result["coverage_complete"] is False
    assert result["fallback"] is False


def test_staged_change_canceled_by_worktree_is_not_selected(repo):
    path = repo / agent.MODULES[0]
    original = path.read_bytes()
    path.write_text("def test_staged(): pass\n")
    git(repo, "add", agent.MODULES[0])
    path.write_bytes(original)
    assert agent.affected("HEAD")["changes"] == []


def test_tracked_staged_unstaged_deleted_and_untracked(repo):
    first, second, third = agent.MODULES[:3]
    (repo / first).write_text("def test_changed(): pass\n")
    git(repo, "add", first)
    (repo / second).write_text("def test_unstaged(): pass\n")
    # Delete a runtime dependency, not an inventoried module (which must exist).
    (repo / "src").mkdir()
    (repo / "src/deleted.zig").write_text("test {}")
    git(repo, "add", "src/deleted.zig")
    git(repo, "commit", "-qm", "Add dependency")
    (repo / "src/deleted.zig").unlink()
    (repo / "untracked\nfile").write_text("")
    (repo / "ignored").write_text("")
    result = agent.affected("HEAD~1")
    paths = {item["path"] for item in result["changes"]}
    # Added then removed cancels relative to base; it is not a changed path.
    assert paths == {first, second, "untracked\nfile"}
    result = agent.affected("HEAD")
    assert "src/deleted.zig" in {item["path"] for item in result["changes"]}
    assert result["fallback"] is True
    assert {item["id"] for item in result["items"]} == set(agent.GROUPS)


def test_direct_module_selection_and_shared_dependency(repo):
    module = agent.MODULES[0]
    (repo / module).write_text("def test_new(): pass\n")
    result = agent.affected("HEAD")
    assert [item["id"] for item in result["items"]] == [module]
    assert result["changes"][0]["reason"] == "test_module"
    (repo / "tests/admin/conftest.py").write_text("")
    result = agent.affected("HEAD")
    assert {item["id"] for item in result["items"]} == {module, *agent.ADMIN_MODULES}
    assert result["fallback"] is False


@pytest.mark.parametrize(
    "path,expected",
    [
        (
            "tools/performance_contracts.py",
            {"tests/tools/test_performance_contracts.py"},
        ),
        ("bench/contracts/example.json", {"tests/tools/test_performance_contracts.py"}),
        ("tools/replay/zb_replay.py", {"tests/tools/test_replay.py"}),
        ("src/records.zig", set(agent.ADMIN_MODULES)),
        ("build.zig", set(agent.ADMIN_MODULES)),
        ("zig-pkg/dependency/file.zig", set(agent.ADMIN_MODULES)),
        ("tests/_bin.py", set(agent.MODULES)),
        ("clients/typescript/src/client.ts", set(agent.SDK_SUITES)),
        ("clients/typescript/package-lock.json", set(agent.SDK_SUITES)),
        ("clients/typescript/vitest.config.ts", set(agent.SDK_SUITES)),
    ],
)
def test_curated_tool_dependencies_and_admin_group(repo, path, expected):
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("changed dependency\n")
    result = agent.affected("HEAD")
    assert {item["id"] for item in result["items"]} == expected
    assert result["changes"][0]["reason"] == "curated_dependency"
    assert result["fallback"] is False
    assert result["coverage_complete"] is False


def test_selector_source_and_unmapped_file_keep_full_fallback(repo):
    with (repo / "tools/agent_tests.py").open("a") as script:
        script.write("\n# modified selector\n")
    result = agent.affected("HEAD")
    assert {item["id"] for item in result["items"]} == set(agent.GROUPS)
    assert result["fallback"] is False
    (repo / "unmapped-tool.py").write_text("")
    result = agent.affected("HEAD")
    assert {item["id"] for item in result["items"]} == set(agent.GROUPS)
    assert result["fallback"] is True


def test_rename_accounts_for_old_and_new_path(repo):
    (repo / "src").mkdir()
    (repo / "src/before.zig").write_text("unchanged content")
    git(repo, "add", "src")
    git(repo, "commit", "-qm", "Source")
    git(repo, "mv", "src/before.zig", "outside.zig")
    result = agent.affected("HEAD")
    assert {item["path"] for item in result["changes"]} == {
        "src/before.zig",
        "outside.zig",
    }
    assert result["fallback"]


def test_cli_preserves_unusual_filename_bytes_and_ignores_git_redirection(repo):
    names = [b"--option", b"tabs\tand\nlines", b"bad-\xff", "unicode-é".encode()]
    for name in names:
        descriptor = os.open(
            os.fsencode(repo) + b"/" + name, os.O_CREAT | os.O_WRONLY, 0o600
        )
        os.close(descriptor)
    env = dict(os.environ, GIT_DIR="/nonexistent", GIT_INDEX_FILE="/nonexistent")
    process = subprocess.run(
        [sys.executable, repo / "tools/agent_tests.py", "affected", "--base", "HEAD"],
        env=env,
        capture_output=True,
        timeout=20,
    )
    assert process.returncode == 0
    result = json.loads(process.stdout)
    assert result["protocol_version"] == result["selection_version"] == 1
    assert {bytes.fromhex(item["path_bytes_hex"]) for item in result["changes"]} == set(
        names
    )
    assert all(item["reason"] == "unmapped_fallback" for item in result["changes"])
    assert result["coverage_complete"] is False
    assert result["items"][0]["argv"] == [
        *agent.RUN_PREFIX,
        "--selector",
        agent.MODULES[0],
    ]
    assert (
        process.stdout
        == subprocess.run(
            [
                sys.executable,
                repo / "tools/agent_tests.py",
                "affected",
                "--base",
                "HEAD",
            ],
            env=env,
            capture_output=True,
            timeout=20,
            check=True,
        ).stdout
    )


@pytest.mark.parametrize("base", ["", "--all", "a" * 257, "HEAD\0"])
def test_invalid_base_never_spawns(base, monkeypatch):
    monkeypatch.setattr(agent, "git_output", lambda _: pytest.fail("spawned"))
    with pytest.raises(agent.ContractError, match="Base must"):
        agent.affected(base)


def test_missing_revision_is_structured_cli_error(repo):
    process = subprocess.run(
        [
            sys.executable,
            repo / "tools/agent_tests.py",
            "affected",
            "--base",
            "not-a-revision",
        ],
        capture_output=True,
        timeout=20,
    )
    result = json.loads(process.stdout)
    assert process.returncode == result["exit_code"] == 2
    assert result["failure"]["code"] == "git_failed"
    assert "items" not in result and str(repo) not in process.stdout.decode()


@pytest.mark.parametrize(
    "raw",
    ["missing terminator", "\0", "/absolute\0", "../escape\0", "a//b\0", "a/./b\0"],
)
def test_invalid_git_paths_fail_closed(raw):
    with pytest.raises(agent.ContractError):
        agent.changed_paths(raw)


def test_path_count_and_byte_limits_fail_closed(monkeypatch):
    monkeypatch.setattr(agent, "MAX_CHANGED_PATHS", 1)
    with pytest.raises(agent.ContractError, match="Too many"):
        agent.changed_paths("a\0b\0")
    monkeypatch.setattr(agent, "MAX_PATH_BYTES", 1)
    with pytest.raises(agent.ContractError, match="oversized"):
        agent.changed_paths("é\0")


@pytest.mark.parametrize(
    "outcome",
    ["timed_out", "output_limit", "cleanup_error", "failed", "execution_error"],
)
def test_git_limits_do_not_return_partial_selection(monkeypatch, outcome):
    monkeypatch.setattr(
        agent,
        "execute",
        lambda *args, **kwargs: {"outcome": outcome, "stdout": "partial"},
    )
    with pytest.raises(agent.ContractError, match="no selection"):
        agent.git_output(["diff"])


@pytest.mark.parametrize("mode", ["timeout", "output"])
def test_actual_git_process_limits_fail_closed(repo, monkeypatch, mode):
    # A controlled executable exercises the real bounded subprocess reader;
    # no test selector is ever executed by affected().
    commands = repo / "fixture-bin"
    commands.mkdir()
    executable = commands / "git"
    code = "import time; time.sleep(5)" if mode == "timeout" else "print('x' * 10000)"
    executable.write_text(f"#!{sys.executable}\n{code}\n")
    executable.chmod(0o700)
    monkeypatch.setenv("PATH", str(commands))
    monkeypatch.setattr(agent, "GIT_TIMEOUT", 0.1)
    monkeypatch.setattr(agent, "MAX_OUTPUT_BYTES", 100)
    with pytest.raises(agent.ContractError, match="no selection"):
        agent.affected("HEAD")
