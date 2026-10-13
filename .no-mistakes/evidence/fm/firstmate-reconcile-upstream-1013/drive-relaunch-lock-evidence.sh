#!/usr/bin/env bash
# Evidence driver for the firstmate upstream reconcile (branch
# fm/firstmate-reconcile-upstream-1013). Exercises the real product surfaces the
# incoming upstream commit 6407052f and the fork's review fix e32050ea change:
#   1. the watcher's secondmate_liveness_tick (bin/fm-watch.sh, sourced through
#      its own source guard) under per-home relaunch-lock contention,
#   2. the same tick with the lock free,
#   3. the session-start bootstrap sweep recovering two distinct mates whose
#      fresh spawns overlap,
#   4. bin/fm-spawn.sh's task-set refusal naming the holder it found.
set -u
WT=/Users/crossbow/.no-mistakes/worktrees/00644a303d6a/01M4VA59PE9GT8G6SH21MJZQ31
# shellcheck source=/dev/null
. "$WT/tests/lib.sh"
TMP=$(fm_test_tmproot fm-reconcile-evidence)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

fake_tmux() {  # <dir> -> fakebin dir; FM_TEST_PANE_CMD drives the probe verdict
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *pane_current_command*)
      case "$mode" in missing) printf 'node\n'; exit 0 ;; unreadable) exit 1 ;;
        *) printf '%s\n' "$mode"; exit 0 ;; esac ;; esac; done
    exit 0 ;;
  list-sessions) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    case "$mode" in
      missing) printf 'main\n'; exit 0 ;;
      unreadable) exit 1 ;;
      *) [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf 'fm-sm1\n'; exit 0 ;;
    esac ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    if [ "${1:-}" = new-window ] && [ -n "${FM_TEST_NEW_WINDOW_PAUSE:-}" ]; then
      sleep "$FM_TEST_NEW_WINDOW_PAUSE"
    fi
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

new_world() {  # <name> -> world dir with a primary home
  local w="$TMP/$1"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

add_sm_home() {  # <world> <id> <window>
  local w=$1 id=$2 window=$3 home
  home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  { printf 'window=%s\n' "$window"; printf 'kind=secondmate\n'
    printf 'harness=claude\n'; printf 'home=%s\n' "$home"; } > "$w/home/state/$id.meta"
}

hold_lock() {  # <state> <lock-path> [role] -> holder pid (lock held ~30s)
  local state=$1 lock=$2 role=${3:-} holder i=0
  ( STATE="$state" bash -c '
      . "$1"
      fm_lock_try_acquire "$2" || exit 1
      [ -z "$3" ] || fm_lock_set_role "$2" "$3" || exit 1
      sleep 30' _ "$WT/bin/fm-wake-lib.sh" "$lock" "$role" ) >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  if [ -n "$role" ]; then
    while [ "$(cat "$lock/role" 2>/dev/null || true)" != "$role" ] && [ "$i" -lt 200 ]; do
      sleep 0.05; i=$((i + 1))
    done
  fi
  printf '%s\n' "$holder"
}

# make_toolchain() is lifted verbatim from tests/fm-secondmate-liveness.test.sh:
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

hr() { printf '\n==================== %s ====================\n' "$*"; }

watcher_tick() {  # <world> <PATH-prefix> <call-log>
  local w=$1 fb=$2 log=$3
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_ROOT_OVERRIDE="$WT" \
    FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$log" \
    FM_SECONDMATE_LIVENESS_TIMEOUT=1 \
    bash -c '
      set -u
      . "'"$WT"'/bin/fm-watch.sh"
      rc=0
      secondmate_liveness_tick || rc=$?
      echo "[watcher] secondmate_liveness_tick exit status: $rc"
    ' _ 2>&1
}

# ---------------------------------------------------------------- scenario 1
hr "1. watcher tick: another mate's relaunch already owns the per-home lock"
w=$(new_world watcher-contended); add_sm_home "$w" sm1 firstmate:fm-sm1
fb=$(fake_tmux "$w"); tc=$(make_toolchain "$w"); log="$w/calls.log"; : > "$log"
lock="$w/home/state/.secondmate-relaunch.lock"
holder=$(hold_lock "$w/home/state" "$lock")
echo "[setup] a concurrent relaunch (pid $(cat "$lock/pid" 2>/dev/null)) holds $lock"
watcher_tick "$w" "$fb:$tc" "$log"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
echo "--- endpoint calls made (tmux kill-window/new-window): ---"
if [ -s "$log" ]; then cat "$log"; else echo "(none: the dead endpoint was left exactly as found)"; fi
echo "--- durable attempt ledger state/.secondmate-relaunch-sm1: ---"
if [ -e "$w/home/state/.secondmate-relaunch-sm1" ]; then
  cat "$w/home/state/.secondmate-relaunch-sm1"
else
  echo "(absent: a relaunch that never ran did not consume one of the 3 attempts)"
fi

# ---------------------------------------------------------------- scenario 2
hr "2. watcher tick: the same dead mate with the per-home lock free"
echo "(the spawn itself still warns because this fixture's primary home is not a"
echo " git repo; the point of the contrast is that the endpoint IS killed and"
echo " respawned and an attempt IS ledgered once the lock is available.)"
w=$(new_world watcher-free); add_sm_home "$w" sm1 firstmate:fm-sm1
fb=$(fake_tmux "$w"); tc=$(make_toolchain "$w"); log="$w/calls.log"; : > "$log"
watcher_tick "$w" "$fb:$tc" "$log"
echo "--- endpoint calls made: ---"; cat "$log"
echo "--- durable attempt ledger state/.secondmate-relaunch-sm1: ---"
cat "$w/home/state/.secondmate-relaunch-sm1"
echo "--- queued captain wake rows (state/.wake-queue): ---"
cat "$w/home/state/.wake-queue" 2>/dev/null || echo "(none)"

# ---------------------------------------------------------------- scenario 3
hr "3. session-start sweep: two distinct dead mates whose spawns overlap"
w=$(new_world sweep-concurrent)
add_sm_home "$w" sm1 firstmate:fm-sm1
add_sm_home "$w" sm2 firstmate:fm-sm2
fb=$(fake_tmux "$w"); tc=$(make_toolchain "$w"); log="$w/calls.log"; : > "$log"
PATH="$fb:$tc:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
  FM_TEST_PANE_CMD=missing FM_TMUX_CALL_LOG="$log" FM_TEST_NEW_WINDOW_PAUSE=2 \
  "$WT/bin/fm-bootstrap.sh" 2>&1 | grep -E 'SECONDMATE_LIVENESS|respawn|task set' \
  || echo "(bootstrap printed no SECONDMATE_LIVENESS line: every mate recovered silently)"
echo "--- fresh spawns reaching the backend: ---"
grep -c '^new-window ' "$log" | sed 's/^/new-window calls: /'
for id in sm1 sm2; do
  printf -- '--- state/.secondmate-relaunch-%s: ---\n' "$id"
  cat "$w/home/state/.secondmate-relaunch-$id" 2>/dev/null || echo "(absent)"
done

# ---------------------------------------------------------------- scenario 4
hr "4. fm-spawn.sh task-set refusal names the holder it actually found"
spawn_home="$TMP/spawn-home"
mkdir -p "$spawn_home/state" "$spawn_home/data" "$spawn_home/projects"
printf '%s\n' domain > "$spawn_home/.fm-secondmate-home"
fm_git_worktree "$spawn_home/projects/alpha" "$TMP/spawn-child-wt" child-evidence >/dev/null 2>&1
lock=$( . "$WT/bin/fm-wake-lib.sh"; fm_task_set_lock_path "$spawn_home/state" )
for role in task-spawn forced-teardown none; do
  rm -rf "$lock"
  if [ "$role" = none ]; then
    holder=$(hold_lock "$spawn_home/state" "$lock")
  else
    holder=$(hold_lock "$spawn_home/state" "$lock" "$role")
  fi
  printf -- '--- recorded lock holder role: %s ---\n' "$(cat "$lock/role" 2>/dev/null || echo '(unrecorded)')"
  printf '$ fm-spawn.sh newtask %s --scout\n' "$spawn_home/projects/alpha"
  FM_HOME="$spawn_home" FM_SPAWN_NO_GUARD=1 PATH="$BASE_PATH" \
    "$WT/bin/fm-spawn.sh" newtask "$spawn_home/projects/alpha" --scout 2>&1 >/dev/null \
    | grep -E '^error:' || echo "(no refusal printed)"
  printf 'published task meta: %s\n' \
    "$([ -e "$spawn_home/state/newtask.meta" ] && echo yes || echo 'no (refused before publication)')"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
done
hr "end of evidence run"
