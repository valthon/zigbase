# Migrate a Rails API to ZigBase

This guide re-platforms the **backend** of a Rails application onto ZigBase. It covers API and
service behavior only. Rails views, Turbo, Stimulus, and Rails-managed assets are out of scope, and
nothing here migrates them.

Use the generic [migration tools](migration-tools.md) for target schema, NDJSON import, supported
legacy bcrypt migration, and parity replay. Rails additionally has a supported offline converter —
`tools/rails/rails2zb.py` — for inventory, durable decisions, deterministic extraction, and Active
Storage files. Prefer it over hand-building the schema and NDJSON described in the generic guide.

To pair a retained or replacement frontend with the migrated backend, see
[Zigapagos pairing](zigapagos-pairing.md). That is a separate piece of work with its own skill.

## 0. Gate the scope before anything else

Do not begin until one of these is true and recorded:

1. the source is genuinely API-only — no view templates render in the request path, no browser
   route returns HTML, and no asset pipeline serves the application's own UI;
2. the operator explicitly selected backend-only migration and the frontend is recorded as retained
   and out of scope; or
3. the operator explicitly selected a **partial** migration of the JSON API subset of a
   view-rendering application, and recorded which routes move, which stay, and how the two halves
   coexist during and after cutover.

The third case is the common one. A pure `config.api_only` Rails application is rare; the ordinary
shape is a view-rendering monolith with a JSON API mounted under a namespace. Migrating that API
subset is legitimate work, but it is a *partial* migration and must be reported as one: the Rails
application keeps running, keeps its database, and keeps serving HTML.

A partial migration additionally needs a recorded answer for shared state. When both stacks read the
same rows, name the system of record per table, the synchronization direction, and the cutover
moment for each — or migrate a table-disjoint subset. Two writers against one dataset with no
recorded owner is the failure mode this gate exists to prevent.

Enumerate `app/views/`, every route whose action renders a template, and the asset pipeline. If any
exist, report them plainly as retained and never as migrated. A completion report that does not
distinguish the migrated backend from the retained frontend is wrong even when every row moved.

## 1. Freeze the source boundary

Stop writes, stop job workers and the scheduler, and take an immutable, recoverable snapshot. Record
the source revision, Ruby and Rails versions, the `Gemfile.lock` digest, the database engine and
version, a digest of the database export, the Active Storage service and its blob tree, effective
environment-variable names with values redacted, and the production server/worker/cron commands.

Never edit the source. Work from the snapshot for every subsequent step.

## 2. Inventory what the framework knows, not what the source says

Rails resists static reading. Routes come from a DSL evaluated at boot; associations, validations,
enums, and attribute encryption are declared through metaprogramming; `default_scope` filters every
ordinary read including the one an exporter would issue. `config/routes.rb` plus `db/schema.rb`
produces a plausible and wrong inventory.

**Preferred — observed.** Run the extractor inside the booted application against the snapshot:

```sh
bin/rails runner /path/to/zigbase/tools/rails/export_source.rb -- \
  --out source/inventory --taken-at 2026-08-21T00:00:00Z
```

It dumps what the framework actually knows: the resolved route set, model reflections, validators,
enums, `default_scope` presence, encrypted attribute names, the connection's real column types and
indexes, database triggers and views, Active Storage services and attachments, Active Job classes
and the queue adapter, and `unscoped` row counts. Every record it writes is stamped
`"source": "observed"` alongside the Ruby and Rails versions that produced it.

**Fallback — inferred.** When the application cannot be booted, read `db/schema.rb` (or
`structure.sql`) and `config/routes.rb` and stamp every record `"source": "inferred"`. An inferred
inventory is a starting point for questions, not a description of behavior. Never report an inferred
record as observed, and never let one silently satisfy a completion criterion.

`db/schema.rb` is not the database. Under the default `:ruby` schema format it records tables,
columns, and indexes — and **silently omits triggers, SQL views, check constraints, and most
engine-specific objects**. Rebuilding from it produces a schema that looks right and behaves
differently: a counter column maintained by a trigger simply stops being maintained. Read the live
catalog — `sqlite_master`, or `pg_catalog`/`information_schema` — and treat `schema.rb` as a
cross-check, never as the source of truth. An application using `schema_format = :sql` keeps these
objects in `structure.sql`; that is the one case where the checked-in file is authoritative.

