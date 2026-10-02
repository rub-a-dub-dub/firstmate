Evidence for: reconcile 18 new upstream commits into rub-a-dub-dub/firstmate and
land it as a REAL merge so upstream history is recorded.

01-merge-ancestry.txt
    The deliverable itself. Two real two-parent merges; every one of the 18 new
    upstream commits is an ancestor of HEAD; the count of upstream-main commits
    the fork does not record goes 238 -> 0.

02-steering-doorbell.txt
    Upstream #6240 plus the fork's own doorbell rewording, at the product
    surface: the exact line bin/fm-task-inbox-lib.sh emits for a realistic
    40-character task id, before and after, in a shallow and a deep home, and a
    real bin/fm-send.sh run against a real tmux pane.

03-captain-hold-archived-origin-cli.txt
    Upstream #6331 plus the fork's archived-origin binding, driven end to end
    through the real bin/fm-captain-hold.sh, the real bin/fm-teardown.sh and the
    real external tasks-axi 0.2.6: a pruned answered call refuses the wrong
    origin (and refuses that scout's teardown) and completes for its own.

04-supervision-host-gate-6154.txt
    The standing issue-5269 escalation item. Upstream #6154 changes the
    supervision-host home gate; this is the before/after truth table from the
    real fm_supervision_host_enabled, plus the reachability check for this fleet.

05-upstream-behaviour-coverage.txt
    The behaviour assertions that ran green for #5263, #6306, #6221, #6307 and
    #6255.

06-host-flakiness.txt
    Why four watcher/supervision/inbox suites could not be driven to a stable
    green on this machine, with the base-commit comparison and the measured
    root cause.
