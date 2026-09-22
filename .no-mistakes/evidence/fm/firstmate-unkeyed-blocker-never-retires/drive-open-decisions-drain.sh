#!/usr/bin/env bash
# Drives the REAL bin/fm-wake-drain.sh (and bin/fm-send.sh) over a state dir
# that reproduces the three stale-row instances from the captain's report, and
# prints the OPEN DECISIONS section a captain actually reads.
set -u
ROOT=$1          # repo worktree
LABEL=$2         # "BEFORE" / "AFTER"
HOME_DIR=$(mktemp -d)
STATE="$HOME_DIR/state"; mkdir -p "$STATE"

# Instance 1 - firstmate-detect-dropped-ci-event: unkeyed blocked, long since
# resolved by moving to a fresh branch; task went on to report done + paused.
{
  printf 'blocked: no-mistakes axi run refuses to push the rebased branch to its internal gate mirror\n'
  printf 'working: moved the work to a fresh branch\n'
  printf 'done: PR 12 green at 14/14\n'
  printf 'paused: captain-held\n'
} > "$STATE/firstmate-detect-dropped-ci-event.status"

# Instance 2 - firstmate-unreplayable-backlog-close: unkeyed blocked, work moved
# to a v2 branch and became PR 8; task re-appended a paused line.
{
  printf 'blocked: escape-the-branch remedy did not work either\n'
  printf 'working: restarted the work on a v2 branch\n'
  printf 'paused: captain-held\n'
} > "$STATE/firstmate-unreplayable-backlog-close.status"

# Instance 3 - spend-unattended-op-read-hangs: unkeyed needs-decision answered in
# chat; the worker's resolved line carries a DIFFERENT key, then done.
{
  printf 'needs-decision: how should the worker proceed with the stale skills directory?\n'
  printf 'resolved [key=skills-directory-stale]: use the refreshed directory\n'
  printf 'done: pull request went green\n'
} > "$STATE/spend-unattended-op-read-hangs.status"

# Control A - a genuinely open KEYED captain decision: must keep folding open.
printf 'needs-decision [key=api-shape]: pick REST or RPC\nworking: continuing elsewhere\n' \
  > "$STATE/ios-shell.status"

# Control B - a genuinely open UNKEYED blocker with no terminal line after it:
# must keep folding open, and must now print a key the footer's command can use.
printf 'blocked: waiting on release credentials\n' > "$STATE/release-cut.status"

drain() {  # retry around an unrelated host flake (/usr/bin/stat segfaults
           # intermittently on this machine, see testing notes)
  local i out
  for i in 1 2 3 4 5 6 7 8; do
    out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
    case "$out" in *'PRESENTATION INCOMPLETE'*) continue ;; esac
    printf '%s\n' "$out"; return 0
  done
  printf '%s\n' "$out"
}

echo "===== $LABEL: bin/fm-wake-drain.sh (what the captain reads) ====="
echo "\$ FM_STATE_OVERRIDE=<state> bin/fm-wake-drain.sh"
drain
echo

if [ "$LABEL" = AFTER ]; then
  # The footer names --resolve-key <key> as the ONE way to close a listed row.
  # Fill it in literally for the unkeyed row, using the real fm-send.
  fb="$HOME_DIR/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x95\xad----\xe2\x95\xae\n|    |\n\xe2\x95\xb0----\xe2\x95\xaf\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-release-cut; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/sleep"
  printf 'window=sess:fm-release-cut\nkind=ship\n' > "$STATE/release-cut.meta"

  echo "===== AFTER: the footer's own command, filled in from the row above ====="
  echo "\$ bin/fm-send.sh release-cut --resolve-key default 'credentials rotated, go'"
  env PATH="$fb:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
      FM_SEND_LOG="$HOME_DIR/send.log" FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-send.sh" release-cut --resolve-key default 'credentials rotated, go' 2>/dev/null
  echo "(exit $?)"
  echo
  echo "--- state/release-cut.status after the send ---"
  cat "$STATE/release-cut.status"
  echo
  echo "===== AFTER: drain again - the answered row is gone ====="
  drain
fi
rm -rf "$HOME_DIR"
