#!/usr/bin/env bash
# Behavior tests for the home-local Buzz bridge: bin/fm-buzz.sh (enable,
# disable, status), bin/fm-buzz-poll.sh intake, and bin/fm-buzz-reply.sh as
# reached through the shared Relay entry points bin/fm-x-reply.sh,
# bin/fm-x-dismiss.sh, bin/fm-x-link.sh and bin/fm-x-followup.sh.
#
# Hermetic: every key is invented, every event is signed here by
# tests/fixtures/buzz-sign.py, and the Buzz CLI is a fakebin script that serves
# the fixture events and records sends. No relay is contacted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in jq python3; do
  dir=$(command -v "$tool" 2>/dev/null) && BASE_PATH="$(dirname "$dir"):$BASE_PATH"
done
TMP_ROOT=$(fm_test_tmproot fm-buzz-bridge-tests)
SIGN="$ROOT/tests/fixtures/buzz-sign.py"

OWNER_SK=1111111111111111111111111111111111111111111111111111111111111111
BRIDGE_SK=2222222222222222222222222222222222222222222222222222222222222222
OTHER_SK=3333333333333333333333333333333333333333333333333333333333333333
OWNER=$(python3 -I "$SIGN" pubkey "$OWNER_SK")
BRIDGE=$(python3 -I "$SIGN" pubkey "$BRIDGE_SK")
OTHER=$(python3 -I "$SIGN" pubkey "$OTHER_SK")
CHANNEL=0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b
OTHER_CHANNEL=9e8d7c6b-5a49-4382-a716-152433425160
NOW=1800000000

# sign_event <secret> <created_at> <kind> <tags-json> <content>
sign_event() {
  python3 -I "$SIGN" event "$@"
}

mention_tags() {  # [channel]
  printf '[["h","%s"],["p","%s"]]' "${1:-$CHANNEL}" "$BRIDGE"
}

# The fake CLI mirrors the pinned buzz CLI surface the bridge uses:
#   --relay <url> --format json messages get --channel C --kinds 9 --since S --before U --limit L
#   --relay <url> --format json messages thread --channel C --event E --limit L
#   --relay <url> --format json messages send --channel C --reply-to E --content -
# It logs argv and whether the bridge secret reached it through the environment.
make_fake_cli() {
  local home=$1
  mkdir -p "$home/bin"
  cat > "$home/bin/buzz" <<'SH'
#!/usr/bin/env bash
log=${FAKE_BUZZ_LOG:?}
if [ "${BUZZ_PRIVATE_KEY:-}" = "$FAKE_EXPECT_SECRET" ]; then key=ok; else key=wrong; fi
printf 'argv=%s key=%s\n' "$*" "$key" >> "$log"
since=0 until=99999999999 limit=50 cmd= channel= reply= event=
while [ $# -gt 0 ]; do
  case "$1" in
    --relay|--format|--kinds) shift 2 ;;
    --channel) channel=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --before) until=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --event) event=$2; shift 2 ;;
    --reply-to) reply=$2; shift 2 ;;
    --content) shift 2 ;;
    messages) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$cmd" in
  get)
    [ "${FAKE_GET_RC:-0}" = 0 ] || exit "$FAKE_GET_RC"
    jq -c --argjson s "$since" --argjson u "$until" --argjson l "$limit" \
      '[.[] | select(.created_at >= $s and .created_at <= $u)]
       | sort_by(-.created_at) | .[:$l] | sort_by(.created_at)' "${FAKE_EVENTS:?}"
    ;;
  thread)
    [ "${FAKE_THREAD_RC:-0}" = 0 ] || exit "$FAKE_THREAD_RC"
    [ -z "${FAKE_THREAD_DELAY:-}" ] || sleep "$FAKE_THREAD_DELAY"
    jq -c --arg root "$event" --arg c "$channel" --argjson l "$limit" '
      map(select(any(.tags[]; .[0] == "h" and .[1] == $c))) |
      (map(select(any(.tags[]; .[0] == "e" and .[1] == $root)))
       | sort_by(-.created_at) | .[:$l]) + map(select(.id == $root))
    ' "${FAKE_EVENTS:?}"
    ;;
  send)
    [ "${FAKE_SEND_RC:-0}" = 0 ] || exit "$FAKE_SEND_RC"
    jq -cRs --arg c "$channel" --arg r "$reply" '{channel:$c, reply_to:$r, content:.}' >> "${FAKE_SENT:?}"
    printf '{"accepted":true,"event_id":"%064d","mention_pubkeys":[],"message":""}\n' 7
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/bin/buzz"
}

# new_home <name> [channel]: a home with valid Buzz config, the fake CLI, an
# invented key file, and an empty event feed. The bridge stays disabled.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  make_fake_cli "$home"
  printf 'Public key: %s\nSecret key: %s\n\nSet BUZZ_PRIVATE_KEY to the secret key to use this identity.\n' \
    "$BRIDGE" "$BRIDGE_SK" > "$home/bridge.key"
  cat > "$home/config/buzz-bridge.env" <<EOF
BUZZ_RELAY_URL=https://relay.test.invalid
BUZZ_CHANNEL=${2:-$CHANNEL}
BUZZ_OWNER_PUBKEY=$OWNER
BUZZ_BRIDGE_PUBKEY=$BRIDGE
BUZZ_BRIDGE_KEY_FILE=$home/bridge.key
BUZZ_CLI=$home/bin/buzz
EOF
  printf '[]\n' > "$home/events.json"
  : > "$home/cli.log"
  : > "$home/sent.jsonl"
  printf '%s\n' "$home"
}

set_events() {  # <home> <event-json>...
  local home=$1
  shift
  printf '%s\n' "$@" | jq -s . > "$home/events.json"
}

# run_in <home> <command> [args...]: run a firstmate script against the home.
run_in() {
  local home=$1
  shift
  PATH="$BASE_PATH" FM_HOME="$home" FMX_NOW_OVERRIDE=$NOW FAKE_BUZZ_LOG="$home/cli.log" \
    FAKE_EVENTS="$home/events.json" FAKE_SENT="$home/sent.jsonl" FAKE_EXPECT_SECRET=$BRIDGE_SK "$@"
}

poll() {
  run_in "$1" "$ROOT/bin/fm-buzz-poll.sh"
}

