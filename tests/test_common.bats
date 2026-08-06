#!/usr/bin/env bats
#
# Tests for lib/common.sh
#
# Run with:  bats tests/
# Install:   brew install bats-core   |   npm i -g bats   |   see docs/testing-bash.md

# BATS_TEST_TMPDIR and `run -<status>` both need 1.5+.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  LIB="${REPO_ROOT}/lib/common.sh"
  export LIB

  # Each test gets its own scratch dir. BATS_TEST_TMPDIR is per-test and is
  # cleaned up automatically by bats-core 1.5+.
  TESTDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export TESTDIR
}

# Helper: run a snippet in a fresh bash with the library sourced.
# We deliberately shell out instead of sourcing into the bats process, because
# common.sh installs EXIT/ERR traps and calls `set -e`, which would fight with
# bats' own control flow.
in_lib() {
  bash -c "source '${LIB}'; $1"
}

# --- logging ------------------------------------------------------------------

@test "log_info writes to stderr, not stdout" {
  run bash -c "source '${LIB}'; log_info hello 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "log_info message reaches stderr" {
  run bash -c "source '${LIB}'; log_info hello 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
  [[ "$output" == *"INFO"* ]]
}

@test "LOG_LEVEL filters lower severities" {
  run bash -c "source '${LIB}'; LOG_LEVEL=WARN log_info suppressed 2>&1"
  [ -z "$output" ]

  run bash -c "source '${LIB}'; LOG_LEVEL=WARN log_error shown 2>&1"
  [[ "$output" == *"shown"* ]]
}

@test "multi-argument log messages join with spaces" {
  # Regression test: IFS is newline+tab, so a naive "$*" would split the
  # message across lines.
  run bash -c "source '${LIB}'; log_info one two three 2>&1"
  [[ "$output" == *"one two three"* ]]
  [ "${#lines[@]}" -eq 1 ]
}

@test "LOG_FORMAT=json emits one valid JSON object per line" {
  run bash -c "source '${LIB}'; LOG_FORMAT=json log_warn 'msg' 2>&1"
  [[ "$output" == '{"ts":"'* ]]
  [[ "$output" == *'"level":"WARN"'* ]]
  [[ "$output" == *'"msg":"msg"'* ]]
}

@test "json format escapes quotes and control characters" {
  run bash -c "source '${LIB}'; LOG_FORMAT=json log_info 'a\"b' 2>&1"
  [[ "$output" == *'a\"b'* ]]
  # Must remain a single line even with an embedded quote.
  [ "${#lines[@]}" -eq 1 ]
}

# --- die ----------------------------------------------------------------------

@test "die exits 1 by default" {
  run bash -c "source '${LIB}'; die 'boom'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
}

@test "die honours a leading numeric exit code" {
  run bash -c "source '${LIB}'; die 42 'boom'"
  [ "$status" -eq 42 ]
  [[ "$output" == *"boom"* ]]
}

# --- require_cmd / require_env / require_file ---------------------------------

@test "require_cmd succeeds for commands that exist" {
  run in_lib "require_cmd bash sh"
  [ "$status" -eq 0 ]
}

@test "require_cmd exits 127 and names every missing command" {
  # `run -127` declares the expected status, so bats does not warn about the
  # 127 it would otherwise read as an accidental command-not-found.
  run -127 bash -c "source '${LIB}'; require_cmd definitely_absent_aaa definitely_absent_bbb"
  [[ "$output" == *"definitely_absent_aaa"* ]]
  [[ "$output" == *"definitely_absent_bbb"* ]]
}

@test "require_env exits 78 when a variable is unset or empty" {
  run bash -c "source '${LIB}'; require_env DEFINITELY_UNSET_VAR_XYZ"
  [ "$status" -eq 78 ]

  run bash -c "source '${LIB}'; EMPTY='' require_env EMPTY"
  [ "$status" -eq 78 ]

  run bash -c "source '${LIB}'; SET=value require_env SET"
  [ "$status" -eq 0 ]
}

@test "require_file exits 66 for an unreadable path" {
  run bash -c "source '${LIB}'; require_file '${TESTDIR}/no-such-file'"
  [ "$status" -eq 66 ]

  touch "${TESTDIR}/present"
  run bash -c "source '${LIB}'; require_file '${TESTDIR}/present'"
  [ "$status" -eq 0 ]
}

# --- retry --------------------------------------------------------------------

@test "retry returns 0 immediately when the command succeeds" {
  run bash -c "source '${LIB}'; retry 3 1 -- true"
  [ "$status" -eq 0 ]
}

