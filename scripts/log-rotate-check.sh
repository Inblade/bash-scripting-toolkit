#!/usr/bin/env bash
#
# log-rotate-check.sh - detect log rotation that has silently stopped working.
#
# The classic production failure is not "logrotate is down" but "logrotate runs,
# yet one file keeps growing" - usually because the writing process holds the
# old inode open after a rename and nobody sent it SIGHUP (missing copytruncate
# or a missing postrotate). This checks for the symptoms rather than the daemon.
#
# Checks performed per path:
#   1. file size against a threshold
#   2. mtime of the newest rotated sibling (rotation actually happening?)
#   3. filesystem usage of the containing mount
#   4. deleted-but-open files holding disk space (needs lsof, best effort)
#
# Exit status:
#   0  all checks passed
#   1  at least one warning or critical finding
#   2  usage error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_MAX_SIZE_MB=1024
readonly DEFAULT_MAX_AGE_HOURS=48
readonly DEFAULT_DISK_PCT=85

usage() {
  cat <<'EOF'
Usage: log-rotate-check.sh [OPTIONS] PATH [PATH...]

Check that log files are being rotated and are not silently growing.
PATH may be a file or a directory (directories are scanned for *.log).

Options:
  -m MB         warn when a single log exceeds this size (default: 1024)
  -A HOURS      warn when no rotated sibling is newer than this (default: 48)
  -d PERCENT    warn when the containing filesystem exceeds this use% (default: 85)
  -o            also check for deleted-but-open files (requires lsof)
  -h            show this help

Examples:
  log-rotate-check.sh /var/log/nginx
  log-rotate-check.sh -m 256 -A 24 -o /var/log/app/app.log
EOF
}

# file_size_bytes PATH -> bytes (portable across GNU and BSD stat)
file_size_bytes() {
  local path="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c %s -- "$path"          # GNU
  else
    stat -f %z -- "$path"          # BSD / macOS
  fi
}

# file_mtime_epoch PATH -> seconds since epoch
file_mtime_epoch() {
  local path="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c %Y -- "$path"
  else
    stat -f %m -- "$path"
  fi
}

# check_size PATH MAX_MB -> 0 ok, 1 warn
check_size() {
  local path="$1" max_mb="$2"
  local bytes max_bytes
  bytes="$(file_size_bytes "$path")"
  max_bytes=$(( max_mb * 1024 * 1024 ))

  if (( bytes > max_bytes )); then
    log_warn "oversized: ${path} is $(human_bytes "$bytes") (limit ${max_mb} MiB)"
    return 1
  fi
  log_debug "size ok: ${path} = $(human_bytes "$bytes")"
  return 0
}

# check_rotation PATH MAX_AGE_HOURS -> 0 ok, 1 warn
# Looks for siblings named like PATH.1, PATH-20260801.gz, PATH.1.gz and checks
# that at least one of them is recent.
check_rotation() {
  local path="$1" max_age_hours="$2"
  local dir base newest newest_age now cutoff
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"

  now="$(date +%s)"
  cutoff=$(( max_age_hours * 3600 ))

  newest=''
  local candidate
  # -maxdepth keeps us out of nested app directories; -print0 for odd names.
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$path" ]] && continue
    if [[ -z "$newest" ]] || \
       (( $(file_mtime_epoch "$candidate") > $(file_mtime_epoch "$newest") )); then
      newest="$candidate"
    fi
  done < <(find "$dir" -maxdepth 1 -type f \
             \( -name "${base}.*" -o -name "${base}-*" \) -print0 2>/dev/null)

  if [[ -z "$newest" ]]; then
    log_warn "no rotated sibling found for ${path} - is rotation configured?"
    return 1
  fi

  newest_age=$(( now - $(file_mtime_epoch "$newest") ))
  if (( newest_age > cutoff )); then
    log_warn "stale rotation: newest sibling ${newest} is $(( newest_age / 3600 ))h old (limit ${max_age_hours}h)"
    return 1
  fi

  log_debug "rotation ok: ${newest} is $(( newest_age / 3600 ))h old"
  return 0
}