# The watcher caps every custom check at FM_CHECK_TIMEOUT (30s by default) with
# timeout(1), gtimeout(1), or a perl alarm, in that order (bin/fm-watch.sh
# run_check_process); stock macOS has no timeout(1). Resolved to an absolute
# path here because run_in restricts PATH.
CHECK_TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)

# age_cursor <home> <epoch>: replace the enable-time cursor seed with an older
# fence, the way real elapsed time would. Enabling seeds {since: now}, and the
# tests freeze the clock, so without this a held cursor and a freshly advanced
# one carry the same value.
age_cursor() {
  (umask 077; mkdir -p "$1/state/buzz") || fail "age_cursor: cannot prepare $1/state/buzz"
  jq -cn --argjson since "$2" '{since:$since}' > "$1/aged-cursor.json"
  mv "$1/aged-cursor.json" "$1/state/buzz/cursor.json"
  chmod 600 "$1/state/buzz/cursor.json"
}

# poll_bounded <home> [seconds]: the poll under the watcher's bound. Exits 124
# when the bound cut it short, exactly as the watcher's own runner reports.
poll_bounded() {
  local home=$1 limit=${2:-30}
  if [ -n "$CHECK_TIMEOUT_BIN" ]; then
    run_in "$home" "$CHECK_TIMEOUT_BIN" "$limit" "$ROOT/bin/fm-buzz-poll.sh"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    run_in "$home" perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } my $stop = sub { $SIG{TERM} = "IGNORE"; kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$limit" bash "$ROOT/bin/fm-buzz-poll.sh"
  fi
}

# enable_from_off <home>: turn the bridge on and leave the enable-time fence in
# place, so the first read starts at the enable moment. Only the tests about that
# fence want this; the clock is frozen, so it admits nothing older than NOW.
enable_from_off() {
  run_in "$1" "$ROOT/bin/fm-buzz.sh" enable >/dev/null || fail "enable failed for $1"
}

# enable <home>: a bridge that is on and has polled up to now, which is the state
# nearly every test wants - the cursor is the fence its last poll left, not the
# enable seed, so a fixture from the last few minutes is still in the window.
enable() {
  enable_from_off "$1"
  age_cursor "$1" "$NOW"
}

# fm_buzz_rid_for <home> <inbox text>: the request id whose inbox record has that text.
fm_buzz_rid_for() {
  local f
  for f in "$1"/state/x-inbox/buzz-*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r .text "$f")" = "$2" ] || continue
    basename "$f" .json
    return 0
  done
}

only_rid() {
  local f
  for f in "$1"/state/x-inbox/buzz-*.json; do
    [ -f "$f" ] && basename "$f" .json
  done
}

test_disabled_by_default() {
  local home out
  home=$(new_home default-off)
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" '@Firstmate status')"
  out=$(poll "$home"); expect_code 0 $? "disabled poll exit"
  assert_equals "" "$out" "a disabled bridge must stay silent"
  assert_equals "" "$(cat "$home/cli.log")" "a disabled bridge must never call the Buzz CLI"
  assert_absent "$home/state/x-inbox" "a disabled bridge must not stage requests"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" status)
  assert_contains "$out" "bridge: disabled" "status must report the default off state"
  assert_contains "$out" "watcher check: not registered" "an off home has no Buzz watcher check"
  rm -f "$home/config/buzz-bridge.env"
  out=$(poll "$home"); expect_code 0 $? "unconfigured poll exit"
  assert_equals "" "$out" "a home without Buzz configured is a silent no-op"
  pass "the Buzz bridge is off by default and an off bridge never polls"
}

test_enable_validates_config() {
  local home out rc
  home=$(new_home enable-invalid)
  sed -i.bak 's#^BUZZ_RELAY_URL=.*#BUZZ_RELAY_URL=wss://relay.test.invalid#' "$home/config/buzz-bridge.env"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" enable 2>&1); rc=$?
  expect_code 1 "$rc" "enable with a websocket relay URL"
  assert_contains "$out" "BUZZ_RELAY_URL must be an https URL" "only the relay's https endpoint is configurable"
  assert_absent "$home/config/buzz-bridge.enabled" "a refused enable must not turn the bridge on"
  assert_absent "$home/state/buzz-bridge.check.sh" "a refused enable must not arm the watcher check"
  mv "$home/config/buzz-bridge.env.bak" "$home/config/buzz-bridge.env"
  sed -i.bak '/^BUZZ_CLI=/d' "$home/config/buzz-bridge.env"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" enable 2>&1); rc=$?
  expect_code 1 "$rc" "enable without the pinned CLI path"
  assert_contains "$out" "BUZZ_CLI" "enable must require an explicit pinned CLI"
  assert_absent "$home/config/buzz-bridge.enabled" "a refused enable must leave the bridge off"
  pass "enable refuses an invalid configuration and leaves the bridge off"
}

test_enable_poll_ingests_verified_owner_mention() {
  local home out rid ev eid
  home=$(new_home ingest)
  enable "$home"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" status)
  assert_contains "$out" "bridge: enabled" "status must report the bridge on"
  assert_contains "$out" "watcher check: registered" "enable must register the watcher check"
  ev=$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" '@Firstmate how is the fleet?')
  eid=$(printf '%s' "$ev" | jq -r .id)
  set_events "$home" "$ev"
  out=$(poll "$home"); expect_code 0 $? "poll exit"
  rid=$(only_rid "$home")
  [ -n "$rid" ] || fail "an owner mention must stage one inbox request"
  assert_equals "buzz-mention $rid" "$out" "the poll must wake once with the request id"
  assert_equals buzz "$(jq -r .platform "$home/state/x-inbox/$rid.json")" "the inbox route must be Buzz, not Discord or X"
  assert_equals '@Firstmate how is the fleet?' "$(jq -r .text "$home/state/x-inbox/$rid.json")" "the inbox text is the signed message"
  assert_equals "$OWNER" "$(jq -r .buzz.signer "$home/state/x-inbox/$rid.json")" "the inbox records the verified signer"
  assert_equals "relay.test.invalid relay.test.invalid" \
    "$(jq -r .buzz.community "$home/state/x-inbox/$rid.json") $(jq -r .community "$home/state/buzz/requests/$rid.json")" \
    "the community is bound from the relay URL host"
  assert_equals "offered $eid $eid $OWNER" \
    "$(jq -r '[.state, .parent, .thread_root, .signer] | join(" ")' "$home/state/buzz/requests/$rid.json")" \
    "the binding records state, parent, thread root, and signer"
  assert_equals "$NOW" "$(jq -r .since "$home/state/buzz/cursor.json")" "a complete poll advances the cursor to its fence"
  assert_grep "key=ok" "$home/cli.log" "reads must sign as the configured bridge key"
  assert_no_grep "$BRIDGE_SK" "$home/cli.log" "the secret must never appear in CLI argv"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" status)
  assert_not_contains "$out" "$BRIDGE_SK" "status must never print the secret"
  assert_contains "$out" "pending requests: 1" "status counts pending Buzz requests"
  pass "an enabled bridge ingests a verified owner mention into the shared Relay inbox"
}

