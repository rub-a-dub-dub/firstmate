# Round 2 re-verification: contended per-home relaunch lock is a skip, not a failure

Target `2a0369da` (fix `2653f06e` + the polled contention test). Same scenario
both arms: secondmate `sm1`'s endpoint is agent-free (relaunchable) while a
separate live process already holds `$STATE/.secondmate-relaunch.lock`, and the
tick's bounded wait (`FM_SECONDMATE_LIVENESS_TIMEOUT=1`) expires against that
proven holder. The real `bin/fm-watch.sh` runs in both arms; only
`bin/fm-watch.sh` + `bin/fm-secondmate-liveness-lib.sh` differ.

| operator-visible surface | before (`faa048db`) | after (`2a0369da`) |
| --- | --- | --- |
| watcher process | **EXITED** — supervision lost | still running, keeps ticking |
| watcher stderr | `watcher: secondmate liveness check failed` | empty |
| `$STATE/.watch-triage.log` | `secondmate sm1 liveness **error**: …` | `secondmate sm1 liveness: …` (once per retried tick) |
| `$STATE/.wake-queue` | empty | empty |
| `$STATE/.secondmate-relaunch-sm1` | absent (no attempt) | absent (no attempt) |
| tmux kill-window / new-window | none | none |

The after-arm triage log shows the line twice: the tick left the endpoint
exactly as found and the next cadence retried, which is the "wait-and-retry"
behaviour the intent asks for. Parity target confirmed by inspection:
`bin/fm-bootstrap.sh:772` already renders the same skip as
`SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>`, never a failure.

Full transcripts: `watcher-contention-before-fix.txt`, `watcher-contention-after-fix.txt`.
Round 1's longer 25s-observation transcripts are in `relaunch-lock-contention.md`.
