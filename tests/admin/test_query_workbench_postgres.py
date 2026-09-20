"""Live PostgreSQL operator boundary and client-measurement contracts.

Uses the explicitly supplied disposable PostgreSQL test database. No SQL driver
dependency: the real CLI provisions the operator before server startup.
"""
import os
import pathlib
import subprocess
import uuid

import pytest

from conftest import _free_port, _stop_server, _wait_reachable_or_fail
from test_query_workbench import call


@pytest.mark.parametrize("enabled", [False, True])
def test_postgres_workbench_live(enabled, tmp_path):
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    variable = "ZIGBASE_TEST_QUERY_WORKBENCH_BINARY" if enabled else "ZIGBASE_TEST_QUERY_WORKBENCH_OFF_BINARY"
    binary = os.environ.get(variable)
    if not url or not binary:
        pytest.skip("requires live PostgreSQL and paired query-workbench fixtures")
    assert pathlib.Path(binary).is_file()
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DB_URL": url, "ZIGBASE_DATA_DIR": str(tmp_path),
           "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
    email = f"workbench-{uuid.uuid4().hex}@x.io"
    created = subprocess.run([binary, "superuser", "create", "--email", email,
                              "--password", "adminpassword"], env=env, check=True,
                             capture_output=True, text=True, timeout=30)
    assert "superuser created:" in created.stderr
    log_path = tmp_path / "server.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))
        base = f"http://127.0.0.1:{port}"
        assert call(base, "GET", "/work/private-path")[0] == 204
        if not enabled:
            for method, path in [("GET", "stats"), ("POST", "explain")]:
                assert call(base, method, f"/api/query-workbench/{path}")[0] == 404
            assert call(base, "GET", "/api/meta")[1]["capabilities"]["queryWorkbench"] is False
            return
        code, body = call(base, "POST", "/api/collections/_superusers/auth-with-password",
                          {"identity": email, "password": "adminpassword"})
        assert code == 200, body
        token = body["token"]
        for method, path in [("GET", "stats"), ("POST", "explain")]:
            endpoint = f"/api/query-workbench/{path}"
            assert call(base, method, endpoint)[0] == 401
            assert call(base, method, endpoint, headers={"Cookie": f"zb_auth={token}"})[0] == 401
        assert call(base, "POST", "/api/query-workbench/explain", {"collection": "_superusers"}, token)[0] == 501
        assert call(base, "GET", "/held")[0] == 204
        assert call(base, "GET", "/pool-wait")[0] == 204
        code, report = call(base, "GET", "/api/query-workbench/stats", token=token)
        assert code == 200 and report["activeBackend"] == "postgres"
        route = next(row for row in report["routes"] if row["routeTemplate"] == "/work/:id")
        assert route["completedScopes"] == 1
        assert route["totalNanoseconds"] == route["maxNanoseconds"]
        work = next(item for item in report["items"] if item["routeTemplate"] == "/work/:id")
        assert work["backend"] == "postgres"
        assert work["measurement"] == "client-extended-protocol-exchange-time"
        assert work["executions"] == work["finalizedStatements"] == 3
        assert work["repeatedShapes"] == 2
        wait_route = next(row for row in report["routes"] if row["routeTemplate"] == "/pool-wait")
        wait = next(row for row in wait_route["poolWaits"] if row["backend"] == "postgres" and row["role"] == "writer")
        assert wait["acquisitions"] == 1
        assert wait["totalNanoseconds"] == wait["maxNanoseconds"] >= 50_000_000
        assert wait_route["responseStatusClasses"]["success"] == 1
        held = next(item for item in report["items"] if item["routeTemplate"] == "/held")
        assert held["executions"] == 2 and held["finalizedStatements"] == 1
        assert held["heldNanoseconds"] >= 40_000_000
        assert held["statementLifetimeNanoseconds"] == held["measuredCallNanoseconds"] + held["heldNanoseconds"]
        for secret in ("private-path", "private-literal", email, token, "SELECT"):
            assert secret not in str(report)
        assert call(base, "GET", "/api/query-workbench/stats", token=token)[1] == report
        members = "workbench_members_" + uuid.uuid4().hex[:12]
        assert call(base, "POST", "/api/collections", {"name": members, "type": "auth", "fields": []}, token)[0] == 201
        assert call(base, "POST", f"/api/collections/{members}/records",
                    {"email": "member@x.io", "password": "memberpassword"}, token)[0] == 201
        code, member = call(base, "POST", f"/api/collections/{members}/auth-with-password",
                            {"identity": "member@x.io", "password": "memberpassword"})
        assert code == 200, member
        for method, path in [("GET", "stats"), ("POST", "explain")]:
            assert call(base, method, f"/api/query-workbench/{path}", token=member["token"])[0] == 403
    finally:
        _stop_server(proc)
