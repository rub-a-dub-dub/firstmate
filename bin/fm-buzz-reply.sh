#!/usr/bin/env bash
# Native Buzz reply backend for a Buzz-bound Relay request.
#
# Usage: fm-buzz-reply.sh <request_id> [--followup] [--receipt-file <path>] <text>
#        fm-buzz-reply.sh <request_id> [--followup] [--receipt-file <path>] --text-file <path>
#        fm-buzz-reply.sh <request_id> [--followup] [--receipt-file <path>] -
#        fm-buzz-reply.sh <request_id> --dismiss
#
# bin/fm-x-reply.sh and bin/fm-x-dismiss.sh exec this for any request that has a
# Buzz binding (state/buzz/requests/<request_id>.json, written once at ingress by
# bin/fm-buzz-poll.sh), so fmx-respond keeps one reply command for every Relay
# surface. Routing comes only from that binding and the home's Buzz config: the
# reply is a signed kind-9 message from the bridge key in the configured channel,
# replying to the original event so it lands in the original thread. Nothing in
# the reply text can change its destination.
#
# Budget: one answer (the acknowledgement or the outcome) and one follow-up (the
# final outcome) per request. A second follow-up exits 9, the exhausted-binding
# code bin/fm-x-followup.sh treats as "skip and clear the link". Text only:
# --image is refused. Long text splits into at most three numbered messages of
# the binding's reply budget, each a reply to the original event.
#
# Refusals send nothing: a disabled bridge (bin/fm-buzz.sh disable), a binding
# whose community, bridge key, or channel no longer matches the config, or an
# unreadable secret. The secret is read only for the signing call.
#
# --dismiss is a local terminal receipt for a skipped request: there is no Buzz
# message to delete and no offline auto-reply to prevent, so a live dismiss marks
# the binding dismissed and drops the reply context without contacting the relay.
# Because it is terminal it is still gated on the off switch: while the bridge is
# disabled a dismiss records nothing, so a pending request survives the off
# period answerable.
#
# Dry-run: with FMX_DRY_RUN truthy (environment or .env, as for every Relay
# reply), nothing is sent; the would-be messages are recorded to
# state/x-outbox/<request_id>.json, a DRY RUN summary goes to stderr, the
# caller's receipt is written with dry_run true, and stdout echoes the request id.
# Every dry run here is a preview only, answers and follow-ups as well as
# --dismiss: each of those is terminal and no relay re-offers a Buzz request, so
# a preview leaves the binding and the reply context alone and the real reply,
# follow-up or dismiss still works afterwards.
# That covers this binding, not the caller's task link. A previewed
# bin/fm-x-followup.sh --final still clears x_request= from the task meta, the
# same as for X and Discord, so the task can no longer reach the request: post
# the real final with bin/fm-x-reply.sh <request_id> --followup instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

MAX_MESSAGES=3

usage() {
  echo "usage: fm-buzz-reply.sh <request_id> [--followup] [--receipt-file <path>] <text> | ... --text-file <path> | ... - | <request_id> --dismiss" >&2
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac
REQ=${1:-}
fm_buzz_rid_valid "$REQ" || { echo "fm-buzz-reply: not a Buzz request id: $REQ" >&2; exit 2; }
shift

FOLLOWUP=0
DISMISS=0
RECEIPT_FILE=
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --followup) FOLLOWUP=1 ;;
    --dismiss) DISMISS=1 ;;
    --image) echo "fm-buzz-reply: Buzz replies are text only; --image is not supported" >&2; exit 2 ;;
    --receipt-file)
      shift
      case "${1:-}" in ''|-*) echo "fm-buzz-reply: missing --receipt-file path" >&2; exit 2 ;; esac
      RECEIPT_FILE=$1
      ;;
    --text-file)
      shift
      case "${1:-}" in ''|-*) echo "fm-buzz-reply: missing --text-file path" >&2; exit 2 ;; esac
      ARGS+=(--text-file "$1")
      ;;
    -) ARGS+=("$1") ;;
    -*) echo "fm-buzz-reply: unknown option '$1'" >&2; usage; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-buzz-reply: jq not found" >&2; exit 1; }
