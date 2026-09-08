"""Fail-closed CLI proof run where CI builds the dev-tools-disabled binary."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    binary = parser.parse_args().binary.resolve(strict=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith("ZIGBASE_")}
    for args in [("diagnostics", "--json"), ("diagnostics", "--help"),
                 ("capabilities", "--json")]:
        result = subprocess.run([str(binary), *args], env=env, timeout=5,
                                capture_output=True, text=True)
        if result.returncode != 1 or result.stdout or "-Ddev-tools=true" not in result.stderr:
            raise SystemExit(f"disabled CLI contract failed for {args!r}: {result!r}")
    print("disabled agent CLI: 3 rejection contracts passed")


if __name__ == "__main__":
    main()
