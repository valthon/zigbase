"""End-to-end coverage for the `zigbase serve` session lifecycle (SP-3).

These drive real processes: they start, inspect, kill -9, and stop servers.
Everything pure lives in Zig unit tests (src/serve_session.zig,
src/serve_control.zig); what is here is what only a real fork can prove.
"""
import json, os, pathlib, signal, subprocess, time
import urllib.error, urllib.request

import pytest

from conftest import clean_env, free_port, run, status_json, wait_running, wait_until


def _health(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as r:
            return json.loads(r.read())
    except Exception:
        return None


def test_background_start_status_logs_stop(binary, data_dir):
    port = free_port()
    p = run(binary, "serve", "--background", "--insecure-cookies",
            "--data-dir", data_dir, "--http-port", str(port))
    # The parent exits 0 ONLY on real readiness, so the server must answer the
    # instant this returns — no sleep, no retry. That is the whole handshake.
    assert p.returncode == 0, p.stderr
    assert _health(port)["status"] == "ok"
    assert "running in the background" in p.stderr

    st, code = status_json(binary, data_dir)
    assert code == 0
    assert st["running"] is True and st["starting"] is False
    assert st["port"] == port and st["background"] is True and st["healthy"] is True
    assert st["pid"] > 0 and st["ephemeral"] is False

    logs = run(binary, "serve", "logs", "--data-dir", data_dir)
    assert logs.returncode == 0
    assert "zigbase listening" in logs.stdout

    stop = run(binary, "serve", "stop", "--data-dir", data_dir)
    assert stop.returncode == 0
    assert _health(port) is None
    # serve.json is gone; serve.lock is permanent by design.
    assert not (pathlib.Path(data_dir) / "serve.json").exists()
    assert (pathlib.Path(data_dir) / "serve.lock").exists()

    st, code = status_json(binary, data_dir)
    assert code == 1 and st == {"running": False, "starting": False}


def test_stop_is_idempotent(binary, data_dir):
    # Nothing running at all: friendly success, not an error.
    first = run(binary, "serve", "stop", "--data-dir", data_dir)
    assert first.returncode == 0

    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    assert run(binary, "serve", "stop", "--data-dir", data_dir).returncode == 0
    # Stopping an already-stopped session is success too.
    assert run(binary, "serve", "stop", "--data-dir", data_dir).returncode == 0


def test_kill_9_session_reads_as_gone_not_stale(binary, data_dir):
    """flock liveness is the point: a SIGKILLed server leaves serve.json behind,
    and the next status must report 'not running' rather than trusting the file."""
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    st, _ = status_json(binary, data_dir)
    pid = st["pid"]

    os.kill(pid, signal.SIGKILL)
    assert wait_until(lambda: _health(port) is None)

    st, code = status_json(binary, data_dir)
    assert code == 1 and st["running"] is False and st["starting"] is False
    # And the data dir is claimable again immediately.
    port2 = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port2)).returncode == 0
    run(binary, "serve", "stop", "--data-dir", data_dir)


