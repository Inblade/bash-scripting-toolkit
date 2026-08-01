#!/usr/bin/env bash
# common.sh - reusable primitives for production Bash scripts.
#
# Source it, do not execute it:
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=../lib/common.sh
#   source "${SCRIPT_DIR}/../lib/common.sh"
#
# Requires Bash 4.0+ (associative arrays, ${var,,}). macOS ships Bash 3.2 as
# /bin/bash; the shebang uses `env bash` so a newer Bash from Homebrew wins.
#
# Everything here is namespaced with a `log_`, `retry`, `require_`, `on_exit`
# or `CM_` prefix to reduce collisions with the sourcing script.

# --- guard against double-sourcing -------------------------------------------
[[ -n "${CM_COMMON_SH_LOADED:-}" ]] && return 0
CM_COMMON_SH_LOADED=1

# --- Bash version gate --------------------------------------------------------
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'FATAL: bash 4.0+ required, found %s\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

# --- strict mode --------------------------------------------------------------
# -e   exit on unhandled non-zero status
# -u   error on unset variable expansion
# -o pipefail  a pipeline fails if ANY stage fails, not just the last
#
# Caveat, and it is a real one: `set -e` is not a general error handler. It is
# suppressed inside conditionals (`if cmd`, `cmd && ...`, `! cmd`), so a
# function called from an `if` runs to completion even after an inner failure.
# See docs/style-guide.md. Use explicit `|| die` at the call sites that matter.
set -euo pipefail

# Keep field splitting to newline+tab so unquoted expansion of paths with
# spaces is less catastrophic. Quote your expansions anyway.
IFS=$'\n\t'

# --- configuration knobs (override via environment) ---------------------------
# LOG_LEVEL: DEBUG | INFO | WARN | ERROR  (default INFO)
: "${LOG_LEVEL:=INFO}"
# LOG_FORMAT: text | json  (json is for shipping into a log pipeline)
: "${LOG_FORMAT:=text}"
# NO_COLOR is honoured; colour is also disabled when stderr is not a TTY.
: "${NO_COLOR:=}"

CM_SCRIPT_NAME="${CM_SCRIPT_NAME:-$(basename -- "${0}")}"

# --- colour setup -------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR}" && "${TERM:-dumb}" != "dumb" ]]; then
  readonly CM_C_RESET=$'\033[0m'
  readonly CM_C_DIM=$'\033[2m'
  readonly CM_C_RED=$'\033[31m'
  readonly CM_C_YELLOW=$'\033[33m'
  readonly CM_C_BLUE=$'\033[34m'
else
  readonly CM_C_RESET='' CM_C_DIM='' CM_C_RED='' CM_C_YELLOW='' CM_C_BLUE=''
fi

# --- log levels ---------------------------------------------------------------
declare -A CM_LEVELS=([DEBUG]=10 [INFO]=20 [WARN]=30 [ERROR]=40)

# _cm_level_num LEVEL -> numeric severity (unknown levels sort as INFO)
_cm_level_num() {
  local lvl="${1^^}"
  printf '%s' "${CM_LEVELS[$lvl]:-20}"
}

# _cm_json_escape STRING -> STRING with ", \\ and control chars escaped
_cm_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# _cm_log LEVEL MESSAGE...
# All logs go to stderr so stdout stays clean for real output/piping.
_cm_log() {
  local level="${1^^}"; shift
  # "$*" joins with the FIRST character of IFS, which this library sets to a
  # newline. Without this local override every multi-argument log call would
  # come out split across lines.
  local IFS=' '
  local msg="$*"

  (( $(_cm_level_num "$level") < $(_cm_level_num "$LOG_LEVEL") )) && return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$LOG_FORMAT" == "json" ]]; then
    printf '{"ts":"%s","level":"%s","script":"%s","msg":"%s"}\n' \
      "$ts" "$level" "$(_cm_json_escape "$CM_SCRIPT_NAME")" \
      "$(_cm_json_escape "$msg")" >&2
    return 0
  fi

  local colour=''
  case "$level" in
    DEBUG) colour="$CM_C_DIM" ;;
    INFO)  colour="$CM_C_BLUE" ;;
    WARN)  colour="$CM_C_YELLOW" ;;
    ERROR) colour="$CM_C_RED" ;;
  esac

  printf '%s%s [%-5s] %s: %s%s\n' \
    "$colour" "$ts" "$level" "$CM_SCRIPT_NAME" "$msg" "$CM_C_RESET" >&2
}

log_debug() { _cm_log DEBUG "$@"; }
log_info()  { _cm_log INFO  "$@"; }
log_warn()  { _cm_log WARN  "$@"; }
log_error() { _cm_log ERROR "$@"; }

# die [EXIT_CODE] MESSAGE...  - log at ERROR and exit.
# If the first argument is a bare integer it is used as the exit code.
die() {
  local code=1
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="$1"; shift
  fi
  log_error "$*"
  exit "$code"
}

