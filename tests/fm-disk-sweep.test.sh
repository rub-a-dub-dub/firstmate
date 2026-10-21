#!/usr/bin/env bash
# Behavior tests for bin/fm-disk-sweep.sh.
#
# Covers task teardown cleanup for a task that owns a worktree and for a
# secondmate that owns none, orphan-sweep age/live-state rules, process-use
# refusal for inferred candidates, honest reporting and record-keeping when a
# bounded size probe cannot finish, unconditional removal of the two temp roots
# teardown owns, wrong-root refusal, Xcode cache structure and WorkspacePath
# provenance (including a WorkspacePath equal to the worktree root),
# DerivedData matching, refusal to touch anything inside a worktree, Treehouse
# pool-root attribution of orphan and consumer rows, the available-versus-busy
# slot decision for a workspace that still exists, low-space thresholds and
# wake throttling, dry-run-by-default, and the watcher's critical wake plus
# detached daily-sweep collection.
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
  if [ -n "${FM_FAKE_SLOTS:-}" ]; then
    # <path>|<status> entries separated by ';', as one pool's slot list.
    printf '['
    sep=''
    IFS=';' read -r -a slots <<< "$FM_FAKE_SLOTS"
    for slot in "${slots[@]}"; do
      [ -n "$slot" ] || continue
      printf '%s{"name":"s","path":"%s","status":"%s","processes":[]}' \
        "$sep" "${slot%%|*}" "${slot#*|}"
      sep=','
    done
    printf ']\n'
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

xcresult() {  # <bundle>; an Xcode result bundle, which records no WorkspacePath
  mkdir -p "$1/Data"
  printf '<plist/>\n' > "$1/Info.plist"
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
  local dir wt out task_tmp launch
  dir=$(make_case cleanup)
  wt="$dir/wt"
  mkdir -p "$wt/build-cache/a" "$wt/keep"
  printf 'golden\n' > "$wt/.env"

  mkdir -p "$dir/temp/attempt-task-a/Build"
  plist "$dir/temp/attempt-task-a" "$wt/App.xcodeproj"
  xcresult "$dir/temp/result-task-a.xcresult"
  printf 'worktree=%s\n' "$dir/sibling-wt" > "$dir/home/state/task-a-ui.meta"
  mkdir -p "$dir/temp/task-a-ui-Run/Build"
  plist "$dir/temp/task-a-ui-Run" "$wt/App.xcodeproj"
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
  # Xcode records the package directory itself for a Swift package opened as a
  # folder, so the worktree root is a WorkspacePath this cleanup must match.
  mkdir -p "$dir/derived/Package-task-a/Build"
  plist "$dir/derived/Package-task-a" "$wt"

  task_tmp="$dir/temp/fm-task-a"
  mkdir -p "$task_tmp"
  printf 'temporary\n' > "$task_tmp/file"
  launch="$dir/temp/fm-task-a+$(home_hash_for "$dir/home")"
  mkdir -p "$launch"
  printf 'launch\n' > "$launch/command"

  # A whole-system listing that cannot complete must retain every inferred
  # candidate, and must not strand the two roots teardown created itself.
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_LSOF_ROOT="$dir" \
    FM_DISK_TEMP_ROOTS="$dir/temp" FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    FM_DISK_TASK_TMP="$task_tmp" FM_FAKE_LSOF_FAIL=1 \
    "$SWEEP" --cleanup-task task-a "$wt" 2>&1)
  [ -e "$dir/temp/attempt-task-a" ] || fail "cache was deleted although open files could not be listed"
  [ -e "$dir/derived/Demo-task-a" ] || fail "DerivedData was deleted although open files could not be listed"
  assert_contains "$out" "skip unprovable-open-state" "failed open-file listing was not reported as a refusal"
  [ ! -e "$task_tmp" ] || fail "recorded task temp root was stranded by a failed open-file listing"
  [ ! -e "$launch" ] || fail "launch temp namespace was stranded by a failed open-file listing"

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_LSOF_ROOT="$dir" \
    FM_DISK_TEMP_ROOTS="$dir/temp" FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    FM_FAKE_PS_PATH="$dir/temp/cmdline-task-a" \
    "$SWEEP" --cleanup-task task-a "$wt" 2>&1)

  [ ! -e "$dir/temp/attempt-task-a" ] || fail "recognized task DerivedData temp cache was retained"
  [ -e "$dir/temp/result-task-a.xcresult" ] \
    || fail "a result bundle was deleted on its task-id-bearing name, with no WorkspacePath to prove whose it is"
  [ -e "$dir/temp/task-a-ui-Run" ] || fail "a live sibling task's cache was deleted"
  assert_contains "$out" "skip cache also named for live task task-a-ui" "live sibling refusal was not reported"
  [ ! -e "$dir/derived/Demo-task-a" ] || fail "matching global DerivedData was retained"
  [ ! -e "$dir/derived/Package-task-a" ] || fail "DerivedData whose WorkspacePath is the worktree root was retained"
  [ -e "$dir/temp/name-only-task-a" ] || fail "bare task-name match was deleted"
  [ -e "$dir/temp/in-use-task-a" ] || fail "lsof-held cache was deleted"
  [ -e "$dir/temp/cmdline-task-a" ] || fail "command-line-held cache was deleted"
  [ -e "$dir/temp/other-task" ] || fail "another task's cache was deleted"
  [ -e "$dir/outside/linked/Build" ] || fail "symlinked temp candidate escaped to a cache outside the temp root"
  [ -e "$dir/derived/Other" ] || fail "nonmatching DerivedData was deleted"
  [ -e "$wt/build-cache/a" ] || fail "build output inside the worktree was deleted"
  [ -e "$wt/.env" ] || fail "golden local file was deleted"
  assert_contains "$out" "disk cleanup task-a: freed" "cleanup did not print one freed-space summary"
  assert_contains "$out" "skip in-use task temp cache" "in-use refusal was not reported"
  assert_contains "$out" "skip command-line-in-use task temp cache" "command-line refusal was not reported"
  assert_grep 'removed=task temp cache' "$dir/home/state/disk-sweep.log" "removed paths were not logged durably"

  pass "task cleanup requires structure, WorkspacePath, allowed roots, and process safety, and never deletes inside the worktree"
}

