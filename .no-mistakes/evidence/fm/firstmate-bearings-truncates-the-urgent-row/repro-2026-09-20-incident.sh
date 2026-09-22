#!/usr/bin/env bash
# Manual end-to-end reproduction of the 2026-09-20 bearings incident described in
# the change's intent: 26 queued gates, 19 of them filed on the SAME day, the
# default Charted Next bound of 20 - and the one row the captain was actively
# blocked on (cowork-refine-job-unattended-commit-and-timeout, named in his live
# captain hold) falling into the 6 the digest dropped behind "gates showing 20 of 26".
#
# Drives the real bin/fm-bearings-snapshot.sh CLI twice over one identical home:
# once with the pre-fix wrapper (base commit 74044a4) and once with the shipped one.
set -u
WORKTREE=/Users/crossbow/.no-mistakes/worktrees/00644a303d6a/01M33JA0BYH32XTJA0RRRDW86Y
. "$WORKTREE/tests/lib.sh"
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bearings-repro)
export FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"; mkdir -p "$FM_ROOT_OVERRIDE"

HOME_DIR="$TMP_ROOT/captains-home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/config"
: > "$HOME_DIR/data/secondmates.md"

FB=$(fm_fakebin "$HOME_DIR")
for t in no-mistakes tmux gh gh-axi curl; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/$t"; chmod +x "$FB/$t"
done

# --- the captain's backlog on the night of 2026-09-20 ------------------------
{
  printf '## In flight\n\n## Queued\n'
  # 7 rows filed the NEXT day up the list - genuinely newer, and correctly kept.
  for i in 1 2 3 4 5 6 7; do
    printf -- '- [ ] newer-item-%02d - Newer item %02d (repo: firstmate) (kind: ship) (since 2026-09-21)\n' "$i" "$i"
  done
  # The same-day cluster of 19. Filed date cannot discriminate inside it at all.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    printf -- '- [ ] sameday-item-%02d - Same-day item %02d (repo: firstmate) (kind: ship) (since 2026-09-20)\n' "$i" "$i"
  done
  cat <<'ROWS'
- [ ] cowork-refine-job-unattended-commit-and-timeout - Fix the unattended commit and timeout in the refine job (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] sameday-item-15 - Same-day item 15 (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] sameday-item-16 - Same-day item 16 (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] sameday-item-17 - Same-day item 17 (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] sameday-item-18 - Same-day item 18 (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] sameday-item-19 - Same-day item 19 (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] enable-nightly-schedule - Enable the nightly scheduled job (repo: firstmate) (kind: captain) (since 2026-09-20) (hold: waiting on the refine-job fix) (hold-kind: captain)
  Captain hold set: 2026-09-20T18:00:00Z
  Tonight's scheduled run is the whole point of this week, and it will hang on the
  unattended commit the moment it fires, so nothing else on this list matters until
  that is cleared.
  Waiting on cowork-refine-job-unattended-commit-and-timeout before enabling it.

## Done
ROWS
} > "$HOME_DIR/data/backlog.md"

emit() {  # <label> <wrapper> <extra args...>
  local label=$1 wrapper=$2; shift 2
  printf '\n========================= %s =========================\n' "$label"
  printf '$ FM_BEARINGS_GATES=20 (default)  bin/%s %s\n\n' "$(basename "$wrapper")" "$*"
  PATH="$FB:$PATH" refresh_local_secondmate_ledgers "$HOME_DIR" >/dev/null 2>&1
  PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_BEARINGS_NOW=2026-09-20T22:00:00Z \
    NET_LOG="$HOME_DIR/net.log" "$wrapper" "$@" 2>&1
}

# The wrapper resolves its sibling libraries from its own directory, so the
# pre-fix copy has to live in bin/ alongside them. It is materialized from git
# here and removed on exit, leaving the worktree clean.
BASE="$ROOT/bin/zz-bearings-base.sh"
FIXED="$ROOT/bin/fm-bearings-snapshot.sh"
git -C "$ROOT" show 74044a42331c760d104a2ee2b81b8def04b4c175:bin/fm-bearings-snapshot.sh > "$BASE"
chmod +x "$BASE"
trap 'rm -f "$BASE"' EXIT

emit "BEFORE THE FIX (wrapper at base commit 74044a4)" "$BASE"
emit "AFTER THE FIX (wrapper as shipped)" "$FIXED"

# --- Scenario B ---------------------------------------------------------------
# The human-readable omitted[] line is bounded prose and cannot name every retained
# row once ids are realistic. A board composer that must carry all of them reads the
# structured gates_retained field instead. Five rows retained under a bound of 1.
HOME_B="$TMP_ROOT/captains-home-b"
mkdir -p "$HOME_B/state" "$HOME_B/data" "$HOME_B/projects" "$HOME_B/config"
: > "$HOME_B/data/secondmates.md"
cat > "$HOME_B/data/backlog.md" <<'ROWS'
## In flight

## Queued
- [ ] top-gate - Newest filed gate (repo: firstmate) (kind: ship) (since 2026-09-21)
- [ ] cowork-refine-job-unattended-commit-and-timeout - Unattended commit and timeout (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] cowork-refine-job-signing-and-retry-backoff-path - Signing and retry backoff (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] cowork-refine-job-log-rotation-and-disk-pressure - Log rotation and disk pressure (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] cowork-refine-job-secret-rotation-and-key-escrow - Secret rotation and key escrow (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] cowork-refine-job-timeout-budget-and-kill-switch - Timeout budget and kill switch (repo: firstmate) (kind: ship) (since 2026-09-20)
- [ ] enable-nightly-schedule - Enable the nightly scheduled job (repo: firstmate) (kind: captain) (since 2026-09-20) (hold: waiting on the refine work) (hold-kind: captain)
  Captain hold set: 2026-09-20T18:00:00Z
  Waiting on cowork-refine-job-unattended-commit-and-timeout, cowork-refine-job-signing-and-retry-backoff-path, cowork-refine-job-log-rotation-and-disk-pressure, cowork-refine-job-secret-rotation-and-key-escrow and cowork-refine-job-timeout-budget-and-kill-switch before enabling it.

## Done
ROWS

printf '\n========================= SCENARIO B: five retained rows under FM_BEARINGS_GATES=1 =========================\n'
printf '$ FM_BEARINGS_GATES=1 bin/fm-bearings-snapshot.sh --json | jq "{gates, gates_retained, omitted}"\n\n'
PATH="$FB:$PATH" refresh_local_secondmate_ledgers "$HOME_B" >/dev/null 2>&1
PATH="$FB:$PATH" FM_HOME="$HOME_B" FM_BEARINGS_NOW=2026-09-20T22:00:00Z \
  NET_LOG="$HOME_B/net.log" FM_BEARINGS_GATES=1 "$FIXED" --json 2>&1 \
  | jq '{gates:[.gates[].id], gates_retained, omitted:[.omitted[].surface | select(startswith("gates"))]}'
