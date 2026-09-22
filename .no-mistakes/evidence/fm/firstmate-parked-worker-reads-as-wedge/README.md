# Parked worker read as a wedge — end-to-end evidence

`parked-worker-wedge-repro.sh` drives the **real** `bin/fm-watch.sh` and the **real**
`bin/fm-crew-state.sh`. The only fakes are the terminal multiplexer and the
`no-mistakes` CLI, which replays the exact `axi status --run <id>` record the
supervisor saw at the third escalation on 2026-09-20
(`review, fixing, active_for 29m53s, last_activity 5s, agent_pid 83267, round "fix 2"`).
The worker's pane is parked on a monitor: it renders the same bytes every poll.

Run as `TREE=<firstmate checkout> parked-worker-wedge-repro.sh <ladder|quiet|resurface>`.

| file | tree | shows |
| --- | --- | --- |
| `01-before-fix-ladder.txt` | base `2e9903c` | the reported false positive: three crossings of the 240s wedge threshold produce escalations 1, 2, 3, the third carrying `demand-deep-inspection`, each costing a drained supervision turn — while `axi status` reports 5s of activity |
| `02-after-fix-ladder.txt` | `e25b566` | the same three crossings absorbed silently: no wake reason, no queued wake, no handling turn; the watcher's triage log records `absorbed non-terminal stale (live no-mistakes run reports recent activity, idle 251s)` |
| `03-after-fix-quiet-run-still-escalates.txt` | `e25b566` | safety direction: the same run after it genuinely stopped logging (`last_activity "quiet 31m2s"`) still escalates 1, 2, 3 and still reaches `demand-deep-inspection` |
| `04-after-fix-bounded-resurface.txt` | `e25b566` | a deferral held past `FM_PAUSE_RESURFACE_SECS` re-surfaces once, naming the run's reported activity rather than a wedge, without advancing the escalation ladder |

Note in `01` vs `02` the `bin/fm-crew-state.sh` verdict line firstmate reads each
heartbeat: base emits `state: working · source: run-step · validating (fixing)`;
after the change the same run emits `... · activity: recent`, the positive fact the
wedge timer consults.
