# shellcheck shell=bash
# Shared configuration, on/off state, and request binding for the home-local
# Buzz bridge (bin/fm-buzz.sh, bin/fm-buzz-poll.sh, bin/fm-buzz-reply.sh).
#
# The bridge is a third Relay surface: verified owner mentions in one private
# Buzz Stream channel land in the shared Relay inbox (state/x-inbox) with
# platform "buzz", and bin/fm-x-reply.sh / bin/fm-x-dismiss.sh hand any request
# that carries a Buzz binding to bin/fm-buzz-reply.sh. docs/configuration.md
# "Buzz bridge" owns setup, the off switch, and the attended smoke test.
#
# Sourced, never executed. Callers set FM_HOME, STATE, and CONFIG first.
#
# Off switch: the bridge runs only while config/buzz-bridge.enabled exists, and
# only bin/fm-buzz.sh enable creates it. Absent means off, so a home without
# Buzz configured is off by default and a disabled home stays off across
# restarts until an explicit enable. Intake and replies both re-check it.
#
# Settings live in the private, gitignored config/buzz-bridge.env (KEY=VALUE,
# read with fmx_env_get). Environment variables never override them:
#   BUZZ_RELAY_URL       relay base URL (https); its host is the community
#   BUZZ_CHANNEL         private Stream channel UUID
#   BUZZ_OWNER_PUBKEY    owner pubkey, 64-char lowercase hex
#   BUZZ_BRIDGE_PUBKEY   bridge pubkey, 64-char lowercase hex
#   BUZZ_BRIDGE_KEY_FILE absolute path to the bridge's buzz-admin key file
#   BUZZ_CLI             absolute path to the buzz CLI built at relay-v0.3.0
#   BUZZ_LISTENER        optional absolute path to the pinned listener helper
#
# Defines:
#   fm_buzz_enabled                 - 0 when the on marker exists
#   fm_buzz_load_config             - populate BUZZ_*; on a problem return 1
#                                     with FM_BUZZ_CONFIG_ERROR
#   fm_buzz_request_id <event-id>   - the stable request id for an event
#   fm_buzz_rid_valid <rid>         - 0 for a well-formed Buzz request id
#   fm_buzz_binding_dir             - state/buzz/requests
#   fm_buzz_binding_get <rid>       - print the binding JSON, 1 when absent
#   fm_buzz_binding_put <rid>       - replace the binding from stdin
#   fm_buzz_binding_claim <rid>     - create the binding from stdin; 0 new,
#                                     1 existing, 2 error
#   fm_buzz_binding_prune           - drop bindings past the 7-day window
#   fm_buzz_secret_read             - print the bridge secret from the key file
#                                     (only ever into a signing call's env)
#   fm_buzz_cli [--timeout <seconds>] <args...>
#                                  - run a read as the bridge identity, with one
#                                    retry for a stale-timestamp refusal; stdin
#                                    does not reach the CLI, and its stderr is
#                                    consumed by the retry match, not forwarded
#   fm_buzz_cli_once <args...>      - one attempt, for a write no retry may
#                                    repeat; stdin reaches the CLI
#   fm_buzz_export_cli              - export the config and functions a bounded
#                                     child shell needs to call fm_buzz_cli_retry
#                                     (same contract as fm_buzz_cli) itself

if ! command -v fmx_private_artifact_publish_stdin >/dev/null 2>&1; then
  # shellcheck source=bin/fm-x-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-x-lib.sh"
fi

# Both are read by the scripts that source this library.
# shellcheck disable=SC2034
FM_BUZZ_CHECK_ID=buzz-bridge
# shellcheck disable=SC2034
FM_BUZZ_POLL_LOCK="$STATE/.buzz-poll.lock"
# shellcheck disable=SC2034
FM_BUZZ_CONFIG_ERROR=
# The intake window stays inside the seven-day binding and offer retention.
# shellcheck disable=SC2034
BUZZ_MAX_AGE_SECS=86400
# shellcheck disable=SC2034
BUZZ_REPLY_MAX_CHARS=1000
# How far a poll reads back behind its cursor, so a message that lands between
# the cursor and the read is not missed. The cursor's `fence` bounds it, so this
# look-back can never reach behind the moment the bridge was turned on.
# shellcheck disable=SC2034
BUZZ_READ_OVERLAP=300

# CONFIG is set by the sourcing script.
# shellcheck disable=SC2153
fm_buzz_enabled() {
  [ -f "$CONFIG/buzz-bridge.enabled" ] && [ ! -L "$CONFIG/buzz-bridge.enabled" ]
}

