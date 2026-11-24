#!/usr/bin/env bash
# End-to-end walkthrough of the stage-1 Buzz bridge, driving only the real
# scripts in bin/. No relay is contacted: the pinned `buzz` CLI is replaced by a
# fake that serves signed fixture events and records what the bridge sends, and
# every key is invented. Owner messages are signed with the project's own
# tests/fixtures/buzz-sign.py, so the bridge verifies them for real. The clock
# advances between steps the way real time would (FMX_NOW_OVERRIDE), so enable,
# the owner's messages, each watcher sweep and the off period are ordered.
set -u
ROOT=${ROOT:?set ROOT to the worktree}
SIGN="$ROOT/tests/fixtures/buzz-sign.py"
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buzz-walkthrough.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT

OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
T0=1800000000
CLOCK=$T0

at() { TZ=UTC date -u -r "$1" '+%H:%M:%S' 2>/dev/null || printf '%s' "$1"; }
say() { printf '\n%s\n' "$*"; }
step() { printf '\n\n===== %s =====\n[clock %sZ]\n' "$1" "$(at "$CLOCK")"; }
cmd() { printf '\n$ %s\n' "$*"; }

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/buzz" <<'SH'
#!/usr/bin/env bash
log=${FAKE_BUZZ_LOG:?}
if [ "${BUZZ_PRIVATE_KEY:-}" = "$FAKE_EXPECT_SECRET" ]; then key=ok; else key=wrong; fi
printf 'argv=%s key=%s\n' "$*" "$key" >> "$log"
since=0 until=99999999999 limit=50 cmd= channel= reply=
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds) shift 2 ;;
    --channel) channel=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --reply-to) reply=$2; shift 2 ;;
    --content) shift 2 ;;
    messages) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  get) jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
        '[.[] | select(.created_at >= $s and .created_at <= $u)] | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "${FAKE_EVENTS:?}" ;;
  send) jq -cRs --arg c "$channel" --arg r "$reply" '{channel:$c, reply_to:$r, content:.}' >> "${FAKE_SENT:?}"
        printf '{"accepted":true,"event_id":"%064d","mention_pubkeys":[],"message":""}\n' 7 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$HOME_DIR/bin/buzz"
printf 'Public key: %s\nSecret key: %s\n' "$BRIDGE" "$BRIDGE_SK" > "$HOME_DIR/bridge.key"
cat > "$HOME_DIR/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://buzz.fleet.example
BUZZ_CHANNEL=$CHANNEL
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$HOME_DIR/bridge.key
BUZZ_CLI=$HOME_DIR/bin/buzz
EOF
printf '[]\n' > "$HOME_DIR/events.json"
: > "$HOME_DIR/cli.log"; : > "$HOME_DIR/sent.jsonl"

BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
for tool in jq python3; do d=$(command -v "$tool") && BASE_PATH="$(dirname "$d"):$BASE_PATH"; done
run() { PATH="$BASE_PATH" FM_HOME="$HOME_DIR" FMX_NOW_OVERRIDE=$CLOCK \
  FAKE_BUZZ_LOG="$HOME_DIR/cli.log" FAKE_EVENTS="$HOME_DIR/events.json" \
  FAKE_SENT="$HOME_DIR/sent.jsonl" FAKE_EXPECT_SECRET=$BRIDGE_SK "$@"; }
sweep() { cmd "state/buzz-bridge.check.sh   # $1"; run "$HOME_DIR/state/buzz-bridge.check.sh"; }
: > "$HOME_DIR/posts.jsonl"
# owner_posts <epoch> <content>: the owner sends a signed kind-9 channel message
# mentioning the bridge. Appends to the channel feed; leaves its event id in
# $LAST_POST_ID (a file, so a subshell cannot swallow the feed).
owner_posts() {
  local ev
  ev=$(python3 -I "$SIGN" event "$OWNER_SK" "$1" 9 "[[\"h\",\"$CHANNEL\"],[\"p\",\"$BRIDGE\"]]" "$2")
  printf '%s\n' "$ev" >> "$HOME_DIR/posts.jsonl"
  jq -s . "$HOME_DIR/posts.jsonl" > "$HOME_DIR/events.json"
  printf '%s' "$ev" | jq -r .id > "$HOME_DIR/last-post-id"
  printf '  %sZ  owner      %s\n' "$(at "$1")" "$2"
}
rid_for() { local f; for f in "$HOME_DIR"/state/x-inbox/buzz-*.json; do
  [ -f "$f" ] && [ "$(jq -r .text "$f")" = "$1" ] && basename "$f" .json; done; }
