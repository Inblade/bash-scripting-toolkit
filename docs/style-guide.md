# Bash Style Guide

An opinionated guide. The rules here are the ones I have seen pay for themselves
in production, usually after a script failed in a way that was hard to diagnose
at 03:00. Where a rule is contentious I say so and give the reasoning rather
than asserting it.

---

## 0. The first rule: know when Bash is the wrong tool

Bash is excellent glue for "run these processes in this order, check their exit
codes". It is a bad general-purpose language. Reach for Python or Go when you
hit any of these:

| Signal | Why Bash hurts |
|---|---|
| You need to parse JSON/YAML/XML | `jq` helps, but nested data in shell variables is misery. No real data structures. |
| Arithmetic beyond integers | Bash has no floating point. You end up shelling out to `bc`/`awk` for every sum. |
| More than ~300 lines | No modules, no namespaces, dynamic scoping, no type checking. Refactoring is unsafe. |
| You need real error handling | No exceptions. `set -e` is full of holes (see below). |
| Concurrency with result aggregation | `wait -n` and job control exist but are fiddly; collecting per-job results means temp files. |
| It will be maintained by people who don't know Bash well | The failure modes are non-obvious and silent. |
| You need unit tests with mocking | bats-core is good, but mocking is PATH manipulation and hope. |
| Performance matters | Every `grep`/`sed`/`awk` in a loop is a fork. A 10k-iteration loop with 3 forks each is 30k processes. |

Rule of thumb: **if the script has more branching logic than process
invocation, it should not be a shell script.** Rewriting a 500-line Bash script
in Python usually halves the line count and makes it testable.

Bash is the right tool for: CI steps, container entrypoints, installers,
health checks, cron wrappers, and anything that is mostly "call these binaries
and check exit codes".

---

## 1. Strict mode, and its very real caveats

Start every script with:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

Use `#!/usr/bin/env bash`, not `#!/bin/bash`: on macOS `/bin/bash` is 3.2 (2007,
GPLv2-era), which lacks associative arrays, `${var,,}`, and `declare -n`.

### What each flag does, and where it fails you

**`set -e` (errexit) is not an error handler.** It is a collection of special
cases. It does *not* trigger when a command is:

```bash
if failing_cmd; then ...; fi     # suppressed - this is the whole point of `if`
failing_cmd && echo ok           # suppressed (left of && or ||)
! failing_cmd                    # suppressed
failing_cmd || true              # suppressed (idiomatic "I don't care")
while failing_cmd; do ...; done  # suppressed
```

The trap that catches people: **suppression is inherited by the whole call
stack.** A function invoked from an `if` runs to completion even if a command
inside it fails:

```bash
process() {
  cp missing_file /tmp/   # fails, but does NOT abort the function
  echo "this still runs"
  rm -rf "$SOME_DIR"      # and so does this
}

if process; then echo "success"; fi   # `process` returns 0 from the final rm
```

This is why `set -e` alone is not enough. Add explicit checks where the failure
matters:

```bash
cp missing_file /tmp/ || die "failed to stage file"
```

Two more `set -e` gotchas worth memorising:

```bash
# 1. Arithmetic evaluating to zero returns exit status 1.
count=0
(( count++ ))    # exit status 1 (returns the PRE-increment value 0) -> script dies
(( count++ )) || true          # fix
count=$(( count + 1 ))         # better fix: assignment always succeeds

# 2. `local` masks the exit status of the command substitution.
local result="$(failing_cmd)"  # `local` succeeds, so $? is 0 and -e never fires
# fix: declare and assign separately
local result
result="$(failing_cmd)"        # now the assignment's status is visible
```

That second one is the single most common silent bug in "strict mode" scripts.
Always split `local` from an assignment whose exit status you care about.

**`set -u` (nounset)** turns unset-variable typos into errors. Its friction
point is arrays and `$@`: on Bash < 4.4, `"${arr[@]}"` on an empty array is an
"unbound variable" error. Use `"${arr[@]:-}"` or guard with
`(( ${#arr[@]} > 0 ))`.

