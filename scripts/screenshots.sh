#!/usr/bin/env bash
#
# screenshots.sh — reproduce ALL marketing screenshots used on the site.
#
# CAPTURE PATH: REAL UI.
#   Every shot drives the ACTUAL ZigBase admin SPA (served at /_/) or the real
#   example frontends (Zigapagos builds served by the example binaries) — never a
#   static mock. Shots are 1280x800 desktop viewport with devicePixelRatio 2
#   (intrinsic 2560x1600 PNGs), color_scheme "light".
#
# OUTPUT (all under site/src/assets/screenshots/):
#   admin-dashboard.png            collections + records view (posts demo seed)
#   admin-login.png                /_/#/login
#   admin-new-collection-users.png schema editor: new `users` auth collection
#   admin-fields-listings.png      schema editor: `listings` fields populated
#   admin-rules-listings.png       API Rules tab with owner-scoped rules
#   admin-records-users.png        users records table after signup
#   admin-new-record-listing.png   record drawer filled (incl. photo file)
#   admin-records-listings.png     listings table with the created record
#   admin-oauth.png                Auth/OAuth2 tab of users (google provider)
#   example-blog-home.png          blog example: post list
#   example-blog-write.png         blog example: authed /write editor
#   example-golfsim-listings.png   golfsim example: listings browser (signed in)
#   example-golfsim-bookings.png   golfsim example: /bookings with a hold
#   example-plugins-browser.png    plugins example: authors + published posts
#
# REQUIREMENTS:
#   - Zig 0.16   (via `mise exec zig@0.16.0 -- zig ...`)
#   - Python 3.13 with Playwright + Chromium (via mise); Pillow is installed
#     on the fly if missing (for the generated sample photo)
#   - Node/npm via mise (the repo mise.toml pins node) for the example frontends
#
# USAGE:
#   ./scripts/screenshots.sh [all|dashboard|admin|examples]
#
#   all (default)  every screenshot
#   dashboard      admin-dashboard.png only
#   admin          the admin-UI tutorial flow (admin-*.png minus the dashboard)
#   examples       the example frontends (example-*.png)
#
# Everything runs against throwaway data dirs under a mktemp work dir which is
# removed at the end — the repo-root ./zb_data is never touched and nothing
# under the work dir is committed. Each server gets its own free port and is
# killed on exit.

set -euo pipefail

STAGE="${1:-all}"
case "$STAGE" in
  all|dashboard|admin|examples) ;;
  *) echo "usage: $0 [all|dashboard|admin|examples]" >&2; exit 1 ;;
