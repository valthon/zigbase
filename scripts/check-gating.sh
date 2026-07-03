#!/usr/bin/env bash
# Gating invariant (R2-3/R2-4/R2-5, audit gating-consistency §4): a consumer App
# with nothing optional configured must contain NO symbols from deselected
# subsystems. Each pattern is also required to match in at least one FULL
# reference binary — a pattern that matches nothing anywhere has drifted
# (rename) and would make the check vacuous, so that fails too.
#
# Two FULL references, not one: the stock `zigbase` binary (src/main.zig) only
# sets `.enable_typegen`, so `.admin` and the five built-in auth methods are on
# by default there — but `.mail`/`.webhooks`/`.analytics` are NOT configured, so
# their symbols (senders/inbound API, the webhook + mail job kinds, the
# analytics API) never appear in it either. Checking those patterns against the
# stock binary alone would DRIFT-fail forever, defeating exactly the guarantee
# (R2-5's job-kind gating) this script exists to prove. fixtures/full turns
# those specific knobs on as a positive control; see fixtures/full/main.zig.
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=zig-out/bin/zigbase
FULL2=zig-out/bin/full-fixture
LEAN=zig-out/bin/minimal-server
[ -x "$FULL" ] || { echo "build $FULL first (zig build)"; exit 2; }
[ -x "$FULL2" ] || { echo "build $FULL2 first (zig build full-fixture)"; exit 2; }
[ -x "$LEAN" ] || { echo "build $LEAN first (zig build minimal-server)"; exit 2; }

# subsystem -> symbol substring expected in AT LEAST ONE full binary, and in
# NEITHER binary should it appear in the lean one.
# (spellings verified against nm --defined-only output during R2-7; Debug builds
# keep Zig's dot-namespaced module-path symbol names)
#
# NOTE: bare `webauthn`/`analytics`/`senders`/`magic_link`/`oauth2` substrings
# false-positive: the comptime `Gates` struct gets printed literally into the
# mangled `server.Server(.{ .admin = false, .analytics = false, ... }).xxx`
# type name REGARDLESS of whether the gate is on or off, so e.g. bare
# "webauthn" matches even in the lean binary via ".webauthn = false". That is
# why every pattern below is namespaced past the Gates-struct field name (a
# trailing "." into the real module path, not " = ").
PATTERNS=(
  "methods.webauthn"      # WebAuthn method (register endpoints live under api.webauthn_register)
  "cbor"                  # WebAuthn attestation parsing (CBOR/COSE stack)
  "methods.magic_link"    # magic-link method (consume route + mailer body)
  "methods.oauth2"        # OAuth2 method
  "analytics.api"         # analytics read endpoints
  "api.senders"           # senders endpoints
  "mail.inbound"          # inbound bounce/complaint webhook
  "api.mail_unsubscribe"  # RFC 8058 one-click unsubscribe endpoints
  "webhookJobHandler"     # built-in webhook job kind
  "mail.send.jobHandler"  # built-in mail job kind
  "admin.serve"           # admin SPA dispatch (+ its @embedFile assets)
)

fail=0
for p in "${PATTERNS[@]}"; do
  full_n=$(nm --defined-only "$FULL" | grep -c -i -- "$p" || true)
  full2_n=$(nm --defined-only "$FULL2" | grep -c -i -- "$p" || true)
  lean_n=$(nm --defined-only "$LEAN" | grep -c -i -- "$p" || true)
  if [ "$full_n" -eq 0 ] && [ "$full2_n" -eq 0 ]; then
    echo "DRIFT: pattern '$p' matches nothing in either full binary — update the pattern"; fail=1
  fi
  if [ "$lean_n" -ne 0 ]; then
    echo "LEAK: '$p' found $lean_n symbol(s) in the lean binary:"
    nm --defined-only "$LEAN" | grep -i -- "$p" | head -5
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "gating invariant OK (${#PATTERNS[@]} patterns)"
exit $fail
