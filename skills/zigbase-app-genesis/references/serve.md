> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/serve> — the site is the canonical reading experience.

# Running the server: background sessions, control verbs, and `doctor`

`zigbase serve` normally blocks in the foreground for as long as it runs. This page covers
everything around that: detaching it into the background, the `stop`/`status`/`logs` verbs
that manage a detached session, the on-disk session contract those verbs read, throwaway
`--ephemeral` instances for test backends, and the `zigbase doctor` preflight command.

## 1. Foreground vs background

By default `zigbase serve` is a foreground process: it prints its own startup log directly
to the terminal and keeps running until it is killed (`Ctrl-C`, a signal, or the process
exiting). `--background` changes that: the process you invoked re-execs itself into a new,
detached process group with its stdout/stderr redirected to `<data-dir>/serve.log`, waits
for the new (child) process to answer its own `GET /api/health`, prints a short summary, and
exits **0** — only once the server is actually up. The child never recurses into
`--background` again itself (the parent sets an internal env var the child checks first; see
§5), and `--force` is consumed by the parent and not forwarded.

| Outcome | Trigger | What happens |
|---|---|---|
| Already running | a live session already owns the data dir, no `--force` | prints `serve: already running at <url> (pid <pid>)` (or a note that the session file could not be read) and does **not** spawn anything |
| Becomes ready | the spawned child answers `/api/health` within 30s | prints the summary below (or, with `--ephemeral`, the one JSON object — see §7) |
| Dies before ready | the child process exits, or becomes unobservable, before publishing `serve.json` | prints an error plus a bounded tail of `serve.log`; deletes an ephemeral tempdir this process allocated, if any |
| Times out | 30s elapse with the child still running but not yet healthy | sends `TERM` to the child's whole process group, waits briefly for it to exit, then reports the same error + log tail |

`--force` modifies the first row: instead of reporting "already running" and exiting 0, the
parent stops the existing session first (the same TERM→poll→escalate-to-KILL sequence as
`serve stop`) and then proceeds through the normal spawn path above.

On success (not `--ephemeral`), the parent prints:

```
serve: running in the background at http://127.0.0.1:8090 (pid 4242)
serve: admin UI: http://127.0.0.1:8090/_/
serve: log file: /abs/zb_data/serve.log
serve: manage:   zigbase serve stop | status [--json] | logs [--follow]
```

Any failure path exits **1**.

## 2. Control verbs

`zigbase serve stop | status [--json] | logs [--json] [--follow|-f]`, each taking `[--data-dir PATH]`
(env `ZIGBASE_DATA_DIR`, default `./zb_data`) — every verb resolves its target session from
the data dir exactly like `serve` itself.

