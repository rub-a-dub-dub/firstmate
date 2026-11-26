#!/usr/bin/env bash
# The real fm-buzz-listen binary, built by the command docs/configuration.md
# prescribes, driven by the built-in process-event adapter in a firstmate home.
#
# The relay is https://relay.test.invalid - a reserved name that never resolves,
# so no relay is contacted. That makes this the reconnect path: the helper keeps
# re-handshaking with bounded backoff while bin/fm-buzz.sh status reports
# `listener: disconnected`, and the off switch alone must stop both the adapter
# and the helper process it owns.
set -u
umask 022
ROOT=${1:?usage: real-helper-integration.sh <firstmate-repo-root> <fm-buzz-listen>}
HELPER=${2:?usage: real-helper-integration.sh <firstmate-repo-root> <fm-buzz-listen>}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/real-helper.XXXXXX")
HOME_DIR="$WORK/home"
export FM_PROCEVENT_CLAIM_ROOT="$WORK/procevent-claims"
export FM_BUZZ_LISTEN_RECHECK_SECONDS=1   # the off-switch re-check cadence (60s in production)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
for tool in jq python3; do d=$(command -v "$tool" 2>/dev/null) && BASE_PATH="$(dirname "$d"):$BASE_PATH"; done
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
OWNER=$(python3 -I "$SIGN" pubkey 1111111111111111111111111111111111111111111111111111111111111111)
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
cleanup() {
  if [ -d "$HOME_DIR/state/procevent" ]; then
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/buzz"; chmod +x "$HOME_DIR/bin/buzz"
printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.test.invalid
BUZZ_CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
BUZZ_LISTENER=$HELPER
EOF
fm() { PATH="$BASE_PATH" FM_HOME="$HOME_DIR" "$@"; }
say() { printf '\n$ %s\n' "$*"; }

printf '=== the real fm-buzz-listen binary under the process-event adapter =======\n'
printf '# %s\n' "$("$HELPER" 2>&1 | head -1)"
printf '# built by the documented command; file: %s\n' "$(ls -l "$HELPER" | awk '{print $5" bytes"}')"

say "bin/fm-buzz.sh enable"
fm "$ROOT/bin/fm-buzz.sh" enable
say "bin/fm-buzz.sh status"
fm "$ROOT/bin/fm-buzz.sh" status | sed -n '1,3p'

for i in $(seq 1 100); do
  helper_pid=$(pgrep -f "^$HELPER " | head -1) && [ -n "$helper_pid" ] && break
  sleep 0.1
done
listen_pid=$(ps -o ppid= -p "$helper_pid" 2>/dev/null | tr -d ' ')
printf '\n# the adapter process the runner started, and the real helper it owns:\n'
ps -o pid=,ppid=,command= -p "$listen_pid" 2>/dev/null | cut -c1-110
printf '%s\n' "$(ps -o pid=,ppid=,command= -p "$helper_pid" 2>/dev/null)" | fold -w 110
printf '# the helper is re-handshaking against an unresolvable relay, so status\n'
printf '# stays `listener: disconnected` and nothing claims a session it lacks.\n'

printf '\n--- the off switch alone, with no traffic on the channel ----------------\n'
say "rm config/buzz-bridge.enabled   # the marker is the off switch"
rm -f "$HOME_DIR/config/buzz-bridge.enabled"
for i in $(seq 1 100); do
  ps -o pid= -p "$listen_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
for i in $(seq 1 100); do
  ps -o pid= -p "$helper_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
printf 'adapter pid %s: %s\n' "$listen_pid" "$(ps -o stat= -p "$listen_pid" 2>/dev/null || echo gone)"
printf 'helper  pid %s: %s\n' "$helper_pid" "$(ps -o stat= -p "$helper_pid" 2>/dev/null || echo gone)"
say "bin/fm-buzz.sh status   # the source stays registered for a later enable"
fm "$ROOT/bin/fm-buzz.sh" status | sed -n '1,3p'
printf '\n# no secret in the helper argv above, and none in status output:\n'
fm "$ROOT/bin/fm-buzz.sh" status | grep -c "$BRIDGE_SK" | sed 's/^/  occurrences of the bridge secret: /'
printf '=== end ==================================================================\n'
