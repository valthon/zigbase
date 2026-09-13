"""Real Python SDK runner regression; install SDK dev/realtime extras first.

Kept outside dependency-light tests/tools. CI uses this instead of repeating
the SDK unit suite. No missing-dependency skips or installation attempts.
"""

import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PythonRunnerTest(unittest.TestCase):
    def test_actual_bounded_sdk_selector(self):
        completed = subprocess.run(
            [
                sys.executable, str(ROOT / "tools/agent_tests.py"), "run",
                "--selector", "clients/python::unit", "--timeout-seconds", "180",
                "--output-limit-bytes", "1048576",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=190,
        )
        diagnostics = (
            f"Wrapper exit: {completed.returncode}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
        self.assertEqual(completed.returncode, 0, diagnostics)
        report = json.loads(completed.stdout)
        self.assertEqual(report["protocol_version"], 1)
        self.assertEqual(report["scope"], "repository-focused-tests")
        self.assertEqual(report["exit_code"], 0, diagnostics)
        self.assertEqual(report["outcome"], "passed", diagnostics)
        self.assertEqual(report["child_exit_code"], 0, diagnostics)
        self.assertEqual(report["selector"], "clients/python::unit")
        self.assertEqual(report["cwd"], "clients/python")
        self.assertEqual(report["argv"], [
            "mise", "exec", "python@3.13", "--", "python", "-m", "pytest",
            "-q", "-o", "addopts=", "-p", "pytest_asyncio.plugin",
            "-c", "pyproject.toml", "-o", "pythonpath=src", "-m", "not integration",
            "--ignore=tests/integration", "--", "tests",
        ])
        self.assertEqual(report["limits"], {
            "timeout_seconds": 180, "output_limit_bytes": 1048576,
        })
        self.assertFalse(report["output_truncated"], diagnostics)
        self.assertFalse(report["cleanup_failed"], diagnostics)
        self.assertIsNone(report["test_counts"])
        self.assertRegex(report["stdout"], r"\b[1-9][0-9]* passed\b", diagnostics)
        self.assertNotIn("PytestUnhandledCoroutineWarning", report["stdout"], diagnostics)


if __name__ == "__main__":
    unittest.main()
