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


def test_resolve_binary_falls_back_to_build_when_override_missing(monkeypatch):
    monkeypatch.setenv("ZIGBASE_TEST_FAKE", "/does/not/exist")
    # Falls through to `zig build` in a dir with no build.zig -> non-zero exit.
    with pytest.raises(subprocess.CalledProcessError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")


def test_resolve_binary_falls_back_when_env_unset(monkeypatch):
    monkeypatch.delenv("ZIGBASE_TEST_FAKE", raising=False)
    with pytest.raises(subprocess.CalledProcessError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")
