"""F2 e2e against the auth2 fixture (registered beforeAuthSuccess that blocks emails
starting with 'blocked' and writes a loginAudit row for every allowed login)."""
import json


def _signup(pg, email, password):
    r = pg.request.post("/api/collections/users/records",
                        data=json.dumps({"email": email, "password": password}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 201, r.text()
    return r.json()["id"]


def test_legacy_login_fires_the_hook_and_audit_row_commits(auth2_page):
    pg = auth2_page
    _signup(pg, "ok@x.io", "password123")
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": "ok@x.io", "password": "password123"}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 200, r.text()
    # The hook's side-write committed WITH the session (method tag = password).
    r = pg.request.get("/api/collections/loginAudit/records")
    items = r.json()["items"]
    assert any(i["method"] == "password" and i["col"] == "users" for i in items), items


def test_blocked_identity_is_vetoed_with_clean_rollback(auth2_page):
    pg = auth2_page
    _signup(pg, "blocked@x.io", "password123")
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": "blocked@x.io", "password": "password123"}),
                        headers={"Content-Type": "application/json"})
    assert r.status == 403, r.text()
    assert "token" not in r.json()
    # Rollback: the audit row written BEFORE the veto must not persist.
    r = pg.request.get("/api/collections/loginAudit/records")
    assert not any(i["col"] == "users" for i in r.json()["items"])


def test_admin_spa_superuser_login_still_works_with_a_passing_hook(auth2_page):
    # Breaking-change pin: the hook NOW fires for _superusers (admin SPA login route);
    # a passing hook must not break the SPA, and the audit row records the tag.
    pg = auth2_page
    pg.goto("/_/#/login")
    pg.fill('[data-test=email]', 'admin@x.io')
    pg.fill('[data-test=password]', 'adminpassword')
    pg.click('[data-test=login-submit]')
    pg.wait_for_selector('[data-test=nav-collections]', timeout=5000)
    r = pg.request.get("/api/collections/loginAudit/records")
    assert any(i["col"] == "_superusers" and i["method"] == "password" for i in r.json()["items"])


def test_refresh_fires_the_seam_with_the_refresh_tag(auth2_page):
    pg = auth2_page
    _signup(pg, "rt@x.io", "password123")
    r = pg.request.post("/api/collections/users/auth-with-password",
                        data=json.dumps({"identity": "rt@x.io", "password": "password123"}),
                        headers={"Content-Type": "application/json"})
    tok = r.json()["token"]
    r = pg.request.post("/api/collections/users/auth-refresh",
                        headers={"Authorization": f"Bearer {tok}"})
    assert r.status == 200, r.text()
    r = pg.request.get("/api/collections/loginAudit/records")
    assert any(i["method"] == "refresh" for i in r.json()["items"])  # .refresh, not .password
