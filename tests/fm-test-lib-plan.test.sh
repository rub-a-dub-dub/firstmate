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

# classify_tap_stream <file>: scaffolding private to this file, not a shared
# interface - nothing outside these assertions calls it. It stands in for the
# external scanner so each case below can state what a stream means instead of
# restating grep counts. Prints one of failed, incomplete, unknown, or
# complete. A "not ok" line always wins, whatever the observed count, so this
# never buys quieter real failures in exchange for reading a truncation
# correctly. Only a plan line that is present and undershot means the run was
# cut short; a stream carrying no plan line is no evidence either way and
# reads unknown, never the "worth retrying" incomplete.
classify_tap_stream() {
  local file=$1 planned ok_count notok_count
  planned=$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
  ok_count=$(grep -c '^ok - ' "$file")
  notok_count=$(grep -c '^not ok - ' "$file")
  if [ "$notok_count" -gt 0 ]; then
    printf 'failed\n'
  elif [ -z "$planned" ]; then
    printf 'unknown\n'
  elif [ "$((ok_count + notok_count))" -lt "$planned" ]; then
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

test_scanner_reads_a_stream_with_no_plan_line_as_unknown() {
  local home stream
  home=$(fm_test_tmproot fm-plan-scanner)
  stream="$home/stream.out"
  # The shape every test file that has not adopted plan() still emits: clean
  # results, no declared count, nothing cut short.
  {
    pass "first"
    pass "second"
  } > "$stream"
  assert_no_grep '1\.\.' "$stream" "the plan-less fixture used to reproduce this declared a count after all"
  assert_equals unknown "$(classify_tap_stream "$stream")" \
    "a complete run that declares no plan was read as cut short"
  pass "a stream with no plan line reads as unknown, not incomplete"
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

TESTS=(
  test_plan_prints_the_declared_count
  test_scanner_reads_a_complete_run_as_complete
  test_scanner_reads_a_truncated_clean_run_as_incomplete_not_failed
  test_scanner_reads_a_stream_with_no_plan_line_as_unknown
  test_scanner_still_reads_a_real_failure_as_failed
  test_scanner_reads_a_real_failure_as_failed_even_when_short_of_the_plan
)

plan "${#TESTS[@]}"
for t in "${TESTS[@]}"; do
  "$t"
done
