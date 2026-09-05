"""Real HTTP and browser ceremonies for the shipped two-factor configuration."""
import base64
import hashlib
import hmac
import json
import struct
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import pytest


def request(base, path, body=None, token=None, method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers=headers, method=method or ("POST" if body is not None else "GET"))
    try:
        response = urllib.request.urlopen(req)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if data else None, response.headers


def setup(base, mode="required", webauthn=False):
    status, admin, _ = request(base, "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200
    methods = {"password": {}}
    if webauthn:
        methods["webauthn"] = {"rp_id": urlsplit(base).hostname, "rp_name": "Two factor test", "origin": base}
    status, _, _ = request(base, "/api/collections", {
        "name": "members", "type": "auth", "fields": [],
        "viewRule": "id = @request.auth.id",
        "options": {"auth": {"two_factor": mode, "methods": methods}},
    }, admin["token"])
    assert status == 201
    status, user, _ = request(base, "/api/collections/members/records", {"email": "member@example.test", "password": "longenough"}, admin["token"])
    assert status == 201
    return user["id"]


def login(base):
    return request(base, "/api/collections/members/auth-with-password", {"identity": "member@example.test", "password": "longenough"})


def factor(base, action, pending, **proof):
    return request(base, f"/api/collections/members/auth/two-factor/{action}", {"pendingToken": pending, **proof})


def totp(secret, offset=0):
    counter = int(time.time()) // 30 + offset
    digest = hmac.new(base64.b32decode(secret), struct.pack(">Q", counter), hashlib.sha1).digest()
    start = digest[-1] & 15
    return f"{(struct.unpack('>I', digest[start:start + 4])[0] & 0x7fffffff) % 1000000:06d}"


def enroll_totp(base, pending):
    status, ceremony, _ = factor(base, "enroll-begin", pending, factor="totp")
    assert status == 200
    status, result, _ = factor(base, "enroll-complete", pending, factor="totp", ceremonyId=ceremony["ceremonyId"], code=totp(ceremony["secret"]))
    assert status == 200, result
    return ceremony["secret"], result


def test_required_totp_enrollment_login_recovery_and_replay(server):
    user_id = setup(server)
    status, pending, headers = login(server)
    assert status == 200 and pending["status"] == "enrollment_required"
    assert "token" not in pending and not headers.get_all("Set-Cookie")
    assert request(server, f"/api/collections/members/records/{user_id}", token=pending["pendingToken"])[0] in (401, 403, 404)
    secret, enrolled = enroll_totp(server, pending["pendingToken"])
    assert len(enrolled["recoveryCodes"]) == 10 and len(set(enrolled["recoveryCodes"])) == 10
    assert request(server, f"/api/collections/members/records/{user_id}", token=enrolled["token"])[0] == 200
    assert factor(server, "enroll-begin", pending["pendingToken"], factor="totp")[0] == 401
    _, pending, _ = login(server)
    assert pending["status"] == "factor_required"
    status, completed, _ = factor(server, "complete", pending["pendingToken"], factor="totp", code=totp(secret, 1))
    assert status == 200, completed
    assert factor(server, "complete", pending["pendingToken"], factor="totp", code=totp(secret, 1))[0] == 401
    status, refreshed, _ = request(server, "/api/collections/members/auth-refresh", {}, completed["token"])
    assert status == 200 and refreshed["token"]
    _, pending, _ = login(server)
    recovery = enrolled["recoveryCodes"][0]
    status, recovered, _ = factor(server, "complete", pending["pendingToken"], factor="recovery", code=recovery)
    assert status == 200 and recovered["managementToken"]
    _, pending, _ = login(server)
    assert factor(server, "complete", pending["pendingToken"], factor="recovery", code=recovery)[0] == 401


def test_optional_enrollment_rejects_old_session_and_allows_factor_removal(server):
    setup(server, "optional")
    _, primary, _ = login(server)
    assert primary["token"]
    status, pending, _ = request(server, "/api/collections/members/auth/two-factor/enroll", {}, primary["token"])
    assert status == 200
    _, enrolled = enroll_totp(server, pending["pendingToken"])
    assert request(server, "/api/collections/members/auth-refresh", {}, primary["token"])[0] == 401
    status, _, _ = factor(server, "remove", enrolled["managementToken"], factor="totp")
    assert status == 204
    _, primary_again, _ = login(server)
    assert primary_again["token"]


def test_required_factor_cannot_be_removed_and_recovery_replacement_revokes(server):
    setup(server)
    _, pending, _ = login(server)
    _, enrolled = enroll_totp(server, pending["pendingToken"])
    assert factor(server, "remove", enrolled["managementToken"], factor="totp")[0] == 400
    status, replacement, _ = factor(server, "replace-recovery", enrolled["managementToken"])
    assert status == 200 and replacement["reauthenticate"]
    assert request(server, "/api/collections/members/auth-refresh", {}, enrolled["token"])[0] == 401
    assert factor(server, "replace-recovery", enrolled["managementToken"])[0] == 401
    _, pending, _ = login(server)
    assert factor(server, "complete", pending["pendingToken"], factor="recovery", code=enrolled["recoveryCodes"][0])[0] == 401
    assert factor(server, "complete", pending["pendingToken"], factor="recovery", code=replacement["recoveryCodes"][0])[0] == 200


def test_pending_binding_and_concurrent_recovery_consumption(server):
    from concurrent.futures import ThreadPoolExecutor

    setup(server)
    _, pending, _ = login(server)
    _, competing, _ = login(server)
    _, ceremony, _ = factor(server, "enroll-begin", pending["pendingToken"], factor="totp")
    assert factor(server, "enroll-complete", competing["pendingToken"], factor="totp", ceremonyId=ceremony["ceremonyId"], code=totp(ceremony["secret"]))[0] == 401
    _, enrolled = enroll_totp(server, pending["pendingToken"])
    assert factor(server, "enroll-begin", competing["pendingToken"], factor="totp")[0] == 401
    _, first, _ = login(server)
    _, second, _ = login(server)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda p: factor(server, "complete", p["pendingToken"], factor="recovery", code=enrolled["recoveryCodes"][0])[0], [first, second]))
    assert sorted(results) == [200, 401]