Beyond the dump, inventory by hand and record with evidence:

- controllers, concerns, `before`/`after`/`around` actions and their order, strong parameters,
  serializers, pagination, and the exact success and error envelopes clients depend on;
- authentication, token and session behavior, authorization policies or abilities, CSRF and CORS
  boundaries, and rate limits;
- transactions, callbacks, raw SQL, database triggers, and engine-specific behavior;
- Active Job classes, queues, retries, mailers, Action Cable, webhooks, uploads, scheduled work, and
  outbound services; and
- mounted API engines, route constraints, formats, and redirects.

Commit stable findings with source evidence, disposition, replacement artifact, and rationale.
Missing private gems, runtime-generated routes, and behavior that only exists in production
configuration are blockers, not omissions.

## 3. Use the converter as the only extraction path

The converter is a repository tool, not a file embedded in a skill. From a ZigBase source checkout:

**Scope.** The observed inventory is adapter-neutral — the extractor reads whatever connection the
application booted, Postgres and MySQL included, and `inventory` works on all of them. Row
*extraction* is not: `extract` opens the frozen SQLite file directly and refuses any other adapter
by name. For a Postgres or MySQL source, take the findings and durable decisions from `inventory`,
then export the rows through the generic NDJSON path in [migration tools](migration-tools.md).

**Decisions that change the output.** Most choices record work you will do elsewhere, but a few are
carried out by the converter itself and are worth knowing: `rename` on a rejected table name takes
the new name as its artifact and remaps every relation that referred to it; `relation` on a
`belongs_to` with no database foreign key emits a real relation instead of a bare number; `cascade`
on dependent behavior sets `cascadeDelete`, and is offered only for the four dependents that really
delete children — `destroy`, `delete_all`, `delete` and `destroy_async` — because a
`restrict_with_exception` is Rails refusing the delete, and cascading it would destroy rows the
source protects. A `restrict_with_*` declaration on a column suppresses the cascade *decision* even
when a *different* model asks to cascade the same column. Where the database ALSO declares
`ON DELETE CASCADE` on that column, the two layers disagree, and that is its own decision rather
than a silent win for either: `cascade` keeps the database's behavior, `hook` carries the
application's refusal, and `omit` accepts neither. Section 4 describes that finding in full.
`omit` genuinely drops its subject, whether that is a column, a relation or a whole table, and a
renamed or omitted table takes its Active Storage attachments with it — omitting a table also
excuses its blobs, so `omit` is a usable route around the damaged part of a snapshot. Omitting an *attachment* leaves its blobs behind too, and `report.json`
records them under `droppedAttachments` alongside `droppedIndexes`, so nothing disappears without
a trail.

**Filenames.** Active Storage keeps the client-supplied filename verbatim, and ZigBase's file
route byte-compares the raw path segment — the SDKs build that URL with `encodeURIComponent`, so a
name outside `[A-Za-z0-9._-]` installs cleanly and then 404s for every client. Extraction rewrites
such a name using the same rule the engine's own upload path uses, and `files/manifest.json` keeps
the original alongside the rewritten one. `My Photo.png` is stored and served as `My_Photo.png`.

Names are carried through decision ids intact, including schema-qualified ones such as
`legacy.posts`: a decision id escapes the separator reversibly, so `rename` and `omit` work on
exactly the names most likely to need them. Column names are held to the same identifier gate as
table names — `legacy.value`, `user-name` and `2fa_enabled` each raise a finding offering `rename`
(the artifact is the new field name) or `omit`, rather than shipping a field the target refuses at
`schema apply`. A table name ending in `_fts` raises the same finding, because a searchable
collection provisions a shadow table under that name. Where two columns would resolve to the same
field — a denormalised `author` beside `author_id`, two columns renamed onto one name, or `Title`
beside `title`, which ZigBase compares case-insensitively — the relation first falls back to its
full column name, and a genuine collision is refused rather than letting one silently overwrite
the other.

