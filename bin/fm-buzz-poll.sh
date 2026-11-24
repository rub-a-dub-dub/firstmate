#!/usr/bin/env bash
# One bounded poll of the configured Buzz channel for verified owner mentions.
#
# Run by the watcher through the registered state/buzz-bridge.check.sh shim that
# bin/fm-buzz.sh enable writes. Contract: output => wake firstmate, silence =>
# keep sleeping. A HARD no-op (exit 0, no output) while the bridge is disabled
# (no config/buzz-bridge.enabled), so a stray shim can never poll.
#
# Each poll reads kind-9 events in the one configured channel through the
# pinned Buzz CLI (`messages get`, signed NIP-98 reads with the bridge key),
# paging backward from a fixed upper fence to the durable cursor minus a
# 300-second overlap, never past the age limit (BUZZ_MAX_AGE_SECS). Every page
# is filtered and verified by bin/fm-buzz-verify.py: only owner-signed kind-9
# messages that p-tag the bridge key, with a valid event id and signature,
# survive; everything else is dropped silently.
#
# For each accepted event, in order, before the cursor may advance:
#   1. claim the request binding state/buzz/requests/<request_id>.json
#      (state "staged"; an existing "offered" binding deduplicates the event)
#   2. publish the shared Relay inbox record state/x-inbox/<request_id>.json
#      with platform "buzz" and the reply budget
#   3. record the per-request reply context (state/x-context/<request_id>.json)
#   4. mark the binding "offered" and wake with "buzz-mention <request_id>"
# A staged binding whose inbox publish failed is retried on the next poll,
# because the cursor only advances after a complete, fully persisted range.
#
# Diagnostics wake once per distinct message as "buzz-bridge-error <reason>":
# configuration problems, an auth refusal, a malformed read, and a catch-up range
# too large to drain in one poll. A relay or network failure is silent; the next
# cycle retries it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

fm_buzz_enabled || exit 0

PAGE_LIMIT=200
MAX_PAGES=5
OVERLAP=300

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE/buzz" poll.error 600 \
    && [ "$(cat "$STATE/buzz/poll.error" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  fmx_private_artifact_dir_prepare "$STATE/buzz" >/dev/null 2>&1 || true
  printf '%s\n' "$msg" | fmx_private_artifact_publish_stdin "$STATE/buzz" poll.error 600 2>/dev/null || true
  printf 'buzz-bridge-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_file_valid "$STATE/buzz" poll.error 600 && rm -f "$STATE/buzz/poll.error"
  return 0
}

command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }
command -v python3 >/dev/null 2>&1 || { emit_error_once "missing python3"; exit 0; }
fm_buzz_load_config || { emit_error_once "$FM_BUZZ_CONFIG_ERROR"; exit 0; }

NOW=${FMX_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac
FLOOR=$((NOW - BUZZ_MAX_AGE_SECS))
fm_buzz_binding_prune
fmx_context_registry_prune "$STATE"

SINCE=$(jq -r '.since // empty' "$STATE/buzz/cursor.json" 2>/dev/null) || SINCE=
case "$SINCE" in ''|*[!0-9]*) SINCE=$FLOOR ;; esac
LOWER=$((SINCE - OVERLAP))
[ "$LOWER" -ge "$FLOOR" ] || LOWER=$FLOOR

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-buzz-poll.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT

# Page backward from the fence. `until` is inclusive, so a full page restarts at
# its oldest timestamp and the verifier deduplicates the overlap by event id.
UNTIL=$NOW
COMPLETE=0
page=0
: > "$WORK/pages"
while [ "$page" -lt "$MAX_PAGES" ]; do
  page=$((page + 1))
  fm_buzz_cli messages get --channel "$BUZZ_CHANNEL" --kinds 9 \
    --since "$LOWER" --before "$UNTIL" --limit "$PAGE_LIMIT" > "$WORK/page" 2>/dev/null
  rc=$?
  case "$rc" in
    0) ;;
    2) exit 0 ;;
    3) emit_error_once "relay refused the bridge key (auth error); check channel membership"; exit 0 ;;
    10) emit_error_once "cannot read the bridge secret from BUZZ_BRIDGE_KEY_FILE"; exit 0 ;;
    *) emit_error_once "buzz CLI read failed (exit $rc)"; exit 0 ;;
  esac
  count=$(jq -er 'if type == "array" then length else error("not an array") end' "$WORK/page" 2>/dev/null) \
    || { emit_error_once "buzz CLI returned a malformed read"; exit 0; }
  cat "$WORK/page" >> "$WORK/pages"
  if [ "$count" -lt "$PAGE_LIMIT" ]; then
    COMPLETE=1
    break
  fi
  oldest=$(jq -r '[.[].created_at | numbers] | min // empty' "$WORK/page")
  case "$oldest" in ''|*[!0-9]*) break ;; esac
  # More than a full page inside one second cannot be paged by timestamp alone.
  [ "$oldest" -lt "$UNTIL" ] || break
  UNTIL=$oldest
done

jq -s 'add // []' "$WORK/pages" > "$WORK/all" 2>/dev/null \
  || { emit_error_once "buzz CLI returned a malformed read"; exit 0; }
python3 -I "$SCRIPT_DIR/fm-buzz-verify.py" --owner "$BUZZ_OWNER_PUBKEY" --bridge "$BUZZ_BRIDGE_PUBKEY" \
  --channel "$BUZZ_CHANNEL" --floor "$FLOOR" < "$WORK/all" > "$WORK/accepted" 2>/dev/null \
  || { emit_error_once "event verification failed to run"; exit 0; }

FAILED=0
NEW=()
while IFS= read -r ev; do
  [ -n "$ev" ] || continue
  eid=$(printf '%s' "$ev" | jq -r '.event_id')
  rid=$(fm_buzz_request_id "$eid") || { FAILED=1; continue; }
  if binding=$(fm_buzz_binding_get "$rid"); then
    [ "$(printf '%s' "$binding" | jq -r '.state')" = staged ] || continue
  else
    printf '%s' "$ev" | jq -c --arg rid "$rid" --arg community "$BUZZ_COMMUNITY" \
      --arg relay "$BUZZ_RELAY_URL" --arg bridge "$BUZZ_BRIDGE_PUBKEY" --arg channel "$BUZZ_CHANNEL" \
      --argjson max "$BUZZ_REPLY_MAX_CHARS" --argjson now "$NOW" '{
        request_id:$rid, transport:"buzz", community:$community, relay_url:$relay,
        bridge_pubkey:$bridge, channel:$channel, event_id, parent, thread_root, signer,
        source_class:"owner-direct", reply_max_chars:$max, created_at, recorded_at:$now,
        state:"staged", answer_posted:false, followup_posted:false, dismissed:false}' > "$WORK/binding"
    fm_buzz_binding_claim "$rid" < "$WORK/binding"
    case $? in
      0) binding=$(cat "$WORK/binding") ;;
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
  printf '%s' "$binding" | jq -c '.state = "offered"' | fm_buzz_binding_put "$rid" || { FAILED=1; continue; }
  NEW+=("$rid")
done < <(jq -c '.[]' "$WORK/accepted")

if [ "$FAILED" -eq 1 ]; then
  emit_error_once "cannot persist an accepted request; the cursor is held for retry"
elif [ "$COMPLETE" -eq 1 ]; then
  if jq -cn --argjson since "$NOW" '{since:$since}' \
    | fmx_private_artifact_publish_stdin "$STATE/buzz" cursor.json 600; then
    clear_error
  else
    emit_error_once "cannot advance the poll cursor"
  fi
else
  # shortcut: the newest pages are still delivered, but the cursor holds until
  # the uncovered range falls under the page budget or behind the age limit.
  emit_error_once "catch-up range exceeds $((PAGE_LIMIT * MAX_PAGES)) messages; older messages in the window were not read"
fi

if [ "${#NEW[@]}" -gt 0 ]; then
  if [ "${#NEW[@]}" -gt 1 ]; then
    printf 'buzz-mention %s (+%s more)\n' "${NEW[${#NEW[@]}-1]}" "$((${#NEW[@]} - 1))"
  else
    printf 'buzz-mention %s\n' "${NEW[0]}"
  fi
fi
exit 0