home_hash_for() {  # <home>
  local root
  root=$(cd "$1" && pwd -P)
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$root" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$root" | sha256sum | awk '{print $1}'
  fi
}

# A secondmate teardown owns no worktree, so bin/fm-teardown.sh calls the same
# cleanup with an empty worktree argument.
test_secondmate_cleanup_without_a_worktree() {
  local dir out task_tmp launch
  dir=$(make_case secondmate)
  task_tmp="$dir/temp/fm-design"
  launch="$dir/temp/fm-design+$(home_hash_for "$dir/home")"
  mkdir -p "$task_tmp/gotmp" "$launch"
  printf 'temporary\n' > "$task_tmp/gotmp/build-artifact"
  printf 'launch\n' > "$launch/command"
  xcresult "$dir/temp/run-design.xcresult"
  mkdir -p "$dir/temp/attempt-design/Build"
  plist "$dir/temp/attempt-design" "$dir/elsewhere/App.xcodeproj"
  mkdir -p "$dir/derived/Demo-design/Build"
  plist "$dir/derived/Demo-design" "$dir/elsewhere/App.xcodeproj"

  out=$(FM_DISK_TASK_TMP="$task_tmp" run_sweep "$dir" --cleanup-task design "" 2>&1) \
    || fail "cleanup refused a secondmate's empty worktree argument: $out"

  [ ! -e "$task_tmp" ] || fail "secondmate cleanup retained the recorded task temp root"
  [ ! -e "$launch" ] || fail "secondmate cleanup retained this home's launch namespace"
  [ -e "$dir/temp/run-design.xcresult" ] \
    || fail "secondmate cleanup deleted a result bundle on its name alone"
  [ -e "$dir/temp/attempt-design" ] \
    || fail "a DerivedData-layout temp cache was deleted with no worktree to prove its WorkspacePath"
  [ -e "$dir/derived/Demo-design" ] || fail "global DerivedData was deleted with no worktree to match"
  assert_contains "$out" "disk cleanup design: freed" "cleanup did not print one freed-space summary"
  pass "cleanup for a secondmate with no worktree clears its temp roots and touches no DerivedData"
}

