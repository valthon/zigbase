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

def test_number_fixed_non_integer_scale_shows_field_error(page):
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'floatscale')
    page.click('[data-test=add-field]')
    page.fill('[data-test=field-name]', 'amount')
    page.select_option('[data-test=field-type]', 'number')
    page.select_option('[data-test=opt-mode]', 'fixed')
    # a non-integer scale must not be sent (it would 400 with a top-level
    # "Invalid request body." and no field attribution); omitting it instead
    # surfaces the server's inline validation_invalid_scale under the row
    page.fill('[data-test=opt-scale]', '2.5')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=field-row] .error', timeout=8000)
    assert 'scale' in page.inner_text('[data-test=field-row] .error')
    assert not any(c["name"] == "floatscale" for c in api_request(page, "GET", "/api/collections").json())

def test_edit_rules_lock_toggle(page):
    login(page)
    # seed a base collection that starts PUBLIC via the explicit "@public" sentinel, so we can
    # toggle it to Locked. Safe-by-default semantics (F3): null/"" both mean Locked (admins only);
    # only "@public" is allow-all. The rule editor is a three-state select (locked/expr/public).
    api_request(page, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [{"id": "", "name": "body", "type": "text", "options": {}}], "viewRule": "@public"})
    # full document load (query-busted) onto the schema route so the SPA mounts fresh on the editor
    page.goto("/_/?t=1#/collections/notes")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-rules]')
    # viewRule was "@public" -> the rule-mode select reads "public"; toggle it to Locked
    assert page.input_value('[data-test=rulemode-viewRule]') == 'public'
    page.select_option('[data-test=rulemode-viewRule]', 'locked')  # -> sets the rule to "" (no confirm)
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=nav-notes]', timeout=8000)
    # save navigates to the records view and reloads the page to refresh the sidebar;
    # wait for that post-save reload to settle before navigating back to the editor.
    page.wait_for_selector('[data-test=records-view]', timeout=8000)
    # reload editor: viewRule should now be Locked (persisted null/"" -> mode "locked")
    page.goto("/_/?t=2#/collections/notes")
    page.wait_for_selector('[data-test=schema-editor]', timeout=8000)
    page.click('[data-test=tab-rules]')
    assert page.input_value('[data-test=rulemode-viewRule]') == 'locked'
    assert page.is_visible('[data-test=locktag-viewRule]')


def test_edit_rules_expression_from_locked(page):
    # Regression: selecting "Expression" on a Locked rule must REVEAL the text
    # input and let you type one. Previously the empty seed value derived back to
    # Locked, so the input never rendered and an expression could never be set.
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "memos", "type": "base", "fields": [{"id": "", "name": "body", "type": "text", "options": {}}]})
    page.goto("/_/?t=1#/collections/memos")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-rules]')
    # default is Locked; no expression input yet
    assert page.input_value('[data-test=rulemode-listRule]') == 'locked'
    assert page.locator('[data-test=rule-listRule]').count() == 0
    # switch to Expression -> select stays on "expr" and the input appears even while empty
    page.select_option('[data-test=rulemode-listRule]', 'expr')
    assert page.input_value('[data-test=rulemode-listRule]') == 'expr'
    page.wait_for_selector('[data-test=rule-listRule]', timeout=8000)
    page.fill('[data-test=rule-listRule]', 'status = "published"')
    page.click('[data-test=save-collection]')
    page.wait_for_selector('[data-test=records-view]', timeout=8000)
    # reload editor: the expression persisted and reads back as Expression mode
    page.goto("/_/?t=2#/collections/memos")
    page.wait_for_selector('[data-test=schema-editor]', timeout=8000)
    page.click('[data-test=tab-rules]')
    assert page.input_value('[data-test=rulemode-listRule]') == 'expr'
    assert page.input_value('[data-test=rule-listRule]') == 'status = "published"'


def test_rule_public_cancel_reverts_select(page):
    # Regression: choosing "PUBLIC" then CANCELLING the confirm() must snap the controlled
    # <select> back to the prior mode (it used to stay visually stuck on "PUBLIC" with no
    # re-render, even though the rule was never opened up).
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "cancels", "type": "base", "fields": [{"id": "", "name": "body", "type": "text", "options": {}}]})
    page.goto("/_/?t=1#/collections/cancels")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-rules]')
    assert page.input_value('[data-test=rulemode-viewRule]') == 'locked'  # default
    # dismiss (cancel) the "Make ... PUBLIC?" confirm dialog
    page.on("dialog", lambda d: d.dismiss())
    page.select_option('[data-test=rulemode-viewRule]', 'public')
    # the select reverts to 'locked' and no PUBLIC tag is shown; the rule stays unset (locked)
    page.wait_for_function("document.querySelector('[data-test=rulemode-viewRule]').value === 'locked'")
    assert page.locator('[data-test=pubtag-viewRule]').count() == 0
    col = next(c for c in api_request(page, "GET", "/api/collections").json() if c["name"] == "cancels")
    assert col.get("viewRule") in (None, "")  # never became "@public"
