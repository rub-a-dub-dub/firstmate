#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

# Reproduces the captain-facing incident: several tasks hold genuinely open,
# never-resolved needs-decision/blocked lines whose presentation cursors the
# bootstrap drain already advanced to EOF, and a completely UNRELATED task's
# status log - no open decision of its own, and the fleet's only remaining
# unread span - hits a transient read failure while the drain acknowledges the
# presented snapshot. status_acknowledge_presented_snapshot reads each task's
# unread span through status_new_lines_since_cursor and aborts the whole
# fleet-wide pass on its per-task `|| return 1`; the three decision-holding
# tasks short-circuit at EOF without reading, so that one unrelated task's
# failure is the only span read even attempted. Before the fix,
# print_status_sections then returned before preparing a single section, so
# the drain went completely silent, indistinguishable from "nothing is open".
# The very next drain (no status append, no ack) recomputed cleanly and
# showed all the open decisions again unchanged, which is exactly the
# self-correcting-but-dangerous pattern reported: a captain turn that lands
# on the failing drain sees no open decisions at all.
test_unrelated_task_read_failure_reports_incomplete_not_silent_empty() {
  local dir state out reader
  dir=$(make_case unrelated-read-failure)
  state="$dir/state"
  out="$dir/drain.out"
  reader="$dir/fail-reader"

  # The trailing `note:` is the only unread-surface verb here, so the bootstrap
  # drain commits these three cursors at EOF. The unrelated task's routine
  # `working:` line is not an unread surface, so its cursor stays at 0 and its
  # span is the one the next drain still has to read - and fail on.
  printf 'needs-decision [key=which-fork]: pick a or b\nnote: still waiting on the captain\n' > "$state/cowork-skills-directory-phone-design-forks.status"
  printf 'needs-decision [key=default]: reconcile with upstream how?\nnote: still waiting on the captain\n' > "$state/firstmate-reconcile-fork-with-upstream.status"
  printf 'blocked [key=default]: cannot replay this close\nnote: still waiting on the captain\n' > "$state/firstmate-unreplayable-backlog-close.status"
  printf 'working: no decision here, just routine progress\n' > "$state/zzz-unrelated-task.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected unrelated read failure failed"
  grep -F 'cowork-skills-directory-phone-design-forks' "$out" | grep -F '[key=which-fork]' >/dev/null \
    || fail "a decision failed to surface on the bootstrap drain"

  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of reporting an incomplete computation"
  if grep -F 'OPEN DECISIONS (still open' "$out" >/dev/null; then
    fail "an incomplete fold still printed a normal OPEN DECISIONS section: $(command cat "$out")"
  fi
  grep -F 'STATUS PRESENTATION INCOMPLETE: unread status, outcome backstop, OPEN DECISIONS' "$out" >/dev/null \
    || fail "an unrelated task's read failure went silent instead of reporting an incomplete drain: $(command cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "recovery drain after the injected failure cleared failed"
  while IFS='|' read -r task decision; do
    [ -n "$task" ] || continue
    grep -F "$task [key=$decision" "$out" >/dev/null \
      || fail "task $task's open decision did not reappear unchanged once the read failure cleared: $(command cat "$out")"
  done <<'DECISIONS'
cowork-skills-directory-phone-design-forks|which-fork] needs-decision: pick a or b
firstmate-reconcile-fork-with-upstream|default] needs-decision: reconcile with upstream how?
firstmate-unreplayable-backlog-close|default] blocked: cannot replay this close
DECISIONS

  pass "an unrelated task's transient read failure reports an incomplete drain instead of a silently empty OPEN DECISIONS section"
}

# The reported incident, reproduced end to end. Teardown retires a task's
# presentation record and deletes $STATE/<task>.status but purges nothing from
# the wake queue, so a still-unacked `signal:` row keeps pointing at a status
# file that no longer exists. The annotation pass read that vanished task's
# cursor before checking whether the snapshot even listed it, so one torn-down
# task aborted the whole pass; the drain then skipped every section and printed
# no notice, and the next drain - once the ack consumed the row - printed all
# the open calls again unchanged. That is exactly the teardown-adjacent,
# self-correcting blank the captain saw.
test_torn_down_task_wake_row_does_not_blank_the_sections() {
  local dir state out
  dir=$(make_case torn-down-wake-row)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'needs-decision [key=which-fork]: pick a or b\n' > "$state/cowork-skills-directory-phone-design-forks.status"
  printf 'blocked [key=default]: cannot replay this close\n' > "$state/firstmate-unreplayable-backlog-close.status"
  printf 'working: about to be torn down\n' > "$state/firstmate-bearings-truncates-the-urgent-row.status"

  append_wake "$state" signal firstmate-bearings-truncates-the-urgent-row.status \
    "signal: $state/firstmate-bearings-truncates-the-urgent-row.status" \
    || fail "seeding the torn-down task's wake row failed"
  rm -f "$state/firstmate-bearings-truncates-the-urgent-row.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed on a wake row whose status file teardown removed"

  grep -F 'cowork-skills-directory-phone-design-forks [key=which-fork] needs-decision: pick a or b' "$out" >/dev/null \
    || fail "a torn-down task's queued wake row blanked another task's open decision: $(command cat "$out")"
  grep -F 'firstmate-unreplayable-backlog-close [key=default] blocked: cannot replay this close' "$out" >/dev/null \
    || fail "a torn-down task's queued wake row blanked another task's open decision: $(command cat "$out")"
  # The sections all computed, so the drain owes no incomplete notice: a task
  # that was legitimately retired has nothing left to report, and crying
  # incomplete over it would erode the notice everywhere else.
  if grep -F 'STATUS PRESENTATION INCOMPLETE' "$out" >/dev/null; then
    fail "a legitimately torn-down task's queued wake row reported a false incomplete drain: $(command cat "$out")"
  fi

  pass "a torn-down task's still-queued wake row does not blank the surviving tasks' open decisions"
}

