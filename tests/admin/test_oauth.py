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

    # --- Contract endpoint: GET /api/collections/:col/auth/oauth2/providers ---
    # After the provider is configured, the public-facing discovery endpoint should
    # list it (without exposing the client secret).
    r = api_request(page, "GET", "/api/collections/members/auth/oauth2/providers")
    assert r.status == 200
    body = r.json()
    assert "providers" in body
    assert len(body["providers"]) == 1
    prov = body["providers"][0]
    assert prov["clientId"] == "my-client-id"
    assert "clientSecret" not in prov
    assert "authURL" in prov
    assert "scopes" in prov

    # --- Contract endpoint: POST /api/collections/:col/auth/oauth2/initiate ---
    # Posting a valid provider name should return the redirect-building info
    # (authURL, clientId, scopes). No state is expected when server-side state
    # is disabled (the default).
    r2 = api_request(page, "POST", "/api/collections/members/auth/oauth2/initiate",
                     {"provider": "google"})
    assert r2.status == 200
    init_body = r2.json()
    assert "authURL" in init_body
    assert "clientId" in init_body
    assert init_body["clientId"] == "my-client-id"
    assert "scopes" in init_body
    assert isinstance(init_body["scopes"], list)
