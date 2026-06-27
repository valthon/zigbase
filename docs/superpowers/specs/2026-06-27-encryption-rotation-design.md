# Encryption key rotation + rewrap tooling (issue #104)

Status: implemented. Builds on the at-rest field encryption from PR #94
(`src/aead.zig`, `src/field_policy.zig`, the `v<N>:` envelope, the strict
fail-closed read contract).

## Goal

The `v<N>:` envelope prefix was designed for rotation, but only `v1` shipped and
there was no way to (a) write under a new key while still reading old data, or
(b) migrate existing data forward. This delivers both:

1. **Multi-generation keys** — a primary (write) key plus zero or more older
   read-only generations, each mapped to an envelope version.
2. **`zigbase rewrap`** — a CLI command that re-encrypts every encrypted cell
   under the primary key (and migrates legacy plaintext into ciphertext).

## Config scheme (env only — keys are never persisted or logged)

Generation number ≡ envelope version. A `v<N>:` blob is decrypted with the key
of generation `N`.

| Env var | Meaning |
| --- | --- |
| `ZIGBASE_FIELD_KEY` | The **primary** (current/write) key. Required when any `.encrypted` field exists. Unchanged from before. |
| `ZIGBASE_FIELD_KEY_GENERATION` | Integer `1..64`, **default `1`**. The generation of the primary key. Writes stamp `v<this>:`. |
| `ZIGBASE_FIELD_KEY_V<M>` | Read-only key for an **older** generation `M` (`1..64`). Used to decrypt `v<M>:` envelopes. |

Rules:

- Default (`ZIGBASE_FIELD_KEY` only, generation `1`) is **identical to the
  pre-rotation single-key build** — it writes and reads `v1:`. Full backward
  compatibility.
- The primary generation's key comes **only** from `ZIGBASE_FIELD_KEY`. Setting
  `ZIGBASE_FIELD_KEY_V<M>` where `M == ZIGBASE_FIELD_KEY_GENERATION` is a
  **fatal config error** (ambiguous: two sources for the same generation).
- A generation outside `1..64` is a fatal config error.

### HKDF domain separation per generation

Each generation derives an independent AES-256 key via HKDF, domain-separated by
generation: domain = `"zigbase-field-encryption-v<M>"`. Generation 1's domain is
exactly `"zigbase-field-encryption-v1"` — the constant the single-key build
already used — so existing `v1:` data decrypts unchanged once `ZIGBASE_FIELD_KEY`
(or a `ZIGBASE_FIELD_KEY_V1`) is configured as that generation.

## Write-primary / read-by-version

- **Write:** seal with the primary generation's key, stamp `v<primary>:`.
- **Read:** parse the version `N` from the `v<N>:` prefix, look up generation
  `N`'s key, AEAD-decrypt. Tag verification is unchanged.
- **Fail-closed reads (unchanged contract):**
  - Non-envelope (legacy plaintext) → `error.BadEnvelope`.
  - Unknown/missing generation (no key configured for `N`, or `N > 64`) →
    `error.BadEnvelope`. No plaintext, no wrong-key garbage.
  - Wrong key / tamper / malformed → `error.BadEnvelope` (AEAD).

`field_policy.Cipher` becomes a small key-ring: `keys: [65]?[32]u8` indexed by
generation, plus `primary_gen` and `io`. `seal`/`open` are methods; `values.zig`
holds a `*const Cipher` (pointer, no per-value copy of the ring).

## Rotation workflow

Starting from a deployment running `ZIGBASE_FIELD_KEY=oldkey` (all data `v1:`):

1. Set `ZIGBASE_FIELD_KEY=newkey`, `ZIGBASE_FIELD_KEY_GENERATION=2`,
   `ZIGBASE_FIELD_KEY_V1=oldkey`. Now writes are `v2:`; old `v1:` rows still read.
2. Run `zigbase rewrap` to re-encrypt every `v1:` cell as `v2:`.
3. Once rewrap completes, drop `ZIGBASE_FIELD_KEY_V1` — no `v1:` data remains.

## `zigbase rewrap` (CLI) — UX + semantics

```
zigbase rewrap [--data-dir PATH] [--dry-run]
```

Enumerates every collection from `_collections` (covers both comptime-provisioned
and admin-created collections) and, for each `.encrypted` field:

- `SELECT rowid, "<col>" FROM "<table>"` (raw SQL — **bypasses** the value-layer
  strict decrypt so it can read mixed-generation and legacy-plaintext cells
  directly; identifiers are quoted via `ddl.quoteIdent`).
- For each non-null cell:
  - already `v<primary>:` → **skip** (this is what makes rewrap idempotent).
  - other `v<M>:` envelope → decrypt with generation `M`'s key, re-seal under
    primary. **Fail-closed:** an undecryptable cell (missing generation, wrong
    key, tamper) aborts the whole run with the offending `table.column rowid`
    reported; the per-collection transaction is rolled back (no partial writes,
    no data loss).
  - non-envelope (legacy plaintext) → taken as-is and sealed under primary. This
    is the supported path to enable `.encrypted` on a column that already holds
    plaintext under strict mode.
- Per-collection transaction (`BEGIN IMMEDIATE` … `COMMIT`); progress logged per
  column (`rewrapped` / `plaintext-migrated` / `skipped`).
- `--dry-run` performs every decrypt (so it still surfaces a key gap) and reports
  counts, but writes nothing.

Run rewrap with the primary key **plus** every older generation needed to read
existing data configured. If a needed generation is missing it fails closed and
names the row, so no data is silently dropped.

### Edge note

A legacy-plaintext value that happens to begin with `v<digits>:` is
misclassified as an envelope and will fail to decrypt — rewrap reports it and
aborts (fail-loud, no data loss) rather than guessing. This is the same
theoretical limitation as the existing strict read and is vanishingly rare for
real plaintext.
