"""Bounded subprocess execution for agent evaluations."""

from __future__ import annotations

import os
import signal
import stat
import subprocess
import threading
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProcessResult:
    exit_code: int
    timed_out: bool
    interrupted: bool
    output_truncated: bool
    stdout: str = ""
    stderr: str = ""


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


def _terminate_group(process: subprocess.Popen[bytes], grace_seconds: int) -> None:
    """Terminate a runner-owned process group and reap its leader."""
    _signal_group(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        _signal_group(process.pid, signal.SIGKILL)
        process.wait()


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
    read_output: bool = True,
) -> ProcessResult:
    """Run argv without a shell and clean up its whole process group."""
    budget = _CaptureBudget(max_output_bytes)
    timed_out = False
    interrupted = False

    def private_log(path: Path):
        descriptor = os.open(
            path,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError(f"{path} is not a regular file")
            os.fchmod(descriptor, 0o600)
            return os.fdopen(descriptor, "w+b")
        except Exception:
            os.close(descriptor)
            raise

    with ExitStack() as stack:
        stdout_file = stack.enter_context(private_log(stdout_path))
        stderr_file = stack.enter_context(private_log(stderr_path))
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
            _terminate_group(process, term_grace_seconds)
        except KeyboardInterrupt:
            interrupted = True
            _terminate_group(process, term_grace_seconds)
        finally:
            # Clean up ordinary helpers that remain in the command's process group.
            _signal_group(process.pid, signal.SIGTERM)
            for pump in pumps:
                pump.join(timeout=term_grace_seconds)
            if any(pump.is_alive() for pump in pumps):
                _signal_group(process.pid, signal.SIGKILL)
                for pump in pumps:
                    pump.join(timeout=term_grace_seconds)
            if feeder is not None:
                feeder.join(timeout=term_grace_seconds)

        stdout_file.flush()
        stderr_file.flush()
        captured_stdout = ""
        captured_stderr = ""
        if read_output:
            stdout_file.seek(0)
            stderr_file.seek(0)
            stdout_bytes = stdout_file.read(max_output_bytes + 1)
            stderr_bytes = stderr_file.read(max_output_bytes + 1)
            captured_stdout = stdout_bytes.decode("utf-8", errors="replace")
            captured_stderr = stderr_bytes.decode("utf-8", errors="replace")

    return ProcessResult(
        exit_code=process.returncode,
        timed_out=timed_out,
        interrupted=interrupted,
        output_truncated=budget.truncated,
        stdout=captured_stdout,
        stderr=captured_stderr,
    )
