#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified.
#   - The tmux classifier returns missing only after a readable session
#     inventory omits the exact window, regardless of display-message fallback.
#   - The Herdr classifier preserves the proven husk mapping while separating a
#     missing pane from an existing agent-less pane.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep recovers only dead or
#     missing endpoints, keeps successful recovery and already-live results
#     silent by default, and reports ambiguous and unreadable targets distinctly.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_state --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_failed_probe_tmux <dir> <inventory>: missing and present fail the pane
# read, while unreadable returns a misleading fallback node process but fails
# the inventory that must be authoritative.
make_failed_probe_tmux() {
  local dir=$1 inventory=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    [ '$inventory' = unreadable ] && { printf '%s\n' node; exit 0; }
    exit 1
    ;;
  list-windows)
    case '$inventory' in
      missing) printf '%s\n' main ; exit 0 ;;
      missing-session) printf '%s\n' "can't find session: sess" >&2; exit 1 ;;
      missing-server) printf '%s\n' "no server running on /tmp/tmux-test/default" >&2; exit 1 ;;
      missing-socket) printf '%s\n' "error connecting to /tmp/tmux-test/default (No such file or directory)" >&2; exit 1 ;;
      present) printf '%s\n' fm-sm1 ; exit 0 ;;
      *) printf '%s\n' "permission denied" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_classifies() {
  local fb out

  for harness in claude codex opencode grok kimi pi pi-signed pi-launcher Pi; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-$harness" "$harness")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $harness foreground process should classify as alive, got '$out'"
  done

  for shell in zsh bash -zsh; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-${shell#-}" "$shell")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = dead ] || fail "a bare $shell foreground process should classify as dead, got '$out'"
  done

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-missing" missing)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
  [ "$out" = missing ] || fail "a readable inventory omitting the target should classify as missing, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:fm-sm1' "$ROOT")" = dead ] \
    || fail "the compatibility view should treat an authoritatively missing target as dead"

  for inventory in present unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = unreadable ] || fail "a $inventory inventory case should stay unreadable, got '$out'"
  done

  for inventory in missing-session missing-server missing-socket; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = missing ] || fail "a confirmed $inventory inventory failure should classify as missing, got '$out'"
  done

  pass "fm_backend_tmux_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_tmux_agent_state_rejects_malformed_targets_before_probe() {
  local fakebin marker target out
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux-malformed")
  marker="$TMP_ROOT/tmux-malformed-called"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_TMUX_MARKER"
printf 'bash\n'
SH
  chmod +x "$fakebin/tmux"

  for target in sess sess: :win sess:win:extra; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_TEST_TMUX_MARKER="$marker" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1"' "$ROOT" "$target")
    [ "$out" = unreadable ] || fail "malformed tmux target '$target' should classify as unreadable, got '$out'"
    [ ! -e "$marker" ] || fail "malformed tmux target '$target' invoked tmux"
  done

  pass "fm_backend_tmux_agent_state: rejects malformed targets before probing tmux"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  # Pin the session server as running so an installed herdr on the host
  # cannot turn the unknown row into a stopped-server `missing`.
  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_server_running_state() { printf running; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
    [ "$out" = "$expected" ] || fail "Herdr pane state $pane_state should map to $expected, got '$out'"
  done

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "no-colon-target"' "$ROOT")
  [ "$out" = unreadable ] || fail "an unparseable Herdr target should classify as unreadable, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "the Herdr compatibility view should keep a no-agent husk dead, got '$out'"

  pass "fm_backend_herdr_agent_state: preserves missing/no-agent/live/unknown husk behavior"
}

# --- unit level: the generic dispatchers ------------------------------------