esac
run_stage() { [ "$STAGE" = all ] || [ "$STAGE" = "$1" ]; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/site/src/assets/screenshots"
# Secret must be >= 32 bytes (enforced since the security hardening in #8). The
# value is throwaway — it only has to be consistent between `superuser create`
# and `serve`, and long enough to pass the strength check.
JWT_SECRET="${ZIGBASE_JWT_SECRET:-screenshots-dev-secret-not-for-production-use}"
EMAIL="admin@example.com"
PASSWORD='Password123!'

WORK="$(mktemp -d)"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

ZIG() { mise exec zig@0.16.0 -- zig "$@"; }
PY()  { mise exec python@3.13 -- python "$@"; }
NPM() { mise exec -- npm "$@"; }

pick_port() {
  PY -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_health() {
  local port=$1
  for _ in $(seq 1 120); do
    if curl -fs "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "ERROR: server on :$port did not become healthy" >&2
  exit 1
}

stop_server() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# jget <dotted.path>  — extract a value from JSON on stdin.
jget() {
  PY -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(d)
' "$1"
}

# api_json <port> <bearer-token-or-empty> <method> <path> [json-body]
api_json() {
  local port=$1 token=$2 method=$3 path=$4 data=${5:-}
  local args=(-fs -X "$method" "http://127.0.0.1:$port$path" -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$data" ] && args+=(-d "$data")
  curl "${args[@]}"
}

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Sample photo for the tutorial's file upload (stand-in for bay1.jpg).
# ---------------------------------------------------------------------------
PHOTO="$WORK/bay1.jpg"
if run_stage admin; then
if ! PY -c "import PIL" >/dev/null 2>&1; then
  echo "==> Installing Pillow (needed for the generated sample photo)"
  mise exec python@3.13 -- pip install pillow
fi

cat > "$WORK/gen_photo.py" <<'PYEOF'
"""Generate a pleasant 1200x800 dusk-over-fairway gradient JPEG."""
import sys
from PIL import Image

path = sys.argv[1]
W, H = 1200, 800

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

rows = []
for y in range(H):
    u = y / (H - 1)
    if u < 0.55:  # dusk sky: soft blue into warm amber at the horizon
        c = lerp((96, 144, 232), (244, 196, 140), u / 0.55)
    else:         # fairway: lit green into shadow
        c = lerp((86, 152, 84), (24, 64, 40), (u - 0.55) / 0.45)
    rows.append(bytes(c) * W)

Image.frombytes("RGB", (W, H), b"".join(rows)).save(path, "JPEG", quality=88)
print("generated", path)
PYEOF
PY "$WORK/gen_photo.py" "$PHOTO"
fi  # run_stage admin

# ---------------------------------------------------------------------------
# Build the stock server once (used by the dashboard + tutorial captures).
# ---------------------------------------------------------------------------
if run_stage dashboard || run_stage admin; then
echo "==> Building server (zig build)"
ZIG build
fi

# ===========================================================================
# PART 0 — admin-dashboard.png (existing posts/authors/comments demo seed)
# ===========================================================================
if run_stage dashboard; then
echo "==> [dashboard] Starting stock server"
DASH_PORT="${PORT:-$(pick_port)}"
DASH_DATA="$WORK/dash_data"

ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase superuser create \
  --email "$EMAIL" --password "$PASSWORD" --data-dir "$DASH_DATA"

ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase serve \
  --http-port "$DASH_PORT" --data-dir "$DASH_DATA" --insecure-cookies &
DASH_PID=$!
PIDS+=("$DASH_PID")
wait_health "$DASH_PORT"

echo "==> [dashboard] Seeding demo data (login + collections + records)"
COOKIES="$WORK/cookies.txt"
curl -fs -c "$COOKIES" -X POST "http://127.0.0.1:$DASH_PORT/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null
CSRF="$(grep zb_csrf "$COOKIES" | awk '{print $7}')"

api() { curl -fs -b "$COOKIES" -H "X-CSRF-Token: $CSRF" -H 'Content-Type: application/json' "$@"; }

# NOTE: every field needs a non-empty stable `id` (see docs/fields.md). `int`-mode
# number fields accept string-encoded integers on input.
api -X POST "http://127.0.0.1:$DASH_PORT/api/collections" -d '{
  "name":"posts","type":"base","fields":[
    {"id":"f_title","name":"title","type":"text","required":true,"options":{}},
    {"id":"f_slug","name":"slug","type":"text","required":true,"unique":true,"options":{}},
    {"id":"f_status","name":"status","type":"select","options":{"values":["draft","published"],"maxSelect":1}},
    {"id":"f_views","name":"views","type":"number","options":{"mode":"int"}}
  ]}' >/dev/null
api -X POST "http://127.0.0.1:$DASH_PORT/api/collections" -d \
  '{"name":"authors","type":"auth","fields":[{"id":"f_name","name":"name","type":"text","options":{}}]}' >/dev/null
api -X POST "http://127.0.0.1:$DASH_PORT/api/collections" -d \
  '{"name":"comments","type":"base","fields":[{"id":"f_body","name":"body","type":"editor","options":{}},{"id":"f_post","name":"post","type":"relation","options":{"targetCollectionId":"posts","maxSelect":1}}]}' >/dev/null

post_record() {
  api -X POST "http://127.0.0.1:$DASH_PORT/api/collections/posts/records" -d "$1" >/dev/null
}
post_record '{"title":"Single-binary backends with ZigBase","slug":"single-binary-backends","status":"published","views":"1248"}'
post_record '{"title":"Defining collections and schemas","slug":"collections-and-schemas","status":"published","views":"842"}'
post_record '{"title":"Realtime subscriptions over WebSocket","slug":"realtime-subscriptions","status":"published","views":"613"}'
post_record '{"title":"Writing a beforeCreate hook in Zig","slug":"beforecreate-hook-zig","status":"draft","views":"97"}'
post_record '{"title":"OAuth2 with the embedded admin","slug":"oauth2-embedded-admin","status":"draft","views":"54"}'
post_record '{"title":"File storage and uploads","slug":"file-storage-uploads","status":"published","views":"389"}'
post_record '{"title":"Comptime schema in the Zig framework","slug":"comptime-schema-framework","status":"published","views":"271"}'

echo "==> [dashboard] Capturing with Playwright"
CAPTURE="$WORK/capture_dashboard.py"
cat > "$CAPTURE" <<'PYEOF'
import sys
from playwright.sync_api import sync_playwright

base = sys.argv[1]
out = sys.argv[2]
email, password = "admin@example.com", "Password123!"

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1280, "height": 800},
                              device_scale_factor=2, color_scheme="light")
    page = ctx.new_page()
    page.goto(f"{base}/_/#/login", wait_until="networkidle")
    page.wait_for_selector('[data-test="email"]', timeout=10000)
    page.fill('[data-test="email"]', email)
    page.fill('[data-test="password"]', password)
    page.click('[data-test="login-submit"]')
    page.wait_for_selector('.shell', timeout=10000)
    page.goto(f"{base}/_/#/collections/posts/records", wait_until="networkidle")
    page.wait_for_selector('[data-test="records-view"]', timeout=10000)
    page.wait_for_selector('[data-test="row"]', timeout=10000)
    page.wait_for_timeout(400)
    page.screenshot(path=out)
    browser.close()
