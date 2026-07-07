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
