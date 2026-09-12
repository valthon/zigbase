"""Bounded opt-in operator diagnostics against actual SQLite and HTTP routes."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import pathlib
import re
import urllib.error
import urllib.request
import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]

@pytest.fixture(scope="session")
def binary():
    value = os.environ.get("ZIGBASE_TEST_QUERY_WORKBENCH_BINARY")
    if not value:
        pytest.skip("requires -Dquery-workbench=true query-workbench-fixture")
    assert pathlib.Path(value).is_file()
    return value

def call(base, method, path, data=None, token=None, headers=None):
    headers = dict(headers or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        return response.status, json.loads(body) if body else None

def admin(base):
    code, body = call(base, "POST", "/api/collections/_superusers/auth-with-password",
                      {"identity": "admin@x.io", "password": "adminpassword"})
    assert code == 200, body
    return body["token"]

def test_bounded_private_route_template_attribution_and_concurrency(server):
    token = admin(server)
    with ThreadPoolExecutor(max_workers=8) as executor:
        codes = list(executor.map(lambda n: call(server, "GET", f"/work/private-path-{n}")[0], range(24)))
    assert codes == [204] * 24
    code, report = call(server, "GET", "/api/query-workbench/stats", token=token)
    assert code == 200
    assert len(report["items"]) <= report["maxEntries"] == 8
    entries = [item for item in report["items"] if item["routeTemplate"] == "/work/:id"]
    assert len(entries) == 1, report
    entry = entries[0]
    assert entry["executions"] == 72
    assert entry["repeatedShapes"] == 48
    assert entry["method"] == "GET"
    assert re.fullmatch(r"[0-9a-f]{16}", entry["shape"])
    assert entry["stepNanoseconds"] >= entry["maxStepNanoseconds"] >= 0
    assert entry["finalizedStatements"] == 72
    assert entry["statementLifetimeNanoseconds"] >= entry["maxStatementLifetimeNanoseconds"] >= 0
    assert entry["statementLifetimeNanoseconds"] == entry["measuredCallNanoseconds"] + entry["heldNanoseconds"]
    serialized = json.dumps(report)
    for forbidden in ["private-path", "private-literal", "admin@x.io", "SELECT", token]:
        assert forbidden not in serialized
    # Inspector auth and plans must not instrument themselves.
    assert call(server, "GET", "/api/query-workbench/stats", token=token)[1] == report
    meta = call(server, "GET", "/api/meta")[1]
    assert meta["capabilities"]["queryWorkbench"] is True
    assert meta["endpoints"]["queryWorkbench"] == "/api/query-workbench/stats"

def test_statement_lifetime_separates_application_hold_and_reset_reuse(server):
    token = admin(server)
    assert call(server, "GET", "/held")[0] == 204
    code, report = call(server, "GET", "/api/query-workbench/stats", token=token)
    assert code == 200
    assert report["measurement"] == "prepared-statement-step-time"
    assert report["lifetimeMeasurement"] == "prepare-through-finalize"
    assert report["measuredCalls"] == ["prepare", "step", "reset", "finalize"]
    entries = [item for item in report["items"] if item["routeTemplate"] == "/held"]
    assert len(entries) == 1, report
    entry = entries[0]
    assert entry["finalizedStatements"] == 1
    assert entry["executions"] == 2
    assert entry["repeatedShapes"] == 1
    # Only a lower bound: scheduling can lengthen the hold, without making this flaky.
    assert entry["heldNanoseconds"] >= 40_000_000
    assert entry["statementLifetimeNanoseconds"] == entry["maxStatementLifetimeNanoseconds"]
    assert entry["statementLifetimeNanoseconds"] == entry["measuredCallNanoseconds"] + entry["heldNanoseconds"]

def test_operator_only_bearer_boundary(server):
    token = admin(server)
    code, _ = call(server, "POST", "/api/collections", {"name": "members", "type": "auth", "fields": []}, token)
    assert code == 201
    assert call(server, "POST", "/api/collections/members/records", {"email": "member@x.io", "password": "memberpassword"}, token)[0] == 201
    code, body = call(server, "POST", "/api/collections/members/auth-with-password", {"identity": "member@x.io", "password": "memberpassword"})
    assert code == 200
    member = body["token"]
    for method, path, data in [("GET", "/api/query-workbench/stats", None),
                               ("POST", "/api/query-workbench/explain", {"collection": "members"})]:
        assert call(server, method, path, data)[0] == 401
        assert call(server, method, path, data, "invalid")[0] == 401
        assert call(server, method, path, data, member)[0] == 403
        assert call(server, method, path, data, headers={"Cookie": f"zb_auth={token}"})[0] == 401
        assert call(server, method, path, data, token)[0] == 200

def test_structural_explain_search_scan_and_rejected_sql(server):
    token = admin(server)
    assert call(server, "POST", "/api/collections", {"name": "posts", "type": "base", "fields": [{"id": "", "name": "title", "type": "text", "options": {}}]}, token)[0] == 201
    endpoint = "/api/query-workbench/explain"
    code, report = call(server, "POST", endpoint, {"collection": "posts", "equalityField": "id"}, token)
    assert code == 200, report
    assert report["executesQuery"] is False and report["includesAuthorizationPredicates"] is False
    assert any("SEARCH" in row["detail"] for row in report["items"]), report
    assert len(report["items"]) <= 32
    assert all(len(row["detail"].encode()) <= 512 for row in report["items"])
    code, scan = call(server, "POST", endpoint, {"collection": "posts", "orderField": "title"}, token)
    assert code == 200 and any("SCAN" in row["detail"] for row in scan["items"])
    for value in [b"{", {"collection": "posts", "sql": "DELETE FROM posts"},
                  {"collection": "posts", "equalityField": "id); DROP TABLE posts;--"},
                  {"collection": "posts", "value": "private-value"},
                  {"collection": "posts", "orderField": "é" * 300},
                  {"collection": "posts", "descending": "false"}, b"x" * 4097]:
        assert call(server, "POST", endpoint, value, token)[0] == 400
    assert call(server, "GET", "/api/collections/posts/records", token=token)[1]["items"] == []
