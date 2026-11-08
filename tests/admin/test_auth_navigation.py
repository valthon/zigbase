"""Collection type determines the account workspace and complete account form."""
import json
import re
import pytest
from playwright.sync_api import expect
from conftest import login, api_request


def collection(page, name, type="auth", fields=None, options=None):
    body = {"name": name, "type": type, "fields": [{"id": "", "options": {}, **f} for f in (fields or [])]}
    if options is not None:
        body["options"] = options
    response = api_request(page, "POST", "/api/collections", body)
    assert response.ok, response.text()
    return response.json()


def scoped(page, name):
    expect(page).to_have_url(re.compile(r"#/users/" + name + r"$"))
    expect(page.locator('[data-test=users-collection]')).to_have_value(name)
    expect(page.locator('[data-test=user-new]')).to_be_enabled()


@pytest.mark.parametrize('kind', ['auth', 'base'])
def test_profile_controls_have_accessible_names(page, kind):
    login(page)
    groups = collection(page, 'groups', 'base')
    group = api_request(page, 'POST', '/api/collections/groups/records', {}).json()['id']
    fields = [
        {'name': 'displayName', 'type': 'text', 'required': True},
        {'name': 'consent', 'type': 'bool', 'required': True},
        {'name': 'rating', 'type': 'number', 'required': True},
        {'name': 'visits', 'type': 'number', 'options': {'mode': 'int'}},
        {'name': 'balance', 'type': 'number', 'options': {'mode': 'fixed', 'scale': 2}},
        {'name': 'birthday', 'type': 'date'},
        {'name': 'contact', 'type': 'email'},
        {'name': 'website', 'type': 'url'},
        {'name': 'level', 'type': 'select', 'required': True, 'options': {'values': ['reader', 'editor']}},
        {'name': 'tags', 'type': 'select', 'options': {'values': ['a', 'b'], 'maxSelect': 2}},
        {'name': 'group', 'type': 'relation', 'options': {'targetCollectionId': groups['id']}},
        {'name': 'groups', 'type': 'relation', 'options': {'targetCollectionId': groups['id'], 'maxSelect': 2}},
        {'name': 'preferences', 'type': 'json', 'required': True},
        {'name': 'biography', 'type': 'editor', 'required': True},
        {'name': 'avatar', 'type': 'file', 'required': True, 'options': {'maxSelect': 2}},
    ]
    collection(page, 'members', kind, fields)
    page.goto('/_/#/users/members' if kind == 'auth' else '/_/#/collections/members/records')
    page.click('[data-test=user-new]' if kind == 'auth' else '[data-test=new-record]')
    drawer = page.locator('[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]')
    for field in fields:
        control = drawer.get_by_label(field['name'], exact=True)
        expect(control).to_have_count(1)
        expect(control).to_have_accessible_name(field['name'])
        assert control.get_attribute('id')
        if field.get('required'):
            expect(control).to_have_attribute('aria-required', 'true')
    ids = drawer.locator('input[id], select[id], textarea[id], [contenteditable][id]').evaluate_all('(els) => els.map(el => el.id)')
    assert len(ids) == len(set(ids))
    prefix = 'user-field-' if kind == 'auth' else 'record-field-'
    drawer.locator(f'label[for={prefix}displayName]').click()
    expect(drawer.get_by_label('displayName', exact=True)).to_be_focused()
    drawer.locator(f'label[for={prefix}consent]').click()
    expect(drawer.get_by_label('consent', exact=True)).to_be_checked()
    expect(drawer.get_by_role('combobox', name='group', exact=True)).to_be_visible()
    expect(drawer.get_by_role('listbox', name='groups', exact=True)).to_be_visible()
    expect(drawer.get_by_role('listbox', name='tags', exact=True)).to_be_visible()
    expect(drawer.get_by_role('textbox', name='preferences', exact=True)).to_be_visible()
    if kind == 'auth':
        drawer.get_by_label('Email', exact=True).fill('labels@example.com')
        drawer.get_by_label('Username', exact=True).fill('labels')
        drawer.get_by_label('Password', exact=True).fill('safe password here')
    drawer.get_by_label('displayName', exact=True).fill('Accessible profile')
    drawer.get_by_label('consent', exact=True).check()
    for name, value in {'rating': '1.5', 'visits': '9007199254740993', 'balance': '12.34', 'birthday': '2026-11-07', 'contact': 'profile@example.com', 'website': 'https://example.com'}.items():
        drawer.get_by_label(name, exact=True).fill(value)
    drawer.get_by_label('level', exact=True).select_option('reader')
    drawer.get_by_label('tags', exact=True).select_option(['a', 'b'])
    drawer.get_by_label('group', exact=True).select_option(group)
    drawer.get_by_label('groups', exact=True).select_option([group])
    drawer.get_by_label('preferences', exact=True).fill('{"theme":"dark"}')
    drawer.get_by_role('button', name='Format preferences JSON', exact=True).click()
    rich_text = drawer.get_by_role('textbox', name='biography', exact=True)
    expect(rich_text).to_have_attribute('aria-multiline', 'true')
    rich_text.fill('Accessible biography')
    expect(drawer.get_by_role('group', name='biography formatting', exact=True)).to_be_visible()
    expect(drawer.get_by_role('button', name='Bold', exact=True)).to_be_visible()
    drawer.get_by_label('avatar', exact=True).set_input_files({'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    save = '[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]'
    drawer.locator(save).click()
    expect(drawer).to_have_count(0)
    record = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert record['displayName'] == 'Accessible profile'
    assert record['biography'] == 'Accessible biography'
    page.click('[data-test=user-row]' if kind == 'auth' else '[data-test=row]')
    expect(drawer.locator('input[id], select[id], textarea[id], [contenteditable][id]')).to_have_count(len(ids))
    assert drawer.locator('input[id], select[id], textarea[id], [contenteditable][id]').evaluate_all('(els) => els.map(el => el.id)') == ids
    expect(drawer.get_by_label('displayName', exact=True)).to_have_value('Accessible profile')
    if kind == 'auth':
        expect(drawer.get_by_label('Set new password (admin reset)', exact=True)).to_be_visible()
    expect(drawer.get_by_role('checkbox', name=re.compile(r'^Remove avatar file '))).to_have_count(1)
    drawer.get_by_role('checkbox', name=re.compile(r'^Remove avatar file ')).check()
    # Replace the required file and preserve the same names on edit.
    drawer.get_by_label('avatar', exact=True).set_input_files({'name': 'replacement.txt', 'mimeType': 'text/plain', 'buffer': b'replacement'})
    drawer.locator(save).click()
    expect(drawer).to_have_count(0)
    updated = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert 'replacement' in str(updated['avatar'])
    assert 'avatar' not in str(updated['avatar'])


def test_type_groups_multiple_auth_and_base_named_users(page):
    login(page)
    collection(page, "users", "base")
    collection(page, "members")
    collection(page, "staff")
    page.reload()
    for name in ("members", "staff", "_superusers"):
        expect(page.locator(f'[data-test=nav-users-group] [data-test=nav-{name}]')).to_be_visible()
        expect(page.locator(f'[data-test=nav-data-group] [data-test=nav-{name}]')).to_have_count(0)
    page.click('[data-test=nav-members]')
    scoped(page, "members")
    expect(page.locator('[data-test=new-record]')).to_have_count(0)
    page.click('[data-test=nav-users-group] [data-test=nav-staff]')
    scoped(page, "staff")
    page.click('[data-test=nav-data-group] [data-test=nav-users]')
    expect(page.locator('[data-test=records-view]')).to_be_visible()
    expect(page.locator('[data-test=new-record]')).to_be_visible()


def test_scoped_links_reload_history_and_legacy_handoff(page):
    login(page)
    collection(page, "members")
    collection(page, "staff")
    page.goto('/_/#/users/members')
    scoped(page, "members")
    page.select_option('[data-test=users-collection]', 'staff')
    scoped(page, "staff")
    page.go_back()
    scoped(page, "members")
    page.go_forward()
    scoped(page, "staff")
    page.reload()
    scoped(page, "staff")
    page.goto('/_/#/collections/members/records')
    scoped(page, "members")
    expect(page.locator('[data-test=new-record]')).to_have_count(0)
    page.click('[data-test=users-settings]')
    expect(page.locator('[data-test=schema-editor]')).to_be_visible()
    expect(page.locator('[data-test=col-name]')).to_have_value('members')
    expect(page.locator('[data-test=manage-users]')).to_have_attribute('href', '#/users/members')
    page.click('[data-test=manage-users]')
    scoped(page, "members")
    page.click('[data-test=nav-collections]')
    page.click('[data-test=settings-staff]')
    expect(page.locator('[data-test=manage-users]')).to_have_attribute('href', '#/users/staff')
    page.click('[data-test=nav-collections]')
    expect(page.locator('[data-test=new-collection]')).to_be_visible()


def test_custom_required_profile_create_edit_and_password(page):
    login(page)
    collection(page, "members", fields=[
        {"name": "displayName", "type": "text", "required": True},
        {"name": "level", "type": "select", "required": True, "options": {"values": ["reader", "editor"]}},
        {"name": "preferences", "type": "json"},
        {"name": "joined", "type": "autodate"},
    ], options={"auth": {"identityFields": ["username"], "minPasswordLength": 12}})
    page.goto('/_/#/users/members')
    scoped(page, "members")
    page.click('[data-test=user-new]')
    assert page.locator('[data-test=user-password]').get_attribute('minlength') is None
    expect(page.locator('[data-test=user-password]')).to_have_attribute('required', '')
    page.fill('[data-test=user-username]', 'river')
    page.fill('[data-test=user-password]', 'a long safe password')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=err-displayName]')).to_be_visible()
    page.fill('[data-test=in-displayName]', 'River')
    page.select_option('[data-test=in-level]', 'reader')
    page.fill('[data-test=in-preferences]', '{broken')
    expect(page.locator('[data-test=user-save]')).to_be_disabled()
    page.fill('[data-test=in-preferences]', '{"theme":"dark"}')
    expect(page.locator('[data-test=user-save]')).to_be_enabled()
    for name in ('joined', 'verified', 'passwordHash', 'tokenKey', 'token_epoch', 'externalAuths', 'id'):
        expect(page.locator(f'[data-test=in-{name}]')).to_have_count(0)
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]:has-text("river")')
    expect(page.locator('[data-test=in-displayName]')).to_have_value('River')
    expect(page.locator('[data-test=in-level]')).to_have_value('reader')
    page.fill('[data-test=in-displayName]', 'River Updated')
    page.select_option('[data-test=in-level]', 'editor')
    page.fill('[data-test=user-password]', 'another long safe password')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['displayName'] == 'River Updated'
    assert user['level'] == 'editor'
    preferences = user['preferences']
    assert (json.loads(preferences) if isinstance(preferences, str) else preferences) == {'theme': 'dark'}
    response = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': 'river', 'password': 'another long safe password'})
    assert response.ok, response.text()


