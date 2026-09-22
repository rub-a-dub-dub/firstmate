#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-20 false-positive wedge escalation on
# fm/firstmate-detect-dropped-ci-event, driving the REAL bin/fm-watch.sh and the
# REAL bin/fm-crew-state.sh. The only fakes are the terminal multiplexer and the
# `no-mistakes` CLI, which replays the exact `axi status --run <id>` record the
# supervisor saw at the third escalation (review, fixing, active_for 29m53s,
# last_activity 5s, agent_pid 83267, round "fix 2").
#
# Usage: TREE=<firstmate checkout> parked-worker-wedge-repro.sh <scenario>
#   ladder     three consecutive wedge-threshold crossings on a parked worker
#              whose run is still logging (the reported incident)
#   quiet      the same run after it genuinely stopped logging
#   resurface  a deferral that has been held for 500s, past FM_PAUSE_RESURFACE_SECS
set -u
TREE=${TREE:?set TREE to a firstmate checkout}
SCENARIO=${1:-ladder}
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/parked-worker-repro.XXXXXX")
[ -n "${KEEP:-}" ] || trap 'rm -rf "$SANDBOX"' EXIT

STATE="$SANDBOX/state"; FAKEBIN="$SANDBOX/fakebin"; WT="$SANDBOX/worktree"
mkdir -p "$STATE" "$FAKEBIN" "$WT"
WINDOW="firstmate:fm-dropped-ci"; TASK="dropped-ci"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
BRANCH="fm/firstmate-detect-dropped-ci-event"

# --- the crew's real worktree, on the real branch ---------------------------
git -C "$WT" init -q
git -C "$WT" -c user.name=fmtest -c user.email=fm@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m init
git -C "$WT" checkout -q -b "$BRANCH"
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)

# --- the pipeline's own report, as `no-mistakes axi status --run <id>` emits it
case "$SCENARIO" in
  quiet) LAST_ACTIVITY='"quiet 31m2s"' ;;   # the run genuinely stopped logging
  *)     LAST_ACTIVITY='5s' ;;              # the reported "last_activity 5s ago"
esac
cat > "$SANDBOX/axi-status.toon" <<EOF
run:
  id: "01RUNDROPPEDCI"
  branch: $BRANCH
  status: fixing
  head: "$HEAD_SHA"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,29m53s,$LAST_ACTIVITY,83267,"fix 2"
EOF
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi) shift; case "\${1:-}" in status) cat "$SANDBOX/axi-status.toon" ;; esac ;;
  daemon) printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/no-mistakes"

# --- one fake multiplexer serving both the watcher and fm-crew-state.sh -----
# The worker is parked on a monitor: its pane renders the same bytes every poll.
printf 'Waiting for the next gate...\n> \n' > "$SANDBOX/pane.txt"
cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-windows)  printf '%s\n' "${WINDOW#*:}" ;;
  capture-pane)  cat "$SANDBOX/pane.txt" ;;
  display-message)
    case "\$*" in
      *pane_current_command*) printf 'bash\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/tmux"

# --- the crew's recorded state ----------------------------------------------
printf 'window=%s\nworktree=%s\nkind=ship\n' "$WINDOW" "$WT" > "$STATE/$TASK.meta"
printf 'working: handed the branch to no-mistakes\n' > "$STATE/$TASK.status"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$TREE/bin/fm-wake-lib.sh" "$STATE" "$STATE/$TASK.status"
PANE_HASH=$(printf '%s' "$(cat "$SANDBOX/pane.txt")" | { md5 -q 2>/dev/null || md5sum | cut -d' ' -f1; })
printf '%s' "$PANE_HASH" > "$STATE/.hash-$KEY"
printf '1\n' > "$STATE/.count-$KEY"

