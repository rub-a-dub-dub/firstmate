#!/usr/bin/env bash
# End-to-end evidence for "captain-hold complete appends after pr=".
#
# Builds a real firstmate home, holds a captain origin and one captain call,
# arms a real merge poll on the origin through bin/fm-pr-check.sh, then runs the
# REAL watcher (bin/fm-watch.sh) before and after `fm-captain-hold.sh complete`.
# The watcher's own output is the end-user surface: an origin whose record the
# completion wedged makes it wake with
#   check: rejected unauthenticated state checks: <state>/<id>.check.sh
# on every cycle.
set -u

ROOT=${ROOT:?set ROOT to the worktree}
. "$ROOT/tests/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TASKS_AXI_BIN=$(command -v tasks-axi)
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-pr-evidence)
HOME_DIR="$TMP_ROOT/case"
ORIGIN=pr-review-origin
CALL=pr-review-call
PR_URL=https://github.com/example/sample/pull/7
HEAD_SHA=0123456789abcdef0123456789abcdef01234567

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/wt"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes
# gh, answering only what arming a GitHub merge poll reads.
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --json isDraft "*) printf '%s\n' '{"isDraft":false}' ;;
  *headRefOid*) printf '%s\n' '{"headRefOid":"$HEAD_SHA","reviewDecision":"APPROVED"}' ;;
  *" api repos/"*"/pulls/"*) printf '%s\n' '{"state":"open","user":{"login":"author"},"head":{"sha":"$HEAD_SHA"},"draft":false,"mergeable":true,"merged_at":null}' ;;
  *" state "*) printf '%s\n' "\${FM_TEST_GH_STATE:-OPEN}" ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"

git -C "$HOME_DIR/wt" init -q
fm_git_identity fmtest fmtest@example.invalid
git -C "$HOME_DIR/wt" commit -q --allow-empty -m init
git -C "$HOME_DIR/wt" update-ref "refs/remotes/origin/main" "$(git -C "$HOME_DIR/wt" rev-parse HEAD)"
git -C "$HOME_DIR/wt" update-ref "refs/remotes/origin/fm/$ORIGIN" "$(git -C "$HOME_DIR/wt" rev-parse HEAD)"

run_captain() {
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}
run_pr_check() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-pr-check.sh" "$@"
}
# Drain and acknowledge the wake a cycle just delivered, the way a live captain
# session's wake handshake does, so the next cycle starts from a quiet watcher.
ack_watcher_cycle() {
  local err sequence generation
  err="$HOME_DIR/state/.wake-drain.err"
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
}

# One bounded cycle of the real watcher, with the slow per-task checks due.
watch_cycle() {
  rm -f "$HOME_DIR/state/.last-check"
  perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $left=$ENV{EVIDENCE_WATCH_BOUND}||12; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now - $last; $last=$now; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.02 } exit($? >> 8)' \
    env -u FM_CHECK_TIMEOUT FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-watch.sh" 2>&1
}

# The watcher reports ONE wake per cycle and exits, so a cycle that wakes on the
# post-downtime resurface or on an unrelated check never reaches the per-task
# merge poll. Run cycles, acknowledging each wake, until one reports on the
# origin's own check or nothing is left to report.
run_watcher() {
  local out i
  for i in 1 2 3 4 5; do
    out=$(watch_cycle)
    ack_watcher_cycle || true
    case "$out" in
      *"$ORIGIN.check.sh"*|*"rejected unauthenticated state checks"*) break ;;
      '') break ;;
    esac
  done
  printf '%s\n' "$out"
}

say() { printf '\n=== %s ===\n' "$1"; }

say "1. hold the review origin and one captain call (operator CLI)"
run_captain hold "$ORIGIN" --title "Review call for $ORIGIN" --reason "Choose" || exit 1
run_captain hold "$CALL" --title "Call $CALL" --reason "Choose" --origin "$ORIGIN" || exit 1

# The task record a spawned review origin carries.
fm_write_meta "$HOME_DIR/state/$ORIGIN.meta" \
  "window=firstmate:fm-$ORIGIN" \
  "worktree=$HOME_DIR/wt" \
  "project=$HOME_DIR/projects/sample" \
  "harness=codex" \
  "kind=scout" \
  "mode=scout" \
  "spawn_gen=evidence-$ORIGIN"

say "2. arm the merge poll on the origin (bin/fm-pr-check.sh)"
run_pr_check "$ORIGIN" "$PR_URL" || exit 1

# bin/fm-pr-check.sh also arms a contributions observation check. It is
# unrelated to this regression and its own wake would end the cycle before the
# origin's merge poll ran, so it is removed from the fixture.
rm -f "$HOME_DIR/state/contributions.check.sh"

say "3. the armed task record"
cat "$HOME_DIR/state/$ORIGIN.meta"

say "4. watcher cycle BEFORE completion"
run_watcher

say "5. record the reviewed inventory (fm-captain-hold.sh complete)"
run_captain complete "$ORIGIN" "$CALL" || exit 1

say "6. the task record AFTER completion"
cat "$HOME_DIR/state/$ORIGIN.meta"

say "7. watcher cycle AFTER completion"
out=$(run_watcher)
printf '%s\n' "$out"

say "8. verdict"
case "$out" in
  *"rejected unauthenticated state checks"*)
    printf 'WEDGED: the watcher rejects the completed origin on every cycle.\n' ;;
  *)
    printf 'CLEAN: the watcher still authenticates the completed origin.\n' ;;
esac

# fm-pr-check.sh refuses to re-arm an origin whose record is not a private,
# single-link regular file, so the record `complete` republishes has to keep
# satisfying that gate.
say "9. the republished record still satisfies the re-arm precondition"
meta="$HOME_DIR/state/$ORIGIN.meta"
printf 'mode=%s links=%s symlink=%s\n' \
  "$(stat -f %Lp "$meta")" "$(stat -f %l "$meta")" \
  "$([ -L "$meta" ] && echo yes || echo no)"
if bash -c '. "$1"; fm_pr_private_file_valid "$2" 600 "$(fm_pr_file_device "$3")"' _ \
  "$ROOT/bin/fm-pr-lib.sh" "$meta" "$HOME_DIR/state"; then
  printf 'fm_pr_private_file_valid: accepted\n'
else
  printf 'fm_pr_private_file_valid: REFUSED\n'
fi
