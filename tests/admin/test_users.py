from conftest import login


def _seed_user(page, col="users", email="alice@example.com"):
    from conftest import api_request
    # create the auth collection if the fixture doesn't have it, then a user
    api_request(page, "POST", "/api/collections", {"name": col, "type": "auth"})
    api_request(page, "POST", f"/api/collections/{col}/records",
                {"email": email, "password": "correct horse battery staple"})


def test_users_view_lists_and_searches(page):
    login(page)
    _seed_user(page, email="alice@example.com")
    _seed_user(page, email="bob@example.com")
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    # collection picker defaults to the first auth collection with records
    page.select_option('[data-test=users-collection]', "users")
    page.wait_for_selector('[data-test=user-row]')
    assert page.locator('[data-test=user-row]').count() >= 2
    page.fill('[data-test=users-search]', "alice")
    page.click('[data-test=users-search-go]')
    page.wait_for_function("document.querySelectorAll('[data-test=user-row]').length === 1")
    assert "alice@example.com" in page.inner_text('[data-test=user-row]')


def test_users_create_edit_delete_and_password(page):
    login(page)
    from conftest import api_request
    api_request(page, "POST", "/api/collections", {"name": "users", "type": "auth"})
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    page.select_option('[data-test=users-collection]', "users")
    # create (with a username, so the drawer/list identity paths are exercised)
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', "carol@example.com")
    page.fill('[data-test=user-username]', "carol")
    page.fill('[data-test=user-password]', "correct horse battery staple")
    page.click('[data-test=user-save]')
    # success signal: the drawer closes and the new row appears in the list
    page.wait_for_selector('[data-test=user-drawer]', state='detached')
    page.wait_for_function("[...document.querySelectorAll('[data-test=user-row]')].some(r => r.textContent.includes('carol@example.com'))")
    # re-open to confirm the username round-tripped, then admin password reset
    # (superuser PATCH; no old password)
    page.click('[data-test=user-row]:has-text("carol@example.com")')
    page.wait_for_selector('[data-test=user-drawer]')
    assert page.input_value('[data-test=user-username]') == "carol"
    page.fill('[data-test=user-password]', "another good passphrase here")
    page.click('[data-test=user-save]')
    # drawer closes after the save instead of showing an in-drawer confirmation
    page.wait_for_selector('[data-test=user-drawer]', state='detached')
    page.wait_for_function("[...document.querySelectorAll('[data-test=user-row]')].some(r => r.textContent.includes('carol@example.com'))")
    # delete
    page.click('[data-test=user-row]:has-text("carol@example.com")')
    page.wait_for_selector('[data-test=user-drawer]')
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=user-delete]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=user-row]')].some(r => r.textContent.includes('carol@example.com'))")


def test_users_drawer_remounts_on_selection_change(page):
    # Regression: switching the edit target while the drawer is already open must
    # discard whatever was typed for the previous user, so a save can never leak
    # data (e.g. a password) from one user onto another. See UserDrawer's `key`.
    login(page)
    _seed_user(page, email="alice@example.com")
    _seed_user(page, email="bob@example.com")
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    page.select_option('[data-test=users-collection]', "users")
    page.wait_for_selector('[data-test=user-row]')
    # open alice's drawer and type a password, but don't close it
    page.click('[data-test=user-row]:has-text("alice@example.com")')
    page.wait_for_selector('[data-test=user-drawer]')
    page.fill('[data-test=user-password]', "alices leaked password")
    # switch straight to bob without closing
    page.click('[data-test=user-row]:has-text("bob@example.com")')
    page.wait_for_selector('[data-test=user-drawer]')
    assert page.input_value('[data-test=user-password]') == ''
    assert page.input_value('[data-test=user-email]') == 'bob@example.com'


def test_users_oauth_providers_panel(page):
    login(page)
    from conftest import api_request
    api_request(page, "POST", "/api/collections", {"name": "users", "type": "auth"})
    page.goto("/_/#/users")
    page.wait_for_selector('[data-test=users-view]')
    page.select_option('[data-test=users-collection]', "users")
    # panel renders (0 providers configured by default -> empty-state); wait on
    # the empty-state node itself, not the outer container, which is present
    # (in a loading state) before the async oauthProviders() fetch resolves.
    page.wait_for_selector('[data-test=oauth-empty]')
