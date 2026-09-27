# Evidence for target `1889a5f` (base `5719dac`)

Branch `fm/firstmate-unreplayable-backlog-close-v4`. Verified against the real
`bin/fm-teardown.sh`, `bin/fm-bootstrap.sh`, a real `data/backlog.md`, and the
real `tasks-axi` CLI (0.2.5 - the version CI pins - installed into a throwaway
prefix for this run; it is not installed on this host otherwise, which would
otherwise make the whole suite self-skip).

Files:

- `incident-before-after.txt` - the filed incident reproduced at base and shown
  fixed at target, side by side (the headline artifact).
- `teardown-aged-out-row.txt` / `before/teardown-aged-out-row.txt` - raw
  completion transcripts at target / base.
- `session-start-replay.txt` / `before/session-start-replay.txt` - raw session
  start transcripts at target / base.
- `refusals-unconfirmed-absence.txt` - the two refusal paths that must stay loud,
  verbatim.

## What this round changed, and what the transcripts show

This round's operator-visible delta is the softened link wording: completion no
longer asserts the completion link "was never applied", it says it "could not be
confirmed as applied and should be checked" - the same phrasing session start
already used. The target transcript carries exactly that phrasing and the
suite's `assert_not_contains "was never applied"` holds.

## Incident, reproduced and fixed

Row added, started, closed, then pruned with `--keep 0` so `tasks-axi show <id>`
answers `code: NOT_FOUND`. Teardown then runs its own close.

Base `5719dac`:

```
error: fm-incident-aged-out's endpoint and local copy are cleaned up, but its backlog item could not
be closed atomically (error: "Task \"fm-incident-aged-out\" not found in this backlog"); the pending
close is recorded and the next session start retries it
exit 1 | pending-close records left behind: 1   <- the retry can never land
```

Target `1889a5f`:

```
teardown fm-incident-aged-out complete (window firstmate:fm-fm-incident-aged-out, worktree ...)
Backlog: fm-incident-aged-out had already left <TMPROOT>/home/data/backlog.md, so cleanup recorded no
close there and its completion link (local main) could not be confirmed as applied and should be
checked. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates, check date gates, and
dispatch only work whose blockers are gone and date is due.
exit 0 | pending-close records left behind: 0
```

Session start replaying a recorded close for a row removed outright - base
printed nothing at all and retired the record silently, dropping the merged PR
the record carried. Target:

```
BACKLOG_RECONCILE: fm-incident-replay: the recorded backlog close was retired because its backlog row
had already left this backlog, so no close was left to land; its recorded completion link
(PR https://example.test/pr/7) could not be confirmed as applied and should be checked
state/fm-incident-replay.backlog-close: RETIRED
```

## The refusal is still loud when the absence is not confirmed

Both preserved records, both exit 1 (`refusals-unconfirmed-absence.txt`):

1. close reported `NOT_FOUND`, the confirming row read failed - the message names
   the read failure, which is the only thing left to fix.
2. close failed for a reason that is not an absence and the row read also failed -
   the message names both failures and claims no absence ("absence" and "had
   already left" are both absent from the output).

## Regression proof: fail before, pass after

Each of the change's 7 new tests, run individually with `bin/` and everything
else rolled back to base `5719dac` and only the new test file copied in:

```
BASE test_completion_accepts_a_row_already_archived_by_retention               rc=1
     not ok - teardown failed against a row already archived by retention: error: ... not found ...
BASE test_completion_keeps_a_close_whose_row_lookup_fails                      rc=1
     not ok - ... (missing: 'could not be read to confirm whether the item still exists')
BASE test_completion_refusal_claims_no_absence_when_the_close_never_reported_one rc=1
     not ok - ... (missing: 'backlog is unreadable')
BASE test_interrupted_cleanup_of_an_archived_row_still_warns_about_its_endpoint rc=1
     not ok - ... (missing: 'had already left this backlog')
BASE test_recovery_retires_a_close_for_a_row_archived_by_retention             rc=1
     not ok - a retired pending close was resolved silently (missing: 'had already left this backlog')
BASE test_recovery_retires_a_close_for_a_row_removed_without_closing           rc=1
     not ok - a retired pending close was resolved silently (missing: 'had already left this backlog')
BASE test_recovery_reports_a_row_that_left_the_backlog_mid_close               rc=1
     not ok - a close whose row left the backlog mid-replay was left to retry forever

TARGET: all 7 pass.
```

## Suites run at target

- `tests/fm-backlog-atomicity.test.sh` (owning suite) - 120 ok, 0 not ok
- `tests/fm-backlog-read-bound.test.sh` - 10 ok, 0 not ok
- `tests/fm-tasks-axi.test.sh` - 8 ok, 0 not ok
