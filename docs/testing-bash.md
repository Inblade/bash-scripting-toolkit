# Testing Bash with bats-core

Shell scripts are usually the least-tested code in an infrastructure repo, which
is unfortunate given they often run as root on production hosts. bats-core
(Bash Automated Testing System) makes them testable with very little ceremony.

---

## Installing

```bash
# macOS
brew install bats-core

# npm
npm install -g bats

# From source, no root required
git clone --depth 1 https://github.com/bats-core/bats-core.git
./bats-core/bin/bats --version

# In CI (GitHub Actions)
- uses: bats-core/bats-action@main
```

The optional helper libraries are worth adding for anything non-trivial:

```bash
git clone https://github.com/bats-core/bats-support.git test/helpers/bats-support
git clone https://github.com/bats-core/bats-assert.git  test/helpers/bats-assert
```

They give you `assert_success`, `assert_failure`, `assert_output --partial`,
`assert_line`, and much better failure messages than bare `[ ]` tests.

---

## Anatomy of a test file

A `.bats` file is Bash with one piece of added syntax: the `@test` block.

```bash
#!/usr/bin/env bats

setup() {
  # Runs before EVERY test in the file.
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO_ROOT}/lib/common.sh"
}

teardown() {
  # Runs after every test, even if it failed.
  rm -f /tmp/fixture
}

setup_file()    { :; }   # once, before the first test in the file
teardown_file() { :; }   # once, after the last test in the file

@test "descriptive name that reads as a sentence" {
  run some_command --flag
  [ "$status" -eq 0 ]
  [[ "$output" == *"expected substring"* ]]
}
```

Run it:

```bash
bats tests/                  # a directory
bats tests/test_common.bats  # one file
bats --tap tests/            # TAP output for CI
bats --filter 'retry' tests/ # only tests whose name matches
bats --jobs 4 tests/         # parallel (needs GNU parallel)
bats --print-output-on-failure tests/
```

---

## The `run` helper

`run` is the core of bats. It executes a command, captures everything, and
**never fails the test itself** — so you assert on the results afterwards.

| Variable | Contents |
|---|---|
| `$status` | exit code of the command |
| `$output` | stdout + stderr combined, trailing newlines stripped |
| `${lines[@]}` | `$output` split into an array of lines |
| `${#lines[@]}` | number of output lines |
| `$stderr`, `$stdout` | separated streams, with `run --separate-stderr` |

```bash
@test "rejects a bad argument" {
  run ./scripts/healthcheck.sh -t notanumber https://example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be an integer"* ]]
}
```

Newer bats supports asserting the status inline, which also silences the
"command not found" warning for expected 127s:

```bash
run -127 some_missing_command
run -2   ./scripts/healthcheck.sh        # expect usage error
```

Without `run`, any non-zero exit fails the test immediately — which is sometimes
exactly what you want for setup steps.

---

## Testing a sourced library

This is the case that trips people up. `lib/common.sh` calls `set -euo pipefail`
and installs `EXIT`/`ERR` traps. Sourcing that directly into the bats process
fights with bats' own control flow and produces confusing results.

Shell out instead, so the library gets its own process:

```bash
@test "die honours a leading numeric exit code" {
  run bash -c "source '${LIB}'; die 42 'boom'"
  [ "$status" -eq 42 ]
  [[ "$output" == *"boom"* ]]
}
```

The cost is quoting gymnastics for multi-line snippets. Keep them short; if a
snippet needs more than about five lines, write it to a fixture script in
`$BATS_TEST_TMPDIR` and run that instead.

---

## Temporary directories

bats provides per-test and per-file scratch space and cleans it up for you:

| Variable | Scope |
|---|---|
| `$BATS_TEST_TMPDIR` | unique per test |
| `$BATS_FILE_TMPDIR` | shared across tests in one file |
| `$BATS_RUN_TMPDIR` | shared across the whole run |
| `$BATS_TEST_DIRNAME` | directory containing the `.bats` file |
| `$BATS_TEST_NAME` | current test's function name |

Always build fixtures under these rather than a fixed `/tmp/foo`, otherwise
parallel runs collide.

---

## Mocking external commands

There is no mocking framework. You manipulate `PATH`.

