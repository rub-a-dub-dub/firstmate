#!/usr/bin/env bash
# Retire retain-unresolved reconcile records: durable
# state/<id>.backlog-reconcile files bin/fm-backlog-transition-lib.sh's
# fm_backlog_reconcile_marker_write creates when a captain-held retain
# marker's row is absent from both the live backlog and its archive, so
# nothing closed the call and its recorded deliverable would otherwise be
# lost. bin/fm-bootstrap.sh re-reports every surviving record on every session
# start; this script is the only way one is ever cleared, mirroring the
# register/unregister shape of bin/fm-check-register.sh and
# bin/fm-check-unregister.sh for a similar durable-until-explicitly-retired
# record.
#
# Usage:
#   fm-backlog-reconcile.sh ack <id>
#
# `ack <id>` removes the record for <id> - the explicit "I reconciled this with
# the captain" act; there is no automatic retirement path, on purpose (an
# unresolved captain call must not be silently dropped).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

command_ack() {
  local id=${1:-}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: task id must be a non-empty privacy-safe slug: $id" >&2
      exit 2
      ;;
  esac
  fm_backlog_directory_present "$STATE" "state directory" \
    || { echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2; exit 1; }
  if fm_backlog_reconcile_marker_ack "$STATE" "$id"; then
    printf 'acked: %s\n' "$id"
  else
    echo "error: could not retire the reconcile record for $id: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  fi
}

case "${1:-}" in
  ack) shift; command_ack "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
