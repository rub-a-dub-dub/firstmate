#!/usr/bin/env bash
# fm-disk-sweep.sh - bounded disk warnings and conservative cache cleanup.
#
# Public modes:
#   fm-disk-sweep.sh                         Dry-run the orphan sweep.
#   fm-disk-sweep.sh --apply                 Apply the orphan sweep.
#   fm-disk-sweep.sh --check [--watcher]     Print only a low-disk warning.
#   fm-disk-sweep.sh --cleanup-task <id> <worktree> <project>
#                                             Remove one landed task's caches.
#
# The orphan sweep removes only two categories:
#   - structurally recognized task-named Xcode caches below the configured
#     system temporary roots, older than 24 hours, whose task is known to this
#     home but is no longer live; and
#   - Xcode DerivedData entries older than seven days whose WorkspacePath is
#     attributable to a project in this home and is missing or is a Treehouse
#     slot that Treehouse reports available.
# It is a dry run unless --apply is present.
#
# Task cleanup is called only after fm-teardown.sh's landed-work gates and
# process reap. It removes recognized task-named temp caches, the exact recorded
# task temp root, this home's per-launch temp namespace, DerivedData whose
# WorkspacePath lies inside the returned worktree, and worktree-relative globs
# explicitly opted in through config/idle-slot-clean.
#
# Safety contract:
#   - every candidate is re-proved below an allowed root immediately before rm;
#   - a task id matches a temp entry's or its parent's name only as a whole
#     token delimited by start/end or one of - _ . +; teardown skips a cache
#     also named for another live task, and the sweep requires every task id
#     the name carries to be known here and not live;
#   - symlinks, root directories, malformed globs, and candidates without
#     structural or plist provenance are skipped;
#   - lsof and ps must both complete and prove no running process has the path
#     (or anything below it) open or in its command line; a missing tool,
#     timeout, or read error skips. One whole-system lsof listing is reused for
#     at most ten seconds, because a per-tree `lsof +D` walk of a multi-GiB
#     DerivedData entry is slower than any useful bound;
#   - temp candidates require a DerivedData layout (Build/ plus info.plist),
#     whose WorkspacePath must identify the task worktree (teardown) or one of
#     this home's projects (sweep), or an .xcresult bundle layout (Data/ plus
#     Info.plist or Staging/), which carries no WorkspacePath and is attributed
#     by its task-id-bearing name alone;
#   - simulator runtimes and Treehouse pool slots are never deleted here.
#
# Local config:
#   config/disk-space-thresholds
#       Optional key/value lines `warn_gb=<positive integer>` and
#       `wake_gb=<positive integer>`. Defaults are 20 and 10; wake_gb must not
#       exceed warn_gb or both values fall back to their defaults.
#   config/idle-slot-clean
#       Optional tab-separated rows: `<project><TAB><relative-glob> [...]`.
#       Project names may contain spaces; globs may not. Absolute paths, `.`,
#       and any `..` segment are refused. No file is removed without this opt-in.
#
# Durable local records:
#   state/disk-sweep.log      One totals row per sweep or task cleanup.
#   state/disk-usage.cache    Best-effort current-home consumer attribution.
#   state/disk-space.log      Low-disk observations from --watcher checks.
#   state/.disk-space-critical-woke
#                             Throttles the critical wake to one per six hours
#                             while space stays critical; removed on recovery.
#
# Test-only path seams:
#   FM_DISK_TEMP_ROOTS         Colon-separated temporary roots.
#   FM_DISK_DERIVED_DATA_ROOT  Xcode DerivedData root.
#   FM_DISK_IN_USE_TIMEOUT     Bound for each lsof or ps listing (default 10 seconds).
#   FM_DISK_SCAN_TIMEOUT       Per-size/treehouse probe bound (default 3 seconds;
#                              the watcher's detached daily sweep raises it).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
TEMP_ROOTS=${FM_DISK_TEMP_ROOTS:-/tmp:/private/tmp}
DERIVED_ROOT=${FM_DISK_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}
IN_USE_TIMEOUT=${FM_DISK_IN_USE_TIMEOUT:-10}
SCAN_TIMEOUT=${FM_DISK_SCAN_TIMEOUT:-3}
WARN_GB=20
WAKE_GB=10
APPLY=0
WATCHER=0
MODE=sweep
TASK_ID=
TASK_WORKTREE=
TASK_PROJECT=
TASK_TMP=${FM_DISK_TASK_TMP:-}
SAFE_FREED=0
SAFE_REMOVED=0
SAFE_SKIPPED=0
SWEEP_CANDIDATES=0
AVAILABLE_WORKTREES=
ALL_WORKTREES=
KNOWN_IDS=
LIVE_IDS=
OPEN_FILES=
OPEN_FILES_AT=0
USAGE_CACHE_TMP=
USAGE_POOLS_TMP=

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