@test "retry gives up after the requested number of attempts" {
  # Count attempts via an external file; the callee runs in this same shell.
  run bash -c "
    source '${LIB}'
    attempts_file='${TESTDIR}/attempts'
    : > \"\$attempts_file\"
    counter() { echo x >> \"\$attempts_file\"; return 1; }
    RETRY_MAX_DELAY=0 retry 3 0 -- counter
  "
  [ "$status" -eq 1 ]
  [ "$(wc -l < "${TESTDIR}/attempts" | tr -d ' ')" -eq 3 ]
}

@test "retry succeeds on a later attempt and preserves the callee's counter" {
  # Regression test for dynamic scoping: the callee uses variable names that
  # a naive implementation of retry would also use as locals.
  run bash -c "
    source '${LIB}'
    n=0 rc=0 delay=0 attempts=0
    flaky() { n=\$((n+1)); (( n >= 3 )); }
    RETRY_MAX_DELAY=0 retry 5 0 -- flaky
    echo \"calls=\$n\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"calls=3"* ]]
}

@test "retry propagates the command's exit status" {
  run bash -c "
    source '${LIB}'
    fails() { return 7; }
    RETRY_MAX_DELAY=0 retry 2 0 -- fails
  "
  [ "$status" -eq 7 ]
}

@test "retry rejects an empty command" {
  run bash -c "source '${LIB}'; retry 3 1 --"
  [ "$status" -eq 64 ]
}

# --- cleanup traps ------------------------------------------------------------

@test "on_exit callbacks run at exit" {
  run bash -c "
    source '${LIB}'
    on_exit touch '${TESTDIR}/cleaned'
    true
  "
  [ "$status" -eq 0 ]
  [ -f "${TESTDIR}/cleaned" ]
}

@test "on_exit callbacks run in LIFO order" {
  bash -c "
    source '${LIB}'
    on_exit sh -c 'echo first >> ${TESTDIR}/order'
    on_exit sh -c 'echo second >> ${TESTDIR}/order'
    true
  "
  run cat "${TESTDIR}/order"
  [ "${lines[0]}" = "second" ]
  [ "${lines[1]}" = "first" ]
}

@test "on_exit still runs when the script dies" {
  run bash -c "
    source '${LIB}'
    on_exit touch '${TESTDIR}/cleaned-on-die'
    die 'failing on purpose'
  "
  [ "$status" -eq 1 ]
  [ -f "${TESTDIR}/cleaned-on-die" ]
}

@test "on_exit handles arguments containing spaces" {
  bash -c "
    source '${LIB}'
    on_exit touch '${TESTDIR}/file with spaces'
    true
  "
  [ -f "${TESTDIR}/file with spaces" ]
}

# --- temp files ---------------------------------------------------------------

@test "make_temp_dir creates a directory and removes it at exit" {
  local dir
  # Regression test: the path must be reported AND the directory must actually
  # be gone once the shell exits. An implementation that printed the path from
  # a command substitution would pass the first assertion and fail the second,
  # because the exit trap registration is lost with the subshell.
  dir="$(bash -c "
    source '${LIB}'
    make_temp_dir d bats
    [ -d \"\$d\" ] || exit 1
    echo \"\$d\"
  ")"
  [ -n "$dir" ]
  [ ! -d "$dir" ]
}

@test "make_temp_file creates a file and removes it at exit" {
  local file
  file="$(bash -c "
    source '${LIB}'
    make_temp_file f bats
    [ -f \"\$f\" ] || exit 1
    echo \"\$f\"
  ")"
  [ -n "$file" ]
  [ ! -f "$file" ]
}

@test "make_temp_dir requires a target variable name" {
  run bash -c "source '${LIB}'; make_temp_dir"
  [ "$status" -ne 0 ]
}

# --- locking ------------------------------------------------------------------

@test "acquire_lock blocks a second concurrent instance" {
  local lock="${TESTDIR}/test.lock"

  # First holder sleeps in the background while holding the lock.
  bash -c "source '${LIB}'; acquire_lock '${lock}'; sleep 3" &
  local holder=$!
  sleep 0.5

  run bash -c "source '${LIB}'; acquire_lock '${lock}'"
  [ "$status" -eq 75 ]
  [[ "$output" == *"already running"* ]]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "acquire_lock succeeds once the previous holder is gone" {
  local lock="${TESTDIR}/serial.lock"
  run bash -c "source '${LIB}'; acquire_lock '${lock}'"
  [ "$status" -eq 0 ]
  run bash -c "source '${LIB}'; acquire_lock '${lock}'"
  [ "$status" -eq 0 ]
}

# --- helpers ------------------------------------------------------------------

@test "is_true recognises affirmative values" {
  for v in 1 true TRUE yes Y on; do
    run in_lib "is_true '$v'"
    [ "$status" -eq 0 ]
  done
}

@test "is_true rejects everything else" {
  for v in 0 false no off '' banana; do
    run in_lib "is_true '$v'"
    [ "$status" -ne 0 ]
  done
}

@test "human_bytes formats common magnitudes" {
  run in_lib "human_bytes 0"
  [ "$output" = "0.0 B" ]

  run in_lib "human_bytes 1536"
  [ "$output" = "1.5 KiB" ]

  run in_lib "human_bytes 1048576"
  [ "$output" = "1.0 MiB" ]
}

@test "confirm auto-approves when stdin is not a TTY" {
  run bash -c "source '${LIB}'; confirm 'proceed?' < /dev/null"
  [ "$status" -eq 0 ]
}

@test "confirm auto-approves when ASSUME_YES is set" {
  run bash -c "source '${LIB}'; ASSUME_YES=1 confirm 'proceed?' < /dev/null"
  [ "$status" -eq 0 ]
}

# --- library hygiene ----------------------------------------------------------

@test "sourcing the library twice is a no-op" {
  run bash -c "source '${LIB}'; source '${LIB}'; log_info ok 2>/dev/null"
  [ "$status" -eq 0 ]
}

@test "all shipped scripts pass bash -n" {
  local f
  for f in "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}"/scripts/*.sh; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}

@test "every script exposes -h without error" {
  local f
  for f in "${REPO_ROOT}"/scripts/*.sh; do
    run bash "$f" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "scripts exit 2 on usage errors" {
  run bash "${REPO_ROOT}/scripts/healthcheck.sh"
  [ "$status" -eq 2 ]
}
