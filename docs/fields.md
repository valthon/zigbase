# Field types & options reference

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/fields> — the site is the canonical reading experience.

This is the complete catalog of ZigBase field types and their `options` shapes. It
is the companion reference to the [API docs](api.md) (which describe the request/
response envelopes) and the [recipes](recipes.md) (which show provisioning in
practice). Every type name, option key, default, and validation rule below matches
`src/schema.zig`.

## How fields appear in requests vs. responses

When you **create or update** a collection (`POST`/`PATCH /api/collections`), you
supply the field list under the key **`fields`**. When the server **returns** a
collection, the same list is exposed under the key **`schema`** (see
[api.md → Input vs. output shape](api.md#input-vs-output-shape)). The per-field
object is identical in both directions:

```jsonc
{
  "id": "f_title",        // your stable field id (any non-empty string; you choose it)
  "name": "title",        // the column name — see naming rules below
  "type": "text",         // one of the 12 types below
  "required": false,      // optional, default false
  "unique": false,        // optional, default false
  "options": { }          // type-specific; see each type
}
```

`required` and `unique` are common to every type and both default to `false`.
The `options` object is type-specific; unknown/omitted option keys fall back to the
defaults listed for each type. A field whose `options` you don't care about can pass
`"options": {}` (all defaults).

### Field-name rules (apply to every type)

A field `name` must:

- be a **valid identifier** — start with a letter, then letters/digits/underscores
  only (`^[A-Za-z][A-Za-z0-9_]*$`);
- not collide (case-insensitively) with another field in the same collection;
- not be a **reserved system name**. The reserved set is: `id`, `created`,
  `updated`, `email`, `username`, `passwordHash`, `tokenKey`, `verified`. These are
  injected/managed by the engine. (On an `auth` collection, `email`, `username`,
  `passwordHash`, `tokenKey`, and `verified` are added for you automatically — see
  [auth collections](#auth-collections-and-system-fields).)

A field that violates any of these produces a `400` with a `validation_*` field
error (`validation_invalid_name`, `validation_duplicate_name`,
`validation_reserved_name`).

---

## The 12 field types

| `type` | Stored as (SQLite) | `options` keys |
| --- | --- | --- |
| `text` | TEXT | `min`, `max`, `pattern` |
| `email` | TEXT | *(none)* |
| `url` | TEXT | *(none)* |
| `editor` | TEXT | *(none)* |
| `date` | TEXT | `min`, `max` |
| `autodate` | TEXT | `onCreate`, `onUpdate` |
| `bool` | INTEGER | *(none)* |
| `number` | REAL (float) / INTEGER (int, fixed) | `mode`, `scale`, `min`, `max` |
| `json` | TEXT | `maxSize` |
| `select` | TEXT | `values`, `maxSelect` |
| `relation` | TEXT | `targetCollectionId`, `cascadeDelete`, `minSelect`, `maxSelect` |
| `file` | TEXT | `maxSelect`, `maxSize`, `mimeTypes` |

> Note the type tag is spelled **`bool`** in JSON (the Zig enum is `@"bool"`).

---

### `text`

A string column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `min` | integer (≥0) | unset | minimum length, counted in **unicode codepoints** |
| `max` | integer (≥0) | unset | maximum length, counted in **unicode codepoints** |
| `pattern` | string | unset | a regex the value must match — **accepted but not yet enforced** (see KNOWN_LIMITATIONS.md) |

`min`/`max` violations are a `400` with a `validation_min` / `validation_max`
field error. An explicitly empty value (`""`) on an optional field skips the
`min` check so the field stays clearable; use `required` to forbid empty.

```json
{ "name": "title", "type": "text", "required": true, "options": { "min": 1, "max": 200 } }
```

### `email`

A string column intended to hold an email address. **No options.**

```json
{ "name": "contact", "type": "email", "options": {} }
```

### `url`

A string column intended to hold a URL. **No options.**

```json
{ "name": "homepage", "type": "url", "options": {} }
```

### `editor`

A rich-text / HTML string column. **No options.** (Stored as TEXT; the type is a
hint to clients/admin UI.)

```json
{ "name": "body", "type": "editor", "options": {} }
```

### `date`

A date/time string column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `min` | string | unset | earliest allowed value (a date string) — **accepted but not yet enforced** |
| `max` | string | unset | latest allowed value (a date string) — **accepted but not yet enforced** |

`min`/`max` are stored and round-tripped, but record validation does not apply
them yet: enforcement needs date parsing/normalization, which the write path
doesn't have (see KNOWN_LIMITATIONS.md).

```json
{ "name": "starts_at", "type": "date", "options": { "min": "2026-01-01 00:00:00" } }
```

### `autodate`

A server-managed timestamp column, written automatically by the engine on create
and/or update.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `onCreate` | bool | `true` | stamp the current time when the record is created |
| `onUpdate` | bool | `false` | re-stamp on every update |

```json
{ "name": "published_at", "type": "autodate", "options": { "onCreate": true, "onUpdate": false } }
```

> The base `created` and `updated` columns already exist on every record; use
> `autodate` for *additional* managed timestamps.

### `bool`

A boolean column (stored as INTEGER 0/1). **No options.** Spell the type `"bool"`.

```json
{ "name": "is_active", "type": "bool", "options": {} }
```

### `number`

A numeric column. **The `mode` decides storage and precision.**

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `mode` | `"float"` \| `"int"` \| `"fixed"` | `"float"` | numeric kind (see below) |
| `scale` | integer **1..8** | unset | decimal places — **required when `mode` is `"fixed"`** |
| `min` | number | unset | minimum value, inclusive (`validation_min` on violation) |
| `max` | number | unset | maximum value, inclusive (`validation_max` on violation) |

- **`float`** — stored as SQLite `REAL` (IEEE-754 double). The default.
- **`int`** — stored as `INTEGER` (whole numbers).
- **`fixed`** — fixed-point decimal stored as `INTEGER` (scaled by `10^scale`).
  **`scale` is mandatory and must be 1..8.** Use this for money and other values
  where binary-float rounding is unacceptable.

> **Validation gotcha:** `mode: "fixed"` **without** a valid `scale` (1..8) is a
> `400` (`validation_invalid_scale`: "fixed number requires scale 1..8."). A `float`
> or `int` field never needs `scale`.

```json
// money: two decimal places, fixed-point
{ "name": "price_per_hour", "type": "number", "options": { "mode": "fixed", "scale": 2, "min": 0 } }
```
```json
// a plain integer count
{ "name": "seats", "type": "number", "options": { "mode": "int", "min": 1, "max": 8 } }
```

### `json`

An arbitrary JSON value, stored as TEXT.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `maxSize` | integer (bytes) | unset | maximum serialized size |

```json
{ "name": "metadata", "type": "json", "options": { "maxSize": 4096 } }
```

### `select`

A single- or multi-value enumerated column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `values` | array of strings | **required, non-empty** | the allowed values |
| `maxSelect` | integer | `1` | how many values may be chosen at once |

- `maxSelect: 1` → single-valued (the record stores one of `values`).
- `maxSelect > 1` → multi-valued (the field becomes a multi-value column).

> **Validation gotcha:** an empty `values` array is a `400` (`validation_required`:
> "select requires at least one value.").

```json
{ "name": "status", "type": "select", "options": { "values": ["pending", "confirmed", "cancelled"], "maxSelect": 1 } }
```

### `relation`

A foreign-key reference to records in another collection.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `targetCollectionId` | string | **required** | **the target collection's `id`** (see gotcha) |
| `cascadeDelete` | bool | `false` | delete this record when its referenced record is deleted |
| `minSelect` | integer | unset | minimum number of references |
| `maxSelect` | integer | `1` | maximum number of references (1 = single relation) |

- `maxSelect: 1` → a single relation (one referenced id).
- `maxSelect > 1` → a multi-relation.

> ### CRITICAL: `targetCollectionId` is an **id**, not a name
>
> `targetCollectionId` must be the **id** that the target collection's create
> response returned — **not** the collection's `name`. ZigBase assigns the id when
> you create the collection; it is in the `"id"` field of the
> `POST /api/collections` response:
>
> ```jsonc
> // response from creating the "simulators" collection
> { "id": "a1b2c3d4e5f6g7h", "name": "simulators", "schema": [ ... ] }
> //        ^^^^^^^^^^^^^^^ THIS is what a relation's targetCollectionId must hold
> ```
>
> So provisioning is **order-dependent**: create the target collection first,
> **capture its `id` from the response**, then create the referencing collection
> with `targetCollectionId` set to that captured id. The
> [provisioning recipe](recipes.md#recipe-provisioning-your-schema) shows the exact
> create-then-capture-id `curl` sequence. A relation with an empty
> `targetCollectionId` is a `400` (`validation_required`: "relation requires
> targetCollectionId.").

```json
// "listing" belongs to one "simulator"; cascade-delete the listing if the simulator is removed
{ "name": "simulator", "type": "relation", "required": true,
  "options": { "targetCollectionId": "a1b2c3d4e5f6g7h", "cascadeDelete": true, "maxSelect": 1 } }
```

### `file`

An uploaded-file reference. Files themselves are uploaded as `multipart/form-data`
on record create/update and served from `GET /api/files/:col/:rec/:name` (see
[api.md → Files](api.md#files)).

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `maxSelect` | integer | `1` | maximum number of files (1 = single file) |
| `maxSize` | integer (bytes) | unset | maximum per-file size |
| `mimeTypes` | array of strings | unset | allowed MIME types; others are rejected |

- `maxSelect: 1` → single file; `maxSelect > 1` → multiple files.
- An upload exceeding `maxSize` → `413`; a disallowed `mimeTypes` value → `400`
  ("File type not allowed."); too many files for `maxSelect` → `400`.

```json
{ "name": "photos", "type": "file",
  "options": { "maxSelect": 6, "maxSize": 5242880, "mimeTypes": ["image/png", "image/jpeg", "image/webp"] } }
```

---

## Auth collections and system fields

A collection created with `"type": "auth"` automatically gains these system fields
(you do **not** declare them, and you may **not** reuse their names):

| Field | Type | Notes |
| --- | --- | --- |
| `email` | email | identity; uniqueness enforced via a partial unique index |
| `username` | text | |
| `passwordHash` | text | **hidden** — never serialized in API output |
| `tokenKey` | text | **hidden** — never serialized; rotated on password change |
| `verified` | bool | forced to `false` on create; flipped via email-verification |

Auth collections also carry an `options.auth` block:

```jsonc
"options": {
  "auth": {
    "identityFields": ["email"],   // which fields auth-with-password matches against
    "minPasswordLength": 8,        // default 8
    "oauth2": { "enabled": false, "providers": [] }
  }
}
```

`identityFields` defaults to `["email"]`; each entry must be a valid identifier
(it is interpolated into SQL). `minPasswordLength` defaults to `8`. See the
[signup recipe](recipes.md#recipe-user-registration-signup) for how record-create
acts as the signup path on an auth collection.

---

## A complete multi-field `POST /api/collections` body

A `listings` base collection that exercises `text`, fixed-point `number`,
`select`, `relation`, and `file`. (`owner` references a `users` auth collection and
`simulator` references a `simulators` collection — substitute the **ids** those
collections' create responses returned for the two `targetCollectionId` values.)

```jsonc
{
  "name": "listings",
  "type": "base",
  "fields": [
    { "id": "f_title", "name": "title", "type": "text", "required": true,
      "options": { "min": 1, "max": 140 } },

    { "id": "f_desc", "name": "description", "type": "editor",
      "options": {} },

    { "id": "f_price", "name": "price_per_hour", "type": "number", "required": true,
      "options": { "mode": "fixed", "scale": 2, "min": 0 } },

    { "id": "f_status", "name": "status", "type": "select", "required": true,
      "options": { "values": ["draft", "published", "archived"], "maxSelect": 1 } },

    { "id": "f_owner", "name": "owner", "type": "relation", "required": true,
      "options": { "targetCollectionId": "REPLACE_WITH_users_id", "cascadeDelete": true, "maxSelect": 1 } },

    { "id": "f_sim", "name": "simulator", "type": "relation", "required": true,
      "options": { "targetCollectionId": "REPLACE_WITH_simulators_id", "cascadeDelete": true, "maxSelect": 1 } },

    { "id": "f_photos", "name": "photos", "type": "file",
      "options": { "maxSelect": 6, "maxSize": 5242880, "mimeTypes": ["image/png", "image/jpeg", "image/webp"] } }
  ],
  "listRule": "",
  "viewRule": "",
  "createRule": "@request.auth.id != \"\"",
  "updateRule": "@request.auth.id = owner",
  "deleteRule": "@request.auth.id = owner"
}
```

The five rule keys (`listRule`/`viewRule`/`createRule`/`updateRule`/`deleteRule`)
are described in [api.md → Access rules](api.md#access-rules); owner-scoped and
relation-traversal rule patterns are in
[recipes.md → Owner-scoped access rules](recipes.md#recipe-owner-scoped-access-rules).

---

See also: [recipes.md](recipes.md) · [tutorial.md](tutorial.md) ·
[api.md](api.md) · [framework.md](framework.md)
</content>
</invoke>
