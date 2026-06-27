# Admin Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Settings / Feature Flags" admin-UI section to `src/admin/app.js` that lets superusers view, create, edit, and delete KV entries and toggle boolean feature flags, backed by the existing `/api/settings` REST endpoints.

**Architecture:** A single-file SPA edit — add a `SettingsView` component + `SettingDrawer`, extend the hash router and sidebar nav, add API client helpers, and carry `data-test` attributes throughout. No build step; rebuild binary after editing `app.js`.

**Tech Stack:** Preact via htm (CDN import, already in app.js), Zig 0.16.0 (binary rebuild), pytest + Playwright (browser tests).

## Global Constraints

- Zig 0.16.0: `mise exec zig@0.16.0 -- zig build` (rebuild after every app.js edit)
- No SPA build step — `src/admin/app.js` is `@embedFile`-d; edit it directly
- All new UI elements must have `data-test` attributes (Playwright requires them)
- Boolean flag detection: value === `"true"` or value === `"false"` (case-sensitive)
- Admin SPA uses `api(method, path, body)` where path is appended to `/api` internally
- Tests go in `tests/admin/test_settings.py`; follow `conftest.py` harness conventions
- Superuser credentials in tests: email=`admin@x.io` password=`adminpassword`
- Changelog fragments go in `changelog.d/`; never edit `CHANGELOG.md` directly
- Docs mirror: every `docs/*.md` change must be reflected in `site/src/content/docs/*.md`
- All absolute paths in commands

---

### Task 1: Extend app.js — API helpers + router + sidebar nav + SettingsView + SettingDrawer

**Files:**
- Modify: `/home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca/src/admin/app.js`

**Interfaces:**
- Produces: `SettingsView` component, `SettingDrawer` component, `#/settings` route,
  `nav-settings` sidebar link, `API.settings.*` helpers
- Consumes: existing `api()` helper, `html`, `useState`, `useEffect` from app.js

- [ ] **Step 1: Add settings API helpers to the `API` object**

  Locate the `API = { ... }` literal (lines 20-29 in the current file) and add three
  methods. The existing `api()` helper prepends `/api`, so the path here starts with
  `/settings`:

  In the `API` object after the `refresh` line, add:
  ```javascript
  settingsList: () => api('GET', '/settings'),
  settingsPut: (key, value) => api('PUT', `/settings/${encodeURIComponent(key)}`, { value }),
  settingsDelete: (key) => api('DELETE', `/settings/${encodeURIComponent(key)}`),
  ```

- [ ] **Step 2: Add `#/settings` to `parseRoute`**

  In `parseRoute` (lines 41-48), add a settings branch before the collections branches:
  ```javascript
  if (seg[0] === 'settings') return { name: 'settings' };
  ```
  Insert it after the `login` check and before the `collections` checks.

- [ ] **Step 3: Add "Settings" nav link to Shell sidebar**

  In the `Shell` component's sidebar section (around line 105, near the existing
  `nav-collections` anchor), add a settings nav link. The `route` object is available
  in `Shell` scope. Insert before the `nav-collections` anchor so Settings appears
  above Collections in the bottom nav:

  ```javascript
  <a class=${'navitem hide-collapsed' + (route.name === 'settings' ? ' active' : '')} href="#/settings" data-test="nav-settings">⚙ Settings</a>
  ```

- [ ] **Step 4: Add `SettingsView` to Shell's main content dispatch**

  In the Shell main area (around line 109), add settings to the conditional chain:
  ```javascript
  ${route.name === 'settings' ? html`<${SettingsView}/>`
    : route.name === 'records' ? html`<${RecordsTable} col=${route.col}/>`
    : route.name === 'schema' ? html`<${SchemaEditor} name=${route.col}/>`
    : html`<div data-test="collections-home"><h2>Collections</h2><button data-test="new-collection" onClick=${() => go('#/collections/__new__')}>+ New collection</button></div>`}
  ```

