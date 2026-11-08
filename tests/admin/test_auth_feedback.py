"""Account drawer writes preserve unrelated state and Shell metadata has one owner."""
import json
import re
import pytest
from playwright.sync_api import expect
from conftest import login, api_request, csrf
from test_auth_navigation import collection, scoped


@pytest.mark.parametrize('transport', ['json', 'upload', 'remove'])
def test_account_patch_only_sends_dirty_fields_and_preserves_concurrent_values(page, transport):
    login(page)
    collection(page, 'members', fields=[
        {'name': 'plan', 'type': 'text'},
        {'name': 'preferences', 'type': 'json'},
        {'name': 'rating', 'type': 'number'},
        {'name': 'tags', 'type': 'select', 'options': {'values': ['a', 'b'], 'maxSelect': 2}},
        {'name': 'avatar', 'type': 'file'},
    ])
    created = api_request(page, 'POST', '/api/collections/members/records', {
        'email': 'before@example.com', 'password': 'safe password here',
        'plan': 'old', 'preferences': {'theme': 'dark'}, 'rating': 1.5, 'tags': ['a', 'b']})
    assert created.ok, created.text()
    endpoint = '/api/collections/members/records/' + created.json()['id']
    if transport == 'remove':
        response = page.request.patch(endpoint, headers={'X-CSRF-Token': csrf(page)}, multipart={
            'avatar': {'name': 'old.txt', 'mimeType': 'text/plain', 'buffer': b'old'}})
        assert response.ok, response.text()
    page.goto('/_/#/users/members')
    page.click('[data-test=user-row]')
    page.fill('[data-test=in-plan]', 'temporary')
    page.fill('[data-test=in-plan]', 'old')
    page.fill('[data-test=in-rating]', '2')
    page.fill('[data-test=in-rating]', '1.5')
    response = api_request(page, 'PATCH', endpoint, {'plan': 'concurrent', 'preferences': {'theme': 'light'}, 'rating': 3, 'tags': ['b']})
    assert response.ok, response.text()
    page.fill('[data-test=user-email]', 'after@example.com')
    if transport == 'upload':
        page.set_input_files('[data-test=in-avatar]', {'name': 'new.txt', 'mimeType': 'text/plain', 'buffer': b'new'})
    elif transport == 'remove':
        page.check('[data-test=rm-avatar]')
    with page.expect_response(lambda r: r.url.endswith(endpoint) and r.request.method == 'PATCH') as write:
        page.click('[data-test=user-save]')
    assert write.value.ok, write.value.text()
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    if transport == 'json':
        assert write.value.request.post_data_json == {'email': 'after@example.com'}
    else:
        assert 'multipart/form-data' in write.value.request.headers['content-type']
    saved = api_request(page, 'GET', endpoint).json()
    assert saved['plan'] == 'concurrent'
    assert saved['rating'] == 3
    tags = saved['tags']
    assert (json.loads(tags) if isinstance(tags, str) else tags) == ['b']
    preferences = saved['preferences']
    assert (json.loads(preferences) if isinstance(preferences, str) else preferences) == {'theme': 'light'}
    assert saved['email'] == 'after@example.com'
    if transport == 'upload':
        assert saved['avatar']
    elif transport == 'remove':
        assert not saved['avatar']


def test_credential_reset_omits_missing_legacy_required_profile(page):
    login(page)
    metadata = collection(page, 'members', fields=[{'name': 'plan', 'type': 'text'}])
    created = api_request(page, 'POST', '/api/collections/members/records', {
        'email': 'legacy@example.com', 'password': 'safe password here'})
    assert created.ok, created.text()
    # Adding a required field leaves older rows empty. Tighten an existing nullable
    # field so the real collection definition, rather than a mocked form, exercises it.
    fields = [f for f in metadata['schema'] if f['name'] == 'plan']
    fields[0]['required'] = True
    changed = api_request(page, 'PATCH', '/api/collections/members', {'name': 'members', 'type': 'auth', 'fields': fields})
    assert changed.ok, changed.text()
    endpoint = '/api/collections/members/records/' + created.json()['id']
    page.goto('/_/#/users/members')
    page.click('[data-test=user-row]')
    page.fill('[data-test=user-password]', 'new safe password here')
    with page.expect_response(lambda r: r.url.endswith(endpoint) and r.request.method == 'PATCH') as write:
        page.click('[data-test=user-save]')
    assert write.value.ok, write.value.text()
    assert write.value.request.post_data_json == {'password': 'new safe password here'}
    assert api_request(page, 'GET', endpoint).json()['plan'] is None
    response = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': 'legacy@example.com', 'password': 'new safe password here'})
    assert response.ok, response.text()


