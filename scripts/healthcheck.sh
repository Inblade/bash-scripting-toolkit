#!/usr/bin/env bash
#
# healthcheck.sh - probe a list of HTTP endpoints and report status.
#
# Exit status:
#   0  every endpoint healthy
#   1  at least one endpoint unhealthy
#   2  usage error
#
# Designed to be usable three ways: interactively, from cron (LOG_FORMAT=json),
# and as a CI gate (non-zero exit on failure).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly DEFAULT_TIMEOUT=5
readonly DEFAULT_ATTEMPTS=3
readonly DEFAULT_EXPECT=200

usage() {
  cat <<'EOF'
Usage: healthcheck.sh [OPTIONS] URL [URL...]
       healthcheck.sh [OPTIONS] -f ENDPOINTS_FILE

Probe HTTP endpoints and report per-endpoint status and latency breakdown.

Options:
  -f FILE       read endpoints from FILE, one URL per line ('#' comments ok)
  -t SECONDS    per-request timeout (default: 5)
  -a ATTEMPTS   attempts per endpoint, with exponential backoff (default: 3)
  -c CODE       expected HTTP status code (default: 200)
  -s SUBSTRING  also require this substring in the response body
  -q            quiet: only report failures
  -h            show this help

Environment:
  LOG_LEVEL     DEBUG|INFO|WARN|ERROR (default INFO)
  LOG_FORMAT    text|json (default text)

Examples:
  healthcheck.sh https://example.internal/healthz
  healthcheck.sh -t 2 -a 5 -c 204 https://example.internal/ready
  LOG_FORMAT=json healthcheck.sh -q -f endpoints.txt
EOF
}

# probe_one URL TIMEOUT EXPECT SUBSTRING -> 0 healthy, 1 unhealthy
# Prints a one-line summary on stdout.
probe_one() {
  local url="$1" timeout="$2" expect="$3" substring="$4"
  local body_file metrics code dns connect tls ttfb total rc=0

  # NOTE: deliberately not using make_temp_file here. probe_one runs inside a
  # command substitution, and Bash resets the EXIT trap in that subshell, so
  # on_exit cleanup would never fire. Clean up explicitly instead.
  body_file="$(mktemp "${TMPDIR:-/tmp}/healthcheck-body.XXXXXX")" \
    || die "failed to create temp file"

  # -w gives the timing breakdown that actually localises a slow endpoint:
  # a large time_namelookup is DNS, a large time_appconnect is TLS, a large
  # time_starttransfer with small connect times is server-side think time.
  local fmt='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}'

  if ! metrics="$(curl --silent --show-error --location \
      --max-time "$timeout" \
      --output "$body_file" \
      --write-out "$fmt" \
      "$url" 2>/dev/null)"; then
    rm -f -- "$body_file"
    printf '%-50s UNREACHABLE\n' "$url"
    return 1
  fi

  # The library sets IFS to newline+tab, so a plain `read` would not split on
  # the spaces in curl's -w output. Scope IFS to this one command.
  IFS=' ' read -r code dns connect tls ttfb total <<<"$metrics"

  if [[ "$code" != "$expect" ]]; then
    printf '%-50s BAD_STATUS code=%s want=%s total=%ss\n' \
      "$url" "$code" "$expect" "$total"
    rc=1
  elif [[ -n "$substring" ]] && ! grep -qF -- "$substring" "$body_file"; then
    printf '%-50s BAD_BODY missing=%s total=%ss\n' "$url" "$substring" "$total"
    rc=1
  else
    printf '%-50s OK code=%s dns=%ss conn=%ss tls=%ss ttfb=%ss total=%ss\n' \
      "$url" "$code" "$dns" "$connect" "$tls" "$ttfb" "$total"
  fi

  rm -f -- "$body_file"
  return "$rc"
}

main() {
  local endpoints_file='' timeout="$DEFAULT_TIMEOUT" attempts="$DEFAULT_ATTEMPTS"
  local expect="$DEFAULT_EXPECT" substring='' quiet=0
  local opt

  while getopts ':f:t:a:c:s:qh' opt; do
    case "$opt" in
      f) endpoints_file="$OPTARG" ;;
      t) timeout="$OPTARG" ;;
      a) attempts="$OPTARG" ;;
      c) expect="$OPTARG" ;;
      s) substring="$OPTARG" ;;
      q) quiet=1 ;;
      h) usage; exit 0 ;;
      :) usage >&2; die 2 "option -${OPTARG} requires an argument" ;;
      \?) usage >&2; die 2 "unknown option: -${OPTARG}" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  require_cmd curl grep mktemp

  [[ "$timeout"  =~ ^[0-9]+$ ]] || die 2 "-t must be an integer, got: ${timeout}"
  [[ "$attempts" =~ ^[0-9]+$ ]] || die 2 "-a must be an integer, got: ${attempts}"
  [[ "$expect"   =~ ^[0-9]{3}$ ]] || die 2 "-c must be a 3-digit code, got: ${expect}"

  local -a urls=()
  if [[ -n "$endpoints_file" ]]; then
    require_file "$endpoints_file"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                 # strip comments
      line="${line#"${line%%[![:space:]]*}"}"  # ltrim
      line="${line%"${line##*[![:space:]]}"}"  # rtrim
      [[ -n "$line" ]] && urls+=("$line")
    done < "$endpoints_file"
  fi
  urls+=("$@")

  if (( ${#urls[@]} == 0 )); then
    usage >&2
    die 2 "no endpoints given"
  fi

  log_info "probing ${#urls[@]} endpoint(s), timeout=${timeout}s attempts=${attempts}"

  local failed=0 url result
  for url in "${urls[@]}"; do
    if [[ "$url" != http://* && "$url" != https://* ]]; then
      log_warn "skipping non-HTTP endpoint: ${url}"
      failed=$(( failed + 1 ))
      continue
    fi

    # retry returns non-zero once all attempts are exhausted; `if` keeps set -e
    # from aborting the loop so we still probe the remaining endpoints.
    if result="$(retry "$attempts" 1 -- \
        probe_one "$url" "$timeout" "$expect" "$substring")"; then
      (( quiet )) || printf '%s\n' "$result"
    else
      printf '%s\n' "$result"
      log_error "unhealthy: ${url}"
      failed=$(( failed + 1 ))
    fi
  done

  # `exit`, not `return`: a bare `return 1` is itself a failing command and
  # would trip the ERR trap, logging a spurious "unexpected failure" for a
  # perfectly intentional outcome.
  if (( failed > 0 )); then
    log_error "${failed}/${#urls[@]} endpoint(s) unhealthy"
    exit 1
  fi

  log_info "all ${#urls[@]} endpoint(s) healthy"
  exit 0
}

main "$@"