def test_profile_files_and_multi_select_roundtrip(page):
    login(page)
    groups = collection(page, 'groups', 'base')
    group_ids = [api_request(page, 'POST', '/api/collections/groups/records', {}).json()['id'] for _ in range(2)]
    # Relation membership is independent of the option-list order.
    def reversed_options(route):
        response = route.fetch()
        data = response.json()
        data['items'].sort(key=lambda record: group_ids.index(record['id']), reverse=True)
        route.fulfill(response=response, json=data)
    page.route(f"**/api/collections/{groups['id']}/records?*", reversed_options)
    collection(page, 'members', fields=[
        {'name': 'groups', 'type': 'relation', 'options': {'targetCollectionId': groups['id'], 'maxSelect': 2}},
        {'name': 'avatar', 'type': 'file'},
        {'name': 'tags', 'type': 'select', 'options': {'values': ['a', 'b', 'c'], 'maxSelect': 3}},
    ])
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'files@example.com')
    page.fill('[data-test=user-password]', 'safe password here')
    page.select_option('[data-test=in-groups]', group_ids)
    page.select_option('[data-test=in-tags]', ['a', 'b'])
    page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    expect(page.locator('[data-test=rm-avatar]')).to_have_count(1)
    expect(page.locator('[data-test=in-tags]')).to_have_values(['a', 'b'])
    expect(page.locator('[data-test=in-groups] option')).to_have_text(list(reversed(group_ids)))
    selected = page.locator('[data-test=in-groups] option:checked')
    expect(selected).to_have_count(2)
    assert sorted(selected.evaluate_all('(options) => options.map(option => option.value)')) == sorted(group_ids)
    page.check('[data-test=rm-avatar]')
    page.select_option('[data-test=in-tags]', ['c'])
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert not user['avatar']
    relations = user['groups']
    assert sorted(json.loads(relations) if isinstance(relations, str) else relations) == sorted(group_ids)
    tags = user['tags']
    assert (json.loads(tags) if isinstance(tags, str) else tags) == ['c']


