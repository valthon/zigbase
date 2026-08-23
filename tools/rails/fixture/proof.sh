#!/usr/bin/env bash
# Boots the fixture app for real and exercises every endpoint with curl,
# writing an exact request/response transcript to PROOF.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/bookclub_api"
OUT="$ROOT/PROOF.md"
RUBY="mise exec ruby@4.0.1 --"
rb() { mise exec ruby@4.0.1 -- "$@"; }
PORT="${PORT:-3131}"
BASE="http://127.0.0.1:$PORT"
TMP="$ROOT/.prooftmp"

rm -rf "$TMP"; mkdir -p "$TMP"
: > "$OUT"

say() { printf '%s\n' "$*" >> "$OUT"; }

# --- shell helper: run a command, record it verbatim with its output ---------
run() {
  local title="$1"; shift
  say ""
  say "### $title"
  say ""
  say '```console'
  say "\$ $*"
  ( cd "$APP" && eval "$@" ) >> "$OUT" 2>&1
  say '```'
}

# --- placeholder resolution --------------------------------------------------
#
# Request paths and header values are written with {{placeholders}}. They are
# RESOLVED here just before curl runs, and RECORDED unresolved. That way the
# frozen cases.json is inherently parameterized -- no post-hoc redaction of
# tokens that were already baked into a literal.

declare -A SUBST

resolve() {
  local s="$1" k
  for k in "${!SUBST[@]}"; do s="${s//"$k"/${SUBST[$k]}}"; done
  printf '%s' "$s"
}

CASE_N=0
CASES_DIR="$TMP/cases"
mkdir -p "$CASES_DIR"

# --- HTTP helper -------------------------------------------------------------
# req <label> <method> <path-with-placeholders> <actor> [curl args...]
#
# Optional env for one call: VOLATILE="dot.path=placeholder|..."  CHAIN=name  STATEFUL=1
req() {
  local label="$1" method="$2" path="$3" actor="$4"; shift 4
  CASE_N=$((CASE_N + 1))
  local n=$CASE_N

  local rpath; rpath="$(resolve "$path")"
  local -a rargs=()
  local a
  for a in "$@"; do rargs+=("$(resolve "$a")"); done

  local code
  code="$(curl -sS -X "$method" "$BASE$rpath" -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "${rargs[@]}")"

  # PROOF.md shows the RESOLVED command -- it is meant to be a real, pasteable
  # transcript. cases.json keeps the parameterized form.
  local shown="curl -i -X $method '$BASE$rpath'"
  for a in "${rargs[@]}"; do
    case "$a" in
      -*) shown+=" $a" ;;
      *)  shown+=" '$a'" ;;
    esac
  done

  say ""
  say "#### $label"
  say ""
  say "\`$method $path\` — auth: ${actor} — **status $code**"
  say ""
  say '```console'
  say "\$ $shown"
  say ""
  grep -iE '^(HTTP/[0-9.]+ |content-type:|content-disposition:|content-length:|location:)' "$TMP/h" | tr -d '\r' >> "$OUT"
  say ""
  if grep -qiE '^content-type: *application/json' "$TMP/h"; then
    rb ruby -rjson -e 'b = JSON.parse(STDIN.read); if b.is_a?(Hash) && b.key?("traces") then b["traces"] = "<#{b["traces"].values.sum(&:length)} backtrace frames elided>" end; print JSON.pretty_generate(b)' < "$TMP/b" >> "$OUT" 2>/dev/null \
      || cat "$TMP/b" >> "$OUT"
    say ""
  else
    say "<binary body, $(wc -c < "$TMP/b") bytes, sha256 $(sha256sum < "$TMP/b" | cut -d' ' -f1)>"
  fi
  say '```'

  # --- record the case ---------------------------------------------------
  : > "$TMP/args"
  for a in "$@"; do printf '%s\0' "$a" >> "$TMP/args"; done

  {
    printf 'n\0%s\0' "$n"
    printf 'label\0%s\0' "$label"
    printf 'method\0%s\0' "$method"
    printf 'path\0%s\0' "$path"
    printf 'actor\0%s\0' "$actor"
    printf 'observed_status\0%s\0' "$code"
    printf 'volatile\0%s\0' "${VOLATILE:-}"
    printf 'chain\0%s\0' "${CHAIN:-}"
    printf 'stateful\0%s\0' "${STATEFUL:-0}"
  } > "$TMP/meta"

  rb ruby "$ROOT/record_case.rb" "$TMP/meta" "$TMP/args" "$TMP/h" "$TMP/b" \
     "$CASES_DIR/$(printf '%04d' "$n").json"

  unset VOLATILE CHAIN STATEFUL

  LAST_BODY="$TMP/b"
  LAST_CODE="$code"
  echo "$(printf '%2d' "$n") $label -> $code"
}

