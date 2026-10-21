# 'Behavior portable serial' on the fork's CI, before and after the repack

All figures below come from the fork's own GitHub Actions runs (rub-a-dub-dub/firstmate),
read through the Actions API; no run was triggered for this check.

## Before: shard 2 cancelled at the 30-minute job cap

| Run | Trigger | Behavior portable serial 2 | Wall clock |
|---|---|---|---|
| [39613397657](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39613397657) | push to main | **cancelled** | 30m17s (14:03:14 -> 14:33:31Z) |
| [39617554991](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39617554991) | pull request 46 | **cancelled** | 30m16s (15:40:04 -> 16:10:20Z) |

Every other serial shard in those runs finished in 14-21 minutes, so shard 2 alone
hit the cap. The job was still reporting passing tests when it was killed, and PR 46
could not merge.

## After: the repacked partition, run [39644788352](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39644788352)

Branch `fm/firstmate-ci-portable-serial-2-near-timeout`, commit `fabae491` of this change.
All nine serial shards completed green; the figures are from each shard's uploaded
`fm-test-timing-portable-serial-*` artifact.

| Shard | Scripts | Measured lane time | Failures | Slowest script |
|---|---|---|---|---|
| 1 | 1 | 28m32s (1712691 ms) | 0 | `tests/fm-supervision-host.test.sh` 1711444 ms |
| 2 | 1 | 16m54s (1014545 ms) | 0 | `tests/fm-watch-triage.test.sh` 1013674 ms |
| 3 | 30 | 19m14s (1154762 ms) | 0 | `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` 475299 ms |
| 4 | 31 | 16m08s (968403 ms) | 0 | `tests/fm-public-followup.test.sh` 364652 ms |
| 5 | 30 | 14m49s (889287 ms) | 0 | `tests/fm-session-start.test.sh` 240041 ms |
| 6 | 31 | 18m22s (1102853 ms) | 0 | `tests/fm-procevent.test.sh` 293982 ms |
| 7 | 31 | 17m08s (1028595 ms) | 0 | `tests/fm-pr-check-security.test.sh` 280767 ms |
| 8 | 29 | 17m46s (1066880 ms) | 0 | `tests/fm-spawn-dispatch-profile.test.sh` 267483 ms |
| 9 | 30 | 20m29s (1229986 ms) | 0 | `tests/fm-backlog-atomicity.test.sh` 286351 ms |

| Job | Outcome | Job wall clock |
|---|---|---|
| Behavior portable serial 1 | success | 29m34s |
| Behavior portable serial 2 | success | 17m21s |
| Behavior portable serial 3 | success | 19m35s |
| Behavior portable serial 4 | success | 16m35s |
| Behavior portable serial 5 | success | 15m16s |
| Behavior portable serial 6 | success | 18m43s |
| Behavior portable serial 7 | success | 17m34s |
| Behavior portable serial 8 | success | 18m06s |
| Behavior portable serial 9 | success | 20m49s |

The job that used to be cancelled, `Behavior portable serial 2`, now finishes in
17m21s. The new worst shard is `Behavior portable serial 1`, which runs the
indivisible `tests/fm-supervision-host.test.sh` alone: 1711444 ms of script time in a
29m34s job, about 63 seconds of job overhead. That cleared the old 30-minute cap by
26 seconds, which is what the final commits of this change respond to: the host hint
is now its measured 1711444 ms, the packing target is 35 minutes, and the serial
shards run under their own 45-minute tier instead of the shared 30-minute one.

Note on scope: shards 1 and 2 (the two single-script shards) have exactly the
membership the current commit packs; raising the host hint from 1342826 to its
measured 1711444 ms reshuffled the seven mixed shards, which now model at 19m48s
each - inside the band those shards actually measured above (14m49s to 20m29s).
`Behavior portable parallel 2` failed in that run on
`tests/fm-captain-hold-lifecycle.test.sh`, a parallel-lane script this change does not
touch; that lane's composition and hints are unchanged.
