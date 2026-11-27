#!/usr/bin/env bash
# One bounded poll of the configured Buzz channel for verified owner requests.
#
# Run by the watcher through the registered state/buzz-bridge.check.sh shim that
# bin/fm-buzz.sh enable writes. Contract: output => wake firstmate, silence =>
# keep sleeping. A HARD no-op (exit 0, no output) while the bridge is disabled
# (no config/buzz-bridge.enabled), so a stray shim can never poll.
# The push adapter invokes --notify, which publishes the same check wakes
# directly into the durable queue instead of writing them to stdout.
# Both paths hold the same home-local lock. A sweep skips a busy poll;
# the push path can wait for it within the adapter's poll deadline.
#
# Each poll makes one intake read of kind-9 events in the configured channel
# through the pinned Buzz CLI (`messages get`, signed NIP-98 reads with the
# bridge key): the newest PAGE_LIMIT events below a fixed upper fence, down to
# the durable cursor minus a BUZZ_READ_OVERLAP overlap, never past the age limit
# (BUZZ_MAX_AGE_SECS), and never behind the cursor's `fence` - the moment
# bin/fm-buzz.sh enable turned the bridge on, which the overlap must not reach
# back across. One newest-first read is what keeps a sweep inside the
# watcher's per-check timeout, because every distinct candidate it returns is
# BIP-340 verified. The read is scoped by channel and kind, not by author, so the
# owner's latest mention is inside it unless more than PAGE_LIMIT channel
# messages from any member are newer than that mention. The read is
# filtered and verified by bin/fm-buzz-verify.py. For potential unaddressed
# replies, a separate budget reads up to THREAD_LOOKUPS distinct threads at up
# to THREAD_LIMIT events per lookup, skipping any thread whose reply this home
# has already handled so a re-read cannot starve an older thread out of the
# budget. Failed, missing, or capped thread reads supply no evidence for implicit
# intake. Three of those are reported, because the cursor moving past a reply
# would otherwise leave it indistinguishable from a message the bridge never
# saw: a read the CLI refused, a budget that ran out before every queued thread
# was read, and a history that came back at THREAD_LIMIT, where a complete
# thread cannot be told from a truncated one. Each is one generic message naming
# no thread, so a single wake can stand for several dropped replies. A thread
# others have joined is refused under rule 3 yet still spends a lookup, so a
# busy shared thread can delay checking another thread by a sweep or more. An
# explicit @Firstmate mention needs no thread read at all and always works:
# that is the way past every limit here, and what each of these diagnostics
# asks the owner for.
#
# For each accepted event, in order, before the cursor may advance:
#   1. claim the request binding state/buzz/requests/<request_id>.json
#      (state "staged"; any binding already offered, answered, followed up or
#      dismissed deduplicates the event)
#   2. publish the shared Relay inbox record state/x-inbox/<request_id>.json
#      with platform "buzz" and the reply budget
#   3. record the per-request reply context (state/x-context/<request_id>.json)
#   4. wake with "buzz-mention <request_id>", then mark the binding "offered"
# Each wake is printed as its own request is persisted, so a poll cut short
# mid-range still delivers what it finished. The wake precedes the "offered"
# mark, which makes delivery at least once: a staged binding is retried, and
# re-announced, on the next poll, because the cursor only advances after a
# complete, fully persisted range.
#
# Diagnostics wake once per distinct message as "buzz-bridge-error <reason>":
# configuration problems, an auth refusal, a malformed read, a thread read the
# CLI refused, a thread lookup budget that ran out, a thread too long to check,
# a catch-up range too large to drain in one poll, and a poll lock whose dead
# holder nothing can reclaim. Relay or network failure and exhausted timestamp
# retries on the intake read stay silent and leave the window for the next sweep.
# Once the range is persisted, every newly bound event gets one best-effort eyes
# reaction, sent sequentially newest first, each bounded to REACTION_BOUND and
# only while the watcher's check budget still has room. Newest first because a
# sweep the budget cuts short should have acknowledged the mentions the owner is
# still waiting on. Reaction failures are best effort, so no wake or cursor
# advance ever depends on one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

fm_buzz_enabled || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