sqlq() {
  ( cd "$APP" && $RUBY bin/rails runner "$1" 2>/dev/null )
}

# =============================================================================
say "# PROOF.md — bookclub_api fixture, observed from a real boot"
say ""
say "Every block below is a verbatim command and its verbatim output. Nothing"
say "here is hand-written: the transcript is produced by \`proof.sh\`, which"
say "boots the application with \`bin/rails server\` and drives it over HTTP."
say ""
say "- app: \`railsgen/bookclub_api\`"
say "- ruby 4.0.1 / Rails 8.1.3.1 / SQLite"
say "- server: \`bin/rails server -p $PORT -b 127.0.0.1\` (RAILS_ENV=development)"
say ""
say "> Runtime-created rows (memberships, notifications, posts, blobs) carry"
say "> wall-clock timestamps, so the HTTP transcript is not byte-stable. The"
say "> **frozen** database is the pristine \`db:seed\` state, which is; \`db:seed\`"
say "> is re-run at the end of this transcript to restore it, and the extractor"
say "> output under \`railsgen/export/\` is taken from that restored state."
say ""
say "---"
say ""
say "## 1. Build the database"

say ""
say "\`db:migrate:reset\` (drop + create + **run every migration**) is the canonical"
say "rebuild for this fixture. Plain \`db:migrate\` against a missing database does"
say "NOT run the migrations -- Rails loads \`db/schema.rb\` instead, and the raw SQL"
say "triggers and the view are silently lost. That is demonstrated below."

run "Rebuild by actually running the migrations" "$RUBY bin/rails db:migrate:reset 2>&1 | tail -n 20"
run "Seed" "$RUBY bin/rails db:seed"

say ""
say "---"
say ""
say "## 2. Traps at the storage layer"

run "The SQLite triggers and view exist in sqlite_master (they are NOT in db/schema.rb)" \
  "$RUBY bin/rails runner ../checks/catalog.rb"

run "grep db/schema.rb for the trigger: absent" \
  "grep -c 'posts_count_after_insert' db/schema.rb; echo '(0 matches = triggers are invisible to the :ruby schema format)'"

say ""
say "The consequence, demonstrated: rebuilding the database with plain \`db:migrate\`"
say "loads \`db/schema.rb\` instead of running the migrations, and the result has NO"
say "triggers and NO view. That is why \`db:migrate:reset\` is the rebuild command for"
say "this fixture, and why an importer must read \`sqlite_master\`, not \`schema.rb\`."

run "rm the database, then plain db:migrate -> schema.rb is loaded, triggers are GONE" \
  "rm -f storage/development.sqlite3 storage/development.sqlite3-wal storage/development.sqlite3-shm; $RUBY bin/rails db:migrate 2>&1 | tail -n 5; echo '--- sqlite_master after db:migrate ---'; $RUBY bin/rails runner ../checks/catalog.rb"

run "db:migrate:reset restores them" \
  "$RUBY bin/rails db:migrate:reset 2>&1 | tail -n 3; echo '--- sqlite_master after db:migrate:reset ---'; $RUBY bin/rails runner ../checks/catalog.rb"

run "Re-seed" "$RUBY bin/rails db:seed"

run "default_scope hides the archived club from the model, not from SQL" \
  "$RUBY bin/rails runner ../checks/default_scope.rb"

