# zb_replay — parity-replay harness

A standalone, stdlib-only Python 3 tool. It is **not** a `zigbase` subcommand: it has to run
against an **old** backend (PocketBase, Rails, Express, an older ZigBase — anything that speaks
HTTP/JSON) to record expectations, so it can't assume anything about what it's talking to. For
the migration workflow this fits into, see [`docs/migration-tools.md`](../../docs/migration-tools.md).

## Commands

```
zb_replay.py record --base-url URL --requests requests.ndjson --out capture.ndjson
                    [--var NAME=VALUE ...] [--volatile KEY ...]
zb_replay.py replay --base-url URL capture.ndjson [--out findings.ndjson]
                    [--var NAME=VALUE ...]
```

- `record` runs each request in `requests.ndjson` against the **OLD** backend and writes a
  capture file: each case gets an `expect` filled in from the actual response, with volatile
  keys stripped so ids and timestamps never become expectations.
- `replay` runs a capture against the **NEW** backend and diffs each response against its
  `expect`.

Findings are streamed as NDJSON to `--out` (default `findings.ndjson`). The run summary is a
single JSON object printed to stdout. These never share a channel — script around the summary
without parsing the findings stream, or vice versa.

## Capture format (NDJSON, one case per line)

```json
{"id":"posts-list","method":"GET","path":"/api/collections/posts/records",
 "query":{"perPage":"5","sort":"-created"},"headers":{"Authorization":"Bearer {{token}}"},
 "body":null,"expect":{"status":200,"bodySubset":{"items":[{"title":"Hello"}]}}}
```

| Key | Meaning |
|---|---|
| `id` | Stable, unique case identifier. Required. Findings key off it. |
| `method`, `path` | Required. `path` is appended to `--base-url`. |
| `query` | Object of string → string. Optional. |
| `headers` | Only the headers that matter. `{{name}}` placeholders resolve from `--var`. |
| `body` | JSON value or `null`. Sent as `application/json` when non-null. |
| `expect.status` | Exact match. |
| `expect.bodySubset` | Recursive **subset** of the response body. |

A `requests.ndjson` fed to `record` needs only `id`, `method`, `path`, and optionally `query`/
`headers`/`body` — `expect` is filled in by the recording run.

## Subset matching

`expect.bodySubset` is a recursive **subset**, not an equality check: every key present in the
expectation must exist and match in the actual response, but extra keys in the response are
fine. Arrays compare element-wise up to the expectation's length — a longer actual array is not
a failure, a shorter one is. This is deliberate: matching on full equality would fail on every
field the old and new backends legitimately disagree on (extra metadata, additional fields),
and a parity check that fails on everything gets ignored.

## Volatile keys

Stripped recursively from the response at **record** time, so they never become expectations:

```
id, created, updated, token, collectionId, collectionName, expand
```

Add more with `--volatile KEY` (repeatable) — e.g. a backend-specific request-id field.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All cases passed (or, for `record`, the recording run completed). |
| `1` | Tool failure — unreadable capture, unresolved `{{placeholder}}`, or (for `replay`) every case dying in transport, meaning the replay target itself was unreachable and nothing could be exercised. |
| `2` | Ran correctly; at least one case has a parity failure, and/or some (but not all) cases errored in transport — an endpoint that vanished is itself a finding. Needs human judgment. |

A per-case transport error (a connection refused, a timeout) is only a tool failure when it
happens for *every* case — that means the target is dead and nothing was actually replayed.
When it happens for *some* cases while others succeed, it's parity signal: an endpoint that
went away between the old backend and the new one is exactly the kind of thing this tool
exists to catch, so it's folded into the findings and exit `2`, not swallowed as exit `1`.

## Worked example

```bash
cat > requests.ndjson <<'EOF'
{"id":"health","method":"GET","path":"/api/health"}
{"id":"posts-list","method":"GET","path":"/api/collections/posts/records","query":{"perPage":"5"}}
EOF

# Record against the OLD backend.
python3 zb_replay.py record --base-url http://old-backend:8080 \
    --requests requests.ndjson --out capture.ndjson

# Replay against the NEW backend.
python3 zb_replay.py replay capture.ndjson --base-url http://localhost:8090 \
    --out findings.ndjson
echo "exit=$?"

# Inspect only the failures.
python3 -c "
import json
for line in open('findings.ndjson'):
    f = json.loads(line)
    if f['result'] != 'pass':
        print(f)
"
```
