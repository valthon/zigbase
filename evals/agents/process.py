"""Bounded subprocess execution for agent evaluations."""

from __future__ import annotations

import os
import signal
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProcessResult:
    exit_code: int
    timed_out: bool
    output_truncated: bool


class _CaptureBudget:
    def __init__(self, maximum: int) -> None:
        self.remaining = maximum
        self.truncated = False
        self.lock = threading.Lock()

    def claim(self, size: int) -> int:
        with self.lock:
            accepted = min(size, self.remaining)
            self.remaining -= accepted
            if accepted != size:
                self.truncated = True
            return accepted


def _pump(source, destination, budget: _CaptureBudget) -> None:
    try:
        while chunk := source.read(64 * 1024):
            accepted = budget.claim(len(chunk))
            if accepted:
                destination.write(chunk[:accepted])
                destination.flush()
    finally:
        source.close()


def _feed(destination, value: bytes) -> None:
    try:
        destination.write(value)
        destination.close()
    except BrokenPipeError:
        pass


def _signal_group(pid: int, sig: signal.Signals) -> None:
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def run_process(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    stdin: bytes | None,
    stdout_path: Path,
    stderr_path: Path,
    timeout_seconds: int,
    term_grace_seconds: int,
    max_output_bytes: int,
) -> ProcessResult:
    """Run argv without a shell and clean up its whole process group."""
    budget = _CaptureBudget(max_output_bytes)
    timed_out = False
    with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        assert process.stdout is not None
        assert process.stderr is not None
        pumps = [
            threading.Thread(
                target=_pump, args=(process.stdout, stdout_file, budget), daemon=True
            ),
            threading.Thread(
                target=_pump, args=(process.stderr, stderr_file, budget), daemon=True
            ),
        ]
        for pump in pumps:
            pump.start()

        feeder = None
        if stdin is not None:
            assert process.stdin is not None
            feeder = threading.Thread(
                target=_feed, args=(process.stdin, stdin), daemon=True
            )
            feeder.start()

        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            _signal_group(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=term_grace_seconds)
            except subprocess.TimeoutExpired:
                _signal_group(process.pid, signal.SIGKILL)
                process.wait()
        finally:
            # A successful agent may still leave helpers behind. The grader owns
            # Docker resources; arbitrary child processes never outlive the run.
            _signal_group(process.pid, signal.SIGTERM)
            for pump in pumps:
                pump.join(timeout=term_grace_seconds)
            if any(pump.is_alive() for pump in pumps):
                _signal_group(process.pid, signal.SIGKILL)
                for pump in pumps:
                    pump.join(timeout=term_grace_seconds)
            if feeder is not None:
                feeder.join(timeout=term_grace_seconds)

    return ProcessResult(
        exit_code=process.returncode,
        timed_out=timed_out,
        output_truncated=budget.truncated,
    )