channel_view() {
  printf '\n  #firstmate-ops - private Stream channel on buzz.fleet.example\n'
  printf '  ------------------------------------------------------------\n'
  jq -r --arg o "$OWNER" '.[] | select(.pubkey == $o) | "\(.created_at)\t\(.content)"' "$HOME_DIR/events.json" > "$HOME_DIR/view.tsv"
  while IFS=$'\t' read -r ts txt; do printf '  %sZ  owner      %s\n' "$(at "$ts")" "$txt"; done < "$HOME_DIR/view.tsv"
  if [ -s "$HOME_DIR/sent.jsonl" ]; then
    printf '  --- replies the bridge posted into those threads ---\n'
    jq -r '"  Firstmate  -> reply_to \(.reply_to[0:12])...  \(.content)"' "$HOME_DIR/sent.jsonl"
  fi
}

printf '%s\n' "Stage 1 Buzz bridge - the owner's front door to the existing firstmate session"
printf '%s\n' "----------------------------------------------------------------------------"
printf 'owner  pubkey  %s\nbridge pubkey  %s\nchannel        %s\ncommunity      buzz.fleet.example (self-hosted relay)\n' \
  "$OWNER" "$BRIDGE" "$CHANNEL"

step "1. A fresh home: the bridge is off, and an off bridge never touches the relay"
cmd "bin/fm-buzz.sh status"; run "$ROOT/bin/fm-buzz.sh" status
printf '\nThe owner mentions Firstmate anyway, before turning the bridge on:\n'
owner_posts $((T0 - 3600)) '@Firstmate are you there?'
cmd "bin/fm-buzz-poll.sh   # what a watcher sweep would run"
run "$ROOT/bin/fm-buzz-poll.sh"; printf '(exit %s, no output)\n' $?
printf 'buzz CLI calls made:    %s\n' "$(wc -l < "$HOME_DIR/cli.log" | tr -d ' ')"
printf 'inbox requests staged:  %s\n' "$(ls "$HOME_DIR"/state/x-inbox/ 2>/dev/null | wc -l | tr -d ' ')"

CLOCK=$((T0))
step "2. The owner turns the bridge on"
cmd "bin/fm-buzz.sh enable"; run "$ROOT/bin/fm-buzz.sh" enable
cmd "bin/fm-buzz.sh status"; run "$ROOT/bin/fm-buzz.sh" status

CLOCK=$((T0 + 90))
step "3. The owner @mentions Firstmate in the private Buzz channel"
owner_posts $((T0 + 45)) '@Firstmate the staging deploy looks wrong - can you take a look?'
MENTION_ID=$(cat "$HOME_DIR/last-post-id")
printf '  (signed kind-9 channel message, event id %s)\n' "$MENTION_ID"

: > "$HOME_DIR/cli.log"
step "4. A watcher sweep runs the check that enable registered: the bridge poll"
sweep "the watcher execs this, capped at FM_CHECK_TIMEOUT"
RID=$(rid_for '@Firstmate the staging deploy looks wrong - can you take a look?')
printf '\n^ that line is the wake firstmate receives, naming the request id.\n'
printf '\n-- the one scoped, NIP-98-signed read the bridge made (secret never in argv) --\n'
sed 's/^/  /' "$HOME_DIR/cli.log"
printf '\n-- state/x-inbox/%s.json : the SAME inbox the X/Discord Relay surface uses --\n' "$RID"
run jq . "$HOME_DIR/state/x-inbox/$RID.json" | sed 's/^/  /'
printf '\n-- state/buzz/requests/%s.json : the ingress binding, written before the cursor moved --\n' "$RID"
run jq . "$HOME_DIR/state/buzz/requests/$RID.json" | sed 's/^/  /'

CLOCK=$((T0 + 120))
step "5. Firstmate acknowledges in the owner's thread, through the shared Relay command"
cmd "bin/fm-x-reply.sh $RID -   <<< 'On it - pulling the staging deploy logs now.'"
run "$ROOT/bin/fm-x-reply.sh" "$RID" - <<<'On it - pulling the staging deploy logs now.'
printf '\n-- what the bridge sent, signed by the bridge key, natively in the thread --\n'
tail -n1 "$HOME_DIR/sent.jsonl" | jq . | sed 's/^/  /'
printf '  reply_to is the owner original (%s): %s\n' "${MENTION_ID:0:12}..." \
  "$([ "$(tail -n1 "$HOME_DIR/sent.jsonl" | jq -r .reply_to)" = "$MENTION_ID" ] && echo yes || echo NO)"

