# `bin/fm-pr-merge.sh` - dropped-CI gate, per-pull-request applicability

Real CLI runs of the merge gate against mocked GitHub reads, for the three
cases the intent names plus the two that must NOT change. Each pull request
below has **zero** `pull_request` Actions runs at its head.

## Case 1 - paths-filtered workflow, PR touches only README

`on: pull_request: paths: ['src/**']`; the pull request changes only `README.md`, so GitHub creates no run by construction.

### Before (base commit 2e9903c)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/120
error: refusing to merge https://github.com/example/repo/pull/120
  - no pull_request-triggered check has reported for head 9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a, and its commit is already past the delivery grace window: wait and retry this merge first, because a run still on its way looks identical here once the commit has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

### After (this branch)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/120
note: no pull_request-triggered workflow applies to this pull request - ci.yml (paths filter) confirmed it is skipped at base main - so the dropped-CI-event check is disarmed for this merge attempt
verified: https://github.com/example/repo/pull/120 is open and mergeable, with every required check green at head 9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a
armed: state/task-x1.check.sh
verified: https://github.com/example/repo/pull/120 is merged (state=MERGED, merged=true, isInMergeQueue=false)
exit status: 0
```
_forge call made:_ `gh pr merge 120 --repo example/repo --match-head-commit 9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a --squash`

## Case 2 - branches-filtered workflow, non-main base

This repository's own `.github/workflows/ci.yml` shape: `on: pull_request: branches: [main]`, with a pull request based on `release-1.0`.

### Before (base commit 2e9903c)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/121
error: refusing to merge https://github.com/example/repo/pull/121
  - no pull_request-triggered check has reported for head 9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b, and its commit is already past the delivery grace window: wait and retry this merge first, because a run still on its way looks identical here once the commit has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

### After (this branch)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/121
note: no pull_request-triggered workflow applies to this pull request - ci.yml (branches filter) confirmed it is skipped at base release-1.0 - so the dropped-CI-event check is disarmed for this merge attempt
verified: https://github.com/example/repo/pull/121 is open and mergeable, with every required check green at head 9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b
armed: state/task-x1.check.sh
verified: https://github.com/example/repo/pull/121 is merged (state=MERGED, merged=true, isInMergeQueue=false)
exit status: 0
```
_forge call made:_ `gh pr merge 121 --repo example/repo --match-head-commit 9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b --squash`

## Case 3 - PR whose Actions runs aged past the retention window

Unfiltered `pull_request` trigger, but both the head commit and the pull request itself were created 214 days ago, so GitHub has purged the runs.

### Before (base commit 2e9903c)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/130
error: refusing to merge https://github.com/example/repo/pull/130
  - no pull_request-triggered check has reported for head 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c, and its commit is already past the delivery grace window: wait and retry this merge first, because a run still on its way looks identical here once the commit has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

### After (this branch)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/130
note: no pull_request-event run is recorded for head 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c and both its commit and this pull request are older than GitHub's Actions run retention window, so that absence is expired evidence rather than a confirmed one and the dropped-CI-event check is disarmed for this merge attempt
verified: https://github.com/example/repo/pull/130 is open and mergeable, with every required check green at head 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c
armed: state/task-x1.check.sh
verified: https://github.com/example/repo/pull/130 is merged (state=MERGED, merged=true, isInMergeQueue=false)
exit status: 0
```
_forge call made:_ `gh pr merge 130 --repo example/repo --match-head-commit 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c --squash`

## Guard A - covered PR still refuses

Same paths filter, but the pull request changes `src/foo.go`, so the trigger genuinely applies and the missing run is a suspected drop.

### Before (base commit 2e9903c)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/122
error: refusing to merge https://github.com/example/repo/pull/122
  - no pull_request-triggered check has reported for head 9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c, and its commit is already past the delivery grace window: wait and retry this merge first, because a run still on its way looks identical here once the commit has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

### After (this branch)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/122
error: refusing to merge https://github.com/example/repo/pull/122
  - no pull_request-triggered check has reported for head 9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c, and its delivery is already past the grace window: wait and retry this merge first, because a run still on its way looks identical here once the delivery has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

## Guard B - unevaluable filter still refuses

`paths: ['**/*.tsx?']` - GitHub's `?` is a quantifier the heuristic will not evaluate, so the pull request counts as covered and the gate stays armed.

### Before (base commit 2e9903c)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/123
error: refusing to merge https://github.com/example/repo/pull/123
  - no pull_request-triggered check has reported for head 8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f, and its commit is already past the delivery grace window: wait and retry this merge first, because a run still on its way looks identical here once the commit has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

### After (this branch)

```console
$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/123
error: refusing to merge https://github.com/example/repo/pull/123
  - no pull_request-triggered check has reported for head 8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f, and its delivery is already past the grace window: wait and retry this merge first, because a run still on its way looks identical here once the delivery has aged out of the window, and treat it as a suspected dropped CI event only if a retry still finds none. Neither is ever treated as green
armed: state/task-x1.check.sh
exit status: 1
```
_forge call made:_ none - the merge was refused before `gh pr merge`