run "users.phone is ciphertext in SQL, plaintext through the model" \
  "$RUBY bin/rails runner ../checks/encryption.rb"

run "clubs.posts_count is maintained by the trigger, not by Rails" \
  "$RUBY bin/rails runner ../checks/posts_count.rb"

run "STI and polymorphic rows" \
  "$RUBY bin/rails runner ../checks/sti.rb"

# --- boot the server ---------------------------------------------------------
#
# The database runs in WAL mode, so a hard-killed process can leave a
# `-wal`/`-shm` pair behind that a later run would pick up alongside a
# recreated database file. Start from a checkpointed database with no
# sidecars, and refuse to boot onto a port something else already holds --
# otherwise `bin/rails server` fails to bind, `/up` is answered by the stale
# process, and the whole transcript is recorded against the wrong database.
echo "booting server on $PORT ..."

if curl -sS -o /dev/null --max-time 2 "$BASE/up" 2>/dev/null; then
  echo "FATAL: something is already listening on $PORT; refusing to run." >&2
  exit 1
fi

rm -f "$APP/storage/development.sqlite3-wal" "$APP/storage/development.sqlite3-shm"
( cd "$APP" && $RUBY bin/rails server -p "$PORT" -b 127.0.0.1 > "$TMP/server.log" 2>&1 & echo $! > "$TMP/pid" )
for _ in $(seq 1 60); do
  if curl -sS -o /dev/null "$BASE/up" 2>/dev/null; then break; fi
  sleep 1
done
curl -sS -o /dev/null -w 'health /up -> %{http_code}\n' "$BASE/up"

cleanup() {
  if [ -f "$TMP/pid" ]; then
    pkill -P "$(cat "$TMP/pid")" 2>/dev/null
    kill "$(cat "$TMP/pid")" 2>/dev/null
  fi
  pkill -f "puma.*$PORT" 2>/dev/null

  # Wait for the listener to actually go away. A blind `sleep` here is how a
  # surviving server ends up holding the database open while the next phase
  # drops and rebuilds it.
  local i
  for i in $(seq 1 30); do
    curl -sS -o /dev/null --max-time 1 "$BASE/up" 2>/dev/null || return 0
    sleep 1
  done
  echo "WARNING: server on $PORT did not exit" >&2
}
trap cleanup EXIT

say ""
say "---"
say ""
say "## 3. HTTP transcript"
say ""
say 'Every request below was issued against the running server. `JSON` bodies are'
say 'pretty-printed; headers are shown filtered to the status line and content type.'

JSON=(-H 'Content-Type: application/json')

say ""
say "### 3.1 Signup and login"

JSON=(-H 'Content-Type: application/json')

VOLATILE="data.id=user:eve" CHAIN=signup-eve \
req "Signup (public, no token)" POST /api/v1/users "none" \
  "${JSON[@]}" -d '{"user":{"email":"eve@example.test","password":"eve-password-5","display_name":"Eve Outsider","phone":"+1-555-0199"}}'

req "Signup with an invalid email and a too-short display name (custom 422 envelope)" POST /api/v1/users "none" \
  "${JSON[@]}" -d '{"user":{"email":"not-an-email","password":"x","display_name":"E"}}'

req "Login with the wrong password" POST /api/v1/sessions "none" \
  "${JSON[@]}" -d '{"email":"ada@example.test","password":"wrong"}'

login() { # login <actor> <email> <password> <label> [volatile] [chain] [stateful]
  local actor="$1" email="$2" password="$3" label="$4"
  VOLATILE="${5:-}" CHAIN="${6:-}" STATEFUL="${7:-0}" \
  req "$label" POST /api/v1/sessions "none" \
    "${JSON[@]}" -d "{\"email\":\"$email\",\"password\":\"$password\"}"
  local token; token="$(rb ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","token")' < "$TMP/b")"
  SUBST["{{token:$actor}}"]="$token"
  printf '%s\t%s\n' "$token" "token:$actor" >> "$TMP/tokens.tsv"
}