test_poll_drops_everything_else() {
  local home good tampered out
  home=$(new_home drop)
  enable "$home"
  good=$(sign_event "$OWNER_SK" $((NOW - 30)) 9 "$(mention_tags)" 'the one real request')
  tampered=$(sign_event "$OWNER_SK" $((NOW - 40)) 9 "$(mention_tags)" 'original' | jq -c '.content = "tampered"')
  set_events "$home" \
    "$good" \
    "$tampered" \
    "$(sign_event "$OTHER_SK" $((NOW - 50)) 9 "$(mention_tags)" 'not the owner')" \
    "$(sign_event "$OWNER_SK" $((NOW - 51)) 9 "[[\"h\",\"$CHANNEL\"]]" 'no bridge mention')" \
    "$(sign_event "$OWNER_SK" $((NOW - 52)) 9 "$(mention_tags "$OTHER_CHANNEL")" 'other channel')" \
    "$(sign_event "$OWNER_SK" $((NOW - 53)) 40003 "$(mention_tags)" 'an edit')" \
    "$(sign_event "$BRIDGE_SK" $((NOW - 55)) 9 "$(mention_tags)" 'the bridge itself')" \
    "$(sign_event "$OWNER_SK" $((NOW - 90000)) 9 "$(mention_tags)" 'older than the age limit')" \
    "$(sign_event "$OWNER_SK" $((NOW - 56)) 9 "$(mention_tags)" 'bad signature' | jq -c '.sig = ("0" * 128)')"
  out=$(poll "$home")
  assert_equals 1 "$(find "$home/state/x-inbox" -name 'buzz-*.json' | wc -l | tr -d ' ')" "only the valid owner mention may be staged"
  assert_equals 'the one real request' "$(jq -r .text "$home/state/x-inbox/$(only_rid "$home").json")" "the staged request is the valid one"
  assert_not_contains "$out" "buzz-bridge-error" "dropped events are silent"
  pass "the poll drops non-owner, untagged, other-channel, edit, own, stale, tampered and badly signed events silently"
}

test_poll_accepts_only_addressed_owner_thread_replies() {
  local home root root_id reply bridge_reply bridge_id tags out rid
  home=$(new_home addressed-threads)
  enable "$home"
  root=$(sign_event "$OWNER_SK" $((NOW - 90002)) 9 "[[\"h\",\"$CHANNEL\"]]" 'old thread root')
  root_id=$(jq -r .id <<<"$root")
  tags=$(jq -cn --arg c "$CHANNEL" --arg r "$root_id" '[["h",$c],["e",$r,"","root"]]')
  bridge_reply=$(sign_event "$BRIDGE_SK" $((NOW - 90001)) 9 "$tags" 'earlier bridge answer')
  bridge_id=$(jq -r .id <<<"$bridge_reply")
  tags=$(jq -c --arg b "$bridge_id" '. + [["e",$b,"","reply"]]' <<<"$tags")
  reply=$(sign_event "$OWNER_SK" $((NOW - 30)) 9 "$tags" 'plain follow-up')
  set_events "$home" "$root" "$bridge_reply" "$reply" \
    "$(sign_event "$OWNER_SK" $((NOW - 27)) 9 "$(jq -c --arg p "$OTHER" '. + [["p",$p]]' <<<"$tags")" 'for someone else')" \
    "$(sign_event "$OWNER_SK" $((NOW - 25)) 9 "[[\"h\",\"$CHANNEL\"]]" 'unaddressed top-level')"
  out=$(poll "$home")
  rid=$(only_rid "$home")
  assert_equals "buzz-mention $rid" "$out" "only the unaddressed reply to the bridge thread wakes"
  assert_equals 'plain follow-up' "$(jq -r .text "$home/state/x-inbox/$rid.json")" "the plain reply is the request"
  assert_equals "$root_id" "$(jq -r .thread_root "$home/state/buzz/requests/$rid.json")" "the reply keeps its original root"
  assert_equals 1 "$(grep -c 'messages thread .* key=ok' "$home/cli.log")" "one bounded thread lookup signs as the bridge"

  # Another member's post is outside the intake overlap but inside thread history.
  set_events "$home" "$root" "$bridge_reply" \
    "$(sign_event "$OTHER_SK" $((NOW - 90000)) 9 "$tags" 'someone else joined')" \
    "$(sign_event "$OWNER_SK" $((NOW - 20)) 9 "$tags" 'plain shared-thread reply')" \
    "$(sign_event "$OWNER_SK" $((NOW - 10)) 9 "$(jq -c --arg b "$BRIDGE" --arg p "$OTHER" '. + [["p",$b],["p",$p]]' <<<"$tags")" 'explicit shared-thread mention')"
  out=$(poll "$home")
  rid=$(fm_buzz_rid_for "$home" 'explicit shared-thread mention')
  [ -n "$rid" ] || fail "the explicit mention in the shared thread must be ingested"
  assert_equals "buzz-mention $rid" "$out" "the shared thread requires an explicit bridge mention"
  pass "owner thread replies are implicit only in threads Firstmate has answered that have no other participants or addressees"
}

test_poll_spends_the_thread_budget_on_signed_roots() {
  local home root root_id tags bridge_reply reply forged fabricated out rid i
  home=$(new_home starved-threads)
  enable "$home"
  root=$(sign_event "$OWNER_SK" $((NOW - 800)) 9 "[[\"h\",\"$CHANNEL\"]]" 'thread root')
  root_id=$(jq -r .id <<<"$root")
  tags=$(jq -cn --arg c "$CHANNEL" --arg r "$root_id" '[["h",$c],["e",$r,"","root"]]')
  bridge_reply=$(sign_event "$BRIDGE_SK" $((NOW - 700)) 9 "$tags" 'earlier bridge answer')
  reply=$(sign_event "$OWNER_SK" $((NOW - 30)) 9 "$tags" 'plain follow-up')
  set_events "$home" "$root" "$bridge_reply" "$reply"
  # Five junk-signature owner replies, each in a thread of its own and all newer
  # than the real reply. The id recomputes, so they pass every cheap check: a
  # relay serving events it never verified must not be able to spend the
  # bridge's bounded thread lookups on threads the owner never wrote in.
  for i in 1 2 3 4 5; do
    fabricated=$(printf 'ff%062d' "$i")
    forged=$(python3 -I "$SIGN" forge "$OWNER" $((NOW - 10 + i)) 9 \
      "$(jq -cn --arg c "$CHANNEL" --arg r "$fabricated" '[["h",$c],["e",$r,"","root"]]')" "flood" 1)
    jq -c --argjson f "$forged" '. + $f' "$home/events.json" > "$home/flooded.json"
    mv "$home/flooded.json" "$home/events.json"
  done
  out=$(poll "$home")
  rid=$(fm_buzz_rid_for "$home" 'plain follow-up')
  [ -n "$rid" ] || fail "an unsigned flood must not starve the real thread of its lookup"
  assert_equals "buzz-mention $rid" "$out" "only the signed unaddressed reply wakes"
  assert_equals "$root_id" "$(jq -r .thread_root "$home/state/buzz/requests/$rid.json")" \
    "the surviving reply keeps its own thread root"
  pass "the bounded thread lookups go to roots of signature-verified candidates only"
}

test_poll_requires_complete_thread_history() {
  local home root root_id tags reply bridge_reply late_reply forged out explicit rid
  home=$(new_home incomplete-thread)
  enable "$home"
  root=$(sign_event "$OWNER_SK" $((NOW - 800)) 9 "[[\"h\",\"$CHANNEL\"]]" 'thread root')
  root_id=$(jq -r .id <<<"$root")
  tags=$(jq -cn --arg c "$CHANNEL" --arg r "$root_id" '[["h",$c],["e",$r,"","reply"]]')
  reply=$(sign_event "$OWNER_SK" $((NOW - 10)) 9 "$tags" 'unaddressed reply')
  late_reply=$(sign_event "$BRIDGE_SK" $((NOW - 5)) 9 "$tags" 'later bridge answer')
  bridge_reply=$(sign_event "$BRIDGE_SK" $((NOW - 20)) 9 "$tags" 'earlier bridge answer')
  forged=$(jq -c '.sig = ("0" * 128)' <<<"$bridge_reply")
  set_events "$home" "$root" "$reply" "$late_reply" "$forged"
  assert_equals "" "$(poll "$home")" "neither a later reply nor an invalid signature supplies prior bridge participation"

  set_events "$home" "$root" "$reply" "$bridge_reply"
  out=$(FAKE_THREAD_RC=2 poll "$home")
  assert_equals "" "$out" "a failed thread lookup leaves the unaddressed reply silent"

  forged=$(python3 -I "$SIGN" forge "$OWNER" $((NOW - 1000)) 9 "$tags" 'older fixtures' 50)
  jq -c --argjson f "$forged" '. + $f' "$home/events.json" > "$home/full-thread.json"
  mv "$home/full-thread.json" "$home/events.json"
  assert_equals "" "$(poll "$home")" "a capped thread lookup cannot authorize the unaddressed reply"
  assert_equals "$NOW" "$(jq -r .since "$home/state/buzz/cursor.json")" "thread fallback leaves channel cursor behavior intact"

  explicit=$(sign_event "$OWNER_SK" $((NOW - 1)) 9 "$(mention_tags)" 'explicit mention during slow lookup')
  set_events "$home" "$root" "$reply" "$bridge_reply" "$explicit"
  out=$(FAKE_THREAD_DELAY=10 FM_CHECK_TIMEOUT=18 poll_bounded "$home" 18)
  expect_code 0 $? "a stalled thread lookup must not time out the entire poll"
  assert_contains "$(tail -1 "$home/cli.log")" "messages thread" "the slow thread lookup was attempted"
  rid=$(only_rid "$home")
  [ -n "$rid" ] || fail "slow history must leave time to deliver the explicit mention"
  assert_equals "buzz-mention $rid" "$out" "a timed-out lookup cannot authorize the unaddressed reply"
  assert_equals 'explicit mention during slow lookup' "$(jq -r .text "$home/state/x-inbox/$rid.json")" \
    "an explicit mention remains usable when thread history times out"
  pass "unaddressed replies require a complete signed thread with prior bridge participation"
}

test_poll_ingests_a_mention_that_carries_an_attachment() {
  local home rid out
  home=$(new_home media)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 \
    "[[\"h\",\"$CHANNEL\"],[\"p\",\"$BRIDGE\"],[\"imeta\",\"url https://x.invalid/a.png\"]]" \
    '@Firstmate what broke here?')"
  out=$(poll "$home")
  assert_contains "$out" "buzz-mention buzz-" "an owner mention with an attachment must still wake firstmate"
  rid=$(only_rid "$home")
  [ -n "$rid" ] || fail "an owner mention with an attachment must be staged"
  assert_equals '@Firstmate what broke here?' "$(jq -r .text "$home/state/x-inbox/$rid.json")" \
    "the caption is the request; the attachment is ignored, not fetched"
  pass "an owner mention carrying an attachment is ingested by its text"
}

test_poll_deduplicates_across_restarts() {
  local home rid out
  home=$(new_home dedupe)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'once only')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  rm -f "$home/state/buzz/cursor.json" "$home/state/x-inbox/$rid.json"
  out=$(poll "$home")
  assert_equals "" "$out" "a re-read of an accepted event must not wake again"
  assert_absent "$home/state/x-inbox/$rid.json" "a handled request must not be re-staged after a cursor loss"
  pass "event-id bindings deduplicate a re-read even after the cursor and inbox are gone"
}

