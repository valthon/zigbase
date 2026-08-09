import json as _json
import re
import socket
import time
import pytest
from urllib.parse import urlparse
from conftest import login, api_request


def _raw_exchange(host, port, raw: bytes, timeout=3.0) -> bytes:
    """Open a fresh TCP connection, send `raw`, read until the peer closes or times out,
    return whatever came back (b"" if the connection could not even be established)."""
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(raw)
        s.settimeout(timeout)
        chunks = []
        try:
            while True:
                b = s.recv(4096)
                if not b:
                    break
                chunks.append(b)
        except socket.timeout:
            pass
        return b"".join(chunks)


def test_malformed_ws_upgrade_does_not_crash_server(server):
    """SECURITY REGRESSION — unauthenticated remote double-free on the WS upgrade path.

    A WebSocket upgrade carrying an INVALID `Sec-WebSocket-Version` drives facil.io's
    `http1_http2websocket_server` down its `bad_request` branch, which sends a terminal 400
    AND invokes the connection's `on_close` (our teardown) ITSELF before returning -1.
    Pre-fix, `ws.handleUpgrade`'s `WS.upgrade catch { ... }` block then freed the `LiveConn`
    and released the shared connection slot a SECOND time -> heap double-free + double
    slot-release. No auth is required to reach this path, so it is a trivial remote DoS.

    Oracle: fire many malformed upgrades and assert the server is STILL serving afterwards.
    Under the debug-safety allocator the very first double-free aborts the process, so pre-fix
    the loop (or the final health probe) fails to connect; post-fix every request succeeds."""
    u = urlparse(server)
    host, port = u.hostname, u.port
    health = b"GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

    # Baseline: the server is up and answering before we start.
    assert b"200" in _raw_exchange(host, port, health), "server not healthy at start"

    malformed = (
        "GET /api/realtime HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 999\r\n"  # invalid (must be 13) -> facil.io bad_request path
        "\r\n"
    ).encode()

    # Repeat well past 1: the double-free is deterministic per hit, but iterating hardens the
    # oracle against any allocator that only trips on repeated corruption.
    for i in range(30):
        try:
            resp = _raw_exchange(host, port, malformed)
        except OSError as e:
            raise AssertionError(f"server unreachable on malformed upgrade #{i} (crashed?): {e}")
        assert b"400" in resp, f"iteration {i}: expected a 400 to the malformed upgrade, got {resp!r}"

    # The real assertion: after all those failure-path upgrades the server is alive and serving.
    # A double-free would have aborted the process, and this probe would raise instead.
    try:
        final = _raw_exchange(host, port, health)
    except OSError as e:
        raise AssertionError(f"server crashed after malformed upgrades (double-free?): {e}")
    assert b"200" in final, f"server not healthy after malformed upgrades: {final!r}"


def _recv_until(sock, needle: bytes, timeout=8.0) -> bytes:
    """Read from an already-open socket until `needle` appears or the peer closes/times out."""
    sock.settimeout(timeout)
    buf = b""
    while needle not in buf:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf


