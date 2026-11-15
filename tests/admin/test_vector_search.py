"""Live opt-in checks: ZIGBASE_TEST_VECTOR_BINARY must be a SQLite build with -Dvector=true.

`?vector=` list queries run on pooled READER connections, so these exercise the reader path
that #488 broke (every vector list answered 500 "no such function: vec_distance_cosine").
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

import pytest


@pytest.fixture(scope="session")
def binary():
    path = os.environ.get("ZIGBASE_TEST_VECTOR_BINARY")
    if not path:
        pytest.skip("requires a -Dvector=true binary (ZIGBASE_TEST_VECTOR_BINARY)")
    assert os.path.isfile(path), path
    return path


def call(server, method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(server + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if data else None


DOCS = {
    # cosine distance to [1,0]: east 0, northeast ~0.29, north 1, west 2
    # L2 distance to [1,0]:     east 0, northeast 1,     north ~1.41, west 2
    # `far_east` ([3,0]) points the same way as `east`, so cosine always ties them; under L2 a
    # query vector of [3,0] makes `far_east` the strict nearest (at [2,0] the two tie at 1), so
    # the two metrics give different orders.
    "east": [1, 0],
    "far_east": [3, 0],
    "northeast": [1, 1],
    "north": [0, 1],
    "west": [-1, 0],
}


@pytest.fixture()
def docs(server):
    status, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, auth
    token = auth["token"]
    fields = [
        {"id": "", "name": "title", "type": "text", "options": {}},
        {"id": "", "name": "embedding", "type": "json", "options": {}},
    ]
    status, col = call(server, "POST", "/api/collections", {"name": "docs", "type": "base", "fields": fields, "listRule": "@public", "viewRule": "@public"}, token)
    assert status == 201, col
    for title, embedding in DOCS.items():
        status, rec = call(server, "POST", "/api/collections/docs/records", {"title": title, "embedding": embedding}, token)
        assert status == 201, rec
    return token


def search(server, spec, token=None):
    return call(server, "GET", "/api/collections/docs/records?" + urllib.parse.urlencode({"vector": spec, "perPage": 50}), token=token)


def titles(page):
    return [item["title"] for item in page["items"]]


def test_cosine_orders_nearest_first(server, docs):
    status, page = search(server, "embedding:cosine:[2,0]")
    assert status == 200, page
    got = titles(page)
    # east and far_east are both at cosine distance 0 (same direction); their mutual order is a tie.
    assert set(got[:2]) == {"east", "far_east"}, got
    assert got[2:] == ["northeast", "north", "west"], got


def test_default_metric_is_cosine(server, docs):
    status, page = search(server, "embedding:[0,1]")
    assert status == 200, page
    # cosine to [0,1]: north 0, northeast ~0.29, then east/far_east/west all tie at 1.
    assert titles(page)[:2] == ["north", "northeast"], page


def test_l2_orders_nearest_first(server, docs):
    status, page = search(server, "embedding:l2:[2,0]")
    assert status == 200, page
    # L2 to [2,0]: east 1, far_east 1 (tie), northeast ~1.41, north ~2.24, west 3
    got = titles(page)
    assert set(got[:2]) == {"east", "far_east"}, got
    assert got[2:] == ["northeast", "north", "west"], got
    status, page = search(server, "embedding:l2:[3,0]")
    assert status == 200, page
    # L2 to [3,0]: far_east 0, east 2, northeast ~2.24, north ~3.16, west 4 — differs from cosine.
    assert titles(page) == ["far_east", "east", "northeast", "north", "west"], page


@pytest.mark.parametrize("metric", ["cosine", "l2"])
def test_dimension_mismatch_is_400(server, docs, metric):
    # A controlled pair: the same field and metric, differing only in the query embedding's
    # length. Every stored embedding is 2-D, so the 3-D query is the only cause of the 400.
    # (Over HTTP any `?vector=` execution failure gets this 400, so the response alone cannot
    # name the cause; the backend's own "dimension mistmatch" error is pinned by the db.zig
    # unit test "pool: every query-serving connection registers sqlite-vec (#488)".)
    status, page = search(server, f"embedding:{metric}:[1,0]")
    assert status == 200, page
    status, body = search(server, f"embedding:{metric}:[1,0,0]")
    assert status == 400, body
    assert "dimension" in body["message"], body
    # The reader that failed is parked and reused; a well-formed search right after still answers.
    status, page = search(server, f"embedding:{metric}:[1,0]")
    assert status == 200, page