# tests/fixtures/buzz-sign.py signs every "valid" fixture with bin/fm-buzz-verify.py's
# own curve arithmetic and id serialization, so the rest of this file cannot tell a
# correct verifier from a self-consistent wrong one. These are the external oracles:
# the BIP-340 specification's own vectors, and one kind-9 event whose id and
# signature were produced by the pinned buzz CLI's Rust nostr SDK.
test_verifier_matches_external_bip340_and_nip01_oracles() {
  local out
  out=$(python3 -I - "$ROOT/bin/fm-buzz-verify.py" <<'ORACLE'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("fm_buzz_verify", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
h = bytes.fromhex

# BIP-340 test vectors: index 1 verifies, index 6 must not (its R has odd y).
PK = h("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659")
MSG = h("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89")
VALID = h("6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341"
          "8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A")
ODD_Y_R = h("FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A1460297556"
            "3CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2")

# A kind-9 channel message the pinned buzz CLI produced and signed with an
# invented key, so its id fixes NIP-01 serialization and its sig fixes BIP-340
# independently of this repository.
EV = json.loads(
    '{"id":"cfff11735c08f496a29c282b755c0e08dccd2b8a1f599c8ba5f399020018e735",'
    '"pubkey":"466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27",'
    '"created_at":1795496866,"kind":9,'
    '"tags":[["h","0b7f6a4e-1c2d-4e3f-8a9b-0c1d2e3f4a5b"],'
    '["e","145ff9426ca62abbd3136d55b9f4c107660aa2b3600557ea0a78cd2086c4a6ca","","reply"]],'
    '"content":"Aye, on it.",'
    '"sig":"5551dead4ad1348cb144e8bd906562cc9cc0cf5297c30e1c3fa92092438e9ed7'
    '12279fb9c99a4e642856f0a5fa879e72d15ffb5522d31b4eadca5bcb5027c930"}'
)
TAMPERED = dict(EV, content="Bye, on it.")

print(
    "bip340-valid=%s bip340-odd-y-r=%s nip01-id=%s event-sig=%s tampered-id=%s tampered-sig=%s"
    % (
        v.schnorr_verify(MSG, PK, VALID),
        v.schnorr_verify(MSG, PK, ODD_Y_R),
        v.event_id(EV) == EV["id"],
        v.schnorr_verify(h(EV["id"]), h(EV["pubkey"]), h(EV["sig"])),
        v.event_id(TAMPERED) == EV["id"],
        v.schnorr_verify(h(v.event_id(TAMPERED)), h(EV["pubkey"]), h(EV["sig"])),
    )
)
ORACLE
  ) || fail "the external BIP-340 and NIP-01 oracle check did not run"
  assert_equals \
    "bip340-valid=True bip340-odd-y-r=False nip01-id=True event-sig=True tampered-id=False tampered-sig=False" \
    "$out" "the verifier must agree with the BIP-340 vectors and an independently signed event"
  pass "signature verification and event ids agree with external BIP-340 and NIP-01 oracles"
}

test_poll_holds_the_cursor_on_an_exactly_full_window() {
  local home out filler
  home=$(new_home exact)
  enable "$home"
  # Exactly the read budget of channel messages, the owner's mention among them.
  # The pinned CLI caps a read at that budget, so a full page is indistinguishable
  # from a larger window: the poll must deliver what it read and still hold the
  # cursor rather than risk advancing it past an unread mention.
  age_cursor "$home" $((NOW - 290))
  filler=$(jq -cn --arg ch "$CHANNEL" --argjson now "$NOW" '[range(0; 199)
    | {id: (tostring | ("0" * (64 - length)) + .), pubkey: ("f" * 64),
       created_at: ($now - 290 + .), kind: 9, tags: [["h", $ch]],
       content: "chatter", sig: ("0" * 128)}]')
  sign_event "$OWNER_SK" $((NOW - 30)) 9 "$(mention_tags)" 'the only real request' \
    | jq -c --argjson f "$filler" '[.] + $f' > "$home/events.json"
  out=$(poll "$home")
  assert_contains "$out" "buzz-mention buzz-" "the mention in an exactly full window is delivered"
  assert_contains "$out" "buzz-bridge-error catch-up range exceeds" \
    "a full page is reported as possibly over budget, because the read cannot see past it"
  assert_equals $((NOW - 290)) "$(jq -r .since "$home/state/buzz/cursor.json")" \
    "a full page must not advance the cursor past what the read could not see"
  pass "a full page delivers its mentions and holds the cursor, erring toward re-reading"
}

test_poll_delivers_the_newest_mention_past_the_read_budget() {
  local home out rc forged
  home=$(new_home flood)
  enable "$home"
  # A relay serving owner-attributed events it never verified: the ids recompute,
  # so every one of them reaches the signature check. More of them than one read
  # covers, and all older than the owner's mention.
  age_cursor "$home" $((NOW - 290))
  forged=$(python3 -I "$SIGN" forge "$OWNER" $((NOW - 290)) 9 "$(mention_tags)" 'forged' 250)
  sign_event "$OWNER_SK" $((NOW - 10)) 9 "$(mention_tags)" 'the newest real request' \
    | jq -c --argjson f "$forged" '[.] + $f' > "$home/events.json"
  out=$(poll_bounded "$home"); rc=$?
  expect_code 0 "$rc" "the poll must finish inside the watcher's check bound, not be cut at 124"
  assert_contains "$out" "buzz-mention buzz-" "a flood older than the mention must not bury it"
  assert_contains "$out" "buzz-bridge-error catch-up range exceeds" "an undrained window is a diagnostic wake"
  assert_equals $((NOW - 290)) "$(jq -r .since "$home/state/buzz/cursor.json")" \
    "an undrained window must not advance the cursor"
  assert_equals 'the newest real request' "$(jq -r .text "$home/state/x-inbox/$(only_rid "$home").json")" \
    "the owner's signed mention is the one that reaches the inbox"
  assert_equals 1 "$(grep -c 'messages get' "$home/cli.log")" "one poll makes exactly one read"
  pass "one newest-first read delivers the owner's latest mention under a flood, inside the watcher's bound"
}

test_poll_keeps_a_real_event_beside_its_junk_signature_copy() {
  local home out ev
  home=$(new_home twin)
  enable "$home"
  # A copy carrying a junk signature shares the real event's id, because the id
  # fixes every signed field but the signature.
  ev=$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'the real request')
  printf '%s\n' "$ev" | jq -c '.sig = ("0" * 128)' \
    | jq -sc --argjson real "$ev" '. + [$real]' > "$home/events.json"
  out=$(poll "$home")
  assert_contains "$out" "buzz-mention buzz-" "a junk-signature copy must not displace the real event"
  assert_equals 'the real request' "$(jq -r .text "$home/state/x-inbox/$(only_rid "$home").json")" \
    "the verified event is the one that reaches the inbox"
  pass "deduplication keys on id and signature, so a forged copy cannot stand in for a real event"
}