NOTIFY=0
case "${1-}" in
  --notify) NOTIFY=1 ;;
  '') ;;
  *) exit 2 ;;
esac

WORK=
UNRECLAIMABLE=
# shellcheck disable=SC2329 # EXIT trap owns cleanup.
cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
  if [ "$NOTIFY" -eq 1 ]; then fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true; fi
  fm_lock_release "$FM_BUZZ_POLL_LOCK" || true
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
if [ "$NOTIFY" -eq 1 ]; then
  fm_lock_acquire_wait "$FM_BUZZ_POLL_LOCK" --refuse-unreapable || exit 1
elif ! fm_lock_try_acquire "$FM_BUZZ_POLL_LOCK"; then
  # A held or deferred lock is an ordinary skip. A lock whose dead holder cannot
  # be cleared silences every later sweep too, so that one is reported below
  # once the poll's own diagnostic is defined.
  UNRECLAIMABLE=${FM_LOCK_RECLAIM_FAILED_PATH:-}
  [ -n "$UNRECLAIMABLE" ] || exit 0
fi
fm_buzz_enabled || exit 0

PAGE_LIMIT=200
THREAD_LOOKUPS=4
THREAD_LIMIT=50
THREAD_SECONDS=5
# Reactions are acknowledgements, not deliverables: the sweep stops sending them
# before the watcher's own per-check bound (FM_CHECK_TIMEOUT, default 30) cuts
# the check. A cut keeps what the check already printed and appends
# "timed out after <n>s" to it (bin/fm-watch.sh run_check_capture), so the cost
# of overrunning is a wake that reads as a stuck check, not a lost one. The
# reserve is one whole bounded send plus the runner's own KILL escalation and
# fork overhead, so it cannot drift away from REACTION_BOUND. That budget is the
# only limit: every bound mention is acknowledged while time remains.
REACTION_BOUND=3
# 10# because a zero-padded value is octal to bash's arithmetic: 030 would mean
# 24, and 08 is not octal at all, so a bare expansion fails here and leaves
# REACTION_DEADLINE unset - which under set -u kills the poll at its first
# reaction, after intake and the cursor have already run, exiting 1 with the
# acknowledgement silently never sent. Every bound below reads this one value.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*) CHECK_TIMEOUT=30 ;; *) CHECK_TIMEOUT=$((10#$CHECK_TIMEOUT)) ;; esac
[ "$CHECK_TIMEOUT" -gt 0 ] || CHECK_TIMEOUT=30
REACTION_DEADLINE=$(( $(date +%s) + CHECK_TIMEOUT - REACTION_BOUND - 2 ))

emit_wake() {
  local line=$1 check="$STATE/$FM_BUZZ_CHECK_ID.check.sh"
  if [ "$NOTIFY" -eq 1 ]; then
    fm_wake_append_guarded fm_buzz_enabled check buzz-push "check: $check: $line"
  else
    printf '%s\n' "$line"
  fi
}

offer_request() {
  local rid=$1 binding=$2 status=0 check="$STATE/$FM_BUZZ_CHECK_ID.check.sh"
  if [ "$NOTIFY" -eq 0 ]; then
    emit_wake "buzz-mention $rid" || return 1
    printf '%s' "$binding" | jq -c '.state = "offered"' | fm_buzz_binding_put "$rid"
    return $?
  fi
  # The watcher and drain take this same lock before surfacing the queued row.
  # Keep the write-ahead wake order without exposing a stale staged binding to
  # an immediate reply that could race the final offered write.
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if fm_wake_append_locked check buzz-push "check: $check: buzz-mention $rid" fm_buzz_enabled; then
    printf '%s' "$binding" | jq -c '.state = "offered"' | fm_buzz_binding_put "$rid" || status=1
  else
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE/buzz" poll.error 600 \
    && [ "$(cat "$STATE/buzz/poll.error" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  emit_wake "buzz-bridge-error $msg" || return 0
  fmx_private_artifact_dir_prepare "$STATE/buzz" >/dev/null 2>&1 || true
  printf '%s\n' "$msg" | fmx_private_artifact_publish_stdin "$STATE/buzz" poll.error 600 2>/dev/null || true
}

clear_error() {
  fmx_private_artifact_file_valid "$STATE/buzz" poll.error 600 && rm -f "$STATE/buzz/poll.error"
  return 0
}

react_to_request() {
  fm_buzz_enabled || return 0
  fm_buzz_cli --timeout "$REACTION_BOUND" reactions add --event "$1" --emoji '👀' \
    </dev/null >/dev/null 2>&1 || true
}

[ -z "$UNRECLAIMABLE" ] \
  || { emit_error_once "cannot reclaim $UNRECLAIMABLE; the Buzz poll cannot run"; exit 0; }
command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }
command -v python3 >/dev/null 2>&1 || { emit_error_once "missing python3"; exit 0; }
fm_buzz_load_config || { emit_error_once "$FM_BUZZ_CONFIG_ERROR"; exit 0; }
fmx_load_config