def test_sse_stream_and_uplink_end_to_end(server, page):
    """#188 SSE is END-TO-END reachable: open the EventSource stream, learn the clientId from the
    connect frame, drive a `subscribe` verb over the POST uplink, and receive a broadcast on that
    subscription off the SAME stream. Proves the whole off-reactor path Task 8 builds — openStream ->
    registry insert -> connect frame -> pin (worker thread) -> shared hub verb -> reply framing ->
    onChannelMessage delivery — plus the non-oracle 404 for an unknown clientId.

    All raw sockets (no browser): the uplink is a plain authenticated-by-capability POST an SDK makes,
    so the test speaks the same HTTP an SDK would. The clientId is a 32-char capability delivered only
    on this Origin-gated stream; a request with no Origin header is a non-browser client (allowed)."""
    u = urlparse(server)
    host, port = u.hostname, u.port

    # 1. Open a long-lived SSE stream (Accept: text/event-stream routes facil.io to the SSE upgrade),
    #    then read the connect frame to learn this connection's clientId.
    stream = socket.create_connection((host, port), timeout=5.0)
    stream.sendall((
        "GET /api/realtime/sse HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Accept: text/event-stream\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
    ).encode())
    connect = _recv_until(stream, b'"clientId"', timeout=5.0)
    m = re.search(rb'"clientId":"([^"]+)"', connect)
    assert m, f"no connect frame with a clientId on the SSE stream: {connect!r}"
    client_id = m.group(1).decode()
    assert len(client_id) == 32, f"clientId should be a 32-char capability, got {client_id!r}"

    # 2. Uplink `subscribe __features` (public, anonymous-allowed) over POST -> 200 + the exact ack
    #    frame WS would have written. This runs the SAME hub.subscribeCheck the WS socket runs.
    sub_body = b'{"action":"subscribe","topic":"__features"}'
    resp = _raw_exchange(host, port, (
        f"POST /api/realtime/sse/{client_id} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(sub_body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode() + sub_body)
    assert b" 200 " in resp, f"uplink subscribe should 200, got {resp!r}"
    assert b'"type":"ack"' in resp and b'__features' in resp, f"expected an ack frame, got {resp!r}"

    # 3. Non-oracle: an unknown clientId 404s with the byte-identical body of any not-found (the
    #    just-closed and unknown cases are indistinguishable to a probing client).
    bogus = _raw_exchange(host, port, (
        "POST /api/realtime/sse/WRONGIDWRONGIDWRONGIDWRONGIDWRON HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 2\r\n"
        "Connection: close\r\n"
        "\r\n"
        "{}"
    ).encode())
    assert b" 404 " in bogus, f"unknown clientId should 404, got {bogus!r}"
    assert b'{"status":404,"code":"not_found","message":"Not found.","data":{}}' in bogus, f"non-oracle 404 body, got {bogus!r}"

    # 4. Delivery leg: a superuser feature-override broadcasts the signal frame on __features, which
    #    must arrive on the SSE stream we subscribed in step 2 -> the full stream+uplink+delivery loop.
    login(page)
    api_request(page, "PUT", "/api/settings/flag:sse_e2e", {"value": "true"})
    delivered = _recv_until(stream, b'"type":"signal"', timeout=8.0)
    stream.close()
    assert b'"topic":"__features"' in delivered, f"no __features signal delivered on the SSE stream: {delivered!r}"


@pytest.mark.parametrize("server", [{"ZIGBASE_REALTIME_OUTBOUND_HWM": "4"}], indirect=True)
def test_slow_sse_consumer_disconnected_at_hwm(server, page):
    """issue #203: a STALLED SSE reader must be DISCONNECTED once its queued outbound frames
    exceed the per-connection high-water-mark, instead of the server buffering frames without
    bound (OOM/DoS). The server is launched with ZIGBASE_REALTIME_OUTBOUND_HWM=4.

    Mechanism: open an SSE stream on a raw socket with a TINY SO_RCVBUF, subscribe to a @public
    collection, then STOP reading. A burst of large-payload create events fills the peer's
    receive window + the server's send buffer, so facil.io's per-socket queue (`fio_pending`)
    climbs past the HWM; the delivery chokepoint then closes our stream. Oracle: the stalled
    socket reaches EOF/reset (server dropped us) AND the server stays healthy afterwards. WS
    shares the identical predicate + chokepoint (connection.outboundOverHwm, unit-tested).

    Reliability (why LARGE frames + a settle BEFORE draining): `fio_pending` (the socket's
    queued-write count) climbs once the server's send buffer is full and `write()` returns EAGAIN.
    facil.io pins accepted sockets' SO_SNDBUF to 131072 (fio.c), so ~256 KiB blocks the socket —
    with ~256 KiB frames that is ONE frame, so the HWM is crossed after only a handful of
    deliveries. Crucially we must NOT start reading until the disconnect has latched: draining
    reopens the peer's TCP window, frames flush, and `fio_pending` would fall back under the HWM —
    so on a slow runner where the reactor lags the burst, an early read would let the connection
    survive. We therefore hold the window closed (don't read) and sleep after the burst, giving the
    reactor time to cross the HWM and latch `fio_close` (latched: it can't flush a blocked socket,
    but the pending close survives until our later drain reopens the window). This is the fix for
    the CI-only failure of the naive read-immediately version."""
    u = urlparse(server)
    host, port = u.hostname, u.port

    # A @public collection with a large text field: each create event is a big frame, so a few
    # unread frames fill the buffers and trip the (tiny) HWM deterministically — no need to fire
    # thousands of records. createRule @public lets the burst be fast, anonymous raw HTTP.
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "slow_pub", "type": "base",
        "fields": [{"id": "", "name": "blob", "type": "text", "options": {}}],
        "listRule": "@public", "viewRule": "@public", "createRule": "@public",
        "updateRule": "", "deleteRule": ""})

    # Open the SSE stream with a tiny receive buffer, learn the clientId, then never read again.
    stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    stream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)  # shrink the peer window
    stream.connect((host, port))
    stream.settimeout(5.0)
    stream.sendall((
        "GET /api/realtime/sse HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Accept: text/event-stream\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
    ).encode())
    connect = _recv_until(stream, b'"clientId"', timeout=5.0)
    m = re.search(rb'"clientId":"([^"]+)"', connect)
    assert m, f"no clientId on the SSE stream: {connect!r}"
    client_id = m.group(1).decode()

    # Subscribe to the public collection over the uplink (separate short-lived connection).
    sub = b'{"action":"subscribe","topic":"slow_pub"}'
    ack = _raw_exchange(host, port, (
        f"POST /api/realtime/sse/{client_id} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(sub)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + sub)
    assert b'"type":"ack"' in ack, f"subscribe not acked: {ack!r}"

    # Burst of large-payload creates while the stream socket is NOT being read. Each ~256 KiB
    # create is one ~256 KiB event frame queued to our stalled stream; with the pinned ~256 KiB
    # send buffer the socket blocks after ~1 frame, so fio_pending crosses the HWM within a few
    # deliveries. createRule @public lets the burst be fast, anonymous HTTP.
    body = _json.dumps({"blob": "x" * (256 * 1024)}).encode()
    for _ in range(32):
        _raw_exchange(host, port, (
            "POST /api/collections/slow_pub/records HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode() + body, timeout=5.0)

    # Keep the peer window CLOSED (do NOT read) and let the reactor catch up: it delivers the
    # queued frames, crosses the HWM, and latches fio_close on the stalled socket. Reading now
    # would reopen the window and let fio_pending fall back under the HWM before the disconnect
    # fires, so this settle is load-bearing for slow runners (see the docstring).
    time.sleep(5.0)

    # NOW drain: the first read reopens the window, facil flushes the backlog, then sends FIN once
    # the latched close completes -> we read the backlog and hit EOF (b"") or a reset. A timeout
    # with the socket still open => the server did NOT shed us (regression). Generous for slow CI.
    stream.settimeout(15.0)
    closed = False
    try:
        while True:
            chunk = stream.recv(65536)
            if not chunk:
                closed = True  # clean EOF: the server closed the stream
                break
    except (ConnectionResetError, ConnectionAbortedError):
        closed = True  # RST: the server dropped the slow consumer
    except socket.timeout:
        closed = False  # still open, no EOF => NOT disconnected
    finally:
        stream.close()
    assert closed, "server did not disconnect the stalled slow SSE consumer (issue #203)"

    # After shedding the slow consumer the server is still serving.
    health = _raw_exchange(host, port, b"GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    assert b"200" in health, f"server unhealthy after disconnecting slow consumer: {health!r}"


def test_features_changed_signal_on_override(page):
    """The signal-only feature channel: an ANONYMOUS client may subscribe to the
    public `__features` channel, and writing a flag/experiment override broadcasts
    the standard signal frame `{"type":"signal","topic":"__features"}` on it
    (clients then re-GET /api/state)."""
    login(page)  # superuser session, for the override PUT below
    # Open a SEPARATE, anonymous WS (no auth frame) subscribed to __features. Same-origin
    # (location.host) so the upgrade's Origin check passes without an allowlist.
    page.evaluate(
        """() => {
            window.__featFrames = [];
            const proto = location.protocol === 'https:' ? 'wss' : 'ws';
            const ws = new WebSocket(proto + '://' + location.host + '/api/realtime');
            ws.onmessage = (e) => { window.__featFrames.push(e.data); };
            ws.onopen = () => { ws.send(JSON.stringify({action: 'subscribe', topic: '__features'})); };
        }"""
    )
    # Anonymous subscribe to the public signal channel is acknowledged (not rejected).
    page.wait_for_function(
        "window.__featFrames && window.__featFrames.some(f => f.includes('\"ack\"') && f.includes('__features'))",
        timeout=8000,
    )
    # Writing a feature override (superuser) fans out the signal on __features.
    api_request(page, "PUT", "/api/settings/flag:rt_signal_test", {"value": "true"})
    page.wait_for_function(
        "window.__featFrames && window.__featFrames.some(f => f.includes('\"type\":\"signal\"') && f.includes('\"topic\":\"__features\"'))",
        timeout=8000,
    )
    # Clearing the override also signals.
    page.evaluate("() => { window.__featFrames = []; }")
    api_request(page, "DELETE", "/api/settings/flag:rt_signal_test")
    page.wait_for_function(
        "window.__featFrames && window.__featFrames.some(f => f.includes('\"type\":\"signal\"') && f.includes('\"topic\":\"__features\"'))",
        timeout=8000,
    )

def test_records_table_updates_live(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "live", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()
    page.goto("/_/?t=1#/collections/live/records")
    page.wait_for_selector('[data-test=records-view]')
    # give the WS time to auth+subscribe
    page.wait_for_timeout(800)
    # create a record via the API (out of band) -> a live 'create' event should add a row
    api_request(page, "POST", "/api/collections/live/records", {"title": "LiveRow"})
    page.wait_for_function("document.querySelector('[data-test=rows]') && document.querySelector('[data-test=rows]').innerText.includes('LiveRow')", timeout=8000)


# --- Dual-transport delivery matrix (#188) ---------------------------------
#
# Everything below drives the SAME assertions against BOTH the WebSocket and
# SSE transports, proving the two share one delivery path (hub.frameForDelivery)
# and one authorization outcome. A transport-neutral in-page client speaks
# both framings behind one `window.__rt` interface (frames array + send), so
# each scenario is written once and parametrized over `transport`.

RT_CLIENT_JS = """(transport) => {
    window.__rt = { frames: [], clientId: null, transport };
    const push = (d) => {
        window.__rt.frames.push(d);
        try { const m = JSON.parse(d); if (m.type === 'connect') window.__rt.clientId = m.clientId; } catch {}
    };
    if (transport === 'ws') {
        const proto = location.protocol === 'https:' ? 'wss' : 'ws';
        const ws = new WebSocket(proto + '://' + location.host + '/api/realtime');
        ws.onmessage = (e) => push(e.data);
        window.__rtSend = (frame) => new Promise((resolve) => {
            const go = () => { ws.send(JSON.stringify(frame)); resolve(200); };
            if (ws.readyState === 1) go(); else ws.onopen = go;
        });
    } else {
        const es = new EventSource('/api/realtime/sse');
        es.onmessage = (e) => push(e.data);
        window.__rtClose = () => es.close();
        window.__rtSend = async (frame) => {
            while (!window.__rt.clientId) await new Promise(r => setTimeout(r, 25));
            const r = await fetch('/api/realtime/sse/' + window.__rt.clientId, { method: 'POST', body: JSON.stringify(frame) });
            push(await r.text()); // uplink replies ARE protocol frames — one frame path
            return r.status;
        };
    }
}"""

def rt_open(page, transport):
    page.evaluate(RT_CLIENT_JS, transport)

def rt_send(page, frame):
    return page.evaluate("(f) => window.__rtSend(f)", frame)

def rt_wait_frame(page, needle_js, timeout=8000):
    page.wait_for_function(
        f"window.__rt && window.__rt.frames.some(f => {needle_js})", timeout=timeout)

def superuser_token(page):
    r = page.request.post("/api/collections/_superusers/auth-with-password",
                          data=_json.dumps({"identity": "admin@x.io", "password": "adminpassword"}),
                          headers={"Content-Type": "application/json"})
    return r.json()["token"]

@pytest.mark.parametrize("transport", ["ws", "sse"])
def test_rt_connect_and_public_delivery(page, transport):
    """Matrix: connect frame delivers a clientId; ANONYMOUS subscribe to a @public collection
    is acked and create/update events are delivered — byte-identical frame grammar on both
    transports (#188)."""
    login(page)
    api_request(page, "POST", "/api/collections", {"name": f"m_{transport}_pub", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
        "listRule": "@public", "viewRule": "@public", "createRule": "", "updateRule": "", "deleteRule": ""})
    rt_open(page, transport)
    rt_send(page, {"action": "subscribe", "topic": f"m_{transport}_pub"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"') && f.includes('subscribe')")
    api_request(page, "POST", f"/api/collections/m_{transport}_pub/records", {"title": "Hello"})
    rt_wait_frame(page, "f.includes('\"type\":\"event\"') && f.includes('\"action\":\"create\"') && f.includes('Hello')")

@pytest.mark.parametrize("transport", ["ws", "sse"])
def test_rt_locked_requires_auth_then_delivers(page, transport):
    """Matrix: anonymous subscribe to a LOCKED collection is rejected with the standard error
    frame; after the auth verb (superuser token in the BODY — never a URL) the subscribe acks
    and events deliver."""
    login(page)
    tok = superuser_token(page)
    api_request(page, "POST", "/api/collections", {"name": f"m_{transport}_lk", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    rt_open(page, transport)
    rt_send(page, {"action": "subscribe", "topic": f"m_{transport}_lk"})
    rt_wait_frame(page, "f.includes('authentication required to subscribe')")
    rt_send(page, {"action": "auth", "token": tok})
    rt_wait_frame(page, "f.includes('\"type\":\"auth\"') && f.includes('\"status\":\"ok\"')")
    rt_send(page, {"action": "subscribe", "topic": f"m_{transport}_lk"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"')")
    api_request(page, "POST", f"/api/collections/m_{transport}_lk/records", {"title": "Sekrit"})
    rt_wait_frame(page, "f.includes('\"action\":\"create\"') && f.includes('Sekrit')")

@pytest.mark.parametrize("transport", ["ws", "sse"])
def test_rt_delete_is_id_only_and_gated(page, transport):
    """Matrix (F4): on a locked collection, the authed subscriber receives an ID-ONLY delete
    frame (no snapshot leak — no field values in the frame); an anonymous second stream
    receives NOTHING for the same delete."""
    login(page)
    tok = superuser_token(page)
    api_request(page, "POST", "/api/collections", {"name": f"m_{transport}_dl", "type": "base",
        "fields": [{"id": "", "name": "secretfield", "type": "text", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    rec = api_request(page, "POST", f"/api/collections/m_{transport}_dl/records", {"secretfield": "topsecretvalue"}).json()
    # Stream 1: authed subscriber.
    rt_open(page, transport)
    rt_send(page, {"action": "auth", "token": tok})
    rt_wait_frame(page, "f.includes('\"status\":\"ok\"')")
    rt_send(page, {"action": "subscribe", "topic": f"m_{transport}_dl"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"')")
    # Stream 2 (anonymous, second in-page client under different globals): must stay silent.
    page.evaluate("""() => {
        window.__anonFrames = [];
        const es = new EventSource('/api/realtime/sse');
        es.onmessage = async (e) => {
            window.__anonFrames.push(e.data);
            const m = JSON.parse(e.data);
            if (m.type === 'connect') {
                await fetch('/api/realtime/sse/' + m.clientId, { method: 'POST',
                    body: JSON.stringify({action: 'subscribe', topic: '%s'}) });
            }
        };
    }""" % f"m_{transport}_dl")
    page.wait_for_timeout(500)  # let the anon subscribe settle (its error frame is fine)
    api_request(page, "DELETE", f"/api/collections/m_{transport}_dl/records/{rec['id']}")
    rt_wait_frame(page, "f.includes('\"action\":\"delete\"') && f.includes('%s')" % rec["id"])
    frames = page.evaluate("() => window.__rt.frames")
    deletes = [f for f in frames if '"action":"delete"' in f]
    assert deletes and all("topsecretvalue" not in f and "_deleteSnapshot" not in f for f in deletes), deletes
    anon = page.evaluate("() => window.__anonFrames")
    assert not any('"action":"delete"' in f for f in anon), anon

@pytest.mark.parametrize("transport", ["ws", "sse"])
def test_rt_features_signal(page, transport):
    """Matrix: the public __features signal channel works on both transports (the existing
    WS-only test keeps running unchanged; this adds the parameterized arm)."""
    login(page)
    rt_open(page, transport)
    rt_send(page, {"action": "subscribe", "topic": "__features"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"') && f.includes('__features')")
    api_request(page, "PUT", "/api/settings/flag:rt_matrix_test", {"value": "true"})
    rt_wait_frame(page, "f.includes('\"type\":\"signal\"') && f.includes('\"topic\":\"__features\"')")
    api_request(page, "DELETE", "/api/settings/flag:rt_matrix_test")

@pytest.mark.parametrize("transport", ["ws", "sse"])
def test_rt_unsubscribe_stops_delivery(page, transport):
    """Matrix: unsubscribe acks and stops delivery."""
    login(page)
    api_request(page, "POST", "/api/collections", {"name": f"m_{transport}_un", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
        "listRule": "@public", "viewRule": "@public", "createRule": "", "updateRule": "", "deleteRule": ""})
    rt_open(page, transport)
    rt_send(page, {"action": "subscribe", "topic": f"m_{transport}_un"})
    rt_wait_frame(page, "f.includes('\"type\":\"ack\"') && f.includes('subscribe')")
    rt_send(page, {"action": "unsubscribe", "topic": f"m_{transport}_un"})
    rt_wait_frame(page, "f.includes('\"action\":\"unsubscribe\"')")
    api_request(page, "POST", f"/api/collections/m_{transport}_un/records", {"title": "AfterUnsub"})
    page.wait_for_timeout(1500)
    assert not any("AfterUnsub" in f for f in page.evaluate("() => window.__rt.frames"))

def test_sse_uplink_404_is_non_oracle(page):
    """SSE-only: a never-existed clientId and a just-closed clientId answer BYTE-IDENTICAL
    404 bodies (no liveness oracle)."""
    login(page)
    rt_open(page, "sse")
    page.wait_for_function("window.__rt.clientId !== null", timeout=8000)
    cid = page.evaluate("() => window.__rt.clientId")
    bogus = page.evaluate("""async () => {
        const r = await fetch('/api/realtime/sse/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', {method:'POST', body:'{}'});
        return { status: r.status, body: await r.text() };
    }""")
    assert bogus["status"] == 404
    page.evaluate("() => window.__rtClose()")
    # Poll until the server has reaped the stream (on_close), then compare bodies.
    closed = page.evaluate("""async (cid) => {
        for (let i = 0; i < 80; i++) {
            const r = await fetch('/api/realtime/sse/' + cid, {method:'POST', body:'{}'});
            if (r.status === 404) return { status: r.status, body: await r.text() };
            await new Promise(res => setTimeout(res, 100));
        }
        return { status: -1, body: '' };
    }""", cid)
    assert closed["status"] == 404
    assert closed["body"] == bogus["body"]  # NON-ORACLE: byte-identical

@pytest.mark.parametrize("server", [{"ZIGBASE_SSE_HEARTBEAT_SECONDS": "2"}], indirect=True)
def test_sse_heartbeat_ping_comment(page):
    """SSE-only: with a 2s heartbeat the raw stream carries the facil.io `: ping` comment on
    an idle stream within 8s (EventSource hides comments, so read the raw bytes via fetch)."""
    login(page)  # loads a real document so the request below has a base URL to resolve against
    # NOTE: fetch()'s ReadableStream reader does NOT work here — this response is
    # close-delimited (no Content-Length, no Transfer-Encoding: chunked; the connection
    # just stays open), and Chromium's fetch() buffers such streams internally and never
    # surfaces a handful of small chunks (a ~70-byte connect frame plus 8-byte pings) to
    # the reader within the window. XMLHttpRequest's onprogress + incrementally-growing
    # responseText does not have that buffering and delivers bytes as they arrive on the
    # wire, which is what a raw-bytes assertion on a live comment needs.
    got = page.evaluate("""async () => {
        return await new Promise((resolve) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', '/api/realtime/sse');
            xhr.setRequestHeader('Accept', 'text/event-stream');
            let done = false;
            const finish = (v) => { if (!done) { done = true; xhr.abort(); resolve(v); } };
            xhr.onprogress = () => { if (xhr.responseText.includes(': ping')) finish(true); };
            setTimeout(() => finish(false), 8000);
            xhr.send();
        });
    }""")
    assert got, "no ': ping' heartbeat comment on the idle SSE stream within 8s"