login ada   ada@example.test   ada-password-1   "Login as ada (club owner / admin)"
login brian brian@example.test brian-password-2 "Login as brian (member of both clubs)"
login coral coral@example.test coral-password-3 "Login as coral (owner of the PRIVATE club)"
login dane  dane@example.test  dane-password-4  "Login as dane (member of the archived club only)"
# eve exists only because case 1 created her, and her id is runtime-assigned.
login eve   eve@example.test   eve-password-5   "Login as eve (just signed up, member of nothing)" \
      "data.user.id=user:eve" signup-eve 1

say ""
say "Tokens are an HMAC-SHA256 over the user id keyed by the fixed \`secret_key_base\`,"
say "so they are stable literals for this fixture. They appear in \`http/cases.json\`"
say "only as \`{{token:<actor>}}\` placeholders."

say ""
say "### 3.2 Clubs — the custom \`{data, meta}\` envelope"

req "List clubs (note: total=2, the archived club is silently absent)" GET /api/v1/clubs "none"
req "List clubs, page 2 of per_page=1" GET "/api/v1/clubs?page=2&per_page=1" "none"
req "Show a club by SLUG" GET /api/v1/clubs/morning-pages "none"
req "Show the ARCHIVED club by slug -> 404, although the row exists" GET /api/v1/clubs/retired-readers "none"

req "Update a club unauthenticated -> 401" PATCH /api/v1/clubs/morning-pages "none" \
  "${JSON[@]}" -d '{"club":{"name":"Hijacked"}}'
req "Update a club as a NON-owner -> 403" PATCH /api/v1/clubs/morning-pages "brian" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:brian}}" -d '{"club":{"name":"Hijacked"}}'
req "Update a club as the OWNER -> 200" PATCH /api/v1/clubs/morning-pages "ada" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:ada}}" -d '{"club":{"name":"Morning Pages (renamed)"}}'
req "Update a club with an invalid enum value -> 422" PATCH /api/v1/clubs/morning-pages "ada" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:ada}}" -d '{"club":{"visibility":"secret_club"}}'

say ""
say "### 3.3 Private-club reads — 404, not 403"

req "Private club posts, unauthenticated -> 404" GET /api/v1/clubs/night-owls/posts "none"
STATEFUL=1 \
req "Private club posts as eve (authenticated NON-member) -> 404" GET /api/v1/clubs/night-owls/posts "eve" \
  -H "Authorization: Bearer {{token:eve}}"
req "Private club posts as brian (member) -> 200" GET /api/v1/clubs/night-owls/posts "brian" \
  -H "Authorization: Bearer {{token:brian}}"
req "Private club posts as coral (owner) -> 200" GET /api/v1/clubs/night-owls/posts "coral" \
  -H "Authorization: Bearer {{token:coral}}"
req "Public club posts, unauthenticated -> 200" GET /api/v1/clubs/morning-pages/posts "none"

say ""
say "### 3.4 Join a club — one explicit transaction writing two tables"

run "notifications BEFORE the join" "$RUBY bin/rails runner ../checks/notifications.rb"

VOLATILE="data.id=membership:new" CHAIN=membership-join \
req "Join the private club as dane -> 201 (Membership + owner Notification, atomically)" \
  POST /api/v1/clubs/night-owls/memberships "dane" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:dane}}" -d '{"role":"reader"}'

run "notifications AFTER the join (the owner, coral=3, got membership.created)" "$RUBY bin/rails runner ../checks/notifications.rb"

CHAIN=membership-join STATEFUL=1 \
req "Join the SAME club again -> 422 (unique index + validation)" \
  POST /api/v1/clubs/night-owls/memberships "dane" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:dane}}" -d '{"role":"reader"}'

run "ROLLBACK PROOF: identical to the block above -- the failed join wrote neither row" "$RUBY bin/rails runner ../checks/notifications.rb"

CHAIN=membership-join STATEFUL=1 \
req "dane can now read the private club he just joined -> 200" GET /api/v1/clubs/night-owls/posts "dane" \
  -H "Authorization: Bearer {{token:dane}}"

say ""
say "### 3.5 Posts — creation, the custom validation envelope, and the trigger"

