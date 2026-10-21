#!/usr/bin/env bash
# Behavior tests for bin/fm-disk-sweep.sh.
#
# Covers task teardown cleanup, orphan-sweep age/live-state rules, process-use
# refusal, wrong-root and malformed-glob refusal, Xcode cache structure and
# WorkspacePath provenance, DerivedData matching, default-off idle-slot output,
# explicit idle-slot globs, low-space thresholds and wake throttling, dry-run-by-default,
# and the watcher's critical wake plus detached daily-sweep collection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-disk-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-sweep-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

make_case() {  # <name>
  local dir=$1
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/home/projects/demo" "$dir/temp" "$dir/derived" "$dir/fakebin"
  # A whole-system listing in which every *in-use* directory holds an open file.
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LSOF_FAIL:-}" ] || exit 1
printf 'p1\nfcwd\nn/\n'
[ -n "${FM_FAKE_LSOF_ROOT:-}" ] || exit 0
root=$(cd "$FM_FAKE_LSOF_ROOT" && pwd -P)
find "$root" -type d -name '*in-use*' | while IFS= read -r d; do
  printf 'f3\nn%s/Build/open-file\n' "$d"
done
SH
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_PS_PATH:-}" ]; then
  printf '99999 fake-worker %s\n' "$FM_FAKE_PS_PATH"
fi
SH
  cat > "$dir/fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake-volume 2000000000 1 %s 1%% /\n' "${FM_FAKE_FREE_KIB:-50000000}"
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -n "${FM_FAKE_AVAILABLE_WORKTREE:-}" ]; then
    printf '[{"name":"1","path":"%s","status":"available","processes":[]}]\n' "$FM_FAKE_AVAILABLE_WORKTREE"
  else
    printf '[]\n'
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/lsof" "$dir/fakebin/ps" "$dir/fakebin/df" "$dir/fakebin/treehouse"
  printf '%s\n' "$dir"
}

plist() {  # <entry> <workspace> [capitalized]
  local entry=$1 workspace=$2 file=info.plist
  [ "${3:-}" = capitalized ] && file=Info.plist
  mkdir -p "$entry"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist><dict><key>WorkspacePath</key>' \
    "<string>$workspace</string></dict></plist>" > "$entry/$file"
}

xcresult() {  # <bundle> [staging]
  mkdir -p "$1/Data"
  if [ "${2:-}" = staging ]; then mkdir -p "$1/Staging"; else printf '<plist/>\n' > "$1/Info.plist"; fi
}

old() {
  touch -t 202001010000 "$1"
}

run_sweep() {  # <case> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" \
    FM_FAKE_LSOF_ROOT="$dir" \
    FM_HOME="$dir/home" \
    FM_DISK_TEMP_ROOTS="$dir/temp" \
    FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    "$SWEEP" "$@"
}