test_poll_refuses_a_key_file_that_is_not_hex() {
  local home out
  home=$(new_home nonhex)
  enable "$home"
  age_cursor "$home" $((NOW - 600))
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'never read')"
  printf 'Public key: %s\nSecret key: nsec1%s\n' "$BRIDGE" "$(printf 'q%.0s' $(seq 58))" > "$home/bridge.key"
  out=$(poll "$home")
  assert_contains "$out" "buzz-bridge-error cannot read the bridge secret" \
    "a secret the pinned CLI cannot take must be refused before any read"
  assert_equals $((NOW - 600)) "$(jq -r .since "$home/state/buzz/cursor.json")" \
    "an unusable secret must not advance the cursor"
  assert_equals "" "$(only_rid "$home")" "nothing may be ingested without a usable bridge key"
  pass "only the 64-hex secret the pinned buzz-admin emits is accepted"
}

test_poll_wakes_for_every_request_as_it_is_persisted() {
  local home out first second
  home=$(new_home perwake)
  enable "$home"
  set_events "$home" \
    "$(sign_event "$OWNER_SK" $((NOW - 90)) 9 "$(mention_tags)" 'the first ask')" \
    "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'the second ask')"
  out=$(poll "$home")
  first=$(fm_buzz_rid_for "$home" 'the first ask')
  second=$(fm_buzz_rid_for "$home" 'the second ask')
  [ -n "$first" ] && [ -n "$second" ] || fail "both owner mentions must be staged"
  assert_contains "$out" "buzz-mention $first" "the first request must be announced by id"
  assert_contains "$out" "buzz-mention $second" "the second request must be announced by id"
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^buzz-mention ')" "one wake line per persisted request"
  pass "every accepted request is announced by id as it is persisted, not once per poll"
}

