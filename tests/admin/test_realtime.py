from conftest import login, api_request

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
