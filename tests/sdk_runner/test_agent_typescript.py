"""Run only after installing clients/typescript dependencies (no pytest needed).

This lives outside tests/tools so Python-only tooling checks never acquire SDK
dependencies. CI runs it instead of a second, duplicate SDK unit-suite command.
"""

import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]


class TypeScriptRunnerTest(unittest.TestCase):
    def test_actual_bounded_sdk_selector(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "tools/agent_tests.py"),
                "run",
                "--selector", "clients/typescript::unit",
                "--timeout-seconds", "180",
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
        self.assertEqual(report["selector"], "clients/typescript::unit")
        self.assertEqual(report["cwd"], "clients/typescript")
        self.assertEqual(report["argv"], [
            "mise", "exec", "node@24", "--", "node",
            "node_modules/vitest/vitest.mjs", "run", "--config", "vitest.config.ts",
            "--maxWorkers=2", "--minWorkers=1",
        ])
        self.assertEqual(report["limits"], {
            "timeout_seconds": 180, "output_limit_bytes": 65536,
        })
        self.assertFalse(report["output_truncated"], diagnostics)
        self.assertFalse(report["cleanup_failed"], diagnostics)
        self.assertIsNone(report["test_counts"])
        # Confirm real SDK execution, not an empty/no-op successful command.
        self.assertIn("test/smoke.test.ts", report["stdout"], diagnostics)


if __name__ == "__main__":
    unittest.main()
