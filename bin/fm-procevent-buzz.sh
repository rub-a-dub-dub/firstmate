#!/usr/bin/env bash
# Built-in process-event source for the home-local Buzz bridge.
#
# Usage: fm-procevent-buzz.sh arm|retire|status|listen
# arm registers and starts one listener, and fails when this registration
# generation has no live listener; retire stops its owned process group.
# listen consumes only fixed helper signals, owns the helper process it starts,
# and re-reads the off switch at least once a minute so a marker that goes away
# by any route stops the helper and its relay session. match runs the same
# bounded poll as the watcher sweep. Relay events and poll output never become generic
# process-event results. status reads the source registration first - a listener
# the off switch could not retire is still armed - and then the connection
# marker's process identity.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

RUNNER="$SCRIPT_DIR/fm-procevent.sh"
LISTENER="$SCRIPT_DIR/fm-procevent-buzz.sh"
CONNECTION="$STATE/buzz/listener.connected"

[ "$#" -eq 1 ] || exit 2
source_id() {
  local canonical digest
  canonical=$(CDPATH='' cd -- "$STATE" && pwd -P) || return 1
  digest=$(printf '%s' "$canonical" | fm_buzz_sha256) || return 1
  printf 'buzz-bridge-%s\n' "${digest:0:40}"
}

case "$1" in
  arm)
    fm_buzz_enabled && fm_buzz_load_config && fm_buzz_listener_available || exit 1
    source=$(source_id) || exit 1
    "$RUNNER" register buzz "$source" -- "$LISTENER" listen >/dev/null || exit 1
    "$RUNNER" ensure-listening "$source" >/dev/null
    ;;
  retire)
    [ -d "$STATE/procevent" ] || exit 0
    source=$(source_id) || exit 1
    "$RUNNER" retire "$source" --if-matches buzz -- "$LISTENER" listen >/dev/null || exit 1
    rm -f -- "$CONNECTION"
    ;;
  status)
    source=$(source_id) || exit 1
    if [ -e "$STATE/procevent/$source.source" ]; then
      # shellcheck source=bin/fm-wake-lib.sh
      . "$SCRIPT_DIR/fm-wake-lib.sh"
      if fmx_private_artifact_file_valid "$STATE/buzz" listener.connected 600 \
        && IFS=' ' read -r pid identity < "$CONNECTION" \
        && [ -n "$identity" ] \
        && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ]; then
        echo "listener: connected"
      else
        echo "listener: disconnected"
      fi
    else
      BUZZ_LISTENER=
      fm_buzz_load_config >/dev/null 2>&1 || true
      if fm_buzz_listener_available; then
        echo "listener: stopped"
      elif [ -n "$BUZZ_LISTENER" ]; then
        echo "listener: unusable (BUZZ_LISTENER is not an executable file)"
      else
        echo "listener: not configured"
      fi
    fi
    ;;
  listen)
    # An empty nonzero completion has no generic result to announce.
    fm_buzz_enabled && fm_buzz_load_config && fm_buzz_listener_available || exit 75
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    identity=$(fm_pid_identity "$$") || exit 75
    # The helper holds the relay session, so this process owns its lifetime:
    # nothing else stops it when the off switch is read here.
    helper_pid=
    trap 'rm -f -- "$CONNECTION"; [ -z "$helper_pid" ] || kill "$helper_pid" 2>/dev/null' EXIT
    trap 'exit 75' HUP INT TERM
    # A quiet channel sends nothing for hours, so the off-switch re-check below
    # runs on this cadence rather than on helper traffic.
    recheck=${FM_BUZZ_LISTEN_RECHECK_SECONDS:-60}
    case "$recheck" in ''|*[!0-9]*|0*) recheck=60 ;; esac
    [ "$recheck" -lt 60 ] || recheck=60
    exec 3< <(
      unset BUZZ_PRIVATE_KEY
      exec "$BUZZ_LISTENER" "$BUZZ_RELAY_URL" "$BUZZ_CHANNEL" "$BUZZ_OWNER_PUBKEY" \
        "$BUZZ_BRIDGE_PUBKEY" "$BUZZ_BRIDGE_KEY_FILE" </dev/null 2>/dev/null
    )
    helper_pid=$!
    pending=0
    poll_pid=
    while :; do
      fm_buzz_enabled || exit 75
      if [ -n "$poll_pid" ] && ! kill -0 "$poll_pid" 2>/dev/null; then
        wait "$poll_pid" || true
        poll_pid=
      fi
      if [ "$pending" -eq 1 ] && [ -z "$poll_pid" ]; then
        # The timed runner reaps the poll group if this source is retired.
        (FM_EXEC_TIMED_OWNER_PID=$$ fm_exec_timed 30 1 "$SCRIPT_DIR/fm-buzz-poll.sh" --notify) \
          </dev/null >/dev/null 2>&1 &
        poll_pid=$!
        pending=0
      fi
      # One second while a poll is in flight, so it is reaped promptly.
      wait_secs=$recheck
      [ -z "$poll_pid" ] || wait_secs=1
      rc=0
      IFS= read -r -t "$wait_secs" signal <&3 || rc=$?
      [ "$rc" -le 128 ] || continue
      [ "$rc" -eq 0 ] || break
      case "$signal" in
        connected)
          printf '%s %s\n' "$$" "$identity" \
            | fmx_private_artifact_publish_stdin "$STATE/buzz" listener.connected 600 || true
          ;;
        disconnected) rm -f -- "$CONNECTION" ;;
        match) pending=1 ;;
      esac
    done
    exit 75
    ;;
  *) exit 2 ;;
esac
