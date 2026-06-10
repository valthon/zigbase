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

def test_number_fixed_scale_roundtrip(page):
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'prices')
    page.click('[data-test=add-field]')
    page.fill('[data-test=field-name]', 'amount')
    page.select_option('[data-test=field-type]', 'number')
    page.select_option('[data-test=opt-mode]', 'fixed')
    page.fill('[data-test=opt-scale]', '2')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=nav-prices]', timeout=8000)
    page.wait_for_selector('[data-test=records-view]', timeout=8000)
    # the saved schema carries mode=fixed + scale=2
    col = next(c for c in api_request(page, "GET", "/api/collections").json() if c["name"] == "prices")
    fld = next(f for f in col["schema"] if f["name"] == "amount")
    assert fld["options"]["mode"] == "fixed"
    assert fld["options"]["scale"] == 2
    # reopen the editor: the scale input round-trips the stored value
    page.goto("/_/?t=1#/collections/prices")
    page.wait_for_selector('[data-test=schema-editor]', timeout=8000)
    assert page.input_value('[data-test=opt-scale]') == '2'
    # switching mode away from fixed drops scale from the saved options
    page.select_option('[data-test=opt-mode]', 'float')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=records-view]', timeout=8000)
    col = next(c for c in api_request(page, "GET", "/api/collections").json() if c["name"] == "prices")
    fld = next(f for f in col["schema"] if f["name"] == "amount")
    assert fld["options"]["mode"] == "float"
    assert "scale" not in fld["options"]

def test_number_fixed_without_scale_shows_field_error(page):
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'badprices')
    page.click('[data-test=add-field]')
    page.fill('[data-test=field-name]', 'amount')
    page.select_option('[data-test=field-type]', 'number')
    page.select_option('[data-test=opt-mode]', 'fixed')
    page.click('[data-test=save-collection]')
    # the server-side validation error renders under the field row
    page.wait_for_selector('[data-test=field-row] .error', timeout=8000)
    assert 'scale' in page.inner_text('[data-test=field-row] .error')
    assert not any(c["name"] == "badprices" for c in api_request(page, "GET", "/api/collections").json())

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