**Names the engine owns.** ZigBase reserves `id`, `created`, `updated`, `email`, `username`,
`passwordHash`, `tokenKey`, `verified` and `token_epoch` as field names, case-insensitively. A
field carrying one of these is **dropped by `schema apply` rather than refused**, and the importer
then discards that column's values while reporting success — so an ordinary `contacts.email` column
migrated to nothing, with a clean exit at every step.

A column that *is* one of these names raises a finding offering `rename` or `omit`. A `rename` onto
one of them is refused, except where the same exemption applies — a scalar column on an auth
collection, whose type matches what the engine stores there. A name merely *derived* from a column takes the deterministic route
instead: a foreign key `email_id` whose relation field would be `email` keeps its full column name,
exactly as it does for any other collision. An Active Storage attachment has no second name to fall
back to on its own, so a reserved one is a finding offering `rename` or `omit`. So is an attachment
that shares its name with a *column* — a Paperclip or CarrierWave column left in place beside the
Active Storage attachment that replaced it is an ordinary shape, and both names are perfectly valid.
There `rename` moves the attachment's field and leaves the column alone, and `omit` drops the
attachment and keeps the column's data.

The exception is an auth collection, where `email`, `username` and `verified` are exactly what the
auth import maps. Those travel in the records — under the engine's own spelling, since it matches
record keys byte-for-byte — and the schema document deliberately does not redeclare them, so the
bundle never depends on the target silently dropping a duplicate. That exemption belongs to a
scalar column that genuinely is the collection's identity, never to a derived name and never to a
relation however it was named: `verified_id` is a foreign key, a `belongs_to` on a column called
`email` is a foreign key, and renaming either one onto an engine field is refused. The type has to
match too — the engine reads `verified` only as a boolean, so an integer column of that name is a
finding rather than a value it will quietly ignore.

**Access rules.** An `expression` decision's artifact is the rule text itself. Supply one expression
to apply it to all five actions, or a complete `<action> = <expression>` line per action
(`list`, `view`, `create`, `update`, `delete`) — any action you do not name stays Locked. Mixing the
two forms is refused rather than guessed at.

**Partial indexes.** A `WHERE` predicate is written against source columns and source values, both of
which extraction changes — `author_id` becomes the relation field `author`, and an integer-backed
enum becomes its label. The converter will not translate SQL it cannot verify, so every partial index
raises a finding: supply a reviewed target predicate as the decision's artifact, or omit the index.

```sh
python3 tools/rails/rails2zb.py inventory --source source --out findings.json
```

Exit `2` means judgment is required, not failure. Build a versioned `decisions.json` keyed by every
exact finding id, each with a non-empty rationale and a typed replacement artifact where behavior is
being replaced. Never substitute comments, unstructured notes, or warning suppression for a durable
decision.

Run extraction only after every finding reconciles:

```sh
python3 tools/rails/rails2zb.py extract --source source --decisions decisions.json --out bundle
```

Review source and decision digests, row and file counts, omissions, replacement artifacts, public
rules, unreferenced objects, and credential redaction. Run it twice and require byte-identical
bundles.

### Fidelity boundaries the converter will not cross

Each of these becomes a finding that needs a decision, never a silent conversion:

- **`default_scope`** — extraction reads through `unscoped`. A scoped read is silent data loss.
- **Active Record encryption** — ciphertext never migrates. Decide re-key or retire.
- **Polymorphic associations and single-table inheritance** — no automatic collection shape exists.
- **Composite primary and foreign keys** (Rails 7.1+) — a ZigBase record is keyed by one `id` and a
  relation holds one record id, so neither can be reproduced. A table keyed by several columns
  raises the same blocker as any other non-`id` key, and its only faithful answers are a hand-built
  import or leaving the table behind. A relation keyed by several columns is reported and not
  emitted; the columns themselves travel as ordinary numbers, so nothing is lost but the link.
- **Database triggers, views, and raw SQL** — behavior outside the readable schema. Catalog
  inspection is implemented for SQLite only; on any other adapter an empty trigger or view list
  means *unknown*, not *none*, and the converter raises a blocker saying so.
