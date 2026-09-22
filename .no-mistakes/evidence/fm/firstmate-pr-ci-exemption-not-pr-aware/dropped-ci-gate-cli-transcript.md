# `bin/fm-pr-merge.sh` — dropped-CI gate, before vs after

Each block is the real stderr `bin/fm-pr-merge.sh` writes to the operator, captured
while running `tests/fm-pr-merge.test.sh`'s fixtures (mocked `gh`, real script).
"Before" runs the base commit's copy of the script (`2e9903c`) against the identical
fixture; "after" runs the branch's script (`c7a4fa7`).

---

## Intent case 1 — `on: pull_request: paths: ['src/**']`, PR touches only README

BEFORE (base 2e9903c) — deadlocked, and `--allow-red` cannot waive it:

    error: refusing to merge https://github.com/example/repo/pull/120
      - no pull_request-triggered check has reported for head 9a9a...9a, and its commit is
        already past the delivery grace window: wait and retry this merge first, because a run
        still on its way looks identical here once the commit has aged out of the window, and
        treat it as a suspected dropped CI event only if a retry still finds none. Neither is
        ever treated as green

AFTER (branch c7a4fa7) — the gate stands down, names why, and the merge proceeds:

    note: no pull_request-triggered workflow applies to this pull request - ci.yml (paths filter)
      confirmed it is skipped at base main - so the dropped-CI-event check is disarmed for this
      merge attempt
    verified: https://github.com/example/repo/pull/120 is open and mergeable, with every required
      check green at head 9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a

---

## Intent case 2 — `pull_request: branches: [main]`, PR based on `release-1.0`

(the intent's "THIS REPO's own .github/workflows/ci.yml" case)

BEFORE (base 2e9903c):

    error: refusing to merge https://github.com/example/repo/pull/121
      - no pull_request-triggered check has reported for head 9b9b...9b, and its commit is
        already past the delivery grace window: ... Neither is ever treated as green

AFTER (branch c7a4fa7):

    note: no pull_request-triggered workflow applies to this pull request - ci.yml (branches filter)
      confirmed it is skipped at base release-1.0 - so the dropped-CI-event check is disarmed for
      this merge attempt
    verified: https://github.com/example/repo/pull/121 is open and mergeable, with every required
      check green at head 9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b

---

## Intent case 3 — head commit and PR both older than the Actions run-retention window

BEFORE (base 2e9903c):

    error: refusing to merge https://github.com/example/repo/pull/130
      - no pull_request-triggered check has reported for head 7c7c...7c, and its commit is
        already past the delivery grace window: ... Neither is ever treated as green

AFTER (branch c7a4fa7):

    note: no pull_request-event run is recorded for head 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c
      and both its commit and this pull request are older than GitHub's Actions run retention
      window, so that absence is expired evidence rather than a confirmed one and the
      dropped-CI-event check is disarmed for this merge attempt
    verified: https://github.com/example/repo/pull/130 is open and mergeable, with every required
      check green at head 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c

---

## The conservative direction is preserved (the PR-34 defect stays closed)

A pull request whose changed files DO match the workflow's `paths` filter, with zero
pull_request-event runs at its head, still refuses — identically before and after:

    error: refusing to merge https://github.com/example/repo/pull/122
      - no pull_request-triggered check has reported for head 9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c,
        and its delivery is already past the grace window: wait and retry this merge first, because a
        run still on its way looks identical here once the delivery has aged out of the window, and
        treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever
        treated as green

Same refusal for a filter the scanner cannot evaluate confidently (`branches-ignore`,
character classes, `?` quantifiers, a wrapped/partial inline list, an unreadable or
capped changed-file list, and an unreadable merge ref) — every unevaluable read
resolves toward "covered", never toward exempting the merge.
