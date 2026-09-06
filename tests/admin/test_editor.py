import json
from conftest import login, api_request

def setup_posts(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "posts", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "body", "type": "editor", "options": {}},
                   {"id": "", "name": "meta", "type": "json", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()

def _meta_of(page, title):
    items = api_request(page, "GET", "/api/collections/posts/records").json()["items"]
    for it in items:
        if it.get("title") == title:
            m = it.get("meta")
            return json.loads(m) if isinstance(m, str) else m
    return None

def test_invalid_json_blocks_save_then_format_and_save(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'J1')

    # invalid JSON -> error shown + Save disabled
    page.fill('[data-test=in-meta]', '{ "a": }')
    page.wait_for_selector('[data-test=json-err-meta]')
    assert page.locator('[data-test=record-save]').is_disabled()

    # Format on invalid input is a no-op: still invalid, still disabled
    page.click('[data-test=json-format-meta]')
    assert page.locator('[data-test=record-save]').is_disabled()

    # fix it -> error clears, Save enables
    page.fill('[data-test=in-meta]', '{"a":1}')
    page.wait_for_selector('[data-test=json-err-meta]', state='detached')
    assert not page.locator('[data-test=record-save]').is_disabled()

    # Format pretty-prints
    page.click('[data-test=json-format-meta]')
    assert '\n' in page.locator('[data-test=in-meta]').input_value()

    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert _meta_of(page, 'J1') == {"a": 1}

def test_rich_text_round_trips_as_html(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'R1')

    body = page.locator('[data-test=in-body]')
    body.click()
    page.keyboard.type('Hello world')
    page.keyboard.press('Control+a')
    page.click('[data-test=rte-bold-body]')

    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)

    items = api_request(page, "GET", "/api/collections/posts/records").json()["items"]
    stored = next(it["body"] for it in items if it.get("title") == "R1")
    assert "Hello world" in stored
    assert ("<strong>" in stored) or ("<b>" in stored)  # execCommand emits one or the other

def test_paste_is_sanitized(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')

    # The drawer shell can render before its editor. Locator evaluation waits
    # for the actual paste target instead of racing a null DOM query.
    page.locator('[data-test=in-body]').evaluate("""el => {
      el.focus();
      const dt = new DataTransfer();
      dt.setData('text/html', '<img src=x onerror=alert(1)><script>alert(1)<\\/script><b>ok</b>');
      el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    }""")

    inner = page.locator('[data-test=in-body]').inner_html()
    assert 'ok' in inner
    assert '<script' not in inner.lower()
    assert 'onerror' not in inner.lower()
    assert '<img' not in inner.lower()

def test_sanitizer_drops_dangerous_content(page):
    login(page)
    out = page.evaluate("""async () => {
      const m = await import('/_/assets/lib/editor.js');
      return [
        m.sanitizeHtml('<svg><script>alert(1)<\\/script></svg>ok'),
        m.sanitizeHtml('<p onclick="x()" style="color:red">hi</p>'),
        m.sanitizeHtml('<a href="javascript:alert(1)">l</a>'),
        m.sanitizeHtml('<a href="https://ok.test">l</a>'),
        m.sanitizeHtml('<img src=x onerror=alert(1)><b>keep</b>'),
      ];
    }""")
    svg, attrs, jslink, oklink, img = out
    assert 'alert(1)' not in svg and 'ok' in svg
    assert 'onclick' not in attrs.lower() and 'style' not in attrs.lower() and 'hi' in attrs
    assert 'javascript' not in jslink.lower()
    assert 'href="https://ok.test"' in oklink and 'noopener' in oklink
    assert '<img' not in img.lower() and 'onerror' not in img.lower() and 'keep' in img

def test_live_surface_reflects_sanitized_html(page):
    # Content inserted straight into the contenteditable DOM (drag-drop, or a
    # toolbar command) must not linger in the editing surface after the sanitizer
    # strips it — emit() writes the clean HTML back. Simulate raw insertion then
    # fire the input event emit() listens on.
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')

    page.evaluate("""() => {
      const el = document.querySelector('[data-test=in-body]');
      el.focus();
      el.innerHTML = '<a href="javascript:alert(1)">x</a><b>ok</b>';
      el.dispatchEvent(new InputEvent('input', { bubbles: true }));
    }""")

    inner = page.locator('[data-test=in-body]').inner_html()
    assert 'ok' in inner
    assert 'javascript' not in inner.lower()   # unsafe href stripped from the live DOM
    assert '<a' not in inner.lower()           # href-less anchor unwrapped, not left behind