# --- dependency checks --------------------------------------------------------

# require_cmd CMD...  - fail fast if any command is missing from PATH.
# Reports every missing command at once rather than one per run.
require_cmd() {
  local IFS=' '   # so "${missing[*]}" joins with spaces, not newlines
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v -- "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die 127 "missing required command(s): ${missing[*]}"
  fi
}

# require_env VAR...  - fail fast if any variable is unset or empty.
require_env() {
  local IFS=' '
  local missing=()
  local var
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    die 78 "missing required environment variable(s): ${missing[*]}"
  fi
}

# require_file PATH...  - fail fast if any path is not a readable file.
require_file() {
  local path
  for path in "$@"; do
    [[ -r "$path" ]] || die 66 "required file not readable: ${path}"
  done
}

# --- retry with exponential backoff ------------------------------------------

# retry ATTEMPTS BASE_DELAY_SECONDS -- COMMAND [ARGS...]
#
# Exponential backoff with full jitter: sleep = random(0, base * 2^(n-1)),
# capped at RETRY_MAX_DELAY (default 60s). Full jitter is deliberate; fixed
# backoff synchronises every caller into the same retry wave and turns a blip
# into a thundering herd.
#
#   retry 5 1 -- curl -fsS https://example.internal/healthz
#
# Returns the exit status of the last attempt.
# IMPORTANT: every local here is prefixed. Bash uses DYNAMIC scoping, so a
# function invoked by retry can see - and assign to - retry's locals. A callee
# that innocently uses `n` or `rc` would silently corrupt the retry loop.
# Prefixing is not cosmetic; it is the only thing preventing that class of bug.
retry() {
  local _cm_r_attempts="${1:?retry: attempts required}"
  local _cm_r_base="${2:?retry: base delay required}"
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  (( $# > 0 )) || die 64 "retry: no command given"

  local _cm_r_max="${RETRY_MAX_DELAY:-60}"
  local _cm_r_n=1 _cm_r_rc=0 _cm_r_delay

  while :; do
    _cm_r_rc=0
    # `set -e` must not abort us here; the `if` context suppresses it.
    if "$@"; then
      (( _cm_r_n > 1 )) && \
        log_info "succeeded on attempt ${_cm_r_n}/${_cm_r_attempts}: $1"
      return 0
    else
      _cm_r_rc=$?
    fi

    if (( _cm_r_n >= _cm_r_attempts )); then
      # Pass the command as separate arguments; _cm_log joins them with spaces.
      # Interpolating "$*" here would use this shell's IFS (newline) instead,
      # and deliberately NOT overriding IFS locally keeps the callee's
      # environment untouched.
      log_error "failed after ${_cm_r_attempts} attempt(s) (rc=${_cm_r_rc}):" "$@"
      return "$_cm_r_rc"
    fi

    _cm_r_delay=$(( _cm_r_base * (2 ** (_cm_r_n - 1)) ))
    (( _cm_r_delay > _cm_r_max )) && _cm_r_delay="$_cm_r_max"
    # Full jitter. RANDOM is 0..32767; modulo bias is irrelevant here.
    (( _cm_r_delay > 0 )) && _cm_r_delay=$(( RANDOM % (_cm_r_delay + 1) ))

    log_warn "attempt ${_cm_r_n}/${_cm_r_attempts} failed (rc=${_cm_r_rc}), retrying in ${_cm_r_delay}s: $1"
    sleep "$_cm_r_delay"
    _cm_r_n=$(( _cm_r_n + 1 ))
  done
}

# with_timeout SECONDS COMMAND [ARGS...]
# Wrapper over coreutils/BSD `timeout`. Exit 124 means the command was killed.
with_timeout() {
  local secs="${1:?with_timeout: seconds required}"; shift
  require_cmd timeout
  timeout --preserve-status "$secs" "$@"
}

# --- cleanup traps ------------------------------------------------------------
# Register cleanup callbacks that run exactly once, in LIFO order, on normal
# exit and on INT/TERM. LIFO matters: you tear down in the reverse order you
# built up (unmount before removing the mountpoint, etc).

declare -a CM_CLEANUP_STACK=()
CM_CLEANUP_DONE=0

# on_exit COMMAND [ARGS...]  - push a cleanup action.
#   tmp="$(make_temp_dir)"      # already registers itself
#   on_exit rm -f /var/run/my.lock
on_exit() {
  (( $# > 0 )) || return 0
  # Store as a single properly quoted string so arguments with spaces survive.
  CM_CLEANUP_STACK+=("$(printf '%q ' "$@")")
}

_cm_run_cleanup() {
  local rc="$1"
  (( CM_CLEANUP_DONE )) && return 0
  CM_CLEANUP_DONE=1

  local i
  for (( i = ${#CM_CLEANUP_STACK[@]} - 1; i >= 0; i-- )); do
    log_debug "cleanup: ${CM_CLEANUP_STACK[i]}"
    # Cleanup must never abort the rest of the cleanup.
    eval "${CM_CLEANUP_STACK[i]}" || \
      log_warn "cleanup step failed: ${CM_CLEANUP_STACK[i]}"
  done
  log_debug "exiting with status ${rc}"
}

_cm_on_err() {
  local rc="$1" line="$2" cmd="$3"
  log_error "unexpected failure (rc=${rc}) at line ${line}: ${cmd}"
}

# Order matters: ERR fires first and logs context, then EXIT runs cleanup.
trap '_cm_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap '_cm_run_cleanup "$?"' EXIT
# 128+signal is the conventional exit status; re-raising would be purer but
# an explicit exit keeps the EXIT trap semantics simple and portable.
trap 'log_warn "received SIGINT"; exit 130' INT
trap 'log_warn "received SIGTERM"; exit 143' TERM

# --- temp files ---------------------------------------------------------------
#
# These assign into a caller-named variable rather than printing the path, and
# that is a deliberate correctness decision, not a style preference.
#
# The obvious API would be `dir="$(make_temp_dir)"`. It is broken: command
# substitution runs the function in a SUBSHELL, and Bash resets traps there, so
# the on_exit registration is thrown away along with the subshell. The path
# comes back fine and the directory then leaks forever. Assigning via
# `printf -v` keeps the function in the caller's shell, so the cleanup
# registration actually survives.
#
#   make_temp_dir workdir            # sets $workdir
#   make_temp_dir workdir myprefix
#
# printf -v is used instead of a nameref (local -n) to stay compatible with
# Bash 4.0-4.2, which predate namerefs.

# make_temp_dir VARNAME [PREFIX] - creates a temp dir, auto-removed at exit.
make_temp_dir() {
  local __cm_var="${1:?make_temp_dir: target variable name required}"
  local __cm_prefix="${2:-${CM_SCRIPT_NAME}}"
  local __cm_dir
  __cm_dir="$(mktemp -d "${TMPDIR:-/tmp}/${__cm_prefix}.XXXXXX")" \
    || die "failed to create temp dir"
  on_exit rm -rf -- "$__cm_dir"
  printf -v "$__cm_var" '%s' "$__cm_dir"
}

# make_temp_file VARNAME [PREFIX] - creates a temp file, auto-removed at exit.
make_temp_file() {
  local __cm_var="${1:?make_temp_file: target variable name required}"
  local __cm_prefix="${2:-${CM_SCRIPT_NAME}}"
  local __cm_file
  __cm_file="$(mktemp "${TMPDIR:-/tmp}/${__cm_prefix}.XXXXXX")" \
    || die "failed to create temp file"
  on_exit rm -f -- "$__cm_file"
  printf -v "$__cm_var" '%s' "$__cm_file"
}

# --- single-instance lock -----------------------------------------------------

# acquire_lock [LOCKFILE]
# Uses `flock` when available (Linux), falls back to an atomic mkdir (portable,
# works on macOS). Both release automatically via the exit trap.
acquire_lock() {
  local lockfile="${1:-${TMPDIR:-/tmp}/${CM_SCRIPT_NAME}.lock}"

  if command -v flock >/dev/null 2>&1; then
    exec {CM_LOCK_FD}>"$lockfile" || die "cannot open lock file: ${lockfile}"
    flock -n "$CM_LOCK_FD" \
      || die 75 "another instance is already running (lock: ${lockfile})"
    on_exit rm -f -- "$lockfile"
  else
    local lockdir="${lockfile}.d"
    mkdir -- "$lockdir" 2>/dev/null \
      || die 75 "another instance is already running (lock: ${lockdir})"
    on_exit rmdir -- "$lockdir"
  fi
  log_debug "acquired lock: ${lockfile}"
}

# --- small helpers ------------------------------------------------------------

# is_true VALUE -> 0 if the value looks affirmative (1/true/yes/on, any case).
is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# human_bytes BYTES -> e.g. "1.4 GiB"
human_bytes() {
  local bytes="${1:-0}" unit
  local -a units=(B KiB MiB GiB TiB PiB)
  local i=0
  # Integer arithmetic only; keep one decimal by scaling to tenths.
  local tenths=$(( bytes * 10 ))
  while (( tenths >= 10240 && i < ${#units[@]} - 1 )); do
    tenths=$(( tenths / 1024 ))
    i=$(( i + 1 ))
  done
  unit="${units[i]}"
  printf '%d.%d %s' $(( tenths / 10 )) $(( tenths % 10 )) "$unit"
}

# confirm PROMPT -> 0 if the user answered yes. Auto-yes when ASSUME_YES is set
# or when stdin is not a TTY (so it never hangs a cron job or CI step).
confirm() {
  local prompt="${1:-Continue?}"
  if is_true "${ASSUME_YES:-no}" || [[ ! -t 0 ]]; then
    log_debug "auto-confirming: ${prompt}"
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  is_true "$reply"
}