# A remote secondmate's control state lives inside the home being retired, so
# bin/fm-teardown.sh calls this cleanup after that home is gone. The temp roots
# must still be cleared, and no durable record may recreate the retired home.
test_cleanup_after_the_home_is_retired_writes_nothing_back() {
  local dir out retired task_tmp launch
  dir=$(make_case retired)
  retired="$dir/retired-home"
  task_tmp="$dir/temp/fm-ios"
  launch="$dir/temp/fm-ios+$(home_hash_for "$dir/home")"
  mkdir -p "$task_tmp/gotmp" "$launch"
  printf 'temporary\n' > "$task_tmp/gotmp/build-artifact"
  printf 'launch\n' > "$launch/command"

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$retired/state/parent-route" \
    FM_DISK_TEMP_ROOTS="$dir/temp" FM_DISK_DERIVED_DATA_ROOT="$dir/derived" \
    FM_DISK_TASK_TMP="$task_tmp" \
    "$SWEEP" --cleanup-task ios "" 2>&1) \
    || fail "cleanup failed once the retired home's state was gone: $out"

  [ ! -e "$task_tmp" ] || fail "cleanup retained the retired secondmate's task temp root"
  [ ! -e "$launch" ] || fail "cleanup retained the retired secondmate's launch namespace"
  [ ! -e "$retired" ] || fail "cleanup recreated the retired home to write its durable record"
  assert_contains "$out" "disk cleanup ios: freed" "cleanup did not print one freed-space summary"
  pass "cleanup for a retired home clears its temp roots without recreating the removed home"
}

# state/disk-sweep.log is this script's documented durable record: one
# `removed=<label>\tbytes=<size>\tpath=<path>` row per removed path.
test_unmeasurable_size_is_not_reported_as_zero() {
  local dir out task_tmp
  dir=$(make_case unsized)
  # The size probe is bounded; a walk of a multi-GiB tree that outruns its
  # bound leaves fm_run_timed with a nonzero status, exactly as this stands in.
  cat > "$dir/fakebin/du" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$dir/fakebin/du"
  task_tmp="$dir/temp/fm-slow"
  mkdir -p "$task_tmp"
  printf 'temporary\n' > "$task_tmp/file"

  out=$(FM_DISK_TASK_TMP="$task_tmp" run_sweep "$dir" --cleanup-task slow "" 2>&1) \
    || fail "cleanup failed when the size probe could not finish: $out"

  [ ! -e "$task_tmp" ] || fail "an unmeasurable path was not removed"
  assert_contains "$out" "1 removed path(s) of unmeasured size" \
    "the summary hid that a removed path's size could not be measured"
  assert_grep 'bytes=unknown' "$dir/home/state/disk-sweep.log" \
    "the durable record logged an unmeasurable size as a measured value"
  assert_not_contains "$out" "freed 1" "an unmeasured path was counted into the freed total"
  pass "a removed path whose bounded size probe cannot finish is reported as unmeasured, not as zero bytes"
}

