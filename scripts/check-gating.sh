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

# A separate build-flag axis. The build job checks absence in its stock binary;
# the S3 job invokes the paired mode against explicit off/on binaries as a
# positive control, so renamed patterns cannot silently make the test vacuous.
INVENTORY_PATTERNS=('files\.inventory\.' 'files\.local_inventory\.' 'fileInventoryRun')
check_inventory() {
  local off=$1 on=${2:-} symbols pattern
  symbols=$(nm --defined-only "$off")
  for pattern in "${INVENTORY_PATTERNS[@]}"; do
    if grep -Eq "$pattern" <<< "$symbols"; then
      echo "LEAK: inventory pattern '$pattern' in $off"; return 1
    fi
    if [ -n "$on" ] && ! nm --defined-only "$on" | grep -E "$pattern" >/dev/null; then
      echo "DRIFT: inventory pattern '$pattern' absent in $on"; return 1
    fi
  done
}
if [ "${1:-}" = --inventory ]; then
  [ "$#" -eq 3 ] || { echo 'usage: check-gating.sh --inventory OFF_BINARY ON_BINARY'; exit 2; }
  check_inventory "$2" "$3"
  echo 'inventory gating: OK'
  exit 0
fi

FULL=zig-out/bin/zigbase
check_inventory "$FULL"
FULL2=zig-out/bin/full-fixture
LEAN=zig-out/bin/minimal-server
[ -x "$FULL" ] || { echo "build $FULL first (zig build)"; exit 2; }
[ -x "$FULL2" ] || { echo "build $FULL2 first (zig build full-fixture)"; exit 2; }
[ -x "$LEAN" ] || { echo "build $LEAN first (zig build minimal-server)"; exit 2; }

# Fourth reference: the SAME zigbase binary rebuilt with -Ddev-tools=false. This is a
# different axis from the three above — a build.zig -D flag (a whole separate compile),
# not an App()-level comptime cfg key toggled within one binary — so it can't reuse the
# FULL/LEAN diff above and gets its own pair + pattern set. Proves `init`/`agents-md`/
# `typegen` (src/scaffold*.zig, src/codegen/**) actually disappear rather than just
# becoming dead-but-still-linked code; see src/devtools.zig.
DEVTOOLS_OFF=zig-out-devtools-off/bin/zigbase
[ -x "$DEVTOOLS_OFF" ] || { echo "build $DEVTOOLS_OFF first (zig build -Ddev-tools=false -p zig-out-devtools-off)"; exit 2; }

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
  "scheduler_coordination.claim" # opted-in distributed scheduler dispatcher
  "two_factor.Subsystem" # optional second-factor dispatcher and verification
  "totp.verify"          # TOTP verification is absent when unselected
  "webauthn.second_factor" # separate WebAuthn second-factor ceremonies
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

# -Ddev-tools=false: init/agents-md/typegen's whole subtree (scaffold + codegen) must be
# gone. Namespaced past the module name (a trailing "." into the real decl path, same
# rule as PATTERNS above) so this can't false-positive on an unrelated identifier that
# merely contains "scaffold" or "codegen" as a substring.
DEVTOOLS_PATTERNS=(
  "scaffold\."   # src/scaffold.zig + src/scaffold/** (init, agents-md)
  "codegen\."    # src/codegen/** (typegen — ~24 files, the largest of the three) — the
                 # dot is escaped (unlike PATTERNS above): "codegen"/"scaffold" alone are
                 # common enough substrings elsewhere (e.g. sqlite3ExprCodeGeneratedColumn)
                 # to false-LEAK on the plain-dot-as-wildcard behavior grep BRE gives "."
)
for p in "${DEVTOOLS_PATTERNS[@]}"; do
  full_n=$(nm --defined-only "$FULL" | grep -c -i -- "$p" || true)
  off_n=$(nm --defined-only "$DEVTOOLS_OFF" | grep -c -i -- "$p" || true)
  if [ "$full_n" -eq 0 ]; then
    echo "DRIFT: dev-tools pattern '$p' matches nothing in the default (-Ddev-tools=true) $FULL — update the pattern"; fail=1
  fi
  if [ "$off_n" -ne 0 ]; then
    echo "LEAK: '$p' found $off_n symbol(s) in the -Ddev-tools=false binary:"
    nm --defined-only "$DEVTOOLS_OFF" | grep -i -- "$p" | head -5
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "gating invariant OK (${#PATTERNS[@]} + ${#DEVTOOLS_PATTERNS[@]} patterns)"
exit $fail