def test_duplicate_start_is_refused_and_ignore_lock_is_the_escape_hatch(binary, data_dir):
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    try:
        dup = run(binary, "serve", "--insecure-cookies",
                  "--data-dir", data_dir, "--http-port", str(free_port()), timeout=30)
        assert dup.returncode != 0
        assert "already owns the data dir" in dup.stderr
        # The message must name every way out, or it is not actionable.
        for hint in ("serve status", "serve stop", "--ignore-lock"):
            assert hint in dup.stderr

        # --ignore-lock starts an UNTRACKED instance: it runs, and status still
        # reports the tracked one.
        port2 = free_port()
        untracked = subprocess.Popen(
            [binary, "serve", "--insecure-cookies", "--ignore-lock",
             "--data-dir", data_dir, "--http-port", str(port2)],
            env=clean_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert wait_until(lambda: _health(port2) is not None)
            st, code = status_json(binary, data_dir)
            assert code == 0 and st["port"] == port  # the TRACKED session, not the untracked one
        finally:
            untracked.terminate()
            untracked.wait(timeout=10)
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_background_and_ignore_lock_conflict_at_parse_time(binary, data_dir):
    # src/cli.zig:466 rejects --background + --ignore-lock at parse time
    # (ParseError.ConflictingFlags); framework.zig's runCliImpl now exits
    # non-zero on every parse error (std.process.exit(1) after printing
    # usage) instead of the bare `return;` that used to silently exit 0 —
    # fixed alongside this suite (was xfail'd; see task-11-report.md).
    p = run(binary, "serve", "--background", "--ignore-lock", "--data-dir", data_dir)
    assert p.returncode != 0
    # It must fail FAST — before spawning anything — not after a 30s stall.
    assert not (pathlib.Path(data_dir) / "serve.json").exists()


def test_background_reports_a_child_that_dies_during_boot(binary, data_dir, tmp_path):
    """A port already in use makes the child die before publishing. The parent
    must say so and print the log tail, not sit through the 30s timeout."""
    port = free_port()
    squatter = subprocess.Popen(["python3", "-c",
        f"import socket,time;s=socket.socket();s.setsockopt(1,2,1);"
        f"s.bind(('127.0.0.1',{port}));s.listen(1);time.sleep(60)"])
    try:
        start = time.time()
        p = run(binary, "serve", "--background", "--insecure-cookies",
                "--data-dir", data_dir, "--http-port", str(port), timeout=45)
        elapsed = time.time() - start
        assert p.returncode == 1
        assert "exited before becoming ready" in p.stderr
        assert "last" in p.stderr and "bytes of" in p.stderr  # the log tail
        assert elapsed < 25, f"took {elapsed:.1f}s — it waited out the timeout instead of noticing the death"
    finally:
        squatter.terminate()
        squatter.wait(timeout=10)


def test_agent_env_backgrounds_automatically_and_names_the_opt_out(binary, data_dir):
    port = free_port()
    p = run(binary, "serve", "--insecure-cookies", "--data-dir", data_dir,
            "--http-port", str(port), env={"CLAUDECODE": "1"})
    try:
        assert p.returncode == 0
        assert "Claude Code" in p.stderr
        assert "ZIGBASE_SERVE_BACKGROUND=0" in p.stderr   # the opt-out is named
        assert _health(port)["status"] == "ok"
        st, _ = status_json(binary, data_dir)
        assert st["background"] is True
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_the_opt_out_env_beats_agent_detection(binary, data_dir):
    port = free_port()
    proc = subprocess.Popen(
        [binary, "serve", "--insecure-cookies", "--data-dir", data_dir, "--http-port", str(port)],
        env=clean_env({"CLAUDECODE": "1", "ZIGBASE_SERVE_BACKGROUND": "0"}),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        # It stayed in the FOREGROUND: the process is still running and did not
        # exit 0 the way a --background parent would.
        assert wait_until(lambda: _health(port) is not None)
        assert proc.poll() is None
        # wait_running (not a bare status_json): /api/health answers as soon as
        # the listener starts, which races the ~100ms-later write of serve.json
        # (see wait_running's docstring) — a foreground process has no external
        # parent forcing that handshake to complete first.
        st, _ = wait_running(binary, data_dir)
        assert st["background"] is False
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_logs_points_a_foreground_session_at_its_terminal(binary, data_dir):
    port = free_port()
    proc = subprocess.Popen(
        [binary, "serve", "--insecure-cookies", "--data-dir", data_dir, "--http-port", str(port)],
        env=clean_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        assert wait_until(lambda: _health(port) is not None)
        wait_running(binary, data_dir)  # close the health-vs-serve.json race; see conftest
        p = run(binary, "serve", "logs", "--data-dir", data_dir)
        assert p.returncode == 1
        assert "FOREGROUND" in p.stderr
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def _assert_all_json_lines(stream_text, what):
    """Every non-empty line must parse as JSON.

    `--log-format json` promises an NDJSON stream; a consumer piping it to `jq`
    or a log shipper breaks on the FIRST non-JSON line. Bare-text lines are the
    failure this guards, so report the offender verbatim.
    """
    bad = []
    for line in stream_text.splitlines():
        if not line.strip():
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError:
            bad.append(line)
    assert not bad, f"{what}: non-JSON line(s) in a --log-format json stream: {bad!r}"


def test_serve_refusal_log_line_honors_the_log_format_flag(binary, data_dir):
    """A refusal to start is an error-level LOG RECORD, so it must obey
    --log-format json like every other record.

    Regression guard for an ordering class, not just this one message: any
    std.log call emitted between the env-only pre-install and the flag-merged
    logging.apply() lands in the stream in the WRONG format, because only the
    env was consulted when it was written. This path is the strictest case —
    it never enters serveImpl at all (it returns SessionAlreadyRunning from the
    CLI arm), so the flag merge must happen before the arm's staging, not
    inside the server boot.
    """
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    try:
        dup = run(binary, "serve", "--insecure-cookies", "--log-format", "json",
                  "--data-dir", data_dir, "--http-port", str(free_port()), timeout=30)
        assert dup.returncode != 0
        # It really is the refusal we are formatting (not some earlier failure).
        assert "already owns the data dir" in dup.stderr
        _assert_all_json_lines(dup.stderr, "serve refusal")
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_untracked_warning_honors_the_log_format_flag(binary, data_dir):
    """Same ordering class as the refusal above, on the path that DOES boot:
    the --ignore-lock warning is emitted from the CLI arm before serveImpl, so
    it too must already see the flag-merged logging config."""
    port = free_port()
    log_path = pathlib.Path(data_dir) / "stderr.txt"
    with open(log_path, "w") as errfile:
        proc = subprocess.Popen(
            [binary, "serve", "--insecure-cookies", "--ignore-lock",
             "--log-format", "json", "--data-dir", data_dir, "--http-port", str(port)],
            env=clean_env(), stdout=subprocess.DEVNULL, stderr=errfile)
        try:
            assert wait_until(lambda: _health(port) is not None)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
    captured = log_path.read_text()
    carriers = [l for l in captured.splitlines() if "UNTRACKED" in l]
    assert carriers, "the --ignore-lock warning was never emitted at all"

    # Scoped deliberately to the line this test owns, NOT to "every line is
    # JSON": facil.io prints its own banner ("INFO: Listening on port ...",
    # "* Press ^C to stop", the shutdown notice) from C, straight to the fd,
    # never through Zig's std.log — so those lines are outside what
    # --log-format json can promise, and asserting on them here would make this
    # test fail for a reason it is not about.
    for line in carriers:
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            raise AssertionError(
                "the --ignore-lock warning was emitted as bare text inside a "
                f"--log-format json stream: {line!r}"
            )
        assert rec["level"] == "warn"
        assert "UNTRACKED" in rec["msg"]


def test_logs_json_filters_the_mixed_log_stream(binary, data_dir):
    """`serve logs --json` must yield a stream `jq` can eat.

    serve.log is genuinely mixed even with --log-format json: facil.io writes
    its banner ("INFO: Listening on port ...", "* Root pid: ...") straight to
    the fd from C, bypassing the log encoder. So this asserts BOTH directions —
    the plain form really does carry non-JSON lines (otherwise the flag would
    be a no-op and this test would be vacuous), and the --json form carries
    none while keeping the real records.
    """
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies", "--log-format", "json",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    try:
        plain = run(binary, "serve", "logs", "--data-dir", data_dir)
        assert plain.returncode == 0
        plain_lines = [l for l in plain.stdout.splitlines() if l.strip()]
        assert any(not l.lstrip().startswith("{") for l in plain_lines), (
            "expected serve.log to be a MIXED stream; if it is already pure JSON then "
            "--json has nothing to do and this test is asserting nothing"
        )

        js = run(binary, "serve", "logs", "--json", "--data-dir", data_dir)
        assert js.returncode == 0
        out = [l for l in js.stdout.splitlines() if l.strip()]
        assert out, "--json dropped everything, including the real records"
        for line in out:
            json.loads(line)  # every surviving line must parse
        # The records themselves survived the filter, not just some of them.
        assert len(out) == sum(1 for l in plain_lines if l.lstrip().startswith("{"))
        assert any("zigbase listening" in l for l in out)
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_logs_json_reports_a_log_file_with_no_records(binary, data_dir):
    """A text-format session filtered with --json would otherwise print nothing
    and look broken; it must explain itself instead."""
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies",
               "--data-dir", data_dir, "--http-port", str(port)).returncode == 0
    try:
        js = run(binary, "serve", "logs", "--json", "--data-dir", data_dir)
        assert not [l for l in js.stdout.splitlines() if l.strip()]
        assert "no JSON records" in js.stderr
        assert "--log-format json" in js.stderr  # names the actual fix
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_unwritable_data_dir_is_reported_as_permissions_not_a_busy_session(binary, data_dir):
    """A data dir we cannot create the lock file in must NOT be reported as
    "another session already owns it".

    This drives the FOREGROUND path deliberately. `--background` happens to
    report this case correctly by accident — the parent opens serve.log before
    it ever reaches the flock, so it fails earlier with the real errno — which
    is exactly why nothing caught the foreground path being wrong.
    """
    if os.geteuid() == 0:
        pytest.skip("root ignores directory permissions, so the failure cannot be provoked")
    os.chmod(data_dir, 0o500)
    try:
        p = run(binary, "serve", "--insecure-cookies", "--data-dir", data_dir,
                "--http-port", str(free_port()),
                env={"ZIGBASE_SERVE_BACKGROUND": "0"}, timeout=30)
        assert p.returncode != 0
        # The old message named a session that does not exist, and offered three
        # remedies none of which can help with a permissions problem.
        assert "already owns the data dir" not in p.stderr
        # It must name the real cause and a remedy that addresses it.
        assert "session lock file" in p.stderr
        assert "writable" in p.stderr
        assert "AccessDenied" in p.stderr
    finally:
        os.chmod(data_dir, 0o700)


def test_status_sweeps_the_tempdir_of_a_kill_9ed_ephemeral_session(binary):
    """docs/serve.md promises the next `serve stop` OR `serve status` against a
    dead session's data dir sweeps its tempdir. `stop` already did; `status`
    silently left it on disk."""
    p = run(binary, "serve", "--background", "--ephemeral", "--insecure-cookies")
    assert p.returncode == 0, p.stderr
    obj = json.loads(p.stdout.strip())
    d = pathlib.Path(obj["data_dir"])
    assert d.exists()

    os.kill(obj["pid"], signal.SIGKILL)  # no graceful cleanup runs
    assert wait_until(lambda: _health(obj["port"]) is None)
    assert d.exists(), "kill -9 should leave the tempdir behind; nothing has swept it yet"

    st, code = status_json(binary, str(d))
    assert code == 1 and st == {"running": False, "starting": False}
    assert not d.exists(), "serve status saw the dead session but left its tempdir on disk"
