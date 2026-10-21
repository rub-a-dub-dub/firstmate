#!/usr/bin/env bash
# Reenacts the 2026-10-21 full-disk incident shape against the real scripts on
# this branch and records what the captain would see.
#
# Real: bin/fm-disk-sweep.sh, bin/fm-watch.sh, du, lsof, ps, plutil, git.
# Stubbed: df (free space is dictated), treehouse (slot states are dictated).
# Sizes are scaled down from the incident (MiB, not GiB) so the fixture fits.
set -u

REPO=/Users/crossbow/.no-mistakes/worktrees/00644a303d6a/01M5EGJB9C0BXD17T0AWVKN35A
SWEEP="$REPO/bin/fm-disk-sweep.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-disk-incident.XXXXXX")
# Xcode records a resolved WorkspacePath, so the fixture speaks the same
# canonical paths the real caches would carry.
FIX=$(cd "$FIX" && pwd -P)
trap 'rm -rf "$FIX"' EXIT

HOME_DIR="$FIX/home"
mkdir -p "$HOME_DIR"/{state,data,config} "$HOME_DIR/projects/hattie" \
  "$FIX/temp" "$FIX/derived" "$FIX/fakebin"
git init -q "$HOME_DIR/projects/hattie"

cat > "$FIX/fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk3s5 1932735283 1 %s 99%% /\n' "${FM_FAKE_FREE_KIB:-50000000}"
SH
cat > "$FIX/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '['; sep=''
  IFS=';' read -r -a slots <<< "${FM_FAKE_SLOTS:-}"
  for slot in "${slots[@]}"; do
    [ -n "$slot" ] || continue
    printf '%s{"name":"s","path":"%s","status":"%s","processes":[]}' \
      "$sep" "${slot%%|*}" "${slot#*|}"
    sep=','
  done
  printf ']\n'; exit 0
fi
exit 1
SH
chmod +x "$FIX/fakebin/df" "$FIX/fakebin/treehouse"

blob() { mkdir -p "$(dirname "$2")"; dd if=/dev/zero of="$2" bs=1048576 count="$1" 2>/dev/null; }
plist() {  # <entry> <workspace>
  mkdir -p "$1"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist><dict><key>WorkspacePath</key>' \
    "<string>$2</string></dict></plist>" > "$1/info.plist"
}
cache() {  # <dir> <workspace> <mib>
  mkdir -p "$1/Build"; plist "$1" "$2"; blob "$3" "$1/Build/objects.o"
}
old() { touch -t 202001010000 "$1"; }

# Seven Hattie worktree slots in one Treehouse pool, each with its own global
# Xcode DerivedData entry, as on the captain's Mac.
SLOTS=
for n in 1 2 3 4 5 6 7; do
  mkdir -p "$FIX/pool/$n/hattie/Hattie.xcodeproj"
  git init -q "$FIX/pool/$n/hattie"
  blob 32 "$FIX/pool/$n/hattie/.build/blob"
  cache "$FIX/derived/Hattie-slot$n" "$FIX/pool/$n/hattie/Hattie.xcodeproj" 64
  old "$FIX/derived/Hattie-slot$n"
done
# Slot states Treehouse reports: 2-4 returned (available), 1/6/7 still held.
SLOTS="$FIX/pool/1/hattie|busy;$FIX/pool/2/hattie|available;$FIX/pool/3/hattie|available"
SLOTS="$SLOTS;$FIX/pool/4/hattie|available;$FIX/pool/6/hattie|busy;$FIX/pool/7/hattie|busy"
# Slot 5 was destroyed with its pool entry; its caches outlived it.
rm -rf "$FIX/pool/5"

# Task records: six finished, one still in flight on slot 7.
for n in 1 2 3 4 5 6; do printf 'done [at=1]: landed\n' > "$HOME_DIR/state/hattie-ship-$n.status"; done
printf 'working [at=1]: building\n' > "$HOME_DIR/state/hattie-ship-7.status"
printf 'worktree=%s\n' "$FIX/pool/7/hattie" > "$HOME_DIR/state/hattie-ship-7.meta"

# Per-attempt build folders under the shared temp volume.
for a in 1 2 3; do
  cache "$FIX/temp/hattie-ship-1-attempt-$a" "$FIX/pool/1/hattie/Hattie.xcodeproj" 128
done
mkdir -p "$FIX/temp/fm-hattie-ship-1/gotmp"
blob 32 "$FIX/temp/fm-hattie-ship-1/gotmp/build-artifact"
cache "$FIX/temp/hattie-ship-5-attempt-1" "$FIX/pool/5/hattie/Hattie.xcodeproj" 128
old "$FIX/temp/hattie-ship-5-attempt-1"
cache "$FIX/temp/hattie-ship-7-attempt-1" "$FIX/pool/7/hattie/Hattie.xcodeproj" 128
old "$FIX/temp/hattie-ship-7-attempt-1"
cache "$FIX/temp/other-home-attempt-1" "$FIX/elsewhere/Other.xcodeproj" 64
old "$FIX/temp/other-home-attempt-1"
# A simulator runtime: 128 GB of these were removed by hand in the incident,
# and this cleanup must never touch them.
mkdir -p "$FIX/temp/CoreSimulator/Runtimes/iOS-18.0.simruntime"
blob 48 "$FIX/temp/CoreSimulator/Runtimes/iOS-18.0.simruntime/runtime.dmg"
old "$FIX/temp/CoreSimulator/Runtimes/iOS-18.0.simruntime"
cache "$FIX/derived/OtherApp" "$FIX/elsewhere/Other.xcodeproj" 64
old "$FIX/derived/OtherApp"