print("captured", out)
PYEOF
PY "$CAPTURE" "http://127.0.0.1:$DASH_PORT" "$OUT_DIR/admin-dashboard.png"

stop_server "$DASH_PID"
fi  # run_stage dashboard

# ===========================================================================
# PART A — admin UI tutorial flow (fresh data dir, the golfsim schema is
# built by ACTUALLY DRIVING the schema editor / records UI).
# ===========================================================================
if run_stage admin; then
echo "==> [tutorial] Starting stock server with a fresh data dir"
TUT_PORT="$(pick_port)"
TUT_DATA="$WORK/tutorial_data"

ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase superuser create \
  --email "$EMAIL" --password "$PASSWORD" --data-dir "$TUT_DATA"

ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase serve \
  --http-port "$TUT_PORT" --data-dir "$TUT_DATA" --insecure-cookies &
TUT_PID=$!
PIDS+=("$TUT_PID")
wait_health "$TUT_PORT"

echo "==> [tutorial] Driving the admin UI with Playwright"
CAPTURE_ADMIN="$WORK/capture_admin.py"
cat > "$CAPTURE_ADMIN" <<'PYEOF'
"""Drive the real admin SPA through the tutorial's golfsim schema, capturing
the marketing screenshots along the way. argv: base outdir photo_path"""
import json
import sys
import urllib.request

from playwright.sync_api import sync_playwright

base, outdir, photo = sys.argv[1], sys.argv[2], sys.argv[3]
ADMIN_EMAIL, ADMIN_PW = "admin@example.com", "Password123!"
HOST_EMAIL, HOST_PW = "host@example.com", "hostpassword"


def api(path, payload=None, token=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path, data=data,
        method=method or ("POST" if data is not None else "GET"))
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req) as r:
        body = r.read()
    return json.loads(body) if body else None


