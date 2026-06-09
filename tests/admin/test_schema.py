from conftest import login, api_request

def test_create_collection_with_fields_via_ui(page):
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'tasks')
    page.click('[data-test=add-field]')
    page.fill('[data-test=field-name]', 'title')  # first (only) field row
    page.click('[data-test=save-collection]')
    # after save it navigates to the records view + reloads; the sidebar should list 'tasks'
    page.wait_for_selector('[data-test=nav-tasks]', timeout=8000)

def test_edit_rules_lock_toggle(page):
    login(page)
    # seed a base collection via the API (uses the session cookie + csrf)
    api_request(page, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [{"id": "", "name": "body", "type": "text", "options": {}}], "viewRule": ""})
    # full document load (query-busted) onto the schema route so the SPA mounts fresh on the editor
    page.goto("/_/?t=1#/collections/notes")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-rules]')
    # viewRule was "" (public) -> not locked; lock it
    page.check('[data-test=lock-viewRule]')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=nav-notes]', timeout=8000)
    # save navigates to the records view and reloads the page to refresh the sidebar;
    # wait for that post-save reload to settle before navigating back to the editor.
    page.wait_for_selector('[data-test=records-view]', timeout=8000)
    # reload editor: viewRule should now be locked (null -> checkbox checked)
    page.goto("/_/?t=2#/collections/notes")
    page.wait_for_selector('[data-test=schema-editor]', timeout=8000)
    page.click('[data-test=tab-rules]')
    assert page.is_checked('[data-test=lock-viewRule]')
