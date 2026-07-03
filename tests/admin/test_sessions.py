"""F3 e2e against the auth2 fixture (.session_store = .table): list / revoke / revoke-all."""
import json
import urllib.request


def _login(pg, email, password):
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": email, "password": password}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 200, r.text()
    return r.json()["token"]


def _signup(pg, email, password):
    r = pg.request.post("/api/collections/users/records",
                        data=json.dumps({"email": email, "password": password}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 201, r.text()


def test_list_shows_two_devices_with_is_current(auth2_page):
    pg = auth2_page
    _signup(pg, "dev@x.io", "password123")
    tok_a = _login(pg, "dev@x.io", "password123")
    tok_b = _login(pg, "dev@x.io", "password123")
    r = pg.request.get("/api/collections/users/auth/sessions",
                       headers={"Authorization": f"Bearer {tok_b}"})
    assert r.status == 200, r.text()
    items = r.json()["items"]  # {items} envelope, newest first
    assert len(items) == 2
    assert sum(1 for s in items if s["is_current"]) == 1
    assert set(items[0]) >= {"id", "created", "last_seen", "user_agent", "ip", "is_current"}
    assert items[0]["is_current"]  # newest-first ⇒ the just-minted tok_b session leads
    del tok_a


def test_revoke_other_device_kills_it_and_404s_are_non_oracle(auth2_page):
    pg = auth2_page
    _signup(pg, "rv@x.io", "password123")
    tok_a = _login(pg, "rv@x.io", "password123")
    tok_b = _login(pg, "rv@x.io", "password123")
    # From device B, find device A's sid (the non-current row) and revoke it.
    items = pg.request.get("/api/collections/users/auth/sessions",
                           headers={"Authorization": f"Bearer {tok_b}"}).json()["items"]
    other = next(s for s in items if not s["is_current"])
    r = pg.request.delete(f"/api/collections/users/auth/sessions/{other['id']}",
                          headers={"Authorization": f"Bearer {tok_b}"})
    assert r.status == 204 and r.text() == ""
    # Device A is dead on its next call.
    r = pg.request.post("/api/collections/users/auth-refresh",
                        headers={"Authorization": f"Bearer {tok_a}"})
    assert r.status == 401
    # A second user cannot probe: absent id and non-owned id are the SAME 404.
    _signup(pg, "rv2@x.io", "password123")
    tok_c = _login(pg, "rv2@x.io", "password123")
    mine = pg.request.get("/api/collections/users/auth/sessions",
                          headers={"Authorization": f"Bearer {tok_b}"}).json()["items"]
    r1 = pg.request.delete(f"/api/collections/users/auth/sessions/{mine[0]['id']}",
                           headers={"Authorization": f"Bearer {tok_c}"})
    r2 = pg.request.delete("/api/collections/users/auth/sessions/nonexistent00000",
                           headers={"Authorization": f"Bearer {tok_c}"})
    assert r1.status == 404 and r2.status == 404
    assert r1.text() == r2.text()


def test_revoke_all_kills_everything_and_clears_cookies(auth2_page, auth2_server):
    pg = auth2_page
    _signup(pg, "all@x.io", "password123")
    tok_a = _login(pg, "all@x.io", "password123")
    tok_b = _login(pg, "all@x.io", "password123")
    # urllib so we can read the raw Set-Cookie headers (playwright's APIResponse hides them).
    req = urllib.request.Request(f"{auth2_server}/api/collections/users/auth/sessions",
                                 method="DELETE",
                                 headers={"Authorization": f"Bearer {tok_a}"})
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 204
        set_cookies = resp.headers.get_all("Set-Cookie") or []
    # Pin CLEARED, not merely re-set: the zb_auth cookie's value must be empty AND
    # carry an expiry attribute that tells the browser to drop it (Max-Age <= 0 or an
    # Expires attribute) — a non-empty re-issued zb_auth must NOT satisfy this.
    zb_auth = next((c for c in set_cookies if c.split(";", 1)[0].strip() == "zb_auth="), None)
    assert zb_auth is not None, set_cookies
    attrs = [a.strip() for a in zb_auth.split(";")[1:]]
    assert any(a.startswith("Max-Age=") and int(a.split("=", 1)[1]) <= 0 for a in attrs) or \
        any(a.startswith("Expires=") for a in attrs), zb_auth
    # BOTH tokens dead (epoch bump), list empty for a fresh login.
    for tok in (tok_a, tok_b):
        r = pg.request.post("/api/collections/users/auth-refresh",
                            headers={"Authorization": f"Bearer {tok}"})
        assert r.status == 401
    tok_new = _login(pg, "all@x.io", "password123")
    items = pg.request.get("/api/collections/users/auth/sessions",
                           headers={"Authorization": f"Bearer {tok_new}"}).json()["items"]
    assert len(items) == 1


def test_epoch_mode_routes_404(page, server):
    # The STOCK binary (epoch mode): per-device routes are 404 (feature not enabled),
    # matching a disabled auth-method slug. Uses the plain server fixture.
    from conftest import login, api_request
    login(page)
    r = api_request(page, "GET", "/api/collections/_superusers/auth/sessions")
    assert r.status == 404
    r = api_request(page, "DELETE", "/api/collections/_superusers/auth/sessions/whatever000000x")
    assert r.status == 404