with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1280, "height": 800},
                              device_scale_factor=2, color_scheme="light")
    page = ctx.new_page()
    # Selecting a rule's "public" mode fires a JS confirm() dialog; Playwright
    # auto-dismisses dialogs unless we explicitly accept them.
    page.on("dialog", lambda d: d.accept())

    def shot(name):
        page.wait_for_timeout(350)  # settle fonts/animations
        page.screenshot(path=f"{outdir}/{name}")
        print("captured", name)

    def add_field(name, ftype, required=False):
        """Append a field row in the schema editor; returns the row locator.
        NOTE: set the row's option inputs immediately — the locator points at
        the LAST row and goes stale once another field is added."""
        page.click('[data-test="add-field"]')
        row = page.locator('[data-test="field-row"]').last
        row.locator('[data-test="field-name"]').fill(name)
        row.locator('[data-test="field-type"]').select_option(ftype)
        if required:
            row.locator('input[type="checkbox"]').first.check()  # "req"
        return row

    def goto_new_collection():
        page.goto(f"{base}/_/#/collections/__new__")
        page.wait_for_selector('[data-test="col-name"]', timeout=10000)

    def save_collection():
        # Save triggers a full document load of #/collections/<name>/records.
        page.click('[data-test="save-collection"]')
        page.wait_for_selector('[data-test="records-view"]', timeout=15000)

    def goto_records(col):
        page.goto(f"{base}/_/#/collections/{col}/records")
        page.wait_for_selector(f'h2:has-text("{col}")', timeout=10000)
        # the "· N records" total only renders once the data fetch landed
        page.wait_for_selector('[data-test="total"]:has-text("records")', timeout=10000)

    # --- 1. login screen -------------------------------------------------
    page.goto(f"{base}/_/#/login", wait_until="networkidle")
    page.wait_for_selector('[data-test="email"]', timeout=10000)
    page.fill('[data-test="email"]', ADMIN_EMAIL)
    shot("admin-login.png")

    page.fill('[data-test="password"]', ADMIN_PW)
    page.click('[data-test="login-submit"]')
    page.wait_for_selector('.shell', timeout=10000)

    # --- 2. users (auth) -------------------------------------------------
    goto_new_collection()
    page.fill('[data-test="col-name"]', "users")
    page.select_option('[data-test="col-type"]', "auth")
    add_field("name", "text")
    shot("admin-new-collection-users.png")
    # Rules (three-state select per rule). Open signup => createRule PUBLIC
    # (the "@public" sentinel); list/view also public so the app can read users;
    # update/delete are self-only expressions. New collections default every
    # rule to Locked/null (superuser only).
    page.click('[data-test="tab-rules"]')
    for r in ("listRule", "viewRule", "createRule"):
        page.select_option(f'[data-test="rulemode-{r}"]', "public")
    for r in ("updateRule", "deleteRule"):
        page.select_option(f'[data-test="rulemode-{r}"]', "expr")
        page.fill(f'[data-test="rule-{r}"]', "@request.auth.id = id")
    save_collection()

    # --- 3. simulators (base) — needed for listings' relation dropdown ---
    goto_new_collection()
    page.fill('[data-test="col-name"]', "simulators")
    add_field("label", "text", required=True)
    row = add_field("owner", "relation", required=True)
    row.locator('[data-test="opt-target"]').select_option("users")
    save_collection()

    # --- 4. listings fields ----------------------------------------------
    goto_new_collection()
    page.fill('[data-test="col-name"]', "listings")
    add_field("title", "text", required=True)
    row = add_field("price_per_hour", "number", required=True)
    row.locator('[data-test="opt-mode"]').select_option("fixed")
    # the scale input only renders once mode=fixed is selected
    row.locator('[data-test="opt-scale"]').fill("2")
    row = add_field("status", "select", required=True)
    row.locator('[data-test="opt-values"]').fill("draft,published,archived")
    row = add_field("simulator", "relation", required=True)
    row.locator('[data-test="opt-target"]').select_option("simulators")
    row = add_field("photos", "file")
    row.locator('[data-test="opt-maxselect"]').fill("6")
    shot("admin-fields-listings.png")

    # --- 5. listings API rules --------------------------------------------
    page.click('[data-test="tab-rules"]')
    rules = {
        "listRule": 'status = "published"',
        "viewRule": 'status = "published" || @request.auth.id = simulator.owner',
        "createRule": '@request.auth.id != ""',
        "updateRule": '@request.auth.id = simulator.owner',
        "deleteRule": '@request.auth.id = simulator.owner',
    }
    for r, v in rules.items():
        # null (Locked) -> Expression mode reveals the rule input, then fill it.
        page.select_option(f'[data-test="rulemode-{r}"]', "expr")
        page.fill(f'[data-test="rule-{r}"]', v)
    shot("admin-rules-listings.png")
    save_collection()

    # --- 6. sign up an end user via the public API ------------------------
    api("/api/collections/users/records",
        {"email": HOST_EMAIL, "password": HOST_PW, "name": "Demo Host"})

    # --- 7. users records table -------------------------------------------
    goto_records("users")
    page.wait_for_selector('[data-test="row"]', timeout=10000)
    shot("admin-records-users.png")

    # --- 8. simulator record via the records drawer ------------------------
    host_id = api("/api/collections/users/auth-with-password",
                  {"identity": HOST_EMAIL, "password": HOST_PW})["record"]["id"]

    goto_records("simulators")
    page.click('[data-test="new-record"]')
    page.wait_for_selector('[data-test="in-label"]', timeout=10000)
    page.fill('[data-test="in-label"]', "Bay 1 — TrackMan")
    page.wait_for_selector(f'[data-test="in-owner"] option[value="{host_id}"]',
                           state="attached", timeout=10000)
    page.select_option('[data-test="in-owner"]', host_id)
    page.click('[data-test="record-save"]')
    page.wait_for_selector('[data-test="record-drawer"]', state="detached", timeout=10000)
    page.wait_for_selector('[data-test="row"]', timeout=10000)

    # --- 9. listing record drawer (with photo) ------------------------------
    goto_records("listings")
    page.click('[data-test="new-record"]')
    page.wait_for_selector('[data-test="in-title"]', timeout=10000)
    page.fill('[data-test="in-title"]', "Sunset Tee Times")
    page.fill('[data-test="in-price_per_hour"]', "45.00")
    page.select_option('[data-test="in-status"]', "published")
    page.wait_for_selector('[data-test="in-simulator"] option:nth-child(2)',
                           state="attached", timeout=10000)
    sim_id = page.locator('[data-test="in-simulator"] option').nth(1).get_attribute("value")
    page.select_option('[data-test="in-simulator"]', sim_id)
    page.set_input_files('[data-test="in-photos"]', photo)
    shot("admin-new-record-listing.png")
    page.click('[data-test="record-save"]')
    page.wait_for_selector('[data-test="record-drawer"]', state="detached", timeout=15000)

    # --- 10. listings records table -----------------------------------------
    page.wait_for_selector('[data-test="row"]', timeout=10000)
    shot("admin-records-listings.png")

    # --- 11. OAuth2 tab on users (not saved) ---------------------------------
    page.goto(f"{base}/_/#/collections/users")
    page.wait_for_selector('[data-test="tab-auth"]', timeout=10000)
    page.click('[data-test="tab-auth"]')
    page.wait_for_selector('[data-test="oauth-enabled"]', timeout=10000)
    page.check('[data-test="oauth-enabled"]')
    page.click('[data-test="add-provider"]')
    page.wait_for_selector('[data-test="oauth-provider"]', timeout=10000)
    page.select_option('[data-test="oauth-name"]', "google")
    page.fill('[data-test="oauth-clientid"]', "1234-demo.apps.googleusercontent.com")
    page.fill('[data-test="oauth-redirects"]', "https://yourapp.example/oauth/callback")
    shot("admin-oauth.png")

    browser.close()