test_orphan_sweep_rules_and_default_dry_run() {
  local dir missing idle busy live_wt lookalike out slots
  dir=$(make_case orphan)
  git init -q "$dir/home/projects/demo"
  printf 'done [at=1]: old\n' > "$dir/home/state/old-task.status"
  printf 'working [at=1]: live\n' > "$dir/home/state/live-task.status"
  # Every slot of this project shares one Treehouse pool root; slot 9 is gone.
  idle="$dir/pool/1/demo"
  busy="$dir/pool/3/demo"
  live_wt="$dir/pool/2/demo"
  missing="$dir/pool/9/demo/App.xcodeproj"
  mkdir -p "$live_wt"
  git init -q "$live_wt"
  printf 'worktree=%s\n' "$live_wt" > "$dir/home/state/live-task.meta"
  # A digit-leading ancestor plus a project name is not this home's layout.
  lookalike="$dir/Dropbox/2024/demo/App.xcodeproj"
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
  mkdir -p "$dir/temp/lookalike-old-task/Build"
  plist "$dir/temp/lookalike-old-task" "$lookalike"
  old "$dir/temp/lookalike-old-task"

  mkdir -p "$dir/derived/Dead/Build"
  plist "$dir/derived/Dead" "$missing"
  old "$dir/derived/Dead"
  mkdir -p "$dir/derived/Live/Build"
  plist "$dir/derived/Live" "$live_wt/App.xcodeproj"
  old "$dir/derived/Live"
  mkdir -p "$dir/derived/Young/Build"
  plist "$dir/derived/Young" "$missing"
  mkdir -p "$dir/derived/Lookalike/Build"
  plist "$dir/derived/Lookalike" "$lookalike"
  old "$dir/derived/Lookalike"

  # Both slots keep a tracked workspace the way a returned Hattie slot does, so
  # the missing-workspace branch cannot decide either: only the slot state can.
  mkdir -p "$idle/App.xcodeproj"
  git init -q "$idle"
  mkdir -p "$dir/derived/Idle/Build"
  plist "$dir/derived/Idle" "$idle/App.xcodeproj"
  old "$dir/derived/Idle"
  mkdir -p "$busy/App.xcodeproj"
  git init -q "$busy"
  mkdir -p "$dir/derived/Busy/Build"
  plist "$dir/derived/Busy" "$busy/App.xcodeproj"
  old "$dir/derived/Busy"
  slots="$idle|available;$busy|busy"

  out=$(FM_FAKE_SLOTS="$slots" run_sweep "$dir" 2>&1)
  assert_contains "$out" "(dry run)" "default sweep was not a dry run"
  [ -e "$dir/temp/cache-old-task" ] || fail "dry run deleted an orphan temp cache"
  [ -e "$dir/derived/Dead" ] || fail "dry run deleted orphan DerivedData"

  out=$(FM_FAKE_SLOTS="$slots" run_sweep "$dir" --apply 2>&1)
  [ ! -e "$dir/temp/cache-old-task" ] || fail "old orphan temp cache was retained"
  [ ! -e "$dir/temp/reused-slot-old-task" ] || fail "done task's cache was retained because its slot was reused"
  [ -e "$dir/temp/foreign-old-task" ] || fail "cache recording another home's workspace was deleted"
  [ -e "$dir/temp/cache-unknown-task" ] || fail "cache for a task id unknown to this home was deleted"
  [ -e "$dir/temp/cache-backlog-task" ] || fail "cache for a task the backlog lists as in flight was deleted"
  [ ! -e "$dir/temp/cache-queued-task" ] || fail "cache for a queued backlog task was retained"
  [ ! -e "$dir/derived/Dead" ] || fail "missing-workspace DerivedData was retained"
  [ ! -e "$dir/derived/Idle" ] || fail "old idle-slot DerivedData was retained"
  [ -e "$dir/derived/Busy" ] || fail "DerivedData for a slot Treehouse reports busy was deleted"
  [ -e "$dir/temp/cache-live-task" ] || fail "live task temp cache was deleted"
  [ -e "$dir/temp/cache-young-old-task" ] || fail "young temp cache was deleted"
  [ -e "$dir/temp/name-only-old-task" ] || fail "unstructured temp directory was deleted"
  [ -e "$dir/temp/in-use-old-task" ] || fail "in-use orphan temp cache was deleted"
  [ -e "$dir/derived/Live" ] || fail "live-worktree DerivedData was deleted"
  [ -e "$dir/derived/Young" ] || fail "young DerivedData was deleted"
  [ -e "$dir/temp/lookalike-old-task" ] || fail "a temp cache whose workspace only ends in a project name was deleted"
  [ -e "$dir/derived/Lookalike" ] || fail "DerivedData whose workspace only ends in a project name was deleted"
  assert_contains "$out" "disk sweep:" "applied sweep did not report totals"
  assert_grep 'mode=orphan-sweep' "$dir/home/state/disk-sweep.log" "durable sweep log omitted totals"
  pass "orphan sweep is dry-run by default and enforces age, live-task, backlog, structure, pool-root workspace, slot-availability, and in-use rules"
}

# state/disk-usage.cache is this script's documented durable record: one
# `bytes<TAB>kind<TAB>label` row per attributed consumer.
usage_row_bytes() {  # <cache> <kind> <label>
  awk -F '\t' -v k="$2" -v l="$3" '$2 == k && $3 == l { print $1; found = 1 }
    END { exit found ? 0 : 1 }' "$1"
}

test_usage_cache_attributes_each_slot_to_its_own_project() {
  local dir cache app_bytes demo_bytes
  dir=$(make_case usage)
  mkdir -p "$dir/home/projects/app"
  git init -q "$dir/home/projects/demo"
  git init -q "$dir/home/projects/app"
  # Two of this home's projects share one pool root, and the first-sorted slot
  # of that root belongs to no project here.
  mkdir -p "$dir/pool/0/ghost" "$dir/pool/1/app" "$dir/pool/2/demo"
  mkdir -p "$dir/pool/0/ghost/junk"
  dd if=/dev/zero of="$dir/pool/0/ghost/junk/blob" bs=1024 count=700 2>/dev/null
  dd if=/dev/zero of="$dir/pool/1/app/blob" bs=1024 count=400 2>/dev/null
  dd if=/dev/zero of="$dir/pool/2/demo/blob" bs=1024 count=8 2>/dev/null

  FM_FAKE_SLOTS="$dir/pool/0/ghost|busy;$dir/pool/1/app|busy;$dir/pool/2/demo|busy" \
    run_sweep "$dir" --apply >/dev/null 2>&1

  cache="$dir/home/state/disk-usage.cache"
  [ -f "$cache" ] || fail "the sweep published no consumer attribution record"
  app_bytes=$(usage_row_bytes "$cache" treehouse app) \
    || fail "no treehouse row for app: $(cat "$cache")"
  demo_bytes=$(usage_row_bytes "$cache" treehouse demo) \
    || fail "a project sharing a pool root was dropped from the record: $(cat "$cache")"
  usage_row_bytes "$cache" treehouse ghost >/dev/null \
    && fail "a slot belonging to no project here was attributed to this home"
  [ "$app_bytes" -gt $((300 * 1024)) ] \
    || fail "app's slot was not sized on its own: $app_bytes"
  [ "$demo_bytes" -lt $((200 * 1024)) ] \
    || fail "demo's row carried a sibling slot's bytes: $demo_bytes"
  [ "$app_bytes" -lt $((700 * 1024)) ] \
    || fail "app's row carried the whole pool root's bytes: $app_bytes"
  pass "each Treehouse slot is sized and attributed to its own project"
}