test_poll_reannounces_a_staged_request() {
  local home out rid
  home=$(new_home restaged)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'say it again')"
  out=$(poll "$home")
  rid=$(only_rid "$home")
  assert_equals "buzz-mention $rid" "$out" "the first poll announces the request"
  # A poll cut between the wake and the "offered" mark leaves the binding staged.
  jq -c '.state = "staged"' "$home/state/buzz/requests/$rid.json" > "$home/restaged.json"
  mv "$home/restaged.json" "$home/state/buzz/requests/$rid.json"
  chmod 600 "$home/state/buzz/requests/$rid.json"
  out=$(poll "$home")
  assert_contains "$out" "buzz-mention $rid" "a staged request must be announced again"
  assert_equals offered "$(jq -r .state "$home/state/buzz/requests/$rid.json")" "the retry marks it offered"
  pass "a request left staged by an interrupted poll is re-announced, so a wake is never lost"
}

test_poll_holds_cursor_on_read_failure() {
  local home out
  home=$(new_home hold)
  enable "$home"
  age_cursor "$home" $((NOW - 600))
  out=$(FAKE_GET_RC=3 poll "$home")
  assert_contains "$out" "buzz-bridge-error relay refused the bridge key" "an auth refusal is a diagnostic wake"
  out=$(FAKE_GET_RC=3 poll "$home")
  assert_equals "" "$out" "the same diagnostic wakes only once"
  out=$(FAKE_GET_RC=2 poll "$home")
  assert_equals "" "$out" "a relay or network failure is silent"
  assert_equals $((NOW - 600)) "$(jq -r .since "$home/state/buzz/cursor.json")" \
    "a failed read must never advance the cursor"
  pass "a failed read holds the cursor, reports auth refusals once, and stays quiet on network failure"
}

test_reply_ack_and_one_final_in_thread() {
  local home rid eid out rc meta
  home=$(new_home reply)
  enable "$home"
  eid=$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'please look into it' | tee "$home/ev.json" | jq -r .id)
  set_events "$home" "$(cat "$home/ev.json")"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  printf 'Aye, on it.' > "$home/ack.txt"
  out=$(run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" --text-file "$home/ack.txt"); rc=$?
  expect_code 0 "$rc" "ack via fm-x-reply"
  assert_equals "$rid" "$out" "a sent reply echoes the request id"
  assert_equals "$CHANNEL $eid Aye, on it." "$(jq -r '[.channel, .reply_to, .content] | join(" ")' "$home/sent.jsonl")" \
    "the ack is a reply to the original event in the configured channel"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" --text-file "$home/ack.txt" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a second answer"
  meta="$home/state/task-b.meta"
  printf 'window=w\nkind=ship\n' > "$meta"
  run_in "$home" "$ROOT/bin/fm-x-link.sh" task-b "$rid" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "link a Buzz request to a task"
  assert_grep "x_platform=buzz" "$meta" "the link records the Buzz platform"
  out=$(run_in "$home" "$ROOT/bin/fm-x-followup.sh" task-b --final - <<<"Done - the fix is in."); rc=$?
  expect_code 0 "$rc" "final via fm-x-followup"
  assert_equals 2 "$(wc -l < "$home/sent.jsonl" | tr -d ' ')" "the final outcome is the second and last message"
  assert_equals "$eid" "$(tail -n1 "$home/sent.jsonl" | jq -r .reply_to)" "the final lands in the same thread"
  assert_no_grep "x_request=" "$meta" "the final clears the task link"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" --followup - <<<"one more" 2>/dev/null; rc=$?
  expect_code 9 "$rc" "a follow-up past the final"
  assert_equals 2 "$(wc -l < "$home/sent.jsonl" | tr -d ' ')" "nothing is sent past the ack and final"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" --image "$home/ack.txt" --followup - <<<"img" 2>/dev/null; rc=$?
  expect_code 2 "$rc" "an image reply"
  pass "a Buzz request gets one ack and one final in the original thread through the shared Relay commands"
}

