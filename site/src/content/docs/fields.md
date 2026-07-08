---
title: Fields
description: The complete catalog of ZigBase field types and their options — text, email, url, editor, date, autodate, bool, number, json, select, relation, and file.
order: 2
group: reference
---

# Field types & options

This is the complete catalog of ZigBase field types and their `options` shapes. It is the
companion reference to the [API docs](./api) (which describe the request/response
envelopes) and the [recipes](./recipes) (which show provisioning in practice). Every type
name, option key, default, and validation rule below matches `src/schema.zig`.

## How fields appear in requests vs. responses

When you **create or update** a collection (`POST`/`PATCH /api/collections`), you supply the
field list under the key **`fields`**. When the server **returns** a collection, the same
list is exposed under the key **`schema`** (see
[API → Input vs. output shape](./api#input-vs-output-shape)). The per-field object is
identical in both directions:

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

`required` and `unique` are common to every type and both default to `false`. A third
common boolean, `encrypted` (default `false`), stores the value encrypted at rest and is
valid only on `text`/`editor`/`json` fields — see
[Encryption at rest](#encryption-at-rest-encrypted). A fourth, `searchable` (default
`false`), mirrors a `text`/`editor` field's text into the collection's full-text index (SQLite
FTS5, or a Postgres `tsvector`) so it can be matched via the `?search=` list param — see [Search](api.md#search); it is
mutually exclusive with `encrypted` (ciphertext is not searchable). The `options`
object is type-specific; unknown/omitted option keys fall back to the defaults listed for
each type. A field whose `options` you don't care about can pass `"options": {}` (all
defaults).

### Field-name rules (apply to every type)

A field `name` must:

- be a **valid identifier** — start with a letter, then letters/digits/underscores only
  (`^[A-Za-z][A-Za-z0-9_]*$`);
- not collide (case-insensitively) with another field in the same collection;
- not be a **reserved system name**. The reserved set is: `id`, `created`, `updated`,
  `email`, `username`, `passwordHash`, `tokenKey`, `verified`. These are injected/managed by
  the engine. (On an `auth` collection, `email`, `username`, `passwordHash`, `tokenKey`, and
  `verified` are added for you automatically — see
  [auth collections](#auth-collections-and-system-fields).)

A field that violates any of these produces a `400` with a `validation_*` field error
(`validation_invalid_name`, `validation_duplicate_name`, `validation_reserved_name`).

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

### text

A string column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `min` | integer (≥0) | unset | minimum length, counted in **unicode codepoints** |
| `max` | integer (≥0) | unset | maximum length, counted in **unicode codepoints** |
| `pattern` | string | unset | a regular expression the value must match (see below) |

`min`/`max` violations are a `400` with a `validation_min` / `validation_max` field
error. An explicitly empty value (`""`) on an optional field skips the `min` check so the
field stays clearable; use `required` to forbid empty.

**`pattern` is enforced on every record write** via a pure-Zig, linear-time Thompson-NFA
matcher — no catastrophic backtracking is possible regardless of input. Matching is
**unanchored (substring)**: the pattern must be found anywhere in the value. To require a
full-string match, anchor with `^…$`. A violation returns `400` with a
`validation_pattern` field error.

Supported syntax:

- **Literals** — any UTF-8 character matches itself.
- **`.`** — matches any Unicode codepoint **except `\n`**.
- **Anchors** — `^` (start of string) and `$` (end of string).
- **Character classes** — `[abc]`, negated `[^abc]`, ranges `[a-z]`.
- **Predefined classes** — `\d` / `\D` (digit), `\w` / `\W` (word char), `\s` / `\S`
  (whitespace) — ASCII semantics only.
- **Escape sequences** — `\t`, `\n`, `\r`, `\f`, `\v`, and `\`-escaped metacharacters.
- **Alternation** — `a|b`.
- **Groups** — `(…)` and non-capturing `(?:…)`.
- **Quantifiers** — `*` (0+), `+` (1+), `?` (0–1), `{m}`, `{m,}`, `{m,n}`.

Not supported: captures/backreferences, lazy quantifiers, `\b`, `\p{}`, or a
case-insensitive flag.

Patterns are validated when a collection is saved — a syntactically invalid pattern is a
`400` field error. For **comptime `.collections` schemas**, a malformed `pattern` is a
`@compileError` at build time.

```json
{ "name": "title", "type": "text", "required": true, "options": { "min": 1, "max": 200 } }
```

### email

A string column intended to hold an email address. **No options.**

```json
{ "name": "contact", "type": "email", "options": {} }
```

### url

A string column intended to hold a URL. **No options.**

```json
{ "name": "homepage", "type": "url", "options": {} }
```

### editor

A rich-text / HTML string column. **No options.** (Stored as TEXT; the type is a hint to
clients/admin UI.)

```json
{ "name": "body", "type": "editor", "options": {} }
```

The admin record editor renders `editor` fields with a toolbar-driven WYSIWYG
rich-text editor (bold, italic, underline, strikethrough, headings, lists,
blockquote, inline code, links). Every write — on input, paste, and toolbar
action — is passed through a sanitizer that allowlists a fixed tag set (`p`,
`br`, `strong`/`b`, `em`/`i`, `u`, `s`, `h1`-`h3`, `ul`, `ol`, `li`,
`blockquote`, `code`, `pre`, `a[href]`) and strips everything else (scripts,
event-handler attributes, images, iframes, and any other markup), only
allowing `http:`, `https:`, and `mailto:` link targets. **Content is stored as
raw HTML** — consumer frontends that render an `editor` field's value must
sanitize it themselves before injecting it into the DOM; the admin sanitizer
only protects the admin UI's own editing surface. The editor relies on the
browser's (deprecated but universally supported) `execCommand` API and
degrades to plain contenteditable formatting on browsers that drop it.

### date

A date/time string column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `min` | string | unset | earliest allowed value (inclusive) — **enforced on every record write** |
| `max` | string | unset | latest allowed value (inclusive) — **enforced on every record write** |

`min`/`max` are **enforced on every record write**. The write path normalizes the value
and the bounds to a common UTC instant before comparing, so mixed input formats compare
correctly. A violation returns `400` with a `validation_min` / `validation_max` field
error.

**Accepted date input formats:**

- `YYYY-MM-DD` (date only).
- `YYYY-MM-DD` followed by `T` or a space, then `HH:MM` or `HH:MM:SS` or
  `HH:MM:SS.fff` (fractional seconds).
- Any of the above followed by `Z` (UTC) or a `±HH:MM` timezone offset. A missing
  timezone is treated as UTC.

Malformed or out-of-range values (e.g. `25:99:99`, `2026-02-29` in a non-leap year) are
rejected with `400` (`validation_date`).

Bounds are validated at collection-save time — a malformed `min`/`max` string is a `400`
field error, as is an unsatisfiable range where `min` is later than `max` (no value could
ever pass). For **comptime `.collections` schemas**, a malformed or unsatisfiable bound is
a `@compileError` at build time.

```json
{ "name": "starts_at", "type": "date", "options": { "min": "2026-01-01 00:00:00" } }
```

### autodate

A server-managed timestamp column, written automatically by the engine on create and/or
update.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `onCreate` | bool | `true` | stamp the current time when the record is created |
| `onUpdate` | bool | `false` | re-stamp on every update |

```json
{ "name": "published_at", "type": "autodate", "options": { "onCreate": true, "onUpdate": false } }
```

> The base `created` and `updated` columns already exist on every record; use `autodate` for
> *additional* managed timestamps.

### bool

A boolean column (stored as INTEGER 0/1). **No options.** Spell the type `"bool"`.

```json
{ "name": "is_active", "type": "bool", "options": {} }
```

### number

A numeric column. **The `mode` decides storage and precision.**

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `mode` | `"float"` \| `"int"` \| `"fixed"` | `"float"` | numeric kind (see below) |
| `scale` | integer **1..8** | unset | decimal places — **required when `mode` is `"fixed"`** |
| `min` | number | unset | minimum value, inclusive (`validation_min` on violation) |
| `max` | number | unset | maximum value, inclusive (`validation_max` on violation) |

- **`float`** — stored as SQLite `REAL` (IEEE-754 double). The default.
- **`int`** — stored as `INTEGER` (whole numbers).
- **`fixed`** — fixed-point decimal stored as `INTEGER` (scaled by `10^scale`). **`scale` is
  mandatory and must be 1..8.** Use this for money and other values where binary-float
  rounding is unacceptable.

> **Validation gotcha:** `mode: "fixed"` **without** a valid `scale` (1..8) is a `400`
> (`validation_invalid_scale`: "fixed number requires scale 1..8."). A `float` or `int`
> field never needs `scale`.

```json
// money: two decimal places, fixed-point
{ "name": "price_per_hour", "type": "number", "options": { "mode": "fixed", "scale": 2, "min": 0 } }
```

```json
// a plain integer count
{ "name": "seats", "type": "number", "options": { "mode": "int", "min": 1, "max": 8 } }
```

### json

An arbitrary JSON value, stored as TEXT.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `maxSize` | integer (bytes) | unset | maximum serialized size |

```json
{ "name": "metadata", "type": "json", "options": { "maxSize": 4096 } }
```

The admin record editor renders `json` fields with a monospace code editor that
validates on input, offers a **Format** button, and **blocks Save while the JSON is
invalid**.

### select

A single- or multi-value enumerated column.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `values` | array of strings | **required, non-empty** | the allowed values |
| `maxSelect` | integer | `1` | how many values may be chosen at once |

- `maxSelect: 1` → single-valued (the record stores one of `values`).
- `maxSelect > 1` → multi-valued (the field becomes a multi-value column).

> **Validation gotcha:** an empty `values` array is a `400` (`validation_required`: "select
> requires at least one value.").

```json
{ "name": "status", "type": "select", "options": { "values": ["pending", "confirmed", "cancelled"], "maxSelect": 1 } }
```

### relation

A foreign-key reference to records in another collection.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `targetCollectionId` | string | **required** | **the target collection's `id`** (see gotcha) |
| `cascadeDelete` | bool | `false` | delete this record when its referenced record is deleted |
| `minSelect` | integer | unset | minimum number of references |
| `maxSelect` | integer | `1` | maximum number of references (1 = single relation) |

- `maxSelect: 1` → a single relation (one referenced id).
- `maxSelect > 1` → a multi-relation.

> **CRITICAL: `targetCollectionId` is an id, not a name.**
>
> `targetCollectionId` must be the **id** that the target collection's create response
> returned — **not** the collection's `name`. ZigBase assigns the id when you create the
> collection; it is in the `"id"` field of the `POST /api/collections` response:
>
> ```jsonc
> // response from creating the "simulators" collection
> { "id": "a1b2c3d4e5f6g7h", "name": "simulators", "schema": [ ... ] }
> //        ^^^^^^^^^^^^^^^ THIS is what a relation's targetCollectionId must hold
> ```
>
> So provisioning is **order-dependent**: create the target collection first, **capture its
> `id` from the response**, then create the referencing collection with `targetCollectionId`
> set to that captured id. The [provisioning recipe](./recipes#recipe-provisioning-your-schema)
> shows the exact create-then-capture-id `curl` sequence. A relation with an empty
> `targetCollectionId` is a `400` (`validation_required`: "relation requires
> targetCollectionId.").

```json
// "listing" belongs to one "simulator"; cascade-delete the listing if the simulator is removed
{ "name": "simulator", "type": "relation", "required": true,
  "options": { "targetCollectionId": "a1b2c3d4e5f6g7h", "cascadeDelete": true, "maxSelect": 1 } }
```

### file

An uploaded-file reference. Files themselves are uploaded as `multipart/form-data` on record
create/update and served from `GET /api/files/:col/:rec/:name` (see
[API → Files](./api#files)).

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `maxSelect` | integer | `1` | maximum number of files (1 = single file) |
| `maxSize` | integer (bytes) | unset | maximum per-file size |
| `mimeTypes` | array of strings | unset | allowed MIME types; others are rejected |

- `maxSelect: 1` → single file; `maxSelect > 1` → multiple files.
- An upload exceeding `maxSize` → `413`; a disallowed `mimeTypes` value → `400` ("File type
  not allowed."); too many files for `maxSelect` → `400`.

```json
{ "name": "photos", "type": "file",
  "options": { "maxSelect": 6, "maxSize": 5242880, "mimeTypes": ["image/png", "image/jpeg", "image/webp"] } }
```

## Encryption at rest (`encrypted`)

Set `"encrypted": true` on a field to store its value **encrypted at rest** (AES-256-GCM,
versioned envelope, a fresh random nonce per write). The records layer encrypts on write and
decrypts on read, so your handlers, the records API, and HTTP responses always see
**plaintext** — only the SQLite file holds ciphertext.

```jsonc
{ "name": "ssn", "type": "text", "encrypted": true }
```

| Rule | Behavior |
| --- | --- |
| **Allowed types** | `text`, `editor`, `json` only. `encrypted` on any other type is rejected. |
| **Cannot combine with** | `unique`, an index, a `?filter`, or a `?sort` — ciphertext is per-row-nonce, so it is not comparable. A request filtering/sorting on an encrypted field returns **`400`**. |
| **Key** | Comes only from the `ZIGBASE_FIELD_KEY` env var; it is never auto-generated, persisted, or logged. If any collection declares an encrypted field and the key is unset, the **server refuses to start** (fail-closed). |
| **Reads are strict** | A stored value that is not a valid envelope (e.g. legacy plaintext) or fails authentication **fails closed** — there is no plaintext passthrough. Enabling `encrypted` on a column that already holds plaintext requires running `zigbase rewrap` first. |

Access rules that compare an encrypted field compare against ciphertext and effectively never
match — don't reference encrypted fields in rules. Key rotation (multiple generations via
`ZIGBASE_FIELD_KEY_V<n>`) and the `zigbase rewrap` command are covered in
[Framework → Field encryption at rest](./framework#field-encryption-at-rest-encrypted).

### Dev-only fake-encrypt mode

Set `ZIGBASE_FIELD_CRYPTO=fake` (or, in `zigbase.testing`, boot with no `field_key` — see
[Framework → Encrypted-field apps (#260)](./framework#encrypted-field-apps-260)) to swap the real
AES-GCM envelope for a **readable** one: an `.encrypted` value is stored as `fake:<key>:<value>`
— the plaintext, visible verbatim, prefixed with the label instead of a version tag. This is for
debugging/testing an `.encrypted`-field app without managing a real key, and for the
`zigbase.testing` harness to boot such an app at all (previously impossible — a real boot fails
closed with no key configured).

- **Dev-build-only, never on a production binary.** Fake mode is gated by the same `dev_mode`
  build option as the frozen clock and seeded entropy (`-Ddev-mode`, on by default in `Debug`,
  off in every release build — see
  [Framework §14](./framework#14-test--dev-mode-determinism-seams)). On a release binary the
  `ZIGBASE_FIELD_CRYPTO` env var is never even read; the mode is always `.real`.
- **Fail-closed across modes.** A fake envelope and a real `v<N>:` envelope are mutually
  unreadable: a real binary can never read fake-encrypted data (it isn't a valid envelope), and
  fake mode can never read real ciphertext. A database seeded with fake-encrypt data can never
  accidentally be served as if it were really encrypted.
- **Label-scoped.** `open` requires the exact `fake:<key>:` prefix; a different label fails
  closed, same as a wrong real key would.

## Row expiry (`ttl_field`) — a collection option

`ttl_field` is a **collection-level** option (not a field option): it names an existing
`date`/`autodate` field on the collection to use as each row's **expiry timestamp**. Rows
whose value is non-null and at/before "now" are reaped by an internal GC and hidden from
every read. It is set in the collection body's `options` object, not on a field:

```jsonc
{
  "name": "sessions",
  "type": "base",
  "fields": [ { "name": "expires_at", "type": "date" } ],
  "options": { "ttl_field": "expires_at" }
}
```

See [API → Collection options](./api#collection-options) and
[Framework → Row expiry (TTL)](./framework#row-expiry-ttl--ttl_field) for full semantics.

## Auth collections and system fields

A collection created with `"type": "auth"` automatically gains these system fields (you do
**not** declare them, and you may **not** reuse their names):

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

`identityFields` defaults to `["email"]`; each entry must be a valid identifier (it is
interpolated into SQL). `minPasswordLength` defaults to `8`. See the
[signup recipe](./recipes#recipe-user-registration-signup) for how record-create acts as the
signup path on an auth collection.

## A complete multi-field `POST /api/collections` body

A `listings` base collection that exercises `text`, fixed-point `number`, `select`,
`relation`, and `file`. (`owner` references a `users` auth collection and `simulator`
references a `simulators` collection — substitute the **ids** those collections' create
responses returned for the two `targetCollectionId` values.)

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

The five rule keys (`listRule`/`viewRule`/`createRule`/`updateRule`/`deleteRule`) are
described in [API → Access rules](./api#access-rules); owner-scoped and relation-traversal
rule patterns are in [Recipes → Owner-scoped access rules](./recipes#recipe-owner-scoped-access-rules).

## See also

[Recipes](./recipes) · [Tutorial](./tutorial) · [API](./api) · [Framework](./framework)
