from conftest import login

def test_bad_login_shows_error(page):
    page.goto("/_/#/login")
    page.fill('[data-test=email]', 'admin@x.io')
    page.fill('[data-test=password]', 'wrongpass')
    page.click('[data-test=login-submit]')
    page.wait_for_selector('[data-test=login-error]', timeout=5000)

def test_login_then_sidebar_lists_builtin_collections(page):
    login(page)
    # login() only waits for the static nav-collections link; the built-in
    # collection nav items (_superusers, ...) render asynchronously just after,
    # so wait for the target before counting — a bare count() races and reads 0.
    page.wait_for_selector('[data-test=nav-_superusers]', timeout=5000)
    assert page.locator('[data-test=nav-_superusers]').count() == 1

def test_sidebar_shows_backend_badge(page):
    # Read-only backend badge sourced from GET /api/health {"backend": "..."}.
    # The browser suite runs on the default SQLite build, so it reads "SQLite".
    login(page)
    badge = page.locator('[data-test=backend-badge]')
    badge.wait_for(timeout=5000)
    assert badge.inner_text().strip() == "SQLite"

def test_unauthenticated_deeplink_bounces_to_login(page):
    page.goto("/_/#/collections/_superusers/records")
    page.wait_for_selector('[data-test=email]', timeout=5000)

def test_browse_records_table_renders(page):
    login(page)
    page.click('[data-test=nav-_superusers]')
    page.wait_for_selector('[data-test=records-view]', timeout=5000)
    page.wait_for_selector('[data-test=row]', timeout=5000)
    assert page.locator('[data-test=row]').count() >= 1
