# Observability & machine-readable output

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/observability> — the site is the canonical reading experience.

ZigBase ships several machine-readable contracts for tools and agents driving it:
a structured log stream, a frozen error-code registry, `--json` output on selected
CLI commands, and a capability-discovery endpoint. This page is the canonical
reference for all of them — the properties you can rely on, and which are still
being filled in.

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