**`set -o pipefail`** makes a pipeline return the first non-zero status rather
than only the last command's. Without it:

```bash
set -e
curl -fsS https://example.internal/data | jq .name    # curl 404s -> jq gets
                                                       # empty input, exits 0,
                                                       # pipeline "succeeds"
```

The cost of pipefail is that benign SIGPIPE failures now count:

```bash
grep -q pattern huge_file | head -1   # head exits early, grep gets SIGPIPE (141)
```

Handle those explicitly with `|| true` when the early exit is intended.

**`IFS=$'\n\t'`** removes the space from the field separator, so unquoted
expansion of a path with spaces splits on fewer boundaries. It is a seatbelt,
not a substitute for quoting. Be aware it changes two things you may not expect:

- `"$*"` joins arguments with the **first character of IFS** — a newline, not a
  space. Multi-word messages come out split across lines.
- `read -r a b c <<< "one two three"` no longer splits on spaces.

Scope an override where you need the default behaviour:

```bash
IFS=' ' read -r code time_total <<< "$metrics"
```

`lib/common.sh` in this repo hits both cases and handles them explicitly; see
`_cm_log` and `probe_one`.

---

## 2. Quoting

**Quote every expansion unless you have a specific reason not to.**

```bash
rm -rf "$dir/$name"        # correct
rm -rf $dir/$name          # if dir="/ tmp" you just deleted /
```

The exceptions, and they are the only ones:

```bash
(( count > 5 ))            # arithmetic context: no word splitting happens
[[ $var == pattern* ]]     # RHS of == in [[ ]] is a pattern; quoting makes it literal
${arr[@]}                  # when you deliberately want each element as one word - use "${arr[@]}"
```

Note the difference, it matters:

```bash
[[ $file == *.txt ]]       # glob match  -> true for "a.txt"
[[ $file == "*.txt" ]]     # literal match -> only true for the string "*.txt"
```

Prefer `"${var}"` over `"$var"` when adjacent to other characters:

```bash
echo "${name}_suffix"      # unambiguous
echo "$name_suffix"        # expands the variable $name_suffix - almost certainly a bug
```

Use `--` before user-controlled paths so a filename starting with `-` is not
parsed as an option:

```bash
rm -f -- "$file"
grep -- "$pattern" "$file"
```

---

## 3. `[[ ]]` over `[ ]`

Always use `[[ ]]` in Bash. `[` is an ordinary command whose arguments undergo
word splitting; `[[` is shell syntax and does not.

```bash
[ $var = "value" ]         # breaks if $var is empty or contains spaces
[[ $var == "value" ]]      # safe
```

`[[ ]]` also gives you:

```bash
[[ $string == pre* ]]           # glob matching
[[ $string =~ ^[0-9]+$ ]]       # regex; captures land in ${BASH_REMATCH[@]}
[[ -n $a && -z $b ]]            # && and || work directly, no -a/-o
[[ $file1 -nt $file2 ]]         # newer-than
```

Do not quote the regex on the right of `=~` — quoting makes it a literal string:

```bash
[[ $v =~ ^[0-9]+$ ]]       # regex
[[ $v =~ "^[0-9]+$" ]]     # literal - matches only that exact text
```

For a regex held in a variable, assign it first and use it unquoted:

```bash
local re='^v[0-9]+\.[0-9]+$'
[[ $version =~ $re ]]
```

Use `(( ))` for arithmetic comparisons — it reads better than `-gt`/`-lt`:

```bash
(( retries > max_retries ))
```

---

## 4. Functions

- One job per function. If you cannot name it in a verb phrase, split it.
- `local` every variable. Bash uses **dynamic scoping**: a function sees and can
  overwrite its caller's locals. This is a genuine source of production bugs.
- Return status codes; print results to stdout; log to stderr.
- Put `main "$@"` at the bottom so the whole file parses before anything runs.
  A script without this can execute a half-downloaded copy of itself.

### The dynamic scoping hazard

Because a callee can clobber a caller's locals, any function that invokes
*arbitrary* user-supplied code must namespace its own variables:

```bash
retry() {
  local n=1              # BAD: if the retried command also uses `n`,
  ...                    # it overwrites this counter and the loop misbehaves
}

retry() {
  local _cm_r_n=1        # GOOD: prefixed, effectively private
}
```

This repo's `retry` had exactly this bug during development. The retried
function used `n` as a counter, silently corrupted `retry`'s attempt counter,
and produced nonsensical "attempt 2 ... attempt 4" logs. `bash -n` and
ShellCheck both pass such code happily — only running it reveals the problem.

### Return values

Bash functions return an exit status (0-255), not a value. To return data:

```bash
# Option A: print to stdout, capture with $( )
get_name() { printf '%s' "$name"; }
result="$(get_name)"

# Option B: assign into a caller-named variable (no subshell)
set_name() { printf -v "$1" '%s' "$name"; }
set_name result
```

Prefer Option B when the function also registers cleanup, holds a lock, or
otherwise mutates shell state — **command substitution runs in a subshell, and
Bash resets traps in subshells**, so any `trap`/`on_exit` registration made
inside `$( )` is silently discarded. That is why `make_temp_dir` in
`lib/common.sh` takes a variable name instead of printing the path.

---

## 5. Traps and cleanup

Register cleanup as soon as the resource is created, not at the end:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
```

Points to get right:

- `EXIT` fires on normal exit *and* after `set -e` aborts, so it is the one you
  want. `INT`/`TERM` need their own traps if you want a distinct message or exit
  code.
- A second `trap ... EXIT` **replaces** the first. If you need several cleanup
  actions, push them onto a stack and run them from one handler (see `on_exit`
  in `lib/common.sh`). Run them in LIFO order: unmount before removing the
  mountpoint.
- Cleanup handlers must be idempotent and must not fail. Use `rm -f`, and
  `|| true` on anything that can error.
- A bare `return 1` is itself a failing command and will trigger an `ERR` trap.
  If you have an `ERR` trap that logs "unexpected failure", use `exit 1` for
  *intentional* failure exits so you don't log a false alarm.
- Conventional exit codes: `128 + signal`. SIGINT -> 130, SIGTERM -> 143.

---

## 6. Loops and input

**Never parse `ls`.** Use globs or `find -print0`.

```bash
# Correct: handles spaces, newlines, leading dashes
while IFS= read -r -d '' file; do
  process "$file"
done < <(find . -type f -name '*.log' -print0)

# Correct for simple cases: a glob
shopt -s nullglob             # otherwise an unmatched glob stays literal
for file in ./*.log; do
  process "$file"
done
```

`IFS= read -r` is the correct incantation for reading lines:

- `IFS=` prevents stripping leading/trailing whitespace
- `-r` prevents backslash interpretation
- `-d ''` reads NUL-delimited records

Use process substitution `< <(cmd)`, not `cmd | while`. A piped `while` runs in a
subshell, so variables set inside it are lost:

```bash
count=0
find . -name '*.log' | while read -r f; do count=$((count+1)); done
echo "$count"      # prints 0 - the increments happened in a subshell

count=0
while read -r f; do count=$((count+1)); done < <(find . -name '*.log')
echo "$count"      # correct
```

Also handle a final line with no trailing newline:

```bash
while IFS= read -r line || [[ -n $line ]]; do ...; done < "$file"
```

---

## 7. Avoid useless forks

Every external command is a fork+exec. Bash builtins are free.

```bash
basename "$path"          ->  "${path##*/}"
dirname "$path"           ->  "${path%/*}"
echo "$s" | tr a-z A-Z    ->  "${s^^}"
echo "$s" | sed 's/a/b/'  ->  "${s/a/b}"
echo "$s" | wc -c         ->  "${#s}"
cat file | grep x         ->  grep x file
echo "$(cmd)"             ->  cmd
```

Parameter expansion cheat sheet:

```bash
${var#pattern}     # strip shortest leading match
${var##pattern}    # strip longest leading match
${var%pattern}     # strip shortest trailing match
${var%%pattern}    # strip longest trailing match
${var/old/new}     # replace first
${var//old/new}    # replace all
${var:-default}    # use default if unset/empty
${var:=default}    # use AND assign default
${var:?message}    # error out with message if unset/empty
${var:offset:len}  # substring
${#var}            # length
```

This matters at scale, not in a 20-iteration loop. Optimise the inner loop of a
10,000-item job; leave the readable version everywhere else.

---

## 8. Argument parsing

Use `getopts` for short options. It is a builtin, it is POSIX, and it handles
bundling and `-x value` correctly.

```bash
while getopts ':f:vh' opt; do
  case "$opt" in
    f) file="$OPTARG" ;;
    v) verbose=1 ;;
    h) usage; exit 0 ;;
    :)  die 2 "option -${OPTARG} requires an argument" ;;
    \?) die 2 "unknown option: -${OPTARG}" ;;
  esac