test_reply_dry_run_records_without_sending() {
  local home rid out rc
  home=$(new_home dry)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'dry please')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  out=$(FMX_DRY_RUN=1 run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"Would answer." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run reply"
  assert_equals "$rid" "$out" "a dry run echoes the request id"
  assert_equals "" "$(cat "$home/sent.jsonl")" "a dry run sends nothing"
  assert_equals "buzz answer Would answer." "$(jq -r '[.platform, .endpoint, .text] | join(" ")' "$home/state/x-outbox/$rid.json")" \
    "a dry run records the would-be Buzz reply"
  assert_equals false "$(jq -r .answer_posted "$home/state/buzz/requests/$rid.json")" \
    "a previewed answer must not spend the one answer the request gets"
  out=$(run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"Answered for real."); rc=$?
  expect_code 0 "$rc" "a real answer after a dry-run answer"
  assert_equals "Answered for real." "$(jq -r .content "$home/sent.jsonl")" \
    "the owner still gets the answer the preview did not consume"
  assert_equals true "$(jq -r .answer_posted "$home/state/buzz/requests/$rid.json")" \
    "the real answer is the one that spends the budget"
  pass "dry-run records the would-be Buzz reply without sending or spending the budget"
}

test_reply_dry_run_writes_a_receipt_without_spending_the_budget() {
  local home rid rc
  home=$(new_home dryreceipt)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'receipt please')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  # bin/fm-public-followup.sh refuses to close a delivery whose receipt is
  # missing or untyped, dry run included, so a preview must still write one.
  FMX_DRY_RUN=1 run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" --followup \
    --receipt-file "$home/receipt.json" - <<<"Would follow up." >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "dry-run follow-up with a receipt"
  assert_equals "$rid followup 1 true" \
    "$(jq -r '[.request_id, .endpoint, .chunks, .dry_run] | join(" ")' "$home/receipt.json")" \
    "a previewed follow-up still writes its typed receipt, marked dry_run"
  assert_equals false "$(jq -r .followup_posted "$home/state/buzz/requests/$rid.json")" \
    "a previewed follow-up must not spend the final"
  pass "a dry-run reply writes the caller's receipt while leaving the budget alone"
}

test_disable_stops_intake_and_replies_until_enabled() {
  local home rid out rc bound offperiod
  home=$(new_home disable)
  enable "$home"
  bound=$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'before disable')
  set_events "$home" "$bound"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" disable); rc=$?
  expect_code 0 "$rc" "disable"
  assert_contains "$out" "disabled" "disable confirms"
  assert_absent "$home/state/buzz-bridge.check.sh" "disable retires the watcher check"
  assert_absent "$home/state/buzz-bridge.check-trust" "disable retires the check trust binding"
  : > "$home/cli.log"
  # Stand the clock still but age the surviving cursor, so it is the pre-disable
  # fence a real off period would leave behind. The off-period mention sits
  # inside the poll's read overlap, the span the enable fence has to cover: a
  # fence set at the bare enable moment would still read back behind it.
  age_cursor "$home" $((NOW - 1800))
  offperiod=$(sign_event "$OWNER_SK" $((NOW - 100)) 9 "$(mention_tags)" 'ship the hotfix')
  set_events "$home" "$bound" "$offperiod"
  out=$(poll "$home")
  assert_equals "" "$out" "a disabled bridge does not poll"
  assert_equals "" "$(cat "$home/cli.log")" "a disabled bridge never calls the CLI for intake"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"still there?" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a reply while disabled"
  FMX_DRY_RUN=1 run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"dry while off" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a dry-run reply while disabled"
  assert_equals "" "$(cat "$home/cli.log")" "a disabled bridge never calls the CLI for replies"
  assert_equals "" "$(cat "$home/sent.jsonl")" "nothing is sent while disabled"
  run_in "$home" "$ROOT/bin/fm-x-dismiss.sh" "$rid" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a dismiss while disabled"
  FMX_DRY_RUN=1 run_in "$home" "$ROOT/bin/fm-x-dismiss.sh" "$rid" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a dry-run dismiss while disabled"
  assert_equals false "$(jq -r .dismissed "$home/state/buzz/requests/$rid.json")" \
    "a dismiss while disabled must not record a terminal receipt"
  assert_present "$home/state/x-context/$rid.json" "a dismiss while disabled must keep the reply context"
  assert_absent "$home/state/x-outbox/$rid.json" "a dismiss while disabled must record no outbox preview"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" disable); expect_code 0 $? "disable is idempotent"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" status)
  assert_contains "$out" "bridge: disabled" "the bridge stays off"
  enable_from_off "$home"
  out=$(poll "$home")
  assert_equals "" "$out" "enabling must not answer a mention the owner sent while the bridge was off"
  assert_equals "" "$(fm_buzz_rid_for "$home" 'ship the hotfix')" "the off-period mention must not be staged"
  # The first poll advanced the cursor, so this second one is where an overlap
  # that outlived the enable fence would reach back and ingest the off period.
  set_events "$home" "$bound" "$offperiod" \
    "$(sign_event "$OWNER_SK" "$NOW" 9 "$(mention_tags)" 'and now this one')"
  out=$(poll "$home")
  assert_contains "$out" "buzz-mention" "an explicit enable resumes intake for mentions sent after it"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^buzz-mention ')" \
    "only the mention sent after the enable may wake, not the off-period one"
  assert_equals "" "$(fm_buzz_rid_for "$home" 'ship the hotfix')" \
    "no later poll may reach back behind the enable fence"
  assert_equals "$NOW" "$(jq -r .fence "$home/state/buzz/cursor.json")" \
    "the enable fence must survive every cursor advance, not just the first"
  out=$(run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"answered after the off period"); rc=$?
  expect_code 0 "$rc" "a reply to the pending request after re-enabling"
  assert_equals 'answered after the off period' "$(jq -r .content "$home/sent.jsonl")" \
    "a request bound before the off period survives answerable"
  pass "disable stops intake and replies, enabling reads forward only, and only enable turns the bridge back on"
}

