#!/usr/bin/env bash
# End-to-end demonstration of the home-local Buzz bridge's eyes acknowledgement.
#
# Runs the REAL bin/fm-buzz.sh enable and bin/fm-buzz-poll.sh against a stub
# `buzz` CLI that behaves like a tiny relay: it stores the channel's signed
# events, serves `messages get`, and APPLIES `reactions add` to its own stored
# state. The owner's view of the channel is then rendered from that relay state,
# so the 👀 shown below is a reaction the relay actually holds, not a log line.
set -u
ROOT=$1
OUT=$2
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
PATH_BASE=/usr/bin:/bin:/usr/sbin:/sbin
for t in jq python3; do d=$(command -v "$t") && PATH_BASE="$(dirname "$d"):$PATH_BASE"; done

OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
NOW=$(date +%s)

HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buzz-eyes-demo.XXXXXX")
RELAY="$HOME_DIR/relay"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin" "$RELAY"
printf '[]\n' > "$RELAY/events.json"
printf '{}\n' > "$RELAY/reactions.json"

# ---- the stub relay CLI (stands in for the pinned relay-v0.3.0 buzz binary) --
cat > "$HOME_DIR/bin/buzz" <<'SH'
#!/usr/bin/env bash
set -u
R=${DEMO_RELAY:?}
printf '$ buzz %s\n' "$*" >> "$R/wire.log"
since=0 until=99999999999 limit=50 cmd= event= emoji=
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds|--channel) shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --event) event=$2; shift 2 ;;
    --emoji) emoji=$2; shift 2 ;;
    messages|reactions) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  get)
    jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
      '[.[] | select(.created_at >= $s and .created_at <= $u)]
       | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "$R/events.json"
    ;;
  add)
    # apply the reaction to relay state, keyed by event id, deduplicated by actor
    jq --arg e "$event" --arg m "$emoji" --arg by "${BUZZ_PRIVATE_KEY:0:8}" \
      '.[$e] = ((.[$e] // []) + [{emoji:$m, by:$by}] | unique_by(.emoji + .by))' \
      "$R/reactions.json" > "$R/reactions.tmp" && mv "$R/reactions.tmp" "$R/reactions.json"
    printf '{"accepted":true}\n'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$HOME_DIR/bin/buzz"

printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.demo.invalid
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
EOF

post() {  # <created_at> <content>
  local ev
  ev=$(python3 -I "$SIGN" event "$OWNER_SK" "$1" 9 \
        "$(printf '[["h","%s"],["p","%s"]]' "$CHANNEL" "$BRIDGE")" "$2")
  jq --argjson e "$ev" '. + [$e]' "$RELAY/events.json" > "$RELAY/e.tmp" && mv "$RELAY/e.tmp" "$RELAY/events.json"
  printf '%s' "$ev" | jq -r .id
}

run() { env PATH="$PATH_BASE" FM_HOME="$HOME_DIR" DEMO_RELAY="$RELAY" "$@"; }

