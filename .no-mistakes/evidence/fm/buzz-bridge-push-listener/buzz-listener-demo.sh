#!/usr/bin/env bash
# End-to-end demonstration of the home-local Buzz push listener.
#
# Hermetic: every key is invented here, the relay is a fake `buzz` CLI that
# serves locally signed events, and the long-running listener is a stub that
# stands in for bin/fm-buzz-listen.rs (the Rust helper needs an out-of-tree
# cargo build against a pinned Buzz clone). No relay is contacted.
#
# What it shows an operator: enable -> `listener: connected`, an owner mention
# posted to the channel, and the running watcher surfacing that mention within
# seconds while its own Buzz check sweep (300s, just run) is nowhere near due.
set -u
umask 022
ROOT=${1:?usage: buzz-listener-demo.sh <firstmate-repo-root>}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/buzz-listener-demo.XXXXXX")
HOME_DIR="$WORK/home"
export FM_PROCEVENT_CLAIM_ROOT="$WORK/procevent-claims"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
for tool in jq python3; do
  d=$(command -v "$tool" 2>/dev/null) && BASE_PATH="$(dirname "$d"):$BASE_PATH"
done
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
NOW=1800000000

cleanup() {
  [ -z "${watch_pid:-}" ] || kill "$watch_pid" 2>/dev/null || true
  if [ -d "$HOME_DIR/state/procevent" ]; then
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"

# --- the fake relay CLI (same surface the bridge drives) ---------------------
cat > "$HOME_DIR/bin/buzz" <<'SH'
#!/usr/bin/env bash
since=0 until=99999999999 limit=50 cmd= 
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds|--channel|--event|--reply-to|--content) shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    messages) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  get) jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
        '[.[] | select(.created_at >= $s and .created_at <= $u)]
         | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "${FAKE_EVENTS:?}" ;;
  thread) printf '[]\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$HOME_DIR/bin/buzz"

# --- the long-running listener stub ------------------------------------------
# Stands in for bin/fm-buzz-listen.rs: it reports one connection and then emits
# `match` the moment the relay has a new owner mention for the bridge, which is
# the only contract bin/fm-procevent-buzz.sh consumes from the helper.
cat > "$HOME_DIR/bin/listener" <<'SH'
#!/usr/bin/env bash
home=${0%/bin/listener}
printf '%s\n' "$$" > "$home/listener.pid"
printf 'connected\n'
while [ "$SECONDS" -lt 180 ]; do
  if [ -e "$home/relay-pushed" ]; then rm -f "$home/relay-pushed"; printf 'match\n'; fi
  sleep 0.05
done
SH
chmod +x "$HOME_DIR/bin/listener"

printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.test.invalid
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
BUZZ_LISTENER=$HOME_DIR/bin/listener
EOF
printf '[]\n' > "$HOME_DIR/events.json"

fm() {
  PATH="$BASE_PATH" FM_HOME="$HOME_DIR" FMX_NOW_OVERRIDE=$NOW \
    FAKE_EVENTS="$HOME_DIR/events.json" "$@"
}
say() { printf '\n$ %s\n' "$*"; }

printf '=== Buzz push listener, end to end =======================================\n'
printf 'firstmate home: (temporary)   relay: fake, locally signed events\n'

say "bin/fm-buzz.sh status   # before enable"
fm "$ROOT/bin/fm-buzz.sh" status

say "bin/fm-buzz.sh enable"
fm "$ROOT/bin/fm-buzz.sh" enable

for i in $(seq 1 100); do
  fm "$ROOT/bin/fm-buzz.sh" status | grep -Fxq 'listener: connected' && break
  sleep 0.1
done
say "bin/fm-buzz.sh status   # the listener now holds the relay session"
fm "$ROOT/bin/fm-buzz.sh" status
helper_pid=$(cat "$HOME_DIR/listener.pid")
printf '\n# listener helper pid %s is alive and subscribed:\n' "$helper_pid"
ps -o pid=,stat=,command= -p "$helper_pid"