NOW=${FMX_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac
FLOOR=$((NOW - BUZZ_MAX_AGE_SECS))
fm_buzz_binding_prune
fmx_context_registry_prune "$STATE"

SINCE=$(jq -r '.since // empty' "$STATE/buzz/cursor.json" 2>/dev/null) || SINCE=
case "$SINCE" in ''|*[!0-9]*) SINCE=$FLOOR ;; esac
# The enable fence outlives every cursor advance, so the overlap can never reach
# back behind the moment the bridge was turned on. Absent on a cursor written
# before the bridge recorded one, which clamps nothing.
FENCE=$(jq -r '.fence // empty' "$STATE/buzz/cursor.json" 2>/dev/null) || FENCE=
case "$FENCE" in ''|*[!0-9]*) FENCE=0 ;; esac
LOWER=$((SINCE - BUZZ_READ_OVERLAP))
[ "$LOWER" -ge "$FLOOR" ] || LOWER=$FLOOR
[ "$LOWER" -ge "$FENCE" ] || LOWER=$FENCE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-buzz-poll.XXXXXX") || exit 0

fm_buzz_cli messages get --channel "$BUZZ_CHANNEL" --kinds 9 \
  --since "$LOWER" --before "$NOW" --limit "$PAGE_LIMIT" > "$WORK/all" 2>/dev/null
rc=$?
fm_buzz_enabled || exit 0
case "$rc" in
  0) ;;
  2|11) exit 0 ;;
  3) emit_error_once "relay refused the bridge key (auth error); check channel membership"; exit 0 ;;
  10) emit_error_once "cannot read the bridge secret from BUZZ_BRIDGE_KEY_FILE"; exit 0 ;;
  *) emit_error_once "buzz CLI read failed (exit $rc)"; exit 0 ;;
esac
COUNT=$(jq -er 'if type == "array" then length else error("not an array") end' "$WORK/all" 2>/dev/null) \
  || { emit_error_once "buzz CLI returned a malformed read"; exit 0; }
# The pinned CLI caps `messages get` at PAGE_LIMIT, so a full page is the most
# the relay will return and cannot be told apart from a larger window. A full
# page therefore counts as not drained: the cursor holds and the catch-up
# diagnostic wakes, which over-reports a window that happens to fit exactly
# rather than risk advancing the cursor past an unread mention.
if [ "$COUNT" -lt "$PAGE_LIMIT" ]; then COMPLETE=1; else COMPLETE=0; fi
VERIFY=(
  python3 -I "$SCRIPT_DIR/fm-buzz-verify.py" --owner "$BUZZ_OWNER_PUBKEY" --bridge "$BUZZ_BRIDGE_PUBKEY"
  --channel "$BUZZ_CHANNEL" --floor "$FLOOR"
)

