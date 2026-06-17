"""Resolve a ZigBase server/example binary for the test suites.

In CI, prebuilt binaries are passed via ZIGBASE_TEST_*_BINARY env vars so the
tests do not rebuild. Locally (env unset), fall back to `zig build` / `npm`
exactly as before.
"""
import os
import pathlib
import shutil
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


def _zig_build(package_dir: pathlib.Path, bin_name: str) -> str:
    subprocess.run(ZIG + ["build"], cwd=package_dir, check=True)
    path = package_dir / "zig-out" / "bin" / bin_name
    assert path.exists(), f"{bin_name} binary missing after build at {path}"
    return str(path)


def resolve_binary(env_var: str, package_dir: pathlib.Path, bin_name: str) -> str:
    """Return the prebuilt binary named by $env_var if it exists, else build it."""
    override = os.environ.get(env_var)
    if override and pathlib.Path(override).exists():
        return override
    return _zig_build(package_dir, bin_name)


def resolve_plugins_binary():
    """The plugins binary embeds frontend/dist at build time.

    Returns the $ZIGBASE_TEST_PLUGINS_BINARY override if it exists; otherwise
    builds the frontend (needs npm) and the binary, returning its path. Returns
    None when npm is unavailable so the caller can pytest.skip().
    """
    override = os.environ.get("ZIGBASE_TEST_PLUGINS_BINARY")
    if override and pathlib.Path(override).exists():
        return override
    if shutil.which("npm") is None:
        return None
    plugins = REPO / "examples" / "plugins"
    fe = plugins / "frontend"
    if not (fe / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=fe, check=True)
        subprocess.run(["npm", "run", "build"], cwd=fe, check=True)
    return _zig_build(plugins, "plugins")