PYEOF
PY "$CAPTURE_ADMIN" "http://127.0.0.1:$TUT_PORT" "$OUT_DIR" "$PHOTO"

echo "==> [tutorial] Verifying the saved listings schema is fixed/scale-2"
TUT_SU_TOKEN="$(api_json "$TUT_PORT" "" POST /api/collections/_superusers/auth-with-password \
  "{\"identity\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jget token)"
api_json "$TUT_PORT" "$TUT_SU_TOKEN" GET /api/collections/listings | PY -c '
import sys, json
col = json.load(sys.stdin)
opts = next(f for f in col["schema"] if f["name"] == "price_per_hour")["options"]
assert opts.get("mode") == "fixed" and opts.get("scale") == 2, opts
print("OK: listings.price_per_hour options =", opts)
'

stop_server "$TUT_PID"
fi  # run_stage admin

# ===========================================================================
# PART B — example frontends (blog, golfsim, plugins)
# ===========================================================================
if run_stage examples; then
CAPTURE_EXAMPLES="$WORK/capture_examples.py"
cat > "$CAPTURE_EXAMPLES" <<'PYEOF'
"""Capture the example frontends. argv: mode base outdir [email password]"""
import sys
from playwright.sync_api import sync_playwright

mode, base, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
extra = sys.argv[4:]

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1280, "height": 800},
                              device_scale_factor=2, color_scheme="light")
    page = ctx.new_page()

    def shot(name):
        page.wait_for_timeout(400)
        page.screenshot(path=f"{outdir}/{name}")
        print("captured", name)

    def sign_in(email, pw):
        """Drive the example's real login card (placeholder-labelled inputs)."""
        page.wait_for_selector('input[placeholder="email"]', timeout=15000)
        page.fill('input[placeholder="email"]', email)
        page.fill('input[placeholder^="password"]', pw)
        page.click('button:has-text("Log in")')

    if mode == "blog":
        email, pw = extra
        page.goto(base + "/", wait_until="networkidle")
        page.wait_for_selector("article.card h2", timeout=15000)
        shot("example-blog-home.png")

        page.goto(base + "/write", wait_until="networkidle")
        sign_in(email, pw)
        page.wait_for_selector('input[placeholder="Title"]', timeout=15000)
        page.fill('input[placeholder="Title"]',
                  "Spring scramble: registration opens Friday")
        page.fill("textarea",
                  "Sign-ups for the spring scramble open this Friday at noon. "
                  "Four-player teams, shotgun start, and the simulator bays run "
                  "closest-to-the-pin contests all weekend.\n\n"
                  "Last year's spots went in under an hour, so set a reminder — "
                  "the slug for this post is derived server-side by the "
                  "beforeCreate hook the moment we hit Publish.")
        shot("example-blog-write.png")

    elif mode == "golfsim":
        email, pw = extra
        page.goto(base + "/", wait_until="networkidle")
        sign_in(email, pw)
        # signed-in listings render the real booking form (datetime inputs)
        page.wait_for_selector('input[type="datetime-local"]', timeout=15000)
        shot("example-golfsim-listings.png")

        page.goto(base + "/bookings", wait_until="networkidle")
        page.wait_for_selector("article.card strong", timeout=15000)  # status
        shot("example-golfsim-bookings.png")

    elif mode == "plugins":
        page.goto(base + "/", wait_until="networkidle")
        page.wait_for_selector("section.card ul li", timeout=15000)
        shot("example-plugins-browser.png")

    else:
        raise SystemExit(f"unknown mode {mode!r}")

    browser.close()
