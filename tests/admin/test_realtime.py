from conftest import login, api_request

def test_features_changed_signal_on_override(page):
    """The signal-only feature channel: an ANONYMOUS client may subscribe to the
    public `__features` channel, and writing a flag/experiment override broadcasts
    `{"type":"features.changed"}` on it (clients then re-GET /api/state)."""
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
        "window.__featFrames && window.__featFrames.some(f => f.includes('features.changed'))",
        timeout=8000,
    )
    # Clearing the override also signals.
    page.evaluate("() => { window.__featFrames = []; }")
    api_request(page, "DELETE", "/api/settings/flag:rt_signal_test")
    page.wait_for_function(
        "window.__featFrames && window.__featFrames.some(f => f.includes('features.changed'))",
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