run() {  # <args...>; the script as the fleet invokes it
  PATH="$FIX/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_SLOTS="$SLOTS" \
    FM_DISK_TEMP_ROOTS="$FIX/temp" FM_DISK_DERIVED_DATA_ROOT="$FIX/derived" \
    FM_DISK_SCAN_TIMEOUT=120 FM_FAKE_FREE_KIB="${FM_FAKE_FREE_KIB:-50000000}" \
    "$SWEEP" "$@" 2>&1
}
hr() { printf '\n======== %s ========\n\n' "$1"; }
show() {  # <label> <path...>
  local label=$1; shift
  for p in "$@"; do
    if [ -e "$p" ]; then printf '  present  %s\n' "${p#"$FIX"/}"
    else printf '  GONE     %s\n' "${p#"$FIX"/}"; fi
  done
}
used_mib() { du -sm "$FIX" | awk '{print $1}'; }

printf 'fm-disk-sweep end-to-end reenactment of the 2026-10-21 full-disk incident\n'
printf 'fixture: %s\nbranch commit: %s\n' "$FIX" "$(git -C "$REPO" rev-parse --short HEAD)"
BEFORE_MIB=$(used_mib)
printf 'fixture size before any cleanup: %s MiB\n' "$BEFORE_MIB"

hr '1. the nightly periodic sweep, dry run (default mode, nothing is deleted)'
run

hr '2. the disk falls to 2 GiB free: what the captain is shown'
printf '$ fm-disk-sweep.sh --check --watcher   # the watcher every 5 min; session start prints the same under DISK SPACE\n\n'
FM_FAKE_FREE_KIB=$((2 * 1024 * 1024)) run --check --watcher

hr '3. the same low-disk condition reaching the firstmate through the real watcher'
rm -f "$HOME_DIR/state/.disk-space-critical-woke"
: > "$FIX/watch.out"
PATH="$FIX/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_FAKE_SLOTS="$SLOTS" FM_FAKE_FREE_KIB=$((2 * 1024 * 1024)) \
  FM_DISK_TEMP_ROOTS="$FIX/temp" FM_DISK_DERIVED_DATA_ROOT="$FIX/derived" \
  FM_DISK_SWEEP_INTERVAL=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  "$REPO/bin/fm-watch.sh" > "$FIX/watch.out" 2>&1 &
wpid=$!
i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
printf '$ fm-watch.sh   (watcher stdout)\n'
grep -E 'disk' "$FIX/watch.out" | sed 's/^/  /'
printf '\ndurable wake queue (state/.wake-queue):\n'
sed 's/^/  /' "$HOME_DIR/state/.wake-queue" 2>/dev/null || printf '  (none)\n'

hr '4. teardown of landed task hattie-ship-1 (exactly as bin/fm-teardown.sh delegates it)'
printf '$ FM_DISK_TASK_TMP=temp/fm-hattie-ship-1 fm-disk-sweep.sh --cleanup-task hattie-ship-1 pool/1/hattie\n\n'
FM_DISK_TASK_TMP="$FIX/temp/fm-hattie-ship-1" run --cleanup-task hattie-ship-1 "$FIX/pool/1/hattie"
printf '\nthis task'"'"'s caches:\n'
show x "$FIX/temp/hattie-ship-1-attempt-1" "$FIX/temp/hattie-ship-1-attempt-2" \
  "$FIX/temp/hattie-ship-1-attempt-3" "$FIX/temp/fm-hattie-ship-1" "$FIX/derived/Hattie-slot1"
printf '\nits worktree is untouched:\n'
show x "$FIX/pool/1/hattie/.build/blob" "$FIX/pool/1/hattie/Hattie.xcodeproj"

hr '5. the periodic sweep, applied'
printf '$ fm-disk-sweep.sh --apply\n\n'
run --apply

hr '6. what the sweep kept'
printf 'in flight on slot 7, so untouchable:\n'
show x "$FIX/temp/hattie-ship-7-attempt-1" "$FIX/derived/Hattie-slot7"
printf '\nslot Treehouse still reports busy:\n'
show x "$FIX/derived/Hattie-slot6"
printf '\nnot this home'"'"'s work:\n'
show x "$FIX/temp/other-home-attempt-1" "$FIX/derived/OtherApp"
printf '\nsimulator runtime (never a candidate here):\n'
show x "$FIX/temp/CoreSimulator/Runtimes/iOS-18.0.simruntime"
printf '\nreturned slots 2-4 and the destroyed slot 5:\n'
show x "$FIX/derived/Hattie-slot2" "$FIX/derived/Hattie-slot3" "$FIX/derived/Hattie-slot4" \
  "$FIX/derived/Hattie-slot5" "$FIX/temp/hattie-ship-5-attempt-1"
printf '\nthe Treehouse pool slots themselves are never deleted here:\n'
show x "$FIX/pool/2/hattie" "$FIX/pool/7/hattie"

hr '7. durable records and the space actually reclaimed'
printf 'fixture size after cleanup: %s MiB (was %s MiB at the top of this run)\n\n' \
  "$(used_mib)" "$BEFORE_MIB"
printf 'state/disk-sweep.log:\n'
sed 's/^/  /' "$HOME_DIR/state/disk-sweep.log"
printf '\nstate/disk-usage.cache (bytes<TAB>kind<TAB>label):\n'
sed 's/^/  /' "$HOME_DIR/state/disk-usage.cache"

hr '8. the warning the captain sees once space recovers'
FM_FAKE_FREE_KIB=$((60 * 1024 * 1024)) run --check --watcher
printf '(silent - above the 20 GiB warning threshold)\n'
