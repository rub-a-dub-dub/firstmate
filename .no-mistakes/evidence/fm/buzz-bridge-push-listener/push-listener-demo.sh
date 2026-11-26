#!/usr/bin/env bash
# Manual end-to-end demonstration of the Buzz push listener, run against a
# hermetic home: no relay is contacted, every key is invented, and the buzz CLI
# plus the listener helper are local stubs that stand in for the pinned
# binaries. It shows what an operator sees:
#   A. a poll-only home (no BUZZ_LISTENER) does NOT pick up a mention between
#      sweeps - the pre-change behaviour, up to FM_CHECK_INTERVAL of latency
#   B. a listener home surfaces the same mention to a live watcher in seconds,
#      with the next sweep still far away
#   C. removing config/buzz-bridge.enabled alone stops the listener and the
#      helper holding the relay session
#   D. status labels an unset vs. an unusable BUZZ_LISTENER distinctly
set -u
ROOT=${ROOT:?set ROOT to the firstmate worktree}
. "$ROOT/tests/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in jq python3; do
  dir=$(command -v "$tool" 2>/dev/null) && BASE_PATH="$(dirname "$dir"):$BASE_PATH"
done
TMP_ROOT=$(fm_test_tmproot fm-buzz-push-demo)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/procevent-claims"
SIGN="$ROOT/tests/fixtures/buzz-sign.py"

OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
NOW=1800000000

say() { printf '\n== %s\n' "$*"; }
run_in() {
  local home=$1; shift
  PATH="$BASE_PATH" FM_HOME="$home" FMX_NOW_OVERRIDE=$NOW FAKE_BUZZ_LOG="$home/cli.log" \
    FAKE_EVENTS="$home/events.json" FAKE_SENT="$home/sent.jsonl" FAKE_EXPECT_SECRET=$BRIDGE_SK "$@"
}
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  cat > "$home/bin/buzz" <<'SH'
#!/usr/bin/env bash
log=${FAKE_BUZZ_LOG:?}
printf 'argv=%s\n' "$*" >> "$log"
since=0 until=99999999999 limit=50 cmd=
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds|--channel|--reply-to|--content) shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    messages) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$cmd" = get ] || exit 1
jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
  '[.[] | select(.created_at >= $s and .created_at <= $u)]
   | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "${FAKE_EVENTS:?}"
SH
  chmod +x "$home/bin/buzz"
  printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$home/bridge.key"
  cat > "$home/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.test.invalid
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$home/bridge.key
BUZZ_CLI=$home/bin/buzz
EOF
  printf '[]\n' > "$home/events.json"
  : > "$home/cli.log"
  printf '%s\n' "$home"
}
# A stub for the pinned fm-buzz-listen helper: it speaks the same one-word
# stdout protocol (connected / match / disconnected) and holds the session open.
add_listener() {
  local home=$1
  cat > "$home/bin/listener" <<'SH'
#!/usr/bin/env bash
home=${0%/bin/listener}
printf '%s\n' "$$" > "$home/listener.pid"
printf 'connected\n'
while [ "$SECONDS" -lt 300 ]; do
  if [ -e "$home/doorbell" ]; then rm -f "$home/doorbell"; printf 'match\n'; fi
  sleep 0.05
done
SH
  chmod +x "$home/bin/listener"
  printf 'BUZZ_LISTENER=%s\n' "$home/bin/listener" >> "$home/config/buzz-bridge.env"
}
mention() {
  python3 -I "$SIGN" event "$OWNER_SK" "$NOW" 9 \
    "$(printf '[["h","%s"],["p","%s"]]' "$CHANNEL" "$BRIDGE")" "$1" | jq -s . 
}
start_watcher() {  # <home>
  local home=$1
  # A sweep just happened and the next one is ~11 days out, so nothing the
  # watcher prints from here on can be a scheduled Buzz poll.
  : > "$home/state/.last-check"
  printf 'announced:downtime:demo\n' > "$home/state/.watcher-down"
  fm_test_track_watcher_state "$home/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    run_in "$home" "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
}
exited() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) || return 0; [[ "$s" = Z* || -z "$s" ]]; }

printf 'firstmate Buzz push listener - end-to-end demonstration\n'
printf 'date: %s\n' "$(date -u +%FT%TZ)"
printf 'commit: %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'watcher check interval for every run below: FM_CHECK_INTERVAL=999999s (no sweep can fire)\n'