CLOCK=$((T0 + 900))
step "6. The request runs the normal fleet lifecycle, then the outcome lands in the thread"
printf 'window=w\nkind=ship\n' > "$HOME_DIR/state/task-deploy.meta"
cmd "bin/fm-x-link.sh task-deploy $RID   # bind the Buzz request to a fleet task"
run "$ROOT/bin/fm-x-link.sh" task-deploy "$RID" >/dev/null && echo "linked"
grep -E '^x_(platform|request)' "$HOME_DIR/state/task-deploy.meta" | sed 's/^/  /'
cmd "bin/fm-x-followup.sh task-deploy --final -   <<< 'Fixed: ...'"
run "$ROOT/bin/fm-x-followup.sh" task-deploy --final - <<<'Fixed: staging was pinned to the old image. Redeployed and verified, PR #4821.'
printf '\nmessages the bridge sent for this request: %s (one ack, one final - the budget)\n' "$(wc -l < "$HOME_DIR/sent.jsonl" | tr -d ' ')"
cmd "bin/fm-x-reply.sh $RID --followup -   <<< 'one more thing'   # past the final"
run "$ROOT/bin/fm-x-reply.sh" "$RID" --followup - <<<'one more thing' 2>&1 | sed 's/^/  /'
printf '(nothing sent past the ack and final)\n'
channel_view

CLOCK=$((T0 + 1600))
step "7. The approval condition: the owner can turn the bridge off"
cmd "bin/fm-buzz.sh disable"; run "$ROOT/bin/fm-buzz.sh" disable
cmd "bin/fm-buzz.sh status"; run "$ROOT/bin/fm-buzz.sh" status

CLOCK=$((T0 + 1750))
: > "$HOME_DIR/cli.log"
step "8. The owner messages while the bridge is off; nothing happens"
owner_posts $((T0 + 1700)) '@Firstmate ship the hotfix'
printf '\nThe watcher check itself is gone - disable retired it:\n'
cmd "ls state/buzz-bridge.check.sh"
ls "$HOME_DIR/state/buzz-bridge.check.sh" 2>&1 | sed "s#$HOME_DIR/#  #"
cmd "bin/fm-buzz-poll.sh   # run the poll directly anyway"
run "$ROOT/bin/fm-buzz-poll.sh"
printf '(no output; buzz CLI calls this sweep: %s)\n' "$(wc -l < "$HOME_DIR/cli.log" | tr -d ' ')"
cmd "bin/fm-x-reply.sh $RID -   <<< 'still here?'   # a reply while off"
run "$ROOT/bin/fm-x-reply.sh" "$RID" - <<<'still here?' 2>&1 | sed 's/^/  /'
printf 'messages sent while off: 0 (total still %s)\n' "$(wc -l < "$HOME_DIR/sent.jsonl" | tr -d ' ')"

CLOCK=$((T0 + 1800))
step "9. Only an explicit enable turns it back on, and it reads forward only"
cmd "bin/fm-buzz.sh enable"; run "$ROOT/bin/fm-buzz.sh" enable
printf 'cursor seeded at the enable moment: %s\n' "$(cat "$HOME_DIR/state/buzz/cursor.json")"
CLOCK=$((T0 + 1830))
sweep "first sweep after re-enable"
printf '(no wake: the message sent while off is behind the enable fence)\n'
CLOCK=$((T0 + 1900))
printf '\nThe owner messages again, now that the bridge is back on:\n'
owner_posts $((T0 + 1860)) '@Firstmate status report please'
sweep "second sweep - where a look-back that outlived the fence would reach into the off period"
printf 'cursor: %s\n' "$(cat "$HOME_DIR/state/buzz/cursor.json")"
printf '\nWhat the re-enabled bridge has in the inbox:\n'
for f in "$HOME_DIR"/state/x-inbox/buzz-*.json; do
  [ -f "$f" ] && printf '  %s  %s\n' "$(basename "$f" .json)" "$(jq -r .text "$f")"
done
printf '\n"ship the hotfix" (sent while off) ever staged?   %s\n' \
  "$([ -n "$(rid_for '@Firstmate ship the hotfix')" ] && echo 'YES - LEAK' || echo 'no')"
printf '"ship the hotfix" ever answered in the channel?   %s\n' \
  "$(grep -cF 'hotfix' "$HOME_DIR/sent.jsonl" | grep -qx 0 && echo 'no' || echo 'YES - LEAK')"

CLOCK=$((T0 + 1950))
step "10. The post-re-enable mention is answered normally"
NEWRID=$(rid_for '@Firstmate status report please')
cmd "bin/fm-x-reply.sh $NEWRID -   <<< 'All green: ...'"
run "$ROOT/bin/fm-x-reply.sh" "$NEWRID" - <<<'All green: 3 tasks shipped, none blocked.'
channel_view
say "Done."
