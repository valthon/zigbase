from conftest import login, api_request

def setup_posts(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "posts", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "pinned", "type": "bool", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()

def test_create_edit_delete_record(page):
    setup_posts(page)
    page.goto("/_/?t=1#/collections/posts/records")
    page.wait_for_selector('[data-test=records-view]')
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'Hello')
    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert "Hello" in page.locator('[data-test=rows]').inner_text()
    # edit
    page.click('[data-test=row]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-title]', 'Edited')
    page.click('[data-test=record-save]')
    page.wait_for_function("document.querySelector('[data-test=rows]').innerText.includes('Edited')", timeout=6000)
    # delete
    page.click('[data-test=row]')
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=record-delete]')
    page.wait_for_selector('[data-test=empty]', timeout=6000)
