"""Exercise the actual golfsim route module over HTTP with fresh authorization."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import urllib.error
import urllib.request

import pytest


@pytest.fixture(scope="session")
def binary():
    value = os.environ.get("ZIGBASE_TEST_IDEMPOTENCY_BINARY")
    if not value:
        pytest.skip("requires idempotency-fixture")
    assert Path(value).is_file()
    return value


def call(base, method, path, data=None, token=None, key=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if key is not None:
        headers["Idempotency-Key"] = key
    if data is not None:
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        return response.status, json.loads(raw) if raw else None, response.headers


def setup(base):
    status, auth, _ = call(base, "POST", "/api/collections/_superusers/auth-with-password",
                           {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, auth
    admin = auth["token"]
    assert call(base, "POST", "/api/collections", {"name": "users", "type": "auth", "fields": []}, admin)[0] == 201
    assert call(base, "POST", "/api/collections", {"name": "bookings", "type": "base", "fields": [
        {"id": "", "name": "guest", "type": "text", "options": {}},
        {"id": "", "name": "status", "type": "text", "options": {}},
    ]}, admin)[0] == 201
    users = []
    for email in ["alice@example.com", "bob@example.com"]:
        status, user, _ = call(base, "POST", "/api/collections/users/records", {"email": email, "password": "password12345"}, admin)
        assert status == 201, user
        status, auth, _ = call(base, "POST", "/api/collections/users/auth-with-password", {"identity": email, "password": "password12345"})
        assert status == 200, auth
        users.append((user["id"], auth["token"]))
    bookings = []
    for _ in range(2):
        status, booking, _ = call(base, "POST", "/api/collections/bookings/records", {"guest": users[0][0], "status": "confirmed"}, admin)
        assert status == 201, booking
        bookings.append(booking["id"])
    return admin, users, bookings


def test_concurrent_replay_payload_binding_and_current_guest_guard(server):
    admin, users, bookings = setup(server)
    endpoint = f"/api/bookings/{bookings[0]}/cancel-idempotent"
    alice, bob = users[0][1], users[1][1]
    assert call(server, "POST", endpoint, token=bob, key="retry")[0] == 403
    with ThreadPoolExecutor(max_workers=6) as executor:
        responses = list(executor.map(lambda _: call(server, "POST", endpoint, token=alice, key="retry"), range(12)))
    assert [r[0] for r in responses] == [200] * 12
    assert sum(r[2]["Idempotency-Replayed"] == "false" for r in responses) == 1
    assert all(r[1] == {"cancelled": True} for r in responses)
    # The target is part of the payload digest, not merely the route template.
    assert call(server, "POST", f"/api/bookings/{bookings[1]}/cancel-idempotent", token=alice, key="retry")[0] == 409
    assert call(server, "GET", f"/api/collections/bookings/records/{bookings[1]}", token=admin)[1]["status"] == "confirmed"
    # Current DB authorization is evaluated on the transaction writer, even replay.
    assert call(server, "PATCH", f"/api/collections/bookings/records/{bookings[0]}", {"guest": users[1][0]}, admin)[0] == 200
    assert call(server, "POST", endpoint, token=alice, key="retry")[0] == 403
    status, _, headers = call(server, "POST", endpoint, token=bob, key="retry")
    assert status == 200 and headers["Idempotency-Replayed"] == "false"


def test_authentication_and_input_boundaries(server):
    _, users, bookings = setup(server)
    endpoint = f"/api/bookings/{bookings[0]}/cancel-idempotent"
    token = users[0][1]
    assert call(server, "POST", endpoint, key="retry")[0] == 401
    assert call(server, "POST", endpoint, token=token)[0] == 400
    assert call(server, "POST", endpoint, token=token, key="x" * 129)[0] == 400
    assert call(server, "POST", endpoint, {}, token, "retry")[0] == 400
    assert call(server, "POST", endpoint, token=token, key="retry")[0] == 200
