#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-29 report, using the real ids from it.
#
#   scout            cowork-awaiting-verify-burndown
#   captain call     cowork-awaiting-verify-burndown-resolution-schema
#
# The captain answered the call and it was closed; Done-history retention then
# pruned the answered row out of data/backlog.md into the Done archive. The
# operator then tries to clean the finished scout up:
#
#   bin/fm-captain-hold.sh complete cowork-awaiting-verify-burndown --none
#   bin/fm-teardown.sh     cowork-awaiting-verify-burndown
#
# Usage: reproduce-pruned-captain-call.sh <firstmate-root> <home-dir>
set -u
ROOT=$1
HOME_DIR=$2
TASKS_AXI=$(command -v tasks-axi)

id=cowork-awaiting-verify-burndown
call=cowork-awaiting-verify-burndown-resolution-schema

rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"/{data,state,config,projects,fakebin} "$HOME_DIR/data/$id"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/fakebin/$t"
  chmod +x "$HOME_DIR/fakebin/$t"
done
cat > "$HOME_DIR/state/$id.meta" <<META
window=firstmate:fm-$id
worktree=$HOME_DIR/projects/missing-$id
project=$HOME_DIR/projects/cowork
harness=codex
kind=scout
mode=scout
spawn_gen=fixture-$id
META
printf 'done: report complete\n' > "$HOME_DIR/state/$id.status"
printf '# Awaiting-verify burndown\n\nOne captain choice remains.\n' > "$HOME_DIR/data/$id/report.md"

captain() {
  PATH="$HOME_DIR/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}
teardown() {
  PATH="$HOME_DIR/fakebin:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$@"
}
axi() { (cd "$HOME_DIR" && tasks-axi "$@"); }

step() { printf '\n$ %s\n' "$*"; }

# --- build the history the report describes ---------------------------------
axi add "$id" "Burn down awaiting-verify" --kind scout --repo cowork --start >/dev/null
captain hold "$call" --title "Choose the resolution schema" \
  --reason "captain choice pending" --repo cowork --origin "$id" >/dev/null
captain complete "$id" "$call" >/dev/null
printf 'Use the two-field resolution schema.\n' > "$HOME_DIR/decision.txt"
captain answer "$call" --decision-file "$HOME_DIR/decision.txt" >/dev/null

printf -- '--- data/backlog.md Done section, before retention pruning ---\n'
sed -n '/^## Done/,$p' "$HOME_DIR/data/backlog.md"

step "tasks-axi prune --keep 0 --state done   # Done-history retention"
axi prune --keep 0 --state done

printf -- '\n--- data/backlog.md Done section, after retention pruning ---\n'
sed -n '/^## Done/,$p' "$HOME_DIR/data/backlog.md"
printf -- '\n--- data/done-archive.md ---\n'
cat "$HOME_DIR/data/done-archive.md"

# --- the two commands the report says refuse --------------------------------
step "bin/fm-captain-hold.sh complete $id --none"
captain complete "$id" --none; printf '[exit %s]\n' "$?"

step "bin/fm-teardown.sh $id"
teardown "$id"; printf '[exit %s]\n' "$?"

step "ls state/$id.meta   # scout still registered?"
ls "$HOME_DIR/state/$id.meta" 2>&1 || printf 'state/%s.meta is gone - the scout was torn down\n' "$id"