# A fleet snapshot read that fails PART WAY through still hands back every task
# it printed before the failure. Committing that truncated view rewrites the
# shared presentation-cursor manifest without the tasks the read never reached,
# so their unread and outcome-backstop cursors are lost for good and the whole
# status log replays as unread on the next drain - a durable regression, not the
# self-correcting blank the branch targets. The identity reader fails for the
# middle task only, which is exactly the teardown concurrency the incident
# describes: the record vanishes between the snapshot's existence test and its
# stat.
test_partial_snapshot_does_not_truncate_the_cursor_manifest() {
  local dir state out ident
  dir=$(make_case partial-snapshot)
  state="$dir/state"
  out="$dir/drain.out"
  ident="$dir/ident-reader"

  # Stable per-file identity so the manifest stays trusted across all three
  # drains; the middle task's read fails only while the flag file exists.
  cat > "$ident" <<IDENT
#!/usr/bin/env bash
case "\${1:-}" in
  *mmm-vanishing-task.status) [ ! -f "$dir/fail-ident" ] || exit 1 ;;
esac
printf 'test-ident:%s' "\$(basename "\${1:-}")"
IDENT
  chmod +x "$ident"

  printf 'needs-decision [key=aaa]: pick a or b\nnote: still waiting on the captain\n' > "$state/aaa-open-task.status"
  printf 'working: about to vanish mid-snapshot\nnote: still waiting on the captain\n' > "$state/mmm-vanishing-task.status"
  printf 'needs-decision [key=zzz]: reconcile with upstream how?\nnote: still waiting on the captain\n' > "$state/zzz-open-task.status"

  FM_STATE_OVERRIDE="$state" FM_STATUS_IDENTITY_READER="$ident" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected snapshot failure failed"
  grep -F 'zzz-open-task note: still waiting on the captain' "$out" >/dev/null \
    || fail "the bootstrap drain did not present the last task's status as unread"

  : > "$dir/fail-ident"
  FM_STATE_OVERRIDE="$state" FM_STATUS_IDENTITY_READER="$ident" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of reporting an unreadable snapshot"
  grep -F 'STATUS PRESENTATION INCOMPLETE: status snapshot could not be read.' "$out" >/dev/null \
    || fail "a failed snapshot read went unreported: $(command cat "$out")"

  rm -f "$dir/fail-ident"
  FM_STATE_OVERRIDE="$state" FM_STATUS_IDENTITY_READER="$ident" "$DRAIN" > "$out" \
    || fail "recovery drain after the snapshot failure cleared failed"
  if grep -F 'zzz-open-task note: still waiting on the captain' "$out" >/dev/null; then
    fail "a partial snapshot dropped the trailing task's presentation cursor, replaying its whole status log as unread: $(command cat "$out")"
  fi
  grep -F 'zzz-open-task [key=zzz] needs-decision: reconcile with upstream how?' "$out" >/dev/null \
    || fail "the trailing task's still-open decision stopped surfacing after the snapshot failure: $(command cat "$out")"

  pass "a partially read fleet snapshot never commits over the other tasks' presentation cursors"
}

# An untrusted per-task fold cursor has no persisted open set to fall back on,
# so a span-read failure there cannot honestly report "nothing open". The
# acknowledge and unread-status passes both short-circuit at EOF here, so this
# reaches the fold as the only failing read - the case that used to return rc 0
# with an emptied set and print an authoritative-looking empty section.
test_untrusted_fold_cursor_read_failure_is_not_a_silent_empty() {
  local dir state out reader
  dir=$(make_case untrusted-fold-cursor)
  state="$dir/state"
  out="$dir/drain.out"
  reader="$dir/fail-reader"

  printf 'needs-decision [key=which-fork]: pick a or b\nnote: still waiting on the captain\n' \
    > "$state/cowork-skills-directory-phone-design-forks.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the untrusted-cursor failure failed"
  grep -F 'cowork-skills-directory-phone-design-forks [key=which-fork]' "$out" >/dev/null \
    || fail "the decision failed to surface on the bootstrap drain"

  # Invalidate only the fold cursor: a stale fold version is what a release
  # bump or a reused task id produces, and it clears the trusted open set while
  # leaving the presentation cursor parked at EOF.
  printf 'version=0\noffset=0\nident=stale\n' \
    > "$state/.cowork-skills-directory-phone-design-forks.open-decisions-cursor"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of reporting an incomplete computation"
  if grep -F 'OPEN DECISIONS (still open' "$out" >/dev/null; then
    fail "an unreadable untrusted fold still printed a normal OPEN DECISIONS section: $(command cat "$out")"
  fi
  grep -F 'STATUS PRESENTATION INCOMPLETE: unread status, outcome backstop, OPEN DECISIONS' "$out" >/dev/null \
    || fail "an untrusted fold cursor's read failure printed a silently empty section: $(command cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "recovery drain after the injected failure cleared failed"
  grep -F 'cowork-skills-directory-phone-design-forks [key=which-fork] needs-decision: pick a or b' "$out" >/dev/null \
    || fail "the open decision did not reappear unchanged once the read failure cleared: $(command cat "$out")"

  pass "an untrusted fold cursor's read failure reports an incomplete drain instead of a silently empty section"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_unrelated_task_read_failure_reports_incomplete_not_silent_empty
test_torn_down_task_wake_row_does_not_blank_the_sections
test_partial_snapshot_does_not_truncate_the_cursor_manifest
test_untrusted_fold_cursor_read_failure_is_not_a_silent_empty
test_status_symlink_is_not_followed