def test_shell_collection_failure_mounts_records_and_shows_user_error(page):
    login(page)
    collection(page, 'notes', 'base')
    failures = []
    def fail(route):
        failures.append(route.request.url)
        route.fulfill(status=503, json={'message': 'Collection list unavailable'})
    page.route('**/api/collections', fail)
    page.goto('/_/#/collections/notes/records')
    page.reload()
    expect(page.locator('[data-test=records-view]')).to_be_visible()
    expect(page.locator('[data-test=empty]')).to_be_visible()
    expect(page.locator('[data-test=records-error]')).to_contain_text('Collection list unavailable')
    page.evaluate("location.hash = '#/users'")
    expect(page.locator('[data-test=users-error]')).to_contain_text('Collection list unavailable')
    expect(page.locator('[data-test=user-new]')).to_be_disabled()


def test_failed_lookup_error_clears_when_navigating_to_a_cached_collection(page):
    login(page)
    collection(page, 'members')
    page.goto('/_/?lookup-error=1#/users/members')
    scoped(page, 'members')
    requests = []
    def metadata(route):
        requests.append(route.request)
        route.fulfill(status=503, json={'message': 'Temporary collection failure'})
    page.route('**/api/collections', metadata)
    page.evaluate("location.hash = '#/users/missing'")
    expect(page.locator('[data-test=users-error]')).to_have_text('Temporary collection failure')
    expect(page.locator('.sidebar .error')).to_have_text('Temporary collection failure')
    page.evaluate("location.hash = '#/users/members'")
    scoped(page, 'members')
    expect(page.locator('[data-test=users-error]')).to_have_count(0)
    expect(page.locator('.sidebar .error')).to_have_count(0)
    assert len(requests) == 1


def test_late_lookup_failure_stays_off_the_route_the_admin_moved_to(page):
    login(page)
    collection(page, 'members')
    page.goto('/_/?late-lookup=1#/users/members')
    scoped(page, 'members')
    pending = []
    page.route('**/api/collections', lambda route: pending.append(route))
    with page.expect_request('**/api/collections'):
        page.evaluate("location.hash = '#/users/missing'")
    page.evaluate("location.hash = '#/users/members'")
    expect(page).to_have_url(re.compile(r"#/users/members$"))
    # Route-change effects flush after paint; a failure landing sooner is cleared by them.
    page.wait_for_timeout(300)
    with page.expect_response('**/api/collections') as late:
        pending[0].fulfill(status=503, json={'message': 'Late lookup failure'})
    late.value.finished()
    scoped(page, 'members')
    # A count of zero passes at once, so give the late failure time to render first.
    page.wait_for_timeout(500)
    expect(page.locator('[data-test=users-error]')).to_have_count(0)
    expect(page.locator('.sidebar .error')).to_have_count(0)
    assert len(pending) == 1


