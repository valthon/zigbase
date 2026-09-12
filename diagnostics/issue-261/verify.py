#!/usr/bin/env python3
"""Verify the standalone reproduction against stock and privately patched Zig.

No installed toolchain files are changed. Run with pinned Zig 0.16.0 on PATH;
--zig-lib-dir supports installations whose lib directory is not beside zig.
"""

import argparse
import os
from pathlib import Path
import resource
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent


def check(args, *, cwd, env):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args!r}\n{result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig"))
    parser.add_argument("--zig-lib-dir", type=Path)
    args = parser.parse_args()
    if not args.zig:
        parser.error("pinned Zig 0.16.0 must be on PATH, or pass --zig")
    zig = Path(args.zig).resolve()
    env = dict(os.environ)
    env.pop("ZIG_BUILD_RUNNER", None)
    env.pop("ZIG_LIB_DIR", None)
    if check([str(zig), "version"], cwd=ROOT, env=env).stdout.strip() != "0.16.0":
        parser.error("this reproduction and patch target exactly Zig 0.16.0")
    library = (args.zig_lib_dir or zig.parent / "lib").resolve()
    if not (library / "std/Build/Step/Run.zig").is_file():
        parser.error("cannot locate Zig's lib directory; pass --zig-lib-dir")
    # Deliberate destructor signal must not create large core files in CI.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="zigbase-issue261-") as directory:
        scratch = Path(directory)
        patched = scratch / "lib"
        shutil.copytree(library, patched)
        for patch in ("zig-runner-instrumentation.patch", "zig-runner-diagnostic-fix.patch"):
            check(["patch", "--dry-run", "-p1", "-i", str(ROOT / patch)], cwd=patched, env=env)
        check(["patch", "-p1", "-i", str(ROOT / "zig-runner-diagnostic-fix.patch")], cwd=patched, env=env)
        for variant, lib in (("stock", library), ("patched", patched)):
            for case in ("newline", "meaningful", "assertion", "signal"):
                run_env = {**env, "ZIG_LIB_DIR": str(lib), "ZIG_GLOBAL_CACHE_DIR": str(scratch / "cache")}
                command = [str(zig), "build", "test", "--summary", "all", f"-Dcase={case}", "--cache-dir", str(scratch / f"local-{variant}-{case}")]
                result = subprocess.run(command, cwd=ROOT / "upstream-minimal", env=run_env, capture_output=True, text=True, timeout=120)
                output = result.stdout + result.stderr
                expected_code = 0 if case in ("newline", "meaningful") else 1
                expected_command = variant == "stock" or case in ("assertion", "signal")
                checks = [result.returncode == expected_code, ("failed command:" in output) == expected_command]
                if case == "meaningful":
                    checks.append("issue261-meaningful-stderr" in output)
                if case == "assertion":
                    checks.append("TestUnexpectedResult" in output)
                if case == "signal":
                    checks.append("test process unexpectedly terminated with signal SEGV" in output)
                if not all(checks):
                    raise RuntimeError(f"{variant}/{case}: unexpected diagnostic or exit {result.returncode}\n{output}")
                print(f"{variant}/{case}: exit {result.returncode}, failed-command={expected_command}", flush=True)


if __name__ == "__main__":
    main()
