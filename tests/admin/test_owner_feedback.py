"""Owner review regressions for collection types, freshness and auth policy."""
import pytest
from playwright.sync_api import expect
from conftest import api_request, login, save_collection_and_wait
from test_auth_navigation import collection


def records(page, name):
    with page.expect_response('**/api/collections/_superusers/auth-refresh') as refreshed:
        page.evaluate("name => location.hash = '#/collections/' + name + '/records'", name)
    refreshed.value.finished()
    expect(page.locator('[data-test=new-record]')).to_be_enabled()


@pytest.mark.parametrize('name', ['_suppressions', '_sender_identities'])
def test_builtin_base_email_create_and_edit(page, name):
    login(page)
    records(page, name)
    page.click('[data-test=new-record]')
    page.get_by_label('account', exact=True).fill('test-account')
    page.get_by_label('email', exact=True).fill('before@example.com')
    page.click('[data-test=record-save]')
    expect(page.locator('[data-test=record-drawer]')).to_have_count(0)
    page.click('[data-test=row]')
    page.get_by_label('email', exact=True).fill('after@example.com')
    page.click('[data-test=record-save]')
    expect(page.locator('[data-test=record-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', f'/api/collections/{name}/records').json()['items'][0]
    assert saved['email'] == 'after@example.com'


def test_field_filter_applies_auth_names_only_to_auth_collections(page):
    login(page)
    result = page.evaluate("""async () => {
        const { isSystemField } = await import('/_/assets/views/collections.js');
        const auth = ['email', 'username', 'verified', 'token_epoch'];
        return {
            base: auth.some(name => isSystemField(name, false)),
            auth: auth.every(name => isSystemField(name, true)),
            legacy: ['id', 'created', 'updated', 'passwordHash', 'tokenKey'].every(name => isSystemField(name, false)),
        };
    }""")
    assert result == {'base': False, 'auth': True, 'legacy': True}


def test_failed_missing_collection_does_not_poison_later_routes(page):
    login(page)
    collection(page, 'known', 'base')
    records(page, 'known')
    collection(page, 'first', 'base')
    collection(page, 'second', 'base')
    requests = []
    def metadata(route):
        requests.append(route.request)
        if len(requests) == 1:
            route.fulfill(status=503, json={'message': 'Temporary collection failure'})
        else:
            route.continue_()
    page.route('**/api/collections', metadata)
    page.evaluate("location.hash = '#/collections/first/records'")
    expect(page.locator('[data-test=records-error]')).to_have_text('Temporary collection failure')
    page.click('[data-test=nav-known]')
    expect(page.locator('[data-test=new-record]')).to_be_enabled()
    expect(page.locator('[data-test=records-error]')).to_have_count(0)
    expect(page.locator('.sidebar .error')).to_have_count(0)
    page.evaluate("location.hash = '#/collections/second/records'")
    expect(page.locator('[data-test=new-record]')).to_be_enabled()
    expect(page.locator('[data-test=nav-second]')).to_be_visible()
    expect(page.locator('[data-test=records-error]')).to_have_count(0)
    assert len(requests) == 2


def test_failed_collection_lookup_retries_when_the_route_is_revisited(page):
    login(page)
    collection(page, 'known', 'base')
    records(page, 'known')
    collection(page, 'late', 'base')
    requests = []
    def metadata(route):
        requests.append(route.request)
        if len(requests) == 1:
            route.fulfill(status=503, json={'message': 'Temporary collection failure'})
        else:
            route.continue_()
    page.route('**/api/collections', metadata)
    page.evaluate("location.hash = '#/collections/late/records'")
    expect(page.locator('[data-test=records-error]')).to_have_text('Temporary collection failure')
    expect(page.locator('[data-test=new-record]')).to_be_disabled()
    # Staying on the failed route must not start a retry loop.
    page.wait_for_timeout(300)
    assert len(requests) == 1
    page.click('[data-test=nav-known]')
    expect(page.locator('[data-test=new-record]')).to_be_enabled()
    page.evaluate("location.hash = '#/collections/late/records'")
    expect(page.locator('[data-test=new-record]')).to_be_enabled()
    expect(page.locator('[data-test=nav-late]')).to_be_visible()
    expect(page.locator('[data-test=records-error]')).to_have_count(0)
    assert len(requests) == 2


@pytest.mark.parametrize('editing', [False, True])
def test_drawer_fetches_new_required_schema_on_every_open(page, editing):
    login(page)
    original = collection(page, 'posts', 'base', fields=[{'name': 'title', 'type': 'text'}])
    if editing:
        response = api_request(page, 'POST', '/api/collections/posts/records', {'title': 'existing'})
        assert response.ok, response.text()
    records(page, 'posts')
    fields = original['schema'] + [{'id': '', 'name': 'summary', 'type': 'text', 'required': True, 'options': {}}]
    response = api_request(page, 'PATCH', '/api/collections/posts', {'name': 'posts', 'type': 'base', 'fields': fields})
    assert response.ok, response.text()
    page.click('[data-test=row]' if editing else '[data-test=new-record]')
    page.get_by_label('summary', exact=True).fill('fresh required field')
    page.click('[data-test=record-save]')
    expect(page.locator('[data-test=record-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', '/api/collections/posts/records').json()['items'][0]
    assert saved['summary'] == 'fresh required field'


@pytest.mark.parametrize('minimum', ['-1', '300', '9.5'])
def test_invalid_password_minimum_blocks_schema_save(page, minimum):
    login(page)
    collection(page, 'members')
    page.evaluate("location.hash = '#/collections/members'")
    page.click('[data-test=tab-auth]')
    page.fill('[data-test=min-pw]', minimum)
    expect(page.locator('[data-test=min-pw]')).to_have_value(minimum)
    expect(page.locator('[data-test=min-pw-error]')).to_be_visible()
    expect(page.locator('[data-test=save-collection]')).to_be_disabled()
    page.fill('[data-test=min-pw]', '8')
    expect(page.locator('[data-test=min-pw-error]')).to_have_count(0)
    expect(page.locator('[data-test=save-collection]')).to_be_enabled()


@pytest.mark.parametrize('minimum', [0, 255])
def test_password_minimum_boundaries_save_and_reload(page, minimum):
    login(page)
    collection(page, 'members')
    page.evaluate("location.hash = '#/collections/members'")
    page.click('[data-test=tab-auth]')
    page.fill('[data-test=min-pw]', str(minimum))
    save_collection_and_wait(page)
    page.click('[data-test=users-settings]')
    page.click('[data-test=tab-auth]')
    expect(page.locator('[data-test=min-pw]')).to_have_value(str(minimum))


@pytest.mark.parametrize('minimum', [-1, 300, 9.5])
@pytest.mark.parametrize('editing', [False, True])
def test_api_rejects_invalid_password_minimum_without_mutation(page, minimum, editing):
    login(page)
    if editing:
        collection(page, 'members')
    endpoint = '/api/collections/members' if editing else '/api/collections'
    response = api_request(page, 'PATCH' if editing else 'POST', endpoint, {
        'name': 'members', 'type': 'auth', 'fields': [], 'options': {'auth': {'minPasswordLength': minimum}},
    })
    assert response.status == 400, response.text()
    assert 'options.auth.minPasswordLength' in response.json()['data']
    rows = api_request(page, 'GET', '/api/collections').json()['items']
    found = next((c for c in rows if c['name'] == 'members'), None)
    if editing:
        assert found['options']['auth']['minPasswordLength'] == 8
    else:
        assert found is None


@pytest.mark.parametrize('editing', [False, True])
def test_user_drawer_refreshes_required_profile_and_password_policy(page, editing):
    login(page)
    original = collection(page, 'members')
    if editing:
        response = api_request(page, 'POST', '/api/collections/members/records', {
            'email': 'existing@example.com', 'password': 'original password',
        })
        assert response.ok, response.text()
    page.evaluate("location.hash = '#/users/members'")
    expect(page.locator('[data-test=user-new]')).to_be_enabled()
    list_requests = []
    def lists(route):
        list_requests.append(route.request)
        route.continue_()
    page.route('**/api/collections', lists)
    fields = original['schema'] + [{'id': '', 'name': 'summary', 'type': 'text', 'required': True, 'options': {}}]
    if not editing:
        fields.append({'id': '', 'name': 'consent', 'type': 'bool', 'required': True, 'options': {}})
    response = api_request(page, 'PATCH', '/api/collections/members', {
        'name': 'members', 'type': 'auth', 'fields': fields, 'options': {'auth': {'minPasswordLength': 12}},
    })
    assert response.ok, response.text()
    writes = []
    page.on('request', lambda request: writes.append(request) if request.method in ('POST', 'PATCH') and '/members/records' in request.url else None)
    page.click('[data-test=user-row]' if editing else '[data-test=user-new]')
    expect(page.get_by_label('summary', exact=True)).to_be_visible()
    page.get_by_label('summary', exact=True).fill('current required profile')
    if not editing:
        page.fill('[data-test=user-email]', 'new@example.com')
    page.fill('[data-test=user-password]', 'short123')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-error]')).to_have_text('Password is too short for this collection.')
    assert writes == []
    page.fill('[data-test=user-password]', 'updated long password')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    assert len(writes) == 1 and list_requests == []
    saved = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert saved['summary'] == 'current required profile'
    if not editing:
        assert saved['consent'] is False
    authenticated = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': saved['email'], 'password': 'updated long password',
    })
    assert authenticated.ok, authenticated.text()


def test_user_drawer_blocks_saves_while_definition_loading_or_failed(page):
    login(page)
    collection(page, 'members')
    page.evaluate("location.hash = '#/users/members'")
    expect(page.locator('[data-test=user-new]')).to_be_enabled()
    pending = []
    page.route('**/api/collections/members', lambda route: pending.append(route))
    with page.expect_request('**/api/collections/members'):
        page.click('[data-test=user-new]')
    expect(page.locator('[data-test=user-save]')).to_be_disabled()
    pending[0].fulfill(status=503, json={'message': 'Definition unavailable'})
    expect(page.locator('[data-test=user-error]')).to_have_text('Definition unavailable')
    expect(page.locator('[data-test=user-save]')).to_be_disabled()