say 'A. poll-only home (BUZZ_LISTENER unset): the pre-change experience'
A=$(new_home poll-only)
run_in "$A" "$ROOT/bin/fm-buzz.sh" enable
run_in "$A" "$ROOT/bin/fm-buzz.sh" status
start_watcher "$A"; a_watch=$!
mention 'owner mention with no listener' > "$A/events.json"
printf -- '-- owner posted a mention at %s; waiting 15s for the watcher to say something\n' "$(date -u +%T)"
for _ in $(seq 1 150); do grep -q 'buzz-mention' "$A/watch.out" && break; sleep 0.1; done
if grep -q 'buzz-mention' "$A/watch.out"; then
  printf 'UNEXPECTED: a poll-only home surfaced the mention: %s\n' "$(cat "$A/watch.out")"
else
  printf -- '-- after 15s the watcher has delivered nothing (%s bytes of output); the\n' "$(wc -c < "$A/watch.out" | tr -d ' ')"
  printf -- '   mention waits for the next check sweep, i.e. up to FM_CHECK_INTERVAL (300s by default)\n'
fi
kill "$a_watch" 2>/dev/null; wait "$a_watch" 2>/dev/null
printf -- '-- buzz CLI reads performed in this window: %s\n' "$(grep -c 'messages get' "$A/cli.log" | tr -d ' ')"

say 'B. same home with BUZZ_LISTENER set: a push arrives in seconds'
B=$(new_home listener)
add_listener "$B"
fm_test_track_procevent_home "$B" "$FM_PROCEVENT_CLAIM_ROOT"
run_in "$B" "$ROOT/bin/fm-buzz.sh" enable
for _ in $(seq 1 100); do
  run_in "$B" "$ROOT/bin/fm-buzz.sh" status | grep -Fxq 'listener: connected' && break
  sleep 0.1
done
run_in "$B" "$ROOT/bin/fm-buzz.sh" status
printf -- '-- registered process-event sources:\n'
run_in "$B" "$ROOT/bin/fm-procevent.sh" list
start_watcher "$B"; b_watch=$!
sleep 1
mention 'can you check the deploy?' > "$B/events.json"
start=$(date +%s)
: > "$B/doorbell"
printf -- '-- owner mention published to the relay fixture at %s and the listener notified\n' "$(date -u +%T)"
for _ in $(seq 1 300); do grep -q 'buzz-mention' "$B/watch.out" && break; sleep 0.1; done
elapsed=$(( $(date +%s) - start ))
printf -- '-- watcher wake, %ss after the mention (next scheduled sweep: ~%s days away):\n' \
  "$elapsed" "$(( 999999 / 86400 ))"
sed 's/^/   | /' "$B/watch.out"
wait "$b_watch" 2>/dev/null
rid=$(basename "$(echo "$B"/state/x-inbox/buzz-*.json)" .json)
printf -- '-- persisted inbox entry state/x-inbox/%s.json:\n' "$rid"
jq '{request_id, platform, text, verified: .buzz.verified, channel: .buzz.channel}' \
  "$B/state/x-inbox/$rid.json" | sed 's/^/   | /'

say 'C. the enabled marker is the off switch on its own'
helper=$(cat "$B/listener.pid")
IFS=' ' read -r listen_pid _ < "$B/state/buzz/listener.connected"
printf -- '-- listener process %s owns helper process %s (relay session)\n' "$listen_pid" "$helper"
printf -- '-- removing config/buzz-bridge.enabled by hand; nothing else is told\n'
off=$(date +%s)
rm -f "$B/config/buzz-bridge.enabled"
for _ in $(seq 1 900); do exited "$listen_pid" && exited "$helper" && break; sleep 0.1; done
printf -- '-- %ss later: listener exited=%s helper exited=%s (default re-check cadence is 60s)\n' \
  "$(( $(date +%s) - off ))" \
  "$(exited "$listen_pid" && echo yes || echo NO)" "$(exited "$helper" && echo yes || echo NO)"
run_in "$B" "$ROOT/bin/fm-buzz.sh" status
printf -- '-- and a full disable also retires the registered source:\n'
run_in "$B" "$ROOT/bin/fm-buzz.sh" disable
run_in "$B" "$ROOT/bin/fm-buzz.sh" status
run_in "$B" "$ROOT/bin/fm-procevent.sh" list

say 'D. status tells an unset BUZZ_LISTENER apart from one that cannot run'
D=$(new_home unusable)
printf 'BUZZ_LISTENER=%s\n' "$D/bin/listener-that-moved" >> "$D/config/buzz-bridge.env"
run_in "$D" "$ROOT/bin/fm-buzz.sh" status | sed 's/^/   | /'
printf '\nDONE\n'