cleanup_scratch() {
  rm -f "$OPEN_FILES" "$KNOWN_IDS" "$LIVE_IDS" "$AVAILABLE_WORKTREES" "$ALL_WORKTREES" \
    "$USAGE_POOLS_TMP" "$USAGE_CACHE_TMP" "${USAGE_CACHE_TMP:+$USAGE_CACHE_TMP.sum}" \
    2>/dev/null || true
}
trap cleanup_scratch EXIT

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

case "${1:-}" in
  '') ;;
  --apply) APPLY=1; shift ;;
  --check) MODE=check; shift ;;
  --cleanup-task)
    MODE=cleanup-task
    shift
    TASK_ID=${1:-}
    TASK_WORKTREE=${2:-}
    TASK_PROJECT=${3:-}
    shift "$(( $# < 3 ? $# : 3 ))"
    ;;
  -h|--help) usage; exit 0 ;;
  *) echo "fm-disk-sweep: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
if [ "${1:-}" = --watcher ]; then WATCHER=1; shift; fi
[ "$#" -eq 0 ] || { echo "fm-disk-sweep: unexpected argument: $1" >&2; exit 2; }

case "$IN_USE_TIMEOUT" in ''|*[!0-9]*|0) IN_USE_TIMEOUT=10 ;; esac
case "$SCAN_TIMEOUT" in ''|*[!0-9]*|0) SCAN_TIMEOUT=3 ;; esac

epoch_now() { date +%s; }

real_dir() {  # <directory>
  [ -d "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

path_under() {  # <path> <root>, strict descendant
  local path=$1 root=$2
  [ -n "$path" ] && [ -n "$root" ] || return 1
  case "$path" in "$root"/*) return 0 ;; esac
  return 1
}

stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

older_than() {  # <path> <seconds>
  local mtime now age
  mtime=$(stat_mtime "$1") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(epoch_now)
  age=$((now - mtime))
  [ "$age" -ge "$2" ]
}

human_bytes() {
  awk -v n="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i=1;
    while (n >= 1024 && i < 5) { n /= 1024; i++ }
    if (i == 1) printf "%d %s", n, u[i]; else printf "%.1f %s", n, u[i]
  }'
}

size_bytes() {  # <path>, best effort and bounded
  local out rc=0
  out=$(fm_run_timed "$SCAN_TIMEOUT" du -sk "$1" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || { printf '0\n'; return 1; }
  out=${out%%[[:space:]]*}
  case "$out" in ''|*[!0-9]*) printf '0\n'; return 1 ;; esac
  printf '%s\n' "$((out * 1024))"
}

plist_workspace() {  # <entry>
  local plist value
  for plist in "$1/info.plist" "$1/Info.plist"; do
    [ -f "$plist" ] && [ ! -L "$plist" ] || continue
    if command -v plutil >/dev/null 2>&1; then
      value=$(plutil -extract WorkspacePath raw -o - "$plist" 2>/dev/null || true)
      [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    fi
    value=$(perl -0777 -ne '
      if (m{<key>\s*WorkspacePath\s*</key>\s*<string>(.*?)</string>}s) {
        $v=$1; $v =~ s/&amp;/&/g; $v =~ s/&lt;/</g; $v =~ s/&gt;/>/g;
        print $v; exit 0;
      }
    ' "$plist" 2>/dev/null || true)
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
  done
  return 1
}

recognized_xcode_cache() {  # <directory>
  local dir=$1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  case "$dir" in
    *.xcresult)
      # A finished bundle has Info.plist; one still being written has Staging/.
      [ -d "$dir/Data" ] && [ ! -L "$dir/Data" ] || return 1
      { [ -f "$dir/Info.plist" ] && [ ! -L "$dir/Info.plist" ]; } \
        || { [ -d "$dir/Staging" ] && [ ! -L "$dir/Staging" ]; }
      ;;
    *)
      [ -d "$dir/Build" ] && [ ! -L "$dir/Build" ] \
        && [ -f "$dir/info.plist" ] && [ ! -L "$dir/info.plist" ]
      ;;
  esac
}

temp_cache_candidates() {  # <real-temp-root>; prints outermost recognized caches
  local root=$1 hit dir
  # Locate cache structure directly instead of testing every temp directory.
  find "$root" -xdev -mindepth 1 -maxdepth 5 \
    \( -type d -name '*.xcresult' -print0 -prune \) -o \
    \( -type d -name Build -prune -print0 \) 2>/dev/null \
    | while IFS= read -r -d '' hit; do
        case "$hit" in *$'\n'*|*$'\r'*) continue ;; esac
        case "$hit" in */Build) dir=${hit%/Build} ;; *) dir=$hit ;; esac
        recognized_xcode_cache "$dir" && printf '%s\n' "$dir"
      done \
    | LC_ALL=C sort -u \
    | awk '{
        for (i = 1; i <= n; i++) if (index($0, kept[i] "/") == 1) next
        kept[++n] = $0; print
      }'
}

