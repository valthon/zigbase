"""Schema controls follow persisted field identity, never an in-progress name."""

import pytest
from playwright.sync_api import expect

from conftest import api_request, login, save_collection_and_wait


def field_row(page, name):
    return next(
        row for row in page.locator('[data-test=field-row]').all()
        if row.locator('[data-test=field-name]').input_value() == name
    )


@pytest.mark.parametrize("collection_type", ["base", "auth"])
@pytest.mark.parametrize("field_name", ["EmailAddress", "token_epoch_notes"])
def test_new_field_name_stays_editable_through_reserved_prefix(page, collection_type, field_name):
    login(page)
    page.goto("/_/#/collections/__new__")
    page.wait_for_selector('[data-test=schema-editor]')
    page.fill('[data-test=col-name]', 'field_names')
    page.select_option('[data-test=col-type]', collection_type)
    page.click('[data-test=add-field]')
    row = page.locator('[data-test=field-row]').last
    name = row.locator('[data-test=field-name]')
    # fill() skips the intermediate reserved names and would miss this bug.
    name.press_sequentially(field_name, delay=15)
    expect(name).to_have_value(field_name)
    expect(name).to_be_enabled()
    expect(row.locator('[data-test=field-type]')).to_be_enabled()
    expect(row.locator('[data-test=del-field]')).to_be_visible()
    save_collection_and_wait(page)
    collection = next(c for c in api_request(page, "GET", "/api/collections").json()["items"] if c["name"] == "field_names")
    assert any(f["name"] == field_name for f in collection["schema"])


def test_existing_custom_field_stays_editable_and_injected_auth_fields_stay_protected(page):
    login(page)
    response = api_request(page, "POST", "/api/collections", {
        "name": "field_names", "type": "auth", "fields": [
            {"id": "", "name": "token_epoch_notes", "type": "text", "options": {}},
        ],
    })
    assert response.ok, response.text()
    collection = response.json()
    system_names = {"email", "username", "verified"}
    injected = [f for f in collection["schema"] if f["name"] in system_names]
    assert {f["name"] for f in injected} == system_names
    # Verify the actual API identity used by the editor, including injected fields.
    assert all(f["id"] for f in injected), injected
    assert not {"passwordHash", "tokenKey", "token_epoch"} & {f["name"] for f in collection["schema"]}
    page.goto("/_/?field-names=edit#/collections/field_names")
    page.wait_for_selector('[data-test=schema-editor]')
    for field in injected:
        row = field_row(page, field["name"])
        expect(row.locator('[data-test=field-name]')).to_be_disabled()
        expect(row.locator('[data-test=field-type]')).to_be_disabled()
        expect(row.locator('[data-test=del-field]')).to_have_count(0)

    row = field_row(page, "token_epoch_notes")
    name = row.locator('[data-test=field-name]')
    name.fill("")
    name.press_sequentially("token_epoch_details", delay=15)
    expect(name).to_have_value("token_epoch_details")
    expect(row.locator('[data-test=field-type]')).to_be_enabled()
    expect(row.locator('[data-test=del-field]')).to_be_visible()
    save_collection_and_wait(page)
    saved = api_request(page, "GET", "/api/collections/field_names").json()
    assert any(f["name"] == "token_epoch_details" for f in saved["schema"])
    assert {f["name"]: f["id"] for f in saved["schema"] if f["name"] in system_names} == {f["name"]: f["id"] for f in injected}


def test_new_collection_navigation_fetches_metadata_once(page):
    with page.expect_response('**/api/collections') as initial:
        login(page)
    initial.value.finished()
    expect(page.locator('[data-test=new-collection]')).to_be_visible()
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    requests = []
    def metadata(route):
        requests.append(route.request)
        route.continue_()
    page.route('**/api/collections', metadata)
    page.click('[data-test=new-collection]')
    expect(page.locator('[data-test=schema-editor]')).to_be_visible()
    expect(page.locator('[data-test=col-name]')).to_have_value('')
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    assert len(requests) == 1
