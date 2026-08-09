import json, os, pathlib, subprocess, urllib.request
from conftest import clean_env, run, status_json, wait_until


def _health_ok(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as r:
            return json.loads(r.read())["status"] == "ok"
    except Exception:
        return False


def test_background_ephemeral_prints_exactly_one_usable_json_object(binary):
    p = run(binary, "serve", "--background", "--ephemeral", "--insecure-cookies")
    assert p.returncode == 0, p.stderr
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    assert len(lines) == 1, f"expected one JSON object on stdout, got {p.stdout!r}"
    obj = json.loads(lines[0])
    assert set(obj) == {"url", "port", "data_dir", "pid"}
    assert obj["url"] == f"http://127.0.0.1:{obj['port']}"
    assert "zigbase-ephemeral-" in obj["data_dir"]
    try:
        assert _health_ok(obj["port"])
        st, code = status_json(binary, obj["data_dir"])
        assert code == 0 and st["ephemeral"] is True
    finally:
        run(binary, "serve", "stop", "--data-dir", obj["data_dir"])
    # The tempdir belongs to the session and goes away with it.
    assert not pathlib.Path(obj["data_dir"]).exists()


def test_foreground_ephemeral_announces_itself_and_cleans_up_on_shutdown(binary):
    proc = subprocess.Popen(
        [binary, "serve", "--ephemeral", "--insecure-cookies"],
        env=clean_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = proc.stdout.readline()
        obj = json.loads(line)
        assert _health_ok(obj["port"])
    finally:
        proc.terminate()
        proc.wait(timeout=15)
    assert not pathlib.Path(obj["data_dir"]).exists()


def test_explicit_data_dir_and_port_win_over_ephemeral_allocation(binary, data_dir):
    """The composition rule: --ephemeral fills in only what was NOT specified."""
    from conftest import free_port
    port = free_port()
    p = run(binary, "serve", "--background", "--ephemeral", "--insecure-cookies",
            "--data-dir", data_dir, "--http-port", str(port))
    assert p.returncode == 0, p.stderr
    obj = json.loads(p.stdout.strip())
    assert obj["port"] == port
    assert obj["data_dir"] == str(pathlib.Path(data_dir).resolve())
    run(binary, "serve", "stop", "--data-dir", data_dir)
    # NOT deleted: the prefix guard refuses a dir that is not one of ours, even
    # though the session was flagged ephemeral.
    assert pathlib.Path(data_dir).exists()