workspace_project() {  # <WorkspacePath>; prints a current-home project name
  local workspace=$1 project name root
  root=$(real_dir "$PROJECTS" 2>/dev/null || true)
  for project in "$PROJECTS"/*; do
    [ -d "$project" ] && [ ! -L "$project" ] || continue
    name=$(basename "$project")
    if [ -n "$root" ] && path_under "$workspace" "$root/$name"; then
      printf '%s\n' "$name"
      return 0
    fi
    case "$workspace" in
      */[0-9]*/"$name"|*/[0-9]*/"$name"/*)
        printf '%s\n' "$name"
        return 0
        ;;
    esac
  done
  return 1
}

cache_matches_worktree() {  # <cache> <worktree>
  local workspace
  workspace=$(plist_workspace "$1") || return 1
  path_under "$workspace" "$2"
}

command_line_uses_path() {  # <path> [alias]; 0 means in use, 1 means clean, 2 unknown
  local out rc=0
  out=$(fm_run_timed "$IN_USE_TIMEOUT" ps -axo pid=,command= 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$out" | awk -v self="$$" -v parent="$PPID" -v p="$1" -v q="${2:-$1}" '
    {
      pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if (pid != self && pid != parent && (index($0, p) != 0 || index($0, q) != 0)) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

open_files_snapshot() {  # refreshes the whole-system lsof name listing
  local now rc=0
  now=$(epoch_now)
  if [ -n "$OPEN_FILES" ] && [ -s "$OPEN_FILES" ] && [ $((now - OPEN_FILES_AT)) -lt 10 ]; then
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  if [ -z "$OPEN_FILES" ]; then
    OPEN_FILES=$(mktemp "${TMPDIR:-/tmp}/fm-disk-open.XXXXXX") || { OPEN_FILES=; return 1; }
  fi
  fm_run_timed "$IN_USE_TIMEOUT" lsof -nP -w -Fn > "$OPEN_FILES" 2>/dev/null || rc=$?
  # An empty listing proves nothing: something always has files open.
  if [ "$rc" -ne 0 ] || [ ! -s "$OPEN_FILES" ]; then
    : > "$OPEN_FILES"
    return 1
  fi
  OPEN_FILES_AT=$now
}

path_is_open() {  # <real-path>; 0 means in use, 1 means clean, 2 unknown
  open_files_snapshot || return 2
  awk -v p="$1" '
    /^n/ { name = substr($0, 2); if (name == p || index(name, p "/") == 1) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
  ' "$OPEN_FILES"
}

canonical_path() {  # <existing non-symlink path>; resolves its parent
  local base parent
  base=$(basename "$1")
  parent=$(real_dir "$(dirname "$1")") || return 1
  printf '%s/%s\n' "$parent" "$base"
}

allowed_candidate() {  # <path> <colon-separated-roots>
  local path=$1 roots=$2 resolved root root_real old_ifs
  [ -e "$path" ] && [ ! -L "$path" ] || return 1
  case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  resolved=$(canonical_path "$path") || return 1
  old_ifs=$IFS
  IFS=:
  for root in $roots; do
    [ -n "$root" ] || continue
    root_real=$(real_dir "$root" 2>/dev/null || true)
    [ -n "$root_real" ] || continue
    if path_under "$resolved" "$root_real"; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

safe_remove() {  # <path> <allowed-roots> <label>
  local path=$1 roots=$2 label=$3 bytes=0 rc real
  [ -e "$path" ] || return 0
  if ! allowed_candidate "$path" "$roots"; then
    printf 'skip unsafe path outside allowed roots: %s\n' "$path" >&2
    SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
    return 1
  fi
  # lsof reports resolved paths (/private/tmp, not /tmp), so prove against
  # the canonical spelling and match command lines under either spelling.
  real=$(canonical_path "$path") || real=$path
  if path_is_open "$real"; then
    printf 'skip in-use %s: %s\n' "$label" "$path" >&2
    SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
    return 1
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      printf 'skip unprovable-open-state %s: %s\n' "$label" "$path" >&2
      SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
      return 1
    fi
  fi
  if command_line_uses_path "$path" "$real"; then
    printf 'skip command-line-in-use %s: %s\n' "$label" "$path" >&2
    SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
    return 1
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      printf 'skip unprovable-process-state %s: %s\n' "$label" "$path" >&2
      SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
      return 1
    fi
  fi
  bytes=$(size_bytes "$path" 2>/dev/null || printf '0')
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  SWEEP_CANDIDATES=$((SWEEP_CANDIDATES + 1))
  if [ "$APPLY" -eq 0 ]; then
    printf 'would remove %s: %s (%s)\n' "$label" "$path" "$(human_bytes "$bytes")"
    return 0
  fi
  if rm -rf -- "$path"; then
    SAFE_FREED=$((SAFE_FREED + bytes))
    SAFE_REMOVED=$((SAFE_REMOVED + 1))
    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s\tmode=%s\tremoved=%s\tbytes=%s\tpath=%s\n' \
      "$(epoch_now)" "$MODE" "$label" "$bytes" "$path" >> "$STATE/disk-sweep.log" 2>/dev/null || true
    return 0
  fi
  printf 'skip removal-failed %s: %s\n' "$label" "$path" >&2
  SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
  return 1
}

load_thresholds() {
  local file="$CONFIG/disk-space-thresholds" line key value warn=20 wake=10 valid=1
  [ -f "$file" ] && [ ! -L "$file" ] || { WARN_GB=$warn; WAKE_GB=$wake; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; value=${line#*=}
    case "$key:$value" in
      warn_gb:*[!0-9]*|wake_gb:*[!0-9]*|warn_gb:|wake_gb:) valid=0 ;;
      warn_gb:*) warn=$value ;;
      wake_gb:*) wake=$value ;;
      *) valid=0 ;;
    esac
  done < "$file"
  if [ "$valid" -ne 1 ] || [ "$warn" -le 0 ] || [ "$wake" -le 0 ] || [ "$wake" -gt "$warn" ]; then
    printf 'warning: invalid %s; using warn_gb=20 and wake_gb=10\n' "$file" >&2
    warn=20; wake=10
  fi
  WARN_GB=$warn
  WAKE_GB=$wake
}

df_free_record() {  # <path> -> device<TAB>free-kib
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $1 "\t" $4 }'
}

print_cached_consumers() {
  local cache="$STATE/disk-usage.cache" line bytes kind label shown=0
  [ -f "$cache" ] && [ ! -L "$cache" ] || return 0
  while IFS=$'\t' read -r bytes kind label; do
    case "$bytes" in ''|*[!0-9]*) continue ;; esac
    [ "$bytes" -gt 0 ] || continue
    if [ "$shown" -eq 0 ]; then printf 'Top attributed consumers for this home:\n'; fi
    printf '  %s: %s (%s)\n' "$kind" "$label" "$(human_bytes "$bytes")"
    shown=$((shown + 1))
    [ "$shown" -lt 5 ] || break
  done < <(awk -F '\t' 'NF == 3 && $1 ~ /^[0-9]+$/ { print }' "$cache" | sort -t $'\t' -k1,1nr)
}

shell_quote() { printf '%q' "$1"; }

check_space() {
  local seen_devices='' record device free_kib free_bytes warn_bytes wake_bytes path label low=0 critical=0
  load_thresholds
  warn_bytes=$((WARN_GB * 1024 * 1024 * 1024))
  wake_bytes=$((WAKE_GB * 1024 * 1024 * 1024))
  for label in home temp; do
    if [ "$label" = home ]; then path=$FM_HOME; else path=${TEMP_ROOTS%%:*}; fi
    [ -d "$path" ] || continue
    record=$(df_free_record "$path") || record=
    [ -n "$record" ] || continue
    device=${record%%$'\t'*}; free_kib=${record#*$'\t'}
    case "$free_kib" in ''|*[!0-9]*) continue ;; esac
    case " $seen_devices " in *" $device "*) continue ;; esac
    seen_devices="$seen_devices $device"
    free_bytes=$((free_kib * 1024))
    if [ "$free_bytes" -lt "$warn_bytes" ]; then
      low=1
      printf 'warning: low disk on %s volume %s: %s free (warn below %s GiB; critical below %s GiB)\n' \
        "$label" "$device" "$(human_bytes "$free_bytes")" "$WARN_GB" "$WAKE_GB"
      [ "$free_bytes" -ge "$wake_bytes" ] || critical=1
    fi
  done
  if [ "$low" -eq 1 ]; then
    print_cached_consumers
    printf 'Reclaim orphaned caches safely: FM_HOME=%s %s --apply\n' \
      "$(shell_quote "$FM_HOME")" "$(shell_quote "$SCRIPT_DIR/fm-disk-sweep.sh")"
    if [ "$WATCHER" -eq 1 ]; then
      mkdir -p "$STATE" 2>/dev/null || true
      printf '%s\tlow=%s\tcritical=%s\n' "$(epoch_now)" "$low" "$critical" >> "$STATE/disk-space.log" 2>/dev/null || true
    fi
  fi
  [ "$WATCHER" -eq 1 ] || return 0
  # A persisting critical condition re-wakes at most every six hours rather
  # than on every watcher check; recovering above the threshold re-arms it.
  if [ "$critical" -eq 0 ]; then
    rm -f "$STATE/.disk-space-critical-woke" 2>/dev/null || true
  elif [ ! -e "$STATE/.disk-space-critical-woke" ] \
    || older_than "$STATE/.disk-space-critical-woke" 21600; then
    touch "$STATE/.disk-space-critical-woke" 2>/dev/null || true
    printf 'wake: disk space is below the %s GiB critical threshold for this home\n' "$WAKE_GB"
  fi
}

home_hash() {
  local root hash
  root=$(real_dir "$FM_HOME" 2>/dev/null || printf '%s' "$FM_HOME")
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s\n' "$hash"
}

unique_temp_roots() {
  local old_ifs root resolved seen=''
  old_ifs=$IFS; IFS=:
  for root in $TEMP_ROOTS; do
    resolved=$(real_dir "$root" 2>/dev/null || true)
    [ -n "$resolved" ] || continue
    case " $seen " in *" $resolved "*) continue ;; esac
    seen="$seen $resolved"
    printf '%s\n' "$resolved"
  done
  IFS=$old_ifs
}

name_has_id() {  # <name> <id>; the id must be a whole delimited token run
  case "$1" in
    "$2"|"$2"[-_.+]*|*[-_.+]"$2"|*[-_.+]"$2"[-_.+]*) return 0 ;;
  esac
  return 1
}

path_has_id() {  # <path> <id>; checks the entry and its parent directory names
  local base parent
  base=${1##*/}
  parent=${1%/*}; parent=${parent##*/}
  name_has_id "$base" "$2" || name_has_id "$parent" "$2"
}