test_dry_run_dismiss_previews_and_leaves_the_request_answerable() {
  local home rid out rc
  home=$(new_home drydismiss)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'thanks!')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  : > "$home/cli.log"
  out=$(FMX_DRY_RUN=1 run_in "$home" "$ROOT/bin/fm-x-dismiss.sh" "$rid" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run dismiss"
  assert_equals "$rid" "$out" "a dry-run dismiss echoes the request id"
  assert_equals "buzz dismiss" "$(jq -r '[.platform, .endpoint] | join(" ")' "$home/state/x-outbox/$rid.json")" \
    "a dry-run dismiss records the would-be dismiss"
  assert_equals false "$(jq -r .dismissed "$home/state/buzz/requests/$rid.json")" \
    "a dry-run dismiss must not record a terminal receipt"
  assert_present "$home/state/x-context/$rid.json" "a dry-run dismiss must keep the reply context"
  out=$(run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"Answered after all."); rc=$?
  expect_code 0 "$rc" "a real reply after a dry-run dismiss"
  assert_equals "Answered after all." "$(jq -r .content "$home/sent.jsonl")" \
    "the owner still gets the reply a previewed dismiss did not cancel"
  pass "a dry-run Buzz dismiss previews without consuming the request"
}

test_poll_does_not_reannounce_a_handled_staged_request() {
  local home rid out
  home=$(new_home handled)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'already handled')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  # A poll cut between the wake and the "offered" mark leaves the binding staged;
  # firstmate still answered it and cleared the inbox record.
  jq -c '.state = "staged" | .answer_posted = true' "$home/state/buzz/requests/$rid.json" > "$home/handled.json"
  mv "$home/handled.json" "$home/state/buzz/requests/$rid.json"
  chmod 600 "$home/state/buzz/requests/$rid.json"
  rm -f "$home/state/x-inbox/$rid.json"
  out=$(poll "$home")
  assert_not_contains "$out" "buzz-mention" "an answered request must not be announced again"
  assert_absent "$home/state/x-inbox/$rid.json" "an answered request's inbox record must not be resurrected"
  pass "a staged binding that was already answered is not re-staged or re-announced"
}

test_reenable_while_on_keeps_the_cursor() {
  local home out rc
  home=$(new_home rearm)
  enable "$home"
  # A bridge that has been on and polling, with a cursor deliberately held: the
  # catch-up diagnostic does exactly this, and so does a lost check registration.
  age_cursor "$home" $((NOW - 7200))
  rm -f "$home/state/buzz-bridge.check.sh" "$home/state/buzz-bridge.check-trust"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" status)
  assert_contains "$out" "bridge: enabled" "the bridge is still on with its check lost"
  out=$(run_in "$home" "$ROOT/bin/fm-buzz.sh" enable); rc=$?
  expect_code 0 "$rc" "re-arming the watcher check with enable"
  assert_present "$home/state/buzz-bridge.check.sh" "enable re-arms the watcher check"
  assert_equals $((NOW - 7200)) "$(jq -r .since "$home/state/buzz/cursor.json")" \
    "re-arming a bridge that was never off must not discard unread intake"
  pass "re-running enable while the bridge is on re-arms the check and leaves the cursor alone"
}

test_dismiss_is_local_and_final() {
  local home rid out rc
  home=$(new_home dismiss)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'thanks!')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  : > "$home/cli.log"
  out=$(run_in "$home" "$ROOT/bin/fm-x-dismiss.sh" "$rid"); rc=$?
  expect_code 0 "$rc" "dismiss"
  assert_equals "$rid" "$out" "dismiss echoes the request id"
  assert_equals "" "$(cat "$home/cli.log")" "a Buzz dismiss contacts nothing"
  assert_equals true "$(jq -r .dismissed "$home/state/buzz/requests/$rid.json")" "dismiss records a terminal receipt"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"late reply" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a reply after dismiss"
  pass "dismissing a Buzz request is a local terminal receipt"
}

test_reply_refuses_a_binding_from_another_channel() {
  local home rid rc
  home=$(new_home rebound)
  enable "$home"
  set_events "$home" "$(sign_event "$OWNER_SK" $((NOW - 60)) 9 "$(mention_tags)" 'bound here')"
  poll "$home" >/dev/null
  rid=$(only_rid "$home")
  sed -i.bak "s/^BUZZ_CHANNEL=.*/BUZZ_CHANNEL=$OTHER_CHANNEL/" "$home/config/buzz-bridge.env"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" "$rid" - <<<"wrong place" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a reply after the configured channel changed"
  assert_equals "" "$(cat "$home/sent.jsonl")" "a binding never follows a config change to a new channel"
  run_in "$home" "$ROOT/bin/fm-x-reply.sh" buzz-0000000000000000000000000000000000000000 - <<<"x" 2>/dev/null; rc=$?
  expect_code 1 "$rc" "a reply to an unbound Buzz id"
  pass "replies go only where the ingress binding and current config agree"
}

fm_test_run \
  test_disabled_by_default \
  test_enable_validates_config \
  test_enable_poll_ingests_verified_owner_mention \
  test_poll_drops_everything_else \
  test_poll_accepts_only_addressed_owner_thread_replies \
  test_poll_spends_the_thread_budget_on_signed_roots \
  test_poll_requires_complete_thread_history \
  test_poll_ingests_a_mention_that_carries_an_attachment \
  test_poll_deduplicates_across_restarts \
  test_poll_delivers_the_newest_mention_past_the_read_budget \
  test_poll_holds_the_cursor_on_an_exactly_full_window \
  test_verifier_matches_external_bip340_and_nip01_oracles \
  test_poll_keeps_a_real_event_beside_its_junk_signature_copy \
  test_poll_refuses_a_key_file_that_is_not_hex \
  test_poll_wakes_for_every_request_as_it_is_persisted \
  test_poll_reannounces_a_staged_request \
  test_poll_holds_cursor_on_read_failure \
  test_reply_ack_and_one_final_in_thread \
  test_reply_dry_run_records_without_sending \
  test_reply_dry_run_writes_a_receipt_without_spending_the_budget \
  test_disable_stops_intake_and_replies_until_enabled \
  test_reenable_while_on_keeps_the_cursor \
  test_dismiss_is_local_and_final \
  test_dry_run_dismiss_previews_and_leaves_the_request_answerable \
  test_poll_does_not_reannounce_a_handled_staged_request \
  test_reply_refuses_a_binding_from_another_channel