**`serve stop`** — sends `SIGTERM` to the session's pid, polls the session flock (not the
pid — see §3 for why) for up to 5s, escalates to `SIGKILL` if it's still held, then sweeps
the leftover session file. **Idempotent**: both "I stopped it" and "nothing was running"
print a message and exit **0**. The one non-idempotent case is a session caught **`.starting`**
(the flock is held but `serve.json` hasn't been published yet — the pid is unknowable) —
that prints a retry hint and exits **1**, because nothing was actually stopped.

**`serve status [--json]`** — a single snapshot read; it never polls or blocks, so it can
report a session mid-startup and let the caller retry. Three states, exit code included:

| State | Meaning | Exit |
|---|---|---|
| not running | no live session (a stale `serve.json` left by a `kill -9` is swept here) | 1 |
| starting | the flock is held, `serve.json` not yet published | 1 |
| running | a live, published session | 0 |

The `running` case re-probes `/api/health` right now (not a cached bit) and reports it as
`healthy`. See §4 for the exact JSON.

**`serve logs [--json] [--follow|-f]`** — prints `<data-dir>/serve.log`. Errors (exit **1**) if the
session is live but running in the **foreground** (its output is the terminal that started
it, not a file — only `--background` sessions write `serve.log`), or if the log file can't
be read (a >16 MiB file names itself for `tail -f` instead of being read whole). Without
`--follow`, prints and exits 0. With `--follow`, poll-tails the file every 200ms — a shrink
in size is treated as a `--force` restart's truncation and the fresh content is dumped from
the top — and exits 0 once the session's lock is no longer held.

`--json` keeps **only** the NDJSON records and drops every other line. This is not a no-op
even when the session runs with `--log-format json`: `serve.log` is a genuinely **mixed**
stream, because facil.io writes its own startup banner (`INFO: Listening on port …`,
`* Root pid: …`, the shutdown notice) straight to the file descriptor from C, never through
the log encoder. Filtering them out is what makes this work:

```sh
zigbase serve logs --json | jq -r 'select(.level=="error") | .msg'
zigbase serve logs --json --follow | jq -c 'select(.scope=="http")'
```

It composes with `--follow` (the tail is filtered too). A record is recognised by shape — a
line whose first and last non-space characters are `{` and `}` — rather than by a full parse,
so a malformed record still reaches the consumer instead of being silently swallowed; that
would hide an encoder bug rather than surface it. If the file contains no records at all,
`--json` says so on stderr rather than printing nothing and looking broken: that almost
always means the session was started without `--log-format json`.

## 3. The session files

Two files live under the data dir:

- **`serve.lock`** — an empty file the serving process holds an exclusive, non-blocking
  `flock(2)` on for its whole lifetime. **Liveness IS the lock**: the kernel releases it the
  instant the holder dies, by any means, including `kill -9`. A control verb checks liveness
  with a non-blocking try-lock of its own — if the attempt **fails** (`EWOULDBLOCK`), a live
  process holds it; if it **succeeds**, nobody does, and the verb immediately releases
  (`LOCK_UN`) rather than holding it. This sidesteps the two failure modes of `kill(pid, 0)`:
  PID reuse reading as "alive", and a permission error (alive, just not ours) reading as
  "dead".

  `serve.lock` is **never deleted** — `stop`/sweep only remove `serve.json`. Unlinking a file
  another process still holds an `flock` on does **not** release that lock; it only detaches
  the name from the still-locked inode, so a `create` racing right behind the unlink would
  open a brand-new inode and take a *second*, independent lock under the same name — two
  "live" locks for one session defeats the whole liveness scheme. An empty `serve.lock` left
  behind after a session ends is therefore normal and harmless; `serve`'s own startup already
  handles "the file exists, nobody holds it".

- **`serve.json`** — the session facts, written atomically (temp file + rename) and **only
  after** the server has answered its own `/api/health` — so its appearance doubles as the
  `--background` parent's readiness handshake. Treat it as **read-only**: `serve` owns it,
  tooling reads it.

| Field | Meaning |
|---|---|
| `version` | wire-schema version (currently `1`). A mismatch (or unparseable content) reads as "no session", never a crash |
| `pid` | the serving process's own pid |
| `host` | the session's `--http-host` |
| `port` | the session's listening port |
| `url` | `http://<dialable host>:<port>` — a wildcard bind (`0.0.0.0`, `::`, `[::]`) is rewritten to `127.0.0.1` here, since nothing can *connect* "to" an unspecified address even though the server legitimately listens on all of them |
| `data_dir` | the absolute data-dir path |
| `background` | whether this session is running detached |
| `ephemeral` | whether this session owns a tempdir it will delete on clean shutdown |
| `started_at` | `YYYY-MM-DDTHH:MM:SSZ`, UTC |

```json
{
  "version": 1,
  "pid": 4242,
  "host": "127.0.0.1",
  "port": 8090,
  "url": "http://127.0.0.1:8090",
  "data_dir": "/abs/zb_data",
  "background": true,
  "ephemeral": false,
  "started_at": "2026-08-08T12:34:56Z"
}
```

## 4. `serve status --json`

Three possible response objects, each terminated by a newline. **`running` and `starting`
are always present** in every one of them, so a consumer never needs a null-check dance to
tell them apart:

```jsonc
// No session: exit 1
{"running":false,"starting":false}

// Starting (flock held, serve.json not yet published): exit 1
{"running":false,"starting":true}

// Running: exit 0
{"running":true,"starting":false,"pid":4242,"host":"127.0.0.1","port":8090,
 "url":"http://127.0.0.1:8090","data_dir":"/abs/zb_data","background":true,
 "ephemeral":false,"started_at":"2026-08-08T12:34:56Z","healthy":true}
```

`healthy` is a live re-probe of `/api/health` taken at the moment `status` runs, not a
cached value — a session that is up but degraded (or mid-shutdown) still reports `running:
true` with `healthy: false`, which is a real, reportable state, not "nothing running".

## 5. Agent auto-detection

Starting `zigbase serve` from inside a detected AI coding-agent session **backgrounds it
automatically** — an agent that runs a blocking foreground command has no way to send further
input to that shell, so a blocking `serve` would otherwise hang the whole session. Detection
is env-var checks only (no process-ancestry sniffing, no interactive/hybrid heuristics — a
Warp-the-*terminal* false positive was upstream's first post-release fix for this feature in
Astro, which this design avoids by construction):

| Env var | Detected as |
|---|---|
| `CLAUDECODE` | Claude Code |
| `CODEX_THREAD_ID` | OpenAI Codex |
| `GEMINI_CLI` | Gemini CLI |
| `CODEIUM_EDITOR_APP_ROOT` | Windsurf |
| `AIDER_API_KEY` | Aider |
| `OZ_RUN_ID` | Warp agent |
| `AMP_CURRENT_THREAD_ID` | Amp |
| `AUGMENT_AGENT` | Auggie |
| `QWEN_CODE` | Qwen Code |
| `ANTIGRAVITY_AGENT` | Antigravity |
| `PI_CODING_AGENT` | Pi |
| `OPENCODE` | OpenCode |
| `CRUSH` | Crush |
| `CURSOR_TRACE_ID` **together with** `PAGER` == `head -n 10000 \| cat` | Cursor agent |
| `AGENT` | agent (`AGENT` env — the emerging generic convention Crush and Amp also set) |
| `AI_AGENT` | agent (`AI_AGENT` env) |

An **empty value never counts** — an exported-but-unset shell variable (`export FOO=`) is not
a signal, so `GEMINI_CLI=""` does not trigger detection. `CURSOR_TRACE_ID` alone is the
interactive Cursor *terminal*, not the agent — only the trace id **plus** the agent-mode
`PAGER` rewrite counts.

On detection, the parent prints:

```
serve: Claude Code environment detected — starting in the background (set ZIGBASE_SERVE_BACKGROUND=0 to disable)
```

### Precedence (five levels, highest first)

1. **`ZIGBASE_SERVE_BACKGROUND_CHILD`** (internal — see below) — if set, this process is a
   re-exec'd child and runs the plain foreground path, full stop. Beats even an explicit
   `--background` on its own argv, because the parent already stripped that flag before
   re-exec'ing.
2. **`--background`** (explicit flag) — always backgrounds, with no provider attribution.
3. **`--ignore-lock`** — suppresses auto-detection entirely, even with a known agent env
   present (see §6).
4. **`ZIGBASE_SERVE_BACKGROUND`** (user-facing opt-out/opt-in) — `"1"` forces background;
   **any other value — including empty** — disables the automatic backgrounding a detected
   agent environment would otherwise trigger.
5. **`detectAgent()`** — backgrounds (with provider attribution) only if one of the table
   entries above matches. Otherwise: foreground, as always.

### The two environment variables

- **`ZIGBASE_SERVE_BACKGROUND`** — the user-facing knob. `1` forces `serve` into the
  background; any other value disables auto-detection. Documented in the README and
  `zigbase help`.
- **`ZIGBASE_SERVE_BACKGROUND_CHILD`** — **internal only.** Set by the `--background` parent
  on the environment of the re-exec'd child so the child runs the plain foreground path
  instead of trying to background itself again. Do not set this yourself.

These are deliberately **two separate variables**, not one flag doing double duty: if opting
out of auto-backgrounding and marking "this is the re-exec'd child" were the same variable,
a user opting out would also look, to the child's own environment read, like the recursion
guard — corrupting the `background` field the child publishes into its own `serve.json`. Two
variables keep the recursion signal and the user's own preference independently readable.

## 6. Duplicate instances and `--ignore-lock`

Two `serve` processes can't own the same data dir at once: `serve` takes a non-blocking
exclusive lock on `<data-dir>/serve.lock` at startup (see §3), and a second attempt against a
data dir a live session already holds is refused outright:

```
refusing to start: another zigbase serve session already owns the data dir '/abs/zb_data'.
Inspect it with `zigbase serve status`, stop it with `zigbase serve stop`, or start an
untracked instance with `zigbase serve --ignore-lock`.
```

That failure propagates as an uncaught error, so the process exits non-zero.

**`--ignore-lock`** is the escape hatch: it starts an **untracked** instance — no flock is
taken, no `serve.json` is written — and prints a warning saying so. Consequences:

- The instance is **invisible** to `serve status`/`stop`/`logs` against that data dir —
  there is nothing on disk for them to find.
- Nothing prevents a second `--ignore-lock` instance (or a normal one) from also opening the
  **same** SQLite database concurrently; you are opting out of the very mechanism that
  exists to prevent that, so treat it as a deliberate, supervised choice (e.g. a process
  manager that already tracks this instance itself), not a routine flag.
- **`--ignore-lock` cannot be combined with `--background`**: an untracked instance publishes
  no `serve.json` for the `--background` parent's readiness handshake to watch for, so the
  parser refuses the combination in either flag order (a usage error, exit 1) rather than
  hanging the parent for 30s waiting for a signal that will never come.

## 7. `serve --ephemeral`

`--ephemeral` is a throwaway instance for tests and scripts: on readiness it prints exactly
one JSON object to stdout — `{"url", "port", "data_dir", "pid"}`, in that field order — and
nothing else.

**Composition rule with `--data-dir`/`--http-port`**: `--ephemeral` fills in *only* what you
did not already pass yourself. Pass neither, and it allocates a fresh temp directory (under
`$TMPDIR`, or `/tmp`) and asks the OS for a free port. Pass `--data-dir`, and that directory
is used as-is (no tempdir is allocated). Pass `--http-port`, and that port is used as-is (no
free-port probe). This is what lets `--ephemeral` compose cleanly with `--background`: the
parent resolves both, then re-execs the child with the resolved values explicit on its argv,
so the child never independently re-allocates a *different* tempdir or port than the one the
parent is watching.

**As a test backend from a shell script:**

```sh
result=$(zigbase serve --background --ephemeral)
url=$(jq -r .url <<<"$result")
data_dir=$(jq -r .data_dir <<<"$result")

# ... point your test suite at "$url" ...

zigbase serve stop --data-dir "$data_dir"   # or: kill "$(jq -r .pid <<<"$result")"
```

Without `--background`, `--ephemeral` alone still prints the same JSON object once ready,
but the process stays in the foreground and keeps serving until you kill it — useful
interactively; `--background --ephemeral` together is the pattern for a script, since the
parent exits the moment the JSON line is available.

### Cleanup (four rules)

1. **Clean shutdown** (`serve stop`, `SIGTERM`, or the process exiting normally) — the
   serving process's own deferred cleanup deletes the tempdir as part of its regular
   teardown.
2. **`--background` handoff failure** (the child dies, or never becomes ready, before the
   30s deadline) — the **parent** deletes the tempdir itself, since it allocated it and the
   child never got a chance to run its own cleanup.
3. **`--background` timeout** — the parent sends `TERM` to the child's whole process group,
   waits a bounded window for it to actually exit (so it can close its own SQLite/log files
   first), then deletes the tempdir.
4. **A `kill -9`'d running session** bypasses every graceful-shutdown path above, so its
   tempdir is left on disk — **a `kill -9`'d tempdir is left for the OS to reap; there is no
   background GC.** The next `serve stop`/`serve status` invocation *against that same data
   dir* will notice the dead session and sweep it (including its tempdir) at that point, but
   nothing runs periodically to look for orphans on its own — if nothing ever inspects that
   data dir again, the tempdir sits until the OS's own `/tmp` cleanup (or a human) removes it.

## 8. `zigbase doctor`

`zigbase doctor [--production] [--json] [--data-dir PATH]` runs nine fixed, ordered checks
over a deployment and reports one finding per check (or per `@public` rule, for the rules
check) plus a summary.

| # | Check id | What it reads | Default severity | `--production` severity |
|---|---|---|---|---|
| 1 | `jwt-secret-persisted` | `ZIGBASE_JWT_SECRET` length; `<data-dir>/.jwt_secret`'s length + file mode | short env secret → **error**; nothing set/persisted → **warn**; persisted but not mode `0600` → **warn** | short env secret → **error** (unchanged); nothing persisted → **error**; wrong mode → **error** |
| 2 | `public-rules-enumerated` | every collection's list/view/create/update/delete rule, for the `@public` sentinel (one finding per rule, named `<collection>.<op>Rule`) | read rule (`list`/`view`) `@public` → **warn**; write rule (`create`/`update`/`delete`) `@public` → **warn** | read rule → **warn** (unchanged, a public blog is legitimate); write rule → **error** |
| 3 | `insecure-cookies-off` | whether cookies are `Secure` | not secure → **warn** | not secure → **error** |
| 4 | `host-binding` | `http_host` | wildcard bind (`0.0.0.0`/`::`/`[::]`) → **warn**; loopback → **ok** | wildcard bind → **ok**; loopback → **warn** |
| 5 | `trust-proxy-consistency` | `trust_proxy`, `http_host`, `public_url` | `trust_proxy` on + wildcard bind → **warn**; `https` `public_url` + loopback bind + `trust_proxy` off → **warn** (both modes) | `trust_proxy` on + wildcard bind → **error**; the `public_url`/loopback case stays **warn** |
| 6 | `mailer-configured` | `sendmail_command`, `smtp_host`, `smtp_username`, resolved SMTP TLS | nothing configured → **warn**; SMTP AUTH resolving to no transport security → **warn** | nothing configured → **error**; cleartext SMTP AUTH → **error** |
| 7 | `migrations-applied` | the `_migrations` ledger vs. the binary's compiled `.migrations` | pending → **error** (both modes); orphaned (applied, no longer declared) → **warn** (both modes) | same as default |
| 8 | `data-dir-writable` | a throwaway probe file written then deleted under the data dir | not writable → **error** (both modes) | same as default |
| 9 | `legacy-password-hashes` | count of auth-collection records whose `passwordHash` still matches `$zblegacy$%`, summed across every auth collection (including `_superusers`) | any count > 0 → **warn** (both modes) | same as default — legacy hashes are a normal, self-healing transitional state (each one re-hashes on its account's next successful login), never a misconfiguration, so this never escalates |

A DB-backed check (2, 7, or 9) that cannot open the database reports **`skipped`** instead of
a false `ok` or `error` — a check that could not run is reported, not scored either way.

Prose output — here `ZIGBASE_HTTP_HOST=0.0.0.0` is the one thing this deployment gets flagged
for (a wildcard bind, harmless and even expected in a container, but worth a second look on a
bare-metal dev box); everything else about it is clean, so `host-binding` is the only
non-`ok` line and the summary reads "1 warning":

```sh
$ ZIGBASE_JWT_SECRET=a-strong-development-only-secret-key-value \
  ZIGBASE_SMTP_HOST=smtp.example.com ZIGBASE_HTTP_HOST=0.0.0.0 \
  zigbase doctor --data-dir ./zb_data
ok       jwt-secret-persisted: JWT secret supplied via ZIGBASE_JWT_SECRET
ok       public-rules-enumerated: no @public rules
ok       insecure-cookies-off: cookies are Secure
warn     host-binding: http_host '0.0.0.0' is a wildcard bind
ok       trust-proxy-consistency: trust_proxy is consistent with http_host and public_url
ok       mailer-configured: mailer configured
ok       migrations-applied: all declared migrations applied
ok       data-dir-writable: data dir './zb_data' is writable
ok       legacy-password-hashes: no legacy password hashes
9 checks, 0 errors, 1 warning, 0 skipped
```

`--json` instead: one compact object per finding, then exactly one summary object carrying
`"summary":true` — a **content** discriminator (not a positional one), so a consumer reading
the stream lazily can identify the summary without waiting for EOF (same deployment as above):

```sh
$ ZIGBASE_JWT_SECRET=a-strong-development-only-secret-key-value \
  ZIGBASE_SMTP_HOST=smtp.example.com ZIGBASE_HTTP_HOST=0.0.0.0 \
  zigbase doctor --json --data-dir ./zb_data
{"check":"jwt-secret-persisted","severity":"ok","subject":null,"message":"JWT secret supplied via ZIGBASE_JWT_SECRET"}
{"check":"public-rules-enumerated","severity":"ok","subject":null,"message":"no @public rules"}
{"check":"insecure-cookies-off","severity":"ok","subject":null,"message":"cookies are Secure"}
{"check":"host-binding","severity":"warn","subject":null,"message":"http_host '0.0.0.0' is a wildcard bind"}
{"check":"trust-proxy-consistency","severity":"ok","subject":null,"message":"trust_proxy is consistent with http_host and public_url"}
{"check":"mailer-configured","severity":"ok","subject":null,"message":"mailer configured"}
{"check":"migrations-applied","severity":"ok","subject":null,"message":"all declared migrations applied"}
{"check":"data-dir-writable","severity":"ok","subject":null,"message":"data dir './zb_data' is writable"}
{"check":"legacy-password-hashes","severity":"ok","subject":null,"message":"no legacy password hashes"}
{"summary":true,"production":false,"checks":9,"errors":0,"warnings":1,"skipped":0}
```

**Check ids never change. Match on the id, never on the message text — messages are free to
improve.**

**Database mutation:** `doctor` opens the database read-mostly to check public rules,
migration status, and legacy password hashes; the *one* write it performs is creating the
`_migrations` ledger table if it is missing — the same write `migrate status` already makes
on a fresh database. It changes nothing else, and it never fails outright: an unopenable
database or an unwritable data dir is reported as a finding (`skipped` on the three
DB-backed checks, `error` on `data-dir-writable`), not a crash.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | fully clean — no error- or warning-severity findings |
| `1` | at least one error-severity finding |
| `2` | ran correctly, **warnings only** (something needs judgment, but nothing is broken) |

A `skipped` finding never scores by itself — it doesn't push the exit code toward either 1 or 2.

```sh
zigbase doctor --production && deploy                              # strict: warnings block
zigbase doctor --production; case $? in 0|2) deploy ;; esac        # tolerant: warnings report only
```

Write the tolerant gate as the `case` above, never as `test $? -ne 1`. `-ne 1` reads as
"anything but an error", but it would also proceed on a usage error or any future exit code
the program-wide `0`–`3` scheme adds later — treating a code `doctor` never promised as
success. Enumerating the two codes that actually mean "no errors" is the only spelling that
stays correct as the scheme grows.

## 9. Out of scope

- **No log rotation.** `serve.log` is truncated once, at the start of each `--background`
  session — a long-running session's own log just grows. Put it behind your platform's
  normal log rotation (`logrotate`, journald, a container runtime's own log driver) if that
  matters to you.
- **No restart-on-crash, no supervisor process.** `--background` is exactly one detached
  process; if it crashes, nothing restarts it. Use a real process supervisor (systemd,
  Docker's `--restart` policy, etc.) for that guarantee.
- **No native Windows support.** Every piece of this page — `--background`, `stop`/`status`/
  `logs` — refuses outright on Windows with a pointer to the official Docker image. See
  [docs/docker.md](docker.md) and [KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md).

## See also

- [docs/deployment.md](deployment.md) — systemd, Docker, hosted deployment, backups, upgrades, and rollback.
- [docs/framework.md](framework.md) — embedding ZigBase as a Zig library; `runCli` is what
  gives a consumer binary this same `serve`/`doctor`/control-verb surface.
- [docs/docker.md](docker.md) — the official image, data-volume ownership, and healthchecks
  for deploying a `serve` session as a container instead of `--background`.
- [KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md) — current platform and scheduler caveats,
  including the Windows gap this page's §9 points at.