```bash
setup() {
  MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$MOCK_BIN"
  PATH="${MOCK_BIN}:${PATH}"
}

@test "handles a curl failure" {
  cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
  chmod +x "${MOCK_BIN}/curl"

  run ./scripts/healthcheck.sh -a 1 https://example.internal/healthz
  [ "$status" -eq 1 ]
}
```

To assert on *how* the command was called, have the mock record its arguments:

```bash
cat > "${MOCK_BIN}/aws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${BATS_TEST_TMPDIR}/aws-calls"
exit 0
EOF
chmod +x "${MOCK_BIN}/aws"

run ./scripts/backup-verify.sh /var/backups
grep -q 's3 ls' "${BATS_TEST_TMPDIR}/aws-calls"
```

Caveat: this only intercepts commands resolved through `PATH`. It cannot
intercept builtins (`cd`, `printf`, `[[`) or absolute paths like `/bin/rm`. If
you need to mock something invoked by absolute path, make that path a variable
with a default: `: "${RM_BIN:=/bin/rm}"`.

---

## What is worth testing

Prioritise by blast radius, not by coverage percentage.

**Test these:**

- Argument parsing and validation (cheap, catches real regressions)
- Exit codes for each documented failure mode
- Pure helper functions (`human_bytes`, `is_true`, parsers)
- Retry/backoff logic — attempt counts and status propagation
- Cleanup: that temp files and locks are actually released
- Idempotency: run it twice, assert the same end state
- Edge cases: empty input, missing files, paths with spaces, unicode

**Don't bother testing:**

- That `curl` works
- Trivial one-line wrappers
- Log message wording (brittle; assert on structure, or on a stable substring)

**The highest-value tests in this repo** turned out to be the regression tests:
one asserts that `retry` survives a callee using the same variable names
(dynamic scoping bug), another asserts that `make_temp_dir` actually removes its
directory at exit (a subshell/trap bug that made cleanup silently no-op).
Neither was caught by `bash -n` or ShellCheck — only by executing the code.

---

## Static analysis is not optional

Tests catch behaviour; ShellCheck catches whole categories of bug before you
run anything.

```bash
shellcheck lib/common.sh scripts/*.sh
shellcheck -x scripts/*.sh          # -x follows `source` directives
shellcheck -S warning scripts/*.sh  # only warning and above
```

Silence a specific finding with a justification, never a blanket disable:

```bash
# shellcheck disable=SC2016  # single quotes intentional: awk needs the literal $1
awk '{print $1}' file
```

Findings worth knowing:

| Code | Meaning |
|---|---|
| SC2086 | Unquoted variable (word splitting / globbing) |
| SC2046 | Unquoted command substitution |
| SC2155 | `local x="$(cmd)"` masks the exit status |
| SC2164 | `cd` without `|| exit` |
| SC2181 | Checking `$?` instead of the command directly |
| SC1091 | Cannot follow a sourced file (use `-x` or a `source=` directive) |

`bash -n` is a cheaper first gate — it only parses, so it catches syntax errors
but nothing semantic. Run all three: `bash -n`, `shellcheck`, `bats`.

---

## Wiring it into CI

```yaml
name: shell
on: [push, pull_request]

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Syntax check
        run: |
          for f in lib/*.sh scripts/*.sh; do
            bash -n "$f"
          done

      - name: ShellCheck
        uses: ludeeus/action-shellcheck@master
        with:
          additional_files: 'lib/common.sh'
          severity: warning

      - name: Install bats
        uses: bats-core/bats-action@main

      - name: Run tests
        run: bats --print-output-on-failure --tap tests/
```

Keep the whole gate under a minute. If the shell test suite gets slow enough
that people start skipping it, it has stopped being useful.

---

## Debugging a failing test

```bash
bats --print-output-on-failure tests/      # show output for failures
bats --show-output-of-passing-tests tests/ # show everything
bats --verbose-run tests/                  # print each command as it runs
bats --no-tempdir-cleanup tests/           # keep $BATS_*_TMPDIR for inspection
```

Inside a test, anything on file descriptor 3 is printed immediately without
being captured:

```bash
@test "debugging example" {
  echo "checkpoint: about to run" >&3
  run some_command
  echo "status=$status output=$output" >&3
  [ "$status" -eq 0 ]
}
```