test_task_cleanup_rules() {
  local dir wt out task_tmp
  dir=$(make_case cleanup)
  wt="$dir/wt"
  mkdir -p "$wt/build-cache/a" "$wt/keep" "$dir/outside/precious"
  printf 'golden\n' > "$wt/.env"
  printf 'keep\n' > "$dir/outside/precious/key"

  mkdir -p "$dir/temp/attempt-task-a/Build"
  plist "$dir/temp/attempt-task-a" "$wt/App.xcodeproj"
  xcresult "$dir/temp/result-task-a.xcresult"
  xcresult "$dir/temp/run-task-a.xcresult" staging
  mkdir -p "$dir/temp/fake-task-a.xcresult"
  xcresult "$dir/temp/mytask-abc.xcresult"
  printf 'worktree=%s\n' "$dir/sibling-wt" > "$dir/home/state/task-a-ui.meta"
  xcresult "$dir/temp/task-a-ui-Run.xcresult"
  mkdir -p "$dir/temp/name-only-task-a"
  printf 'not a cache\n' > "$dir/temp/name-only-task-a/file"
  mkdir -p "$dir/temp/in-use-task-a/Build"
  plist "$dir/temp/in-use-task-a" "$wt/App.xcodeproj"
  mkdir -p "$dir/temp/cmdline-task-a/Build"
  plist "$dir/temp/cmdline-task-a" "$wt/App.xcodeproj"
  mkdir -p "$dir/temp/other-task/Build"
  plist "$dir/temp/other-task" "$wt/App.xcodeproj"
  mkdir -p "$dir/outside/linked/Build"
  plist "$dir/outside/linked" "$wt/App.xcodeproj"
  ln -s "$dir/outside/linked" "$dir/temp/link-task-a"

  mkdir -p "$dir/derived/Demo-task-a/Build"
  plist "$dir/derived/Demo-task-a" "$wt/App.xcodeproj"
  mkdir -p "$dir/derived/Other/Build"
  plist "$dir/derived/Other" "$dir/another/App.xcodeproj"

  task_tmp="$dir/temp/fm-task-a"
  mkdir -p "$task_tmp"
  printf 'temporary\n' > "$task_tmp/file"

  out=$(FM_FAKE_LSOF_FAIL=1 run_sweep "$dir" --cleanup-task task-a "$wt" "$dir/home/projects/demo" 2>&1)
  [ -e "$dir/temp/attempt-task-a" ] || fail "cache was deleted although open files could not be listed"
  assert_contains "$out" "skip unprovable-open-state" "failed open-file listing was not reported as a refusal"

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_LSOF_ROOT="$dir" \
    FM_DISK_TEMP_ROOTS="$dir/temp" FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    FM_DISK_TASK_TMP="$task_tmp" \
    FM_FAKE_PS_PATH="$dir/temp/cmdline-task-a" \
    "$SWEEP" --cleanup-task task-a "$wt" "$dir/home/projects/demo" 2>&1)

  [ ! -e "$dir/temp/attempt-task-a" ] || fail "recognized task DerivedData temp cache was retained"
  [ ! -e "$dir/temp/result-task-a.xcresult" ] || fail "task xcresult was retained"
  [ ! -e "$dir/temp/run-task-a.xcresult" ] || fail "in-progress task xcresult was retained"
  [ -e "$dir/temp/fake-task-a.xcresult" ] || fail "xcresult-named directory without bundle layout was deleted"
  [ -e "$dir/temp/mytask-abc.xcresult" ] || fail "a bundle whose name only embeds the id inside another word was deleted"
  [ -e "$dir/temp/task-a-ui-Run.xcresult" ] || fail "a live sibling task's bundle was deleted"
  assert_contains "$out" "skip cache also named for live task task-a-ui" "live sibling refusal was not reported"
  [ ! -e "$dir/derived/Demo-task-a" ] || fail "matching global DerivedData was retained"
  [ ! -e "$task_tmp" ] || fail "recorded task temp root was retained"
  [ -e "$dir/temp/name-only-task-a" ] || fail "bare task-name match was deleted"
  [ -e "$dir/temp/in-use-task-a" ] || fail "lsof-held cache was deleted"
  [ -e "$dir/temp/cmdline-task-a" ] || fail "command-line-held cache was deleted"
  [ -e "$dir/temp/other-task" ] || fail "another task's cache was deleted"
  [ -e "$dir/outside/linked/Build" ] || fail "symlinked temp candidate escaped to a cache outside the temp root"
  [ -e "$dir/derived/Other" ] || fail "nonmatching DerivedData was deleted"
  [ -e "$wt/build-cache/a" ] || fail "worktree output was deleted without opt-in"
  [ -e "$wt/.env" ] || fail "golden local file was deleted"
  assert_contains "$out" "disk cleanup task-a: freed" "cleanup did not print one freed-space summary"
  assert_contains "$out" "skip in-use task temp cache" "in-use refusal was not reported"
  assert_contains "$out" "skip command-line-in-use task temp cache" "command-line refusal was not reported"
  assert_grep 'removed=task temp cache' "$dir/home/state/disk-sweep.log" "removed paths were not logged durably"

  printf 'demo\tbuild-cache/* ../outside/*\n' > "$dir/home/config/idle-slot-clean"
  out=$(run_sweep "$dir" --cleanup-task task-a "$wt" "$dir/home/projects/demo" 2>&1)
  [ ! -e "$wt/build-cache/a" ] || fail "opted-in idle-slot glob was not removed"
  [ -e "$dir/outside/precious/key" ] || fail "unsafe relative glob escaped the worktree"
  [ -e "$wt/.env" ] || fail "idle-slot cleanup deleted an unselected golden file"
  assert_contains "$out" "skip unsafe idle-slot glob" "wrong-root glob was not refused"
  pass "task cleanup requires structure, WorkspacePath, allowed roots, process safety, and idle-slot opt-in"
}

