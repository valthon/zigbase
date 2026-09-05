"""The example's actual islands UI with table-backed sessions and runtime policy."""
import os
import pathlib
import socket
import sqlite3
import subprocess
import time

import pytest

from test_two_factor import request, totp

REPO = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture
def golfsim_server(tmp_path):
    binary = os.environ.get("ZIGBASE_TEST_GOLFSIM_BINARY", str(REPO / "examples/golfsim/zig-out/bin/golfsim"))
    if not os.path.isfile(binary):
        pytest.fail("Build examples/golfsim before running its two-factor browser test")
    data = tmp_path / "data"
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                    "--password", "adminpassword", "--data-dir", str(data)], check=True)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": str(port),
           "ZIGBASE_SERVE_BACKGROUND": "0"}
    proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], cwd=REPO / "examples/golfsim",
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if proc.poll() is not None:
                    pytest.fail("golfsim exited during startup")
                time.sleep(0.1)
        yield f"http://127.0.0.1:{port}", data
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_required_totp_browser_flow_and_recovery(golfsim_server, page):
    base, data = golfsim_server
    _, admin, _ = request(base, "/api/collections/_superusers/auth-with-password",
                          {"identity": "admin@x.io", "password": "adminpassword"})
    status, user, _ = request(base, "/api/collections/users/records", {
        "email": "browser@example.test", "password": "longenough", "name": "Browser"}, admin["token"])
    assert status == 201, user
    # Fixture-only email verification; this test exercises second-factor UI,
    # not delivery to an external mailbox. Production record writes strip verified.
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute('UPDATE users SET verified=1 WHERE id=?', (user["id"],))
    status, requirement, _ = request(base, "/api/collections/security_requirements/records",
                                    {"principal": user["id"], "required": True}, admin["token"])
    assert status == 201, requirement
    page.goto(base + "/bookings/")
    page.get_by_placeholder("Email", exact=True).fill("browser@example.test")
    page.get_by_placeholder("Password", exact=True).fill("longenough")
    page.get_by_role("button", name="Log in with password").click()
    secret = page.locator('[data-test="totp-secret"]').inner_text()
    assert page.evaluate("localStorage.getItem('golfsim_token')") is None
    page.locator('[data-test="second-factor-code"]').fill(totp(secret))
    page.locator('[data-test="second-factor-submit"]').click()
    codes = page.locator('[data-test="recovery-codes"] pre').inner_text().splitlines()
    assert len(codes) == 10
    page.get_by_role("button", name="I saved my recovery codes").click()
    page.get_by_role("heading", name="Account security").wait_for()
    token = page.evaluate("localStorage.getItem('golfsim_token')")
    assert request(base, "/api/collections/users/auth-refresh", {}, token)[0] == 200
    page.evaluate("localStorage.clear()")
    page.context.clear_cookies()
    page.reload()
    page.get_by_placeholder("Email", exact=True).fill("browser@example.test")
    page.get_by_placeholder("Password", exact=True).fill("longenough")
    page.get_by_role("button", name="Log in with password").click()
    page.get_by_role("button", name="Use a recovery code").click()
    assert page.evaluate("localStorage.getItem('golfsim_token')") is None
    page.locator('[data-test="second-factor-code"]').fill(codes[0])
    page.locator('[data-test="second-factor-submit"]').click()
    page.get_by_role("heading", name="Account security").wait_for()