BINDING=$(fm_buzz_binding_get "$REQ") || { echo "fm-buzz-reply: no Buzz binding for $REQ; nothing sent" >&2; exit 1; }

fmx_load_config

if [ "$DISMISS" -eq 1 ]; then
  fm_buzz_enabled || { echo "fm-buzz-reply: the Buzz bridge is disabled; nothing recorded" >&2; exit 1; }
  [ "$FOLLOWUP" -eq 0 ] && [ "${#ARGS[@]}" -eq 0 ] && [ -z "$RECEIPT_FILE" ] || { usage; exit 2; }
  # A dismissal is terminal, so a dry run must only preview it: the binding and
  # the reply context are left alone, and a real reply still works afterwards.
  if [ -n "$FMX_DRY" ]; then
    jq -cn --arg rid "$REQ" '{request_id:$rid, platform:"buzz", endpoint:"dismiss"}' \
      | fmx_private_artifact_publish_stdin "$STATE/x-outbox" "$REQ.json" 600 \
      || { echo "fm-buzz-reply: cannot write dry-run outbox: state/x-outbox/$REQ.json" >&2; exit 1; }
    printf 'fm-buzz-reply: DRY RUN - would dismiss %s locally, nothing sent (recorded: state/x-outbox/%s.json)\n' \
      "$REQ" "$REQ" >&2
    printf '%s\n' "$REQ"
    exit 0
  fi
  printf '%s' "$BINDING" | jq -c '.dismissed = true' | fm_buzz_binding_put "$REQ" \
    || { echo "fm-buzz-reply: cannot record the dismissal for $REQ" >&2; exit 1; }
  fmx_context_registry_clear "$STATE" "$REQ"
  printf '%s\n' "$REQ"
  exit 0
fi

[ "${#ARGS[@]}" -ge 1 ] || { usage; exit 2; }
set -- "${ARGS[@]}"
case "$1" in
  --text-file)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    TEXT=$(cat -- "$2") || { echo "fm-buzz-reply: cannot read text file: $2" >&2; exit 1; }
    ;;
  -) [ "$#" -eq 1 ] || { usage; exit 2; }; TEXT=$(cat) ;;
  *) [ "$#" -eq 1 ] || { usage; exit 2; }; TEXT=$1 ;;
esac
[ -n "$TEXT" ] || { echo "fm-buzz-reply: empty reply text" >&2; exit 2; }

# The off switch and the ingress binding are both re-checked at send time.
fm_buzz_enabled || { echo "fm-buzz-reply: the Buzz bridge is disabled; nothing sent" >&2; exit 1; }
fm_buzz_load_config || { echo "fm-buzz-reply: $FM_BUZZ_CONFIG_ERROR; nothing sent" >&2; exit 1; }
if [ "$(printf '%s' "$BINDING" | jq -r '[.community, .bridge_pubkey, .channel] | join(" ")')" \
  != "$BUZZ_COMMUNITY $BUZZ_BRIDGE_PUBKEY $BUZZ_CHANNEL" ]; then
  echo "fm-buzz-reply: $REQ was bound to a different community, bridge key, or channel; nothing sent" >&2
  exit 1
fi
PARENT=$(printf '%s' "$BINDING" | jq -r '.parent // ""')
[[ "$PARENT" =~ ^[0-9a-f]{64}$ ]] || { echo "fm-buzz-reply: binding for $REQ has no valid parent event; nothing sent" >&2; exit 1; }
[ "$(printf '%s' "$BINDING" | jq -r '.dismissed')" != true ] \
  || { echo "fm-buzz-reply: $REQ was dismissed; nothing sent" >&2; exit 1; }

if [ "$FOLLOWUP" -eq 1 ]; then
  BUDGET_KEY=followup_posted
  ENDPOINT=followup
  [ "$(printf '%s' "$BINDING" | jq -r '.followup_posted')" != true ] \
    || { echo "fm-buzz-reply: the final follow-up for $REQ was already posted" >&2; exit 9; }