test_orphan_sweep_rules_and_default_dry_run() {
  local dir missing idle live_wt out
  dir=$(make_case orphan)
  git init -q "$dir/home/projects/demo"
  printf 'done [at=1]: old\n' > "$dir/home/state/old-task.status"
  printf 'working [at=1]: live\n' > "$dir/home/state/live-task.status"
  live_wt="$dir/live/1/demo"
  mkdir -p "$live_wt"
  git init -q "$live_wt"
  printf 'worktree=%s\n' "$live_wt" > "$dir/home/state/live-task.meta"

  missing="$dir/missing/1/demo/App.xcodeproj"
  mkdir -p "$dir/temp/cache-old-task/Build"
  plist "$dir/temp/cache-old-task" "$missing"
  old "$dir/temp/cache-old-task"
  mkdir -p "$dir/temp/cache-live-task/Build"
  plist "$dir/temp/cache-live-task" "$live_wt/App.xcodeproj"
  old "$dir/temp/cache-live-task"
  mkdir -p "$dir/temp/cache-young-old-task/Build"
  plist "$dir/temp/cache-young-old-task" "$missing"
  mkdir -p "$dir/temp/name-only-old-task"
  old "$dir/temp/name-only-old-task"
  mkdir -p "$dir/temp/in-use-old-task/Build"
  plist "$dir/temp/in-use-old-task" "$missing"
  old "$dir/temp/in-use-old-task"
  # The done task's slot now serves the live task; the cache is still orphaned.
  mkdir -p "$dir/temp/reused-slot-old-task/Build"
  plist "$dir/temp/reused-slot-old-task" "$live_wt/App.xcodeproj"
  old "$dir/temp/reused-slot-old-task"
  xcresult "$dir/temp/old-task-Run.xcresult"
  old "$dir/temp/old-task-Run.xcresult"
  mkdir -p "$dir/temp/foreign-old-task/Build"
  plist "$dir/temp/foreign-old-task" "$dir/elsewhere/App.xcodeproj"
  old "$dir/temp/foreign-old-task"
  mkdir -p "$dir/temp/cache-unknown-task/Build"
  plist "$dir/temp/cache-unknown-task" "$missing"
  old "$dir/temp/cache-unknown-task"
  # A task the backlog still lists as in flight, carrying no live state file.
  printf 'done [at=1]: stale\n' > "$dir/home/state/backlog-task.status"
  printf '%s\n' '## In flight' '- [ ] backlog-task Still running' \
    '## Queued' '- [ ] queued-task Waiting' > "$dir/home/data/backlog.md"
  mkdir -p "$dir/temp/cache-backlog-task/Build"
  plist "$dir/temp/cache-backlog-task" "$missing"
  old "$dir/temp/cache-backlog-task"
  mkdir -p "$dir/temp/cache-queued-task/Build"
  plist "$dir/temp/cache-queued-task" "$missing"
  old "$dir/temp/cache-queued-task"

  mkdir -p "$dir/derived/Dead/Build"
  plist "$dir/derived/Dead" "$missing"
  old "$dir/derived/Dead"
  mkdir -p "$dir/derived/Live/Build"
  plist "$dir/derived/Live" "$live_wt/App.xcodeproj"
  old "$dir/derived/Live"
  mkdir -p "$dir/derived/Young/Build"
  plist "$dir/derived/Young" "$missing"

  idle="$dir/pool/1/demo"
  mkdir -p "$idle"
  git init -q "$idle"
  mkdir -p "$dir/derived/Idle/Build"
  plist "$dir/derived/Idle" "$idle/App.xcodeproj"
  old "$dir/derived/Idle"

  out=$(FM_FAKE_AVAILABLE_WORKTREE="$idle" run_sweep "$dir" 2>&1)
  assert_contains "$out" "(dry run)" "default sweep was not a dry run"
  [ -e "$dir/temp/cache-old-task" ] || fail "dry run deleted an orphan temp cache"
  [ -e "$dir/derived/Dead" ] || fail "dry run deleted orphan DerivedData"

  out=$(FM_FAKE_AVAILABLE_WORKTREE="$idle" run_sweep "$dir" --apply 2>&1)
  [ ! -e "$dir/temp/cache-old-task" ] || fail "old orphan temp cache was retained"
  [ ! -e "$dir/temp/reused-slot-old-task" ] || fail "done task's cache was retained because its slot was reused"
  [ ! -e "$dir/temp/old-task-Run.xcresult" ] || fail "old done-task xcresult was retained"
  [ -e "$dir/temp/foreign-old-task" ] || fail "cache recording another home's workspace was deleted"
  [ -e "$dir/temp/cache-unknown-task" ] || fail "cache for a task id unknown to this home was deleted"
  [ -e "$dir/temp/cache-backlog-task" ] || fail "cache for a task the backlog lists as in flight was deleted"
  [ ! -e "$dir/temp/cache-queued-task" ] || fail "cache for a queued backlog task was retained"
  [ ! -e "$dir/derived/Dead" ] || fail "missing-workspace DerivedData was retained"
  [ ! -e "$dir/derived/Idle" ] || fail "old idle-slot DerivedData was retained"
  [ -e "$dir/temp/cache-live-task" ] || fail "live task temp cache was deleted"
  [ -e "$dir/temp/cache-young-old-task" ] || fail "young temp cache was deleted"
  [ -e "$dir/temp/name-only-old-task" ] || fail "unstructured temp directory was deleted"
  [ -e "$dir/temp/in-use-old-task" ] || fail "in-use orphan temp cache was deleted"
  [ -e "$dir/derived/Live" ] || fail "live-worktree DerivedData was deleted"
  [ -e "$dir/derived/Young" ] || fail "young DerivedData was deleted"
  assert_contains "$out" "disk sweep:" "applied sweep did not report totals"
  assert_grep 'mode=orphan-sweep' "$dir/home/state/disk-sweep.log" "durable sweep log omitted totals"
  pass "orphan sweep is dry-run by default and enforces age, live-task, backlog, structure, workspace, and in-use rules"
}