def test_collection_switches_reuse_shell_metadata(page):
    login(page)
    collection(page, 'members')
    collection(page, 'staff')
    collection(page, 'notes', 'base')
    lists = []
    page.on('request', lambda request: lists.append(request.url) if re.search(r'/api/collections$', request.url) else None)
    page.goto('/_/?metadata-test=1#/users/members')  # Fresh Shell: exactly one initial fetch.
    scoped(page, 'members')
    page.select_option('[data-test=users-collection]', 'staff')
    scoped(page, 'staff')
    assert len(lists) == 1
    page.click('[data-test=nav-notes]')
    expect(page.locator('[data-test=records-view]')).to_be_visible()
    expect(page.locator('[data-test=empty]')).to_be_visible()
    with page.expect_request(lambda request: re.search(r'/api/collections$', request.url)):
        page.click('[data-test=nav-members]')
    scoped(page, 'members')
    assert len(lists) == 2  # Re-entering Users refreshes once; collection switches do not.


@pytest.mark.parametrize('kind', ['base', 'auth'])
def test_rich_text_blur_persists_stored_cleanup_and_preserves_untouched_null(page, kind):
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'biography', 'type': 'editor'}, {'name': 'note', 'type': 'text'}])
    endpoint = '/api/collections/profiles/records'
    body = {'biography': '<p onclick="alert(1)">Safe</p><script>alert(1)</script>', 'note': 'before'}
    if kind == 'auth':
        body.update(email='editor@example.com', password='safe password here')
    created = api_request(page, 'POST', endpoint, body)
    assert created.ok, created.text()
    endpoint += '/' + created.json()['id']
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    row = '[data-test=user-row]' if kind == 'auth' else '[data-test=row]'
    save = '[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]'
    drawer = '[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]'
    page.click(row)
    editor = page.get_by_role('textbox', name='biography', exact=True)
    expect(editor).to_have_text('Safe')
    editor.focus()
    page.get_by_label('note', exact=True).fill('after')
    page.click(save)
    expect(page.locator(drawer)).to_have_count(0)
    assert api_request(page, 'GET', endpoint).json()['biography'] == '<p>Safe</p>'
    assert api_request(page, 'PATCH', endpoint, {'biography': None}).ok
    page.reload()
    page.click(row)
    editor.focus()
    page.get_by_label('note', exact=True).fill('keep null')
    page.click(save)
    expect(page.locator(drawer)).to_have_count(0)
    assert api_request(page, 'GET', endpoint).json()['biography'] is None
    # A real edit can still clear stored nonempty HTML explicitly.
    assert api_request(page, 'PATCH', endpoint, {'biography': '<p>Again</p>'}).ok
    page.reload()
    page.click(row)
    editor.evaluate("el => { el.innerHTML = ''; el.dispatchEvent(new InputEvent('input', {bubbles:true})); }")
    page.click(save)
    expect(page.locator(drawer)).to_have_count(0)
    assert api_request(page, 'GET', endpoint).json()['biography'] == ''


@pytest.mark.parametrize('multipart', [False, True])
def test_blank_username_create_is_null_and_existing_username_can_clear(page, multipart):
    login(page)
    collection(page, 'members', fields=[{'name': 'avatar', 'type': 'file'}])
    page.goto('/_/#/users/members')
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'blank@example.com')
    page.fill('[data-test=user-password]', 'safe password here')
    if multipart:
        page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    record = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert record['username'] is None
    page.click('[data-test=user-row]')
    page.fill('[data-test=user-username]', 'named')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    page.fill('[data-test=user-username]', '')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    assert api_request(page, 'GET', '/api/collections/members/records/' + record['id']).json()['username'] == ''


def test_protected_fields_match_injected_auth_schema(page):
    login(page)
    metadata = collection(page, 'members')
    from pathlib import Path
    source = (Path(__file__).resolve().parents[2] / 'src/schema.zig').read_text()
    auth_fields = source.split('pub fn authSystemFields()', 1)[1].split('return &S.fields;', 1)[0]
    expected = re.findall(r'\.name = "([^"]+)"', auth_fields)
    result = page.evaluate("""async names => {
        const { AUTH_SYSTEM_FIELDS, isSystemField } = await import('/_/assets/views/collections.js');
        return { fields: AUTH_SYSTEM_FIELDS, protected: names.every(name => isSystemField(name, true)),
          special: ['id','created','updated','password','passwordConfirm','oldPassword','externalAuths','TOKEN_EPOCH'].every(name => isSystemField(name, true)) };
    }""", expected)
    assert sorted(result['fields']) == sorted(expected)
    assert result['protected'] and result['special']