def test_superuser_settings_and_collapsed_navigation(page):
    login(page)
    page.click('[data-test=nav-_superusers]')
    scoped(page, '_superusers')
    page.click('[data-test=users-settings]')
    expect(page.locator('[data-test=delete-collection]')).to_have_count(0)
    expect(page.locator('[data-test=col-name]')).to_be_disabled()
    expect(page.locator('[data-test=manage-users]')).to_have_attribute('href', '#/users/_superusers')
    page.click('[data-test=sidebar-toggle]')
    page.click('[data-test=nav-_superusers]')
    scoped(page, '_superusers')
    page.click('[data-test=nav-collections]')
    expect(page.locator('[data-test=new-collection]')).to_be_visible()


def test_unknown_auth_collection_does_not_select_default(page):
    login(page)
    page.goto('/_/#/users/missing')
    expect(page.locator('[data-test=users-not-found]')).to_be_visible()
    expect(page.locator('[data-test=user-new]')).to_be_disabled()
    expect(page.locator('[data-test=user-row]')).to_have_count(0)


def test_empty_users_workspace(page):
    login(page)
    page.route('**/api/collections', lambda route: route.fulfill(json={'items': []}))
    page.goto('/_/#/users')
    page.reload()  # Start a fresh Shell with the mocked collection-list snapshot.
    expect(page.locator('[data-test=users-empty]')).to_be_visible()
    expect(page.locator('[data-test=user-new]')).to_be_disabled()
    expect(page.locator('[data-test=new-collection]')).to_have_count(0)
    page.click('[data-test=users-empty] a')
    expect(page.locator('[data-test=schema-editor]')).to_be_visible()


def test_auth_collection_creation_lands_in_its_users_workspace(page):
    from conftest import save_collection_and_wait
    login(page)
    page.click('[data-test=nav-collections]')
    page.click('[data-test=new-collection]')
    page.fill('[data-test=col-name]', 'subscribers')
    page.select_option('[data-test=col-type]', 'auth')
    save_collection_and_wait(page)
    scoped(page, 'subscribers')
    expect(page.locator('[data-test=new-record]')).to_have_count(0)
    page.click('[data-test=users-settings]')
    expect(page.locator('[data-test=manage-users]')).to_have_attribute('href', '#/users/subscribers')


def test_float_and_exact_decimal_profile_fields_without_files(page):
    login(page)
    collection(page, 'members', fields=[
        {'name': 'rating', 'type': 'number', 'options': {'mode': 'float'}},
        {'name': 'visits', 'type': 'number', 'options': {'mode': 'int'}},
        {'name': 'balance', 'type': 'number', 'options': {'mode': 'fixed', 'scale': 2}},
    ])
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'numbers@example.com')
    page.fill('[data-test=user-password]', 'safe password here')
    page.fill('[data-test=in-rating]', 'invalid')
    page.fill('[data-test=in-visits]', '9007199254740993')
    page.fill('[data-test=in-balance]', '12.34')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-error]')).to_be_visible()
    assert api_request(page, 'GET', '/api/collections/members/records').json()['totalItems'] == 0
    page.fill('[data-test=in-rating]', '1.5')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['rating'] == 1.5
    assert user['visits'] == '9007199254740993'
    assert user['balance'] == '12.34'
    page.click('[data-test=user-row]')
    page.fill('[data-test=in-rating]', '2.75')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['rating'] == 2.75
    assert user['visits'] == '9007199254740993'
    assert user['balance'] == '12.34'
    page.click('[data-test=user-row]')
    for name in ('rating', 'visits', 'balance'):
        page.fill(f'[data-test=in-{name}]', '')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert all(user[name] is None for name in ('rating', 'visits', 'balance'))


def test_required_boolean_profile_defaults_false_and_preserves_edits(page):
    login(page)
    collection(page, 'members', fields=[{'name': 'optedIn', 'type': 'bool', 'required': True}])
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'boolean@example.com')
    page.fill('[data-test=user-password]', 'safe password here')
    expect(page.locator('[data-test=in-optedIn]')).not_to_be_checked()
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['optedIn'] is False
    page.click('[data-test=user-row]')
    page.check('[data-test=in-optedIn]')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    expect(page.locator('[data-test=in-optedIn]')).to_be_checked()
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['optedIn'] is True


