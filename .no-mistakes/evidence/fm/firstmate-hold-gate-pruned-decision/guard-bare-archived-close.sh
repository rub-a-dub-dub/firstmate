#!/usr/bin/env bash
# The closed-safe counterpart to the fix: a Done row that reached the archive
# WITHOUT a recorded captain answer must keep refusing, and an archived answer
# belonging to an earlier incarnation of a re-used call id must not answer for a
# later bare close of the same id.
#
# Usage: guard-bare-archived-close.sh <firstmate-root> <home-dir>
set -u
ROOT=$1
HOME_DIR=$2
TASKS_AXI=$(command -v tasks-axi)

rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"/{data,state,config,projects,fakebin}
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/fakebin/$t"
  chmod +x "$HOME_DIR/fakebin/$t"
done

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
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$@" 2>&1 \
    | grep -v '^●'
  return "${PIPESTATUS[0]}"
}
axi() { (cd "$HOME_DIR" && tasks-axi "$@"); }
step() { printf '\n$ %s\n' "$*"; }

scout() {  # <id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  axi add "$id" "Investigate $id" --kind scout --repo cowork --start >/dev/null
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
  printf '# %s\n\nOne captain choice remains.\n' "$id" > "$HOME_DIR/data/$id/report.md"
}

printf '=== Case A: the archived row was closed out of band, never answered ===\n'
a=cowork-bare-close-scout
acall=cowork-bare-close-call
scout "$a"
captain hold "$acall" --title "Choose the route" --reason "captain choice pending" \
  --repo cowork --origin "$a" >/dev/null
captain complete "$a" "$acall" >/dev/null
axi done "$acall" >/dev/null                 # closed with no recorded answer
axi prune --keep 0 --state done >/dev/null   # retention prunes it into the archive
printf -- '\n--- data/done-archive.md (no resolution record) ---\n'
cat "$HOME_DIR/data/done-archive.md"
step "bin/fm-captain-hold.sh complete $a --none"
captain complete "$a" --none; printf '[exit %s]\n' "$?"
step "bin/fm-teardown.sh $a"
teardown "$a"; printf '[exit %s]\n' "$?"
step "ls state/$a.meta"
ls "$HOME_DIR/state/$a.meta" 2>&1

printf '\n\n=== Case B: one call id archived twice - answered first, closed bare second ===\n'
b1=cowork-reused-first-scout
b2=cowork-reused-second-scout
bcall=cowork-reused-call
scout "$b1"
captain hold "$bcall" --title "Choose the route" --reason "captain choice pending" \
  --repo cowork --origin "$b1" >/dev/null
captain complete "$b1" "$bcall" >/dev/null
printf 'Take the north route.\n' > "$HOME_DIR/decision.txt"
captain answer "$bcall" --decision-file "$HOME_DIR/decision.txt" >/dev/null
axi prune --keep 0 --state done >/dev/null
scout "$b2"
captain hold "$bcall" --title "Choose the route" --reason "captain choice pending" \
  --repo cowork --origin "$b2" >/dev/null
captain complete "$b2" "$bcall" >/dev/null
axi done "$bcall" >/dev/null                 # second incarnation closed bare
axi prune --keep 0 --state done >/dev/null
printf -- '\n--- archived rows for %s ---\n' "$bcall"
grep -c -F -- "- [x] $bcall - " "$HOME_DIR/data/done-archive.md" \
  | xargs printf 'rows: %s\n'
grep -n -F -- "- [x] $bcall - " "$HOME_DIR/data/done-archive.md"
grep -n -F -- "Resolution mode: answered" "$HOME_DIR/data/done-archive.md"
step "bin/fm-captain-hold.sh complete $b2 --none"
captain complete "$b2" --none; printf '[exit %s]\n' "$?"
step "bin/fm-teardown.sh $b2"
teardown "$b2"; printf '[exit %s]\n' "$?"
step "ls state/$b2.meta"
ls "$HOME_DIR/state/$b2.meta" 2>&1
