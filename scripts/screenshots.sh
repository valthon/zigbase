#!/usr/bin/env bash
#
# screenshots.sh — reproduce the admin-UI screenshot(s) used on the marketing site.
#
# CAPTURE PATH: REAL UI.
#   This captures the ACTUAL ZigBase admin SPA (served at /_/) running against a
#   locally-built `zigbase serve` instance — NOT a static mock. The admin UI ships
#   a single dark theme (see src/admin/style.css), so the shot is its native dark
#   appearance captured at a 1280x800 desktop viewport with devicePixelRatio 2
#   (i.e. an intrinsic 2560x1600 PNG).
#
# OUTPUT:
#   site/src/assets/screenshots/admin-dashboard.png  (collections + records view)
#
# REQUIREMENTS:
#   - Zig 0.16   (via `mise exec zig@0.16.0 -- zig ...`)
#   - Python 3.13 with Playwright + Chromium (via mise)
#
# USAGE:
#   ./scripts/screenshots.sh
#
# It builds the server, provisions a throwaway data dir with a superuser and a
# seeded `posts` collection (+ `authors`, `comments`), serves on a free port,
# drives the admin UI with Playwright, copies the PNG into the site assets, and
# tears everything down. The data dir lives under a mktemp dir and is removed at
# the end — nothing under it is committed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PORT="${PORT:-8099}"
JWT_SECRET="${ZIGBASE_JWT_SECRET:-devsecret}"
EMAIL="admin@example.com"
PASSWORD='Password123!'

WORK="$(mktemp -d)"
DATA_DIR="$WORK/zb_data"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ZIG() { mise exec zig@0.16.0 -- zig "$@"; }
PY()  { mise exec python@3.13 -- python "$@"; }

echo "==> Building server (zig build)"
ZIG build

echo "==> Creating superuser"
ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase superuser create \
  --email "$EMAIL" --password "$PASSWORD" --data-dir "$DATA_DIR"

echo "==> Starting server on :$PORT"
ZIGBASE_JWT_SECRET="$JWT_SECRET" ./zig-out/bin/zigbase serve \
  --http-port "$PORT" --data-dir "$DATA_DIR" &
SERVER_PID=$!

echo "==> Waiting for health"
for _ in $(seq 1 60); do
  if curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

echo "==> Seeding demo data (login + collections + records)"
COOKIES="$WORK/cookies.txt"
curl -fs -c "$COOKIES" -X POST "http://127.0.0.1:$PORT/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null
CSRF="$(grep zb_csrf "$COOKIES" | awk '{print $7}')"

api() { curl -fs -b "$COOKIES" -H "X-CSRF-Token: $CSRF" -H 'Content-Type: application/json' "$@"; }

# NOTE: every field needs a non-empty stable `id` (see docs/fields.md). `int`-mode
# number fields accept string-encoded integers on input.
api -X POST "http://127.0.0.1:$PORT/api/collections" -d '{
  "name":"posts","type":"base","fields":[
    {"id":"f_title","name":"title","type":"text","required":true,"options":{}},
    {"id":"f_slug","name":"slug","type":"text","required":true,"unique":true,"options":{}},
    {"id":"f_status","name":"status","type":"select","options":{"values":["draft","published"],"maxSelect":1}},
    {"id":"f_views","name":"views","type":"number","options":{"mode":"int"}}
  ]}' >/dev/null
api -X POST "http://127.0.0.1:$PORT/api/collections" -d \
  '{"name":"authors","type":"auth","fields":[{"id":"f_name","name":"name","type":"text","options":{}}]}' >/dev/null
api -X POST "http://127.0.0.1:$PORT/api/collections" -d \
  '{"name":"comments","type":"base","fields":[{"id":"f_body","name":"body","type":"editor","options":{}},{"id":"f_post","name":"post","type":"relation","options":{"targetCollectionId":"posts","maxSelect":1}}]}' >/dev/null

post_record() {
  api -X POST "http://127.0.0.1:$PORT/api/collections/posts/records" -d "$1" >/dev/null
}
post_record '{"title":"Single-binary backends with ZigBase","slug":"single-binary-backends","status":"published","views":"1248"}'
post_record '{"title":"Defining collections and schemas","slug":"collections-and-schemas","status":"published","views":"842"}'
post_record '{"title":"Realtime subscriptions over WebSocket","slug":"realtime-subscriptions","status":"published","views":"613"}'
post_record '{"title":"Writing a beforeCreate hook in Zig","slug":"beforecreate-hook-zig","status":"draft","views":"97"}'
post_record '{"title":"OAuth2 with the embedded admin","slug":"oauth2-embedded-admin","status":"draft","views":"54"}'
post_record '{"title":"File storage and uploads","slug":"file-storage-uploads","status":"published","views":"389"}'
post_record '{"title":"Comptime schema in the Zig framework","slug":"comptime-schema-framework","status":"published","views":"271"}'

echo "==> Capturing with Playwright"
CAPTURE="$WORK/capture.py"
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

OUT="$REPO_ROOT/site/src/assets/screenshots/admin-dashboard.png"
PY "$CAPTURE" "http://127.0.0.1:$PORT" "$OUT"

echo "==> Done: $OUT"
