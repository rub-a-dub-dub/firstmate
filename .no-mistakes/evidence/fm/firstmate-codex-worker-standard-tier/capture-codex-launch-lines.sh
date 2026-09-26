#!/usr/bin/env bash
# Evidence capture: print the literal command line Firstmate types into a worker
# pane for each Codex launch path, plus a Claude launch as the control.
# Uses the repository's own spawn fixtures and their fake tmux, which records the
# exact `tmux send-keys -l` payload without starting a real harness.
set -u
ROOT_WT=${1:?worktree}
# shellcheck source=/dev/null
. "$ROOT_WT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-evidence-codex-tier)

new_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"; HOME_DIR="$CASE_DIR/home"; PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"; LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" gh gh-axi pi cursor-agent)
  cat > "$FAKEBIN_DIR/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$FAKEBIN_DIR/timeout"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

spawn() {
  : > "$LAUNCH_LOG"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" >/dev/null 2>&1
}

show() { printf '%s\n  %s\n\n' "$1" "$(cat "$LAUNCH_LOG")"; }

id=ev-codex-ship
new_case ev-codex-ship codex "$id"
spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --model gpt-5 --effort high
show '[1] codex ship worker (profile: model gpt-5, effort high):'

id=ev-codex-plain
new_case ev-codex-plain codex "$id"
spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off
show '[2] codex ship worker (no model/effort tokens; Codex default model):'

id=ev-codex-scout
new_case ev-codex-scout codex "$id"
spawn "$id" "$PROJ_DIR" --scout
show '[3] codex scout:'

id=ev-codex-sm
new_case ev-codex-sm codex "$id"
sm="$CASE_DIR/secondmate-home"
mkdir -p "$sm/bin" "$sm/data"
printf '# Firstmate\n' > "$sm/AGENTS.md"
printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
spawn "$id" "$sm" --secondmate
show '[4] codex secondmate:'

id=ev-claude-ship
new_case ev-claude-ship claude "$id"
spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --model sonnet --effort high
show '[5] control - claude ship worker (must carry no service-tier override):'
