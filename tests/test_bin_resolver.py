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
