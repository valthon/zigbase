import pathlib
import subprocess

import pytest

import _bin


def test_resolve_binary_uses_existing_env_override(tmp_path, monkeypatch):
    fake = tmp_path / "prebuilt-bin"
    fake.write_text("#!/bin/sh\n")
    monkeypatch.setenv("ZIGBASE_TEST_FAKE", str(fake))
    # package_dir is bogus on purpose: a valid override must short-circuit
    # before any build is attempted.
    got = _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/nonexistent/pkg"), "whatever")
    assert got == str(fake)


def test_resolve_binary_raises_when_override_set_but_missing(monkeypatch):
    # An explicitly-set override that points nowhere is a misconfiguration
    # (e.g. a missing CI artifact). Fail loudly instead of silently rebuilding.
    monkeypatch.setenv("ZIGBASE_TEST_FAKE", "/does/not/exist")
    with pytest.raises(FileNotFoundError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")


def test_resolve_binary_falls_back_to_build_when_env_unset(monkeypatch):
    # Env unset -> local dev path: build via zig. /tmp has no build.zig, so the
    # build exits non-zero, proving we took the build branch.
    monkeypatch.delenv("ZIGBASE_TEST_FAKE", raising=False)
    with pytest.raises(subprocess.CalledProcessError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")


def test_resolve_plugins_binary_raises_when_override_set_but_missing(monkeypatch):
    # A set-but-missing plugins override must raise rather than fall through to
    # the npm/skip path, which would silently skip the test in CI.
    monkeypatch.setenv("ZIGBASE_TEST_PLUGINS_BINARY", "/does/not/exist")
    with pytest.raises(FileNotFoundError):
        _bin.resolve_plugins_binary()


@pytest.fixture(autouse=True)
def _clear_step_cache():
    # _build_steps memoizes per package dir for the life of the process; the
    # fakes below would otherwise leak declared-step sets between tests.
    _bin._BUILD_STEPS_CACHE.clear()
    yield
    _bin._BUILD_STEPS_CACHE.clear()


def _fake_zig(monkeypatch, steps, *, produce=None):
    """Stub subprocess.run: answer --list-steps with `steps`, record the rest.

    `produce` is a path touched when a build command runs, standing in for the
    binary a real `zig build <step>` would install.
    """
    calls = []

    def run(cmd, **kwargs):
        calls.append((cmd, kwargs.get("cwd")))
        if "--list-steps" in cmd:
            listing = "".join(f"  {name}    description\n" for name in steps)
            return subprocess.CompletedProcess(cmd, 0, stdout=listing, stderr="")
        if produce is not None:
            produce.parent.mkdir(parents=True, exist_ok=True)
            produce.write_text("#!/bin/sh\n")
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(_bin.subprocess, "run", run)
    return calls


def test_zig_build_uses_the_step_named_after_the_binary(tmp_path, monkeypatch):
    # The repo-root fixture servers are installed only by their own named step;
    # the default step never produces them (that was 16 local-only errors).
    out = tmp_path / "zig-out" / "bin" / "features-fixture"
    calls = _fake_zig(monkeypatch, ["install", "test", "features-fixture"], produce=out)

    got = _bin._zig_build(tmp_path, "features-fixture")

    assert got == str(out)
    build_cmds = [cmd for cmd, _ in calls if "--list-steps" not in cmd]
    assert build_cmds == [_bin.ZIG + ["build", "features-fixture"]]


def test_zig_build_uses_default_step_when_no_step_is_named_after_the_binary(tmp_path, monkeypatch):
    # examples/blog and examples/plugins b.installArtifact their binary, so the
    # default step is the one that builds it.
    out = tmp_path / "zig-out" / "bin" / "blog"
    calls = _fake_zig(monkeypatch, ["install", "test"], produce=out)

    got = _bin._zig_build(tmp_path, "blog")

    assert got == str(out)
    build_cmds = [cmd for cmd, _ in calls if "--list-steps" not in cmd]
    assert build_cmds == [_bin.ZIG + ["build", "install"]]


def test_zig_build_error_names_the_step_that_failed_to_produce_the_binary(tmp_path, monkeypatch):
    # A build that succeeds but installs nothing must say which step was run,
    # not just that a file is missing.
    _fake_zig(monkeypatch, ["install", "minimal-server"], produce=None)

    with pytest.raises(FileNotFoundError) as excinfo:
        _bin._zig_build(tmp_path, "minimal-server")

    assert "zig build minimal-server" in str(excinfo.value)


def test_build_steps_are_queried_once_per_package(tmp_path, monkeypatch):
    out = tmp_path / "zig-out" / "bin" / "full-fixture"
    calls = _fake_zig(monkeypatch, ["install", "full-fixture"], produce=out)

    _bin._zig_build(tmp_path, "full-fixture")
    _bin._zig_build(tmp_path, "full-fixture")

    assert sum(1 for cmd, _ in calls if "--list-steps" in cmd) == 1


def test_resolve_plugins_binary_builds_the_frontend_from_the_package_root(tmp_path, monkeypatch):
    # frontend/ has no package.json and no `build` script: npm must run from
    # examples/plugins with the `build:frontend` script.
    monkeypatch.delenv("ZIGBASE_TEST_PLUGINS_BINARY", raising=False)
    monkeypatch.setattr(_bin.shutil, "which", lambda _name: "/usr/bin/npm")
    monkeypatch.setattr(_bin, "REPO", tmp_path)
    plugins = tmp_path / "examples" / "plugins"
    plugins.mkdir(parents=True)
    out = plugins / "zig-out" / "bin" / "plugins"
    calls = _fake_zig(monkeypatch, ["install"], produce=out)

    got = _bin.resolve_plugins_binary()

    assert got == str(out)
    npm_calls = [(cmd, cwd) for cmd, cwd in calls if cmd[0] == "npm"]
    assert npm_calls == [
        (["npm", "install", "--no-audit", "--no-fund"], plugins),
        (["npm", "run", "build:frontend"], plugins),
    ]


def test_resolve_plugins_binary_skips_npm_when_dist_already_built(tmp_path, monkeypatch):
    monkeypatch.delenv("ZIGBASE_TEST_PLUGINS_BINARY", raising=False)
    monkeypatch.setattr(_bin.shutil, "which", lambda _name: "/usr/bin/npm")
    monkeypatch.setattr(_bin, "REPO", tmp_path)
    plugins = tmp_path / "examples" / "plugins"
    dist = plugins / "frontend" / "dist"
    dist.mkdir(parents=True)
    (dist / "index.html").write_text("<!doctype html>")
    out = plugins / "zig-out" / "bin" / "plugins"
    calls = _fake_zig(monkeypatch, ["install"], produce=out)

    _bin.resolve_plugins_binary()

    assert [cmd for cmd, _ in calls if cmd[0] == "npm"] == []


def test_resolve_plugins_binary_returns_none_without_npm(monkeypatch):
    # The documented asymmetry: no override + no npm is skippable, unlike a
    # set-but-missing override, which raises (covered above).
    monkeypatch.delenv("ZIGBASE_TEST_PLUGINS_BINARY", raising=False)
    monkeypatch.setattr(_bin.shutil, "which", lambda _name: None)

    assert _bin.resolve_plugins_binary() is None