# The owner's view of the channel, rendered from relay state only.
render() {
  jq -r --slurpfile rx "$RELAY/reactions.json" --arg owner "$OWNER" '
    def ago($n): "  " + ($n | strftime("%H:%M:%S"));
    sort_by(.created_at)[]
    | . as $e
    | ($rx[0][$e.id] // []) as $r
    | "  owner  " + ($e.created_at|strftime("%H:%M:%S")) + "   " + $e.content
      + (if ($r|length) > 0 then "\n         " + ([$r[].emoji]|join(" ")) + "  " + (($r|length)|tostring) + "   (from firstmate bridge)" else "" end)
  ' "$RELAY/events.json"
}

exec > >(tee "$OUT") 2>&1

echo "=============================================================="
echo " Buzz bridge: eyes acknowledgement on a picked-up message"
echo "=============================================================="
echo
echo "--- 1. owner turns the bridge on -----------------------------"
run "$ROOT/bin/fm-buzz.sh" enable
jq -cn --argjson since "$((NOW - 600))" '{since:$since}' > "$HOME_DIR/state/buzz/cursor.json"
chmod 600 "$HOME_DIR/state/buzz/cursor.json"
echo
echo "--- 2. owner posts one mention in the channel ----------------"
EID=$(post $((NOW - 60)) '@Firstmate how is the fleet looking this morning?')
echo "owner's Buzz channel, as the owner sees it BEFORE firstmate polls:"
render
echo
echo "(no reaction yet - nothing has read it)"
echo
echo "--- 3. the watcher runs one bridge check ---------------------"
echo "wake emitted to firstmate:"
run "$ROOT/bin/fm-buzz-poll.sh" | sed 's/^/  /'
echo
echo "owner's Buzz channel AFTER the check (rendered from relay state):"
render
echo
echo "relay state for that event id:"
jq -c --arg e "$EID" '{(($e[0:12]) + "..."): .[$e]}' "$RELAY/reactions.json" | sed 's/^/  /'
echo
echo "--- 4. the same message is read again on the next sweep ------"
run "$ROOT/bin/fm-buzz-poll.sh" | sed 's/^/  /'
echo "reaction count still 1 (no duplicate 👀 for an already-bound message):"
render
echo
echo "--- 5. catch-up: 7 mentions arrive while the laptop slept ----"
printf '[]\n' > "$RELAY/events.json"; printf '{}\n' > "$RELAY/reactions.json"
jq -cn --argjson since "$((NOW - 600))" '{since:$since}' > "$HOME_DIR/state/buzz/cursor.json"
chmod 600 "$HOME_DIR/state/buzz/cursor.json"
for i in 1 2 3 4 5 6 7; do post $((NOW - 400 + i * 10)) "backlog mention $i" >/dev/null; done
echo "wakes emitted (every mention is still ingested):"
run "$ROOT/bin/fm-buzz-poll.sh" | sed 's/^/  /'
echo
echo "owner's channel after the catch-up sweep:"
render
echo
echo "--- 6. a sweep already out of check budget skips the ack ------"
printf '[]\n' > "$RELAY/events.json"; printf '{}\n' > "$RELAY/reactions.json"
jq -cn --argjson since "$((NOW - 600))" '{since:$since}' > "$HOME_DIR/state/buzz/cursor.json"
chmod 600 "$HOME_DIR/state/buzz/cursor.json"
post $((NOW - 20)) '@Firstmate budget-pressed sweep' >/dev/null
echo "wake emitted with FM_CHECK_TIMEOUT=5 (no room left for a bounded send):"
run env FM_CHECK_TIMEOUT=5 "$ROOT/bin/fm-buzz-poll.sh" | sed 's/^/  /'
echo "relay reactions (deliberately none - intake still completed above):"
jq -c . "$RELAY/reactions.json" | sed 's/^/  /'
echo
echo "--- 7. dry-run preview ---------------------------------------"
printf '[]\n' > "$RELAY/events.json"; printf '{}\n' > "$RELAY/reactions.json"
jq -cn --argjson since "$((NOW - 600))" '{since:$since}' > "$HOME_DIR/state/buzz/cursor.json"
chmod 600 "$HOME_DIR/state/buzz/cursor.json"
post $((NOW - 30)) '@Firstmate dry run please' >/dev/null
printf 'FMX_DRY_RUN=1\n' > "$HOME_DIR/.env"
run "$ROOT/bin/fm-buzz-poll.sh" 2>&1 | sed 's/^/  /'
echo "relay reactions after a dry run (must be empty):"
jq -c . "$RELAY/reactions.json" | sed 's/^/  /'
echo
echo "--- 8. exact wire calls the bridge made to the relay ---------"
grep -n 'reactions add' "$RELAY/wire.log" | sed 's/^/  /'
echo
echo "=============================================================="
rm -rf "$HOME_DIR"