run_watcher() {  # <out> <stale-escalate-secs> [extra env...]
  local out=$1 esc=$2; shift 2
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$TREE/bin/fm-crew-state.sh" FM_FAKE_TMUX_WINDOW="$WINDOW" \
    FM_STALE_ESCALATE_SECS="$esc" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 env "$@" "$TREE/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCHER_PID=$!
}
# Killing a still-running watcher leaves the .watcher-down marker a real
# shutdown would not; clearing it keeps a harness artifact out of the transcript.
stop_watcher() { kill "$WATCHER_PID" 2>/dev/null; wait "$WATCHER_PID" 2>/dev/null; rm -f "$STATE/.watcher-down"; }
# Re-declare the (unchanged) status log as already seen, so an unrelated
# signature drift cannot masquerade as the crossing's own verdict.
reprime() { FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$TREE/bin/fm-wake-lib.sh" "$STATE" "$STATE/$TASK.status"; }
settle() { local i; for i in $(seq 1 120); do kill -0 "$WATCHER_PID" 2>/dev/null || return 0; sleep 0.1; done; }

# Model the supervision handling turn each escalation costs: the captain drains
# the queue and acknowledges it, exactly as firstmate does after handling a wake.
handle_and_drain() {
  local err="$SANDBOX/ack.err" seq gen
  FM_STATE_OVERRIDE="$STATE" "$TREE/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  gen=$(sed -n 's/.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && FM_STATE_OVERRIDE="$STATE" \
    "$TREE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  rm -f "$STATE/.watcher-down"
}
show() { if [ -s "$1" ]; then sed 's/^/    /' "$1"; else printf '    %s\n' "${2:-(empty)}"; fi; }

echo "=============================================================="
echo " scenario: $SCENARIO"
echo " tree:     $TREE"
echo "=============================================================="
echo
echo "--- what the pipeline reports: no-mistakes axi status --run 01RUNDROPPEDCI"
PATH="$FAKEBIN:$PATH" no-mistakes axi status --run 01RUNDROPPEDCI | sed 's/^/    /'
echo
echo "--- what firstmate reads back for this crew: bin/fm-crew-state.sh $TASK"
PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" "$TREE/bin/fm-crew-state.sh" "$TASK" | sed 's/^/    /'
echo

# Poll 1: the watcher classifies the parked pane stale and opens its wedge timer.
run_watcher "$SANDBOX/poll1.out" 999
for _ in $(seq 1 120); do [ -s "$STATE/.stale-since-$KEY" ] && break; sleep 0.1; done
sleep 1; stop_watcher
[ -s "$STATE/.stale-since-$KEY" ] || { echo "SETUP FAILED: no wedge timer opened"; exit 1; }
# Precondition: the captain has handled and drained everything before the first
# threshold crossing, so anything below is caused by the crossing itself.
rm -f "$STATE/.wake-queue" "$STATE/.watcher-down"

if [ "$SCENARIO" = resurface ]; then
  BACK=$(( $(date +%s) - 500 ))
  echo "$BACK" > "$STATE/.stale-since-$KEY"
  printf '%s' "$PANE_HASH" > "$STATE/.stale-$KEY"
  # This pane has already been deferring on the run's own activity for 500s.
  : > "$STATE/.run-active-since-$KEY"
  if STAMP=$(date -r "$BACK" +%Y%m%d%H%M.%S 2>/dev/null); then :; else STAMP=$(date -d "@$BACK" +%Y%m%d%H%M.%S); fi
  touch -t "$STAMP" "$STATE/.run-active-since-$KEY" "$STATE/.stale-since-$KEY"
  : > "$STATE/.watch-triage.log"
  echo "--- a deferral held for 500s, with FM_PAUSE_RESURFACE_SECS=240"
  run_watcher "$SANDBOX/rs.out" 240 FM_PAUSE_RESURFACE_SECS=240
  settle; stop_watcher
  echo
  echo "[watcher stdout - the wake reason firstmate's captain is handed]"
  show "$SANDBOX/rs.out" "(nothing)"
  echo
  echo "[durable wake queue - what a later drain replays]"
  show "$STATE/.wake-queue" "(empty - no wake recorded)"
  echo
  echo "[wedge escalation counter]"
  if [ -e "$STATE/.wedge-escalations-$KEY" ]; then
    printf '    escalations recorded: %s\n' "$(cat "$STATE/.wedge-escalations-$KEY")"
  else
    printf '    (none - the recheck did not advance the escalation ladder)\n'
  fi
  exit 0
fi

# Three consecutive crossings of the 240s wedge threshold, ~4 minutes apart -
# the "three escalations in about twelve minutes" from the incident report.
for ROUND in 1 2 3; do
  reprime
  echo $(( $(date +%s) - 250 )) > "$STATE/.stale-since-$KEY"
  : > "$STATE/.watch-triage.log"
  : > "$SANDBOX/x$ROUND.out"
  run_watcher "$SANDBOX/x$ROUND.out" 240
  settle; stop_watcher
  echo "--- crossing $ROUND: the pane has been quiet 250s, threshold is 240s"
  echo "  [watcher stdout - the wake reason firstmate's captain is handed]"
  show "$SANDBOX/x$ROUND.out" "(nothing - the watcher kept running; no supervision turn spent)"
  echo "  [state/.watch-triage.log - the watcher's own account of the decision]"
  show "$STATE/.watch-triage.log" "(empty)"
  if [ -s "$SANDBOX/x$ROUND.out" ]; then
    echo "  [cost] a supervision handling turn is now owed; draining it as the captain would"
    QUEUED=$(cat "$STATE/.wake-queue" 2>/dev/null | wc -l | tr -d ' ')
    handle_and_drain
    printf '        drained %s queued wake(s)\n' "$QUEUED"
  fi
  echo
done
echo "--- durable wake queue after three crossings (what a drain replays)"
show "$STATE/.wake-queue" "(empty - no wake recorded, no handling turn owed)"