else
  BUDGET_KEY=answer_posted
  ENDPOINT=answer
  [ "$(printf '%s' "$BINDING" | jq -r '.answer_posted')" != true ] \
    || { echo "fm-buzz-reply: $REQ was already answered; nothing sent" >&2; exit 1; }
fi

MAX=$(printf '%s' "$BINDING" | jq -r '.reply_max_chars // ""')
case "$MAX" in ''|*[!0-9]*) MAX=$BUZZ_REPLY_MAX_CHARS ;; esac
CHUNKS=$(printf '%s' "$TEXT" | fmx_split_thread "$MAX" "$MAX_MESSAGES") \
  || { echo "fm-buzz-reply: failed to split the reply" >&2; exit 1; }
N=$(printf '%s' "$CHUNKS" | jq 'length')
[ "$N" -gt 0 ] || { echo "fm-buzz-reply: empty reply text" >&2; exit 2; }

# The caller's typed delivery receipt (bin/fm-public-followup.sh requires one for
# every reply it drives, dry run included), so it is written on its own rather
# than with the budget a preview must not spend.
write_receipt() {
  [ -n "$RECEIPT_FILE" ] || return 0
  if ! (umask 077; jq -n --arg r "$REQ" --arg e "$ENDPOINT" --argjson c "$N" --argjson d "$1" \
      '{request_id:$r, endpoint:$e, chunks:$c, dry_run:($d == 1)}' > "$RECEIPT_FILE"); then
    echo "fm-buzz-reply: warning: could not write the receipt to $RECEIPT_FILE" >&2
  fi
}

record_budget() {
  printf '%s' "$BINDING" | jq -c --arg k "$BUDGET_KEY" '.[$k] = true' | fm_buzz_binding_put "$REQ" \
    || echo "fm-buzz-reply: warning: sent but could not record the reply budget for $REQ" >&2
  if [ "$FOLLOWUP" -eq 0 ]; then
    fmx_context_registry_set "$STATE" "$REQ" buzz "$MAX" 1 2>/dev/null || true
  fi
  write_receipt "$1"
}

if [ -n "$FMX_DRY" ]; then
  printf '%s' "$CHUNKS" | jq -c --arg rid "$REQ" --arg e "$ENDPOINT" --arg c "$BUZZ_CHANNEL" --arg p "$PARENT" \
    '{request_id:$rid, platform:"buzz", endpoint:$e, channel:$c, reply_to:$p, text:.[0]}
      + (if length > 1 then {texts:.} else {} end)' \
    | fmx_private_artifact_publish_stdin "$STATE/x-outbox" "$REQ.json" 600 \
    || { echo "fm-buzz-reply: cannot write dry-run outbox: state/x-outbox/$REQ.json" >&2; exit 1; }
  printf 'fm-buzz-reply: DRY RUN - would send %s Buzz %s message(s) in reply to the original event (recorded: state/x-outbox/%s.json)\n' \
    "$N" "$ENDPOINT" "$REQ" >&2
  write_receipt 1
  printf '%s\n' "$REQ"
  exit 0
fi

i=0
while [ "$i" -lt "$N" ]; do
  OUT=$(printf '%s' "$CHUNKS" | jq -j --argjson i "$i" '.[$i]' \
    | fm_buzz_cli --replay-stdin messages send --channel "$BUZZ_CHANNEL" --reply-to "$PARENT" --content - 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
    [ "$rc" -ne 10 ] || echo "fm-buzz-reply: cannot read the bridge secret from BUZZ_BRIDGE_KEY_FILE" >&2
    if [ "$rc" -eq 11 ]; then
      fm_buzz_log_stale_auth
    else
      echo "fm-buzz-reply: Buzz send failed for $REQ (message $((i + 1)) of $N, exit $rc)" >&2
    fi
    if [ "$i" -gt 0 ]; then
      # A partial thread already landed; spend the budget rather than duplicate it.
      record_budget 0
    fi
    exit 1
  fi
  i=$((i + 1))
done
record_budget 0
printf '%s\n' "$REQ"