test_agent_state_dispatcher_and_compatibility() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route tmux, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_state herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route Herdr, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state zellij sess:7' "$ROOT")
  [ "$out" = unverified ] || fail "Zellij should remain unverified, got '$out'"
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:7' "$ROOT")
  [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified to unknown, got '$out'"

  pass "fm_backend_agent_state: routes tmux/Herdr and keeps Zellij unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.77
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail).
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  list-sessions)
    # The absence owner scans every session for the task's pinned window name,
    # so this fixture holds exactly one session and answers the same three
    # shapes list-windows does.
    case "$mode" in
      unreadable) exit 1 ;;
      *) printf '%s\n' firstmate; exit 0 ;;
    esac
    ;;
  list-windows)
    case "$mode" in
      missing) printf '%s\n' main; exit 0 ;;
      unreadable) exit 1 ;;
      *) [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1; exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && [ "${1:-}" = new-window ] && exit 1
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_endpoint_absent_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/fake-state/sessions"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
FS=${FM_TEST_TMUX_STATE:?}
LOG=${FM_TMUX_CALL_LOG:?}
no_server_error() {
  printf 'no server running on /tmp/tmux-test/default\n' >&2
  exit 1
}
target_session() {  # <target> -> session name, stripping a leading = (tmux's
                     # exact-match prefix) and a trailing :window
  local t=${1#=}
  printf '%s' "${t%%:*}"
}
case "${1:-}" in
  list-sessions)
    [ -e "$FS/no-server" ] && no_server_error
    for f in "$FS"/sessions/*; do
      [ -e "$f" ] || continue
      basename "$f"
    done
    exit 0
    ;;
  has-session)
    [ -e "$FS/no-server" ] && exit 1
    shift
    t=
    while [ $# -gt 0 ]; do case "$1" in -t) t=$2; shift 2 ;; *) shift ;; esac; done
    [ -f "$FS/sessions/$(target_session "$t")" ]
    exit $?
    ;;
  new-session)
    rm -f "$FS/no-server"
    shift
    name=
    while [ $# -gt 0 ]; do case "$1" in -s) name=$2; shift 2 ;; *) shift ;; esac; done
    printf '' >> "$FS/sessions/$name"
    printf 'new-session -s %s\n' "$name" >> "$LOG"
    exit 0
    ;;
  list-windows)
    [ -e "$FS/no-server" ] && no_server_error
    shift
    t=
    while [ $# -gt 0 ]; do case "$1" in -t) t=$2; shift 2 ;; *) shift ;; esac; done
    session=$(target_session "$t")
    if [ ! -f "$FS/sessions/$session" ]; then
      printf "can't find session: %s\n" "$session" >&2
      exit 1
    fi
    cat "$FS/sessions/$session"
    exit 0
    ;;
  new-window)
    shift
    sess= wname=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) sess=$2; shift 2 ;;
        -n) wname=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    session=$(target_session "$sess")
    printf '%s\n' "$wname" >> "$FS/sessions/$session"
    printf 'new-window -t %s -n %s\n' "$session" "$wname" >> "$LOG"
    printf '@1\n'
    exit 0
    ;;
  set-window-option|send-keys|display-message|capture-pane|kill-window)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" \
    "the shared library did not leave the durable per-mate relaunch record"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_skips_mate_whose_liveness_lock_is_held() {
  local w fb tmuxfb log out holder i=0
  w=$(new_world sweep-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # A concurrent liveness episode (the watcher's tick) owns the per-mate lock;
  # the sweep must skip rather than probe or relaunch a moving target.
  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$w/home/state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  while [ ! -d "$w/home/state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$w/home/state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: another liveness check is already in progress" \
    "a mate under an active liveness lock should be skipped, not probed"
  [ ! -s "$log" ] || fail "a locked mate must never be killed or respawned: $(cat "$log")"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "sweep: a mate mid-episode under the shared liveness lock is skipped entirely"
}

test_sweep_refuses_relaunch_on_ledger_errors() {
  local w fb tmuxfb log out mode ledger word
  if [ "$(id -u)" -eq 0 ]; then
    pass "sweep: ledger permission errors skipped (root ignores file modes)"
    return 0
  fi
  for mode in 200 444; do
    case "$mode" in 200) word=unreadable ;; *) word=unwritable ;; esac
    w=$(new_world "sweep-ledger-$mode")
    add_sm_home "$w" sm1 firstmate:fm-sm1
    fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
    log="$w/calls.log"; : > "$log"
    ledger="$w/home/state/.secondmate-relaunch-sm1"
    : > "$ledger"
    chmod "$mode" "$ledger"

    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
    chmod 644 "$ledger"

    assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: relaunch ledger $ledger is $word" \
      "a mode-$mode relaunch ledger should skip the relaunch with its reason"
    [ ! -s "$log" ] || fail "a mode-$mode relaunch ledger still killed or spawned: $(cat "$log")"
    [ ! -s "$ledger" ] || fail "a mode-$mode ledger gained rows: $(cat "$ledger")"
  done
  pass "sweep: an unreadable or unwritable relaunch ledger refuses to kill or spawn"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=tmux)" \
    "verbose diagnostics should identify the already-live outcome"
  [ ! -s "$log" ] || fail "verbose reporting must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

# A `missing` tmux window is recoverable once the absence owner's scan of every
# session on the addressed server never finds the task's pinned name: nothing
# is holding that endpoint, so the mate is respawned rather than reported.
test_sweep_respawns_authoritatively_missing_pi_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a successful missing-window recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing Pi secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing Pi secondmate window is relaunched"
}

test_sweep_respawns_authoritatively_missing_pi_signed_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi-signed)
  printf '%s\n' pi-signed > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi-signed
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded pi-signed secondmate should be verified for recovery"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing pi-signed secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent pi-signed window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing pi-signed secondmate window is relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb tmuxfb log out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing Pi-shaped node process should be reported as ambiguous"
  [ ! -s "$log" ] || fail "an ambiguous existing process must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an existing ambiguous Pi process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" unreadable "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_dead_endpoint_relaunch_failure() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after confirmed agent absence on existing endpoint" \
    "a failed relaunch should retain the cause that authorized it"
  pass "sweep: failed relaunch diagnostics name the endpoint verdict that authorized the attempt"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should not let a dead endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an unverified harness blocks recovery with a concrete diagnostic"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

# --- library level: the watcher's poll-mode remote probe ---------------------
# bin/fm-secondmate-liveness-lib.sh's `poll` mode is the read-only probe the
# watcher tick runs per cadence: exactly one remote `state` call, `dead` and
# `missing` alone authorize relaunch, and transport failure (ssh exit 255) is
# never evidence of death. Full-mode remote readiness repair and route
# revalidation remain the startup sweep's own behavior, covered by the sweep
# tests above and tests/fm-remote-secondmate-lifecycle-e2e.test.sh.

# make_remote_probe_world <name>: a parent home carrying one remote-route
# secondmate meta plus a fake ssh that logs every call and answers with
# FM_FAKE_REMOTE_REPLY on FM_FAKE_REMOTE_RC.
make_remote_probe_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

# probe_remote <w> <mode> [env...] -> "<status>|<state>|<kill>|<cause>|<where>|<reason>"
probe_remote() {
  local w=$1 mode=$2; shift 2
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" "$@" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 "$2"
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" \
        "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_WHERE" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta" "$mode"
}

test_remote_poll_probe_maps_states() {
  local w out
  w=$(make_remote_probe_world probe-states)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=dead)
  [ "$out" = 'relaunchable|dead|0|remote endpoint dead on its configured host|host=lab-host|' ] \
    || fail "a dead remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=missing)
  [ "$out" = 'relaunchable|missing|0|remote endpoint missing on its configured host|host=lab-host|' ] \
    || fail "a missing remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=alive)
  [ "$out" = 'alive|alive|0|||' ] || fail "an alive remote reply should be a quiet no-op, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=ambiguous)
  [ "$out" = 'skipped|ambiguous|0|||remote endpoint state is ambiguous on lab-host' ] \
    || fail "an ambiguous remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=unverified)
  [ "$out" = 'skipped|unverified|0|||remote endpoint state is unverified on lab-host' ] \
    || fail "an unverified remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=bogus)
  [ "$out" = 'skipped|bogus|0|||remote endpoint returned an invalid state' ] \
    || fail "an invalid remote reply must preserve the endpoint, got: $out"

  [ "$(wc -l < "$w/ssh.log" | tr -d ' ')" -eq 6 ] \
    || fail "each poll-mode probe should spend exactly one remote state call: $(cat "$w/ssh.log")"
  pass "poll probe: remote states map to the same contract as local, one call each"
}

test_remote_poll_probe_unreachable_preserves_route() {
  local w out
  w=$(make_remote_probe_world probe-unreachable)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "ssh exit 255 must never read as a dead endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=1)
  [ "$out" = 'skipped|unknown|0|||remote endpoint probe unreadable on lab-host' ] \
    || fail "a non-transport remote probe failure must stay inconclusive, got: $out"
  pass "poll probe: unreachable or inconclusive remote reads preserve the route"
}

# The `missing` arm delegates to the control plane's one absence owner, and
# only a positively `gone` verdict may re-create an endpoint. The verdict
# itself is stubbed here because its per-backend reads are that function's own
# contract (fm-control-lib.sh owns them; tests/fm-backend.test.sh's
# test_tmux_absence_verdict_is_gone_only_for_an_absent_server pins the tmux
# arm, and the sweep cases below drive the real verdict end to end); what this
# pins is the probe's use of the answer, which is the decision that can
# duplicate a live agent onto its own worktree.
probe_local_with_verdict() {  # <w> <verdict-line> -> "<status>|<state>|<kill>|<cause>|<where>|<reason>"
  local w=$1 verdict=$2
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_TEST_VERDICT="$verdict" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_backend_agent_state() { printf missing; }
      fm_control_endpoint_absence_verdict() { printf "%s" "$FM_TEST_VERDICT"; }
      fm_secondmate_liveness_probe "$1" sm1 poll
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" \
        "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_WHERE" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/sm1.meta"
}

# Each of the absence owner's four answers maps to exactly one outcome here,
# and all three of its callers must agree on them: `gone` re-creates the
# endpoint, `dead` adopts the one that is still there with a pre-kill, `alive`
# is a healthy mate, and anything else settles nothing and is reported.
test_missing_endpoint_maps_every_absence_verdict_to_its_outcome() {
  local w out verdict
  w=$(new_world probe-absence-verdict)
  add_sm_home "$w" sm1 firstmate:fm-sm1

  out=$(probe_local_with_verdict "$w" "$(printf 'gone\t')")
  [ "$out" = 'relaunchable|missing|0|recorded endpoint confidently missing|backend=tmux|' ] \
    || fail "a proven-gone endpoint should authorize relaunch with no pre-kill, got: $out"

  out=$(probe_local_with_verdict "$w" "$(printf 'unproven\tno socket identity to prove it by')")
  [ "$out" = 'skipped|missing|0|||recorded endpoint '"'"'firstmate:fm-sm1'"'"' does not resolve, and no socket identity to prove it by; its agent may still be alive there, so reconcile the endpoint before any relaunch' ] \
    || fail "an unproven absence must report the verdict's own reason and relaunch nothing, got: $out"

  # A verdict that positively found the agent answering is not a missing
  # endpoint at all: the mate is healthy, so the probe reports the ordinary
  # already-live outcome and nothing is queued for the captain.
  out=$(probe_local_with_verdict "$w" "$(printf 'alive\t')")
  [ "$out" = 'alive|alive|0|||' ] \
    || fail "an endpoint the owner re-read as alive must be the ordinary already-live outcome, got: $out"

  # An endpoint the owner re-read as present but agent-free is adoptable, so it
  # is relaunched with the husk killed first - the same answer `exit` reports as
  # already-stopped and `relaunch` adopts.
  out=$(probe_local_with_verdict "$w" "$(printf 'dead\t')")
  [ "$out" = 'relaunchable|dead|1|confirmed agent absence on existing endpoint|backend=tmux|' ] \
    || fail "a dead endpoint should be adopted with a pre-kill, got: $out"

  # A verdict that established nothing is reported, and because the owner
  # carries a reason only with `unproven` the report must name the verdict
  # itself rather than interpolating an empty clause. An unrecognized word is
  # the shape a future owner answer would arrive as, so it must land here
  # rather than in any of the acting arms above.
  verdict=bogus
  out=$(probe_local_with_verdict "$w" "$(printf '%s\t' "$verdict")")
  [ "$out" = "skipped|missing|0|||recorded endpoint 'firstmate:fm-sm1' did not resolve on the first read, and the endpoint absence proof answered '$verdict', which does not authorize re-creating it" ] \
    || fail "a '$verdict' verdict must report itself and relaunch nothing, got: $out"
  pass "poll probe: gone re-creates, dead adopts with a pre-kill, alive is healthy, anything else reports"
}

test_sweep_reboot_with_no_server_recreates_endpoint() {
  local w fb tmuxfb fs log out
  w=$(new_world sweep-reboot-single)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_endpoint_absent_tmux "$w")
  fs="$w/fake-state"
  log="$w/calls.log"; : > "$log"
  # A genuine reboot: no tmux server at all, so the window cannot exist
  # anywhere on the backend. Absence of a server is what makes this the safe
  # case - unlike the rename/move cases above, there is nowhere left an agent
  # could still be running.
  : > "$fs/no-server"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_TMUX_STATE="$fs")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a successful reboot recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window -t firstmate -n fm-sm1" \
    "a genuinely rebooted secondmate should be recreated"
  pass "sweep: a genuine reboot with no tmux server still recreates the endpoint"
}
# The brief's own scenario: several secondmates parked across a reboot.
# Relaunching the first one necessarily starts the tmux server (and its
# session), so a check that read only "is a server/session running" would
# restore exactly one secondmate and then refuse the rest - this is the exact
# shape of regression the sibling recreate-arm fix caught. Because
# fm_control_endpoint_absence_verdict proves absence per WINDOW NAME rather than per
# server/session presence, a session that now exists (from an earlier
# secondmate's own relaunch) does not disqualify a later one whose own window
# is still nowhere in it.
#
# Each secondmate here gets its OWN home and its own sequential
# bin/fm-bootstrap.sh invocation - the same single-item shape every other
# sweep test in this file already exercises - while all three share ONE
# simulated tmux backend (a fixed fake-state directory, independent of which
# home is checking it). That isolates the exact question this regression is
# about - does a later secondmate's absence check get fooled by an earlier
# secondmate's relaunch having already started the shared session? - from a
# separate, pre-existing concurrency limit in how bin/fm-bootstrap.sh's own
# sweep parallelizes several respawns registered in one primary's state/ (its
# per-home task-set lock is a single non-blocking `fm_lock_try_acquire`, so
# concurrent fresh spawns already race there today regardless of this fix -
# confirmed independent of fm_control_endpoint_absence_verdict by reproducing the same
# lock refusal with two plain `dead` secondmates on unmodified fm-spawn.sh).
# That is a distinct defect outside this task's scope (AGENTS.md: an accepted
# risk is not authority to widen a task); it belongs in its own follow-up.
test_sweep_reboot_relaunches_every_parked_secondmate_not_just_the_first() {
  local base fb tmuxfb fs log out id w
  base="$TMP_ROOT/sweep-reboot-fleet"
  mkdir -p "$base"
  tmuxfb=$(make_endpoint_absent_tmux "$base")
  fs="$base/fake-state"
  fb=$(make_toolchain "$base")
  : > "$fs/no-server"
  log="$base/calls.log"; : > "$log"

  for id in sm1 sm2 sm3; do
    w=$(new_world "sweep-reboot-fleet-$id")
    add_sm_home "$w" "$id" "firstmate:fm-$id"
    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_TMUX_STATE="$fs")
    assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
      "secondmate $id parked across the reboot should recover silently, whether or not the shared server was already started by an earlier one"
  done

  for id in sm1 sm2 sm3; do
    assert_contains "$(cat "$log")" "new-window -t firstmate -n fm-$id" \
      "secondmate $id parked across the reboot should have been relaunched too, not just the one that restarts the server"
  done
  [ -s "$fs/sessions/firstmate" ] \
    || fail "recreating the first parked secondmate should have started the server the rest then share"
  pass "sweep: every secondmate parked across a reboot relaunches, not just the one whose relaunch restarts the server"
}

test_sweep_renamed_session_with_window_intact_refuses_relaunch() {
  local w fb tmuxfb fs log out
  w=$(new_world sweep-renamed-session)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_endpoint_absent_tmux "$w")
  fs="$w/fake-state"
  log="$w/calls.log"; : > "$log"
  # `tmux rename-session -t firstmate work`: the recorded session name is
  # gone, but the task's own window - and the agent inside it - moved with
  # it, intact, under the new name.
  printf '%s\n' fm-sm1 >> "$fs/sessions/work"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_TMUX_STATE="$fs")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped" \
    "a renamed session whose window survived elsewhere should be reported as skipped, not silently ignored"
  assert_contains "$out" "may still be alive there" \
    "the skip reason should name why a missing address is not proof of absence"
  [ ! -s "$log" ] || fail "a renamed session with its window intact must never trigger a relaunch: $(cat "$log")"
  pass "sweep: a renamed tmux session whose window survives elsewhere refuses to relaunch"
}

test_sweep_moved_window_found_in_another_session_refuses_relaunch() {
  local w fb tmuxfb fs log out
  w=$(new_world sweep-moved-window)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_endpoint_absent_tmux "$w")
  fs="$w/fake-state"
  log="$w/calls.log"; : > "$log"
  # `tmux move-window -s firstmate:fm-sm1 -t work`: the recorded session is
  # still there but no longer holds the window, which - and its agent - is
  # alive under a different session instead.
  printf '%s\n' main >> "$fs/sessions/firstmate"
  printf '%s\n' fm-sm1 >> "$fs/sessions/work"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_TMUX_STATE="$fs")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped" \
    "a window moved into a live session should be reported as skipped, not silently ignored"
  [ ! -s "$log" ] || fail "a window found alive under another session must never trigger a relaunch: $(cat "$log")"
  pass "sweep: a tmux window moved into another live session refuses to relaunch"
}
test_missing_endpoint_maps_every_absence_verdict_to_its_outcome
test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_respawns_authoritatively_missing_pi_secondmate
test_sweep_respawns_authoritatively_missing_pi_signed_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_dead_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_reboot_with_no_server_recreates_endpoint
test_sweep_reboot_relaunches_every_parked_secondmate_not_just_the_first
test_sweep_renamed_session_with_window_intact_refuses_relaunch
test_sweep_moved_window_found_in_another_session_refuses_relaunch
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta
test_sweep_skips_mate_whose_liveness_lock_is_held
test_sweep_refuses_relaunch_on_ledger_errors
test_remote_poll_probe_maps_states
test_remote_poll_probe_unreachable_preserves_route

echo "# all fm-secondmate-liveness tests passed"
