"""End-to-end tests for the public feature-state projection (#130).

`GET /api/state?subject=<id>` is UNAUTHENTICATED and returns ONLY resolved values:
`{ "flags": { "<name>": <bool> }, "experiments": { "<name>": "<variant>" } }`. It must
never expose the `_kv` admin surface (keys/timestamps) or any superuser settings verb.

Two server flavors are exercised:
  - the stock `zigbase` binary (no declared flags) — empty projection, no-auth, no leak,
    and the read-only contract (admin verbs stay behind requireSuperuser);
  - the `dating-server` fixture binary (declares two flags + one experiment) — named
    flags/experiment resolve, deterministically, and reflect a superuser override.
"""

import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _wait_port(port):
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)


def _http(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def _raw_head(url):
    return _raw_request("HEAD", url)


def _raw_response(method, url):
    parsed = urllib.parse.urlsplit(url)
    with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as sock:
        target = parsed.path or "/"
        if parsed.query:
            target += f"?{parsed.query}"
        sock.sendall(
            f"{method} {target} HTTP/1.1\r\nHost: {parsed.hostname}\r\n"
            "Connection: close\r\n\r\n".encode()
        )
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    head, body = b"".join(chunks).split(b"\r\n\r\n", 1)
    lines = head.decode("iso-8859-1").split("\r\n")
    status = int(lines[0].split()[1])
    headers = [
        (name.lower(), value.strip())
        for name, value in (line.split(":", 1) for line in lines[1:] if ":" in line)
    ]
    return status, headers, body


def _raw_request(method, url):
    status, header_items, body = _raw_response(method, url)
    return status, dict(header_items), body


def _assert_head_parity(url, expected_status, expected_content_type="application/json"):
    get_status, get_body = _http("GET", url)
    head_status, headers, wire_body = _raw_head(url)
    assert get_status == expected_status
    assert head_status == get_status
    assert headers["content-type"].startswith(expected_content_type)
    assert int(headers["content-length"]) == len(get_body.encode())
    assert wire_body == b""


# ---------------------------------------------------------------------------
# Stock binary: declares NO flags/experiments (R2-1 evicted the demo ones into
# fixtures/features) — empty projection, public, no leakage.
# ---------------------------------------------------------------------------


def test_state_public_no_auth_returns_resolved_shape(server):
    # No Authorization header at all — the endpoint is public.
    status, body = _http("GET", f"{server}/api/state?subject=anon")
    assert status == 200, body
    doc = json.loads(body)
    # Exactly two keys, both objects; values are RESOLVED (booleans / variant strings).
    assert set(doc.keys()) == {"flags", "experiments"}
    # The stock binary declares nothing — empty projection.
    assert doc["flags"] == {}
    assert doc["experiments"] == {}
    # Must NOT leak the _kv admin surface (raw keys / timestamps / key prefixes /
    # declared defaults / weights).
    for forbidden in (
        '"key"',
        '"created"',
        '"updated"',
        "flag:",
        "exp:",
        '"default"',
        '"weights"',
        '"variants"',
    ):
        assert forbidden not in body, forbidden


def test_state_does_not_expose_admin_verbs_or_settings(server):
    # The public route is read-only: a write verb must never succeed there.
    status, _ = _http("PUT", f"{server}/api/state", body={"value": "x"})
    assert status in (404, 405)
    # The superuser settings/KV surface stays locked without a token.
    status, _ = _http("GET", f"{server}/api/settings")
    assert status == 403


@pytest.fixture(scope="session")
def feature_route_binaries():
    binaries = {}
    for mode in ("remapped", "disabled"):
        env_name = f"ZIGBASE_TEST_FEATURE_{mode.upper()}_BINARY"
        override = os.environ.get(env_name)
        if override:
            path = pathlib.Path(override)
            if not path.exists():
                raise FileNotFoundError(f"{env_name}={override} does not exist")
        else:
            step = f"feature-{mode}-fixture"
            subprocess.run(ZIG + ["build", step], cwd=REPO, check=True)
            path = REPO / "zig-out" / "bin" / step
        binaries[mode] = path
    return binaries


def test_feature_head_is_bodyless_for_default_remapped_and_disabled(
    server, feature_route_binaries
):
    _assert_head_parity(f"{server}/api/state?subject=head", 200)

    for mode, path, expected_status in (
        ("remapped", "/public/features?subject=head", 200),
        ("remapped", "/api/state?subject=head", 200),
        ("disabled", "/api/state?subject=head", 200),
    ):
        with tempfile.TemporaryDirectory(prefix=f"zb_feature_{mode}_") as data:
            port = _free_port()
            proc = subprocess.Popen(
                [
                    str(feature_route_binaries[mode]),
                    "serve",
                    "--http-port",
                    str(port),
                    "--data-dir",
                    data,
                ],
                env={
                    **os.environ,
                    "ZIGBASE_SERVE_BACKGROUND": "0",
                    "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef",
                },
            )
            try:
                _wait_port(port)
                content_type = (
                    "text/plain"
                    if path.startswith("/api/state")
                    else "application/json"
                )
                _assert_head_parity(
                    f"http://127.0.0.1:{port}{path}", expected_status, content_type
                )

                if path.startswith("/api/state"):
                    status, body = _http("GET", f"http://127.0.0.1:{port}{path}")
                    assert status == 200
                    assert body == "consumer-state"

                if mode == "remapped":
                    for custom_path, custom_status, representation_length in (
                        (
                            "/custom/head-success",
                            200,
                            len(b"custom-head-representation"),
                        ),
                        ("/custom/head-error", 500, None),
                    ):
                        status, headers, wire_body = _raw_head(
                            f"http://127.0.0.1:{port}{custom_path}"
                        )
                        assert status == custom_status
                        assert wire_body == b""
                        assert int(headers["content-length"]) > 0
                        if representation_length is not None:
                            assert (
                                int(headers["content-length"]) == representation_length
                            )

                    status, headers, wire_body = _raw_head(
                        f"http://127.0.0.1:{port}/custom/no-content"
                    )
                    assert status == 204
                    assert "content-length" not in headers
                    assert "transfer-encoding" not in headers
                    assert wire_body == b""

                    for method in ("HEAD", "POST"):
                        _, header_items, _ = _raw_response(
                            method,
                            f"http://127.0.0.1:{port}/custom/no-content",
                        )
                        dates = [
                            value for name, value in header_items if name == "date"
                        ]
                        assert dates == ["Thu, 01 Jan 1970 00:00:00 GMT"]

                    status, headers, wire_body = _raw_head(
                        f"http://127.0.0.1:{port}/custom/not-modified"
                    )
                    assert status == 304
                    assert headers.get("content-length") == "9"
                    assert "transfer-encoding" not in headers
                    assert wire_body == b""

                    status, headers, wire_body = _raw_request(
                        "POST", f"http://127.0.0.1:{port}/custom/no-content"
                    )
                    assert status == 204
                    assert "content-length" not in headers
                    assert "transfer-encoding" not in headers
                    assert wire_body == b""

                    for method in ("HEAD", "POST"):
                        status, headers, wire_body = _raw_request(
                            method,
                            f"http://127.0.0.1:{port}/custom/reset-content",
                        )
                        assert status == 205
                        assert headers.get("content-length") == "0"
                        assert "transfer-encoding" not in headers
                        assert wire_body == b""

                    for method in ("GET", "POST"):
                        status, headers, wire_body = _raw_request(
                            method,
                            f"http://127.0.0.1:{port}/custom/wrong-framing",
                        )
                        assert status == 200
                        assert headers.get("content-length") == "6"
                        assert "transfer-encoding" not in headers
                        assert "trailer" not in headers
                        assert wire_body == b"framed"

                    status, headers, wire_body = _raw_head(
                        f"http://127.0.0.1:{port}/custom/owned-file"
                    )
                    assert status == 200
                    assert headers.get("content-length") == "7"
                    assert wire_body == b""

                    missing_body_length = None
                    for method in ("GET", "HEAD"):
                        status, header_items, wire_body = _raw_response(
                            method,
                            f"http://127.0.0.1:{port}/custom/missing-owned-file",
                        )
                        headers = dict(header_items)
                        assert status == 404
                        if method == "GET":
                            missing_body_length = len(wire_body)
                            assert json.loads(wire_body)["code"] == "not_found"
                        else:
                            assert wire_body == b""
                        assert int(headers["content-length"]) == missing_body_length
                        header_names = [name for name, _ in header_items]
                        assert header_names.count("content-length") == 1
                        assert header_names.count("content-type") == 1
                        assert not {
                            "accept-ranges",
                            "content-range",
                            "etag",
                        }.intersection(header_names)

                    for method, path in (
                        ("GET", "/custom/early-hints"),
                        ("HEAD", "/custom/early-hints"),
                        ("GET", "/custom/informational-unnamed"),
                        ("GET", "/custom/status-unsupported"),
                        ("POST", "/custom/not-modified"),
                    ):
                        status, header_items, wire_body = _raw_response(
                            method, f"http://127.0.0.1:{port}{path}"
                        )
                        headers = dict(header_items)
                        assert status == 500
                        assert headers["content-type"].startswith("application/json")
                        assert int(headers["content-length"]) > 0
                        assert "transfer-encoding" not in headers
                        if method == "HEAD":
                            assert wire_body == b""
                        else:
                            assert json.loads(wire_body)["code"] == "internal"
                        if path == "/custom/status-unsupported":
                            assert any(
                                value.startswith("invalid-status=kept")
                                for name, value in header_items
                                if name == "set-cookie"
                            )
            finally:
                proc.terminate()
                proc.wait(timeout=10)


def test_invalid_handler_status_logs_the_normalized_wire_status(feature_route_binaries):
    with tempfile.TemporaryDirectory(prefix="zb_invalid_status_") as data:
        port = _free_port()
        log_path = pathlib.Path(data) / "server.log"
        with log_path.open("w") as log:
            proc = subprocess.Popen(
                [
                    str(feature_route_binaries["remapped"]),
                    "serve",
                    "--http-port",
                    str(port),
                    "--data-dir",
                    data,
                    "--log-format",
                    "json",
                ],
                env={
                    **os.environ,
                    "ZIGBASE_SERVE_BACKGROUND": "0",
                    "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef",
                },
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                _wait_port(port)
                long_path = "/custom/status-unsupported/" + "x" * 256
                for path in ("/custom/status-unsupported", long_path):
                    status, body = _http(
                        "GET", f"http://127.0.0.1:{port}{path}"
                    )
                    assert status == 500
                    assert json.loads(body)["code"] == "internal"
                time.sleep(0.2)
            finally:
                proc.terminate()
                proc.wait(timeout=10)

        log_text = log_path.read_text()
        records = [
            json.loads(line)
            for line in log_text.splitlines()
            if line.strip().startswith("{")
        ]
        request = next(
            record
            for record in records
            if record.get("msg") == "request"
            and record.get("path") == "/custom/status-unsupported"
        )
        assert request["status"] == 500
        assert (
            "route returned invalid final status 799 for GET "
            "/custom/status-unsupported" in log_text
        )
        long_message = f"route returned invalid final status 799 for GET {long_path}"
        assert long_message in log_text
        assert f"fixture observed InvalidResponseStatus: {long_message}" in log_text


# ---------------------------------------------------------------------------
# Configured app (dating-server: 2 flags + 1 experiment): resolution + override.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def dating_binary():
    subprocess.run(ZIG + ["build", "dating-server"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "dating-server"
    assert path.exists(), f"dating-server not built at {path}"
    return str(path)


@pytest.fixture()
def dating_server(dating_binary):
    data = tempfile.mkdtemp(prefix="zb_state_")
    subprocess.run(
        [
            dating_binary,
            "superuser",
            "create",
            "--email",
            "admin@x.io",
            "--password",
            "adminpassword",
            "--data-dir",
            data,
        ],
        check=True,
    )
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    proc = subprocess.Popen(
        [dating_binary, "serve", "--insecure-cookies"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    _wait_port(port)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        shutil.rmtree(data, ignore_errors=True)


def _su_token(base):
    status, body = _http(
        "POST",
        f"{base}/api/collections/_superusers/auth-with-password",
        body={"identity": "admin@x.io", "password": "adminpassword"},
    )
    assert status == 200, body
    return json.loads(body)["token"]


def test_state_configured_app_resolves_declared_defaults(dating_server):
    status, body = _http("GET", f"{dating_server}/api/state?subject=user-42")
    assert status == 200, body
    doc = json.loads(body)
    # Declared flags resolve to their defaults (one bare-bool, one struct form).
    assert doc["flags"] == {"device_link_v2": False, "verbose_winks": True}
    # The experiment resolves to one of its declared variants.
    assert doc["experiments"]["discovery_ranking"] in ("recency", "affinity", "hybrid")
    # Still no admin/key leakage on the configured app.
    for forbidden in ('"created"', '"updated"', "flag:", "exp:"):
        assert forbidden not in body, forbidden


def test_state_reflects_superuser_override(dating_server):
    base = dating_server
    # Operator flips a DECLARED flag via the superuser settings API (writes flag:<name>).
    token = _su_token(base)
    status, _ = _http(
        "PUT",
        f"{base}/api/settings/flag:verbose_winks",
        token=token,
        body={"value": "false"},
    )
    assert status == 200
    # The public projection reflects the override — still WITHOUT any auth.
    status, body = _http("GET", f"{base}/api/state?subject=user-42")
    assert status == 200, body
    assert json.loads(body)["flags"]["verbose_winks"] is False


def test_state_experiment_is_deterministic_per_subject(dating_server):
    base = dating_server
    a = json.loads(_http("GET", f"{base}/api/state?subject=stable")[1])["experiments"][
        "discovery_ranking"
    ]
    b = json.loads(_http("GET", f"{base}/api/state?subject=stable")[1])["experiments"][
        "discovery_ranking"
    ]
    assert a == b


def test_state_sticky_experiment_survives_weight_override(dating_server):
    # `discovery_ranking` is a .sticky experiment: the public, unauthenticated /api/state
    # must return the PERSISTED variant for a seen subject even after a weight override
    # that would otherwise re-bucket it — proving the public path honors sticky and agrees
    # with App.experiment (and persists reader-first, without writer-storming on hits).
    base = dating_server
    subject = "sticky-seen-1"
    # First call (no auth) persists the assignment under the declared weights.
    seen = json.loads(_http("GET", f"{base}/api/state?subject={subject}")[1])[
        "experiments"
    ]["discovery_ranking"]
    assert seen in ("recency", "affinity", "hybrid")

    # Operator forces ALL future buckets to a different variant via a weight override.
    token = _su_token(base)
    forced = "recency" if seen != "recency" else "hybrid"
    weights = {"recency": "[100,0,0]", "affinity": "[0,100,0]", "hybrid": "[0,0,100]"}[
        forced
    ]
    status, _ = _http(
        "PUT",
        f"{base}/api/settings/exp:discovery_ranking:weights",
        token=token,
        body={"value": weights},
    )
    assert status == 200

    # The already-seen subject KEEPS its persisted variant (sticky), still without auth.
    after = json.loads(_http("GET", f"{base}/api/state?subject={subject}")[1])[
        "experiments"
    ]["discovery_ranking"]
    assert after == seen
    # A brand-new subject under the override DOES follow the new weights (override is live).
    fresh = json.loads(_http("GET", f"{base}/api/state?subject=sticky-new-1")[1])[
        "experiments"
    ]["discovery_ranking"]
    assert fresh == forced