# shellcheck disable=SC2034 # BUZZ_* and FM_BUZZ_CONFIG_ERROR are read by callers.
fm_buzz_load_config() {
  local file="$CONFIG/buzz-bridge.env" key host
  FM_BUZZ_CONFIG_ERROR=
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    FM_BUZZ_CONFIG_ERROR="config/buzz-bridge.env is missing"
    return 1
  fi
  for key in BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_OWNER_PUBKEY \
    BUZZ_BRIDGE_PUBKEY BUZZ_BRIDGE_KEY_FILE BUZZ_CLI BUZZ_LISTENER; do
    printf -v "$key" '%s' "$(fmx_env_get "$key" "$file")"
  done
  case "$BUZZ_RELAY_URL" in
    https://*) BUZZ_RELAY_URL=${BUZZ_RELAY_URL%/} ;;
    *) FM_BUZZ_CONFIG_ERROR="BUZZ_RELAY_URL must be an https URL"; return 1 ;;
  esac
  host=${BUZZ_RELAY_URL#https://}
  host=${host%%/*}
  host=${host%%:*}
  case "$host" in
    ''|*[!A-Za-z0-9.-]*) FM_BUZZ_CONFIG_ERROR="BUZZ_RELAY_URL has no usable host"; return 1 ;;
  esac
  BUZZ_COMMUNITY=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [[ "$BUZZ_CHANNEL" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { FM_BUZZ_CONFIG_ERROR="BUZZ_CHANNEL must be a lowercase channel UUID"; return 1; }
  for key in BUZZ_OWNER_PUBKEY BUZZ_BRIDGE_PUBKEY; do
    [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] \
      || { FM_BUZZ_CONFIG_ERROR="$key must be a 64-character lowercase hex pubkey"; return 1; }
  done
  [ "$BUZZ_OWNER_PUBKEY" != "$BUZZ_BRIDGE_PUBKEY" ] \
    || { FM_BUZZ_CONFIG_ERROR="BUZZ_OWNER_PUBKEY and BUZZ_BRIDGE_PUBKEY must differ"; return 1; }
  case "$BUZZ_BRIDGE_KEY_FILE" in
    /*) [ -f "$BUZZ_BRIDGE_KEY_FILE" ] && [ -r "$BUZZ_BRIDGE_KEY_FILE" ] \
      || { FM_BUZZ_CONFIG_ERROR="BUZZ_BRIDGE_KEY_FILE is not a readable file"; return 1; } ;;
    *) FM_BUZZ_CONFIG_ERROR="BUZZ_BRIDGE_KEY_FILE must be an absolute path"; return 1 ;;
  esac
  case "$BUZZ_CLI" in
    /*) [ -f "$BUZZ_CLI" ] && [ -x "$BUZZ_CLI" ] \
      || { FM_BUZZ_CONFIG_ERROR="BUZZ_CLI is not an executable file"; return 1; } ;;
    *) FM_BUZZ_CONFIG_ERROR="BUZZ_CLI must be an absolute path to the relay-v0.3.0 buzz CLI"; return 1 ;;
  esac
  # Listener availability must never disable the stage 1 poll or replies.
  return 0
}

fm_buzz_listener_available() {
  [[ "$BUZZ_LISTENER" = /* ]] && [ -f "$BUZZ_LISTENER" ] && [ -x "$BUZZ_LISTENER" ]
}

fm_buzz_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# Stable across restarts and re-reads: transport, community origin, bridge key,
# and event id bind one request to one community and one bridge identity.
fm_buzz_request_id() {
  local hash
  hash=$(printf 'buzz\n%s\n%s\n%s\n' "$BUZZ_COMMUNITY" "$BUZZ_BRIDGE_PUBKEY" "$1" | fm_buzz_sha256) || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'buzz-%s\n' "${hash:0:40}"
}

fm_buzz_binding_dir() {
  printf '%s\n' "$STATE/buzz/requests"
}

fm_buzz_rid_valid() {
  [[ "${1-}" =~ ^buzz-[0-9a-f]{40}$ ]]
}

fm_buzz_binding_get() {
  local rid=$1 dir
  fm_buzz_rid_valid "$rid" || return 1
  dir=$(fm_buzz_binding_dir)
  fmx_private_artifact_file_valid "$dir" "$rid.json" 600 || return 1
  jq -ce 'select(type == "object")' "$dir/$rid.json" 2>/dev/null
}

fm_buzz_binding_put() {
  fm_buzz_rid_valid "$1" || return 1
  fmx_private_artifact_dir_prepare "$STATE/buzz" >/dev/null || return 1
  fmx_private_artifact_publish_stdin "$(fm_buzz_binding_dir)" "$1.json" 600
}

fm_buzz_binding_claim() {
  fm_buzz_rid_valid "$1" || return 2
  fmx_private_artifact_dir_prepare "$STATE/buzz" >/dev/null || return 2
  fmx_private_artifact_publish_stdin_once "$(fm_buzz_binding_dir)" "$1.json" 600
}

fm_buzz_binding_prune() {
  local dir now file recorded
  dir=$(fm_buzz_binding_dir)
  fmx_private_artifact_dir_device "$dir" >/dev/null 2>&1 || return 0
  now=${FMX_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  for file in "$dir"/buzz-*.json; do
    [ -f "$file" ] || continue
    recorded=$(jq -r '.recorded_at // empty' "$file" 2>/dev/null) || recorded=
    case "$recorded" in ''|*[!0-9]*) continue ;; esac
    [ $((now - recorded)) -le 604800 ] || rm -f -- "$file"
  done
  return 0
}

# The key file is buzz-admin generate-key output: a "Secret key:" line holding
# 64-character lowercase hex, the one encoding the pinned CLI takes. The value is
# printed only into the caller's command substitution, which hands it to the one
# signing CLI call's environment; it is never logged or put in argv.
fm_buzz_secret_read() {
  local line secret
  line=$(grep -m1 -E '^[[:space:]]*Secret key:' "$BUZZ_BRIDGE_KEY_FILE" 2>/dev/null) || return 1
  secret=${line#*:}
  secret=${secret//[[:space:]]/}
  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$secret"
}

# Run one signing attempt as the bridge identity against the
# configured relay. The secret is read at this moment and reaches the CLI only
# through its environment; inherited Buzz identity settings are cleared so a
# desktop pairing or stray auth tag can never stand in for the bridge key.
# Returns the CLI's exit code (2 relay/network, 3 auth), or 10 when the secret
# cannot be read.
fm_buzz_cli_once() {
  local secret relay=$BUZZ_RELAY_URL
  secret=$(fm_buzz_secret_read) || return 10
  (
    unset BUZZ_AUTH_TAG BUZZ_FEDERATED_IDENTITY_TOKEN BUZZ_FEDERATED_IDENTITY_ADAPTER \
      BUZZ_OUTPUT_FORMAT BUZZ_RELAY_URL
    BUZZ_PRIVATE_KEY=$secret exec "$BUZZ_CLI" --relay "$relay" --format json "$@"
  )
}

# Retry one verified NIP-98 timestamp rejection with a fresh signature. Only a
# read belongs here: a second attempt at a write could duplicate an
# owner-visible effect, so writes call fm_buzz_cli_once and keep reporting the
# refusal. All other results pass through immediately. Return 11 if the
# timestamp rejection persists. The only CLI output forwarded is the last
# attempt's stdout.
fm_buzz_cli_retry() (
  local work err rc attempt
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-buzz-cli.XXXXXX") || return 1
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 1' HUP INT TERM
  for attempt in 1 2; do
    rc=0
    err=$(fm_buzz_cli_once "$@" < /dev/null 2>&1 > "$work/out") || rc=$?
    if [ "$rc" -ne 3 ] || ! printf '%s\n' "$err" | jq -se '
      length == 1 and (.[0] | .error == "auth_error" and (.message | strings | contains("timestamp outside")))
      ' >/dev/null 2>&1; then
      break
    fi
    # 11 is this repository's own status, reserved like 10 above.
    if [ "$attempt" -ne 1 ]; then
      rc=11
      break
    fi
    sleep 1
    fm_buzz_enabled || break
  done
  cat -- "$work/out"
  return "$rc"
)

# Export only the functions and config needed by a bounded child shell. The
# signing secret stays in the actual CLI's environment, including on retries.
fm_buzz_export_cli() {
  export -f fm_buzz_cli_retry fm_buzz_cli_once fm_buzz_secret_read fm_buzz_enabled
  export BUZZ_RELAY_URL BUZZ_BRIDGE_KEY_FILE BUZZ_CLI CONFIG
}

# The retrying entry point: same statuses as fm_buzz_cli_retry. Stdin never
# reaches the CLI, because a retried attempt could not replay it, and the CLI's
# stderr is consumed by the retry's rejection match rather than forwarded, so a
# caller that needs the CLI's own error text must call fm_buzz_cli_once and
# accept that the refusal is not retried. The --timeout form bounds the whole
# operation under fm_run_timed, so the status can also be
# one that runner owns rather than a Buzz meaning (see fm-timeout-lib.sh, which
# owns those); a caller mapping exit codes to Buzz meanings must screen them
# first.
fm_buzz_cli() (
  if [ "${1:-}" = --timeout ]; then
    local seconds=$2
    shift 2
    # Bound the complete operation, including any retry.
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
    fm_buzz_export_cli
    fm_run_timed "$seconds" "$BASH" -c 'fm_buzz_cli_retry "$@"' _ "$@"
  else
    fm_buzz_cli_retry "$@"
  fi
)
