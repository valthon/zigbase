#!/usr/bin/env python3
"""Bounded local project/task workload. See docs/testing.md#application-capacity.

Only launches an owned, temporary SQLite application; never targets an existing URL.
The standard-library client uses one HTTP connection per request (no keepalive).
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PASSWORD = "capacity-local-password"
MAX_RESPONSE = 2 * 1024 * 1024


class InvalidResponse(Exception):
    """The request returned, but did not perform the expected application operation."""


class Client:
    def __init__(self, base, token=None, account=None):
        self.base, self.token, self.account = base, token, account
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, method, path, data=None, expected=200):
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.account:
            headers["X-Account-Id"] = self.account
        request = urllib.request.Request(self.base + path, method=method, headers=headers,
                                         data=None if data is None else json.dumps(data).encode())
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if response.status != expected:
                raise InvalidResponse(f"http_{response.status}_expected_{expected}")
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise InvalidResponse("response_too_large")
            return json.loads(raw) if raw else None


def require(condition, reason):
    if not condition:
        raise InvalidResponse(reason)


def checked_task(record, tenant, task_id=None, title=None, expanded=False):
    require(isinstance(record, dict), "record_not_object")
    require(record.get("account") == tenant["account"], "wrong_task_account")
    require(record.get("project") == tenant["project"], "wrong_task_project")
    if task_id is not None:
        require(record.get("id") == task_id, "wrong_task_id")
    if title is not None:
        require(record.get("title") == title, "write_not_observed")
    if expanded:
        project = record.get("expand", {}).get("project")
        # Single relations are returned as objects, not a list of projects.
        require(isinstance(project, dict), "missing_project_expansion")
        require(project.get("id") == tenant["project"], "wrong_expanded_project")
        require(project.get("account") == tenant["account"], "cross_tenant_expansion")


def checked_list(body, tenant, count):
    require(isinstance(body, dict) and isinstance(body.get("items"), list), "invalid_list")
    require(len(body["items"]) == min(20, count), "wrong_list_length")
    ids = [r.get("id") for r in body["items"]]
    require(ids == sorted(set(ids)), "invalid_list_order_or_duplicates")
    for record in body["items"]:
        require(record.get("id") in tenant["tasks"], "unexpected_task")
        checked_task(record, tenant, expanded=True)


def command_json(binary, verb, env):
    result = subprocess.run([str(binary), verb, "--json"], env=env, capture_output=True,
                            text=True, timeout=30, check=True)
    return json.loads(result.stdout)


def clean_environment():
    # Do not inherit a production database, SMTP/S3 credentials, resource overrides,
    # or an agent's detached-process setting. Keep tool/OS settings only.
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    env.update(ZIGBASE_SERVE_BACKGROUND="0", ZIGBASE_RATE_LIMIT_MAX="0",
               ZIGBASE_LOG_REQUESTS="false")
    return env


@contextmanager
def server(binary):
    env = clean_environment()
    with tempfile.TemporaryDirectory(prefix="zigbase-capacity-") as directory:
        data = Path(directory)
        env["ZIGBASE_DATA_DIR"] = directory
        subprocess.run([str(binary), "superuser", "create", "--email", "admin@capacity.test",
                        "--password", PASSWORD], env=env, check=True, capture_output=True, timeout=30)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env.update(ZIGBASE_HTTP_HOST="127.0.0.1", ZIGBASE_HTTP_PORT=str(port))
        with (data / "server.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "serve", "--insecure-cookies"], env=env,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                client = Client(f"http://127.0.0.1:{port}")
                deadline = time.monotonic() + 20
                while True:
                    if process.poll() is not None:
                        raise RuntimeError("capacity server exited during startup")
                    try:
                        require(client.call("GET", "/api/health").get("status") == "ok", "not_ready")
                        break
                    except (OSError, ValueError, InvalidResponse):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("capacity server did not become ready")
                        time.sleep(.05)
                yield client, data, process, env
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def seed(client, data, tenants, tasks):
    admin = Client(client.base, client.call("POST", "/api/collections/_superusers/auth-with-password",
                   {"identity": "admin@capacity.test", "password": PASSWORD})["token"])
    result = []
    for n in range(tenants):
        account = f"capacity{n:04d}"
        email = f"member{n}@capacity.test"
        user = admin.call("POST", "/api/collections/users/records",
                          {"email": email, "password": PASSWORD}, 201)
        # Membership provisioning is deliberately outside the timed workload. The
        # native tenancy engine consumes these rows during every measured request.
        with sqlite3.connect(data / "data.db") as db:
            db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES(?,?,?,?)",
                       (account, "2026-01-01", "2026-01-01", account))
            db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) "
                       "VALUES(?,?,?,?,?,?,?,?)", (f"membership{n:04d}", "2026-01-01", "2026-01-01",
                                                 account, "users", user["id"], "editor", "active"))
        project = admin.call("POST", "/api/collections/projects/records",
                             {"account": account, "title": f"Project {n}"}, 201)
        records = [admin.call("POST", "/api/collections/tasks/records",
                             {"account": account, "project": project["id"], "title": f"Task {i}"}, 201)
                   for i in range(tasks)]
        token = client.call("POST", "/api/collections/users/auth-with-password",
                            {"identity": email, "password": PASSWORD})["token"]
        result.append({"account": account, "project": project["id"], "token": token,
                       "tasks": [r["id"] for r in records]})
    return result


def isolation(base, tenants, count):
    for index, tenant in enumerate(tenants):
        own = Client(base, tenant["token"], tenant["account"])
        other = tenants[(index + 1) % len(tenants)]
        checked_list(own.call("GET", "/api/collections/tasks/records?sort=id&limit=20&expand=project"), tenant, count)
        foreign = "/api/collections/tasks/records/" + other["tasks"][0]
        own.call("GET", foreign + "?expand=project", expected=404)
        own.call("PATCH", foreign, {"title": "forbidden"}, expected=404)
        Client(base, tenant["token"], other["account"]).call("GET", foreign, expected=404)
        Client(base).call("GET", foreign, expected=404)


def process_usage(pid):
    """Linux process counters; None elsewhere, never substitutes client RSS."""
    if sys.platform != "linux":
        return None
    status = Path(f"/proc/{pid}/status").read_text()
    rss = next(int(line.split()[1]) * 1024 for line in status.splitlines() if line.startswith("VmRSS:"))
    stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    cpu = (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK")
    return {"rss_bytes": rss, "cpu_seconds": cpu}


def distribution(samples):
    ordered = sorted(samples)
    if not ordered:
        return None
    return {key: ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]
            for key, fraction in [("p50", .5), ("p95", .95), ("p99", .99), ("max", 1)]}


def workload(base, tenants, args, duration, request_limit, pid, phase):
    start = time.monotonic()
    deadline = start + duration
    stop = threading.Event()
    usage_before = process_usage(pid)
    rss = [usage_before["rss_bytes"]] if usage_before else []

    def sample():
        while not stop.wait(.05):
            usage = process_usage(pid)
            if usage:
                rss.append(usage["rss_bytes"])

    def worker(index):
        tenant = tenants[index % len(tenants)]
        task = tenant["tasks"][index // len(tenants)]
        client = Client(base, tenant["token"], tenant["account"])
        path = "/api/collections/tasks/records/" + task
        quota = request_limit // args.concurrency + (index < request_limit % args.concurrency)
        samples = {op: [] for op in ("list_expand", "update", "read_expand")}
        errors = Counter()
        title = None
        successes = 0
        for sequence in range(quota):
            if time.monotonic() >= deadline:
                break
            operation = ("list_expand", "update", "read_expand")[sequence % 3]
            began = time.perf_counter_ns()
            try:
                if operation == "list_expand":
                    checked_list(client.call("GET", "/api/collections/tasks/records?sort=id&limit=20&expand=project"), tenant, args.tasks)
                elif operation == "update":
                    wanted = f"{phase}-worker-{index}-revision-{sequence}"
                    record = client.call("PATCH", path, {"title": wanted})
                    checked_task(record, tenant, task, wanted)
                    title = wanted
                else:
                    checked_task(client.call("GET", path + "?expand=project"), tenant, task, title, True)
                successes += 1
            except (OSError, ValueError, KeyError, TypeError, InvalidResponse) as error:
                # Keep labels bounded and free of response bodies/tokens.
                label = str(error) if isinstance(error, InvalidResponse) else type(error).__name__
                errors[operation + ":" + label] += 1
            samples[operation].append((time.perf_counter_ns() - began) / 1e6)
        return samples, errors, successes, (tenant, task, title)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    try:
        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            results = list(executor.map(worker, range(args.concurrency)))
    finally:
        stop.set()
        sampler.join()
    elapsed = time.monotonic() - start
    usage_after = process_usage(pid)
    if usage_after:
        rss.append(usage_after["rss_bytes"])
    combined = {op: [] for op in ("list_expand", "update", "read_expand")}
    errors = Counter()
    successful = 0
    for samples, failures, succeeded, _ in results:
        for op, values in samples.items():
            combined[op].extend(values)
        errors.update(failures)
        successful += succeeded
    attempts = sum(len(v) for v in combined.values())
    # Outside timing: confirm the last acknowledged write remains visible. This
    # also catches a response that echoes a mutation without persisting it.
    for _, _, _, (tenant, task, title) in results:
        if title is not None:
            checked_task(Client(base, tenant["token"], tenant["account"]).call(
                "GET", "/api/collections/tasks/records/" + task), tenant, task, title)
    return {"elapsed_seconds_including_drain": elapsed, "requested_seconds": duration,
            "request_limit": request_limit, "limit_reached": attempts == request_limit,
            "attempts": attempts, "successful_requests": successful,
            "successful_requests_per_second": successful / elapsed,
            "errors": dict(errors), "latency_ms_including_failures": {
                op: {"count": len(values), "nearest_rank": distribution(values)} for op, values in combined.items()},
            "server": {"sample_interval_ms": 50, "rss_samples": len(rss),
                       "peak_sampled_rss_bytes": max(rss) if rss else None,
                       "cpu_seconds": usage_after["cpu_seconds"] - usage_before["cpu_seconds"] if usage_before else None}}


def machine_info():
    info = {"platform": platform.platform(), "machine": platform.machine(),
            "logical_cpus": os.cpu_count(),
            "cpu_affinity_count": len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None}
    if sys.platform == "linux":
        cpu = Path("/proc/cpuinfo").read_text()
        info["cpu_model"] = next((line.split(":", 1)[1].strip() for line in cpu.splitlines()
                                  if line.startswith("model name")), None)
        info["system_memory_bytes"] = next(int(line.split()[1]) * 1024 for line in
                                           Path("/proc/meminfo").read_text().splitlines()
                                           if line.startswith("MemTotal:"))
        # Root cgroup observations are context, not a claim about all ancestor limits.
        info["cgroup_root"] = {name: (Path("/sys/fs/cgroup") / name).read_text().strip()
                               for name in ("cpu.max", "memory.max")
                               if (Path("/sys/fs/cgroup") / name).is_file()}
    return info


def bounded_int(low, high):
    def parse(value):
        number = int(value)
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"must be in {low}..{high}")
        return number
    return parse


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--tenants", type=bounded_int(2, 16), default=2)
    parser.add_argument("--tasks", type=bounded_int(1, 1000), default=100, help="tasks per tenant")
    parser.add_argument("--concurrency", type=bounded_int(1, 64), default=4)
    parser.add_argument("--seconds", type=bounded_int(1, 300), default=10)
    parser.add_argument("--warmup", type=bounded_int(0, 30), default=2)
    parser.add_argument("--max-requests", type=bounded_int(3, 200000), default=100000)
    args = parser.parse_args(argv)
    if args.concurrency > args.tenants * args.tasks:
        parser.error("concurrency must not exceed tenant task count (one writer per task)")
    if args.max_requests < args.concurrency * 3:
        parser.error("max-requests must allow a complete three-operation cycle per worker")
    return args


def run(args):
    binary = args.binary.resolve(strict=True)
    with server(binary) as (client, data, process, env):
        resources = command_json(binary, "resources", env)
        version = command_json(binary, "version", env)
        tenants = seed(client, data, args.tenants, args.tasks)
        isolation(client.base, tenants, args.tasks)
        warmup = workload(client.base, tenants, args, args.warmup, min(10000, args.max_requests), process.pid, "warmup") if args.warmup else None
        measured = workload(client.base, tenants, args, args.seconds, args.max_requests, process.pid, "measurement")
        isolation(client.base, tenants, args.tasks)
        with sqlite3.connect(data / "data.db") as db:
            indexes = db.execute("SELECT name,sql FROM sqlite_master WHERE type='index' AND tbl_name IN ('tasks','projects') ORDER BY name").fetchall()
        report = {"schema_version": 1, "scenario": "tenant-project-tasks-v1",
                  "passed": not measured["errors"] and not (warmup and warmup["errors"])
                            and all(row["count"] > 0 for row in measured["latency_ms_including_failures"].values()),
                  "recorded_at": datetime.now(timezone.utc).isoformat(),
                  "harness": {"python": platform.python_version(), "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                              "fixture_source_sha256": hashlib.sha256((ROOT / "fixtures/application-capacity/main.zig").read_bytes()).hexdigest()},
                  "binary": {"sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                             "bytes": binary.stat().st_size, "version": version, "resources": resources},
                  "machine": machine_info(),
                  "dataset": {"tenants": args.tenants, "projects": args.tenants,
                              "tasks_per_tenant": args.tasks, "indexes": indexes},
                  "load": {"concurrency": args.concurrency, "model": "closed-loop, one connection per request",
                           "mix": ["list 20 tasks + project expansion", "update one task", "read task + project expansion"],
                           "timeout_seconds": 5, "response_limit_bytes": MAX_RESPONSE},
                  "isolation_before_and_after": "passed", "warmup": warmup, "measurement": measured,
                  "data_files_bytes_after": {p.name: p.stat().st_size for p in data.iterdir() if p.name.startswith("data.db")},
                  "limitations": ["local SQLite, one server process; no PostgreSQL or replicas",
                                  "client and server share hardware; Python client may bottleneck",
                                  "closed-loop load omits queue delay from an open-loop arrival stream",
                                  "no realtime, jobs, uploads, login churn, saturation or recovery qualification",
                                  "RSS samples may miss transient peaks; CPU/RSS are Linux process-only",
                                  "dataset and page cache are warm; setup and verification excluded from timing",
                                  "fixture/harness source hashes describe the runner checkout, not proof of binary provenance; preserve your build command and clean revision"]}
        return report


def main(argv=None):
    args = arguments(argv)
    try:
        report = run(args)
    except (OSError, ValueError, InvalidResponse, RuntimeError, subprocess.SubprocessError) as error:
        # No success-shaped throughput report for a failed setup/semantic postcheck.
        print(json.dumps({"schema_version": 1, "passed": False, "error": type(error).__name__ + ": " + str(error)}))
        return 1
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
