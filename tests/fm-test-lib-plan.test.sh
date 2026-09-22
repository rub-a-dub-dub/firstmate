#!/usr/bin/env bash
# fm-test-lib-plan.test.sh - the plan() reporter and the mechanical scanner
# contract it exists to serve.
#
# A run of one of this suite's slower files (fm-captain-hold-lifecycle.test.sh
# is the reported case: bin/fm-test-run.sh's own portable_parallel_weight_hints
# clocks it in the low minutes) can be cut short by a caller's shorter
# invocation budget before it prints a final result. Before plan(), the
# resulting stream - a run of "ok" lines followed by silence - is byte-for-byte
# identical to a genuinely complete pass, so a scanner has no way to tell a
# healthy interruption from a real failure. This suite proves plan() closes
# that gap: a declared count a scanner can check the observed result count
# against, without relying on prose or exit-code timing a scanner may not see.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# classify_tap_stream <file>: the scanner side of the plan() contract. Prints
# one of complete, incomplete, or failed. Any "not ok" line always wins,
# regardless of how the observed count compares to the plan, so this never
# buys quieter real failures in exchange for correctly reading a truncation.
classify_tap_stream() {
  local file=$1 planned ok_count notok_count
  planned=$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
  ok_count=$(grep -c '^ok - ' "$file")
  notok_count=$(grep -c '^not ok - ' "$file")
  if [ "$notok_count" -gt 0 ]; then
    printf 'failed\n'
  elif [ -z "$planned" ] || [ "$((ok_count + notok_count))" -lt "$planned" ]; then
    printf 'incomplete\n'
  else
    printf 'complete\n'
  fi
}

test_plan_prints_the_declared_count() {
  local out
  out=$(plan 3)
  assert_equals '1..3' "$out" "plan did not print the declared count on its own line"
  pass "plan prints the declared count on its own line"
}

test_scanner_reads_a_complete_run_as_complete() {
  local home stream
  home=$(fm_test_tmproot fm-plan-scanner)
  stream="$home/stream.out"
  {
    plan 3
    pass "first"
    pass "second"
    pass "third"
  } > "$stream"
  assert_equals complete "$(classify_tap_stream "$stream")" \
    "a run whose observed count matches its plan was not read as complete"
  pass "a run whose observed count matches its plan reads as complete"
}

test_scanner_reads_a_truncated_clean_run_as_incomplete_not_failed() {
  local home full stream
  home=$(fm_test_tmproot fm-plan-scanner)
  full="$home/full.out"
  stream="$home/truncated.out"
  {
    plan 3
    pass "first"
    pass "second"
    pass "third"
  } > "$full"
  # Simulate an external time bound landing after the plan line and one
  # result: the caller's own cutoff, not anything the fixture printed.
  head -n 2 "$full" > "$stream"
  assert_no_grep 'not ok - ' "$stream" "the truncated fixture used to reproduce this had a real failure in it"
  assert_equals incomplete "$(classify_tap_stream "$stream")" \
    "a truncated-but-clean run read as something other than incomplete"
  pass "a truncated-but-clean run reads as incomplete, not failed"
}

test_scanner_still_reads_a_real_failure_as_failed() {
  local home stream rc
  home=$(fm_test_tmproot fm-plan-scanner)
  stream="$home/stream.out"
  (
    plan 2
    pass "first"
    fail "second: the invariant this fixture checks was violated"
  ) > "$stream" 2>> "$stream"
  rc=$?
  [ "$rc" -ne 0 ] || fail "the fixture's deliberate failure did not exit non-zero"
  assert_equals failed "$(classify_tap_stream "$stream")" \
    "a real not-ok result was not read as a failure"
  pass "a real not-ok result still reads as a failure"
}

test_scanner_reads_a_real_failure_as_failed_even_when_short_of_the_plan() {
  local home stream rc
  home=$(fm_test_tmproot fm-plan-scanner)
  stream="$home/stream.out"
  # fail() exits the run, so a real failure partway through always leaves the
  # observed count short of the plan - the same shape a benign interruption
  # produces. This is that case: five results were planned, only two ever
  # ran, and the second one genuinely failed.
  (
    plan 5
    pass "first"
    fail "second: the invariant this fixture checks was violated"
  ) > "$stream" 2>> "$stream"
  rc=$?
  [ "$rc" -ne 0 ] || fail "the fixture's deliberate failure did not exit non-zero"
  [ "$(grep -c '^ok - ' "$stream")" -lt 5 ] \
    || fail "the fixture no longer reproduces a count short of its declared plan"
  assert_equals failed "$(classify_tap_stream "$stream")" \
    "a genuine failure was masked by comparing it against the plan count"
  pass "a genuine failure still reads as failed even when it also falls short of the plan"
}

# The reported reproduction: run tests/fm-captain-hold-lifecycle.test.sh for
# real, interrupt it the moment it has printed its plan line and one real
# result - mirroring the external time bound that actually cuts this file's
# runs short - and confirm the resulting output, exactly as this suite would
# scan it, reads as interrupted rather than as a failure.
test_captain_hold_lifecycle_interruption_reads_as_incomplete_not_failed() {
  local home out pid waited=0 planned
  if ! command -v jq >/dev/null 2>&1 || ! command -v tasks-axi >/dev/null 2>&1; then
    pass "skipped without jq/tasks-axi: an interrupted run of fm-captain-hold-lifecycle.test.sh reads as incomplete, not failed"
    return 0
  fi
  home=$(fm_test_tmproot fm-plan-repro)
  out="$home/captain-hold.out"
  bash "$ROOT/tests/fm-captain-hold-lifecycle.test.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$waited" -lt 3000 ]; do
    [ -s "$out" ] && grep -q '^ok - ' "$out" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  planned=$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' "$out" | head -n1)
  [ -n "$planned" ] || fail "the interrupted run never printed its plan line"
  assert_no_grep 'not ok - ' "$out" \
    "the reproduction is invalid: a real failure appeared, not just a truncation"
  [ "$(grep -c '^ok - ' "$out")" -lt "$planned" ] \
    || fail "the run finished before it could be interrupted; the reproduction needs a genuine truncation"
  assert_equals incomplete "$(classify_tap_stream "$out")" \
    "an interrupted-but-healthy run of the reported file was not read as incomplete"
  pass "an interrupted run of fm-captain-hold-lifecycle.test.sh reads as incomplete, not failed"
}

TESTS=(
  test_plan_prints_the_declared_count
  test_scanner_reads_a_complete_run_as_complete
  test_scanner_reads_a_truncated_clean_run_as_incomplete_not_failed
  test_scanner_still_reads_a_real_failure_as_failed
  test_scanner_reads_a_real_failure_as_failed_even_when_short_of_the_plan
  test_captain_hold_lifecycle_interruption_reads_as_incomplete_not_failed
)

plan "${#TESTS[@]}"
for t in "${TESTS[@]}"; do
  "$t"
done