PYEOF

build_example() {
  local dir=$1
  echo "==> [$dir] Building frontend (npm)"
  (cd "$REPO_ROOT/examples/$dir/frontend" && { NPM ci || NPM install; } && NPM run build)
  echo "==> [$dir] Building binary (zig build — this can take a few minutes)"
  (cd "$REPO_ROOT/examples/$dir" && ZIG build)
}

# --- blog -------------------------------------------------------------------
build_example blog

BLOG_PORT="$(pick_port)"
BLOG_DATA="$WORK/blog_data"
ZIGBASE_JWT_SECRET="$JWT_SECRET" "$REPO_ROOT/examples/blog/zig-out/bin/blog" \
  superuser create --email "$EMAIL" --password "$PASSWORD" --data-dir "$BLOG_DATA"

echo "==> [blog] Serving on :$BLOG_PORT (runtime --serve-static mode)"
(cd "$REPO_ROOT/examples/blog" && exec env ZIGBASE_JWT_SECRET="$JWT_SECRET" \
  ./zig-out/bin/blog serve --http-port "$BLOG_PORT" --data-dir "$BLOG_DATA" \
  --serve-static frontend/dist --insecure-cookies) &
BLOG_PID=$!
PIDS+=("$BLOG_PID")
wait_health "$BLOG_PORT"

echo "==> [blog] Seeding author + posts"
AUTHOR_EMAIL="author@example.com"
AUTHOR_PW="authorpass123"
api_json "$BLOG_PORT" "" POST /api/collections/users/records \
  "{\"email\":\"$AUTHOR_EMAIL\",\"password\":\"$AUTHOR_PW\",\"passwordConfirm\":\"$AUTHOR_PW\",\"name\":\"Maya Chen\"}" >/dev/null
BLOG_TOKEN="$(api_json "$BLOG_PORT" "" POST /api/collections/users/auth-with-password \
  "{\"identity\":\"$AUTHOR_EMAIL\",\"password\":\"$AUTHOR_PW\"}" | jget token)"

