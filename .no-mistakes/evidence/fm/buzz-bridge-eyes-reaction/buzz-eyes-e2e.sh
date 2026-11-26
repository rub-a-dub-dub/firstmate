#!/usr/bin/env bash
# End-to-end demonstration of the Buzz bridge's eyes acknowledgement, from the
# owner's point of view: the owner posts a mention, firstmate's bridge reads it,
# and the owner's message carries a 👀 from the bridge identity BEFORE the reply
# lands in the thread.
#
# Nothing is mocked inside firstmate: bin/fm-buzz-poll.sh, bin/fm-buzz-lib.sh,
# bin/fm-buzz.sh, bin/fm-x-reply.sh and bin/fm-buzz-verify.py all run for real
# against an invented bridge key. Only the `buzz` CLI is a stand-in - a tiny
# stateful relay that serves the owner's signed event, PERSISTS the reactions
# and messages the bridge writes to it, and answers in the pinned CLI's
# documented normalized write shape. The owner's view at the end is rendered
# from that persisted relay state, not from firstmate's own logs.
set -u
ROOT=$1
OUT=$2
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
NOW=$(date +%s)

HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buzz-eyes-e2e.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin" "$HOME_DIR/relay"
printf '[]\n' > "$HOME_DIR/relay/reactions.json"
printf '[]\n' > "$HOME_DIR/relay/messages.json"

# --- the stand-in relay, reached only through the pinned CLI's argv ---------
cat > "$HOME_DIR/bin/buzz" <<'SH'
#!/usr/bin/env bash
set -u
author=$(python3 -I "$FAKE_SIGN" pubkey "${BUZZ_PRIVATE_KEY:?the relay refuses an unsigned write}")
printf 'buzz %s\n' "$*" >> "${FAKE_TRANSCRIPT:?}"
cmd= event= emoji= reply= channel= since=0 until=99999999999 limit=50
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds) shift 2 ;;
    --emoji) emoji=$2; shift 2 ;;
    --event) event=$2; shift 2 ;;
    --reply-to) reply=$2; shift 2 ;;
    --channel) channel=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --content) shift 2 ;;
    messages|reactions) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  get)
    jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
      '[.[] | select(.created_at >= $s and .created_at <= $u)] | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' \
      "${FAKE_EVENTS:?}" ;;
  thread)
    jq -c --arg root "$event" '[.[] | select(.id == $root)]' "${FAKE_EVENTS:?}" ;;
  add)
    cat >/dev/null 2>&1 || true
    [ -z "${FAKE_REACTION_FAIL:-}" ] || { printf 'relay refused the write\n' >&2; exit 2; }
    jq --arg e "$event" --arg m "$emoji" --arg a "$author" --arg t "$(date -u +%H:%M:%S)" \
      '. + [{target_event:$e, emoji:$m, author:$a, at:$t}]' "$FAKE_REACTIONS" > "$FAKE_REACTIONS.n" \
      && mv "$FAKE_REACTIONS.n" "$FAKE_REACTIONS"
    printf '{"event_id":"%064d","accepted":true,"message":""}\n' 9 ;;
  send)
    jq -Rs --arg r "$reply" --arg a "$author" --arg t "$(date -u +%H:%M:%S)" \
      '{reply_to:$r, author:$a, at:$t, content:.}' | jq -s --slurpfile old "$FAKE_MESSAGES" '$old[0] + .' \
      > "$FAKE_MESSAGES.n" && mv "$FAKE_MESSAGES.n" "$FAKE_MESSAGES"
    printf '{"event_id":"%064d","accepted":true,"mention_pubkeys":[],"message":""}\n' 7 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$HOME_DIR/bin/buzz"

printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.example.invalid
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
EOF

run_in() {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" \
  FM_HOME="$HOME_DIR" FAKE_SIGN="$SIGN" FAKE_TRANSCRIPT="$HOME_DIR/cli-transcript.txt" \
  FAKE_EVENTS="$HOME_DIR/events.json" FAKE_REACTIONS="$HOME_DIR/relay/reactions.json" \
  FAKE_MESSAGES="$HOME_DIR/relay/messages.json" "$@"
}

say() { printf '%s\n' "$*" >> "$OUT"; }
: > "$OUT"
: > "$HOME_DIR/cli-transcript.txt"

say "BUZZ BRIDGE: EYES ACKNOWLEDGEMENT, END TO END"
say "owner pubkey  $OWNER"
say "bridge pubkey $BRIDGE"
say ""

say "== 1. the owner turns the bridge on =="
say "\$ bin/fm-buzz.sh enable"
run_in "$ROOT/bin/fm-buzz.sh" enable >> "$OUT" 2>&1
say ""

say "== 2. the owner posts a mention in the Buzz channel =="
NOW=$(date +%s)
MENTION=$(python3 -I "$SIGN" event "$OWNER_SK" "$NOW" 9 \
  "$(printf '[["h","%s"],["p","%s"]]' "$CHANNEL" "$BRIDGE")" \
  'firstmate: can you look at the flaky lint shard before standup?')
