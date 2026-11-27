# Buzz bridge stale-timestamp retry — test evidence

Intent: a transient NIP-98 "event timestamp outside ±60s window" refusal (the
lid-closed dark-wake case) must no longer raise the false
`buzz-bridge-error relay refused the bridge key (auth error); check channel membership`
notification; it must be retried with a fresh signature. Genuine key/membership
refusals must still alert.

## owner-visible-wakes-before-after.txt  (primary artifact)

The owner-facing wake surface, captured by driving `bin/fm-buzz-poll.sh` against
the hermetic fake Buzz CLI from `tests/fm-buzz-bridge.test.sh` (the fake returns
the exact rc=3 stderr payload from the bug report), once with `bin/` at the base
commit and once at the target commit. Three scenarios: transient skew, genuine
membership refusal, persistent skew.

Before: all three scenarios wake the owner with the auth-error false alarm and
the mention is lost.
After: the transient case delivers the request (`buzz-mention buzz-<id>`) on the
second attempt with no wake at all; the genuine membership refusal still wakes
and is never retried (1 attempt); persistent skew is silent on the wake surface
and visible only as `fm-buzz.sh status` → `last poll diagnostic: relay refused
the bridge signature as stale (clock skew)`, with the cursor held.

Reproduce: copy `tests/fm-buzz-bridge.test.sh` through its last test function,
append a driver that calls `poll` under `FAKE_AUTH_COMMANDS=get` with
`FAKE_AUTH_MODE=once|membership|persistent`, and run it via
`bin/fm-test-run.sh`. (The driver was a transient file; it was removed after
capture and is not part of the change.)

## before-fix-baseline.txt / after-fix-targeted-tests.txt

The six new regression tests plus `test_poll_holds_cursor_on_read_failure`, run
with `bin/` reverted to base (fails at the first assertion: the retried read
does not deliver the request) and at target (7/7 pass).

## listener-test-flakiness.txt

`test_listener_wakes_through_the_poll_and_retires` in the same suite is flaky on
this host at BOTH commits (procevent listener registration, untouched by this
change). Three isolated runs at each commit.

## Full suite

`bin/fm-test-run.sh tests/fm-buzz-bridge.test.sh` — 45 of 46 tests pass; the
only failure is the pre-existing flaky listener test above. Re-run with that one
entry removed from the `fm_test_run` list: 45/45 pass, `FM_TEST_COMPLETE`,
exit=0, duration 133s.
