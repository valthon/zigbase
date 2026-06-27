# Theme B1 — Field/Collection Policy Pipeline + Transparent At-Rest Encryption

**Status:** DESIGN — pending review. Implementation is **HELD** until the
encryption decisions below (envelope, key source/rotation, enforcement) are
approved. (Issue #82.)

## Background

Theme B is the *data-shapes / field-and-collection-policy* layer. Issues #81
(TTL), #82 (encrypted fields), #87 (KV store), #88 (feature flags) share one
idea: declarative behaviors that the framework applies to data *below* the
collection CRUD surface, so a consumer declares intent (`.encrypted = true`,
`.ttl_field = "expires_at"`) and the engine does the work transparently.

This spec covers the **field/collection policy mechanism** and its first
instance, **transparent at-rest encryption**. The mechanism is the reusable
seam; encryption is the proof.

## Goals

- A small, explicit **value-transform pipeline** in the records read/write path:
  a field-scoped behavior that can transform a value *on its way to* SQLite
  (write) and *on its way back* (read), with the field schema in hand.
- `.encrypted = true` as the first behavior: AES-256-GCM authenticated
  encryption, transparent to handlers/records API and the HTTP layer
  (plaintext in memory), ciphertext-only in the SQLite file.
- Reuse the proven envelope from `src/oauth/secrets.zig` (versioned `v1:` +
  base64url(nonce‖ct‖tag)), generalized into a shared module.
- Key from the environment only (`ZIGBASE_FIELD_KEY`); never in the binary,
  never logged, never persisted to the data dir.
- A **rotation story** designed up front (version tag selects key generation),
  even though only `v1` ships.
- Encrypted fields are **non-indexable / non-filterable / non-unique** —
  enforced at **comptime** where the inputs are comptime-known (indexes,
  `unique`), and at **runtime** for the dynamic query surface (`?filter`,
  `?sort`).
- **No regression for non-encrypted fields** — the hot path adds at most one
  `bool` test per field per value when no field in the collection is encrypted.

## Non-goals (this slice)

- A general user-pluggable policy registry. The pipeline is an *internal* seam
  with one built-in behavior (encryption). Future behaviors (hashing,
  redaction, compression) slot into the same seam but are not built now.
- A `rewrap`/re-encrypt CLI for bulk key rotation. The envelope is designed to
  support it; the command is a follow-up.
- Encrypting the system tables, file blobs on disk, or auth credential columns
  (those already have their own hashing). Scope is **user collection fields**.

## Current state (grounding)

- `src/oauth/secrets.zig` — `encryptSecret`/`decryptSecret`: AES-256-GCM, HKDF
  key derivation from an app secret, `v1:` + base64url(nonce‖ct‖tag), fail-closed
  decrypt. Already battle-tested for OAuth client secrets.
- `src/values.zig` — `bindValue(alloc, stmt, idx, field, v)` (write) and
  `readValue(alloc, stmt, idx, field)` (read) are the **single choke points**
  through which every field value passes to/from SQLite. Both already receive
  the `schema.Field`.
- `src/records.zig` — `createInTxn`/`updateInTxn` call `values.bindValue`;
  `rowToObject` (used by `get` + `list`) calls `values.readValue`. `createInTxn`
  already receives `io` (entropy for ids); the others do not.
- `src/schema.zig` — `Field` carries orthogonal flags (`required`, `unique`,
  `hidden`) alongside the per-type `options` union. `FieldOptions` is a
  `union(FieldType)` — per-type, so it is the wrong home for a cross-type flag.
- `src/provision.zig` — `buildField` reads `.required`/`.unique`/`.hidden` from
  the comptime literal; `buildOptions` is the per-type `@compileError` site;
  `buildIndexes` lowers `.indexes`.
- Field options round-trip through `schema.fieldToValue`/`fieldFromValue`
  (the per-field `options` JSON in the `_collections.schema` column) and survive
  additive rebuilds via stable field id matching in `ddl.rebuildPlan`.
- `src/config.zig` — `Config.load(getter)` reads env vars; `App` (app.zig) holds
  resolved runtime config. `serveImpl` (framework.zig) resolves secrets at
  startup (see `resolveJwtSecret`) and constructs `App`.

## Design

### 1. The policy pipeline (the seam)

A new module **`src/field_policy.zig`** defines the value-transform seam:

```zig
/// Resolved at startup from ZIGBASE_FIELD_KEY; null when no key configured.
pub const Cipher = struct {
    key: [32]u8,                 // derived once via HKDF; never the raw env value
    // (future) prior_keys: []const KeyGen  — for rotation reads
};

/// Applied just before a value is bound to SQLite. Returns the value to store.
/// For an encrypted text/json field it returns the "v1:"-blob string; otherwise
/// it returns `v` unchanged. `io` supplies the per-write nonce.
pub fn onWrite(io: std.Io, alloc, cipher: ?Cipher, field: schema.Field, v: std.json.Value) !std.json.Value;

/// Applied just after a value is read from SQLite, before it is handed back.
/// For an encrypted field it decrypts the blob back to the field's plaintext
/// value; otherwise returns `v` unchanged.
pub fn onRead(alloc, cipher: ?Cipher, field: schema.Field, v: std.json.Value) !std.json.Value;
```

Encryption operates on the **storage string** (what `values` would have bound):
text/editor/email/url store their string; json stores its stringified form. So
the cleanest integration is to invoke the pipeline **inside `values.zig`**, at
the exact bind/read choke point, where the storage string already exists:

- `values.bindValue`: after computing the text to bind for an encryptable type,
  if `field.encrypted` and a cipher is present, replace it with the encrypted
  blob and `bindText` that.
- `values.readValue`: for an encryptable type, if `field.encrypted`, take the
  raw column text, decrypt it to the plaintext storage string first, then parse
  it as the underlying type (string for text; `parseFromSlice` for json).

`bindValue`/`readValue` gain one optional parameter, `cipher: ?Cipher`, threaded
from the records functions. **When `cipher == null` or `!field.encrypted`, the
existing code path runs unchanged** (one branch, no allocation, no crypto).

> Rationale for choke-point integration over a separate pre/post pass: a single
> code path correctly handles every encryptable type (notably json, which must
> be encrypted *as its serialized string* and decrypted *before* parsing), and
> it never materializes plaintext anywhere the ciphertext path wouldn't.

### 2. Threading the cipher

`Cipher` is resolved once in `serveImpl` and stored on `App`
(`app.field_cipher: ?field_policy.Cipher`). It reaches `values` by adding an
optional `cipher: ?Cipher` parameter to the records read/write functions
(`createInTxn`, `updateInTxn`, `get`, `list`, `rowToObject`) and to
`bindValue`/`readValue`. The `Data` facade gains the cipher (it already holds
`app`), so `Data.create/update/findById/list` pass `self.app.field_cipher`
through. Hooks/routes/jobs inherit it automatically because they all go through
`Data`/`ctx.records`.

> Alternative considered and rejected: stamping the cipher onto `db.Db`
> connections to avoid signature churn. Rejected — `db.zig` is the low-level
> SQLite layer and must not carry an application-domain concept; explicit
> threading keeps the dependency direction clean and the functions unit-testable
> with an injected cipher.

### 3. The field option

`.encrypted` is a **cross-type field flag**, declared like `required`/`unique`:

```zig
.fields = .{
    .{ .name = "ssn", .type = .text, .encrypted = true },
    .{ .name = "notes", .type = .json, .encrypted = true },
},
```

- Add `encrypted: bool = false` to `schema.Field` (next to `hidden`), **not** to
  the per-type `FieldOptions` union (encryption is orthogonal to type).
- `provision.buildField` reads `.encrypted` from the literal (one line next to
  the existing `.required`/`.unique`/`.hidden` reads).
- Serialize/deserialize the flag in `schema.fieldToValue`/`fieldFromValue` so it
  round-trips through `_collections.schema` and survives additive rebuilds.
  (`ddl.rebuildPlan` copies the column data verbatim; ciphertext is just TEXT, so
  rebuilds preserve it — see §6.)

**Encryptable types (comptime-restricted):** `text`, `editor`, `email`, `url`,
`json`. All store as SQLite TEXT, so the stored blob fits and a rebuild CAST is a
no-op. Marking `.encrypted` on `number`/`bool`/`date`/`autodate`/`select`/
`relation`/`file` is a **`@compileError`** (their typed/relational storage can't
hold a base64 blob and they rely on ordering/joins). Validation (email/url
format, text pattern/length) runs on the **plaintext** before encryption on
write, so format constraints still hold; on read the value is decrypted back to
plaintext for the API.

### 4. Encryption envelope (reuse + generalize)

Generalize `oauth/secrets.zig` into a shared primitive. Two clean options:

- **(a)** Move the AEAD core into `src/crypto.zig` (or a new
  `src/field_crypto.zig`) as `encrypt(io, alloc, key32, plaintext)` /
  `decrypt(alloc, key32, blob)` taking a **derived 32-byte key** directly, and
  have `oauth/secrets.zig` call it with its HKDF-derived key. `field_policy`
  calls it with the field key.
- **(b)** Leave `oauth/secrets.zig` as-is and add a sibling for fields.

**Recommendation: (a)** — one audited AEAD/envelope implementation, two
domain-separated key derivations. Envelope stays **identical** to the proven
format: `"v1:" ++ base64url(nonce(12) ‖ ciphertext ‖ tag(16))`, AES-256-GCM,
fresh random 12-byte nonce per write (`io.random`), empty AAD. Fail-closed on
any decrypt error (`error.BadSecret` → surfaced as a 500/`error.Internal`; the
write/read fails, no plaintext leak).

### 5. Key source, derivation, and rotation

- **Source:** `ZIGBASE_FIELD_KEY` env var **only**. Add it to `config.zig`
  (`field_key: []const u8 = ""`). Never written to the data dir, never logged
  (unlike the JWT secret, which auto-generates+persists — a field key must be
  operator-managed because losing/rotating it determines data recoverability).
- **Derivation:** HKDF-SHA256 over the env value with a **field-specific domain
  separator** (`"zigbase-field-encryption-v1"`), mirroring the OAuth path's
  `"zigbase-oauth-secret-v1"`. So the raw env value may be any length/format; the
  derived 32-byte key is what AES uses. Derived **once** at startup and cached on
  `App` (no per-value HKDF).
- **Fail-closed startup:** if any provisioned collection declares an encrypted
  field but `ZIGBASE_FIELD_KEY` is unset/empty, `serveImpl` **refuses to start**
  (`error.FieldKeyRequired`, logged clearly). This guarantees we never silently
  store plaintext where ciphertext was requested. (Comptime knows whether any
  encrypted field exists; the check is a startup guard.)
- **Rotation (designed, v1-only shipped):** the `v<N>:` prefix is the
  **key-generation selector**. `v1` → key derived from `ZIGBASE_FIELD_KEY` with
  the `…-v1` separator. A future `v2` adds a second configured key (e.g.
  `ZIGBASE_FIELD_KEY` = new primary, `ZIGBASE_FIELD_KEY_PREV` = old) and a
  `…-v2` separator. **Writes always use the highest configured generation**
  (the "primary"); **reads dispatch on the blob's prefix** to pick the matching
  key. Rows migrate forward lazily (any update re-encrypts under the primary) or
  via a future `rewrap` command. v1 ships with a single key; the read dispatch is
  a one-entry table today, extensible without an envelope format change.

  > If the AEAD/format itself ever changes (not just the key), we reserve a
  > distinct higher version range so format-version and key-generation don't
  > collide. For now they share `v1`, exactly as the OAuth secrets do.

### 6. Enforcement: non-indexable / non-filterable / non-unique

- **Comptime (definitive, where inputs are comptime-known):**
  - `provision.buildIndexes` / `buildCollection`: `@compileError` if any index's
    `fields` names an encrypted field. (An index over ciphertext is useless and
    silently breaks lookups.)
  - `provision.buildField`: `@compileError` if `.encrypted` and `.unique` are
    both set (a UNIQUE constraint over per-row-nonce ciphertext is meaningless —
    identical plaintexts produce different blobs).
- **Runtime (dynamic query surface):** the query compiler (`src/query/`) and the
  list/sort path know each field's `encrypted` flag via the collection schema.
  A `?filter=` or `?sort=` that references an encrypted field returns
  `error.BadRequest` ("field 'x' is encrypted and cannot be filtered/sorted").
  This is the only place enforcement *must* be runtime (the query string is
  user-supplied at request time).
- **Access rules caveat (documented; optional comptime warning):** access-rule
  expressions are comptime strings but parsing them at comptime to detect field
  references is fuzzy. A rule that compares an encrypted field will compare
  against ciphertext and effectively never match. We **document** this and may
  add a cheap comptime substring scan that warns (not errors) when a rule string
  contains an encrypted field name. **Open question for review.**

### 7. Migration affordance vs. fail-closed (the one subtle decision)

Toggling `.encrypted = true` on a column that already holds plaintext rows is a
*semantic* change the additive provisioner does **not** detect (same name, same
TEXT type → no rebuild). To make opt-in smooth **without** weakening security:

- On **read** of an encrypted field, if the stored value **lacks** the `v1:`
  prefix, treat it as **not-yet-encrypted plaintext** and return it as-is. New
  writes encrypt; old rows read through until next write. This makes "enable
  encryption on an existing field" a no-downtime change.
- On **read**, if the value **has** the `v1:` prefix but decryption **fails**
  (wrong key, tamper), **fail closed** (`error`, no plaintext, logged). This is
  the genuine security boundary and stays strict.

This cleanly separates "format not applied yet" (pass-through, migration
affordance) from "authenticated decryption failed" (hard fail). **This is a
decision to confirm in review** — the alternative is strict fail-closed even for
unprefixed values (forcing an explicit `rewrap` before enabling encryption).

## Performance

- Non-encrypted collections: `serveImpl` resolves `cipher = null` unless a key is
  set; `bindValue`/`readValue` short-circuit on `!field.encrypted` (the flag is a
  struct bool already in cache with the field). Net cost: one predictable branch
  per field per value — unmeasurable vs. the existing per-field switch.
- Encrypted fields: one AES-GCM op + one base64 transform per value, on a key
  derived once at startup (no per-value HKDF). AES-NI on x86_64/aarch64 makes
  this sub-microsecond for typical field sizes.
- A benchmark-style unit test will assert the non-encrypted path allocates/does
  no crypto (structurally — the cipher is null), and the encrypted round-trip
  works.

## Testing

- **Unit (`zig build test`):**
  - Envelope round-trip + tamper/wrong-key fail-closed (inherited/extended from
    the existing secrets tests).
  - `field_policy.onWrite`/`onRead` round-trip for text and json; pass-through
    when `cipher == null` or `!encrypted`.
  - **Ciphertext-at-rest:** create a record with an encrypted field via the
    records API, then read the **raw SQLite cell** with a direct
    `SELECT "col" FROM "t"` and assert it starts with `v1:` and does **not**
    contain the plaintext.
  - Read-back via the records API returns the **plaintext** (transparent).
  - **Comptime rejection:** a `comptime`-evaluated negative test (the
    "temp-test-revert" pattern — add, confirm `@compileError`, revert with Edit)
    proving that indexing an encrypted field, marking it `unique`, or encrypting
    a non-string type fails to compile.
  - Runtime rejection: `?filter`/`?sort` on an encrypted field → 400.
  - Migration affordance: an unprefixed value reads through; a prefixed-but-
    corrupt value fails closed.
  - Startup guard: encrypted field declared + no key → `error.FieldKeyRequired`.
- **Browser/pytest (`tests/admin/`):** the records hot path is touched — run the
  suite to confirm no regression in admin CRUD; add coverage that an encrypted
  field stores ciphertext and the admin still shows plaintext.

## Docs & examples

- `docs/framework.md` + `site/src/content/` mirror: a "Field encryption" section
  (declare `.encrypted`, set `ZIGBASE_FIELD_KEY`, the non-filterable/-indexable
  rules, rotation note, the fail-closed/migration semantics).
- `KNOWN_LIMITATIONS.md`: encrypted fields can't be filtered/sorted/indexed;
  rotation is single-key in v1.
- Demonstrate in `examples/plugins` (the advanced example): an encrypted field +
  a note in its README, keeping it building.
- `changelog.d/<slug>.md`: `### Features` (field/collection policy pipeline,
  transparent at-rest encryption) and `### Security` (at-rest crypto, key from
  env, fail-closed).

## Decisions to confirm in review (the hard-to-reverse ones)

1. **Envelope:** reuse the exact `v1:` + base64url(nonce‖ct‖tag) AES-256-GCM
   format, generalized into a shared AEAD primitive (recommendation 4a). OK?
2. **Key source & derivation:** `ZIGBASE_FIELD_KEY` env only, HKDF with a
   field-specific domain separator, derived once, never persisted/logged,
   **fail-closed startup** when an encrypted field exists without a key. OK?
3. **Rotation model:** `v<N>:` prefix = key generation; writes use the primary,
   reads dispatch on prefix; v1 ships single-key; lazy/`rewrap` forward
   migration. OK to design now, ship v1 only?
4. **Enforcement split:** comptime `@compileError` for indexes + `unique` +
   non-string types; runtime 400 for `?filter`/`?sort`; **documented** caveat
   (optional warning) for access rules. OK, or do we want a stricter comptime
   rule scan?
5. **Field option home:** `encrypted: bool` on `schema.Field` (cross-type flag),
   not inside the per-type `FieldOptions` union. OK?
6. **Migration affordance:** unprefixed-value read-through (smooth opt-in) vs.
   strict fail-closed-always (requires explicit rewrap before enabling). Which?
7. **Encryptable type set:** text/editor/email/url/json. Include or exclude
   email/url (they carry format validation)?