other_live_ids() {  # <id>; this home's other live task ids
  local meta other
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    other=${meta##*/}; other=${other%.meta}
    [ "$other" = "$1" ] || printf '%s\n' "$other"
  done
}

cleanup_temp_for_task() {  # <id> <worktree>
  local id=$1 worktree=$2 root candidate hash launch other others
  others=$(other_live_ids "$id")
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    # Teardown is latency-sensitive and already knows the exact task id. Probe
    # only task-id-bearing directory names at the two layouts build tools use
    # here (a temp-root child or one attempt-group child), rather than walking
    # the whole shared temp volume on every teardown.
    while IFS= read -r candidate; do
      [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
      path_has_id "$candidate" "$id" || continue
      recognized_xcode_cache "$candidate" || continue
      # A live sibling whose id extends this one (task-a vs task-a-ui) owns
      # any cache its name also matches.
      while IFS= read -r other; do
        [ -n "$other" ] || continue
        if path_has_id "$candidate" "$other"; then
          printf 'skip cache also named for live task %s: %s\n' "$other" "$candidate" >&2
          SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
          continue 2
        fi
      done <<EOF
$others
EOF
      case "$candidate" in
        *.xcresult) ;;
        *)
          if [ -z "$worktree" ] || ! cache_matches_worktree "$candidate" "$worktree"; then
            continue
          fi
          ;;
      esac
      safe_remove "$candidate" "$TEMP_ROOTS" "task temp cache" || true
    done < <(
      compgen -G "$root/*$id*" || true
      compgen -G "$root/*/*$id*" || true
    )
  done < <(unique_temp_roots)

  if [ -n "$TASK_TMP" ]; then
    case "$TASK_TMP" in *"$id"*) safe_remove "$TASK_TMP" "$TEMP_ROOTS" "recorded task temp root" || true ;; esac
  fi
  hash=$(home_hash 2>/dev/null || true)
  if [ -n "$hash" ]; then
    while IFS= read -r root; do
      launch="$root/fm-$id+$hash"
      [ -e "$launch" ] || continue
      safe_remove "$launch" "$TEMP_ROOTS" "task launch temp root" || true
    done < <(unique_temp_roots)
  fi
}