read_thread_history() (
  # Reserve time for the existing delivery loop, for the queue scan above, and
  # for signature verification - whose ceiling is TWICE the intake page (the two
  # verify passes share nothing) plus THREAD_LOOKUPS x THREAD_LIMIT, because every
  # event a history holds is verified before its signer can be trusted. Raising
  # any of those three constants spends this reserve, and so does the one
  # timestamp-retry delay a refused read can add before the loop above stops.
  budget=$((CHECK_TIMEOUT - SECONDS - 15))
  [ "$budget" -gt 0 ] || return 0
  [ "$budget" -le "$THREAD_SECONDS" ] || budget=$THREAD_SECONDS
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fm_buzz_export_cli
  # shellcheck disable=SC2016  # Arguments expand in the bounded child shell.
  fm_run_timed "$budget" "$BASH" -c '
    rc=0
    for ((i = 0; i < $1; i++)); do
      IFS= read -r root || break
      if fm_buzz_cli_retry messages thread --channel "$2" --event "$root" --limit "$3" < /dev/null > "$4/partial"; then
        mv "$4/partial" "$4/$root"
      else
        s=$?
        if [ "$s" -ne 11 ] || [ "$rc" -eq 0 ]; then rc=$s; fi
        # A refusal that outlived its own retry is the host clock, not this one
        # thread: the queued reads would spend their delay to be refused too,
        # and the budget they overran would report starvation instead of skew.
        [ "$s" -eq 11 ] && break
      fi
    done
    exit "$rc"
  ' _ "$THREAD_LOOKUPS" "$BUZZ_CHANNEL" "$THREAD_LIMIT" "$WORK" < "$WORK/wanted"
  rc=$?
  # Running out of time is not a surface problem; the unread roots report it.
  fm_timed_out "$rc" && return 0
  return "$rc"
)

# Spend the scarce lookups only on threads whose reply still has somewhere to go.
# Verify lists every candidate newest-first and cannot know what this home has
# already handled, so a thread answered on an earlier poll would otherwise be
# looked up again on every re-read inside the overlap and starve an older one out
# of the budget for good. A binding the delivery loop below would still act on -
# absent, or staged and untouched - keeps its thread in the queue.
THREAD_ERROR=
WANTED=0
: > "$WORK/wanted"
if "${VERIFY[@]}" --thread-roots < "$WORK/all" > "$WORK/candidates" 2>/dev/null; then
  while read -r root eid; do
    [ -n "$root" ] && [ -n "$eid" ] || continue
    grep -qxF -- "$root" "$WORK/wanted" && continue
    rid=$(fm_buzz_request_id "$eid") || continue
    if binding=$(fm_buzz_binding_get "$rid"); then
      printf '%s' "$binding" \
        | jq -e '.state == "staged" and .answer_posted != true and .followup_posted != true and .dismissed != true' \
          >/dev/null || continue
    fi
    printf '%s\n' "$root" >> "$WORK/wanted"
    WANTED=$((WANTED + 1))
    # One past the budget already proves it overflows; counting the rest costs
    # a request id per candidate and changes nothing.
    [ "$WANTED" -le "$THREAD_LOOKUPS" ] || break
  done < "$WORK/candidates"
fi
if [ "$WANTED" -gt 0 ]; then
  read_thread_history 2>/dev/null
  rc=$?
  if [ "$rc" -eq 11 ]; then
    THREAD_ERROR="buzz thread read refused: request timestamp outside the relay window after retry (clock skew or sleep); unaddressed replies need an explicit mention"
  elif [ "$rc" -ne 0 ]; then
    THREAD_ERROR="buzz CLI thread read failed (exit $rc); unaddressed replies need an explicit mention"
  else
    CAPPED=0
    while IFS= read -r root; do
      if [ ! -f "$WORK/$root" ]; then
        THREAD_ERROR="thread lookup budget exhausted; unaddressed replies in the threads it did not reach need an explicit mention"
        break
      fi
      # A history at the limit is the same read a longer thread would return, so
      # bin/fm-buzz-verify.py cannot trust it and the reply goes unanswered.
      held=$(jq 'if type == "array" then length else 0 end' "$WORK/$root" 2>/dev/null) || held=0
      case "$held" in ''|*[!0-9]*) held=0 ;; esac
      [ "$held" -lt "$THREAD_LIMIT" ] || CAPPED=1
    done < "$WORK/wanted"
    if [ -z "$THREAD_ERROR" ] && [ "$CAPPED" -eq 1 ]; then
      THREAD_ERROR="a thread is past $THREAD_LIMIT messages, too long to check for an unaddressed reply; @-mention Firstmate to reach it there"
    fi
  fi
