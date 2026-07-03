"""F1 e2e: self-service password change via PATCH /records on the STOCK binary (epoch mode).

Pins the full contract end-to-end: oldPassword verification (non-oracle 400), the
keep-this-device cookie re-issue, everyone-else logged out, and the superuser reset
(no oldPassword, no re-issue). A green `zig build test` does NOT cover this.
"""
import json
from conftest import login, api_request


def _mk_users_collection(page):
    login(page)
    r = api_request(page, "POST", "/api/collections", body={
        "name": "users", "type": "auth", "fields": [],
        "createRule": "@public", "updateRule": "@request.auth.id = id",
        "listRule": "@request.auth.id = id", "viewRule": "@request.auth.id = id",
    })
    assert r.status in (200, 201), r.text()


def _signup(browser, server, email, password):
    """Signup (public create) in a throwaway context, return the new record's id."""
    ctx = browser.new_context(base_url=server)
    pg = ctx.new_page()
    r = pg.request.post("/api/collections/users/records",
                        data=json.dumps({"email": email, "password": password}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 201, r.text()
    rid = r.json()["id"]
    ctx.close()
    return rid


def _login_ctx(browser, server, email, password):
    """Cookie-login in a fresh browser context; returns (page, bearer_token)."""
    ctx = browser.new_context(base_url=server)
    pg = ctx.new_page()
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": email, "password": password}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 200, r.text()
    return pg, r.json()["token"]


def _csrf(ctx):
    for ck in ctx.cookies():
        if ck["name"] == "zb_csrf":
            return ck["value"]
    return ""


def test_password_change_keeps_this_device_and_kills_the_rest(page, server):
    _mk_users_collection(page)
    browser = page.context.browser
    rid = _signup(browser, server, "own@x.io", "firstpassword")
    pg_a, _tok_a = _login_ctx(browser, server, "own@x.io", "firstpassword")
    pg_b, tok_b = _login_ctx(browser, server, "own@x.io", "firstpassword")  # same acct, 2nd device
    ctx_a, ctx_b = pg_a.context, pg_b.context

    # Device A changes its own password (cookie session + CSRF double-submit, like any PATCH).
    r = pg_a.request.patch(f"/api/collections/users/records/{rid}",
                           data=json.dumps({"password": "secondpassword", "oldPassword": "firstpassword"}),
                           headers={"Content-Type": "application/json", "X-CSRF-Token": _csrf(ctx_a)})
    assert r.status == 200, r.text()
    body = r.json()
    assert "passwordHash" not in body and "tokenKey" not in body and "oldPassword" not in body

    # Device A: STILL logged in — the response re-issued fresh cookies under the new tokenKey.
    r = pg_a.request.post("/api/collections/users/auth-refresh",
                          headers={"X-CSRF-Token": _csrf(ctx_a)})
    assert r.status == 200, r.text()

    # Device B (old bearer token): dead — the tokenKey rotation killed it.
    r = pg_b.request.post("/api/collections/users/auth-refresh",
                          headers={"Authorization": f"Bearer {tok_b}"})
    assert r.status == 401, r.text()

    # And the new password logs in; the old one does not.
    r = pg_b.request.post("/api/collections/users/auth-with-password",
                          data=json.dumps({"identity": "own@x.io", "password": "secondpassword"}),
                          headers={"Content-Type": "application/json"})
    assert r.status == 200
    r = pg_b.request.post("/api/collections/users/auth-with-password",
                          data=json.dumps({"identity": "own@x.io", "password": "firstpassword"}),
                          headers={"Content-Type": "application/json"})
    assert r.status == 400
    ctx_a.close(); ctx_b.close()


def test_wrong_or_missing_old_password_is_the_login_identical_400(page, server):
    _mk_users_collection(page)
    browser = page.context.browser
    rid = _signup(browser, server, "w@x.io", "firstpassword")
    pg, _tok = _login_ctx(browser, server, "w@x.io", "firstpassword")
    ctx = pg.context
    for body in ({"password": "secondpassword", "oldPassword": "WRONGpassword"},
                 {"password": "secondpassword"}):
        r = pg.request.patch(f"/api/collections/users/records/{rid}",
                             data=json.dumps(body),
                             headers={"Content-Type": "application/json", "X-CSRF-Token": _csrf(ctx)})
        assert r.status == 400, r.text()
        assert r.json()["message"] == "Invalid credentials."  # byte-identical to a failed login
    # Password unchanged.
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": "w@x.io", "password": "firstpassword"}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 200
    ctx.close()


def test_superuser_reset_needs_no_old_password_and_logs_the_user_out(page, server):
    _mk_users_collection(page)
    browser = page.context.browser
    rid = _signup(browser, server, "s@x.io", "firstpassword")
    pg, tok = _login_ctx(browser, server, "s@x.io", "firstpassword")
    # Superuser PATCH (admin cookie session from login(page)): no oldPassword required.
    r = api_request(page, "PATCH", f"/api/collections/users/records/{rid}",
                    body={"password": "adminresetpw1"})
    assert r.status == 200, r.text()
    # Every user session is dead (no re-issue for admin-changing-someone-else).
    r = pg.request.post("/api/collections/users/auth-refresh",
                        headers={"Authorization": f"Bearer {tok}"})
    assert r.status == 401
    # New password works.
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": "s@x.io", "password": "adminresetpw1"}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 200
    pg.context.close()
