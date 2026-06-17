from conftest import login, api_request, save_collection_and_wait

def test_configure_oauth_provider_and_secret_redacted(page):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "members", "type": "auth", "fields": []})
    page.reload()
    page.goto("/_/?t=1#/collections/members")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-auth]')
    page.click('[data-test=add-provider]')
    page.fill('[data-test=oauth-clientid]', 'my-client-id')
    page.fill('[data-test=oauth-secret]', 'my-secret')
    page.fill('[data-test=oauth-redirects]', 'https://app/cb')
    # Save, then wait for the app's full-document post-save reload to COMPLETE
    # before navigating — otherwise our goto below races the in-flight reload
    # and Playwright aborts it (net::ERR_ABORTED). See save_collection_and_wait.
    save_collection_and_wait(page)
    page.wait_for_selector('[data-test=nav-members]', timeout=8000)
    # reload the editor: clientId persists, secret comes back redacted (empty input value)
    page.goto("/_/?t=2#/collections/members")
    page.wait_for_selector('[data-test=schema-editor]')
    page.click('[data-test=tab-auth]')
    page.wait_for_selector('[data-test=oauth-provider]')
    assert page.input_value('[data-test=oauth-clientid]') == 'my-client-id'
    assert page.input_value('[data-test=oauth-secret]') == ''  # redacted, never returned