# The Buzz check sweep has just run, so the backstop is a full interval away.
: > "$HOME_DIR/state/.last-check"
printf 'announced:downtime:demo-generation\n' > "$HOME_DIR/state/.watcher-down"
printf '\n# The registered Buzz check is the backstop. It runs on the watcher check\n'
printf '# interval (FM_CHECK_INTERVAL, 300s by default) and state/.last-check is\n'
printf '# stamped now, so the next backstop sweep is ~300s away. Nothing below can\n'
printf '# have come from it.\n'

say "fm-watch.sh &   # the watcher firstmate normally has running"
FM_ROOT_OVERRIDE="$ROOT" FM_HEARTBEAT=999999 fm "$ROOT/bin/fm-watch.sh" \
  > "$HOME_DIR/watch.out" 2> "$HOME_DIR/watch.err" &
watch_pid=$!
for i in $(seq 1 200); do
  [ -e "$HOME_DIR/state/.last-watcher-beat" ] && break
  sleep 0.1
done

# --- the owner posts a mention ------------------------------------------------
ev=$(python3 -I "$SIGN" event "$OWNER_SK" "$NOW" 9 \
  "$(printf '[["h","%s"],["p","%s"]]' "$CHANNEL" "$BRIDGE")" \
  'can you take a look at the deploy?')
printf '%s\n' "$ev" | jq -s . > "$HOME_DIR/events.json"
posted=$(date +%s.%N)
printf '\n--- owner posts in the private channel at T+0 ---------------------------\n'
printf '%s\n' "$ev" | jq '{created_at, pubkey: .pubkey[0:16], content}'
: > "$HOME_DIR/relay-pushed"   # the relay pushes it to the live subscription

queued=
for i in $(seq 1 400); do
  if [ -z "$queued" ] && grep -q 'buzz-push' "$HOME_DIR/state/.wake-queue" 2>/dev/null; then
    queued=$(date +%s.%N)
  fi
  grep -q 'buzz-mention buzz-' "$HOME_DIR/watch.out" && break
  sleep 0.1
done
woke=$(date +%s.%N)
printf '\n--- the listener hands the mention off ----------------------------------\n'
printf '# the push row the listener'"'"'s poll appended to the durable wake queue:\n'
grep 'buzz-push' "$HOME_DIR/state/.wake-queue" | sed 's/^/  /'
printf 'T+%.1fs  mention handed to firstmate'"'"'s wake queue by the listener\n' \
  "$(python3 -I -c "print($queued - $posted)")"

printf '\n--- what the watcher handed firstmate -----------------------------------\n'
cat "$HOME_DIR/watch.out"
printf 'T+%.1fs  delivered on the watcher'"'"'s next cycle (FM_POLL, 15s by default)\n' \
  "$(python3 -I -c "print($woke - $posted)")"
printf '         the backstop check sweep would have taken up to 300s\n'
wait "$watch_pid" 2>/dev/null || true
watch_pid=

rid=$(cd "$HOME_DIR/state/x-inbox" && ls buzz-*.json | head -1)
printf '\n--- the request the mention became, in the shared Relay inbox -----------\n'
say "jq . state/x-inbox/$rid"
jq . "$HOME_DIR/state/x-inbox/$rid"

say "bin/fm-buzz.sh disable"
fm "$ROOT/bin/fm-buzz.sh" disable
say "bin/fm-buzz.sh status   # after disable"
fm "$ROOT/bin/fm-buzz.sh" status
for i in $(seq 1 100); do
  ps -o pid= -p "$helper_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
printf '\n# listener helper pid %s after disable: %s\n' "$helper_pid" \
  "$(ps -o stat= -p "$helper_pid" 2>/dev/null || echo 'gone')"
printf '=== end ==================================================================\n'
