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


# ---------------------------------------------------------------------------
# Stock binary: resolves its sample declared flags/experiments, public, no leakage.
# (src/main.zig ships .flags = { dark_mode, maintenance }, .experiments = { onboarding_flow }.)
# ---------------------------------------------------------------------------

def test_state_public_no_auth_returns_resolved_shape(server):
    # No Authorization header at all — the endpoint is public.
    status, body = _http("GET", f"{server}/api/state?subject=anon")
    assert status == 200, body
    doc = json.loads(body)
    # Exactly two keys, both objects; values are RESOLVED (booleans / variant strings).
    assert set(doc.keys()) == {"flags", "experiments"}
    # The stock binary's sample declarations resolve to their defaults.
    assert doc["flags"] == {"dark_mode": False, "maintenance": False}
    assert doc["experiments"]["onboarding_flow"] in ("control", "streamlined")
    # Must NOT leak the _kv admin surface (raw keys / timestamps / key prefixes /
    # declared defaults / weights).
    for forbidden in ('"key"', '"created"', '"updated"', "flag:", "exp:",
                      '"default"', '"weights"', '"variants"'):
        assert forbidden not in body, forbidden


def test_state_does_not_expose_admin_verbs_or_settings(server):
    # The public route is read-only: a write verb must never succeed there.
    status, _ = _http("PUT", f"{server}/api/state", body={"value": "x"})
    assert status in (404, 405)
    # The superuser settings/KV surface stays locked without a token.
    status, _ = _http("GET", f"{server}/api/settings")
    assert status == 403


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
        [dating_binary, "superuser", "create", "--email", "admin@x.io",
         "--password", "adminpassword", "--data-dir", data],
        check=True,
    )
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    proc = subprocess.Popen(
        [dating_binary, "serve", "--insecure-cookies"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
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
        "POST", f"{base}/api/collections/_superusers/auth-with-password",
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
    status, _ = _http("PUT", f"{base}/api/settings/flag:verbose_winks", token=token,
                      body={"value": "false"})
    assert status == 200
    # The public projection reflects the override — still WITHOUT any auth.
    status, body = _http("GET", f"{base}/api/state?subject=user-42")
    assert status == 200, body
    assert json.loads(body)["flags"]["verbose_winks"] is False


def test_state_experiment_is_deterministic_per_subject(dating_server):
    base = dating_server
    a = json.loads(_http("GET", f"{base}/api/state?subject=stable")[1])["experiments"]["discovery_ranking"]
    b = json.loads(_http("GET", f"{base}/api/state?subject=stable")[1])["experiments"]["discovery_ranking"]
    assert a == b


def test_state_sticky_experiment_survives_weight_override(dating_server):
    # `discovery_ranking` is a .sticky experiment: the public, unauthenticated /api/state
    # must return the PERSISTED variant for a seen subject even after a weight override
    # that would otherwise re-bucket it — proving the public path honors sticky and agrees
    # with App.experiment (and persists reader-first, without writer-storming on hits).
    base = dating_server
    subject = "sticky-seen-1"
    # First call (no auth) persists the assignment under the declared weights.
    seen = json.loads(_http("GET", f"{base}/api/state?subject={subject}")[1])["experiments"]["discovery_ranking"]
    assert seen in ("recency", "affinity", "hybrid")

    # Operator forces ALL future buckets to a different variant via a weight override.
    token = _su_token(base)
    forced = "recency" if seen != "recency" else "hybrid"
    weights = {"recency": "[100,0,0]", "affinity": "[0,100,0]", "hybrid": "[0,0,100]"}[forced]
    status, _ = _http("PUT", f"{base}/api/settings/exp:discovery_ranking:weights",
                      token=token, body={"value": weights})
    assert status == 200

    # The already-seen subject KEEPS its persisted variant (sticky), still without auth.
    after = json.loads(_http("GET", f"{base}/api/state?subject={subject}")[1])["experiments"]["discovery_ranking"]
    assert after == seen
    # A brand-new subject under the override DOES follow the new weights (override is live).
    fresh = json.loads(_http("GET", f"{base}/api/state?subject=sticky-new-1")[1])["experiments"]["discovery_ranking"]
    assert fresh == forced