- [ ] **Step 5: Add the `SettingsView` component**

  Add this component after the `RelationPicker` component (after line 449, before the
  `render(...)` call at the bottom of the file). It manages the list of KV entries and
  opens the drawer for create/edit:

  ```javascript
  function isFlag(value) { return value === 'true' || value === 'false'; }

  function SettingsView() {
    const [entries, setEntries] = useState(null);
    const [err, setErr] = useState('');
    const [editing, setEditing] = useState(undefined); // undefined=closed, {}=new, entry=edit

    function load() {
      setErr('');
      API.settingsList().then(setEntries).catch(x => setErr((x.data && x.data.message) || 'Failed to load settings'));
    }
    useEffect(load, []);

    async function toggle(key, cur) {
      try { await API.settingsPut(key, cur === 'true' ? 'false' : 'true'); load(); }
      catch (x) { setErr((x.data && x.data.message) || 'Failed to update'); }
    }
    async function del(key) {
      if (!confirm('Delete setting ' + key + '?')) return;
      try { await API.settingsDelete(key); load(); }
      catch (x) { setErr((x.data && x.data.message) || 'Failed to delete'); }
    }

    return html`
      <div data-test="settings-view">
        <div class="toolbar">
          <h2 style="margin:0">Settings / Feature Flags</h2>
          <div class="grow"></div>
          <button data-test="new-setting" onClick=${() => setEditing({})}>+ New setting</button>
        </div>
        ${err && html`<div class="error" data-test="settings-error">${err}</div>`}
        <table>
          <thead><tr><th>Key</th><th>Value</th><th></th></tr></thead>
          <tbody data-test="settings-rows">
            ${(entries || []).map(e => html`<tr key=${e.key} data-test="setting-row">
              <td><code data-test="setting-key">${e.key}</code></td>
              <td data-test="setting-value">${isFlag(e.value)
                ? html`<label><input type="checkbox" style="width:auto" data-test=${'flag-' + e.key} checked=${e.value === 'true'} onChange=${() => toggle(e.key, e.value)}/> ${e.value}</label>`
                : e.value}</td>
              <td>
                <button class="ghost" data-test="edit-setting" onClick=${() => setEditing(e)}>Edit</button>
                <button class="ghost" data-test="del-setting" onClick=${() => del(e.key)}>✕</button>
              </td>
            </tr>`)}
          </tbody>
        </table>
        ${entries && entries.length === 0 && html`<p class="muted" data-test="settings-empty">No settings yet.</p>`}
        ${editing !== undefined && html`<${SettingDrawer} entry=${editing} onClose=${() => setEditing(undefined)} onSaved=${() => { setEditing(undefined); load(); }}/>`}
      </div>`;
  }
  ```

- [ ] **Step 6: Add the `SettingDrawer` component**

  Add immediately after `SettingsView`. Reuses the same drawer style as `RecordDrawer`.
  When `entry` has no `created` field it is a new entry (empty `{}`); otherwise it's
  an existing entry being edited (key is disabled because the KV API has no rename
  endpoint — rename = delete + re-create):

  ```javascript
  function SettingDrawer({ entry, onClose, onSaved }) {
    const isNew = !entry.created;
    const [key, setKey] = useState(entry.key || '');
    const [value, setValue] = useState(entry.value || '');
    const [err, setErr] = useState('');
    async function save() {
      setErr('');
      if (!key.trim()) { setErr('Key is required.'); return; }
      try { await API.settingsPut(key.trim(), value); onSaved(); }
      catch (x) { setErr((x.data && x.data.message) || 'Save failed'); }
    }
    return html`
      <div class="drawer" data-test="setting-drawer" style="position:fixed;top:0;right:0;bottom:0;width:380px;background:var(--panel);border-left:1px solid var(--line);padding:16px;overflow:auto;box-shadow:-8px 0 30px rgba(0,0,0,.4)">
        <div class="row"><b style="flex:1">${isNew ? 'New setting' : 'Edit ' + entry.key}</b><button class="ghost" data-test="drawer-close" onClick=${onClose}>✕</button></div>
        ${err && html`<div class="error" data-test="setting-error">${err}</div>`}
        <div class="field"><label>Key</label><input data-test="setting-key-input" value=${key} onInput=${e => setKey(e.target.value)} disabled=${!isNew}/></div>
        <div class="field"><label>Value</label><input data-test="setting-value-input" value=${value} onInput=${e => setValue(e.target.value)}/></div>
        <div class="row" style="margin-top:14px"><button data-test="setting-save" onClick=${save}>Save</button></div>
      </div>`;
  }
  ```

