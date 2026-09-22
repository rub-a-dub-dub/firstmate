#!/usr/bin/env bash
# Evidence driver: run the real bin/fm-crew-state.sh against the run-record
# shapes from the two 2026-09-20 live incidents and print the exact supervisor-
# facing state line for each. Usage: driver.sh <path-to-fm-crew-state.sh>
set -u
CREW_STATE=$1
ROOT=$(cd "$(dirname "$CREW_STATE")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

mk_fakebin() {  # <dir>
  local fb=$1/fakebin; mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift; case "${1:-}" in
      status) shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status) [ "${2:-}" = --json ] && { printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'; exit 0; } ;;
  server) exit 0 ;;
  pane) case "${2:-}" in
      read) printf 'all quiet\n> \n'; exit 0 ;;
      get) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"; exit 0 ;;
      process-info)
        pane=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "$PPID"
        exit 0 ;;
    esac ;;
  agent) case "${2:-}" in
      get) printf '{"result":{"agent":{"agent_status":"idle"}}}\n'; exit 0 ;;
    esac ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr"
}

scenario() {  # <slug> <pr> <pr_state-line> <outcome>
  local slug=$1 pr=$2 pr_state_line=$3 outcome=$4
  local d="$TMP/$slug" branch="fm/$slug"
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" config commit.gpgsign false
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b "$branch"
  local head; head=$(git -C "$d/wt" rev-parse HEAD)
  mk_fakebin "$d"
  printf 'window=fm:fm-%s\nworktree=%s\nkind=ship\n' "$slug" "$d/wt" > "$d/state/$slug.meta"
  local status_block
  status_block=$(printf 'run:\n  id: "01RUN"\n  branch: %s\n  status: completed\n  head: "%s"\n  pr: "%s"\n%s  findings: none\noutcome: %s\n' \
    "$branch" "$head" "$pr" "$pr_state_line" "$outcome")
  echo "--- run record fm-crew-state reads (no-mistakes axi status) ---"
  printf '%s\n' "$status_block" | sed 's/^/    /'
  echo "--- supervisor-facing output: fm-crew-state.sh $slug ---"
  FM_FAKE_AXI_STATUS="$status_block" \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    "$CREW_STATE" "$slug" | sed 's/^/    /'
  echo
}

echo "############ fm-crew-state.sh under test: $CREW_STATE"
echo "############ version label: ${LABEL:-$( (cd "$ROOT" && git log -1 --format='%h %s') 2>/dev/null || echo 'baseline copy' )}"
echo
echo "=== A. live incident: firstmate-lint-debt-blocking-prs (outcome=passed, pr_state=open) ==="
scenario lint-debt-blocking-prs "https://github.com/o/r/pull/1" '  pr_state: open
' passed

echo "=== B. live incident: firstmate-detect-dropped-ci-event (outcome=passed-with-override) ==="
scenario detect-dropped-ci-event "https://github.com/o/r/pull/2" '  pr_state: open
' passed-with-override

echo "=== C. genuinely merged PR (outcome=passed, pr_state=merged) ==="
scenario really-merged "https://github.com/o/r/pull/3" '  pr_state: merged
' passed

echo "=== D. no PR ever opened (outcome=passed, pr_state=none) ==="
scenario no-pr-opened "" '  pr_state: none
' passed

echo "=== E. older no-mistakes with no pr_state field at all (outcome=passed) ==="
scenario absent-pr-state "https://github.com/o/r/pull/5" '' passed
