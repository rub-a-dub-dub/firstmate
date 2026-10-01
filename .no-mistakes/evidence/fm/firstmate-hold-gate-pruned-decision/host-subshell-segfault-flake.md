# Host-level intermittent SIGSEGV observed while validating this change

Measured on this machine while running the targeted regressions. It is **not**
introduced by this branch: the same command on the **base** commit fails the
same way at the same rate.

Host: macOS 27.0 (Darwin 27.0.0), `/usr/bin/env bash` -> Homebrew bash
5.3.15(1), `/usr/bin/awk` 20200816, tasks-axi 0.2.6, load average ~12.6
(a Virtualization.framework VM and a Backblaze sync were running).

## What fails

`bin/fm-captain-hold.sh complete <origin> --none` against an identical,
pre-built fixture home whose answered captain call has been pruned into
`data/done-archive.md`, replayed on a fresh copy of the same home each time:

| code under test | runs | failures |
|---|---|---|
| target 957a8d98 | 60 | 5 (refusal: "no archived Done row ... records an answer") |
| target 957a8d98 | 60 | 3 (same) |
| target 957a8d98 | 20 | 2 (same) |
| target 957a8d98, same fixture but the answered row still LIVE (not pruned) | 60 | 0 |
| base 6ee9e824, same fixture but the answered row still LIVE | 60 | 0 |
| base 6ee9e824, pruned fixture (expected refusal either way) | 60 | 2 crashed with **rc=139 and empty stderr** |
| target 957a8d98 under `/bin/bash` 3.2.57 instead of Homebrew bash 5.3.15 | 40 | 0 |

## Root cause is not the new archive reader

Instrumenting a private copy of `bin/fm-captain-hold.sh` showed the failing
runs lose a forked subshell to signal 11:

```
57 AWKRC=0          <- the archive awk itself exited 0
 3 SUBRC=139        <- its enclosing $( ) subshell died with SIGSEGV
```

A **dummy** `awk 'BEGIN { print "dummy" }' </dev/null` command substitution
inserted at the top of the same function died in exactly the same 3 runs:

```
57 DUMMYAWKRC=0
 3 DUMMYSUBRC=139
```

No `TERM`/`HUP`/`INT` reached the parent shell (logged traps stayed silent), and
the same function shape replayed 500x standalone never crashed, so the trigger
is the shell process state at that point, not the awk program or the new rule.
The base commit reaches the same absent-row lookup path and dies there outright
(rc=139, no message) at a comparable rate.

## Effect on this branch

`archive_has_resolution_record` treats a non-zero awk status as "no usable
archive", so a lost subshell surfaces as a refusal rather than a crash - the
closed-safe direction, but it means the three new regressions in
`tests/fm-captain-hold-lifecycle.test.sh` fail on this host about a third of
the time. 12 consecutive runs of just those three tests:

```
RUN 1: all 3 ok
RUN 2: all 3 ok
RUN 3 FAILED: not ok - the archived recorded answer did not satisfy completion
RUN 4: all 3 ok
RUN 5: all 3 ok
RUN 6: all 3 ok
RUN 7 FAILED: not ok - teardown refused the scout after its answered call was pruned:
              error: teardown refused: task record authorized directory cannot be resolved at .../state
RUN 8 FAILED: not ok - could not create the pruned-answer origin
RUN 9 FAILED: not ok - the archived recorded answer did not satisfy completion
RUN 10 FAILED: not ok - teardown refused the scout after its answered call was pruned:
               error: teardown refused: task record authorized directory cannot be resolved at .../state
RUN 11: all 3 ok
RUN 12: all 3 ok
```

Runs 7, 8 and 10 fail inside `bin/fm-teardown.sh` path resolution and inside
plain `tasks-axi add` - fixture code shared with dozens of pre-existing tests in
this file - which is further evidence the instability is host-wide rather than
specific to this change.