@pytest.mark.parametrize('profile_value', ['true', '', True, False, 1.5, {'a': [1]}, [1, 'x'], None])
def test_multipart_profile_json_types_and_explicit_clears(page, profile_value):
    login(page)
    groups = collection(page, 'groups', 'base')
    group = api_request(page, 'POST', '/api/collections/groups/records', {}).json()['id']
    collection(page, 'members', fields=[
        {'name': 'profile', 'type': 'json'},
        {'name': 'group', 'type': 'relation', 'options': {'targetCollectionId': groups['id'], 'maxSelect': 1}},
        {'name': 'avatar', 'type': 'file'},
    ])
    response = api_request(page, 'POST', '/api/collections/members/records', {
        'email': 'multipart@example.com', 'password': 'safe password here', 'profile': {'old': True}, 'group': group})
    assert response.ok, response.text()
    user_id = response.json()['id']
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-row]')
    page.fill('[data-test=in-profile]', '' if profile_value is None else json.dumps(profile_value))
    page.select_option('[data-test=in-group]', '')
    page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', f'/api/collections/members/records/{user_id}').json()
    assert user['profile'] == profile_value
    assert type(user['profile']) is type(profile_value)
    assert not user['group']
    assert user['avatar']
    # A second multipart PATCH clears both fields while removing the existing
    # file, rather than uploading one. Re-seed the relation for a real clear.
    response = api_request(page, 'PATCH', f'/api/collections/members/records/{user_id}', {'group': group, 'profile': {'old': True}})
    assert response.ok, response.text()
    page.reload()
    page.click('[data-test=user-row]')
    page.fill('[data-test=in-profile]', '')
    page.select_option('[data-test=in-group]', '')
    page.check('[data-test=rm-avatar]')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', f'/api/collections/members/records/{user_id}').json()
    assert user['profile'] is None
    assert not user['group']
    assert not user['avatar']


