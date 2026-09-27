# Evidence: an unreplayable backlog close now retires instead of promising a retry

Branch `fm/firstmate-unreplayable-backlog-close-v4` (base `6ad419da` -> target `c8c9572`).

Reproduced the filed incident end to end against the real `bin/fm-teardown.sh`,
`bin/fm-bootstrap.sh`, a real `data/backlog.md`, and the real `tasks-axi` CLI
(0.2.6, installed into a throwaway prefix for this run). Tmp paths in the
transcripts are collapsed to `<TMPROOT>`; nothing else is edited.

## The incident, as the operator sees it

Setup in all cases: an in-flight row is closed and then aged out of `done_keep`
retention (`tasks-axi prune --keep 0 --state done`), so `tasks-axi show <id>`
answers `code: NOT_FOUND`. Teardown then runs its own close against that row.

### Before (base `6ad419da`) - `operator-transcript-before-fix-baseline.txt`

```
error: fm-retention-incident-demo's endpoint and local copy are cleaned up, but its backlog item
could not be closed atomically (error: "Task \"fm-retention-incident-demo\" not found in this
backlog"); the pending close is recorded and the next session start retries it

[teardown exit status: 1]
[state/fm-retention-incident-demo.backlog-close after completion: still recorded - retry owed]
```

That is the incident text quoted in the intent, byte for byte, and the retry it
promises can never land. The session-start replay of an already-recorded marker
printed **nothing at all** at base - the record was retired silently, so the
completion link it carried was dropped without a word (see the
`BACKLOG_RECONCILE` section of the baseline transcript: only unrelated `MISSING:`
lines appear).

### After (target `c8c9572`) - `operator-transcript-after-fix.txt`

```
teardown fm-retention-incident-demo complete (window firstmate:fm-fm-retention-incident-demo, ...)
Backlog: fm-retention-incident-demo had already left <TMPROOT>/evidence-incident/home/data/backlog.md,
so cleanup recorded no close there and its completion link (local main) could not be confirmed as
applied and should be checked. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates, ...

[teardown exit status: 0]
[state/fm-retention-incident-demo.backlog-close after completion: retired - no unlandable retry left behind]
```

Session start, replaying a marker an earlier interrupted teardown left for a row
that has since gone, now reports the retirement on an actionable line and names
the link it could not confirm:

```
BACKLOG_RECONCILE: fm-retention-incident-replay: the recorded backlog close was retired because its
backlog row had already left this backlog, so no close was left to land; its recorded completion link
(PR https://github.com/example/repo/pull/42) could not be confirmed as applied and should be checked

[state/fm-retention-incident-replay.backlog-close after session start: retired]
```

## The refusal is still loud when the absence is not confirmed

Same transcript, third section: the close reports `NOT_FOUND` but the confirming
row read fails, so nothing establishes whether the row exists. Teardown still
exits 1, keeps the record, and now names the read failure that is the only thing
left to fix:

```
error: fm-unreadable-backlog-demo's endpoint and local copy are cleaned up, but its backlog item
could not be closed atomically (error: Task "fm-unreadable-backlog-demo" not found in this backlog;
this home's backlog row could not be read to confirm whether the item still exists (error: "backlog
is unreadable"), so the next session start retries this close); the pending close is recorded and the
next session start retries it

[teardown exit status: 1]
[state/fm-unreadable-backlog-demo.backlog-close: preserved for retry]
```

## Control: an ordinary present row is unchanged

Fourth section: a normal in-flight row still closes, reports `is closed in
<backlog>`, exits 0, and the row reads `done`.

## Regression proof (fail before, pass after)

Each of the change's seven new tests, run in isolation with only `bin/` rolled
back to the base commit, then again at target:

```
BASE   test_completion_accepts_a_row_already_archived_by_retention                rc=1 notok=1
BASE   test_completion_keeps_a_close_whose_row_lookup_fails                       rc=1 notok=1
BASE   test_completion_refusal_claims_no_absence_when_the_close_never_reported_one rc=1 notok=1
BASE   test_interrupted_cleanup_of_an_archived_row_still_warns_about_its_endpoint rc=1 notok=1
BASE   test_recovery_retires_a_close_for_a_row_archived_by_retention              rc=1 notok=1
BASE   test_recovery_retires_a_close_for_a_row_removed_without_closing            rc=1 notok=1
BASE   test_recovery_reports_a_row_that_left_the_backlog_mid_close                rc=1 notok=1

TARGET test_completion_accepts_a_row_already_archived_by_retention                rc=0 notok=0
TARGET test_completion_keeps_a_close_whose_row_lookup_fails                       rc=0 notok=0
TARGET test_completion_refusal_claims_no_absence_when_the_close_never_reported_one rc=0 notok=0
TARGET test_interrupted_cleanup_of_an_archived_row_still_warns_about_its_endpoint rc=0 notok=0
TARGET test_recovery_retires_a_close_for_a_row_archived_by_retention              rc=0 notok=0
TARGET test_recovery_retires_a_close_for_a_row_removed_without_closing            rc=0 notok=0
TARGET test_recovery_reports_a_row_that_left_the_backlog_mid_close                rc=0 notok=0
```

The base failure messages are the incident itself and the silent retirement:
`teardown failed against a row already archived by retention: error: ... not
found in this backlog; the pending close is recorded ...`, and
`a retired pending close was resolved silently, leaving the operator to infer it
(missing: 'had already left this backlog')`.

## Suites run

- `tests/fm-backlog-atomicity.test.sh` - the owning suite: 109 ok, 0 not ok (`fm-backlog-atomicity-suite.txt`)
- `tests/fm-backlog-read-bound.test.sh` - 10 ok, 0 not ok
- `tests/fm-tasks-axi.test.sh` - 8 ok, 0 not ok