cleanup_derived_for_task() {  # <worktree>
  local worktree=$1 entry workspace derived_real plist
  [ -n "$worktree" ] || return 0
  derived_real=$(real_dir "$DERIVED_ROOT" 2>/dev/null || true)
  [ -n "$derived_real" ] || return 0
  for entry in "$derived_real"/*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    plist="$entry/info.plist"
    [ -f "$plist" ] && [ ! -L "$plist" ] || plist="$entry/Info.plist"
    [ -f "$plist" ] && [ ! -L "$plist" ] || continue
    # The common nonmatching case stays one fixed-string grep. Parse the plist
    # only after its bytes mention this exact worktree.
    grep -Fq -- "$worktree" "$plist" 2>/dev/null || continue
    workspace=$(plist_workspace "$entry" 2>/dev/null || true)
    if [ -z "$workspace" ] || ! path_under "$workspace" "$worktree"; then
      continue
    fi
    safe_remove "$entry" "$derived_real" "task DerivedData" || true
  done
}

valid_relative_glob() {
  case "$1" in
    ''|.|/*|../*|*/../*|*/..|..) return 1 ;;
  esac
  return 0
}

cleanup_idle_slot_outputs() {  # <worktree> <project>
  local worktree=$1 project=$2 config="$CONFIG/idle-slot-clean" line name patterns pattern match
  [ -n "$worktree" ] && [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 0
  [ -f "$config" ] && [ ! -L "$config" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *$'\t'*) ;; *) printf 'skip malformed idle-slot-clean row (tab required): %s\n' "$line" >&2; SAFE_SKIPPED=$((SAFE_SKIPPED + 1)); continue ;; esac
    name=${line%%$'\t'*}; patterns=${line#*$'\t'}
    [ "$name" = "$project" ] || continue
    for pattern in $patterns; do
      if ! valid_relative_glob "$pattern"; then
        printf 'skip unsafe idle-slot glob for %s: %s\n' "$project" "$pattern" >&2
        SAFE_SKIPPED=$((SAFE_SKIPPED + 1))
        continue
      fi
      while IFS= read -r match; do
        [ -e "$match" ] || continue
        safe_remove "$match" "$worktree" "opted-in idle-slot output" || true
      done < <(compgen -G "$worktree/$pattern" || true)
    done
  done < "$config"
}

log_totals() {  # <mode>
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\tmode=%s\tapply=%s\tcandidates=%s\tremoved=%s\tskipped=%s\tfreed_bytes=%s\n' \
    "$(epoch_now)" "$1" "$APPLY" "$SWEEP_CANDIDATES" "$SAFE_REMOVED" "$SAFE_SKIPPED" "$SAFE_FREED" \
    >> "$STATE/disk-sweep.log" 2>/dev/null || true
}

cleanup_task() {
  local project_name worktree_real
  case "$TASK_ID" in ''|*[!A-Za-z0-9._-]*) echo "fm-disk-sweep: invalid task id" >&2; exit 2 ;; esac
  APPLY=1
  worktree_real=$(real_dir "$TASK_WORKTREE" 2>/dev/null || true)
  project_name=$(basename "${TASK_PROJECT:-unknown}")
  cleanup_temp_for_task "$TASK_ID" "$worktree_real"
  cleanup_derived_for_task "$worktree_real"
  cleanup_idle_slot_outputs "$worktree_real" "$project_name"
  log_totals cleanup-task
  printf 'disk cleanup %s: freed %s from %s cache path(s); skipped %s\n' \
    "$TASK_ID" "$(human_bytes "$SAFE_FREED")" "$SAFE_REMOVED" "$SAFE_SKIPPED"
}

