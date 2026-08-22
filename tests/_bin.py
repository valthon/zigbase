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

# Declared step names per package dir, keyed by resolved path. `zig build
# --list-steps` re-runs the configure phase, so ask once per process.
_BUILD_STEPS_CACHE: dict = {}


def _build_steps(package_dir: pathlib.Path) -> frozenset:
    """Every step name `zig build` declares for the package at package_dir."""
    key = package_dir.resolve()
    cached = _BUILD_STEPS_CACHE.get(key)
    if cached is None:
        listing = subprocess.run(
            ZIG + ["build", "--list-steps"],
            cwd=package_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        # Each line is "  <name>  <description>"; the step name is the first token.
        cached = frozenset(
            line.split()[0] for line in listing.splitlines() if line.split()
        )
        _BUILD_STEPS_CACHE[key] = cached
    return cached


def _zig_build(package_dir: pathlib.Path, bin_name: str) -> str:
    """Build bin_name inside package_dir and return the installed path.

    Which step produces a binary differs by package. The example packages
    (examples/blog, examples/plugins) `b.installArtifact` theirs, so the
    default `install` step builds them. The repo-root fixture servers
    (features-fixture, minimal-server, full-fixture, import-fixture,
    dating-server, auth2-server) are instead reachable only through a *named*
    step that owns their install artifact — `zig build` alone never produces
    them. So: build the step named after the binary when the package declares
    one, else the default step.
    """
    step = bin_name if bin_name in _build_steps(package_dir) else "install"
    subprocess.run(ZIG + ["build", step], cwd=package_dir, check=True)
    path = package_dir / "zig-out" / "bin" / bin_name
    if not path.exists():
        raise FileNotFoundError(
            f"{bin_name} binary missing at {path} after `zig build {step}` in "
            f"{package_dir} — does a build step install it?"
        )
    return str(path)


def resolve_binary(env_var: str, package_dir: pathlib.Path, bin_name: str) -> str:
    """Return the prebuilt binary named by $env_var if it exists, else build it.

    A set-but-missing override is a misconfiguration (e.g. a missing CI
    artifact); raise rather than silently rebuild, which would mask the problem
    and require a Zig toolchain the lean test jobs do not install.
    """
    override = os.environ.get(env_var)
    if override:
        if pathlib.Path(override).exists():
            return override
        raise FileNotFoundError(f"{env_var}={override} does not exist")
    return _zig_build(package_dir, bin_name)


def resolve_plugins_binary():
    """The plugins binary embeds frontend/dist at build time.

    Returns the $ZIGBASE_TEST_PLUGINS_BINARY override if it exists; otherwise
    builds the frontend (needs npm) and the binary, returning its path. Returns
    None when no override is set and npm is unavailable so the caller can
    pytest.skip(). A set-but-missing override raises instead — silently skipping
    in CI would hide a missing artifact as a passing (skipped) test.
    """
    override = os.environ.get("ZIGBASE_TEST_PLUGINS_BINARY")
    if override:
        if pathlib.Path(override).exists():
            return override
        raise FileNotFoundError(f"ZIGBASE_TEST_PLUGINS_BINARY={override} does not exist")
    if shutil.which("npm") is None:
        return None
    plugins = REPO / "examples" / "plugins"
    # The npm package root is examples/plugins (frontend/ carries no package.json),
    # and the script that emits frontend/dist is `build:frontend`.
    if not (plugins / "frontend" / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=plugins, check=True)
        subprocess.run(["npm", "run", "build:frontend"], cwd=plugins, check=True)
    return _zig_build(plugins, "plugins")
