"""
Admin UI tests for the Feature Flags & Experiments screen (PR4 / 0.8.0).

The standalone zigbase binary declares two flags (dark_mode, maintenance) and one
experiment (onboarding_flow) in src/main.zig, so the GET /api/features response is
non-empty and the UI can be exercised end-to-end.

Covers:
- Navigation to the Features view
- Declared flags table: toggle sets/clears override; "Use default" clears it
- Declared experiments panel: editing weights writes the override; reset clears it
- data-test hooks present as specified in the PR4 plan
"""
from conftest import login, api_request


# ── Navigation ──────────────────────────────────────────────────────────────

def test_nav_features_shows_view(page):
    """Clicking 'Features' in the sidebar navigates to the features view."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=features-view]', timeout=5000)


def test_features_view_sections_present(page):
    """The features view contains both the flags section and experiments section."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flags-section]', timeout=5000)
    page.wait_for_selector('[data-test=exps-section]', timeout=5000)


# ── Declared flags ───────────────────────────────────────────────────────────

def test_declared_flags_table_shows_flags(page):
    """The declared flags table lists the binary's declared flags."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flags-rows]', timeout=5000)
    rows_text = page.inner_text('[data-test=flags-rows]')
    assert 'dark_mode' in rows_text
    assert 'maintenance' in rows_text


def test_flag_default_shown_in_table(page):
    """Each flag row shows its declared default value."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flag-row-maintenance]', timeout=5000)
    row_text = page.inner_text('[data-test=flag-row-maintenance]')
    assert 'off' in row_text  # default = false
    assert 'Enable maintenance mode' in row_text


def test_toggle_flag_on_sets_override(page):
    """Toggling a flag (default off) on sets the flag:<name> override to 'true'."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flag-override-dark_mode]', timeout=5000)

    # dark_mode default is false; no override set → checkbox unchecked.
    assert not page.is_checked('[data-test=flag-override-dark_mode]')

    # Toggle on and wait for the PUT round-trip.
    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'PUT') as resp_info:
        page.click('[data-test=flag-override-dark_mode]')
    assert resp_info.value.ok

    # Verify the _kv override is now 'true'.
    r = api_request(page, 'GET', '/api/settings/flag:dark_mode')
    assert r.status == 200
    assert r.json()['value'] == 'true'


def test_toggle_flag_off_sets_override(page):
    """With an existing 'true' override, toggling off sets override to 'false'."""
    login(page)
    # Seed an override.
    api_request(page, 'PUT', '/api/settings/flag:dark_mode', {'value': 'true'})

    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flag-override-dark_mode]', timeout=5000)
    # Reload picks up the seeded override → checkbox should be checked.
    assert page.is_checked('[data-test=flag-override-dark_mode]')

    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'PUT') as resp_info:
        page.click('[data-test=flag-override-dark_mode]')
    assert resp_info.value.ok

    r = api_request(page, 'GET', '/api/settings/flag:dark_mode')
    assert r.json()['value'] == 'false'


def test_flag_clear_removes_override(page):
    """'Use default' button deletes the override and the badge disappears."""
    login(page)
    api_request(page, 'PUT', '/api/settings/flag:dark_mode', {'value': 'true'})

    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=flag-clear-dark_mode]', timeout=5000)

    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'DELETE') as resp_info:
        page.click('[data-test=flag-clear-dark_mode]')
    assert resp_info.value.ok

    # Override cleared → 404 from API.
    r = api_request(page, 'GET', '/api/settings/flag:dark_mode')
    assert r.status == 404

    # The "Use default" button should be gone (no active override).
    page.wait_for_selector('[data-test=flag-clear-dark_mode]', state='detached', timeout=5000)


# ── Declared experiments ─────────────────────────────────────────────────────

def test_experiment_panel_shows_declared_experiment(page):
    """The experiments section shows a panel for the declared onboarding_flow experiment."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=exp-panel-onboarding_flow]', timeout=5000)
    panel_text = page.inner_text('[data-test=exp-panel-onboarding_flow]')
    assert 'onboarding_flow' in panel_text
    assert 'control' in panel_text
    assert 'streamlined' in panel_text
    assert 'Onboarding flow A/B test' in panel_text


