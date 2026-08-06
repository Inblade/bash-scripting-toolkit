#!/usr/bin/env bash
#
# backup-verify.sh - verify that a backup is recent, plausible and restorable.
#
# A backup job exiting 0 proves only that the job ran. The three failures that
# actually bite are: the newest backup is older than you think, the archive is
# truncated or corrupt, and the archive is technically valid but empty because
# the source path moved. This script checks all three, and optionally performs a
# real test restore into a scratch directory.
#
# Exit status:
#   0  backup verified
#   1  verification failed
#   2  usage error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_MAX_AGE_HOURS=26     # daily backup + 2h of slack
readonly DEFAULT_MIN_SIZE_MB=1
readonly DEFAULT_PATTERN='*.tar.gz'

usage() {
  cat <<'EOF'
Usage: backup-verify.sh [OPTIONS] BACKUP_DIR

Verify the newest backup archive in BACKUP_DIR.

Options:
  -p PATTERN    glob for backup files (default: '*.tar.gz')
  -A HOURS      fail if the newest backup is older than this (default: 26)
  -m MB         fail if the newest backup is smaller than this (default: 1)
  -c            verify a checksum sidecar file (.sha256) if present
  -r            perform a test restore into a temp dir and count entries
  -e PATH       after -r, require this path to exist in the restored tree
                (repeatable)
  -h            show this help

Supported archive types: .tar.gz/.tgz, .tar.bz2, .tar.zst, .tar, .zip, .sql.gz

Examples:
  backup-verify.sh /var/backups/app
  backup-verify.sh -A 8 -c -r -e app/config.yaml /var/backups/app
  backup-verify.sh -p '*.sql.gz' -m 50 /var/backups/db
EOF
}

# newest_matching DIR PATTERN -> path of the most recently modified match
newest_matching() {
  local dir="$1" pattern="$2"
  local newest='' candidate

  while IFS= read -r -d '' candidate; do
    if [[ -z "$newest" ]] || [[ "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print0 2>/dev/null)

  [[ -n "$newest" ]] || return 1
  printf '%s' "$newest"
}

# file_size_bytes / file_mtime_epoch - portable across GNU and BSD stat.
file_size_bytes() {
  if stat --version >/dev/null 2>&1; then stat -c %s -- "$1"; else stat -f %z -- "$1"; fi
}
file_mtime_epoch() {
  if stat --version >/dev/null 2>&1; then stat -c %Y -- "$1"; else stat -f %m -- "$1"; fi
}

# check_age FILE MAX_HOURS
check_age() {
  local file="$1" max_hours="$2"
  local age_s
  age_s=$(( $(date +%s) - $(file_mtime_epoch "$file") ))

  if (( age_s > max_hours * 3600 )); then
    log_error "stale: newest backup is $(( age_s / 3600 ))h old (limit ${max_hours}h)"
    return 1
  fi
  log_info "age ok: $(( age_s / 3600 ))h old"
  return 0
}

# check_size FILE MIN_MB
check_size() {
  local file="$1" min_mb="$2"
  local bytes
  bytes="$(file_size_bytes "$file")"

  if (( bytes < min_mb * 1024 * 1024 )); then
    log_error "suspiciously small: $(human_bytes "$bytes") (minimum ${min_mb} MiB)"
    return 1
  fi
  log_info "size ok: $(human_bytes "$bytes")"
  return 0
}

# check_checksum FILE - verify FILE.sha256 sidecar if it exists.
check_checksum() {
  local file="$1"
  local sidecar="${file}.sha256"
  local tool

  if [[ ! -f "$sidecar" ]]; then
    log_warn "no checksum sidecar at ${sidecar}, skipping"
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    tool=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    tool="shasum -a 256"
  else
    log_warn "no sha256sum or shasum available, skipping checksum"
    return 0
  fi

  local expected actual
  IFS=' ' read -r expected _ < "$sidecar"
  IFS=' ' read -r actual _ < <($tool -- "$file")

  if [[ "$expected" != "$actual" ]]; then
    log_error "checksum mismatch: expected ${expected}, got ${actual}"
    return 1
  fi
  log_info "checksum ok: ${actual:0:16}..."
  return 0
}

# check_integrity FILE - decompress/list without extracting.
# This is what catches a truncated archive: the compressor's own CRC fails.
check_integrity() {
  local file="$1"

  case "$file" in
    *.tar.gz|*.tgz)
      require_cmd gzip tar
      gzip -t -- "$file" || { log_error "gzip integrity check failed"; return 1; }
      tar -tzf "$file" >/dev/null || { log_error "tar listing failed"; return 1; }
      ;;
    *.tar.bz2|*.tbz2)
      require_cmd bzip2 tar
      bzip2 -t -- "$file" || { log_error "bzip2 integrity check failed"; return 1; }
      tar -tjf "$file" >/dev/null || { log_error "tar listing failed"; return 1; }
      ;;
    *.tar.zst)
      require_cmd zstd tar
      zstd -t -- "$file" || { log_error "zstd integrity check failed"; return 1; }
      ;;
    *.tar)
      require_cmd tar
      tar -tf "$file" >/dev/null || { log_error "tar listing failed"; return 1; }
      ;;
    *.zip)
      require_cmd unzip
      unzip -t -- "$file" >/dev/null || { log_error "zip integrity check failed"; return 1; }
      ;;
    *.sql.gz|*.gz)
      require_cmd gzip
      gzip -t -- "$file" || { log_error "gzip integrity check failed"; return 1; }
      ;;
    *)
      log_warn "unknown archive type, skipping integrity check: ${file}"
      return 0
      ;;
  esac

  log_info "integrity ok"
  return 0
}