def test_auth_settings_zero_minimum_saves_and_reloads(page):
    login(page)
    collection(page, 'members')
    page.goto('/_/#/collections/members')
    page.click('[data-test=tab-auth]')
    page.fill('[data-test=min-pw]', '0')
    expect(page.locator('[data-test=min-pw]')).to_have_value('0')
    page.click('[data-test=save-collection]')
    scoped(page, 'members')
    saved = next(c for c in api_request(page, 'GET', '/api/collections').json()['items'] if c['name'] == 'members')
    assert saved['options']['auth']['minPasswordLength'] == 0
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'zero-settings@example.com')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=users-settings]')
    page.click('[data-test=tab-auth]')
    expect(page.locator('[data-test=min-pw]')).to_have_value('0')
    page.click('[data-test=tab-fields]')
    page.click('[data-test=add-field]')
    page.locator('[data-test=field-name]').last.fill('newProfile')
    page.click('[data-test=save-collection]')
    scoped(page, 'members')
    page.click('[data-test=user-new]')
    expect(page.get_by_label('newProfile', exact=True)).to_be_visible()
    assert page.get_by_label('Password', exact=True).get_attribute('required') is None


def test_request_credential_names_remain_editable_base_profile_fields(page):
    login(page)
    collection(page, 'notes', 'base', fields=[{'name': 'password', 'type': 'text'}, {'name': 'externalAuths', 'type': 'json'}])
    page.goto('/_/#/collections/notes/records')
    page.click('[data-test=new-record]')
    page.get_by_label('password', exact=True).fill('custom profile value')
    page.get_by_label('externalAuths', exact=True).fill('{"provider":"custom"}')
    page.click('[data-test=record-save]')
    expect(page.locator('[data-test=record-drawer]')).to_have_count(0)
    record = api_request(page, 'GET', '/api/collections/notes/records').json()['items'][0]
    assert record['password'] == 'custom profile value'
    assert record['externalAuths'] == {'provider': 'custom'}
    page.goto('/_/#/collections/notes')
    # Schema controls also preserve valid custom field names.
    fields = page.locator('[data-test=field-name]')
    expect(fields).to_have_count(2)
    assert fields.evaluate_all('(els) => els.every(el => !el.disabled)')


@pytest.mark.parametrize('kind', ['base', 'auth'])
def test_record_metadata_fallback_recovers_shell_and_auth_handoff(page, kind):
    login(page)
    collection(page, 'profiles', kind, fields=[{'name': 'note', 'type': 'text'}])
    requests = []
    def fail_initial(route):
        requests.append(route.request.url)
        if len(requests) == 1:
            route.fulfill(status=500, json={'message': 'Initial metadata failed'})
        else:
            route.continue_()
    page.route('**/api/collections', fail_initial)
    page.goto('/_/?metadata-recovery=1#/collections/profiles/records')
    if kind == 'auth':
        scoped(page, 'profiles')
        expect(page.locator('[data-test=records-view]')).to_have_count(0)
        expect(page.locator('[data-test=users-error]')).to_have_count(0)
        page.click('[data-test=user-new]')
        expect(page.get_by_label('Password', exact=True)).to_be_visible()
    else:
        expect(page.locator('[data-test=records-view]')).to_be_visible()
        expect(page.locator('[data-test=nav-profiles]')).to_be_visible()
        page.click('[data-test=new-record]')
    expect(page.get_by_label('note', exact=True)).to_be_visible()
    expect(page.locator('.sidebar .error')).to_have_count(0)
    assert len(requests) == (3 if kind == 'auth' else 2)