EID=$(printf '%s' "$MENTION" | jq -r .id)
printf '%s\n' "$MENTION" | jq -s . > "$HOME_DIR/events.json"
say "event id $EID"
say "  content: $(printf '%s' "$MENTION" | jq -r .content)"
say ""

sleep 1
say "== 3. firstmate's watcher runs the bridge check =="
say "\$ bin/fm-buzz-poll.sh        # wake lines the watcher acts on:"
run_in "$ROOT/bin/fm-buzz-poll.sh" 2>&1 | sed 's/^/  /' >> "$OUT"
RID=$(ls "$HOME_DIR/state/x-inbox" | head -1)
RID=${RID%.json}
say ""
say "staged in the Relay inbox as request $RID:"
jq '{platform, text}' "$HOME_DIR/state/x-inbox/$RID.json" | sed 's/^/  /' >> "$OUT"
say ""

say "== 4. what the owner sees on their own message, right now =="
say "   (rendered from the stand-in relay's stored reaction state)"
jq -r --arg eid "$EID" --arg owner "$OWNER" '
  "  ---------------------------------------------------------------",
  "   " + ($owner[0:8]) + "...  (the owner)",
  "   firstmate: can you look at the flaky lint shard before standup?",
  "",
  (map(select(.target_event == $eid))
   | if length == 0 then "     (no reactions on this message)"
     else "     " + (map(.emoji) | join(" ")) + "  " + (length|tostring)
          + "   <- " + (.[0].author[0:8]) + "... (firstmate bridge), " + .[0].at + "Z"
     end),
  "  ---------------------------------------------------------------"
' "$HOME_DIR/relay/reactions.json" >> "$OUT"
say ""
say "  reaction as the relay stored it:"
jq -c '.[]' "$HOME_DIR/relay/reactions.json" | sed 's/^/    /' >> "$OUT"
say ""

say "== 5. firstmate answers in the thread, after the 👀 =="
say "\$ bin/fm-x-reply.sh $RID -"
run_in "$ROOT/bin/fm-x-reply.sh" "$RID" - <<<'On it - the lint shard times out because the partitioner balances by byte size. Writing it up now.' >> "$OUT" 2>&1
say ""
say "the owner's thread, from the relay's stored messages:"
jq -r '.[] | "  ↳ " + (.author[0:8]) + "… at " + .at + ": " + .content' "$HOME_DIR/relay/messages.json" >> "$OUT"
say ""

say "== 6. ordering the owner actually experiences =="
say "   every relay write the bridge made, in order:"
nl -ba "$HOME_DIR/cli-transcript.txt" | sed -e 's/--relay [^ ]*/--relay <relay>/' -e 's/^/  /' >> "$OUT"
say ""

say "== 7. the same mention, with FMX_DRY_RUN set =="
HOME2=$(mktemp -d "${TMPDIR:-/tmp}/buzz-eyes-dry.XXXXXX")
cp -R "$HOME_DIR/bin" "$HOME_DIR/config" "$HOME_DIR/bridge.key" "$HOME_DIR/events.json" "$HOME2/" 2>/dev/null
mkdir -p "$HOME2/state" "$HOME2/relay"
printf '[]\n' > "$HOME2/relay/reactions.json"; printf '[]\n' > "$HOME2/relay/messages.json"
sed -i.bak "s|$HOME_DIR|$HOME2|g" "$HOME2/config/buzz-bridge.env"; rm -f "$HOME2/config/buzz-bridge.env.bak"
printf 'FMX_DRY_RUN=1\n' > "$HOME2/.env"
: > "$HOME2/cli-transcript.txt"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" \
  FM_HOME="$HOME2" FAKE_SIGN="$SIGN" FAKE_TRANSCRIPT="$HOME2/cli-transcript.txt" \
  FAKE_EVENTS="$HOME2/events.json" FAKE_REACTIONS="$HOME2/relay/reactions.json" \
  FAKE_MESSAGES="$HOME2/relay/messages.json" "$ROOT/bin/fm-buzz.sh" enable >/dev/null 2>&1
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" \
  FM_HOME="$HOME2" FAKE_SIGN="$SIGN" FAKE_TRANSCRIPT="$HOME2/cli-transcript.txt" \
  FAKE_EVENTS="$HOME2/events.json" FAKE_REACTIONS="$HOME2/relay/reactions.json" \
  FAKE_MESSAGES="$HOME2/relay/messages.json" "$ROOT/bin/fm-buzz-poll.sh" 2>&1 | sed 's/^/  /' >> "$OUT"