- [ ] **Step 7: Build the binary to verify no syntax errors**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && mise exec zig@0.16.0 -- zig build 2>&1 | tail -20
  ```
  Expected: build succeeds (exit 0). If it fails, the JS is embedded verbatim so any
  error is in Zig source, not the JS — check the Zig compilation output.

- [ ] **Step 8: Commit**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && git add src/admin/app.js && git commit -m "feat(admin): add Settings / Feature Flags UI section (#101)"
  ```

---

### Task 2: Playwright test for the Settings UI

**Files:**
- Create: `/home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca/tests/admin/test_settings.py`

**Interfaces:**
- Consumes: `conftest.login`, `conftest.api_request`, `conftest.csrf` helpers;
  `page` + `server` fixtures from conftest.py

- [ ] **Step 1: Write the test file**

  ```python
  """
  Admin UI tests for the Settings / Feature Flags section (issue #101).

  Covers: navigation, KV create/edit/list, boolean flag toggle, delete.
  """
  import json
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
  ```

- [ ] **Step 2: Run just the new test file to verify it passes**

  The binary must already be built (from Task 1 Step 7). Run:
  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && mise exec python@3.13 -- python -m pytest tests/admin/test_settings.py -v 2>&1 | tail -40
  ```
  Expected: all tests PASSED. If a test fails, diagnose the failure — common causes:
  - `data-test` attribute typo in app.js vs test selector
  - Async timing: if the table re-render after a flag toggle races, use `wait_for_function`
    (already done above) or `wait_for_selector` on a specific row element
  - API returns 403: the binary wasn't rebuilt after app.js changes (the superuser cookie
    flow is fine; 403 on settings API would indicate the superuser token isn't sent, but
    in the browser context it uses cookie auth which is set up by `login()`)

- [ ] **Step 3: Commit**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && git add tests/admin/test_settings.py && git commit -m "test(admin): Playwright tests for Settings UI (#101)"
  ```

---

### Task 3: Run the full browser test suite

**Files:** (none changed — verification step)

- [ ] **Step 1: Run all admin tests**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && mise exec python@3.13 -- python -m pytest tests/admin/ -q 2>&1 | tail -30
  ```
  Expected: all existing tests still pass; new settings tests pass.
  If a pre-existing test fails, investigate whether the app.js change broke it (router,
  nav, or Shell rendering).

- [ ] **Step 2: Run Zig unit tests**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Summary|passed|failed|error"
  ```
  Expected: `Build Summary: N/N tests passed`. The spurious `failed command: ...` line
  on success is known noise — trust the Summary line only.

---

### Task 4: Docs + changelog fragment

**Files:**
- Modify: `/home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca/docs/framework.md`
- Modify: `/home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca/site/src/content/docs/framework.md`
- Create: `/home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca/changelog.d/admin-settings-ui.md`

- [ ] **Step 1: Add admin-UI note to docs/framework.md**

  Find the "Superuser settings HTTP API" section (search for `### Superuser settings HTTP API`).
  After the API table, append one sentence:

  ```
  The embedded admin UI also exposes these endpoints as a "Settings / Feature Flags"
  section where superusers can view, create, edit, delete entries, and toggle boolean
  flags with a checkbox — no API client required.
  ```

- [ ] **Step 2: Mirror the same change to site/src/content/docs/framework.md**

  Apply the identical one-sentence addition in the same location in the site mirror.

- [ ] **Step 3: Write the changelog fragment**

  Create `changelog.d/admin-settings-ui.md`:
  ```markdown
  ### Features
  - Admin UI now includes a "Settings / Feature Flags" section (`#/settings`) where
    superusers can list, create, edit, and delete KV entries, and toggle boolean feature
    flags with a checkbox — backed by the existing `/api/settings` REST surface.
  ```

- [ ] **Step 4: Commit**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && git add docs/framework.md site/src/content/docs/framework.md changelog.d/admin-settings-ui.md && git commit -m "docs: note Settings UI in framework.md; add changelog fragment (#101)"
  ```

---

### Task 5: Push and open PR

**Files:** (no file changes — git/GitHub operations)

