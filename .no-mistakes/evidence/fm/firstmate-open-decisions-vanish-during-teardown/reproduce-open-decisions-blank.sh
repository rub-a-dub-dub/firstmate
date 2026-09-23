#!/usr/bin/env bash
# Captain-facing reproduction of the reported incident, run against the REAL
# wake drain (bin/fm-wake-drain.sh) at two trees:
#   BEFORE = base commit a294591, AFTER = branch tip 5267a27.
# Usage: reproduce-open-decisions-blank.sh <tree> <label>
set -u
TREE=$1; LABEL=$2
DRAIN="$TREE/bin/fm-wake-drain.sh"
WORK=$(mktemp -d)
export FM_ROOT_OVERRIDE="$WORK/not-a-git-root"; mkdir -p "$FM_ROOT_OVERRIDE"

seed_fleet() {  # <state>
  local st=$1
  printf 'needs-decision [key=phone-design]: one skills dir per phone, or one shared?\nneeds-decision [key=directory-layout]: flat or nested skills directory?\nnote: still waiting on the captain\n' > "$st/cowork-skills-directory-phone-design-forks.status"
  printf 'needs-decision [key=default]: reconcile the fork with upstream how?\nnote: still waiting on the captain\n' > "$st/firstmate-reconcile-fork-with-upstream.status"
  printf 'blocked [key=default]: cannot replay this backlog close\nnote: still waiting on the captain\n' > "$st/firstmate-unreplayable-backlog-close.status"
}

banner() { printf '\n========== %s ==========\n' "$1"; }

printf '#### TREE: %s (%s)\n' "$LABEL" "$(cd "$TREE" && git rev-parse --short HEAD 2>/dev/null || echo 'extracted snapshot')"

### Scenario A - the recorded incident: four still-open captain calls, and one
### UNRELATED task's status read hiccups while the drain acknowledges what it
### presented.
STATE_A="$WORK/a"; mkdir -p "$STATE_A"
seed_fleet "$STATE_A"
printf 'working: no decision here, just routine progress\n' > "$STATE_A/zzz-unrelated-task.status"

banner "A1. drain BEFORE the hiccup - what the captain should always see"
FM_STATE_OVERRIDE="$STATE_A" "$DRAIN"

printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$WORK/fail-reader"; chmod +x "$WORK/fail-reader"

banner "A2. the very next drain, with one unrelated task's status read failing"
FM_STATE_OVERRIDE="$STATE_A" FM_STATUS_SPAN_READER="$WORK/fail-reader" "$DRAIN"
printf '[drain exit status: %s]\n' "$?"
printf '(above is the ENTIRE captain-facing output of that drain)\n'

banner "A3. the drain after that, hiccup cleared - all four calls still open"
FM_STATE_OVERRIDE="$STATE_A" "$DRAIN"

### Scenario B - a task torn down after its PR merged leaves a still-queued
### wake row pointing at a status file that no longer exists.
STATE_B="$WORK/b"; mkdir -p "$STATE_B"
seed_fleet "$STATE_B"
printf 'working: about to be torn down after its PR merged\n' > "$STATE_B/firstmate-bearings-truncates-the-urgent-row.status"
FM_STATE_OVERRIDE="$STATE_B" bash -c '. "$1"; fm_wake_append signal "firstmate-bearings-truncates-the-urgent-row.status" "signal: $2/firstmate-bearings-truncates-the-urgent-row.status"' \
  _ "$TREE/bin/fm-wake-lib.sh" "$STATE_B" >/dev/null
rm -f "$STATE_B/firstmate-bearings-truncates-the-urgent-row.status"

banner "B. drain immediately after that teardown"
FM_STATE_OVERRIDE="$STATE_B" "$DRAIN"
printf '(above is the ENTIRE captain-facing output of that drain)\n'
rm -rf "$WORK"
