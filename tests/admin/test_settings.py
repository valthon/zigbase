"""
Admin UI tests for the Settings / Feature Flags section (issue #101).

Covers: navigation, KV create/edit/list, boolean flag toggle, delete.
"""
from conftest import login, api_request


def test_nav_settings_shows_view(page):
    """Clicking 'Settings' in the sidebar navigates to the settings view."""
    login(page)
    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)


def test_empty_state_shown_initially(page):
    """With no settings seeded, the empty-state paragraph is visible."""
    login(page)
    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-empty]', timeout=5000)


def test_create_kv_setting_via_ui(page):
    """Create a plain KV entry through the New Setting drawer."""
    login(page)
    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)

    page.click('[data-test=new-setting]')
    page.wait_for_selector('[data-test=setting-drawer]', timeout=3000)

    page.fill('[data-test=setting-key-input]', 'app_theme')
    page.fill('[data-test=setting-value-input]', 'dark')
    page.click('[data-test=setting-save]')

    # Drawer closes on success
    page.wait_for_selector('[data-test=setting-drawer]', state='detached', timeout=5000)

    # The new entry appears in the table
    page.wait_for_selector('[data-test=settings-rows]', timeout=3000)
    rows_text = page.inner_text('[data-test=settings-rows]')
    assert 'app_theme' in rows_text
    assert 'dark' in rows_text

    # Verify persisted via API
    r = api_request(page, 'GET', '/api/settings/app_theme')
    assert r.status == 200
    assert r.json()['value'] == 'dark'


def test_toggle_feature_flag_off_to_on(page):
    """A flag seeded as 'false' renders as an unchecked checkbox; toggling it
    calls PUT and persists 'true'."""
    login(page)
    # Seed via API
    r = api_request(page, 'PUT', '/api/settings/beta_feature', {'value': 'false'})
    assert r.status == 200

    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)
    # Wait for the flag row's checkbox
    page.wait_for_selector('[data-test=flag-beta_feature]', timeout=5000)
    assert not page.is_checked('[data-test=flag-beta_feature]')

    # Toggle on
    page.click('[data-test=flag-beta_feature]')

    # Wait for the checkbox to reflect the new state (Preact re-renders after API)
    page.wait_for_function("document.querySelector('[data-test=\"flag-beta_feature\"]').checked === true", timeout=5000)

    # Verify persisted
    r = api_request(page, 'GET', '/api/settings/beta_feature')
    assert r.json()['value'] == 'true'


def test_toggle_feature_flag_on_to_off(page):
    """A flag seeded as 'true' renders as a checked checkbox; toggling unchecks it."""
    login(page)
    api_request(page, 'PUT', '/api/settings/feature_x', {'value': 'true'})

    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)
    page.wait_for_selector('[data-test=flag-feature_x]', timeout=5000)
    assert page.is_checked('[data-test=flag-feature_x]')

    page.click('[data-test=flag-feature_x]')
    page.wait_for_function("document.querySelector('[data-test=\"flag-feature_x\"]').checked === false", timeout=5000)

    r = api_request(page, 'GET', '/api/settings/feature_x')
    assert r.json()['value'] == 'false'


def test_edit_setting_value_via_drawer(page):
    """Editing an existing entry via the 'Edit' button updates its value."""
    login(page)
    api_request(page, 'PUT', '/api/settings/welcome_msg', {'value': 'Hello'})

    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)

    # Find the row and click Edit
    row = page.locator('[data-test=setting-row]').filter(has_text='welcome_msg')
    row.wait_for(timeout=5000)
    row.locator('[data-test=edit-setting]').click()

    page.wait_for_selector('[data-test=setting-drawer]', timeout=3000)

    # Key input is disabled; only value is editable
    assert page.input_value('[data-test=setting-key-input]') == 'welcome_msg'
    assert page.is_disabled('[data-test=setting-key-input]')

    page.fill('[data-test=setting-value-input]', 'World')
    page.click('[data-test=setting-save]')
    page.wait_for_selector('[data-test=setting-drawer]', state='detached', timeout=5000)

    # Verify
    r = api_request(page, 'GET', '/api/settings/welcome_msg')
    assert r.json()['value'] == 'World'


def test_delete_setting(page):
    """Delete button removes the entry after confirmation."""
    login(page)
    api_request(page, 'PUT', '/api/settings/to_remove', {'value': 'yes'})

    page.click('[data-test=nav-settings]')
    page.wait_for_selector('[data-test=settings-view]', timeout=5000)

    row = page.locator('[data-test=setting-row]').filter(has_text='to_remove')
    row.wait_for(timeout=5000)

    # Accept the confirm() dialog
    page.on('dialog', lambda d: d.accept())
    row.locator('[data-test=del-setting]').click()

    # Row disappears from DOM
    row.wait_for(state='detached', timeout=5000)

    # Verify gone from API
    r = api_request(page, 'GET', '/api/settings/to_remove')
    assert r.status == 404
