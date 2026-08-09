# Observability & machine-readable output

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/observability> — the site is the canonical reading experience.

ZigBase ships several machine-readable contracts for tools and agents driving it:
a structured log stream, a frozen error-code registry, `--json` output on selected
CLI commands, and a capability-discovery endpoint. This page is the canonical
reference for all of them — the properties you can rely on, and which are still
being filled in.

## Log output

Every `std.log` call in the framework, its vendored dependencies, and consumer
hooks/routes goes through one `logFn` and is emitted to **stderr** (never stdout —
stdout is reserved for a command's actual result, see
[Machine-readable CLI output](#machine-readable-cli-output) below). Two line
encodings are supported, selected by `ZIGBASE_LOG_FORMAT` / `--log-format` (`serve`
only; see [Configuration](#configuration-knobs)):

**`text`** (the default) — human-first, one line per record:

```
2026-08-08T19:33:15Z info: zigbase listening on http://127.0.0.1:8090
```

A named scope is parenthesized after the level; the default scope is omitted:

```
2026-08-08T19:33:15Z error(http): boom
```

**`json`** — one JSON object per line (NDJSON) on stderr, for a log-shipping
pipeline or an agent grepping/parsing structured output:

```json
{"ts":"2026-08-08T19:33:15Z","level":"info","scope":"default","msg":"zigbase listening on http://127.0.0.1:8090"}
```

The keys, in this fixed order, are always present:

| key | type | notes |
|---|---|---|
| `ts` | string | `YYYY-MM-DDTHH:MM:SSZ`, UTC |
| `level` | string | the enum's own tag name — `debug`, `info`, `warn`, `err` (**not** `error`; see below) |
| `scope` | string | `std.log`'s scope, or `"default"` |
| `msg` | string | the formatted message, JSON-escaped |

`level` uses `err`, not `error` — that is `std.log.Level`'s own tag spelling, and
it round-trips with `--log-level`'s `parseLevel` (which accepts both `error` and
`err` as input, but only ever emits `err`). Field order is part of the contract;
reorder-detecting tests pin it.

A line that would overflow its fixed-size buffer is truncated, but the truncation
is contract-safe: a `json` line is still exactly one parseable object (the message
is clamped before the envelope is composed around it), never a broken fragment.

### Configuration knobs

| Env var | Flag (`serve` only) | Default | Purpose |
|---|---|---|---|
| `ZIGBASE_LOG_FORMAT` | `--log-format` | `text` | `text` or `json` |
| `ZIGBASE_LOG_LEVEL` | `--log-level` | `info` | minimum severity: `debug`, `info`, `warn`, `error` |
| `ZIGBASE_LOG_REQUESTS` | `--no-request-log` | `true` | per-request access lines (see [Request logging](#request-logging)) |

The env vars apply to **every** subcommand (`ZIGBASE_LOG_FORMAT=json zigbase migrate`
works); the flags are `serve`-only, added there rather than to every subcommand to
avoid growing the CLI surface for no gain.

**Boot ordering.** A malformed `ZIGBASE_LOG_FORMAT`/`ZIGBASE_LOG_LEVEL` must be
reported *by the logger it is configuring* — a chicken-and-egg problem. ZigBase
resolves it with a two-pass startup: `zigbase`'s entrypoint reads and applies only
those two variables first, silently ignoring an invalid value; the real, fail-fast
validation runs moments later and produces the actionable startup error (naming the
variable, the value, and what was expected) in whichever format the (possibly
still-default) pre-pass selected. There is exactly one validation path — the
pre-pass never validates, so the two can never disagree.

That fail-fast validation belongs to config loading, so it runs for every subcommand
that loads config (`serve`, `migrate`, `superuser`, …) — not for the two that need no
config at all, `version` and `explain-code`. Those still *honor* the log env vars via
the pre-pass; they simply ignore a malformed one instead of refusing to run. Printing
a version string is deliberately not blocked by an unrelated bad variable elsewhere in
the environment.

## The NDJSON contract

Any ZigBase stream that emits one JSON object per line — the `json` log format
above, and any future findings/progress stream — follows one rule: **a consumer
must skip any line that does not parse as JSON, and must never fail the run because
of it.** A panic message, a vendored C library's own diagnostic output, or (in
practice, today) facil.io's own startup banner (`INFO: Listening on port 8090`,
`* Detected capacity: …`) can land on the same stream as the structured lines —
facil.io writes some of its own status lines directly, outside `logFn`. Parse each
line independently; a line that fails to parse is not a protocol violation, just
noise to discard.

## Request logging

`logging.request(rec)` is a structured record — method, path, status, duration —
kept **separate from `std.log`** on purpose: a `logFn` only ever receives an
already-formatted string, so routing a request through it would collapse every
field into one opaque `msg`, useless to an agent parsing the JSON stream. The record
shape (already implemented and unit-tested in `src/logging.zig`):

```json
{"ts":"2026-08-08T12:00:00Z","level":"info","scope":"http","msg":"request","method":"GET","path":"/api/health","status":200,"duration_ms":3}
```

```
2026-08-08T12:00:00Z info(http): GET /api/health 200 3ms
```

`path` is attacker-controlled (it comes straight off the wire) and is JSON-escaped
through `std.json.fmt` in the `json` encoding — a crafted URL containing a quote or
newline cannot forge a second log record. Request lines are emitted at `info`, so
`--log-level warn` (or higher) silences them independent of the toggle below.
Turn them off entirely with `ZIGBASE_LOG_REQUESTS=false` / `--no-request-log`, e.g.
on a high-traffic deployment that already ships access logs from its reverse proxy.

Emission is wired at the listener: `server.zig`'s `onRequest` measures wall time
from the moment a request arrives (a monotonic `std.Io.Timestamp`, not the system
clock) to the moment a response goes on the wire, and logs exactly one record per
request on **every** exit path — the happy path, a raw-500 escape, and a file
response that downgrades to a 404 — via a `defer` registered immediately after the
request context is built. `status` reflects what the client actually received, not
what a handler first computed.

## Error codes

Every error response is `{"status":…,"code":…,"message":…,"data":…}` — see
[the API reference](api.md#conventions) for the full envelope shape and the
per-field validation-error form. The contract that matters here: **`code` is a
frozen machine string, `message` is not.** `message` may be reworded in any
release; an agent or SDK that matches on it will break silently the next time
someone improves the wording. Always match on `code`.

Run `zigbase explain-code` to list every registered code with its one-line
summary, or `zigbase explain-code <CODE>` for the long form (what produced it and
what to do about it). Both accept `--json`:

```
$ zigbase explain-code not_found
not_found
no such resource, or the caller may not know whether it exists

Covers both a genuinely absent resource and a resource the caller isn't
permitted to know about — ZigBase deliberately does not distinguish
"doesn't exist" from "exists but you can't see it" in the response, to
avoid leaking existence via status code.

Don't infer permission state from this code; if the caller believes the
resource should exist, that's an authorization question, not a retry.
```

```json
$ zigbase explain-code not_found --json
{"code":"not_found","known":true,"summary":"no such resource, or the caller may not know whether it exists","explanation":"…"}
```

An unregistered code (one a consumer route passed to `ctx.jsonError` directly, for
instance) is reported as `known:false` on stdout with exit 1 — not a CLI usage
error, since the code may be entirely legitimate for that application.

**The ledger is append-only.** The set of registered codes lives in
`src/error-codes.frozen` (an `[ACTIVE]`/`[RETIRED]` list, `@embedFile`-d into
`src/error_codes.zig`) plus the `Code` enum it mirrors. To **add** a code: add the
enum field and append its name to `[ACTIVE]`, keeping the section alphabetical. To
**stop** emitting a code: move its line to `[RETIRED]` and delete the enum field —
the line never disappears, and a retired name is never reused for a different
meaning. Renaming a code is a removal plus an addition, and any consumer matching
on the old string breaks silently — so it never happens. A battery of unit tests
enforces all of this (every enum field is `ACTIVE`, every `ACTIVE` line is an enum
field, no field matches a `RETIRED` line, `ACTIVE` is sorted and duplicate-free,
and every code carries a non-empty summary and explanation).

Those tests only see the tree **as it stands**, so deleting a code from the enum
and from `[ACTIVE]` in the same commit would satisfy every one of them. CI closes
that gap with `scripts/check-error-code-ledger.sh`, which diffs the ledger against
the base branch and fails if any code disappeared without a `[RETIRED]` line (or if
a retired tombstone was dropped or resurrected). Together: the unit tests keep the
ledger and the enum honest with each other, and the CI guard keeps history honest.

> **Two frozen id vocabularies, two casings — on purpose.** API error codes are
> `snake_case` (`validation_min`, `collections_frozen`): they were `snake_case`
> before they were frozen, and a code, once shipped, is permanent — respelling the
> existing 27 `validation_*` codes to gain cosmetic uniformity would break every
> consumer matching on them, which is exactly what the ledger exists to prevent.
> Doctor check ids are `dash-case` (`jwt-secret-persisted`), matching the repo's
> standing URL-segment convention. The two vocabularies never mix in one field, so
> nothing has to guess which rule applies: if it appears as an error envelope's
> `code` it is `snake_case`, and if it appears as a doctor check id it is
> `dash-case`.
