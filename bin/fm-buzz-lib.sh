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
#   BUZZ_RELAY_URL       relay base URL (wss/ws/https/http)
#   BUZZ_COMMUNITY       community host; must equal the relay URL's host
#   BUZZ_CHANNEL         private Stream channel UUID
#   BUZZ_OWNER_PUBKEY    owner pubkey, 64-char lowercase hex
#   BUZZ_BRIDGE_PUBKEY   bridge pubkey, 64-char lowercase hex
#   BUZZ_BRIDGE_KEY_FILE absolute path to the bridge's buzz-admin key file
#   BUZZ_CLI             absolute path to the buzz CLI built at relay-v0.3.0
#   BUZZ_MAX_AGE_SECS    optional intake age limit (default 86400, max 518400)
#   BUZZ_REPLY_MAX_CHARS optional per-message reply budget (default 1000)
#
# Defines:
#   fm_buzz_enabled                 - 0 when the on marker exists
#   fm_buzz_load_config             - populate BUZZ_* (and BUZZ_HTTP_URL); on a
#                                     problem return 1 with FM_BUZZ_CONFIG_ERROR
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
#   fm_buzz_cli <args...>           - run the pinned CLI as the bridge identity

if ! command -v fmx_private_artifact_publish_stdin >/dev/null 2>&1; then
  # shellcheck source=bin/fm-x-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-x-lib.sh"
fi

# Both are read by the scripts that source this library.
# shellcheck disable=SC2034
FM_BUZZ_CHECK_ID=buzz-bridge
# shellcheck disable=SC2034
FM_BUZZ_CONFIG_ERROR=

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
  for key in BUZZ_RELAY_URL BUZZ_COMMUNITY BUZZ_CHANNEL BUZZ_OWNER_PUBKEY \
    BUZZ_BRIDGE_PUBKEY BUZZ_BRIDGE_KEY_FILE BUZZ_CLI BUZZ_MAX_AGE_SECS BUZZ_REPLY_MAX_CHARS; do
    printf -v "$key" '%s' "$(fmx_env_get "$key" "$file")"
  done
  case "$BUZZ_RELAY_URL" in
    wss://*) BUZZ_HTTP_URL="https://${BUZZ_RELAY_URL#wss://}" ;;
    ws://*) BUZZ_HTTP_URL="http://${BUZZ_RELAY_URL#ws://}" ;;
    https://*|http://*) BUZZ_HTTP_URL=$BUZZ_RELAY_URL ;;
    *) FM_BUZZ_CONFIG_ERROR="BUZZ_RELAY_URL must be a ws, wss, http or https URL"; return 1 ;;
  esac
  BUZZ_HTTP_URL=${BUZZ_HTTP_URL%/}
  host=${BUZZ_HTTP_URL#*://}
  host=${host%%/*}
  host=${host%%:*}
  case "$host" in
    ''|*[!A-Za-z0-9.-]*) FM_BUZZ_CONFIG_ERROR="BUZZ_RELAY_URL has no usable host"; return 1 ;;
  esac
  if [ "$(printf '%s' "$BUZZ_COMMUNITY" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" ]; then
    FM_BUZZ_CONFIG_ERROR="BUZZ_COMMUNITY must equal the relay URL host"
    return 1
  fi
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
  case "$BUZZ_MAX_AGE_SECS" in ''|*[!0-9]*) BUZZ_MAX_AGE_SECS=86400 ;; esac
  # Bindings and offer records live seven days; intake must never reach past them.
  [ "${#BUZZ_MAX_AGE_SECS}" -le 7 ] && [ "$BUZZ_MAX_AGE_SECS" -le 518400 ] || BUZZ_MAX_AGE_SECS=518400
  [ "$BUZZ_MAX_AGE_SECS" -ge 60 ] || BUZZ_MAX_AGE_SECS=60
  case "$BUZZ_REPLY_MAX_CHARS" in ''|*[!0-9]*) BUZZ_REPLY_MAX_CHARS=1000 ;; esac
  [ "${#BUZZ_REPLY_MAX_CHARS}" -le 5 ] && [ "$BUZZ_REPLY_MAX_CHARS" -le 4000 ] || BUZZ_REPLY_MAX_CHARS=4000
  [ "$BUZZ_REPLY_MAX_CHARS" -ge 50 ] || BUZZ_REPLY_MAX_CHARS=50
  return 0
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

# The key file is buzz-admin generate-key output: a "Secret key:" line. The value
# is printed only into the caller's command substitution, which hands it to the
# one signing CLI call's environment; it is never logged or put in argv.
fm_buzz_secret_read() {
  local line secret
  line=$(grep -m1 -E '^[[:space:]]*Secret key:' "$BUZZ_BRIDGE_KEY_FILE" 2>/dev/null) || return 1
  secret=${line#*:}
  secret=${secret//[[:space:]]/}
  [[ "$secret" =~ ^([0-9a-f]{64}|nsec1[02-9ac-hj-np-z]{58})$ ]] || return 1
  printf '%s' "$secret"
}

# fm_buzz_cli <args...>: run the pinned CLI as the bridge identity against the
# configured relay. The secret is read at this moment and reaches the CLI only
# through its environment; inherited Buzz identity settings are cleared so a
# desktop pairing or stray auth tag can never stand in for the bridge key.
# Returns the CLI's exit code (2 relay/network, 3 auth), or 10 when the secret
# cannot be read.
fm_buzz_cli() {
  local secret
  secret=$(fm_buzz_secret_read) || return 10
  (
    unset BUZZ_AUTH_TAG BUZZ_FEDERATED_IDENTITY_TOKEN BUZZ_FEDERATED_IDENTITY_ADAPTER \
      BUZZ_OUTPUT_FORMAT BUZZ_RELAY_URL
    BUZZ_PRIVATE_KEY=$secret exec "$BUZZ_CLI" --relay "$BUZZ_HTTP_URL" --format json "$@"
  )
}