fi
"${VERIFY[@]}" --history-dir "$WORK" --thread-limit "$THREAD_LIMIT" < "$WORK/all" > "$WORK/accepted" 2>/dev/null \
  || { emit_error_once "event verification failed to run"; exit 0; }

FAILED=0
while IFS= read -r ev; do
  fm_buzz_enabled || exit 0
  [ -n "$ev" ] || continue
  eid=$(printf '%s' "$ev" | jq -r '.event_id')
  rid=$(fm_buzz_request_id "$eid") || { FAILED=1; continue; }
  if binding=$(fm_buzz_binding_get "$rid"); then
    printf '%s' "$binding" \
      | jq -e '.state == "staged" and .answer_posted != true and .followup_posted != true and .dismissed != true' \
        >/dev/null || continue
  else
    printf '%s' "$ev" | jq -c --arg rid "$rid" --arg community "$BUZZ_COMMUNITY" \
      --arg bridge "$BUZZ_BRIDGE_PUBKEY" --arg channel "$BUZZ_CHANNEL" \
      --argjson max "$BUZZ_REPLY_MAX_CHARS" --argjson now "$NOW" '{
        request_id:$rid, community:$community,
        bridge_pubkey:$bridge, channel:$channel, event_id, parent, thread_root, signer,
        reply_max_chars:$max, created_at, recorded_at:$now,
        state:"staged", answer_posted:false, followup_posted:false, dismissed:false}' > "$WORK/binding"
    fm_buzz_binding_claim "$rid" < "$WORK/binding"
    case $? in
      0)
        printf '%s\n' "$eid" >> "$WORK/reactions"
        binding=$(cat "$WORK/binding")
        ;;
      1) continue ;;
      *) FAILED=1; continue ;;
    esac
  fi
  if ! printf '%s' "$ev" | jq -c --arg rid "$rid" --arg community "$BUZZ_COMMUNITY" \
      --arg channel "$BUZZ_CHANNEL" --argjson max "$BUZZ_REPLY_MAX_CHARS" '{
        request_id:$rid, platform:"buzz", reply_platform:"buzz", reply_max_chars:$max,
        text:.content, in_reply_to:null,
        buzz:{community:$community, channel:$channel, event_id, thread_root, signer,
          verified:"owner-signature", created_at}}' \
      | fmx_private_artifact_publish_stdin "$STATE/x-inbox" "$rid.json" 600; then
    FAILED=1
    continue
  fi
  fmx_context_registry_set "$STATE" "$rid" buzz "$BUZZ_REPLY_MAX_CHARS" 2>/dev/null || true
  offer_request "$rid" "$binding" || { FAILED=1; continue; }
done < <(jq -c '.[]' "$WORK/accepted")

fm_buzz_enabled || exit 0
if [ "$FAILED" -eq 1 ]; then
  emit_error_once "cannot persist an accepted request; the cursor is held for retry"
elif [ "$COMPLETE" -eq 1 ]; then
  if jq -cn --argjson since "$NOW" --argjson fence "$FENCE" '{since:$since, fence:$fence}' \
    | fmx_private_artifact_publish_stdin "$STATE/buzz" cursor.json 600; then
    if [ -n "$THREAD_ERROR" ]; then emit_error_once "$THREAD_ERROR"; else clear_error; fi
  else
    emit_error_once "cannot advance the poll cursor"
  fi
else
  # shortcut: the newest page is still delivered, but the cursor holds until
  # the uncovered range falls under the read budget or behind the age limit.
  emit_error_once "catch-up range exceeds $PAGE_LIMIT messages; older messages in the window were not read"
fi

if [ -s "$WORK/reactions" ]; then
  while IFS= read -r eid; do
    [ "$(date +%s)" -lt "$REACTION_DEADLINE" ] || break
    if [ -n "$FMX_DRY" ]; then
      printf 'fm-buzz-poll: DRY RUN - would add 👀 to Buzz event %s\n' "$eid" >&2
    else
      react_to_request "$eid"
    fi
  done < <(jq -Rrn '[inputs] | reverse | .[]' "$WORK/reactions")
fi

exit 0