collect_task_ids() {
  local file id
  KNOWN_IDS=$(mktemp "${TMPDIR:-/tmp}/fm-disk-known.XXXXXX") || exit 1
  LIVE_IDS=$(mktemp "${TMPDIR:-/tmp}/fm-disk-live.XXXXXX") || { rm -f "$KNOWN_IDS"; exit 1; }
  for file in "$STATE"/*.meta "$STATE"/*.status; do
    [ -f "$file" ] || continue
    id=$(basename "$file"); id=${id%.meta}; id=${id%.status}
    printf '%s\n' "$id" >> "$KNOWN_IDS"
    case "$file" in *.meta) printf '%s\n' "$id" >> "$LIVE_IDS" ;; esac
  done
  if [ -f "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ]; then
    awk '
      /^##[[:space:]]+/ {
        section=$0
        sub(/^##[[:space:]]+/, "## ", section)
        sub(/[[:space:]]+$/, "", section)
        next
      }
      /^- \[[ x]\] / {
        rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
        if (id == "") next
        print id >> known
        if (section == "## In flight") print id >> live
      }
    ' known="$KNOWN_IDS" live="$LIVE_IDS" "$DATA/backlog.md"
  fi
  LC_ALL=C sort -u "$KNOWN_IDS" -o "$KNOWN_IDS"
  LC_ALL=C sort -u "$LIVE_IDS" -o "$LIVE_IDS"
}

task_ids_for_path() {  # <path>; every current-home known id its names carry
  local path=$1 id found=1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if path_has_id "$path" "$id"; then
      printf '%s\n' "$id"
      found=0
    fi
  done < "$KNOWN_IDS"
  return "$found"
}

task_is_live() { grep -Fxq -- "$1" "$LIVE_IDS" 2>/dev/null; }

collect_available_worktrees() {
  local project json
  AVAILABLE_WORKTREES=$(mktemp "${TMPDIR:-/tmp}/fm-disk-available.XXXXXX") || exit 1
  ALL_WORKTREES=$(mktemp "${TMPDIR:-/tmp}/fm-disk-all-worktrees.XXXXXX") \
    || { rm -f "$AVAILABLE_WORKTREES"; exit 1; }
  command -v treehouse >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  for project in "$PROJECTS"/*; do
    [ -d "$project" ] && [ ! -L "$project" ] || continue
    json=$(fm_run_timed "$SCAN_TIMEOUT" bash -c 'cd "$1" 2>/dev/null && exec treehouse status --json' _ "$project" 2>/dev/null || true)
    [ -n "$json" ] || continue
    printf '%s\n' "$json" | jq -r '.[] | .path' 2>/dev/null >> "$ALL_WORKTREES" || true
    printf '%s\n' "$json" | jq -r '.[] | select(.status == "available") | .path' 2>/dev/null >> "$AVAILABLE_WORKTREES" || true
  done
  LC_ALL=C sort -u "$AVAILABLE_WORKTREES" -o "$AVAILABLE_WORKTREES"
  LC_ALL=C sort -u "$ALL_WORKTREES" -o "$ALL_WORKTREES"
}

workspace_top() {  # <WorkspacePath>
  local path=$1 dir top
  if [ -d "$path" ]; then dir=$path; else dir=$(dirname "$path"); fi
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  real_dir "$top"
}

workspace_is_orphaned() {  # <WorkspacePath>
  local workspace=$1 top
  workspace_project "$workspace" >/dev/null || return 1
  if [ ! -e "$workspace" ]; then return 0; fi
  top=$(workspace_top "$workspace" 2>/dev/null || true)
  [ -n "$top" ] || return 1
  grep -Fxq -- "$top" "$AVAILABLE_WORKTREES" 2>/dev/null
}

workspace_has_live_task() {  # <WorkspacePath>
  local workspace=$1 meta wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(sed -n 's/^worktree=//p' "$meta" | tail -n 1)
    [ -n "$wt" ] || continue
    path_under "$workspace" "$wt" && return 0
  done
  return 1
}

sweep_temp() {
  local root candidate id ids live workspace
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      older_than "$candidate" 86400 || continue
      # Every task the name could belong to must be known here and not live.
      ids=$(task_ids_for_path "$candidate" 2>/dev/null || true)
      [ -n "$ids" ] || continue
      live=0
      while IFS= read -r id; do
        task_is_live "$id" && live=1
      done <<EOF
$ids
EOF
      [ "$live" -eq 0 ] || continue
      id=$(printf '%s\n' "$ids" | awk '{ print length($0) "\t" $0 }' | sort -rn | head -n 1 | cut -f2)
      # A DerivedData layout must also record a workspace in one of this
      # home's projects; its slot may since serve another task, so slot state
      # is not consulted. A result bundle records no workspace.
      case "$candidate" in
        *.xcresult) ;;
        *)
          workspace=$(plist_workspace "$candidate" 2>/dev/null || true)
          [ -n "$workspace" ] && workspace_project "$workspace" >/dev/null || continue
          ;;
      esac
      safe_remove "$candidate" "$TEMP_ROOTS" "orphan task temp cache ($id)" || true
    done < <(temp_cache_candidates "$root")
  done < <(unique_temp_roots)
}

sweep_derived() {
  local root entry workspace
  root=$(real_dir "$DERIVED_ROOT" 2>/dev/null || true)
  [ -n "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    older_than "$entry" 604800 || continue
    workspace=$(plist_workspace "$entry" 2>/dev/null || true)
    [ -n "$workspace" ] || continue
    workspace_has_live_task "$workspace" && continue
    workspace_is_orphaned "$workspace" || continue
    safe_remove "$entry" "$root" "orphan DerivedData" || true
  done
}

cache_add() {  # <file> <bytes> <kind> <label>
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1"
}

refresh_usage_cache() {
  local tmp root candidate bytes id entry workspace project pool pools
  mkdir -p "$STATE" 2>/dev/null || return 0
  USAGE_CACHE_TMP=$(mktemp "$STATE/.disk-usage.cache.XXXXXX" 2>/dev/null) || return 0
  USAGE_POOLS_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-disk-pools.XXXXXX") \
    || { rm -f "$USAGE_CACHE_TMP"; USAGE_CACHE_TMP=; return 0; }
  tmp=$USAGE_CACHE_TMP
  pools=$USAGE_POOLS_TMP
  while IFS= read -r root; do
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      id=$(task_ids_for_path "$candidate" 2>/dev/null \
        | awk '{ print length($0) "\t" $0 }' | sort -rn | head -n 1 | cut -f2)
      [ -n "$id" ] || continue
      bytes=$(size_bytes "$candidate" 2>/dev/null || printf '0')
      cache_add "$tmp" "$bytes" temp "$id"
    done < <(temp_cache_candidates "$root")
  done < <(unique_temp_roots)
  root=$(real_dir "$DERIVED_ROOT" 2>/dev/null || true)
  if [ -n "$root" ]; then
    for entry in "$root"/*; do
      [ -d "$entry" ] && [ ! -L "$entry" ] || continue
      workspace=$(plist_workspace "$entry" 2>/dev/null || true)
      project=$(workspace_project "$workspace" 2>/dev/null || true)
      [ -n "$project" ] || continue
      bytes=$(size_bytes "$entry" 2>/dev/null || printf '0')
      cache_add "$tmp" "$bytes" DerivedData "$project"
    done
  fi
  if [ -n "$ALL_WORKTREES" ] && [ -f "$ALL_WORKTREES" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      pool=$(dirname "$(dirname "$entry")")
      grep -Fxq -- "$pool" "$pools" 2>/dev/null && continue
      printf '%s\n' "$pool" >> "$pools"
      project=$(basename "$entry")
      workspace_project "$entry" >/dev/null 2>&1 || continue
      bytes=$(size_bytes "$pool" 2>/dev/null || printf '0')
      cache_add "$tmp" "$bytes" treehouse "$project"
    done < "$ALL_WORKTREES"
  fi
  awk -F '\t' '
    NF == 3 { key=$2 FS $3; total[key]+=$1 }
    END { for (key in total) print total[key] FS key }
  ' "$tmp" | sort -t $'\t' -k1,1nr > "$tmp.sum"
  mv "$tmp.sum" "$STATE/disk-usage.cache"
  rm -f "$tmp" "$tmp.sum" "$pools"
  USAGE_CACHE_TMP=
  USAGE_POOLS_TMP=
}

free_bytes_for_home() {
  local record value
  record=$(df_free_record "$FM_HOME" 2>/dev/null || true)
  value=${record#*$'\t'}
  case "$value" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$((value * 1024))" ;; esac
}

orphan_sweep() {
  local before after warn_bytes
  mkdir -p "$STATE" "$DATA" "$CONFIG" 2>/dev/null || true
  load_thresholds
  before=$(free_bytes_for_home)
  collect_task_ids
  collect_available_worktrees
  sweep_temp
  sweep_derived
  refresh_usage_cache
  log_totals orphan-sweep
  printf 'disk sweep: %s candidate(s), removed %s, skipped %s, freed %s%s\n' \
    "$SWEEP_CANDIDATES" "$SAFE_REMOVED" "$SAFE_SKIPPED" "$(human_bytes "$SAFE_FREED")" \
    "$([ "$APPLY" -eq 1 ] && printf '' || printf ' (dry run)')"
  if [ "$WATCHER" -eq 1 ] && [ "$APPLY" -eq 1 ] && [ "$SAFE_FREED" -ge $((10 * 1024 * 1024 * 1024)) ]; then
    after=$(free_bytes_for_home)
    warn_bytes=$((WARN_GB * 1024 * 1024 * 1024))
    if [ "$before" -lt "$warn_bytes" ] && [ "$after" -lt "$warn_bytes" ]; then
      printf 'wake: disk sweep freed %s but this home remains below its %s GiB warning threshold\n' \
        "$(human_bytes "$SAFE_FREED")" "$WARN_GB"
    fi
  fi
}

case "$MODE" in
  check) check_space ;;
  cleanup-task) cleanup_task ;;
  sweep) orphan_sweep ;;
esac
