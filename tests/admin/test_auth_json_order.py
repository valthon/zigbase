"""JSON dirty tracking follows values rather than object member order."""
import json
import pytest
from playwright.sync_api import expect
from conftest import login, api_request
from test_auth_navigation import collection


@pytest.mark.parametrize('multipart', [False, True])
@pytest.mark.parametrize('edit', ['reordered', 'nested_value', 'array_order'])
def test_account_json_comparison_preserves_concurrent_preferences(page, multipart, edit):
    login(page)
    collection(page, 'members', fields=[
        {'name': 'preferences', 'type': 'json'},
        {'name': 'avatar', 'type': 'file'},
    ])
    original = {'theme': 'dark', 'nested': {'language': 'en', 'enabled': True},
                'items': [{'name': 'first', 'id': 1}, {'name': 'second', 'id': 2}]}
    created = api_request(page, 'POST', '/api/collections/members/records', {
        'email': 'json-order@example.com', 'password': 'safe password here',
        'preferences': original})
    assert created.ok, created.text()
    endpoint = '/api/collections/members/records/' + created.json()['id']
    page.goto('/_/#/users/members')
    page.click('[data-test=user-row]')
    # Reorder members at every object depth, including objects inside arrays.
    edited = {'items': [{'id': 1, 'name': 'first'}, {'id': 2, 'name': 'second'}],
              'nested': {'enabled': True, 'language': 'en'}, 'theme': 'dark'}
    if edit == 'nested_value':
        edited['nested']['language'] = 'fr'
    elif edit == 'array_order':
        edited['items'].reverse()
    page.fill('[data-test=in-preferences]', json.dumps(edited))
    concurrent = {'theme': 'light', 'concurrent': True}
    response = api_request(page, 'PATCH', endpoint, {'preferences': concurrent})
    assert response.ok, response.text()
    page.fill('[data-test=user-password]', 'replacement safe password')
    if multipart:
        page.set_input_files('[data-test=in-avatar]', {
            'name': 'new.txt', 'mimeType': 'text/plain', 'buffer': b'new'})
    with page.expect_response(lambda r: r.url.endswith(endpoint) and r.request.method == 'PATCH') as write:
        page.click('[data-test=user-save]')
    assert write.value.ok, write.value.text()
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    if multipart:
        assert 'multipart/form-data' in write.value.request.headers['content-type']
    else:
        payload = {'password': 'replacement safe password'}
        if edit != 'reordered':
            payload['preferences'] = edited
        assert write.value.request.post_data_json == payload
    saved = api_request(page, 'GET', endpoint).json()['preferences']
    if isinstance(saved, str):
        saved = json.loads(saved)
    assert saved == (concurrent if edit == 'reordered' else edited)
    authenticated = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': 'json-order@example.com', 'password': 'replacement safe password'})
    assert authenticated.ok, authenticated.text()