# state/disk-usage.cache is this script's documented durable record, and the
# low-disk warning is its only consumer.
test_usage_cache_never_publishes_unfinished_probes() {
  local dir cache out slots
  dir=$(make_case usagepartial)
  mkdir -p "$dir/home/projects/app"
  git init -q "$dir/home/projects/demo"
  git init -q "$dir/home/projects/app"
  mkdir -p "$dir/pool/1/app" "$dir/pool/2/demo"
  dd if=/dev/zero of="$dir/pool/1/app/blob" bs=1024 count=400 2>/dev/null
  dd if=/dev/zero of="$dir/pool/2/demo/blob" bs=1024 count=400 2>/dev/null
  slots="$dir/pool/1/app|busy;$dir/pool/2/demo|busy"
  cache="$dir/home/state/disk-usage.cache"

  FM_FAKE_SLOTS="$slots" run_sweep "$dir" --apply >/dev/null 2>&1
  usage_row_bytes "$cache" treehouse app >/dev/null \
    || fail "a complete refresh published no row for app: $(cat "$cache")"
  usage_row_bytes "$cache" treehouse demo >/dev/null \
    || fail "a complete refresh published no row for demo: $(cat "$cache")"
  grep -Fxq '#partial' "$cache" && fail "a complete refresh marked its record partial"

  # Every size probe outruns its bound: this refresh knows nothing, so it must
  # not replace the record the complete refresh published.
  cat > "$dir/fakebin/du" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$dir/fakebin/du"
  FM_FAKE_SLOTS="$slots" run_sweep "$dir" --apply >/dev/null 2>&1
  usage_row_bytes "$cache" treehouse app >/dev/null \
    || fail "a refresh whose probes all failed erased the last good record: $(cat "$cache")"
  grep -Fxq '#partial' "$cache" \
    && fail "a discarded refresh marked the surviving good record partial"

  # One probe finishes and one does not: the surviving row is published, and
  # the record says so rather than presenting itself as the whole picture.
  cat > "$dir/fakebin/du" <<SH
#!/usr/bin/env bash
case "\$*" in *"$dir/pool/1/app"*) exit 124 ;; esac
exec /usr/bin/du "\$@"
SH
  chmod +x "$dir/fakebin/du"
  FM_FAKE_SLOTS="$slots" run_sweep "$dir" --apply >/dev/null 2>&1
  usage_row_bytes "$cache" treehouse demo >/dev/null \
    || fail "a partial refresh dropped a row whose probe did finish: $(cat "$cache")"
  usage_row_bytes "$cache" treehouse app >/dev/null \
    && fail "a row whose probe could not finish was published with a measured size"

  out=$(FM_FAKE_FREE_KIB=$((15 * 1024 * 1024)) run_sweep "$dir" --check --watcher 2>&1)
  assert_contains "$out" "Top attributed consumers for this home (partial" \
    "the low-disk warning presented a partial attribution as the whole picture"
  pass "the consumer record is never published from unfinished probes and says when it is partial"
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
test_secondmate_cleanup_without_a_worktree
test_cleanup_after_the_home_is_retired_writes_nothing_back
test_unmeasurable_size_is_not_reported_as_zero
test_orphan_sweep_rules_and_default_dry_run
test_usage_cache_attributes_each_slot_to_its_own_project
test_usage_cache_never_publishes_unfinished_probes
test_low_disk_thresholds
test_watcher_wakes_once_and_collects_detached_sweep
