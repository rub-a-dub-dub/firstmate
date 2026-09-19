#!/usr/bin/env bash
# End-to-end demo of the never-asked-vs-declined fix, driven through the real
# bin/fm-spawn.sh claude launch path (tmux and claude are the suite's standard
# fakes, so the launch command itself is what a worker pane would receive).
#
# usage: never-asked-spawn-demo.sh <repo-tree> <label>
set -u
TREE=$1
LABEL=$2
# fm-spawn creates a per-task temp root /tmp/fm-<id> that outlives the run, so
# every scenario gets a run-unique task id rather than colliding with a prior
# demo's leftovers.
RUN=${3:-$$}

# shellcheck source=/dev/null
. "$TREE/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-neverasked-demo)

banner() { printf '\n=== %s ===\n' "$1"; }

show_store() {  # <store> <key>
  node -e '
    const fs=require("node:fs");
    const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const e=(j.projects||{})[process.argv[2]];
    console.log(JSON.stringify(e===undefined?"(no entry)":e));
  ' "$1" "$2"
}

scenario() {  # <name> <headline> <project-entry-json>
  local name=$1 headline=$2 entry=$3 id
  local case_dir home proj wt config fakebin out rc
  id="$name-$RUN"
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  config="$case_dir/claude-config"
  mkdir -p "$config"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "finish the stranded task"
  printf '{"hasCompletedOnboarding":true,"projects":{"%s":%s}}\n' "$proj" "$entry" \
    > "$config/.claude.json"

  banner "$LABEL | $headline"
  printf 'captain$ cat ~/.claude.json  # project entry for %s\n' "$(basename "$proj")"
  printf '  %s\n' "$(show_store "$config/.claude.json" "$proj")"
  printf 'captain$ fm spawn %s --harness claude   # launch a Claude worker on the task\n' "$name"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  printf '  [exit %s]\n' "$rc"
  if [ -s "$case_dir/launch.log" ]; then
    printf 'worker pane received:\n'
    sed 's/^/  /' "$case_dir/launch.log"
  else
    printf 'worker pane received: (nothing - no worker was launched)\n'
  fi
  rm -rf "/tmp/fm-$id"
  printf 'project entry after the spawn:\n  %s\n' "$(show_store "$config/.claude.json" "$proj")"
  printf 'worktree entry after the spawn:\n  %s\n' "$(show_store "$config/.claude.json" "$wt")"
}

scenario never-asked \
  'project NEVER ASKED about external imports (approved=false, warningShown=false)' \
  '{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":false,"allowedTools":["Read"]}'

scenario never-asked-absent \
  'project NEVER ASKED, warningShown flag absent entirely' \
  '{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false}'

scenario declined \
  'captain GENUINELY DECLINED the import dialog (approved=false, warningShown=true)' \
  '{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":true}'

scenario approved \
  'captain previously ANSWERED YES to the import dialog' \
  '{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":true,"hasClaudeMdExternalIncludesWarningShown":true}'
