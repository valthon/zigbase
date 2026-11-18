"""#505: an absent `@request.auth.*` value never widens a rule.

For an anonymous caller (or one whose session expired) every `@request.auth.<field>` macro used
to resolve to the empty string, so `owner ~ @request.auth.id` compiled to `LIKE '%%'` and matched
every row with a non-NULL owner — over REST list/view/update/delete and over realtime delivery.
These tests drive the stock binary end to end: anonymous REST calls against owner-scoped rules,
and an authenticated realtime subscriber whose token expires mid-subscription.
"""
import json
import time

import pytest
from conftest import login, api_request

OWNER_LIKE = "owner ~ @request.auth.id"
COLLECTION_OWNER = '@request.auth.collection != "_superusers" && owner = @request.auth.id'


def _setup(page, rules):
    """Superuser: a `users` auth collection and a `notes` collection with `rules`."""
    login(page)
    r = api_request(page, "POST", "/api/collections", {
        "name": "users", "type": "auth", "fields": [],
        "createRule": "@public", "listRule": "@request.auth.id = id",
        "viewRule": "@request.auth.id = id", "updateRule": "", "deleteRule": ""})
    assert r.status in (200, 201), r.text()
    body = {"name": "notes", "type": "base",
            "fields": [{"id": "", "name": "owner", "type": "text", "options": {}},
                       {"id": "", "name": "contact", "type": "text", "options": {}},
                       {"id": "", "name": "title", "type": "text", "options": {}}],
            "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""}
    body.update(rules)
    r = api_request(page, "POST", "/api/collections", body)
    assert r.status in (200, 201), r.text()


def _signup(browser, server, email):
    ctx = browser.new_context(base_url=server)
    r = ctx.new_page().request.post("/api/collections/users/records",
                                    data=json.dumps({"email": email, "password": "userpassword1"}),
                                    headers={"Content-Type": "application/json"})
    assert r.status == 201, r.text()
    uid = r.json()["id"]
    ctx.close()
    return uid


def _user_token(browser, server, email):
    ctx = browser.new_context(base_url=server)
    r = ctx.new_page().request.post("/api/collections/users/auth-with-password",
                                    data=json.dumps({"identity": email, "password": "userpassword1"}),
                                    headers={"Content-Type": "application/json"})
    assert r.status == 200, r.text()
    tok = r.json()["token"]
    ctx.close()
    return tok


def _signup_login(browser, server, email):
    uid = _signup(browser, server, email)
    return uid, _user_token(browser, server, email)


def _note(page, **fields):
    r = api_request(page, "POST", "/api/collections/notes/records", fields)
    assert r.status in (200, 201), r.text()
    return r.json()["id"]


def _anon(browser, server):
    return browser.new_context(base_url=server).new_page()


def _bearer(tok):
    return {"Authorization": f"Bearer {tok}"}


@pytest.mark.parametrize("rule", [
    OWNER_LIKE,
    "owner = @request.auth.id",
    "owner != @request.auth.id",
    "owner >= @request.auth.id",
    "contact ~ @request.auth.email",
    "@request.auth.id ~ owner",
    "owner ~ @request.auth.collection",
])
def test_anonymous_rest_list_and_view_see_nothing(page, server, rule):
    _setup(page, {"listRule": rule, "viewRule": rule})
    browser = page.context.browser
    uid, _ = _signup_login(browser, server, "a@x.io")
    rid = _note(page, owner=uid, contact="a@x.io", title="owned")
    empty = _note(page, owner="", contact="", title="ownerless")
    anon = _anon(browser, server)
    r = anon.request.get("/api/collections/notes/records")
    assert r.status == 200, r.text()
    assert r.json()["items"] == [], f"anonymous list under {rule!r} leaked rows: {r.text()}"
    for target in (rid, empty):
        r = anon.request.get(f"/api/collections/notes/records/{target}")
        assert r.status == 404, f"anonymous view under {rule!r} returned {r.status}: {r.text()}"


def test_owner_like_rule_still_scopes_authenticated_callers(page, server):
    _setup(page, {"listRule": OWNER_LIKE, "viewRule": OWNER_LIKE})
    browser = page.context.browser
    a_id, a_tok = _signup_login(browser, server, "a@x.io")
    b_id, b_tok = _signup_login(browser, server, "b@x.io")
    ra = _note(page, owner=a_id, title="A")
    rb = _note(page, owner=b_id, title="B")
    anon = _anon(browser, server)
    r = anon.request.get("/api/collections/notes/records", headers=_bearer(a_tok))
    assert [i["id"] for i in r.json()["items"]] == [ra], r.text()
    r = anon.request.get(f"/api/collections/notes/records/{rb}", headers=_bearer(a_tok))
    assert r.status == 404, r.text()
    r = anon.request.get(f"/api/collections/notes/records/{rb}", headers=_bearer(b_tok))
    assert r.status == 200, r.text()


def test_anonymous_update_and_delete_denied_under_owner_like_rules(page, server):
    _setup(page, {"listRule": "@public", "viewRule": "@public",
                  "updateRule": OWNER_LIKE, "deleteRule": OWNER_LIKE})
    browser = page.context.browser
    uid, _ = _signup_login(browser, server, "a@x.io")
    rid = _note(page, owner=uid, title="keep")
    anon = _anon(browser, server)
    r = anon.request.patch(f"/api/collections/notes/records/{rid}",
                           data=json.dumps({"title": "pwned"}),
                           headers={"Content-Type": "application/json"})
    assert r.status in (403, 404), f"anonymous update allowed: {r.status} {r.text()}"
    r = anon.request.delete(f"/api/collections/notes/records/{rid}")
    assert r.status in (403, 404), f"anonymous delete allowed: {r.status} {r.text()}"
    r = anon.request.get(f"/api/collections/notes/records/{rid}")
    assert r.status == 200 and r.json()["title"] == "keep", r.text()


def test_anonymous_create_denied_when_rule_compares_body_to_auth(page, server):
    """`@request.data.owner = @request.auth.id` with no owner in the body was `"" = ""` -> allow."""
    _setup(page, {"createRule": "@request.data.owner = @request.auth.id"})
    anon = _anon(page.context.browser, server)
    r = anon.request.post("/api/collections/notes/records", data=json.dumps({"title": "x"}),
                          headers={"Content-Type": "application/json"})
    assert r.status in (400, 403, 404), f"anonymous create allowed: {r.status} {r.text()}"


WS_CLIENT_JS = """(tok) => {
    window.__frames = [];
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(proto + '://' + location.host + '/api/realtime');
    ws.onmessage = (e) => window.__frames.push(e.data);
    ws.onopen = () => {
        ws.send(JSON.stringify({action: 'auth', token: tok}));
        ws.send(JSON.stringify({action: 'subscribe', topic: 'notes'}));
    };
}"""


@pytest.mark.parametrize("rule", [OWNER_LIKE, COLLECTION_OWNER])
@pytest.mark.parametrize("server", [{"ZIGBASE_AUTH_TOKEN_TTL": "8"}], indirect=True)
def test_realtime_owner_rules_deliver_live_but_not_expired(page, server, rule):
    """Live owner delivery needs the verified collection; expired delivery must fail closed.

    Successful producer writes after expiry ensure the negative assertion exercises events.
    The compiler-level absent-value matrix also covers expired RequestContexts directly.
    """
    _setup(page, {"listRule": rule, "viewRule": rule})
    browser = page.context.browser
    a_id = _signup(browser, server, "a@x.io")
    b_id = _signup(browser, server, "b@x.io")
    # Every argon2id hash eats into an 8 s TTL, and a debug build hashes slowly. Re-mint the
    # admin session after the signups and mint B's token last: B's live window then holds no
    # hash, and the admin's holds only B's one.
    login(page)
    ra = _note(page, owner=a_id, title="A0")
    rb = _note(page, owner=b_id, title="B0")
    b_tok = _user_token(browser, server, "b@x.io")
    sub = _anon(browser, server)
    sub.goto("/api/health")  # a same-origin document, so the in-page WebSocket passes the Origin check
    sub.evaluate(WS_CLIENT_JS, b_tok)
    sub.wait_for_function("window.__frames.some(f => f.includes('\"type\":\"ack\"'))", timeout=8000)
    # Positive control while B's session is live: B's own row is delivered.
    r = api_request(page, "PATCH", f"/api/collections/notes/records/{rb}", {"title": "B1-live"})
    assert 200 <= r.status < 300, r.text()
    try:
        sub.wait_for_function("window.__frames.some(f => f.includes('B1-live'))", timeout=8000)
    except Exception:
        pytest.fail(f"positive control: no live frame for B's own row: {sub.evaluate('() => window.__frames')}")
    time.sleep(9)  # B's token (TTL 8 s, minted before this) is now expired; the socket stays open
    login(page)  # The producer's admin session had the same short TTL.
    for rid in (ra, rb):  # Include B's own row: owner equality alone must not hide expiry bugs.
        r = api_request(page, "PATCH", f"/api/collections/notes/records/{rid}",
                        {"title": "after-expiry"})
        assert 200 <= r.status < 300, r.text()
        r = api_request(page, "DELETE", f"/api/collections/notes/records/{rid}")
        assert 200 <= r.status < 300, r.text()
    sub.wait_for_timeout(1500)
    frames = sub.evaluate("() => window.__frames")
    leaked = [f for f in frames if "after-expiry" in f or ((ra in f or rb in f) and '"delete"' in f)]
    assert not leaked, f"expired subscriber received record frames: {leaked}"


@pytest.fixture(scope="session")
def membership_binary():
    from _bin import REPO, resolve_binary
    return resolve_binary("ZIGBASE_TEST_CAPACITY_BINARY", REPO, "application-capacity")


@pytest.fixture()
def membership_server(membership_binary, request):
    # Reuse the ordinary server lifecycle with a tenancy-enabled framework consumer.
    from conftest import server as server_fixture
    from pathlib import Path
    for base in server_fixture.__wrapped__(membership_binary, request):
        _, log_path = request.node._server_diagnostic_context
        yield base, Path(log_path).parent / "data.db"


@pytest.mark.parametrize("transport", ["ws", "sse"])
@pytest.mark.parametrize("change", ["demote", "remove"])
def test_realtime_account_scope_refreshes_on_open_connection(
        membership_server, _browser, transport, change):
    import sqlite3
    from test_realtime import rt_open, rt_send, rt_wait_frame

    base, database = membership_server
    with _browser.new_context(base_url=base) as admin_context, \
            _browser.new_context(base_url=base, extra_http_headers={"X-Account-Id": "accountA"}) as member_context:
        admin = admin_context.new_page()
        login(admin)
        r = api_request(admin, "POST", "/api/collections/users/records",
                        {"email": "member@x.io", "password": "userpassword1"})
        assert r.status == 201, r.text()
        uid = r.json()["id"]
        rule = '@request.account.role = "editor" && owner = @request.auth.id'
        r = api_request(admin, "POST", "/api/collections", {
            "name": "notes", "type": "base", "viewRule": rule,
            "fields": [{"id": "", "name": name, "type": "text", "options": {}}
                       for name in ("owner", "title")]})
        assert r.status == 201, r.text()
        rid = _note(admin, owner=uid, title="initial")
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES('accountA','','','accountA')")
            db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES('memberA','','','accountA','users',?,'editor','active')", (uid,))
        member = member_context.new_page()
        r = member.request.post("/api/collections/users/auth-with-password",
                                data={"identity": "member@x.io", "password": "userpassword1"})
        assert r.status == 200, r.text()
        token = r.json()["token"]
        member.goto("/api/health")
        rt_open(member, transport)
        rt_send(member, {"action": "auth", "token": token})
        rt_wait_frame(member, "JSON.parse(f).status === 'ok'")
        rt_send(member, {"action": "subscribe", "topic": "notes"})
        rt_wait_frame(member, "JSON.parse(f).type === 'ack'")

        def update(title):
            r = api_request(admin, "PATCH", f"/api/collections/notes/records/{rid}", {"title": title})
            assert r.status == 200, r.text()

        update("before-change")
        rt_wait_frame(member, "f.includes('before-change')")
        with sqlite3.connect(database) as db:
            if change == "demote":
                db.execute("UPDATE _memberships SET role='viewer' WHERE id='memberA'")
            else:
                db.execute("DELETE FROM _memberships WHERE id='memberA'")
        update("after-change")
        member.wait_for_timeout(500)
        frames = member.evaluate("() => window.__rt.frames")
        assert not any("after-change" in f for f in frames), frames
        # Restore membership without reauthenticating or reopening the transport:
        # delivery must resume, proving the negative wasn't a dead connection.
        with sqlite3.connect(database) as db:
            db.execute("INSERT OR REPLACE INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES('memberA','','','accountA','users',?,'editor','active')", (uid,))
        update("restored")
        rt_wait_frame(member, "f.includes('restored')")
        assert not any("after-change" in f for f in member.evaluate("() => window.__rt.frames"))
