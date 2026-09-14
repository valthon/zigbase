"""Actual CLI provisioning must create a usable operator or exit unsuccessfully."""
import datetime
import json
import os
import subprocess
import urllib.error
import urllib.request
import uuid

import pytest

from conftest import _free_port, _stop_server, _wait_reachable_or_fail


@pytest.mark.parametrize("backend", ["sqlite", "postgres"])
def test_cli_superuser_create_login_and_duplicate_failure(binary, backend, tmp_path):
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_SERVE_BACKGROUND": "0"}
    env.pop("ZIGBASE_DB_URL", None)
    if backend == "postgres":
        url = os.environ.get("ZIGBASE_PG_TEST_URL")
        if not url:
            pytest.skip("requires a PostgreSQL-enabled binary and disposable PostgreSQL test database")
        env["ZIGBASE_DB_URL"] = url
    email = f"cli-{uuid.uuid4().hex}@x.io"
    password = "cli-test-password"

    def create(value):
        return subprocess.run([binary, "superuser", "create", "--email", email,
                               "--password", value], env=env, text=True,
                              capture_output=True, timeout=30)

    first = create(password)
    assert first.returncode == 0, first.stderr
    assert "superuser created:" in first.stderr
    duplicate = create("replacement-password")
    assert duplicate.returncode != 0, duplicate.stderr
    assert "could not create superuser" in duplicate.stderr
    assert "superuser created:" not in duplicate.stderr
    for secret in (password, "replacement-password"):
        assert secret not in first.stdout + first.stderr + duplicate.stdout + duplicate.stderr

    port = _free_port()
    env["ZIGBASE_HTTP_PORT"] = str(port)
    log_path = tmp_path / "server.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))

        def login(value):
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/api/collections/_superusers/auth-with-password",
                data=json.dumps({"identity": email, "password": value}).encode(),
                headers={"Content-Type": "application/json"}, method="POST")
            try:
                response = urllib.request.urlopen(request, timeout=10)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, json.load(response)

        code, result = login(password)
        assert code == 200, result
        assert result["token"] and result["record"]["email"] == email
        for name in ("created", "updated"):
            assert datetime.datetime.fromisoformat(result["record"][name])
        assert login("replacement-password")[0] == 400
    finally:
        _stop_server(proc)
