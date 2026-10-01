#!/usr/bin/env bash
# Manual end-to-end reproduction of the reported bug:
#   a scout's captain call is answered, closed, then pruned out of the active
#   backlog by Done-history retention; the scout can no longer be completed or
#   torn down.
#
# Usage: repro-pruned-answered-call.sh <repo-root> <label>
# Drives the real CLIs (bin/fm-captain-hold.sh, bin/fm-teardown.sh) against a
# throwaway home, printing each operator command and its real output.
set -u
umask 022
REPO=$1
LABEL=$2
unset FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND 2>/dev/null || true
export FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-repro.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT

ORIGIN=cowork-awaiting-verify-burndown
CALL=cowork-awaiting-verify-burndown-resolution-schema

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" \
  "$HOME_DIR/fakebin" "$HOME_DIR/data/$ORIGIN"
cp "$REPO/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
MD
for tool in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/fakebin/$tool"
  chmod +x "$HOME_DIR/fakebin/$tool"
done
cat > "$HOME_DIR/state/$ORIGIN.meta" <<MD
window=firstmate:fm-$ORIGIN
worktree=$HOME_DIR/projects/missing-$ORIGIN
project=$HOME_DIR/projects/sample
harness=codex
kind=scout
mode=scout
spawn_gen=fixture-$ORIGIN
MD
printf 'done: report complete\n' > "$HOME_DIR/state/$ORIGIN.status"
printf '# Burndown review\n\nOne captain choice remains.\n' > "$HOME_DIR/data/$ORIGIN/report.md"
printf 'Use the staged resolution schema.\n' > "$HOME_DIR/captain-answer.txt"

tasks() { (cd "$HOME_DIR" && PATH="$HOME_DIR/fakebin:$PATH" tasks-axi "$@"); }
captain() {
  PATH="$HOME_DIR/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$REPO/bin/fm-captain-hold.sh" "$@"
}
teardown() {
  PATH="$HOME_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$REPO" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$REPO/bin/fm-teardown.sh" "$@"
}

say() { printf '\n$ %s\n' "$*"; }

printf '=== %s (repo: %s) ===\n' "$LABEL" "$(cd "$REPO" && git rev-parse --short HEAD)"

say "tasks-axi add $ORIGIN 'Burn down the awaiting-verify queue' --kind scout --repo sample --start"
tasks add "$ORIGIN" "Burn down the awaiting-verify queue" --kind scout --repo sample --start >/dev/null \
  && echo "ok: scout row created"

say "bin/fm-captain-hold.sh hold $CALL --origin $ORIGIN ..."
captain hold "$CALL" --title "Pick the resolution schema" \
  --reason "captain choice pending" --repo sample --origin "$ORIGIN" >/dev/null \
  && echo "ok: captain call held"

say "bin/fm-captain-hold.sh complete $ORIGIN $CALL"
captain complete "$ORIGIN" "$CALL"

say "bin/fm-captain-hold.sh answer $CALL --decision-file captain-answer.txt"
captain answer "$CALL" --decision-file "$HOME_DIR/captain-answer.txt"

say "tasks-axi prune --keep 0 --state done        # Done-history retention"
tasks prune --keep 0 --state "done" >/dev/null && echo "ok: Done history pruned"

say "grep -c '$CALL' data/backlog.md              # the answered row is gone"
grep -c -- "$CALL" "$HOME_DIR/data/backlog.md" || echo "0 (absent from the active backlog)"

say "sed -n '/- \\[x\\] $CALL/,/^$/p' data/done-archive.md   # it lives in the Done archive"
awk -v id="$CALL" '
  index($0, "- [x] " id " - ") == 1 { show = 1 }
  show && /^$/ { exit }
  show { print }
' "$HOME_DIR/data/done-archive.md"

printf '\n--- the two operations the bug report says refuse ---\n'
say "bin/fm-captain-hold.sh complete $ORIGIN --none"
if captain complete "$ORIGIN" --none; then
  echo "EXIT 0: completion accepted the archived answer"
else
  echo "EXIT $?: completion REFUSED"
fi

say "bin/fm-teardown.sh $ORIGIN"
if teardown "$ORIGIN"; then
  echo "EXIT 0: scout torn down"
else
  echo "EXIT $?: teardown REFUSED"
fi

say "ls state/$ORIGIN.meta  # scout metadata after teardown"
if [ -e "$HOME_DIR/state/$ORIGIN.meta" ]; then
  echo "still present: the scout could not be cleaned up"
else
  echo "removed: the finished scout is cleaned up"
fi
