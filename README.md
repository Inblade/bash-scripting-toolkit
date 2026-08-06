# Bash Scripting Toolkit

[![ci](https://github.com/Inblade/bash-scripting-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/Inblade/bash-scripting-toolkit/actions/workflows/ci.yml)
[![Bash 4.0+](https://img.shields.io/badge/bash-4.0%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A small, reusable Bash library and a set of operational scripts built on top of
it, plus the style and testing notes that go with them.

These are personal working notes and utilities, distilled from writing and
maintaining shell automation in production — CI steps, cron wrappers, container
entrypoints and on-call tooling. The emphasis is on the parts of Bash that fail
quietly: `set -e`'s many exemptions, dynamic scoping, subshells discarding
traps, and `IFS` changing what `"$*"` means. Every rule in the style guide
exists because ignoring it cost someone a debugging session.

Everything here is original material and free of any employer-specific content.

## Repository structure

```
bash-scripting-toolkit/
├── lib/
│   └── common.sh              # strict mode, logging, retry, traps, locking
├── scripts/
│   ├── healthcheck.sh         # probe HTTP endpoints, report latency breakdown
│   ├── log-rotate-check.sh    # detect log rotation that silently stopped
│   └── backup-verify.sh       # verify a backup is recent, intact, restorable
├── tests/
│   └── test_common.bats       # bats-core suite for lib/common.sh
├── docs/
│   ├── style-guide.md         # opinionated conventions and the reasoning
│   └── testing-bash.md        # bats-core, mocking, ShellCheck, CI wiring
├── LICENSE
└── README.md
```

## Requirements

- **Bash 4.0+.** The library refuses to run on older versions. macOS ships Bash
  3.2 as `/bin/bash`; install a current Bash (`brew install bash`) — the
  `#!/usr/bin/env bash` shebang will pick it up.
- `curl` for `healthcheck.sh`; `tar`/`gzip` (and optionally `zstd`, `unzip`) for
  `backup-verify.sh`; `lsof` is optional for `log-rotate-check.sh -o`.
- [bats-core](https://github.com/bats-core/bats-core) to run the test suite.

## Using the library

Source it, do not execute it:

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd curl jq
require_env API_TOKEN

make_temp_dir workdir              # auto-removed at exit
acquire_lock                       # one instance at a time

retry 5 1 -- curl -fsS "https://example.internal/api" -o "${workdir}/out.json"

log_info "fetched $(human_bytes "$(wc -c < "${workdir}/out.json")")"
```

Sourcing `common.sh` sets `set -euo pipefail`, sets `IFS` to newline+tab, and
installs `EXIT`/`ERR`/`INT`/`TERM` traps. That is deliberate but opinionated —
read `docs/style-guide.md` before adopting it in an existing script.

### What the library provides

| Function | Purpose |
|---|---|
| `log_debug` / `log_info` / `log_warn` / `log_error` | Levelled logging to **stderr**. `LOG_LEVEL` filters; `LOG_FORMAT=json` emits one JSON object per line. Honours `NO_COLOR` and non-TTY output. |
| `die [CODE] MSG` | Log at ERROR and exit. Defaults to exit 1. |
| `require_cmd CMD...` | Fail fast (exit 127) listing *every* missing command, not just the first. |
| `require_env VAR...` | Fail fast (exit 78) on unset or empty variables. |
| `require_file PATH...` | Fail fast (exit 66) on unreadable files. |
| `retry N DELAY -- CMD` | Exponential backoff with **full jitter**, capped by `RETRY_MAX_DELAY`. Propagates the command's exit status. |
| `with_timeout SECS CMD` | Wrapper over `timeout`; exit 124 means killed. |
| `on_exit CMD...` | Push a cleanup action. Multiple registrations, run **LIFO**, on normal exit and on INT/TERM. |
| `make_temp_dir VAR [PREFIX]` | Create a temp dir, auto-removed at exit. Assigns to `$VAR`. |
| `make_temp_file VAR [PREFIX]` | Same, for a file. |
| `acquire_lock [FILE]` | Single-instance guard. `flock` where available, atomic `mkdir` fallback. Exit 75 if already held. |
| `is_true VALUE` | Accepts `1/true/yes/y/on`, any case. |
| `human_bytes N` | `1610612736` → `1.5 GiB`. |
| `confirm PROMPT` | Interactive y/N. Auto-approves when `ASSUME_YES` is set or stdin is not a TTY, so it never hangs cron or CI. |

Two API choices are worth flagging, because both are workarounds for real Bash
behaviour rather than preference:

- **`make_temp_dir` takes a variable name instead of printing the path.**
  Command substitution runs in a subshell and Bash resets traps there, so a
  `dir="$(make_temp_dir)"` design would register its cleanup in a subshell that
  immediately exits — the directory would leak every time.
- **`retry` prefixes all its locals (`_cm_r_*`).** Bash is dynamically scoped,
  so a retried function that happens to use `n` or `rc` would otherwise
  overwrite the retry loop's own counter.

Both were caught by the test suite, not by `bash -n` or ShellCheck.

## Using the scripts

Each script supports `-h`, logs to stderr, writes results to stdout, and uses
distinct exit codes (`0` success, `1` check failed, `2` usage error).

```bash
# HTTP health with a full latency breakdown (DNS / connect / TLS / TTFB)
./scripts/healthcheck.sh https://example.internal/healthz
./scripts/healthcheck.sh -t 2 -a 5 -c 204 -s '"status":"ok"' https://example.internal/ready
LOG_FORMAT=json ./scripts/healthcheck.sh -q -f endpoints.txt

# Catch rotation that stopped working (growing file, stale siblings, held inodes)
./scripts/log-rotate-check.sh /var/log/nginx
./scripts/log-rotate-check.sh -m 256 -A 24 -o /var/log/app/app.log

# Prove a backup is recent, intact, non-empty and actually restorable
./scripts/backup-verify.sh /var/backups/app
./scripts/backup-verify.sh -A 8 -c -r -e app/config.yaml /var/backups/app
./scripts/backup-verify.sh -p '*.sql.gz' -m 50 /var/backups/db
```

The scripts are written to be useful in three contexts without modification:
interactively, from cron (`LOG_FORMAT=json`, `-q`), and as a CI gate (non-zero
exit on failure).

## Development

```bash
make check          # lint + syntax + tests, the same three things CI runs
make lint           # shellcheck -x, style severity
make test           # bats suite
make install-hooks  # run lint + syntax before every commit

bats --print-output-on-failure --filter retry tests/   # one group of tests
```

35 tests covering logging and level filtering, JSON escaping, exit-code
conventions, retry semantics, LIFO cleanup ordering, lock contention, temp-file
cleanup, and a sanity pass over every shipped script.

The last three are worth calling out, because they are the tests that catch the
bugs Bash actually produces. Cleanup ordering is asserted to be LIFO, since a
trap that removes a directory before unmounting something inside it fails only
under load. Lock contention is tested with a second process genuinely running,
not a mocked `flock`. And every shipped script is checked for `-h` and for exit
code 2 on a usage error, so the CLI contract cannot rot silently.

CI runs shellcheck at `--severity=style` (warnings are failures), the bats
suite, and a syntax-and-load pass under bash 4.4 and 5.2 to keep the version
floor in the README honest.

## Scope and non-goals

This is a focused toolkit, not a framework. It does not try to provide an
option-parsing DSL, a plugin system, or portability to `sh`/`dash` — it targets
Bash 4+ and uses Bash features freely.

The most important thing in the repo may be the section of the style guide
titled *"know when Bash is the wrong tool"*. Past roughly 300 lines, or as soon
as you need real data structures, Bash stops being the economical choice.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Danylo Kochetov.