- [ ] **Step 1: Verify branch is clean and ahead of origin**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && git log --oneline -5 && git status
  ```

- [ ] **Step 2: Push to remote**

  ```bash
  cd /home/valthon/nothlav/zigbase/.claude/worktrees/agent-a87cd9a01e5d94fca && git push origin HEAD:feat/admin-settings-ui
  ```

- [ ] **Step 3: Create PR**

  ```bash
  gh pr create --base main --head feat/admin-settings-ui \
    --title "feat(admin): Settings / Feature Flags UI section (closes #101)" \
    --body "$(cat <<'EOF'
  ## Summary
  - Adds a **Settings / Feature Flags** section (`#/settings`) to the embedded admin SPA
  - Superusers can list, create, edit, and delete KV entries, and toggle boolean flags
    with a checkbox, all backed by the existing `/api/settings` REST endpoints
  - All new UI elements carry `data-test` attributes for Playwright coverage

  ## Changes
  - `src/admin/app.js` — new `SettingsView` + `SettingDrawer` components, extended router
    and sidebar nav, `API.settingsList/Put/Delete` helpers
  - `tests/admin/test_settings.py` — 6 Playwright tests (nav, empty state, create, toggle
    flag on/off, edit, delete)
  - `docs/framework.md` + `site/src/content/docs/framework.md` — admin UI note
  - `changelog.d/admin-settings-ui.md` — Features changelog fragment

  ## Test plan
  - [ ] `mise exec zig@0.16.0 -- zig build test --summary all` — unit tests green
  - [ ] `mise exec python@3.13 -- python -m pytest tests/admin/ -q` — full browser suite green
  - [ ] Navigate `/_/#/settings`, create a setting, toggle a flag, delete a setting manually

  Closes #101

  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  EOF
  )"
  ```

- [ ] **Step 4: If `gh pr create` errors on `--head`**, omit it (gh infers the head from
  the current branch of the worktree):

  ```bash
  gh pr create --base main \
    --title "feat(admin): Settings / Feature Flags UI section (closes #101)" \
    --body "$(cat <<'EOF'
  ## Summary
  - Adds a **Settings / Feature Flags** section (`#/settings`) to the embedded admin SPA
  - Superusers can list, create, edit, and delete KV entries, and toggle boolean flags
    with a checkbox, all backed by the existing `/api/settings` REST endpoints
  - All new UI elements carry `data-test` attributes for Playwright coverage

  ## Changes
  - `src/admin/app.js` — new `SettingsView` + `SettingDrawer` components, extended router
    and sidebar nav, `API.settingsList/Put/Delete` helpers
  - `tests/admin/test_settings.py` — 6 Playwright tests (nav, empty state, create, toggle
    flag on/off, edit, delete)
  - `docs/framework.md` + `site/src/content/docs/framework.md` — admin UI note
  - `changelog.d/admin-settings-ui.md` — Features changelog fragment

  ## Test plan
  - [ ] `mise exec zig@0.16.0 -- zig build test --summary all` — unit tests green
  - [ ] `mise exec python@3.13 -- python -m pytest tests/admin/ -q` — full browser suite green
  - [ ] Navigate `/_/#/settings`, create a setting, toggle a flag, delete a setting manually

  Closes #101

  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  EOF
  )"
  ```

---

## Self-Review

### Spec coverage
- [x] View/list KV entries — `SettingsView` table with `settings-rows`
- [x] Create new entry — "+ New setting" button + `SettingDrawer`
- [x] Edit existing entry — "Edit" per row + `SettingDrawer` with key disabled
- [x] Delete entry — "✕" per row with `confirm()`
- [x] Boolean flag toggle — `isFlag()` + inline checkbox in value cell
- [x] `data-test` hooks — all elements documented and wired
- [x] Playwright test — 6 tests covering all scenarios
- [x] Docs mirror (framework.md + site/) — Task 4
- [x] Changelog fragment — Task 4
- [x] Superuser-gated — API already enforces 403; no extra UI auth needed

### Placeholder scan
No TBDs, no "implement later", no "similar to Task N" — all code shown in full.

### Type consistency
- `API.settingsPut(key, value)` used in both `SettingsView.toggle`, `SettingsView.del`
  redirect, and `SettingDrawer.save` — consistent
- `API.settingsDelete(key)` in `SettingsView.del` — consistent
- `isFlag(value)` called in `SettingsView` map — consistent
- `entry.created` used to determine `isNew` in `SettingDrawer` — entries from the list
  API include `created`; new entries use `{}` (no `created`) — consistent