test_low_disk_thresholds() {
  local dir out
  dir=$(make_case thresholds)

  out=$(FM_FAKE_FREE_KIB=$((25 * 1024 * 1024)) run_sweep "$dir" --check 2>&1)
  [ -z "$out" ] || fail "healthy disk check was noisy: $out"

  out=$(FM_FAKE_FREE_KIB=$((15 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "warning: low disk" "warning threshold did not fire"
  assert_not_contains "$out" "wake:" "warning-only threshold escalated a wake"
  assert_contains "$out" "--apply" "low-disk warning omitted the safe reclaim command"

  out=$(FM_FAKE_FREE_KIB=$((5 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "wake: disk space is below the 10 GiB critical threshold" "critical threshold did not escalate"
  out=$(FM_FAKE_FREE_KIB=$((5 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "warning: low disk" "repeated critical check dropped the warning"
  assert_not_contains "$out" "wake:" "persisting critical space re-woke on the next check"
  out=$(FM_FAKE_FREE_KIB=$((25 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  out=$(FM_FAKE_FREE_KIB=$((5 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "wake:" "re-entering critical space after recovery did not wake"
  rm -f "$dir/home/state/.disk-space-critical-woke"

  printf 'warn_gb=30\nwake_gb=12\n' > "$dir/home/config/disk-space-thresholds"
  out=$(FM_FAKE_FREE_KIB=$((15 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "warn below 30 GiB" "custom warning threshold was ignored"
  assert_not_contains "$out" "wake:" "custom critical threshold escalated too early"
  out=$(FM_FAKE_FREE_KIB=$((11 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "wake: disk space is below the 12 GiB critical threshold" "custom critical threshold was ignored"
  pass "disk checks stay quiet when healthy and separate warning from wake thresholds"
}

wait_for_file() {  # <file> [tenths]
  local i=0
  while [ "$i" -lt "${2:-150}" ]; do
    [ -e "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

watch_disk() {  # <case> <free-kib> <out> [sweep-interval]; runs the real watcher in the background
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FAKE_LSOF_ROOT="$dir" FM_FAKE_FREE_KIB="$2" \
    FM_DISK_TEMP_ROOTS="$dir/temp" FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    FM_DISK_SWEEP_INTERVAL="${4:-1}" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$ROOT/bin/fm-watch.sh" > "$3" 2>&1 &
}

ack_wakes() {  # <state>; handles the queued wakes like a supervisor would
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

stop_pid() {  # <pid>; stops only the watcher this test started
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

test_watcher_wakes_once_and_collects_detached_sweep() {
  local dir state pid i
  dir=$(make_case watcher)
  state="$dir/home/state"
  touch -t 202001010000 "$state/.last-disk-sweep"

  watch_disk "$dir" $((5 * 1024 * 1024)) "$dir/watch1.out"
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  stop_pid "$pid"
  assert_grep 'check: disk-space: disk space is below the 10 GiB critical threshold' "$dir/watch1.out" \
    "critical disk space did not wake the watcher"
  assert_grep 'disk-space' "$state/.wake-queue" "critical disk wake was not queued durably"

  wait_for_file "$state/.disk-sweep.report" || fail "detached daily sweep never published its report"
  i=0
  while [ -d "$state/.disk-sweep.running" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ ! -d "$state/.disk-sweep.running" ] || fail "finished sweep left its running claim behind"
  ack_wakes "$state" || fail "could not acknowledge the disk-space wake"

  watch_disk "$dir" $((50 * 1024 * 1024)) "$dir/watch2.out" 999999
  pid=$!
  i=0
  while [ -e "$state/.disk-sweep.report" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  stop_pid "$pid"
  i=0
  while [ -d "$state/.disk-sweep.running" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  [ ! -e "$state/.disk-sweep.report" ] || fail "watcher never collected the finished sweep report: $(cat "$dir/watch2.out")"
  assert_not_contains "$(cat "$dir/watch2.out")" "check: disk-space" "a quiet sweep report woke the watcher"
  assert_grep 'mode=orphan-sweep' "$state/disk-sweep.log" "detached sweep did not log its totals"
  pass "watcher wakes on critical space and collects the detached daily sweep without waking"
}

test_task_cleanup_rules
test_orphan_sweep_rules_and_default_dry_run
test_low_disk_thresholds
test_watcher_wakes_once_and_collects_detached_sweep
