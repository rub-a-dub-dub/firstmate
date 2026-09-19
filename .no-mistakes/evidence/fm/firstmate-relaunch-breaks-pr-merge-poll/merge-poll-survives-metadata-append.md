# Merge poll survives an appended metadata record

Each transcript below drives the real firstmate binaries against a fixture home:
`bin/fm-pr-check.sh` arms the merge poll for a PR, a metadata writer appends to
`state/task-a.meta`, and `bin/fm-watch.sh` then runs against a PR that has just
been merged upstream. The only difference between BEFORE and AFTER is
`bin/fm-pr-lib.sh` at the base commit (6f4c112) vs. the change under test
(ac8a55a). Temp fixture paths are normalized to `<FM_HOME>`.

The line that matters is the last one: BEFORE, firstmate emits the misleading
"rejected unauthenticated state checks" wake and never notices the merge; AFTER,
it reports the merge.

--------------------------------------------------------------------------------
## Writer 1 - `fm-control.sh relaunch` (appends `control_relaunch_tx=`)

### BEFORE (base commit 6f4c112)
```
$ fm-pr-check.sh task-a https://github.com/o/r/pull/1
  armed: state/task-a.check.sh

--- state/task-a.meta (merge poll armed) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567

$ fm-control.sh relaunch task-a   # bin/fm-spawn.sh preserve_relaunch_meta re-emits pr=, then appends control_relaunch_tx=

--- state/task-a.meta (after the append) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567
  control_relaunch_tx=r1758240000.1.1

$ fm-watch.sh   # the PR has just landed upstream (gh reports MERGED)
  check: rejected unauthenticated state checks: <FM_HOME>/home/state/task-a.check.sh

(fm-watch.sh exited)
```

### AFTER (change under test ac8a55a)
```
$ fm-pr-check.sh task-a https://github.com/o/r/pull/1
  armed: state/task-a.check.sh

--- state/task-a.meta (merge poll armed) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567

$ fm-control.sh relaunch task-a   # bin/fm-spawn.sh preserve_relaunch_meta re-emits pr=, then appends control_relaunch_tx=

--- state/task-a.meta (after the append) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567
  control_relaunch_tx=r1758240000.1.1

$ fm-watch.sh   # the PR has just landed upstream (gh reports MERGED)
  check: <FM_HOME>/home/state/task-a.check.sh: merged

(fm-watch.sh exited)
```

--------------------------------------------------------------------------------
## Writer 2 - `fm-captain-hold.sh complete` (appends `decisions_reviewed=` / `decision_keys=`)

### BEFORE (base commit 6f4c112)
```
$ fm-pr-check.sh task-a https://github.com/o/r/pull/1
  armed: state/task-a.check.sh

--- state/task-a.meta (merge poll armed) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567

$ fm-captain-hold.sh complete task-a   # bin/fm-captain-hold.sh appends decisions_reviewed= / decision_keys= after pr=

--- state/task-a.meta (after the append) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567
  decisions_reviewed=1
  decision_keys=example-key

$ fm-watch.sh   # the PR has just landed upstream (gh reports MERGED)
  check: rejected unauthenticated state checks: <FM_HOME>/home/state/task-a.check.sh

(fm-watch.sh exited)
```

### AFTER (change under test ac8a55a)
```
$ fm-pr-check.sh task-a https://github.com/o/r/pull/1
  armed: state/task-a.check.sh

--- state/task-a.meta (merge poll armed) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567

$ fm-captain-hold.sh complete task-a   # bin/fm-captain-hold.sh appends decisions_reviewed= / decision_keys= after pr=

--- state/task-a.meta (after the append) ---
  window=firstmate:fm-task-a
  endpoint_task_id=task-a
  worktree=<FM_HOME>/wt
  project=<FM_HOME>/project
  kind=ship
  mode=no-mistakes
  pr=https://github.com/o/r/pull/1
  pr_head=0123456789abcdef0123456789abcdef01234567
  decisions_reviewed=1
  decision_keys=example-key

$ fm-watch.sh   # the PR has just landed upstream (gh reports MERGED)
  check: <FM_HOME>/home/state/task-a.check.sh: merged

(fm-watch.sh exited)
```