run "clubs.posts_count BEFORE creating a post" "$RUBY bin/rails runner ../checks/posts_count.rb"

VOLATILE="data.id=post:new" CHAIN=post-lifecycle \
req "Create a post -> 201" POST /api/v1/clubs/morning-pages/posts "brian" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:brian}}" -d '{"post":{"title":"Reading Aloud","body":"On the pleasures of being read to."}}'
NEWPOST="$(rb ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","id")' < "$TMP/b")"
SUBST["{{post:new}}"]="$NEWPOST"

run "clubs.posts_count AFTER creating a post (bumped by the SQLite trigger)" "$RUBY bin/rails runner ../checks/posts_count.rb"

req "Create a post with a blank title -> 422 custom error envelope" POST /api/v1/clubs/morning-pages/posts "brian" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:brian}}" -d '{"post":{"title":"","body":"no title"}}'

req "Create a published post with no body -> 422 (conditional validation)" POST /api/v1/clubs/morning-pages/posts "brian" \
  "${JSON[@]}" -H "Authorization: Bearer {{token:brian}}" -d '{"post":{"title":"Empty But Published","status":"published"}}'

req "Create a post with no auth -> 401" POST /api/v1/clubs/morning-pages/posts "none" \
  "${JSON[@]}" -d '{"post":{"title":"Anonymous","body":"nope"}}'

say ""
say "### 3.6 Publish — an ActiveJob side effect, observable because the adapter is \`:inline\`"

run "notifications BEFORE publish" "$RUBY bin/rails runner ../checks/published.rb"

CHAIN=post-lifecycle STATEFUL=1 \
req "Publish as a NON-author -> 403" PATCH "/api/v1/posts/{{post:new}}/publish" "ada" \
  -H "Authorization: Bearer {{token:ada}}"

VOLATILE="data.id=post:new" CHAIN=post-lifecycle STATEFUL=1 \
req "Publish as the author -> 200" PATCH "/api/v1/posts/{{post:new}}/publish" "brian" \
  -H "Authorization: Bearer {{token:brian}}"

run "notifications AFTER publish (written by PostPublishedNotificationJob, inline)" "$RUBY bin/rails runner ../checks/published.rb"

say ""
say "### 3.7 Active Storage — multipart upload and gated download"

CHAIN=post-lifecycle STATEFUL=1 \
req "Upload a cover for a post the caller does NOT own -> 403" POST "/api/v1/posts/{{post:new}}/cover" "ada" \
  -H "Authorization: Bearer {{token:ada}}" -F "cover=@$ROOT/upload_cover.png;type=image/png"

VOLATILE="data.blob_id=blob:new_id|data.key=blob:new_key" CHAIN=post-lifecycle STATEFUL=1 \
req "Upload a cover as the author -> 201 (multipart/form-data)" POST "/api/v1/posts/{{post:new}}/cover" "brian" \
  -H "Authorization: Bearer {{token:brian}}" -F "cover=@$ROOT/upload_cover.png;type=image/png"

req "Download the seeded cover of post 1 (public club) -> 200 image/png" GET /api/v1/posts/1/cover "none"

VOLATILE="data.blob_id=blob:private_id|data.key=blob:private_key" CHAIN=private-cover \
req "Upload a cover on a post in the PRIVATE club as its author -> 201" POST /api/v1/posts/3/cover "coral" \
  -H "Authorization: Bearer {{token:coral}}" -F "cover=@$ROOT/upload_cover.png;type=image/png"

CHAIN=private-cover STATEFUL=1 \
req "Download that private cover as eve (non-member) -> 404" GET /api/v1/posts/3/cover "eve" \
  -H "Authorization: Bearer {{token:eve}}"

CHAIN=private-cover STATEFUL=1 \
req "Download that private cover as brian (member) -> 200" GET /api/v1/posts/3/cover "brian" \
  -H "Authorization: Bearer {{token:brian}}"

run "Blobs on disk after the uploads" "$RUBY bin/rails runner ../checks/blobs.rb"

say ""
say "### 3.8 The \`scope\` + format-constrained route"