# check_contents FILE - archive is valid but is it non-empty?
check_contents() {
  local file="$1"
  local count

  case "$file" in
    *.tar.gz|*.tgz)   count="$(tar -tzf "$file" | wc -l)" ;;
    *.tar.bz2|*.tbz2) count="$(tar -tjf "$file" | wc -l)" ;;
    *.tar)            count="$(tar -tf  "$file" | wc -l)" ;;
    *.zip)            count="$(unzip -Z1 "$file" | wc -l)" ;;
    *.sql.gz)
      # A dump that decompresses to almost nothing is the "empty backup" case.
      local lines
      lines="$(gzip -dc -- "$file" | head -n 200 | wc -l)"
      if (( lines < 5 )); then
        log_error "SQL dump looks empty (${lines} lines in first 200)"
        return 1
      fi
      log_info "sql dump non-empty"
      return 0
      ;;
    *) log_warn "cannot enumerate contents for ${file}"; return 0 ;;
  esac

  count="${count// /}"
  if (( count == 0 )); then
    log_error "archive contains 0 entries"
    return 1
  fi
  log_info "contents ok: ${count} entries"
  return 0
}

# test_restore FILE EXPECTED_PATHS... - extract to a scratch dir and assert.
# This is the only check that proves the backup is actually restorable.
test_restore() {
  local file="$1"; shift
  local -a expected=("$@")
  local workdir rc=0

  make_temp_dir workdir backup-verify
  log_info "test restore into ${workdir}"

  case "$file" in
    *.tar.gz|*.tgz)   tar -xzf "$file" -C "$workdir" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$file" -C "$workdir" ;;
    *.tar)            tar -xf  "$file" -C "$workdir" ;;
    *.zip)            unzip -q -- "$file" -d "$workdir" ;;
    *.sql.gz)         gzip -dc -- "$file" > "${workdir}/dump.sql" ;;
    *) log_warn "cannot test-restore ${file}"; return 0 ;;
  esac || { log_error "extraction failed"; return 1; }

  local restored
  restored="$(find "$workdir" -mindepth 1 | wc -l)"
  restored="${restored// /}"
  log_info "restored ${restored} entries"

  if (( restored == 0 )); then
    log_error "restore produced no files"
    rc=1
  fi

  local path
  for path in "${expected[@]:-}"; do
    [[ -z "$path" ]] && continue
    if [[ -e "${workdir}/${path}" ]]; then
      log_info "expected path present: ${path}"
    else
      log_error "expected path MISSING from restore: ${path}"
      rc=1
    fi
  done

  return "$rc"
}

main() {
  local pattern="$DEFAULT_PATTERN"
  local max_age="$DEFAULT_MAX_AGE_HOURS"
  local min_size="$DEFAULT_MIN_SIZE_MB"
  local do_checksum=0 do_restore=0
  local -a expected=()
  local opt

  while getopts ':p:A:m:cre:h' opt; do
    case "$opt" in
      p) pattern="$OPTARG" ;;
      A) max_age="$OPTARG" ;;
      m) min_size="$OPTARG" ;;
      c) do_checksum=1 ;;
      r) do_restore=1 ;;
      e) expected+=("$OPTARG") ;;
      h) usage; exit 0 ;;
      :) usage >&2; die 2 "option -${OPTARG} requires an argument" ;;
      \?) usage >&2; die 2 "unknown option: -${OPTARG}" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  (( $# == 1 )) || { usage >&2; die 2 "exactly one BACKUP_DIR is required"; }
  local backup_dir="$1"

  require_cmd find stat date wc
  [[ -d "$backup_dir" ]] || die 2 "not a directory: ${backup_dir}"
  [[ "$max_age"  =~ ^[0-9]+$ ]] || die 2 "-A must be an integer"
  [[ "$min_size" =~ ^[0-9]+$ ]] || die 2 "-m must be an integer"

  # Only one verification run at a time: a test restore can be I/O heavy.
  acquire_lock

  local newest
  if ! newest="$(newest_matching "$backup_dir" "$pattern")"; then
    die 1 "no files matching '${pattern}' in ${backup_dir}"
  fi
  log_info "verifying: ${newest}"

  local failures=0
  check_age       "$newest" "$max_age"  || failures=$(( failures + 1 ))
  check_size      "$newest" "$min_size" || failures=$(( failures + 1 ))
  check_integrity "$newest"             || failures=$(( failures + 1 ))
  check_contents  "$newest"             || failures=$(( failures + 1 ))

  if (( do_checksum )); then
    check_checksum "$newest" || failures=$(( failures + 1 ))
  fi

  if (( do_restore )); then
    test_restore "$newest" "${expected[@]:-}" || failures=$(( failures + 1 ))
  fi

  # `exit` rather than `return`: a bare `return 1` trips the ERR trap.
  if (( failures > 0 )); then
    log_error "verification FAILED: ${failures} check(s) failed for ${newest}"
    exit 1
  fi

  log_info "verification PASSED: ${newest}"
  exit 0
}

main "$@"