def test_experiment_weight_inputs_show_declared_weights(page):
    """Weight inputs are initialised to the declared weights when no override is active."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=weight-onboarding_flow-control]', timeout=5000)
    assert page.input_value('[data-test=weight-onboarding_flow-control]') == '70'
    assert page.input_value('[data-test=weight-onboarding_flow-streamlined]') == '30'


def test_save_experiment_weights_writes_override(page):
    """Editing the weight inputs and clicking 'Save weights' writes exp:<name>:weights."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=weight-onboarding_flow-control]', timeout=5000)

    page.fill('[data-test=weight-onboarding_flow-control]', '90')
    page.fill('[data-test=weight-onboarding_flow-streamlined]', '10')

    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'PUT') as resp_info:
        page.click('[data-test=exp-save-onboarding_flow]')
    assert resp_info.value.ok

    r = api_request(page, 'GET', '/api/settings/exp:onboarding_flow:weights')
    assert r.status == 200
    assert r.json()['value'] == '[90,10]'


def test_experiment_weight_input_clamps_to_u16_range(page):
    """Weights are u16 server-side (max 65535); the onInput handler clamps out-of-range
    values so an over-large or negative entry can never be saved."""
    login(page)
    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=weight-onboarding_flow-control]', timeout=5000)

    # Type an over-large value: it should clamp to 65535 in the input state.
    page.fill('[data-test=weight-onboarding_flow-control]', '70000')
    assert page.input_value('[data-test=weight-onboarding_flow-control]') == '65535'

    # Save and verify the persisted override carries the clamped value, not 70000.
    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'PUT') as resp_info:
        page.click('[data-test=exp-save-onboarding_flow]')
    assert resp_info.value.ok
    r = api_request(page, 'GET', '/api/settings/exp:onboarding_flow:weights')
    assert r.status == 200
    assert r.json()['value'] == '[65535,30]'


def test_experiment_reset_clears_weight_override(page):
    """'Reset to declared' button deletes the weight override from _kv."""
    login(page)
    api_request(page, 'PUT', '/api/settings/exp:onboarding_flow:weights', {'value': '[90,10]'})

    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=exp-reset-onboarding_flow]', timeout=5000)
    # Override badge should be visible.
    page.wait_for_selector('[data-test=exp-override-badge-onboarding_flow]', timeout=5000)

    with page.expect_response(lambda r: '/api/settings/' in r.url and r.request.method == 'DELETE') as resp_info:
        page.click('[data-test=exp-reset-onboarding_flow]')
    assert resp_info.value.ok

    r = api_request(page, 'GET', '/api/settings/exp:onboarding_flow:weights')
    assert r.status == 404

    # Reset button and override badge should be gone.
    page.wait_for_selector('[data-test=exp-reset-onboarding_flow]', state='detached', timeout=5000)


def test_weight_inputs_update_after_reset(page):
    """After resetting, the weight inputs revert to the declared values (70/30)."""
    login(page)
    api_request(page, 'PUT', '/api/settings/exp:onboarding_flow:weights', {'value': '[90,10]'})

    page.click('[data-test=nav-features]')
    page.wait_for_selector('[data-test=exp-reset-onboarding_flow]', timeout=5000)
    page.click('[data-test=exp-reset-onboarding_flow]')

    # After reset + reload, inputs should show declared weights.
    page.wait_for_selector('[data-test=exp-reset-onboarding_flow]', state='detached', timeout=5000)
    assert page.input_value('[data-test=weight-onboarding_flow-control]') == '70'
    assert page.input_value('[data-test=weight-onboarding_flow-streamlined]') == '30'
