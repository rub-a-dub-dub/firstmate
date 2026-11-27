#!/usr/bin/env bash
# Manual end-to-end drill for the Buzz bridge stale-timestamp retry.
#
# Reproduces the reported incident: a dark wake makes the relay reject the
# bridge's NIP-98 signature with the exact payload captured from the Buzz CLI
# (rc=3, "event timestamp outside +/-60s window (delta: 106s)"), then the next
# signature is accepted. Everything the owner would see is printed: the wake
# lines fm-buzz-poll.sh emits (the watcher turns these into notifications), the
# delivered request, and `fm-buzz.sh status`.
#
# Usage: buzz-skew-drill.sh <repo-root> <label> <skew-mode: once|persistent|membership>
set -u
ROOT=$1 LABEL=$2 MODE=$3
NOW=1800000000
OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")

HOME_DIR=${TMPDIR:-/tmp}/fm-buzz-drill-$LABEL
rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"

# A fake pinned Buzz CLI. On `messages get` it refuses the signature the way the
# real relay did during the dark wake, with the stderr payload from the
# diagnostic capture, and then serves the channel feed.
cat > "$HOME_DIR/bin/buzz" <<'SH'
#!/usr/bin/env bash
log=${FAKE_BUZZ_LOG:?}
printf 'buzz %s\n' "$*" >> "$log"
since=0 until=99999999999 limit=50 cmd=
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds|--emoji|--channel|--event|--reply-to|--content) shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    messages|reactions) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$cmd" = get ]; then
  marker=$log.refused
  refuse=
  case "${FAKE_SKEW_MODE:?}" in
    once) [ -e "$marker" ] || refuse=timestamp ;;
    persistent) refuse=timestamp ;;
    membership) refuse=membership ;;
  esac
  if [ -n "$refuse" ]; then
    : > "$marker"
    if [ "$refuse" = timestamp ]; then
      printf '%s\n' '{"error":"auth_error","message":"auth error: relay requires authentication (NIP-98: NIP-98 HTTP Auth verification failed: event timestamp outside ±60s window (delta: 106s))","retryable":false}' >&2
    else
      printf '%s\n' '{"error":"auth_error","message":"auth error: not a member of this channel","retryable":false}' >&2
    fi
    exit 3
  fi
  jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
    '[.[] | select(.created_at >= $s and .created_at <= $u)]
     | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "${FAKE_EVENTS:?}"
  exit 0
fi
printf '{"accepted":true}\n'
SH
chmod +x "$HOME_DIR/bin/buzz"

printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.test.invalid
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
EOF
python3 -I "$SIGN" event "$OWNER_SK" $((NOW - 60)) 9 \
  "[[\"h\",\"$CHANNEL\"],[\"p\",\"$BRIDGE\"]]" '@Firstmate what is the branch status?' \
  | jq -s . > "$HOME_DIR/events.json"
: > "$HOME_DIR/cli.log"

run_in() {
  PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin} FM_HOME="$HOME_DIR" \
    FMX_NOW_OVERRIDE=$NOW FAKE_BUZZ_LOG="$HOME_DIR/cli.log" FAKE_EVENTS="$HOME_DIR/events.json" \
    FAKE_SKEW_MODE="$MODE" "$@"
}
run_in "$ROOT/bin/fm-buzz.sh" enable >/dev/null || { echo "enable failed"; exit 1; }
jq -cn --argjson since $NOW '{since:$since}' > "$HOME_DIR/state/buzz/cursor.json"

echo "### $LABEL: relay refuses the bridge signature ($MODE)"
echo
echo "--- owner-visible wake lines from one sweep of bin/fm-buzz-poll.sh ---"
out=$(run_in "$ROOT/bin/fm-buzz-poll.sh" 2>"$HOME_DIR/poll.stderr")
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(none - no notification)"; fi
echo
echo "--- Buzz CLI calls the bridge made ---"
sed 's/--relay [^ ]* //' "$HOME_DIR/cli.log"
echo
echo "--- the owner's request, as delivered to the inbox ---"
found=0
for f in "$HOME_DIR"/state/x-inbox/buzz-*.json; do
  [ -f "$f" ] || continue
  found=1
  jq -r '"\(input_filename | split("/") | last | rtrimstr(".json")): \(.text)"' "$f"
done
[ "$found" = 1 ] || echo "(no request delivered)"
echo
echo "--- fm-buzz.sh status ---"
run_in "$ROOT/bin/fm-buzz.sh" status | sed -n '/^bridge:/p;/^cursor:/p;/last poll diagnostic/p'
echo
echo "--- poll stderr (must stay empty: raw CLI auth payload is private) ---"
if [ -s "$HOME_DIR/poll.stderr" ]; then cat "$HOME_DIR/poll.stderr"; else echo "(empty)"; fi
