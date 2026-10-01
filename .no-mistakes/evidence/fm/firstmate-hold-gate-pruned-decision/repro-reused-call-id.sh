#!/usr/bin/env bash
# The closed-safe half of the same change: one call id archived twice - an
# earlier answered incarnation and a later bare `tasks-axi done` close. The
# archived answer must not answer for the bare close, in either archive order.
#
# Usage: repro-reused-call-id.sh <repo-root>
set -u
umask 022
REPO=$1
unset FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND 2>/dev/null || true
export FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-reused.XXXXXX")
trap 'rm -rf "$H"' EXIT
CALL=sample-reused-call
FIRST=first-incarnation-review
SECOND=second-incarnation-review

mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin" \
  "$H/data/$FIRST" "$H/data/$SECOND"
cp "$REPO/.tasks.toml" "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"
done
meta() {
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=fixture-%s\n' \
    "$1" "$H" "$1" "$H" "$1" > "$H/state/$1.meta"
  printf 'done: report complete\n' > "$H/state/$1.status"
  printf '# %s\n\nOne captain choice remains.\n' "$1" > "$H/data/$1/report.md"
}
tasks() { (cd "$H" && PATH="$H/fakebin:$PATH" tasks-axi "$@"); }
captain() {
  PATH="$H/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$H" \
    FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    FM_CONFIG_OVERRIDE="$H/config" "$REPO/bin/fm-captain-hold.sh" "$@"
}
teardown() {
  PATH="$H/fakebin:$PATH" FM_ROOT_OVERRIDE="$REPO" FM_HOME="$H" \
    FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    FM_CONFIG_OVERRIDE="$H/config" "$REPO/bin/fm-teardown.sh" "$@"
}
say() { printf '\n$ %s\n' "$*"; }

printf '=== reused archived call id (repo: %s) ===\n' "$(cd "$REPO" && git rev-parse --short HEAD)"

meta "$FIRST"; meta "$SECOND"
tasks add "$FIRST" "First incarnation" --kind scout --repo sample --start >/dev/null
tasks add "$SECOND" "Second incarnation" --kind scout --repo sample --start >/dev/null
printf 'Choose the archived route.\n' > "$H/answer.txt"

say "fm-captain-hold.sh hold $CALL --origin $FIRST   # first incarnation"
captain hold "$CALL" --title "Choose the reused route" --reason "captain choice pending" \
  --repo sample --origin "$FIRST" >/dev/null && echo "ok: held"
captain complete "$FIRST" "$CALL" >/dev/null && echo "ok: inventory attested"
say "fm-captain-hold.sh answer $CALL --decision-file answer.txt   # captain answers it"
captain answer "$CALL" --decision-file "$H/answer.txt"
tasks prune --keep 0 --state "done" >/dev/null && echo "ok: answered row pruned into the archive"

say "fm-captain-hold.sh hold $CALL --origin $SECOND  # the id is re-used later"
captain hold "$CALL" --title "Choose the reused route" --reason "captain choice pending" \
  --repo sample --origin "$SECOND" >/dev/null && echo "ok: re-held"
captain complete "$SECOND" "$CALL" >/dev/null && echo "ok: inventory attested"
say "tasks-axi done $CALL            # closed out of band, no captain answer"
tasks "done" "$CALL" >/dev/null && echo "ok: bare close"
tasks prune --keep 0 --state "done" >/dev/null && echo "ok: bare close pruned into the archive"

say "grep -c -- '- [x] $CALL - ' data/done-archive.md   # both incarnations archived"
grep -c -F -- "- [x] $CALL - " "$H/data/done-archive.md"

printf '\n--- the gate must still refuse the second scout ---\n'
say "fm-captain-hold.sh complete $SECOND --none"
if captain complete "$SECOND" --none; then
  echo "EXIT 0: ACCEPTED (an earlier answer spoke for a bare close)"
else
  echo "EXIT $?: refused"
fi
say "bin/fm-teardown.sh $SECOND"
if teardown "$SECOND" 2>&1 | grep -v '^●'; then :; fi
[ -e "$H/state/$SECOND.meta" ] \
  && echo "scout metadata still present: the unanswered call was not discarded" \
  || echo "scout metadata removed"

printf '\n--- same two rows, archive order reversed ---\n'
python3 - "$H/data/done-archive.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
blocks, head, cur = [], [], None
for ln in lines:
    if ln.startswith('- [x] '):
        if cur is not None:
            blocks.append(cur)
        cur = [ln]
    elif cur is None:
        head.append(ln)
    else:
        cur.append(ln)
if cur is not None:
    blocks.append(cur)
assert len(blocks) == 2, "expected two archived rows, got %d" % len(blocks)
open(p, 'w').write('\n'.join(head + blocks[1] + blocks[0]))
print("rewrote data/done-archive.md with the bare-close row listed first")
PY
say "head -1 of each archived row after the swap"
grep -n -F -- "- [x] $CALL - " "$H/data/done-archive.md" | sed 's/ - Choose.*(done/ ... (done/'
say "fm-captain-hold.sh complete $SECOND --none   # newest-first archive order"
if captain complete "$SECOND" --none; then
  echo "EXIT 0: ACCEPTED (order-dependent: the rule broke)"
else
  echo "EXIT $?: refused in this order too"
fi