def test_collection_switch_during_entry_refresh_keeps_request_live(page):
    login(page)
    collection(page, 'members')
    collection(page, 'staff')
    metadata = api_request(page, 'GET', '/api/collections').json()
    expect(page.locator('[data-test=nav-_superusers]')).to_be_visible()
    pending = []
    page.route('**/api/collections', lambda route: pending.append(route))
    with page.expect_request('**/api/collections'):
        page.goto('/_/#/users/members')
    expect(page.locator('[data-test=user-new]')).to_be_disabled()
    page.evaluate("location.hash = '#/users/staff'")
    expect(page).to_have_url(re.compile(r'#/users/staff$'))
    assert len(pending) == 1
    with page.expect_response('**/api/collections') as loaded:
        pending[0].fulfill(json=metadata)
    loaded.value.finished()
    scoped(page, 'staff')
    assert len(pending) == 1


@pytest.mark.parametrize('stale_error', [False, True])
def test_history_refresh_ignores_older_inflight_result_and_retains_completed_miss(page, stale_error):
    login(page)
    collection(page, 'members')
    page.goto('/_/?history-refresh=1#/users/members')
    scoped(page, 'members')
    cached = api_request(page, 'GET', '/api/collections').json()
    collection(page, 'late')
    requests, pending = [], []
    def metadata(route):
        requests.append(route.request)
        if len(requests) == 1:
            pending.append(route)
        else:
            route.continue_()
    page.route('**/api/collections', metadata)
    with page.expect_request('**/api/collections'):
        page.evaluate("location.hash = '#/users/late'")
    expect(page.locator('[data-test=user-new]')).to_be_disabled()
    page.click('[data-test=nav-collections]')
    expect(page.locator('[data-test=collections-home]')).to_be_visible()
    # Entering Users through history starts a fresh request; the older one stays
    # in flight, with no route-cancellation marker to release.
    with page.expect_request('**/api/collections'):
        page.go_back()
    scoped(page, 'late')
    assert len(requests) == 2
    with page.expect_response('**/api/collections') as stale:
        if stale_error:
            pending[0].fulfill(status=503, json={'message': 'Superseded failure'})
        else:
            pending[0].fulfill(json=cached)
    stale.value.finished()
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    scoped(page, 'late')
    expect(page.locator('.sidebar .error')).to_have_count(0)
    with page.expect_response('**/api/collections') as missing:
        page.evaluate("location.hash = '#/users/missing'")
    missing.value.finished()
    expect(page.locator('[data-test=users-not-found]')).to_be_visible()
    page.select_option('[data-test=users-collection]', 'late')
    scoped(page, 'late')
    page.go_back()
    expect(page.locator('[data-test=users-not-found]')).to_be_visible()
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    assert len(requests) == 3


def test_record_cache_miss_has_one_metadata_owner_and_keeps_newer_sidebar(page):
    login(page)
    collection(page, 'known', 'base')
    with page.expect_response('**/api/collections/_superusers/auth-refresh') as refreshed:
        page.goto('/_/?metadata-owner=1#/collections/known/records')
    refreshed.value.finished()
    expect(page.locator('[data-test=new-record]')).to_be_enabled()
    cached = api_request(page, 'GET', '/api/collections').json()
    collection(page, 'newer', 'base')
    fresh = api_request(page, 'GET', '/api/collections').json()
    pending = []
    page.route('**/api/collections', lambda route: pending.append(route))
    with page.expect_request('**/api/collections'):
        page.evaluate("location.hash = '#/collections/missing/records'")
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    assert len(pending) in (1, 2)
    # Older versions launched a child fallback alongside Shell's lookup. Let
    # the newer response publish first, then deliver the child's older snapshot.
    pending[-1].fulfill(json=fresh)
    expect(page.locator('[data-test=nav-newer]')).to_be_visible()
    if len(pending) > 1:
        with page.expect_response('**/api/collections') as stale:
            pending[0].fulfill(json=cached)
        stale.value.finished()
        page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    expect(page.locator('[data-test=nav-newer]')).to_be_visible()
    expect(page.locator('[data-test=new-record]')).to_be_disabled()
    assert len(pending) == 1