def test_relation_picker_retains_off_page_references_until_removed(page):
    login(page)
    groups = collection(page, 'groups', 'base')
    for _ in range(55):
        response = api_request(page, 'POST', '/api/collections/groups/records', {})
        assert response.ok, response.text()
    first_page = api_request(page, 'GET', '/api/collections/groups/records?perPage=50').json()['items']
    all_groups = api_request(page, 'GET', '/api/collections/groups/records?perPage=100').json()['items']
    visible = first_page[0]['id']
    outside = next(g['id'] for g in all_groups if g['id'] not in {r['id'] for r in first_page})
    collection(page, 'members', fields=[
        {'name': 'groups', 'type': 'relation', 'options': {'targetCollectionId': groups['id'], 'maxSelect': 2}},
    ])
    response = api_request(page, 'POST', '/api/collections/members/records', {
        'email': 'relations@example.com', 'password': 'safe password here', 'groups': [outside]})
    assert response.ok, response.text()
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-row]')
    picker = page.locator('[data-test=in-groups]')
    expect(picker.locator(f'option[value="{visible}"]')).to_have_count(1)
    expect(picker).to_have_values([outside])
    # Add a visible option as a user would with Ctrl-click, keeping the existing
    # off-page option selected. Every selected reference must exist in the DOM.
    picker.evaluate("""(select, id) => {
      [...select.options].find(option => option.value === id).selected = true;
      select.dispatchEvent(new Event('change', { bubbles: true }));
    }""", visible)
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert sorted(user['groups']) == sorted([outside, visible])
    page.click('[data-test=user-row]')
    page.select_option('[data-test=in-groups]', [visible])
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    user = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert user['groups'] == [visible]


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('initial_status', [None, 'active'])
@pytest.mark.parametrize('file_change', ['upload', 'remove', 'none'])
def test_optional_single_select_file_changes_and_clear(page, kind, initial_status, file_change):
    from conftest import csrf
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'status', 'type': 'select', 'options': {'values': ['active', 'paused'], 'maxSelect': 1}},
        {'name': 'avatar', 'type': 'file'},
        {'name': 'note', 'type': 'text'},
    ])
    body = {'note': 'initial'}
    if initial_status is not None:
        body['status'] = initial_status
    if kind == 'auth':
        body.update(email='select@example.com', password='safe password here')
    response = api_request(page, 'POST', '/api/collections/profiles/records', body)
    assert response.ok, response.text()
    record_id = response.json()['id']
    endpoint = f'/api/collections/profiles/records/{record_id}'
    if file_change == 'remove':
        response = page.request.patch(endpoint, headers={'X-CSRF-Token': csrf(page)}, multipart={
            'avatar': {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'}})
        assert response.ok, response.text()
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    page.click('[data-test=user-row]' if kind == 'auth' else '[data-test=row]')
    expect(page.locator('[data-test=in-status]')).to_have_value(initial_status or '')
    page.fill('[data-test=in-note]', 'updated profile')
    if initial_status:
        page.select_option('[data-test=in-status]', '')
    if file_change == 'upload':
        page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    elif file_change == 'remove':
        page.check('[data-test=rm-avatar]')
    with page.expect_request(lambda request: request.url.endswith(endpoint) and request.method == 'PATCH') as write:
        page.click('[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]')
    submitted = write.value
    if file_change == 'none':
        assert 'application/json' in submitted.headers['content-type']
        if kind == 'auth' and initial_status is None:
            assert 'status' not in submitted.post_data_json  # unchanged profile values are omitted
        else:
            assert submitted.post_data_json['status'] is None
        assert submitted.post_data_json['note'] == 'updated profile'
    else:
        assert 'multipart/form-data' in submitted.headers['content-type']
    expect(page.locator('[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', endpoint).json()
    assert saved['status'] is None
    assert saved['note'] == 'updated profile'
    assert bool(saved['avatar']) == (file_change == 'upload')


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('initial,choice,upload,expected', [
    ('active', '(empty)', False, ''),
    ('active', '(empty)', True, ''),
    ('active', '—', False, None),
    ('active', '—', True, None),
    (None, None, True, None),
    ('', None, False, ''),
])
def test_declared_empty_select_option_stays_distinct_from_no_selection(page, kind, initial, choice, upload, expected):
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'status', 'type': 'select', 'options': {'values': ['', 'active'], 'maxSelect': 1}},
        {'name': 'avatar', 'type': 'file'},
        {'name': 'note', 'type': 'text'},
    ])
    body = {'note': 'initial'}
    if initial is not None:
        body['status'] = initial
    if kind == 'auth':
        body.update(email='empty@example.com', password='safe password here')
    response = api_request(page, 'POST', '/api/collections/profiles/records', body)
    assert response.ok, response.text()
    endpoint = f"/api/collections/profiles/records/{response.json()['id']}"
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    page.click('[data-test=user-row]' if kind == 'auth' else '[data-test=row]')
    shown = page.locator('[data-test=in-status] option:checked')
    expect(shown).to_have_text('active' if initial == 'active' else '(empty)' if initial == '' else '—')
    page.fill('[data-test=in-note]', 'updated profile')
    if choice is not None:
        page.select_option('[data-test=in-status]', label=choice)
    if upload:
        page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    page.click('[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]')
    expect(page.locator('[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', endpoint).json()
    assert saved['status'] == expected
    assert saved['note'] == 'updated profile'


def test_select_placeholder_never_collides_with_a_declared_option(page):
    login(page)
    option = '__zigbase_no_selection__'
    collection(page, 'profiles', 'base', fields=[
        {'name': 'status', 'type': 'select', 'options': {'values': ['', option], 'maxSelect': 1}},
    ])
    response = api_request(page, 'POST', '/api/collections/profiles/records', {})
    assert response.ok, response.text()
    endpoint = f"/api/collections/profiles/records/{response.json()['id']}"
    page.goto('/_/#/collections/profiles/records')
    page.click('[data-test=row]')
    page.select_option('[data-test=in-status]', label=option)
    page.click('[data-test=record-save]')
    expect(page.locator('[data-test=record-drawer]')).to_have_count(0)
    assert api_request(page, 'GET', endpoint).json()['status'] == option


def test_non_ascii_password_creation_and_admin_reset_use_utf8_bytes(page):
    login(page)
    collection(page, 'members')
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    page.click('[data-test=user-new]')
    page.fill('[data-test=user-email]', 'unicode@example.com')
    page.fill('[data-test=user-password]', 'ééé')  # Six UTF-8 bytes: below the default minimum.
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-error]')).to_contain_text('too short')
    page.fill('[data-test=user-password]', 'éééé')  # Four UTF-16 units, eight UTF-8 bytes.
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    page.fill('[data-test=user-password]', '😀😀')  # Another valid eight-byte password.
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    response = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': 'unicode@example.com', 'password': '😀😀'})
    assert response.ok, response.text()


@pytest.mark.parametrize('multipart', [False, True], ids=['json', 'multipart'])
def test_zero_password_minimum_create_and_edit(page, multipart):
    login(page)
    collection(page, 'members', fields=[{'name': 'note', 'type': 'text'}, {'name': 'avatar', 'type': 'file'}],
               options={'auth': {'minPasswordLength': 0}})
    # A present empty password is supported by the owning REST create path.
    reference = api_request(page, 'POST', '/api/collections/members/records', {'email': 'reference@example.com', 'password': ''})
    assert reference.ok, reference.text()
    page.goto('/_/#/users/members')
    page.click('[data-test=user-new]')
    page.get_by_label('Email', exact=True).fill('zero@example.com')
    page.get_by_label('note', exact=True).fill('initial')
    assert page.get_by_label('Password', exact=True).get_attribute('required') is None

    def upload(name):
        if multipart:
            page.get_by_label('avatar', exact=True).set_input_files({'name': name, 'mimeType': 'text/plain', 'buffer': b'avatar'})

    def save(method, endpoint):
        with page.expect_response(lambda response: response.url.endswith(endpoint) and response.request.method == method) as write:
            page.click('[data-test=user-save]')
        assert write.value.ok, write.value.text()
        expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
        request = write.value.request
        if multipart:
            assert 'multipart/form-data' in request.headers['content-type']
            # File-bearing request bodies are unavailable through Chromium's
            # request.post_data; successful creation and login prove the value.
            return None
        assert 'application/json' in request.headers['content-type']
        return [request.post_data_json['password']] if 'password' in request.post_data_json else []

    upload('initial.txt')
    assert save('POST', '/api/collections/members/records') == (None if multipart else [''])
    record = next(user for user in api_request(page, 'GET', '/api/collections/members/records').json()['items'] if user['email'] == 'zero@example.com')
    endpoint = '/api/collections/members/records/' + record['id']
    page.locator('[data-test=user-row]').filter(has_text='zero@example.com').click()
    page.get_by_label('note', exact=True).fill('changed without password')
    upload('profile.txt')
    assert save('PATCH', endpoint) == (None if multipart else [])
    response = page.request.post('/api/collections/members/auth-with-password', data={'identity': 'zero@example.com', 'password': ''})
    assert response.ok, response.text()
    login(page)
    page.goto('/_/#/users/members')
    page.locator('[data-test=user-row]').filter(has_text='zero@example.com').click()
    page.get_by_label('Set new password (admin reset)', exact=True).fill('é')
    upload('reset.txt')
    assert save('PATCH', endpoint) == (None if multipart else ['é'])
    page.locator('[data-test=user-row]').filter(has_text='zero@example.com').click()
    page.get_by_label('note', exact=True).fill('blank reset preserves nonempty password')
    upload('unchanged-password.txt')
    assert save('PATCH', endpoint) == (None if multipart else [])
    saved = api_request(page, 'GET', endpoint).json()
    assert saved['note'] == 'blank reset preserves nonempty password'
    response = page.request.post('/api/collections/members/auth-with-password', data={'identity': 'zero@example.com', 'password': 'é'})
    assert response.ok, response.text()


@pytest.mark.parametrize('unsaved_name', ['not_saved_yet', 'staff'])
def test_manage_users_keeps_persisted_collection_for_unsaved_name(page, unsaved_name):
    login(page)
    collection(page, 'members')
    collection(page, 'staff')
    for name in ('members', 'staff'):
        response = api_request(page, 'POST', f'/api/collections/{name}/records', {
            'email': f'{name}@example.com', 'password': 'safe password here'})
        assert response.ok, response.text()
    page.goto('/_/#/collections/members')
    page.fill('[data-test=col-name]', unsaved_name)
    expect(page.locator('[data-test=manage-users]')).to_have_attribute('href', '#/users/members')
    page.click('[data-test=manage-users]')
    scoped(page, 'members')
    expect(page.locator('[data-test=user-row]')).to_contain_text('members@example.com')
    definitions = api_request(page, 'GET', '/api/collections').json()['items']
    assert any(c['name'] == 'members' for c in definitions)


@pytest.mark.parametrize('existing', [False, True], ids=['create', 'existing'])
def test_international_email_account_creation_profile_and_password_reset(page, existing):
    login(page)
    collection(page, 'members', fields=[{'name': 'note', 'type': 'text'}])
    email = 'élise@example.com'
    if existing:
        response = api_request(page, 'POST', '/api/collections/members/records', {
            'email': email, 'password': 'safe password here', 'note': 'initial'})
        assert response.ok, response.text()
    page.goto('/_/#/users/members')
    scoped(page, 'members')
    if not existing:
        page.click('[data-test=user-new]')
        page.fill('[data-test=user-email]', email)
        page.fill('[data-test=user-password]', 'safe password here')
        page.fill('[data-test=in-note]', 'initial')
        page.click('[data-test=user-save]')
        expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    expect(page.locator('[data-test=user-email]')).to_have_value(email)
    page.fill('[data-test=in-note]', 'updated profile')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    page.click('[data-test=user-row]')
    expect(page.locator('[data-test=user-email]')).to_have_value(email)
    page.fill('[data-test=user-password]', 'new safe password here')
    page.click('[data-test=user-save]')
    expect(page.locator('[data-test=user-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', '/api/collections/members/records').json()['items'][0]
    assert saved['email'] == email
    assert saved['note'] == 'updated profile'
    response = page.request.post('/api/collections/members/auth-with-password', data={
        'identity': email, 'password': 'new safe password here'})
    assert response.ok, response.text()


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('file_change', ['none', 'upload', 'remove'])
@pytest.mark.parametrize('input_value,expected,accepted', [
    pytest.param('1.5', 1.5, True, id='decimal'),
    pytest.param('0b10', 2, True, id='binary'),
    pytest.param('0x10', 16, True, id='hexadecimal'),
    pytest.param('0o10', 8, True, id='octal'),
    pytest.param('1e2', 100, True, id='exponent'),
    pytest.param('1e20', 1e20, True, id='large-integral-token'),
    pytest.param('-1e20', -1e20, True, id='negative-large-integral-token'),
    pytest.param('9223372036854775808', float(9223372036854775808), True, id='i64-positive-edge'),
    pytest.param('-9223372036854775808', float(-9223372036854775808), True, id='i64-negative-edge'),
    pytest.param('1e21', 1e21, True, id='large-exponent-token'),
    pytest.param('-1e21', -1e21, True, id='negative-large-exponent-token'),
    pytest.param('1.7976931348623157e308', 1.7976931348623157e308, True, id='maximum-finite'),
    pytest.param('1e-999', 0, True, id='underflow'),
    pytest.param('-0', 0, True, id='negative-zero'),
    pytest.param(' 1.5 ', 1.5, True, id='padded-decimal'),
    pytest.param('', None, True, id='empty-clear'),
    pytest.param(' ', None, False, id='whitespace'),
    pytest.param('NaN', None, False, id='nan'),
    pytest.param('Infinity', None, False, id='infinity'),
    pytest.param('1e999', None, False, id='overflow'),
    pytest.param('1_000', None, False, id='underscore'),
    pytest.param('0x1p4', None, False, id='hex-float'),
    pytest.param('-0x10', None, False, id='signed-hex'),
])
def test_float_transport_parity_and_exact_decimals(page, kind, file_change, input_value, expected, accepted):
    from conftest import csrf
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'rating', 'type': 'number', 'options': {'mode': 'float'}},
        {'name': 'visits', 'type': 'number', 'options': {'mode': 'int'}},
        {'name': 'balance', 'type': 'number', 'options': {'mode': 'fixed', 'scale': 2}},
        {'name': 'note', 'type': 'text'},
        {'name': 'avatar', 'type': 'file'},
    ])
    body = {'rating': 1.25, 'visits': '9007199254740993', 'balance': '12.34', 'note': 'initial'}
    if kind == 'auth':
        body.update(email='numeric@example.com', password='safe password here')
    response = api_request(page, 'POST', '/api/collections/profiles/records', body)
    assert response.ok, response.text()
    record_id = response.json()['id']
    endpoint = f'/api/collections/profiles/records/{record_id}'
    if file_change == 'remove':
        response = page.request.patch(endpoint, headers={'X-CSRF-Token': csrf(page)}, multipart={
            'avatar': {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'}})
        assert response.ok, response.text()
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    page.click('[data-test=user-row]' if kind == 'auth' else '[data-test=row]')
    page.fill('[data-test=in-rating]', input_value)
    page.fill('[data-test=in-visits]', '9007199254740995')
    page.fill('[data-test=in-balance]', '34.56')
    page.fill('[data-test=in-note]', 'updated profile')
    if file_change == 'upload':
        page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    elif file_change == 'remove':
        page.check('[data-test=rm-avatar]')
    with page.expect_response(lambda response: response.url.endswith(endpoint) and response.request.method == 'PATCH') as write:
        page.click('[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]')
    assert write.value.status == (200 if accepted else 400), write.value.text()
    submitted = write.value.request
    if file_change == 'none':
        assert 'application/json' in submitted.headers['content-type']
        wire = submitted.post_data_json
        if accepted and expected is not None:
            assert isinstance(wire['rating'], (int, float))
            assert float(wire['rating']) == expected
        else:
            assert wire['rating'] == (expected if accepted else input_value)
        if input_value == '1e20':
            assert '"rating":100000000000000000000' in submitted.post_data
        assert wire['visits'] == '9007199254740995'
        assert wire['balance'] == '34.56'
    else:
        assert 'multipart/form-data' in submitted.headers['content-type']
    saved = api_request(page, 'GET', endpoint).json()
    if accepted:
        expect(page.locator('[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]')).to_have_count(0)
        if expected is None:
            assert saved['rating'] is None
        else:
            assert isinstance(saved['rating'], (int, float))
            assert float(saved['rating']) == expected
        assert saved['visits'] == '9007199254740995'
        assert saved['balance'] == '34.56'
        assert saved['note'] == 'updated profile'
        assert bool(saved['avatar']) == (file_change == 'upload')
    else:
        assert saved['rating'] == 1.25
        assert saved['visits'] == '9007199254740993'
        assert saved['balance'] == '12.34'
        assert saved['note'] == 'initial'
        assert bool(saved['avatar']) == (file_change == 'remove')


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('token,expected,error_bound', [
    pytest.param('100000000000000000000', 1e20, None, id='positive-integral-token'),
    pytest.param('-100000000000000000000', -1e20, None, id='negative-integral-token'),
    pytest.param('9223372036854775808', float(9223372036854775808), None, id='positive-i64-overflow'),
    pytest.param('-9223372036854775809', float(-9223372036854775809), None, id='negative-i64-overflow'),
    pytest.param('200000000000000000000', None, 'maximum', id='above-max'),
    pytest.param('-200000000000000000000', None, 'minimum', id='below-min'),
    pytest.param('1e999', None, None, id='exponent-overflow'),
    pytest.param('9' * 400, None, None, id='integral-overflow'),
    pytest.param('"100000000000000000000"', None, None, id='quoted-integral-string'),
    pytest.param('"1e20"', None, None, id='quoted-exponent-string'),
    pytest.param('NaN', None, None, id='nan-token'),
    pytest.param('Infinity', None, None, id='infinity-token'),
])
def test_raw_json_float_tokens_enforce_finite_bounds(page, kind, token, expected, error_bound):
    from conftest import csrf
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'rating', 'type': 'number', 'options': {'mode': 'float'}},
        {'name': 'bounded', 'type': 'number', 'options': {'mode': 'float', 'min': -1e20, 'max': 1e20}},
        {'name': 'visits', 'type': 'number', 'options': {'mode': 'int'}},
        {'name': 'balance', 'type': 'number', 'options': {'mode': 'fixed', 'scale': 2}},
    ])
    credentials = '"email":"raw@example.com","password":"safe password here",' if kind == 'auth' else ''
    # Pass the integral token verbatim: Python's json.dumps(1e20) would emit an
    # exponent and miss std.json's number_string branch for oversized integers.
    bounded = token if error_bound else '0'
    raw = '{' + credentials + '"rating":' + token + ',"bounded":' + bounded + ',"visits":"9007199254740993","balance":"12.34"}'
    headers = {'X-CSRF-Token': csrf(page), 'Content-Type': 'application/json'}
    response = page.request.post('/api/collections/profiles/records', headers=headers, data=raw)
    assert response.status == (201 if expected is not None else 400), response.text()
    records = api_request(page, 'GET', '/api/collections/profiles/records').json()
    if expected is None:
        assert records['totalItems'] == 0
        if error_bound:
            assert error_bound in response.json()['data']['bounded']['message']
        return
    assert records['totalItems'] == 1
    saved = records['items'][0]
    assert isinstance(saved['rating'], (int, float))
    assert float(saved['rating']) == expected
    assert saved['bounded'] == 0
    assert saved['visits'] == '9007199254740993'
    assert saved['balance'] == '12.34'
    endpoint = f'/api/collections/profiles/records/{saved["id"]}'
    response = page.request.patch(endpoint, headers=headers, data='{"bounded":200000000000000000000}')
    assert response.status == 400, response.text()
    assert 'maximum' in response.json()['data']['bounded']['message']
    saved = api_request(page, 'GET', endpoint).json()
    assert float(saved['rating']) == expected
    assert saved['bounded'] == 0
    assert saved['visits'] == '9007199254740993'
    assert saved['balance'] == '12.34'


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('file_change', ['none', 'upload', 'remove'])
def test_nullable_text_profile_fields_preserve_null_and_explicit_clear(page, kind, file_change):
    from conftest import csrf
    login(page)
    nullable = {'nickname': 'text', 'birthday': 'date', 'bio': 'editor', 'website': 'url', 'contact': 'email'}
    collection(page, 'profiles', kind, fields=[
        *({'name': name, 'type': field_type} for name, field_type in nullable.items()),
        {'name': 'note', 'type': 'text'},
        {'name': 'clearable', 'type': 'text'},
        {'name': 'clearableBio', 'type': 'editor'},
        {'name': 'draftBio', 'type': 'editor'},
        {'name': 'avatar', 'type': 'file'},
    ])
    body = {name: None for name in nullable}
    body.update(note='initial', clearable='erase me', clearableBio='<p>erase me</p>', draftBio=None)
    if kind == 'auth':
        body.update(email='nullable@example.com', password='safe password here')
    response = api_request(page, 'POST', '/api/collections/profiles/records', body)
    assert response.ok, response.text()
    record_id = response.json()['id']
    endpoint = f'/api/collections/profiles/records/{record_id}'
    if file_change == 'remove':
        response = page.request.patch(endpoint, headers={'X-CSRF-Token': csrf(page)}, multipart={
            'avatar': {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'}})
        assert response.ok, response.text()
    initial = api_request(page, 'GET', endpoint).json()
    assert all(initial[name] is None for name in nullable)
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    page.click('[data-test=user-row]' if kind == 'auth' else '[data-test=row]')
    page.get_by_label('bio', exact=True).focus()
    page.get_by_label('note', exact=True).focus()  # Blur alone must preserve SQL null.
    page.get_by_label('clearableBio', exact=True).fill('')
    page.get_by_label('draftBio', exact=True).fill('temporary draft')
    page.get_by_label('draftBio', exact=True).fill('')  # Typing then clearing is intentional.
    page.fill('[data-test=in-note]', 'updated profile')
    page.fill('[data-test=in-clearable]', '')
    if file_change == 'upload':
        page.set_input_files('[data-test=in-avatar]', {'name': 'avatar.txt', 'mimeType': 'text/plain', 'buffer': b'avatar'})
    elif file_change == 'remove':
        page.check('[data-test=rm-avatar]')
    page.click('[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]')
    expect(page.locator('[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]')).to_have_count(0)
    saved = api_request(page, 'GET', endpoint).json()
    assert all(saved[name] is None for name in nullable)
    assert saved['note'] == 'updated profile'
    assert saved['clearable'] == ''
    # Chromium can retain empty paragraph/line-break markup after user clearing.
    # Both deliberate clears must persist nonnull HTML with no remaining text.
    for name in ('clearableBio', 'draftBio'):
        assert saved[name] is not None
        assert re.sub(r'<[^>]*>', '', saved[name]) == ''
    assert bool(saved['avatar']) == (file_change == 'upload')


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('minimum,maximum,accepted', [
    pytest.param('-100000000000000000000', '100000000000000000000', True, id='integral-bounds'),
    pytest.param('-1e20', '1e20', True, id='exponent-bounds'),
    pytest.param('"-1e20"', '100000000000000000000', False, id='string-min'),
    pytest.param('-100000000000000000000', '"1e20"', False, id='string-max'),
    pytest.param('-1e999', '100000000000000000000', False, id='overflow-min'),
    pytest.param('-100000000000000000000', '9' * 400, False, id='overflow-max'),
    pytest.param('NaN', '100000000000000000000', False, id='nan-min'),
    pytest.param('-100000000000000000000', 'Infinity', False, id='infinite-max'),
])
def test_large_numeric_schema_bounds_api_roundtrip(page, kind, minimum, maximum, accepted):
    from conftest import csrf
    login(page)
    raw = ('{"name":"profiles","type":"' + kind + '","fields":['
           '{"id":"","name":"rating","type":"number","options":{"mode":"float","min":' +
           minimum + ',"max":' + maximum + '}}]}')
    response = page.request.post('/api/collections', headers={
        'X-CSRF-Token': csrf(page), 'Content-Type': 'application/json'}, data=raw)
    assert response.status == (201 if accepted else 400), response.text()
    definitions = api_request(page, 'GET', '/api/collections').json()['items']
    if not accepted:
        assert not any(c['name'] == 'profiles' for c in definitions)
        return
    saved = api_request(page, 'GET', '/api/collections/profiles').json()
    rating = next(f for f in saved['schema'] if f['name'] == 'rating')
    assert float(rating['options']['min']) == -1e20
    assert float(rating['options']['max']) == 1e20
    from_list = next(c for c in definitions if c['name'] == 'profiles')
    rating = next(f for f in from_list['schema'] if f['name'] == 'rating')
    assert float(rating['options']['min']) == -1e20
    assert float(rating['options']['max']) == 1e20


@pytest.mark.parametrize('kind', ['base', 'auth'])
@pytest.mark.parametrize('file_change', ['none', 'upload', 'remove'])
def test_prototype_named_fields_remain_own_values_in_forms(page, kind, file_change):
    login(page)
    collection(page, 'profiles', kind, fields=[
        {'name': 'constructor', 'type': 'text'},
        {'name': 'valueOf', 'type': 'number', 'options': {'mode': 'float'}},
        {'name': 'hasOwnProperty', 'type': 'text'},
        {'name': 'toString', 'type': 'file'},
    ])
    page.goto('/_/#/users/profiles' if kind == 'auth' else '/_/#/collections/profiles/records')
    page.click('[data-test=user-new]' if kind == 'auth' else '[data-test=new-record]')
    for name in ('constructor', 'valueOf', 'hasOwnProperty'):
        expect(page.locator(f'[data-test=in-{name}]')).to_have_value('')
        expect(page.locator(f'[data-test=err-{name}]')).to_have_count(0)
    expect(page.locator('[data-test=rm-toString]')).to_have_count(0)
    if kind == 'auth':
        page.fill('[data-test=user-email]', 'own-fields@example.com')
        page.fill('[data-test=user-password]', 'safe password here')
    if file_change != 'none':
        page.set_input_files('[data-test=in-toString]', {'name': 'first.txt', 'mimeType': 'text/plain', 'buffer': b'first'})
    save = '[data-test=user-save]' if kind == 'auth' else '[data-test=record-save]'
    drawer = '[data-test=user-drawer]' if kind == 'auth' else '[data-test=record-drawer]'
    row = '[data-test=user-row]' if kind == 'auth' else '[data-test=row]'
    page.click(save)
    expect(page.locator(drawer)).to_have_count(0)
    saved = api_request(page, 'GET', '/api/collections/profiles/records').json()['items'][0]
    assert all(saved[name] is None for name in ('constructor', 'valueOf', 'hasOwnProperty'))
    if file_change == 'remove':
        page.click(row)
        page.check('[data-test=rm-toString]')
        page.uncheck('[data-test=rm-toString]')
        page.check('[data-test=rm-toString]')
        page.click(save)
        expect(page.locator(drawer)).to_have_count(0)
        saved = api_request(page, 'GET', '/api/collections/profiles/records').json()['items'][0]
        assert all(saved[name] is None for name in ('constructor', 'valueOf', 'hasOwnProperty'))
        assert not saved['toString']
    page.click(row)
    page.fill('[data-test=in-constructor]', 'entered constructor')
    page.fill('[data-test=in-valueOf]', '1.5')
    page.fill('[data-test=in-hasOwnProperty]', 'entered own value')
    if file_change == 'upload':
        page.set_input_files('[data-test=in-toString]', {'name': 'replacement.txt', 'mimeType': 'text/plain', 'buffer': b'replacement'})
    page.click(save)
    expect(page.locator(drawer)).to_have_count(0)
    saved = api_request(page, 'GET', '/api/collections/profiles/records').json()['items'][0]
    assert saved['constructor'] == 'entered constructor'
    assert saved['valueOf'] == 1.5
    assert saved['hasOwnProperty'] == 'entered own value'
    assert bool(saved['toString']) == (file_change == 'upload')


@pytest.mark.parametrize('kind', ['base', 'auth'])
def test_backend_rejects_prototype_setter_field_name(page, kind):
    login(page)
    response = api_request(page, 'POST', '/api/collections', {
        'name': 'profiles', 'type': kind,
        'fields': [{'id': '', 'name': '__proto__', 'type': 'text', 'options': {}}]})
    assert response.status == 400, response.text()
    assert response.json()['data']['__proto__']['message']
    assert not any(c['name'] == 'profiles' for c in api_request(page, 'GET', '/api/collections').json()['items'])
