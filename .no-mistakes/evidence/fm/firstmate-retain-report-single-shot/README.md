# Retain-replay: three consolidated defects, shown at the operator surface

Environment: `tasks-axi` is not installed on this host, so the whole
`tests/fm-backlog-atomicity.test.sh` suite self-skips. It was installed into an
ephemeral prefix (`npm install --prefix /tmp/... tasks-axi@0.2.6`, above the
0.2.4 compatibility floor) and put on `PATH` for these runs, so every transcript
and test below drove the REAL backlog CLI, real markdown backlog, and real
`data/done-archive.md`.

## What the two transcripts show

Same operator steps, same fixtures, only `bin/` differs.

| | `retain-replay-session-transcript-before.txt` (base `6ad419da`) | `retain-replay-session-transcript-after.txt` (head `dbc3e9c8`) |
|---|---|---|
| **1. answered call, cleanup interrupted** | `finished the interrupted cleanup ...` — false: the task's own `.meta` is still on disk | `the captain had already answered the call ... before cleanup finished; its endpoint or local copy may remain and should be reconciled` |
| **2. unresolved retain deliverable** | reported once at session start 1, `state/` left empty, then **silent forever**; PR 16 is unrecoverable | durable `state/<id>.backlog-reconcile` written; the line repeats on session start 2 and in a read-only (`FM_BOOTSTRAP_DETECT_ONLY=1`) start; a mistyped `ack` refuses without touching the record; `ack <id>` prints `acked:` and the next start is silent |
| **3. answer that aged into the archive** | mis-read as "its backlog row no longer exists" — the captain is sent to re-decide a call he already answered | archive probe finds the `## Archived` row and reports the answer; no reconcile record manufactured |
| **3b. same slug re-filed later** | (no archive probe exists) | the stale archived line does **not** answer for the new work — escalates with PR 31 and a durable record |

The pre-fix transcript uses the pre-fix marker schema (no `recorded_utc` field,
which this change introduces), so each scenario reaches the old code path rather
than dying in validation.

## Test runs

`targeted-tests.txt` — the 15 intent-owning cases of
`tests/fm-backlog-atomicity.test.sh`, post-fix.

`prefix-regression.txt` — the same cases against base `bin/`: one per intent
reproduces the reported failure, so these are genuine regression tests.

`replay-family-regression.txt` — every replay/recovery case in that suite (the
family the changed library owns), post-fix, as regression scope.

`captain-hold-retain-family.txt` — the captain-hold retention cases from
`tests/fm-captain-hold-lifecycle.test.sh`, including
`an answer before cleanup replay preserves the retained report`, which the
intent names as one of the three walls this change had to work around without
breaking.

`reconcile-cli-surface.txt` — the new `bin/fm-backlog-reconcile.sh` entrypoint's
own operator surface: `--help`, a bare invocation, an unsafe id, and an `ack`
for an id with no record (each refuses with a named reason rather than
pretending to have retired something).
