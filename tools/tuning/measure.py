"""Linux-only synthetic health benchmark; launches ONLY explicitly supplied binaries.

Not an application-workload benchmark or evidence that a profile is optimal.
Each child uses fresh temporary SQLite state and a loopback HTTP listener.
"""
import argparse
import concurrent.futures
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error


def run_requests(request, requests, concurrency):
    """Keep at most concurrency futures pending, and drain failures before refill."""
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=concurrency)
    try:
        remaining = requests
        pending = set()
        samples = []
        while remaining or pending:
            while remaining and len(pending) < concurrency:
                pending.add(executor.submit(request))
                remaining -= 1
            done, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
            # Observe every completed result before scheduling replacement work.
            # A failed batch must not create more work after the failure is known.
            samples.extend(future.result() for future in done)
        return samples
    finally:
        # Cancel queued calls on failure; only in-flight (5s timeout) calls finish.
        executor.shutdown(wait=True, cancel_futures=True)


def measure(binary, candidate_id, revision, environment, requests, concurrency):
    binary = str(Path(binary).resolve(strict=True))
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    resources = json.loads(subprocess.check_output([binary, "resources"], env=env, timeout=10))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request():
        start = time.perf_counter()
        with opener.open(f"http://127.0.0.1:{port}/api/health", timeout=5) as response:
            body = json.loads(response.read(65536))
            if response.status != 200 or body.get("status") != "ok" or body.get("backend") != "sqlite":
                raise ValueError("unexpected workload response")
        return (time.perf_counter() - start) * 1000

    with tempfile.TemporaryDirectory(prefix="zigbase-tune-") as data:
        process = subprocess.Popen(
            [binary, "serve", "--http-host", "127.0.0.1", "--http-port", str(port),
             "--data-dir", data, "--insecure-cookies"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError("benchmark server exited during startup")
                try:
                    request()
                    break
                except urllib.error.HTTPError:
                    # HTTP responses are evidence of the wrong workload/state,
                    # not a listener that has not started accepting connections.
                    raise
                except (urllib.error.URLError, OSError):
                    time.sleep(0.05)
            else:
                raise RuntimeError("benchmark server did not become healthy")
            for _ in range(10):
                request()
            start = time.perf_counter()
            samples = run_requests(request, requests, concurrency)
            elapsed = time.perf_counter() - start
            if process.poll() is not None:
                raise RuntimeError("benchmark server exited during measurement")
            # Linux VmHWM is process RSS high water, including startup, not the
            # allocator-only peak_live reported by ZigBase microbenchmarks.
            try:
                status = Path(f"/proc/{process.pid}/status").read_text()
            except FileNotFoundError as error:
                raise RuntimeError("benchmark server status disappeared during RSS measurement") from error
            try:
                rss = next(int(line.split()[1]) * 1024 for line in status.splitlines() if line.startswith("VmHWM:"))
            except (StopIteration, ValueError, IndexError) as error:
                raise RuntimeError("benchmark server RSS measurement unavailable: missing or invalid VmHWM") from error
            samples.sort()
            return dict(id=candidate_id, workload=f"health-v1-n{requests}-c{concurrency}",
                        revision=revision, environment=environment,
                        measured_at_unix=int(time.time()), throughput_rps=requests / elapsed,
                        p95_ms=samples[math.ceil(requests * 0.95) - 1], peak_rss_bytes=rss,
                        failed_requests=0, resources=resources)
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", action="append", required=True, metavar="ID=BINARY")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--environment", required=True, help="machine/CPU limit/toolchain/optimization identity")
    parser.add_argument("--memory-budget-bytes", type=int, required=True)
    parser.add_argument("--p95-budget-ms", type=float, required=True)
    parser.add_argument("--requests", type=int, default=1000)
    parser.add_argument("--concurrency", type=int, default=4)
    args = parser.parse_args()
    if not (1 <= args.requests <= 100000 and 1 <= args.concurrency <= 64 and
            1 <= len(args.candidate) <= 128 and 1 <= args.memory_budget_bytes <= 2**64 - 1 and
            math.isfinite(args.p95_budget_ms) and args.p95_budget_ms > 0):
        parser.error("invalid measurement limits or budgets")
    def valid_label(value):
        # Match the comparator's UTF-8 byte bound and ASCII control exclusion.
        try:
            size = len(value.encode("utf-8"))
        except UnicodeError:
            return False
        return 1 <= size <= 256 and all(ord(c) >= 32 and ord(c) != 127 for c in value)

    if not valid_label(args.revision) or not valid_label(args.environment):
        parser.error("revision and environment must be 1..256 UTF-8 bytes without controls")
    planned = []
    ids = set()
    for entry in args.candidate:
        candidate_id, sep, binary = entry.partition("=")
        if not sep or not valid_label(candidate_id) or not binary or candidate_id in ids:
            parser.error("candidate must have a unique valid ID=BINARY (ID: 1..256 UTF-8 bytes without controls)")
        ids.add(candidate_id)
        planned.append((candidate_id, binary))
    # Resolve every binary before running even the first candidate.
    for _, binary in planned:
        path = Path(binary)
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f"candidate binary must be an executable file: {binary}")
    if not Path("/proc/self/status").exists():
        parser.error("measurement helper requires Linux /proc")
    candidates = []
    for candidate_id, binary in planned:
        candidates.append(measure(binary, candidate_id, args.revision, args.environment, args.requests, args.concurrency))
    print(json.dumps(dict(schema_version=1, workload=candidates[0]["workload"],
                          revision=args.revision, environment=args.environment,
                          max_age_seconds=86400, memory_budget_bytes=args.memory_budget_bytes,
                          p95_budget_ms=args.p95_budget_ms, candidates=candidates), allow_nan=False))


if __name__ == "__main__":
    main()