done
shift $(( OPTIND - 1 ))
```

The leading `:` in `':f:vh'` enables silent error handling, which is what lets
you emit your own messages for `:` and `\?`.

`getopts` does **not** support long options. If you need `--long-flag`, either
write a manual `while [[ $# -gt 0 ]]; do case "$1" in ... esac; shift; done`
loop, or accept that you have outgrown Bash.

Always provide `-h`, always write a `usage()` function, and exit **2** on usage
errors (distinct from 1 for runtime failures).

---

## 9. Exit codes

Be deliberate. Callers and monitoring depend on them.

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | general runtime failure |
| 2 | usage error (bad arguments) |
| 64-78 | `sysexits.h` conventions: 64 usage, 66 no input, 69 unavailable, 75 temp fail, 78 config error |
| 126 | command found but not executable |
| 127 | command not found |
| 128+N | killed by signal N (130 = SIGINT, 143 = SIGTERM) |

Reserve distinct codes for conditions a caller might want to distinguish, e.g.
"backup missing" vs "backup corrupt". A monitoring system can then alert
differently without parsing log text.

---

## 10. Security

```bash
# Never build a command string and eval it with untrusted input
eval "rm -rf $user_input"        # catastrophic

# Pass arguments as arguments
rm -rf -- "$user_input"

# Quote to prevent glob/word-splitting surprises
grep -- "$pattern" "$file"

# Don't put secrets on the command line - argv is world-readable via /proc
mysql -p"$PASSWORD"              # visible in `ps aux`
mysql --defaults-file=./my.cnf   # better

# Set a restrictive umask before creating files with sensitive content
umask 077

# Use mktemp, never a predictable path
tmp="$(mktemp)"                  # good
tmp="/tmp/myscript.$$"           # predictable -> symlink attack

# Set a sane PATH in anything running as root or from cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Be careful with `curl | bash`. If you must document it, pin to a tag or digest
and publish a checksum. The pattern is also vulnerable to a server that serves
different content to `curl` than to a browser.

---

## 11. Formatting conventions

- 2-space indent, no tabs.
- Max 80-100 columns.
- `snake_case` for functions and locals; `UPPER_CASE` for exported/global config.
- `readonly` for constants.
- Prefer `printf` over `echo`. `echo` behaviour with `-n`, `-e`, and leading `-`
  varies between shells and builtins; `printf '%s\n' "$x"` is always predictable.
- Use a `# shellcheck source=...` directive above `source` lines so ShellCheck
  can follow them.
- Header comment on every script: what it does, usage, exit codes.

---

## 12. Checklist before merging a script

- [ ] `#!/usr/bin/env bash`, `set -euo pipefail`
- [ ] `bash -n script.sh` passes
- [ ] `shellcheck script.sh` is clean (or has justified inline disables)
- [ ] Every expansion is quoted
- [ ] `local` on every function variable; split `local` from assignments whose status matters
- [ ] Cleanup registered via `trap` at resource-creation time
- [ ] `usage()` and `-h`
- [ ] Distinct, documented exit codes
- [ ] Logs to stderr, results to stdout
- [ ] Idempotent, or clearly documented as not
- [ ] Tested against: missing input, empty input, paths with spaces, no permissions