blog_post() { api_json "$BLOG_PORT" "$BLOG_TOKEN" POST /api/collections/posts/records "$1" >/dev/null; }
blog_post '{"title":"Five drills that actually fixed my slice","body":"After two seasons of fighting a banana ball, these are the five simulator drills that finally straightened my driver: gate drills on the launch monitor, slow-motion top-of-backswing checks, alignment-stick path work, 9-to-3 swings, and exaggerated draw reps. The data does not lie — my club path went from 6 degrees out-to-in to dead neutral.","status":"published"}'
blog_post '{"title":"Winter league results: week three","body":"Week three of the indoor winter league is in the books. Bay 2 saw the closest match of the night, decided on a 22-foot putt on the 18th at simulated Pebble Beach. Standings, skins, and the closest-to-the-pin leaderboard are below — and yes, the trash talk channel is still undefeated.","status":"published"}'
blog_post '{"title":"Choosing a launch monitor on a budget","body":"You do not need a tour-truck budget to practice with real numbers. We compare photometric and radar units under a thousand dollars, what ball data you actually need for game improvement, and which specs are marketing noise. Spoiler: spin axis matters more than you think, and club path is worth paying for.","status":"published"}'
blog_post '{"title":"Course strategy: playing the percentages","body":"Scratch players do not hit more hero shots — they hit fewer dumb ones. Using two months of simulator round data, we look at when laying up actually saves strokes, why the 30-yard pitch is the worst shot in amateur golf, and how to pick targets that make bogey nearly impossible.","status":"published"}'
blog_post '{"title":"What 10,000 swings taught me about tempo","body":"I logged every swing I took on the simulator for a year. The single strongest predictor of a good round was not swing speed or even strike quality — it was tempo consistency. Here is the 3:1 ratio drill that rebuilt mine, and the session data that convinced me it was worth the boring reps.","status":"published"}'

echo "==> [blog] Capturing"
PY "$CAPTURE_EXAMPLES" blog "http://127.0.0.1:$BLOG_PORT" "$OUT_DIR" "$AUTHOR_EMAIL" "$AUTHOR_PW"
stop_server "$BLOG_PID"

# --- golfsim ------------------------------------------------------------------
build_example golfsim

GOLF_PORT="$(pick_port)"
GOLF_DATA="$WORK/golfsim_data"
ZIGBASE_JWT_SECRET="$JWT_SECRET" "$REPO_ROOT/examples/golfsim/zig-out/bin/golfsim" \
  superuser create --email "$EMAIL" --password "$PASSWORD" --data-dir "$GOLF_DATA"

# The static dir is comptime-hardcoded as "frontend/dist" RELATIVE — the server
# must run with CWD = examples/golfsim.
echo "==> [golfsim] Serving on :$GOLF_PORT (comptime-hardcoded static dir)"
(cd "$REPO_ROOT/examples/golfsim" && exec env ZIGBASE_JWT_SECRET="$JWT_SECRET" \
  ./zig-out/bin/golfsim serve --http-port "$GOLF_PORT" --data-dir "$GOLF_DATA" --insecure-cookies) &
GOLF_PID=$!
PIDS+=("$GOLF_PID")
wait_health "$GOLF_PORT"

echo "==> [golfsim] Seeding host, simulator, listings, guest + booking"
HOST_EMAIL="host@example.com"
HOST_PW="hostpassword"
GUEST_EMAIL="guest@example.com"
GUEST_PW="guestpassword"

api_json "$GOLF_PORT" "" POST /api/collections/users/records \
  "{\"email\":\"$HOST_EMAIL\",\"password\":\"$HOST_PW\",\"passwordConfirm\":\"$HOST_PW\",\"name\":\"Demo Host\"}" >/dev/null
HOST_AUTH="$(api_json "$GOLF_PORT" "" POST /api/collections/users/auth-with-password \
  "{\"identity\":\"$HOST_EMAIL\",\"password\":\"$HOST_PW\"}")"
HOST_TOKEN="$(printf '%s' "$HOST_AUTH" | jget token)"
HOST_ID="$(printf '%s' "$HOST_AUTH" | jget record.id)"

SIM_ID="$(api_json "$GOLF_PORT" "$HOST_TOKEN" POST /api/collections/simulators/records \
  "{\"label\":\"Bay 1 — TrackMan\",\"owner\":\"$HOST_ID\"}" | jget id)"

LISTING_ID="$(api_json "$GOLF_PORT" "$HOST_TOKEN" POST /api/collections/listings/records \
  "{\"title\":\"Sunset Tee Times\",\"price_per_hour\":45,\"status\":\"published\",\"simulator\":\"$SIM_ID\"}" | jget id)"
api_json "$GOLF_PORT" "$HOST_TOKEN" POST /api/collections/listings/records \
  "{\"title\":\"Early Bird Range Hour\",\"price_per_hour\":38,\"status\":\"published\",\"simulator\":\"$SIM_ID\"}" >/dev/null