STATEFUL=1 req "Internal stats (defaults: internal=true, format=json)" GET /api/v1/internal/stats "none"
STATEFUL=1 req "Internal stats with an explicit .json format" GET /api/v1/internal/stats.json "none"
req "Internal stats with a format the constraint rejects -> routing failure" GET /api/v1/internal/stats.xml "none"

run "Cross-check the stats counts from a separate process" \
  "$RUBY bin/rails runner ../checks/stats_crosscheck.rb"

say ""
say "### 3.9 Not-found paths"

req "A post id that does not exist -> 404 custom envelope (rescue_from RecordNotFound)" GET /api/v1/posts/9999 "none"
req "A non-numeric post id -> no route matches the \`id: /\\d+/\` constraint" GET /api/v1/posts/abc "none"
req "A club slug that does not exist -> 404" GET /api/v1/clubs/no-such-club "none"

cleanup

say ""
say "---"
say ""
say "## 4. Restore the canonical frozen state"
say ""
say "The HTTP transcript above mutated the database. The canonical build for the"
say "frozen fixture is \`db:migrate:reset && db:seed\` from scratch, and it is"
say "byte-reproducible: every row value is a fixed literal (\`ar_internal_metadata\`"
say "included) and the seed ends with a \`VACUUM\` so the page layout is canonical"
say "instead of a function of the order pages happened to be freed."

run "Canonical rebuild" \
  "$RUBY bin/rails db:migrate:reset >/dev/null 2>&1; $RUBY bin/rails db:seed; rm -f storage/test.sqlite3 storage/test.sqlite3-wal storage/test.sqlite3-shm; sha256sum storage/development.sqlite3"

run "Do it again -- same bytes" \
  "$RUBY bin/rails db:migrate:reset >/dev/null 2>&1; $RUBY bin/rails db:seed >/dev/null; rm -f storage/test.sqlite3 storage/test.sqlite3-wal storage/test.sqlite3-shm; sha256sum storage/development.sqlite3"

say ""
say "Caveat worth recording: re-running \`db:seed\` **on top of** an existing"
say "database yields identical rows but a different file hash. SQLite keeps a file"
say "change counter and a schema cookie in the header that \`VACUUM\` does not reset."
say "Byte equality is a property of the from-scratch build, not of re-seeding."

say ""
say "---"
say ""
say "## 5. The extractor"

run "Assemble http/cases.json from the recorded run" \
  "cd .. && mkdir -p http && mise exec ruby@4.0.1 -- ruby -rjson -e 'puts JSON.generate(File.readlines(ARGV[0]).map { |l| l.chomp.split(\"\\t\") }.to_h)' '$TMP/tokens.tsv' > '$TMP/tokens.json' && mise exec ruby@4.0.1 -- ruby record_case.rb --assemble '$CASES_DIR' '$TMP/tokens.json' http/cases.json"

run "Extract observed metadata" \
  "$RUBY bin/rails runner ../tools_rails_export_source.rb -- --out ../export --taken-at 2024-01-15T09:00:00Z"

run "Extract a second time to a different directory" \
  "$RUBY bin/rails runner ../tools_rails_export_source.rb -- --out ../export_verify --taken-at 2024-01-15T09:00:00Z"

run "The two runs are byte-identical" \
  "cd .. && sha256sum export/*.json | sed 's|export/||' > /tmp/e1.sha && sha256sum export_verify/*.json | sed 's|export_verify/||' > /tmp/e2.sha && /usr/bin/diff /tmp/e1.sha /tmp/e2.sha && echo 'IDENTICAL' && cat /tmp/e1.sha"

say ""
say "---"
say ""
say "## 6. Frozen artifact inventory"

run "Files that make up the fixture" \
  "cd .. && rm -rf export_verify && find bookclub_api/app bookclub_api/config/routes.rb bookclub_api/db bookclub_api/storage checks export tools_rails_export_source.rb proof.sh upload_cover.png -type f | LC_ALL=C sort"

run "Seeded row counts (unscoped)" \
  "$RUBY bin/rails runner ../checks/inventory.rb"

echo "PROOF written to $OUT"