say "   relay reaction state after the dry run: $(jq -c . "$HOME2/relay/reactions.json")"
say "   relay writes attempted:                 $(grep -c 'reactions add' "$HOME2/cli-transcript.txt" || true)"
rm -rf "$HOME2"
say ""
say "== 8. a relay that refuses the reaction =="
HOME3=$(mktemp -d "${TMPDIR:-/tmp}/buzz-eyes-fail.XXXXXX")
cp -R "$HOME_DIR/bin" "$HOME_DIR/config" "$HOME_DIR/bridge.key" "$HOME_DIR/events.json" "$HOME3/" 2>/dev/null
mkdir -p "$HOME3/state" "$HOME3/relay"
printf '[]\n' > "$HOME3/relay/reactions.json"; printf '[]\n' > "$HOME3/relay/messages.json"
sed -i.bak "s|$HOME_DIR|$HOME3|g" "$HOME3/config/buzz-bridge.env"; rm -f "$HOME3/config/buzz-bridge.env.bak"
: > "$HOME3/cli-transcript.txt"
rdry() { PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" \
  FM_HOME="$HOME3" FAKE_SIGN="$SIGN" FAKE_TRANSCRIPT="$HOME3/cli-transcript.txt" FAKE_REACTION_FAIL=1 \
  FAKE_EVENTS="$HOME3/events.json" FAKE_REACTIONS="$HOME3/relay/reactions.json" \
  FAKE_MESSAGES="$HOME3/relay/messages.json" "$@"; }
rdry "$ROOT/bin/fm-buzz.sh" enable >/dev/null 2>&1
say "\$ bin/fm-buzz-poll.sh        # the relay refuses the reactions-add write with exit 2"
rdry "$ROOT/bin/fm-buzz-poll.sh" 2>&1 | sed 's/^/  /' >> "$OUT"
say "   the mention is still staged:           $(ls "$HOME3/state/x-inbox" 2>/dev/null | wc -l | tr -d ' ') inbox record"
say "   relay reaction state:                   $(jq -c . "$HOME3/relay/reactions.json")"
say "\$ bin/fm-buzz-poll.sh        # the next sweep neither re-offers nor retries the 👀"
second=$(rdry "$ROOT/bin/fm-buzz-poll.sh" 2>&1)
say "  ${second:-(no wake, nothing re-offered)}"
say "   reactions-add attempts across both sweeps: $(grep -c 'reactions add' "$HOME3/cli-transcript.txt" || true)"
say "\$ bin/fm-buzz.sh status      # a lost 👀 leaves no diagnostic, by the owner's own decision"
rdry "$ROOT/bin/fm-buzz.sh" status 2>&1 | sed 's/^/  /' >> "$OUT"
rm -rf "$HOME3"

say ""
say "== 9. a catch-up sweep: three mentions posted while firstmate was down =="
HOME4=$(mktemp -d "${TMPDIR:-/tmp}/buzz-eyes-catchup.XXXXXX")
cp -R "$HOME_DIR/bin" "$HOME_DIR/config" "$HOME_DIR/bridge.key" "$HOME4/" 2>/dev/null
mkdir -p "$HOME4/state" "$HOME4/relay"
printf '[]\n' > "$HOME4/relay/reactions.json"; printf '[]\n' > "$HOME4/relay/messages.json"
sed -i.bak "s|$HOME_DIR|$HOME4|g" "$HOME4/config/buzz-bridge.env"; rm -f "$HOME4/config/buzz-bridge.env.bak"
: > "$HOME4/cli-transcript.txt"
rcatch() { PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" \
  FM_HOME="$HOME4" FAKE_SIGN="$SIGN" FAKE_TRANSCRIPT="$HOME4/cli-transcript.txt" \
  FAKE_EVENTS="$HOME4/events.json" FAKE_REACTIONS="$HOME4/relay/reactions.json" \
  FAKE_MESSAGES="$HOME4/relay/messages.json" "$@"; }
rcatch "$ROOT/bin/fm-buzz.sh" enable >/dev/null 2>&1
T=$(date +%s)
TAGS=$(printf '[["h","%s"],["p","%s"]]' "$CHANNEL" "$BRIDGE")
{
  python3 -I "$SIGN" event "$OWNER_SK" "$T"       9 "$TAGS" 'first: any news on the gate?'
  python3 -I "$SIGN" event "$OWNER_SK" $((T + 1)) 9 "$TAGS" 'second: and the lint shard?'
  python3 -I "$SIGN" event "$OWNER_SK" $((T + 2)) 9 "$TAGS" 'third: standup is in ten minutes'
} | jq -s . > "$HOME4/events.json"
sleep 3
say "\$ bin/fm-buzz-poll.sh"
rcatch "$ROOT/bin/fm-buzz-poll.sh" 2>&1 | sed 's/^/  /' >> "$OUT"
say ""
say "  each of the owner's three messages, and the 👀 it got (send order shown):"
python3 -I "$HOME4/render.py" "$HOME4/relay/reactions.json" "$HOME4/events.json" >> "$OUT" 2>/dev/null || \
python3 -I -c '
import json, sys
reactions = json.load(open(sys.argv[1]))
events = json.load(open(sys.argv[2]))
order = {r["target_event"]: i for i, r in enumerate(reactions)}
for ev in sorted(events, key=lambda e: -e["created_at"]):
    i = order.get(ev["id"])
    mark = u"\U0001f440 sent #%d" % (i + 1) if i is not None else "no reaction"
    print("    %-42s %s" % (chr(34) + ev["content"] + chr(34), mark))
' "$HOME4/relay/reactions.json" "$HOME4/events.json" >> "$OUT"
say "   reactions-add writes this sweep: $(grep -c 'reactions add' "$HOME4/cli-transcript.txt" || true) for 3 mentions - no per-sweep cap"
rm -rf "$HOME4"