api_json "$GOLF_PORT" "$HOST_TOKEN" POST /api/collections/listings/records \
  "{\"title\":\"Weekend League Bay\",\"price_per_hour\":60,\"status\":\"published\",\"simulator\":\"$SIM_ID\"}" >/dev/null

api_json "$GOLF_PORT" "" POST /api/collections/users/records \
  "{\"email\":\"$GUEST_EMAIL\",\"password\":\"$GUEST_PW\",\"passwordConfirm\":\"$GUEST_PW\",\"name\":\"Demo Guest\"}" >/dev/null
GUEST_TOKEN="$(api_json "$GOLF_PORT" "" POST /api/collections/users/auth-with-password \
  "{\"identity\":\"$GUEST_EMAIL\",\"password\":\"$GUEST_PW\"}" | jget token)"

# Future slot so the expire-holds cron never sweeps it. (Python, not `date -d`:
# BSD/macOS date has no -d.)
tomorrow_utc() {
  PY -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=$1, minute=0, second=0, microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}
STARTS_AT="$(tomorrow_utc 18)"
ENDS_AT="$(tomorrow_utc 20)"
api_json "$GOLF_PORT" "$GUEST_TOKEN" POST /api/collections/bookings/records \
  "{\"listing\":\"$LISTING_ID\",\"starts_at\":\"$STARTS_AT\",\"ends_at\":\"$ENDS_AT\"}" >/dev/null

echo "==> [golfsim] Capturing"
PY "$CAPTURE_EXAMPLES" golfsim "http://127.0.0.1:$GOLF_PORT" "$OUT_DIR" "$GUEST_EMAIL" "$GUEST_PW"
stop_server "$GOLF_PID"

# --- plugins ------------------------------------------------------------------
build_example plugins

PLUG_PORT="$(pick_port)"
PLUG_DATA="$WORK/plugins_data"
ZIGBASE_JWT_SECRET="$JWT_SECRET" "$REPO_ROOT/examples/plugins/zig-out/bin/plugins" \
  superuser create --email "$EMAIL" --password "$PASSWORD" --data-dir "$PLUG_DATA"

# Fully embedded static assets: no flag and no CWD dependency.
echo "==> [plugins] Serving on :$PLUG_PORT (embedded static assets)"
ZIGBASE_JWT_SECRET="$JWT_SECRET" "$REPO_ROOT/examples/plugins/zig-out/bin/plugins" \
  serve --http-port "$PLUG_PORT" --data-dir "$PLUG_DATA" --insecure-cookies &
PLUG_PID=$!
PIDS+=("$PLUG_PID")
wait_health "$PLUG_PORT"

echo "==> [plugins] Seeding authors + posts (superuser; create rules are locked)"
SU_TOKEN="$(api_json "$PLUG_PORT" "" POST /api/collections/_superusers/auth-with-password \
  "{\"identity\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jget token)"

A1="$(api_json "$PLUG_PORT" "$SU_TOKEN" POST /api/collections/authors/records \
  '{"name":"Maya Chen","contact_email":"maya@example.com"}' | jget id)"
A2="$(api_json "$PLUG_PORT" "$SU_TOKEN" POST /api/collections/authors/records \
  '{"name":"Tomás Rivera","contact_email":"tomas@example.com"}' | jget id)"

plug_post() { api_json "$PLUG_PORT" "$SU_TOKEN" POST /api/collections/posts/records "$1" >/dev/null; }
plug_post "{\"title\":\"Shipping a single-binary backend\",\"author\":\"$A1\",\"status\":\"published\"}"
plug_post "{\"title\":\"Comptime schemas in practice\",\"author\":\"$A2\",\"status\":\"published\"}"
plug_post "{\"title\":\"Plugins: bring your own mailer\",\"author\":\"$A1\",\"status\":\"published\"}"
plug_post "{\"title\":\"Draft: roadmap notes\",\"author\":\"$A2\",\"status\":\"draft\"}"

echo "==> [plugins] Capturing"
PY "$CAPTURE_EXAMPLES" plugins "http://127.0.0.1:$PLUG_PORT" "$OUT_DIR"
stop_server "$PLUG_PID"
fi  # run_stage examples

echo "==> Done ($STAGE). Screenshots written to $OUT_DIR:"
ls -1 "$OUT_DIR"
