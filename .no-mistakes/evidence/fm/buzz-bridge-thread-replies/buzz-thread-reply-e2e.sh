#!/usr/bin/env bash
# End-to-end owner-experience walkthrough of the Buzz bridge's unaddressed
# thread replies (the four accepted rules). Hermetic: invented keys, events
# signed by tests/fixtures/buzz-sign.py, the pinned Buzz CLI replaced by the
# same fake the behavior suite uses (extracted from tests/fm-buzz-bridge.test.sh
# so it cannot drift). No relay is contacted.
#
# Usage: buzz-thread-reply-e2e.sh <firstmate-repo-root> [baseline-bin-dir]
set -u
ROOT=$1
BASE_BIN=${2:-}
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buzz-e2e.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
for tool in jq python3; do d=$(command -v "$tool") && BASE_PATH="$(dirname "$d"):$BASE_PATH"; done

OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OTHER_SK=3333333333333333333333333333333333333333333333333333333333333333
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
OTHER=$(python3 -I "$SIGN" pubkey "$OTHER_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
NOW=1800000000

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"
# The fake Buzz CLI, lifted verbatim out of the behavior suite.
sed -n "/buzz\" <<'SH'$/,/^SH$/p" "$ROOT/tests/fm-buzz-bridge.test.sh" \
  | sed '1d;$d' > "$HOME_DIR/bin/buzz"
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
printf '[]\n' > "$HOME_DIR/events.json"
: > "$HOME_DIR/cli.log"
: > "$HOME_DIR/sent.jsonl"

run_in() {
  PATH="$BASE_PATH" FM_HOME="$HOME_DIR" FMX_NOW_OVERRIDE=$NOW FAKE_BUZZ_LOG="$HOME_DIR/cli.log" \
    FAKE_EVENTS="$HOME_DIR/events.json" FAKE_SENT="$HOME_DIR/sent.jsonl" \
    FAKE_EXPECT_SECRET=$BRIDGE_SK "$@"
}
sign() { python3 -I "$SIGN" event "$@"; }
set_events() { printf '%s\n' "$@" | jq -s . > "$HOME_DIR/events.json"; }
# The channel as the relay holds it, in the owner's words.
feed() {
  jq -r --arg o "$OWNER" --arg b "$BRIDGE" --arg t "$OTHER" 'sort_by(.created_at)[]
    | ((if .pubkey == $o then "owner    " elif .pubkey == $b then "Firstmate" else "teammate " end)
       + "  " + (.content | tostring))' "$HOME_DIR/events.json"
}
poll() { run_in "${1:-$ROOT}/bin/fm-buzz-poll.sh"; }
inbox_text() {  # <request-id>
  jq -r .text "$HOME_DIR/state/x-inbox/$1.json" 2>/dev/null
}
scene() { printf '\n==================== %s ====================\n' "$*"; }
# Report what the watcher saw and what Firstmate was handed.
verdict() {
  local out=$1
  if [ -z "$out" ]; then
    printf 'watcher wake  : (silence - nothing reached Firstmate)\n'
    return
  fi
  printf 'watcher wake  : %s\n' "$out"
  local rid
  while read -r kind rid; do
    [ "$kind" = buzz-mention ] || continue
    printf 'Firstmate gets: %s\n' "$(inbox_text "$rid")"
  done <<<"$out"
}

run_in "$ROOT/bin/fm-buzz.sh" enable >/dev/null || { echo "enable failed"; exit 1; }
# Elapsed-time stand-in: the bridge has already polled up to now.
(umask 077; jq -cn --argjson s "$NOW" '{since:$s}' > "$HOME_DIR/state/buzz/cursor.json")
printf 'Buzz bridge enabled for channel %s\n' "$CHANNEL"
printf 'owner %s... / Firstmate %s... / teammate %s...\n' "${OWNER:0:12}" "${BRIDGE:0:12}" "${OTHER:0:12}"

# ---------------------------------------------------------------- scene 1
scene "1. the owner starts a thread WITH an explicit @Firstmate"
ROOT_EV=$(sign "$OWNER_SK" $((NOW - 280)) 9 \
  "$(jq -cn --arg c "$CHANNEL" --arg b "$BRIDGE" '[["h",$c],["p",$b]]')" '@Firstmate how is the fleet?')
ROOT_ID=$(jq -r .id <<<"$ROOT_EV")
set_events "$ROOT_EV"
feed
out=$(poll); verdict "$out"
RID=${out#buzz-mention }
printf 'Firstmate answers in the thread:\n'
run_in "$ROOT/bin/fm-x-reply.sh" "$RID" - <<<'All green: 3 boats, no failures.' | sed 's/^/  /'
printf 'what the bridge actually sent to Buzz: %s\n' \
  "$(jq -c '{reply_to, content}' "$HOME_DIR/sent.jsonl" | tail -1)"

# The pinned CLI threads that send under the root; this is that reply as the
# relay now holds it.
THREAD_TAGS=$(jq -cn --arg c "$CHANNEL" --arg r "$ROOT_ID" '[["h",$c],["e",$r,"","root"]]')
FM_ANSWER=$(sign "$BRIDGE_SK" $((NOW - 260)) 9 "$THREAD_TAGS" 'All green: 3 boats, no failures.')

# ---------------------------------------------------------------- scene 2
scene "2. RULE 1 - a plain reply in that same thread, no @Firstmate"
REPLY=$(sign "$OWNER_SK" $((NOW - 30)) 9 "$THREAD_TAGS" 'and how is the battery holding up?')
set_events "$ROOT_EV" "$FM_ANSWER" "$REPLY"
feed
out=$(poll); verdict "$out"
if [ -n "$BASE_BIN" ]; then
  printf -- '--- the same channel against the pre-change bridge (base commit) ---\n'
  printf -- '(request state is reset for each arm, so the explicit root mention is\n'
  printf -- ' delivered again by both; the plain reply is the difference)\n'
  rm -rf "$HOME_DIR/state/buzz/requests" "$HOME_DIR/state/x-inbox" "$HOME_DIR/state/x-context"
  (umask 077; jq -cn --argjson s "$NOW" '{since:$s}' > "$HOME_DIR/state/buzz/cursor.json")
  base_out=$(poll "$BASE_BIN")
  verdict "$base_out"
  rm -rf "$HOME_DIR/state/buzz/requests" "$HOME_DIR/state/x-inbox" "$HOME_DIR/state/x-context"
  (umask 077; jq -cn --argjson s "$NOW" '{since:$s}' > "$HOME_DIR/state/buzz/cursor.json")
  out=$(poll); printf -- '--- and against this change again ---\n'; verdict "$out"
fi

# ---------------------------------------------------------------- scene 3
scene "3. RULE 1 boundary - a plain message OUTSIDE any Firstmate thread"
LOOSE=$(sign "$OWNER_SK" $((NOW - 25)) 9 "[[\"h\",\"$CHANNEL\"]]" 'note to self: order new fenders')
set_events "$ROOT_EV" "$FM_ANSWER" "$LOOSE"
feed
out=$(poll); verdict "$out"

# ---------------------------------------------------------------- scene 4
scene "4. RULE 2 - in the Firstmate thread, but @-mentioning the teammate"
FOR_OTHER=$(sign "$OWNER_SK" $((NOW - 20)) 9 \
  "$(jq -c --arg p "$OTHER" '. + [["p",$p]]' <<<"$THREAD_TAGS")" '@teammate can you grab the keys?')
set_events "$ROOT_EV" "$FM_ANSWER" "$FOR_OTHER"
feed
out=$(poll); verdict "$out"

# ---------------------------------------------------------------- scene 5
scene "5. RULE 3 - the teammate joins the thread, then a plain owner reply"
JOIN=$(sign "$OTHER_SK" $((NOW - 600)) 9 "$THREAD_TAGS" 'jumping in - I am on the dock')
SHARED=$(sign "$OWNER_SK" $((NOW - 15)) 9 "$THREAD_TAGS" 'so what is the plan then?')
set_events "$ROOT_EV" "$FM_ANSWER" "$JOIN" "$SHARED"
feed
out=$(poll); verdict "$out"

# ---------------------------------------------------------------- scene 6
scene "6. RULE 4 - an explicit @Firstmate in that same shared thread"
EXPLICIT=$(sign "$OWNER_SK" $((NOW - 10)) 9 \
  "$(jq -c --arg b "$BRIDGE" '. + [["p",$b]]' <<<"$THREAD_TAGS")" '@Firstmate plan us a route, please')
set_events "$ROOT_EV" "$FM_ANSWER" "$JOIN" "$SHARED" "$EXPLICIT"
feed
out=$(poll); verdict "$out"

scene "bounded relay traffic for the whole walkthrough"
printf 'thread history reads: %s (cap 4 per poll, 50 events each)\n' \
  "$(grep -c 'messages thread' "$HOME_DIR/cli.log")"
printf 'every CLI call signed as the bridge key: %s\n' \
  "$(grep -c 'key=ok' "$HOME_DIR/cli.log")/$(wc -l < "$HOME_DIR/cli.log" | tr -d ' ')"
printf 'bridge secret ever present in argv: %s\n' \
  "$(grep -c "$BRIDGE_SK" "$HOME_DIR/cli.log")"
