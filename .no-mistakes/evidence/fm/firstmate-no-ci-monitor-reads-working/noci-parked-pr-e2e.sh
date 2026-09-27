#!/usr/bin/env bash
# Manual end-to-end reproduction of the 2026-09-24 pkm-instruction-budget-ship
# defect: a PR parked for the captain's merge in a repo that declared
# `no_ci: true`. The no-mistakes ci step logs the no-CI marker and then a
# base-advance re-arm line; before the fix the crew read "working" and the idle
# pane kept escalating the wedge ladder.
#
# Drives the REAL bin/fm-crew-state.sh, the REAL bin/fm-classify-lib.sh
# predicates the wedge ladder consults, and the REAL bin/fm-watch.sh watcher,
# against a hermetic fake `no-mistakes` CLI that replays the incident's ci log.
# Run once against the base commit's bin/ and once against the fixed bin/.
set -u

REPO=${REPO:?}
BASE_REV=${BASE_REV:?}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/noci-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/base"
git -C "$REPO" archive "$BASE_REV" | tar -x -C "$WORK/base"

CI_LOG='[ci] waiting for checks on PR #41...
[ci] repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed
[ci] base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout'

AXI_STATUS_TEMPLATE='run:
  id: "01RUNNOCI"
  branch: fm/pkm-instruction-budget-ship
  status: running
  head: "__HEAD__"
  pr: "https://github.com/o/r/pull/41"
  findings: none
  steps[5]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    test,completed,0,0
    push,completed,0,0
    ci,running,0,0'

make_fakebin() {  # <dir>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) shift; [ "${1:-}" = --run ] && exit 0; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs)   printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac ;;
  runs)   printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)   printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}" ;;
  capture-pane)   printf 'idle, nothing to do\n> \n' ;;
  display-message)
    case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
}

setup_case() {  # <root> -> prints case dir
  local d=$1
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false -c gpg.format=openpgp commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/pkm-instruction-budget-ship
  make_fakebin "$d/fakebin"
  printf 'window=%s\nworktree=%s\nkind=ship\n' "fm:fm-pkm-instruction-budget-ship" "$d/wt" \
    > "$d/state/pkm-instruction-budget-ship.meta"
}

run_variant() {  # <label> <bin-root>
  local label=$1 root=$2 d head line
  d="$WORK/case-$label"
  setup_case "$d"
  head=$(git -C "$d/wt" rev-parse HEAD)
  export FM_FAKE_AXI_STATUS=${AXI_STATUS_TEMPLATE//__HEAD__/$head}
  export FM_FAKE_CI_LOGS=$CI_LOG
  export FM_FAKE_TMUX_WINDOW="fm:fm-pkm-instruction-budget-ship"

  echo "################################################################"
  echo "## $label  (bin from: $root)"
  echo "################################################################"
  echo
  echo "--- ci step log the fake \`no-mistakes axi logs --step ci\` replays ---"
  printf '%s\n' "$CI_LOG"
  echo
  echo "--- 1. what the crew reads: bin/fm-crew-state.sh pkm-instruction-budget-ship ---"
  line=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    bash "$root/bin/fm-crew-state.sh" pkm-instruction-budget-ship 2>&1)
  printf '%s\n' "$line"
  echo

  echo "--- 2. the predicates the wedge ladder asks (real bin/fm-classify-lib.sh) ---"
  cat > "$d/crew-state-shim" <<SH
#!/usr/bin/env bash
PATH="$d/fakebin:\$PATH" FM_STATE_OVERRIDE="$d/state" exec bash "$root/bin/fm-crew-state.sh" "\$@"
SH
  chmod +x "$d/crew-state-shim"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_BIN="$d/crew-state-shim" \
    bash -c '
      . "$1/bin/fm-classify-lib.sh"
      printf "crew_absorb_class          -> %s\n" "$(crew_absorb_class pkm-instruction-budget-ship)"
      if crew_done_no_active_run pkm-instruction-budget-ship; then
        printf "crew_done_no_active_run    -> true  (wedge ladder stops: awaiting merge)\n"
      else
        printf "crew_done_no_active_run    -> false (wedge ladder keeps escalating)\n"
      fi
    ' _ "$root" 2>&1
  echo
  echo "--- 3. the wedge ladder itself: real wedge_timer_check() from bin/fm-watch.sh ---"
  echo "    (idle pane, wedge timer 500s past the 240s threshold, 3 prior escalations)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_BIN="$d/crew-state-shim" \
    bash -c '
      set -u
      root=$1; state=$2
      # shellcheck disable=SC1090
      . "$root/bin/fm-watch.sh"
      win="fm:fm-pkm-instruction-budget-ship"
      key=$(window_key "$win")
      echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
      printf "3\n" > "$state/.wedge-escalations-$key"
      wedge_timer_check "$win" "$state/.stale-since-$key" stale \
        "$state/.wedge-escalations-$key" pkm-instruction-budget-ship 1
      printf "(ladder emitted no wake)\n"
    ' _ "$root" "$d/state" 2>&1 | sed 's/^/    watcher stdout: /'
  echo "    watch-triage log: $(tail -1 "$d/state/.watch-triage.log" 2>/dev/null || echo '(none)')"
  echo "    queued stale wakes: $(grep -c . "$d/state/.wake-queue" 2>/dev/null || echo 0)"
  echo "    wedge-escalation counter now: $(cat "$d/state/.wedge-escalations-fm_fm-pkm-instruction-budget-ship" 2>/dev/null || echo '(cleared)')"
  echo
  printf '%s\n' "$d" > "$WORK/last-case-$label"
}

run_variant "BEFORE the fix ($BASE_REV)" "$WORK/base"
echo
run_variant "AFTER  the fix (working tree)" "$REPO"

# --- guardrail matrix on the fixed bin: the new green latch must not swallow a
# --- real pending/failure marker, nor change the plain green-then-rearm rule.
echo
echo "################################################################"
echo "## guardrail matrix (fixed bin) - ci log -> crew state"
echo "################################################################"
matrix_case() {  # <name> <log>
  local name=$1 log=$2 d head
  d="$WORK/matrix-$name"
  setup_case "$d"
  head=$(git -C "$d/wt" rev-parse HEAD)
  export FM_FAKE_AXI_STATUS=${AXI_STATUS_TEMPLATE//__HEAD__/$head}
  export FM_FAKE_CI_LOGS=$log
  export FM_FAKE_TMUX_WINDOW="fm:fm-pkm-instruction-budget-ship"
  echo
  echo "### $name"
  printf '%s\n' "$log" | sed 's/^/    ci log: /'
  printf '    => %s\n' "$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    bash "$REPO/bin/fm-crew-state.sh" pkm-instruction-budget-ship 2>&1)"
}

matrix_case "declared no-CI, then base-advance re-arm (the incident)" \
'[ci] repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed
[ci] base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout'

matrix_case "declared no-CI, re-arm, then a real issue appears" \
'[ci] repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed
[ci] base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
[ci] issues detected: merge conflict - auto-fixing (attempt 2/10)...'

matrix_case "declared no-CI, re-arm, then checks start failing" \
'[ci] repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed
[ci] base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
[ci] 2 checks failed'

matrix_case "ordinary green CI, then base-advance re-arm (unchanged rule)" \
'[ci] all CI checks passed - still monitoring until merged or closed
[ci] base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout'