# check_disk PATH MAX_PCT -> 0 ok, 1 warn
check_disk() {
  local path="$1" max_pct="$2"
  local used mount
  # -P forces POSIX single-line output; without it long device names wrap.
  # IFS is newline+tab from the library, so scope a space-splitting IFS here.
  IFS=' ' read -r _ _ _ _ used mount < <(df -P -- "$path" | tail -n 1)
  used="${used%\%}"

  if (( used > max_pct )); then
    log_warn "disk pressure: ${mount} is ${used}% full (limit ${max_pct}%)"
    return 1
  fi
  log_debug "disk ok: ${mount} at ${used}%"
  return 0
}

# check_deleted_open DIR -> 0 ok, 1 warn
# Files unlinked by rotation but still held open keep consuming blocks until the
# writer is restarted or HUPed. This is the single most common "df says full,
# du says empty" cause on a log volume.
check_deleted_open() {
  local dir="$1"
  local out

  if ! command -v lsof >/dev/null 2>&1; then
    log_debug "lsof not available, skipping deleted-open check"
    return 0
  fi

  # lsof exits 1 when nothing matches, which is the normal case here.
  out="$(lsof -nP +L1 -- "$dir" 2>/dev/null | awk 'NR>1' || true)"

  if [[ -n "$out" ]]; then
    log_warn "deleted-but-open files under ${dir} (writer needs SIGHUP or restart):"
    printf '%s\n' "$out" >&2
    return 1
  fi
  log_debug "no deleted-but-open files under ${dir}"
  return 0
}

main() {
  local max_size_mb="$DEFAULT_MAX_SIZE_MB"
  local max_age_hours="$DEFAULT_MAX_AGE_HOURS"
  local disk_pct="$DEFAULT_DISK_PCT"
  local check_open=0
  local opt

  while getopts ':m:A:d:oh' opt; do
    case "$opt" in
      m) max_size_mb="$OPTARG" ;;
      A) max_age_hours="$OPTARG" ;;
      d) disk_pct="$OPTARG" ;;
      o) check_open=1 ;;
      h) usage; exit 0 ;;
      :) usage >&2; die 2 "option -${OPTARG} requires an argument" ;;
      \?) usage >&2; die 2 "unknown option: -${OPTARG}" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  (( $# > 0 )) || { usage >&2; die 2 "no paths given"; }

  require_cmd find df stat awk tail

  [[ "$max_size_mb"   =~ ^[0-9]+$ ]] || die 2 "-m must be an integer"
  [[ "$max_age_hours" =~ ^[0-9]+$ ]] || die 2 "-A must be an integer"
  [[ "$disk_pct"      =~ ^[0-9]+$ ]] || die 2 "-d must be an integer"

  # Expand directories into their *.log files.
  local -a targets=()
  local -a dirs=()
  local arg f
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      dirs+=("$arg")
      while IFS= read -r -d '' f; do
        targets+=("$f")
      done < <(find "$arg" -maxdepth 1 -type f -name '*.log' -print0 2>/dev/null)
    elif [[ -f "$arg" ]]; then
      targets+=("$arg")
      dirs+=("$(dirname -- "$arg")")
    else
      log_error "not a file or directory: ${arg}"
      exit 1
    fi
  done

  if (( ${#targets[@]} == 0 )); then
    log_warn "no log files matched"
    exit 1
  fi

  log_info "checking ${#targets[@]} log file(s)"

  local findings=0 target
  for target in "${targets[@]}"; do
    check_size     "$target" "$max_size_mb"   || findings=$(( findings + 1 ))
    check_rotation "$target" "$max_age_hours" || findings=$(( findings + 1 ))
    check_disk     "$target" "$disk_pct"      || findings=$(( findings + 1 ))
  done

  if (( check_open )); then
    # Deduplicate directories without relying on sort -u ordering guarantees.
    local -A seen=()
    local dir
    for dir in "${dirs[@]}"; do
      [[ -n "${seen[$dir]:-}" ]] && continue
      seen["$dir"]=1
      check_deleted_open "$dir" || findings=$(( findings + 1 ))
    done
  fi

  # `exit` rather than `return`: a bare `return 1` trips the ERR trap.
  if (( findings > 0 )); then
    log_error "${findings} finding(s)"
    exit 1
  fi

  log_info "all checks passed"
  exit 0
}

main "$@"