- **Check constraints** — `schema.rb` cannot express them and ZigBase has no equivalent, so each
  one needs a hook or rule replacement, or a decision to drop it.
- **Column defaults** — imported rows keep their values, but writes after cutover do not get the
  default. Each defaulted column raises a decision.
- **Foreign-key actions** — only `ON DELETE CASCADE` maps onto a relation. Anything else, and any
  `ON UPDATE` action, needs a replacement or an explicit decision.
- **Password hashes** — only verified bcrypt imports, through `--legacy-hashes bcrypt`, and
  "verified" has a specific meaning here (see below). Every other algorithm needs a reviewed reset
  or a separate design. The login credential is the digest belonging to a declared
  `has_secure_password`, not simply whichever `*_digest` column sorts first: an ordinary Rails app
  has `remember_digest`, `activation_digest` and `reset_digest` beside `password_digest`. Those
  others are bcrypt digests of live *tokens*, so each one raises a credential finding rather than
  migrating as an ordinary column.
- **External identities** — an OmniAuth or social-login account has no password to migrate. Its
  provider linkage moves separately, and only if you ask for it. See below.
- **Sessions, `secret_key_base`, signed and encrypted cookies, OAuth access and refresh tokens
  (including Doorkeeper's), API keys, and JWT signing material** — never migrate.

### Credentials: two ways a "successful" auth migration silently fails

**A Devise pepper is invisible in the hash.** Devise appends a configured pepper to the plaintext
before hashing:

```ruby
# devise/lib/devise/encryptor.rb
password = "#{password}#{klass.pepper}" if klass.pepper.present?
::BCrypt::Password.create(password, cost: klass.stretches).to_s
```

The result is an ordinary `$2a$…` string, structurally identical to an unpeppered one and accepted
by any bcrypt format check. Import it and every login fails after cutover, because the target
verifies the bare password. **You cannot detect this from the hash — you must read the
configuration.** Before importing any Devise credential, confirm `config.pepper` is unset in
`config/initializers/devise.rb` and in the environment. A configured pepper means a reviewed
password reset, not a bcrypt import. Record the pepper's *presence* as a finding; never record its
value. Devise's generator ships the setting commented out, so the default is safe — but applications
migrated from `restful_authentication` were explicitly told to put their old site key there, and
those are exactly the applications being re-platformed. Check `stretches` too: it is the bcrypt cost
and travels inside the hash, so it needs no special handling, but a cost above 12 is worth flagging
for login latency.

**An OmniAuth-only account is locked out unless you migrate its linkage.** ZigBase resolves a
provider sign-in through the `_externalAuths` table. Import the account without it and the user has
no link row and no password, so their first OAuth attempt fails
`409 Email already registered; sign in and link instead.` — their email already exists on the
imported record, and they have nothing to sign in with.

Carry the linkage on the auth row and import it with `--external-auths`
([migration-tools.md §4b](migration-tools.md#4b-external-identities-oauth--omniauth--social-login)):

```json
{"id":"42","email":"ada@example.test","externalAuths":[{"provider":"google","providerId":"110…"}]}
```

The record and its linkage are written in one transaction, so an account and the identity that
reaches it commit or roll back together. Two ordering constraints bite here: the same provider must
already be **configured and enabled** on the target collection before the import — a link naming a
disabled or undeclared provider can never resolve at login — and a `providerId` already linked to
any record is refused outright rather than re-pointed.

Rails-side, the pairs come from whatever your OmniAuth setup persists — commonly an `identities` or
`authentications` table carrying `(provider, uid)`. `uid` is the `providerId`. Inventory that table
explicitly; it is easy to miss because it is not where account data usually lives.

Accounts whose provider you are not carrying over still need a route back in: enable a passwordless
method (magic link or OTP) and run a rollout before cutover, or declare them out of scope and say so
plainly. Do not report a migration as complete while any account has no way to sign in.

## 4. Map schema, data, and authorization

Build a durable table-to-collection map covering ids, types, null and default semantics, indexes,
relations, timestamps and time zones, enums, counter caches, soft-delete policy, owner and tenant
fields, derived fields, and omissions. Preserve ids so relations still resolve.

Express authorization as actor, action, record state, allow or deny **before** choosing a mechanism.
Ordinary CRUD becomes collections and rules. Incompatible envelopes, transactions, callbacks, and
domain operations become typed custom routes. Multi-record invariants keep their transaction
boundary. Add at least one allowed and one denied in-process test per authorization replacement.

Intentional public signup is exact `@public` create plus a rationale in
`security/public-rules.json`. That is a doctor warning to reconcile, not an error to suppress.

Import auth files separately from ordinary data, both with `--preserve-timestamps`, then install
files only after row validation. A table that cannot supply a `created` for every row cannot use
that flag at all — no Rails timestamps, only an `updated_at` (extraction will not mirror backwards,
because "last touched" is not "made"), or a *nullable* `created_at`/`updated_at`, which Rails 4 and
earlier wrote by default and which lets a single row arrive with no timestamp at all. Extraction
also refuses, row by row, to put a record with no `created` **or** no `updated` into a manifest that
will be imported with the flag — an inventory that claims `NOT NULL` and a database that disagrees
is precisely the drift a migration exists to surface. The one mirror extraction does perform is for
a table that declares no `updated_at` **column**: there, `created` is copied into `updated`, the
table is named in `report.json` under `timestampMirrored`, and the inventory raises
`NoUpdatedAtColumn` to say so. A row whose declared `updated_at` is merely *empty* is drift, not a
table shape, and is refused by name rather than quietly backdated to never-updated.

**The import contract is valued per row, not per column.** Several checks therefore run against the
data, not the schema, because a column-level gate can be satisfied by a table whose own rows violate
it:

- **Required is emptiness, not NULL.** ZigBase rejects `""` and `[]` for a required field, while
  Rails' `null: false` only forbids NULL — and `t.string :nickname, null: false, default: ""` is
  idiomatic. A NOT NULL column that actually holds empty values is emitted as **not** required, and
  `report.json` lists it under `relaxedRequired`. The data is valid; the mapping was not.
- **Relations must resolve.** SQLite did not enforce foreign keys for most of Rails' history, so
  orphan rows are common. A relation value pointing at a row that does not exist is refused at
  extraction rather than partway through the import.
- **Ids must be acceptable ids.** A TEXT `id` column is legal in SQLite. An empty or non-printable
  one is refused — imported without `--preserve-timestamps` the target would quietly generate a
  fresh id and leave every relation to that row dangling.
- **Values must match their declared type.** SQLite's dynamic typing lets an INTEGER column hold
  `'banana'`, or a REAL `1.5` that keeps its storage class and that the target refuses for an
  integer field. A non-finite float, or one outside the target's 64-bit range, cannot be stored at
  all.
- **Dates must be real dates.** `0000-00-00 00:00:00` — the legacy-MySQL zero date — along with
  `2024-02-30`, `1900-02-29`, `24:00:00` and an impossible UTC offset like `+30:00` are all
  well-formed to a pattern match and impossible to the target, which range-checks every component.
  They are refused at extraction rather than at import: silently converting a corrupt offset would
  *move* the row, which is worse than stopping.
- **Text must be UTF-8.** Latin-1 bytes in a `TEXT` column are ordinary in an application old enough
  to be worth migrating, and the target stores UTF-8. There is no safe conversion to guess at, so
  extraction refuses and names what it found.

- **An auth collection's identities must be unique.** ZigBase puts a unique index on an auth
  collection's `email`. A legacy application that enforced uniqueness only in Ruby, with
  `validates_uniqueness_of` and no database index, can carry exact duplicates — and the import
  would fail on a bare constraint error, leaving the collection empty and every later import
  failing too.

Every one of these refusals names a location, because on a source of any size a message without one
is a message you cannot act on. A refusal about a single bad value names the table, the column and
the row id; the two that are about a *set* of rows — an orphaned relation and a duplicate identity —
name the table, the column and the offending values or their count, since there is no one row to
point at.

**The snapshot has to agree with the inventory that describes it.** Extraction compares the rows it
reads against the row counts the exporter observed, and refuses when they differ in either
direction. The route is ordinary rather than exotic: SQLite has run in WAL mode by default since
Rails 7, and copying `*.sqlite3` without its `-wal` sidecar opens a pre-checkpoint image that reads
perfectly well and is simply older than the inventory. Without this the bundle would hash and attest
rows it never saw.

**Two decisions about one subject must agree.** A single column or attachment can raise more than
one finding at once, and each is decided separately. Omitting it under one while keeping it under
another — by `rename`, `keep`, or a replacement `hook` — is refused, as is renaming it twice to
different names; otherwise the outcome would fall to whichever line came last. The same holds where
the omit arrives from elsewhere: dropping a polymorphic association drops the columns it names,
omitting a table drops everything in it, and dropping a column drops the relation built on it — so a
decision that asserts one of those still migrates (promoting a `belongs_to` to a relation, cascading
a delete) is refused rather than left inert. Dropping a column *and* the table its relation pointed
at is not a contradiction, though: that is a consistent schema, and it extracts. Nor is dropping one
of a model's children while cascading the rest, or deciding anything at all about a table that is
itself omitted — those decisions are inert, and refusing them would be noise. A cascade is judged
per model, though: if not one of the relations that model's `dependent` covers can carry it, the
decision is refused rather than recorded and ignored. `cascade` is not even offered where another
model declares `restrict_with_*` **directly** on the same rows, because that refusal wins.

Only a direct `has_many` or `has_one` describes rows the owner's deletion cascades to. A
`has_many :through` delegates its foreign key to the source association, so it names the
intermediate model's own pair while firing when a different table's rows are deleted; a `belongs_to`
with `dependent:` runs the other way entirely, destroying the parent when the child goes. Neither is
offered as a cascade, and the finding names each uncovered association with the reason that actually
applies to it. `destroy`, `delete_all`, `delete` and `destroy_async` all remove the children, so all
four are treated as cascades.

A cascade is offered only for a relation the bundle actually emits, pointing back at the deciding
model's own table. A foreign key on a column that never becomes a relation — the shared-primary-key
idiom is the real case — is named in the caveat rather than offered, and a `has_many` whose foreign
key carries a key to some *other* table cannot be governed by this model's decision at all. The
finding, the contradiction check and the emitted schema all ask the same question, so a decision
cannot be offered by one and quietly ignored by another. Deciding that this schema's foreign keys
cannot be trusted refuses any cascade outright, since nothing then carries one.

**Where the source contradicts itself about deletes, that is a decision.** A column can carry
`ON DELETE CASCADE` in the database while a model declares `restrict_with_*` on the same rows:
delete through Active Record and Rails raises with the rows intact, delete through SQL and the
database removes them. ZigBase has one layer, so this is a decision — and only one of the
answers keeps a source behaviour. `cascade` keeps what the database does. `hook` carries the
application's refusal as a before-delete hook you write. `omit` keeps neither: a relation without
`cascadeDelete` is emitted as `ON DELETE SET NULL`, so the parent deletes and the child is orphaned
with a null. The finding is not raised where no answer could act — an untrusted foreign key, a key
pointing at a column other than `id`, a column that never becomes a relation — and keeping the
cascade is refused if another decision has already dropped the relation it would ride.

A column the source cannot carry — encrypted, a primary key, a Rails timestamp, a password digest —
is never a relation, whether the foreign key is declared in the database or promoted by decision.
Promoting one is refused rather than silently ignored, and a database foreign key that lands on one
(the shared-primary-key idiom does) is reported: every other way a relation disappears raises
something, and this one used to flatten the graph in silence. Two findings agreeing — both `keep`, or both the same rename — are
not a contradiction.

Emptiness is judged on the value the bundle *emits*, not on the raw column: a `serialize`d nil is
the text `null` in SQLite — non-empty there, JSON null in the bundle — while a text column whose
content is literally `[]` is the reverse.

**The two manifests have an order.** Strip-then-patch is scoped to a single manifest run, so a
relation crossing the boundary needs its target's manifest imported first; `report.json` gives the
sequence as `manifestOrder`. Relations crossing in *both* directions cannot be ordered at all, and
extraction refuses rather than producing a bundle no sequence can import. Auth collections are not
part of this: they are imported from their own files before either manifest, so a relation pointing
into one is already satisfied and never counts as a crossing.

**Auth identities are validated against the target's own rule.** ZigBase's injected `email` field
rejects control characters and spaces, and requires exactly one `@` with both sides non-empty. A
legacy users table holding `admin` or a trailing space would stop the auth import at its first row
and leave the collection empty — which then fails every later import that relates to it — so those
values are refused at extraction instead. An empty email is fine: the field is not required and its
unique index is partial.

**Auth collections cannot hold relations.** An auth file is imported on its own, without the
manifest importer's ordering machinery, so a relation *out of* an auth collection — including one
pointing back at itself — resolves in no documented order. Each one raises a finding: drop it, or
keep it and re-establish those links yourself after the import. A `separate-import` decision puts such a table in
`manifest-no-timestamps.json`; `report.json` names that file when it exists, and it is imported
**without** `--preserve-timestamps`. An **auth** table in that state has no second manifest to go
to, since auth files are imported one at a time — `report.json` lists it under
`authFilesNoTimestamps`, and that one file drops the flag:

```sh
zigbase import --collection users --legacy-hashes bcrypt --preserve-timestamps \
  --data-dir ./zb_data bundle/auth/users.ndjson
zigbase import --manifest bundle/manifest.json --preserve-timestamps --data-dir ./zb_data
python3 tools/rails/rails2zb.py install-files --bundle bundle --source source --data-dir ./zb_data
```

Verify counts, ids, relations, timestamps, and file digests directly rather than trusting the
tool's own summary.

**Sub-second precision does not survive.** The converter preserves fractional seconds through the
bundle, but the importer parses `created`/`updated` to whole seconds, so `09:00:00.123456Z` lands as
`09:00:00Z`. Timestamps are preserved to the second, not byte-exactly; if sub-second ordering matters
to your data, carry it in a field of its own.

## 5. Port and prove the HTTP contract

Map every client-visible route's authentication and filter chain, parameter coercion and validation,
success and failure wire shape, database and transaction effects, enqueued jobs, mail, files, and
outbound calls to a collection API, hook, typed route, job, or a deliberate retirement.

Rails response envelopes rarely match ZigBase's. A Rails index returning `{"data": …, "meta": …}` and
an error returning `{"error": {"code": …}}` are client contracts: either port them behind a typed
route or record the client change as a decision. Never let an envelope change pass as parity.

Record representative requests against an isolated snapshot of the source and replay them against
the target. Parity must include, at minimum, a successful request, a validation failure, an
unauthenticated request, and an authenticated-but-unauthorized request. Preserve the source's own
concealment semantics: if Rails returns `404` where a record exists but the actor may not see it,
the target must too — do not "fix" it into a `403` during a migration.

Export target OpenAPI and reconcile it against the observed Rails contract; see
[OpenAPI export](openapi.md). Assert database, job, mail, and file side effects directly — replay
cannot observe them.

## 6. Rehearse cutover and preserve rollback

On a fresh, disposable target: syntax-lint and dry-run the schema, apply it, run full-depth rule
lint, import auth then ordinary data, verify counts and files, run the allow/deny and parity suites,
prove bcrypt-to-argon2id rehash on login survives a restart, run production doctor, restart, and
restore a backup into a second target. See [running the server](serve.md),
[deployment](deployment.md), and [Docker](docker.md).

At final cutover stop writes, workers, and the scheduler; drain or durably account for enqueued
jobs; take the final snapshot; regenerate from the already-reviewed decisions; repeat every
rehearsal check; then switch traffic. Keep the source snapshot, decisions, bundle, target database,
storage, and JWT secret as one rollback unit.

## 7. Hand off honestly

Report source and bundle digests, whether the inventory was observed or inferred, decisions and
replacement artifacts, counts, exact commands and exit codes, rule and doctor findings, parity
results including the denied cases, the legacy-hash transition, restart and restore proof, the
cutover owner, and the rollback trigger.

Name every unsupported, retired, and unresolved behavior plainly. State explicitly that Rails views
and frontend behavior were not migrated, and name the retained frontend if there is one.
