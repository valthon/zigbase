"""Deterministic fake command used to exercise the agent runner."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path


mode = sys.argv[1]

if mode == "success":
    Path("agent-result.json").write_text(
        json.dumps(
            {
                "argv": sys.argv[2:],
                "stdin": sys.stdin.read(),
                "home": os.environ.get("HOME"),
                "secret": os.environ.get("FAKE_AGENT_SECRET"),
            }
        )
    )
elif mode == "nonzero":
    print("intentional failure", file=sys.stderr)
    raise SystemExit(7)
elif mode == "sleep":
    time.sleep(30)
elif mode == "flood":
    sys.stdout.write("x" * 100_000)
    sys.stderr.write("y" * 100_000)
elif mode == "spawn":
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ]
    )
    Path("child.pid").write_text(str(child.pid))
else:
    raise SystemExit(f"unknown fake-agent mode: {mode}")
