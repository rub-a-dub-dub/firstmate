# Contended per-home relaunch lock: watcher-exit path

Same scenario both arms: secondmate `sm1` is agent-free (relaunchable) while
another mate already holds `state/.secondmate-relaunch.lock`; the tick's
bounded wait (`FM_SECONDMATE_LIVENESS_TIMEOUT=1`) expires against a live holder.

```
### ARM: before (base faa048db)
scenario: secondmate sm1's endpoint is agent-free (dead); another mate's
          relaunch already holds /private/var/folders/f_/hcy8g0q91p9fdyghn_9ypx5r0000gn/T/fm-wake-tests.oryGra/evidence-before (base faa048db)/state/.secondmate-relaunch.lock

competing relaunch holds the per-home lock (pid 18309)

watcher started (pid 18346); observing 25s of liveness ticks
  t=15s  WATCHER EXITED

--- watcher stderr (what the captain sees) ---
  watcher: secondmate sm1 liveness: another secondmate relaunch still owns the per-home relaunch lock after 1s (live process 18309); endpoint left dead
  watcher: secondmate liveness check failed

--- watcher stdout (captain-facing wake) ---
  (empty - no wake)

--- state/.watch-triage.log ---
  [2026-10-15T23:51:58+0200] secondmate sm1 liveness error: another secondmate relaunch still owns the per-home relaunch lock after 1s (live process 18309); endpoint left dead

--- endpoint mutation: tmux kill-window/new-window calls ---
  (none)
--- relaunch ledger state/.secondmate-relaunch-sm1 ---
  (no attempt recorded)
--- durable wake queue state/.wake-queue ---
  (empty)



### ARM: after (fix 2653f06e)
scenario: secondmate sm1's endpoint is agent-free (dead); another mate's
          relaunch already holds /private/var/folders/f_/hcy8g0q91p9fdyghn_9ypx5r0000gn/T/fm-wake-tests.vll9Z1/evidence-after (fix 2653f06e)/state/.secondmate-relaunch.lock

competing relaunch holds the per-home lock (pid 28244)

watcher started (pid 28423); observing 25s of liveness ticks
  t=25s  watcher still running

--- watcher stderr (what the captain sees) ---
  (empty - no failure reported)

--- watcher stdout (captain-facing wake) ---
  (empty - no wake)

--- state/.watch-triage.log ---
  [2026-10-15T23:52:20+0200] secondmate sm1 liveness: another secondmate relaunch still owns the per-home relaunch lock after 1s (live process 28244); endpoint left dead
  [2026-10-15T23:52:29+0200] secondmate sm1 liveness: another secondmate relaunch still owns the per-home relaunch lock after 1s (live process 28244); endpoint left dead
  [2026-10-15T23:52:37+0200] secondmate sm1 liveness: another secondmate relaunch still owns the per-home relaunch lock after 1s (live process 28244); endpoint left dead

--- endpoint mutation: tmux kill-window/new-window calls ---
  (none)
--- relaunch ledger state/.secondmate-relaunch-sm1 ---
  (no attempt recorded)
--- durable wake queue state/.wake-queue ---
  (empty)

```
