# Admin Settings UI Design Spec (Issue #101)

## Goal

Add a "Settings" section to the embedded admin SPA (`src/admin/app.js`) so superusers can
view, create, edit, and delete KV entries, and toggle feature flags, via the UI — hitting
the existing `/api/settings` REST endpoints (GET/PUT/DELETE) added in Theme B3.

## Background

Theme B3 (#87/#88) shipped:
- `_kv` SQLite table — opaque key→TEXT store
- `ctx.kv()` / `ctx.flag()` framework APIs
- Superuser-only REST surface: `GET /api/settings`, `GET /api/settings/:key`,
  `PUT /api/settings/:key` (`{"value":"..."}`), `DELETE /api/settings/:key` (204)
- No admin UI

The data model is flat: `{ key, value, created, updated }`. There is no explicit
`is_flag` field — flags are KV entries whose value is exactly `"true"` or `"false"`.
(`ctx.flag` treats `"true"` and `"1"` as truthy, but the UI uses the boolean
convention to surface the toggle control.)

## UX Design

### Navigation

Add a "Settings" nav item to the Shell sidebar, below the existing Collections section
and above the spacer/logout:

```
⚙ Settings      → #/settings
⚙ Collections   (existing)
⎋ Logout        (existing)
```

### Settings view (`#/settings`)

A full-width view with:

1. **Toolbar** — "Settings / Feature Flags" heading + "+ New setting" button
2. **Table** of all KV entries, sorted by key (the API returns them in key order):
   - Key column (monospace)
   - Value column: if value is exactly `"true"` or `"false"`, render a **checkbox toggle**
     that calls `PUT /api/settings/:key` with the inverted value on click; otherwise
     render raw text
   - Actions column: "Edit" (opens drawer) + "✕" (delete with confirm)
3. **Empty state** paragraph when no entries exist

### Setting drawer (right-side panel, 380px)

Mirrors the RecordDrawer pattern. Used for both create and edit.

- **Key field**: text input, **disabled when editing** (key is immutable — must delete and
  recreate to rename)
- **Value field**: text input (raw string; boolean flags are edited as text "true"/"false"
  or via the inline toggle)
- **Save** button: calls `PUT /api/settings/:key` with `{"value":"..."}`
- Shows error text on failure

### `data-test` hooks (required for Playwright)

| Attribute | Element |
|---|---|
| `nav-settings` | Sidebar nav anchor |
| `settings-view` | Top-level container div |
| `new-setting` | "New setting" button |
| `settings-error` | Error message div |
| `settings-rows` | `<tbody>` |
| `setting-row` | Each `<tr>` |
| `setting-key` | Key `<td>` |
| `setting-value` | Value `<td>` |
| `flag-{key}` | Checkbox input for boolean entries |
| `edit-setting` | Edit button per row |
| `del-setting` | Delete button per row |
| `settings-empty` | Empty state `<p>` |
| `setting-drawer` | Drawer container |
| `setting-key-input` | Key `<input>` in drawer |
| `setting-value-input` | Value `<input>` in drawer |
| `setting-save` | Save button in drawer |
| `setting-error` | Error in drawer |

## Files Changed

- **`src/admin/app.js`** — only file to edit; no build step
- **`tests/admin/test_settings.py`** — new Playwright test file
- **`changelog.d/admin-settings-ui.md`** — fragment for changelog
- **`docs/framework.md`** + **`site/src/content/docs/framework.md`** — note admin UI
  manages settings (one line in the "Superuser settings HTTP API" section)

## Constraints

- Zig 0.16.0 via `mise exec zig@0.16.0 --`; rebuild binary after editing app.js
- No build step for the SPA — edit app.js directly, rebuild binary
- All new UI elements must carry `data-test` hooks
- Feature-flag value detection: exactly `"true"` or `"false"` (case-sensitive)
- Superuser-only: the API already enforces 403; the UI is inside the existing authed shell
- The `api()` helper in app.js is `fetch('/api' + path, ...)` — pass `/settings/...` paths
