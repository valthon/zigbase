"""
End-to-end browser tests for text.pattern and date min/max enforcement.

Collections are seeded via the API (the schema editor has no UI hooks for
`pattern` / date `min` / `max`), then the record-creation flow is exercised
through the admin SPA.  Field errors render as [data-test=err-<fieldname>].
"""

from conftest import login, api_request


# ---------------------------------------------------------------------------
# text field with pattern
# ---------------------------------------------------------------------------

def test_text_pattern_rejects_invalid_value(page):
    """A text field with pattern='^[a-z0-9-]+$' must reject 'Bad Value'."""
    login(page)
    # Seed the collection via API so we don't need UI hooks for `pattern`.
    api_request(page, "POST", "/api/collections", {
        "name": "slugs",
        "type": "base",
        "fields": [
            {"id": "", "name": "slug", "type": "text",
             "options": {"pattern": "^[a-z0-9-]+$"}},
        ],
        "listRule": "",
        "viewRule": "",
        "createRule": "",
        "updateRule": "",
        "deleteRule": "",
    })
    # Navigate to the records view for this collection.
    page.goto("/_/?t=1#/collections/slugs/records")
    page.wait_for_selector('[data-test=records-view]', timeout=8000)

    # Open the new-record drawer and enter an invalid slug (uppercase + space).
    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-slug]', 'Bad Value')
    page.click('[data-test=record-save]')

    # The server rejects the write; the field error must be displayed.
    page.wait_for_selector('[data-test=err-slug]', timeout=6000)
    err_text = page.inner_text('[data-test=err-slug]')
    assert err_text, "expected a non-empty error message under the slug field"

    # Confirm the record was NOT created.
    records = api_request(page, "GET", "/api/collections/slugs/records").json()
    assert records["totalItems"] == 0


def test_text_pattern_accepts_valid_value(page):
    """A text field with pattern='^[a-z0-9-]+$' must accept 'ok-slug-1'."""
    login(page)
    api_request(page, "POST", "/api/collections", {
        "name": "slugs2",
        "type": "base",
        "fields": [
            {"id": "", "name": "slug", "type": "text",
             "options": {"pattern": "^[a-z0-9-]+$"}},
        ],
        "listRule": "",
        "viewRule": "",
        "createRule": "",
        "updateRule": "",
        "deleteRule": "",
    })
    page.goto("/_/?t=1#/collections/slugs2/records")
    page.wait_for_selector('[data-test=records-view]', timeout=8000)

    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-slug]', 'ok-slug-1')
    page.click('[data-test=record-save]')

    # Drawer closes after a successful save; the record row appears.
    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert 'ok-slug-1' in page.locator('[data-test=rows]').inner_text()


# ---------------------------------------------------------------------------
# date field with min / max bounds
# ---------------------------------------------------------------------------

def test_date_max_rejects_out_of_range(page):
    """A date field with max='2026-12-31' must reject '2027-06-01'."""
    login(page)
    api_request(page, "POST", "/api/collections", {
        "name": "events",
        "type": "base",
        "fields": [
            {"id": "", "name": "scheduled", "type": "date",
             "options": {"min": "2026-01-01", "max": "2026-12-31"}},
        ],
        "listRule": "",
        "viewRule": "",
        "createRule": "",
        "updateRule": "",
        "deleteRule": "",
    })
    page.goto("/_/?t=1#/collections/events/records")
    page.wait_for_selector('[data-test=records-view]', timeout=8000)

    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-scheduled]', '2027-06-01')
    page.click('[data-test=record-save]')

    # The server must reject the date as after the max bound.
    page.wait_for_selector('[data-test=err-scheduled]', timeout=6000)
    err_text = page.inner_text('[data-test=err-scheduled]')
    assert err_text, "expected a non-empty error message under the scheduled field"

    records = api_request(page, "GET", "/api/collections/events/records").json()
    assert records["totalItems"] == 0


def test_date_min_rejects_out_of_range(page):
    """A date field with min='2026-01-01' must reject '2025-01-01'."""
    login(page)
    api_request(page, "POST", "/api/collections", {
        "name": "events2",
        "type": "base",
        "fields": [
            {"id": "", "name": "scheduled", "type": "date",
             "options": {"min": "2026-01-01", "max": "2026-12-31"}},
        ],
        "listRule": "",
        "viewRule": "",
        "createRule": "",
        "updateRule": "",
        "deleteRule": "",
    })
    page.goto("/_/?t=1#/collections/events2/records")
    page.wait_for_selector('[data-test=records-view]', timeout=8000)

    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-scheduled]', '2025-01-01')
    page.click('[data-test=record-save]')

    page.wait_for_selector('[data-test=err-scheduled]', timeout=6000)
    err_text = page.inner_text('[data-test=err-scheduled]')
    assert err_text, "expected a non-empty error message under the scheduled field"

    records = api_request(page, "GET", "/api/collections/events2/records").json()
    assert records["totalItems"] == 0


def test_date_accepts_in_range_value(page):
    """A date field with min/max bounds must accept a value in range."""
    login(page)
    api_request(page, "POST", "/api/collections", {
        "name": "events3",
        "type": "base",
        "fields": [
            {"id": "", "name": "scheduled", "type": "date",
             "options": {"min": "2026-01-01", "max": "2026-12-31"}},
        ],
        "listRule": "",
        "viewRule": "",
        "createRule": "",
        "updateRule": "",
        "deleteRule": "",
    })
    page.goto("/_/?t=1#/collections/events3/records")
    page.wait_for_selector('[data-test=records-view]', timeout=8000)

    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-scheduled]', '2026-06-15')
    page.click('[data-test=record-save]')

    page.wait_for_selector('[data-test=row]', timeout=6000)
    assert '2026-06-15' in page.locator('[data-test=rows]').inner_text()