def test_admin_required_enrollment_ui(server, page):
    _, admin, _ = request(server, "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    status, result, _ = request(server, "/api/collections/_superusers", {"name": "_superusers", "type": "auth", "system": True, "fields": [], "options": {"auth": {"two_factor": "required"}}}, admin["token"], "PATCH")
    assert status == 200, result
    page.goto(server + "/_/#/login")
    page.locator('[data-test="email"]').fill("admin@x.io")
    page.locator('[data-test="password"]').fill("adminpassword")
    page.locator('[data-test="login-submit"]').click()
    secret = page.locator("code").inner_text()
    assert request(server, "/api/collections", token=admin["token"])[0] in (401, 403)
    page.locator('[data-test="second-factor-code"]').fill(totp(secret))
    page.locator('[data-test="login-submit"]').click()
    assert len(page.locator('[data-test="recovery-codes"]').inner_text().splitlines()) == 10
    page.get_by_role("button", name="I saved my recovery codes").click()
    page.wait_for_url("**/#/collections")


@pytest.mark.parametrize("server", [{"ZIGBASE_RATE_LIMIT_MAX": "0"}], indirect=True)
def test_second_factor_budget_survives_new_primary_logins(server):
    setup(server)
    _, pending, _ = login(server)
    enroll_totp(server, pending["pendingToken"])
    results = []
    for _ in range(11):
        _, pending, _ = login(server)
        results.append(factor(server, "complete", pending["pendingToken"], factor="totp", code="not-a-code")[0])
    assert 429 in results
    assert all(status in (401, 429) for status in results)


def test_webauthn_second_factor_with_browser_authenticator(server, page):
    server = server.replace("127.0.0.1", "localhost")
    user_id = setup(server, webauthn=True)
    page.goto(server + "/_/#/login")
    cdp = page.context.new_cdp_session(page)
    cdp.send("WebAuthn.enable")
    cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {"protocol": "ctap2", "transport": "internal", "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True, "automaticPresenceSimulation": True}})
    _, pending, _ = login(server)
    status, options, _ = factor(server, "enroll-begin", pending["pendingToken"], factor="webauthn")
    assert status == 200, options
    create_script = """async options => {
      const decode = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
      const encode = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      options.challenge = decode(options.challenge); options.user.id = decode(options.user.id);
      const c = await navigator.credentials.create({publicKey: options});
      return {attestationObject: encode(c.response.attestationObject), clientDataJSON: encode(c.response.clientDataJSON)};
    }"""
    proof = page.evaluate(create_script, options)
    status, enrolled, _ = factor(server, "enroll-complete", pending["pendingToken"], factor="webauthn", ceremonyId=options["ceremonyId"], **proof)
    assert status == 200, enrolled
    _, pending, _ = login(server)
    _, options, _ = factor(server, "initiate", pending["pendingToken"], factor="webauthn")
    proof = page.evaluate("""async options => {
      const decode = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
      const encode = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      options.challenge = decode(options.challenge);
      options.allowCredentials = options.allowCredentials.map(c => ({...c, id: decode(c.id)}));
      const c = await navigator.credentials.get({publicKey: options});
      return {credentialId: c.id, authenticatorData: encode(c.response.authenticatorData), clientDataJSON: encode(c.response.clientDataJSON), signature: encode(c.response.signature)};
    }""", options)
    status, complete, _ = factor(server, "complete", pending["pendingToken"], factor="webauthn", ceremonyId=options["ceremonyId"], **proof)
    assert status == 200, complete
    assert request(server, f"/api/collections/members/records/{user_id}", token=complete["token"])[0] == 200
    assert factor(server, "complete", pending["pendingToken"], factor="webauthn", ceremonyId=options["ceremonyId"], **proof)[0] == 401


@pytest.mark.parametrize("transport", ["ws", "sse"])
@pytest.mark.parametrize("change", ["required", "enrolled", "removed"])
def test_open_realtime_rechecks_two_factor_and_revocation(server, page, transport, change):
    from test_realtime import rt_open, rt_send, rt_wait_frame

    setup(server, mode="optional")
    _, primary, _ = login(server)
    session = primary
    if change == "removed":
        _, pending, _ = request(server, "/api/collections/members/auth/two-factor/enroll", {}, primary["token"])
        _, session = enroll_totp(server, pending["pendingToken"])
    _, admin, _ = request(server, "/api/collections/_superusers/auth-with-password",
                          {"identity": "admin@x.io", "password": "adminpassword"})
    status, result, _ = request(server, "/api/collections", {
        "name": "private_events", "type": "base",
        "fields": [{"id": "", "name": "message", "type": "text", "options": {}}],
        "viewRule": '@request.auth.id != ""',
    }, admin["token"])
    assert status == 201, result
    page.goto(server + "/_/")
    rt_open(page, transport)
    rt_send(page, {"action": "auth", "token": session["token"]})
    rt_wait_frame(page, "f.includes('\"type\":\"auth\"') && f.includes('\"status\":\"ok\"')")
    rt_send(page, {"action": "subscribe", "topic": "private_events"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"')")

    def publish(message):
        assert request(server, "/api/collections/private_events/records", {"message": message}, admin["token"])[0] == 201

    publish("before-policy-change")
    rt_wait_frame(page, "f.includes('before-policy-change')")
    if change == "required":
        assert request(server, "/api/collections/members", {
            "name": "members", "type": "auth", "fields": [],
            "viewRule": "id = @request.auth.id",
            "options": {"auth": {"two_factor": "required"}},
        }, admin["token"], method="PATCH")[0] == 200
        _, pending, _ = login(server)
    elif change == "enrolled":
        _, pending, _ = request(server, "/api/collections/members/auth/two-factor/enroll", {}, primary["token"])
    else:
        assert factor(server, "remove", session["managementToken"], factor="totp")[0] == 204
    if change == "enrolled":
        _, fresh = enroll_totp(server, pending["pendingToken"])
    elif change == "removed":
        _, fresh, _ = login(server)

    # The existing connection must lose access without sending a new auth frame.
    assert request(server, "/api/collections/members/auth-refresh", {}, session["token"])[0] == 401
    publish("must-not-deliver")
    page.wait_for_timeout(300)
    assert not any("must-not-deliver" in f for f in page.evaluate("window.__rt.frames"))
    rt_send(page, {"action": "subscribe", "topic": "private_events/new-id"})
    rt_wait_frame(page, "f.includes('authentication required to subscribe')")
    # A new, valid session restores delivery on the same transport.
    if change == "required":
        _, fresh = enroll_totp(server, pending["pendingToken"])
    page.evaluate("window.__rt.frames = []")
    rt_send(page, {"action": "auth", "token": fresh["token"]})
    rt_wait_frame(page, "f.includes('\"type\":\"auth\"') && f.includes('\"status\":\"ok\"')")
    publish("after-reauthentication")
    rt_wait_frame(page, "f.includes('after-reauthentication')")
