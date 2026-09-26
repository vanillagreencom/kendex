# shellcheck shell=bash
#
# The one assertion library of the orch suites: the pass/fail counters, the
# stderr dump a failure prints, and the comparisons the suites assert with.
# Every suite under tests/ sources it, directly or through lib/md.sh or
# lib/oversee-watch-harness.sh, and defines none of these names itself, so how
# an assertion judges and what its failure prints are decided here once.
# assertions.test.sh is its suite, the one suite that judges without it, and
# holds the no-redefinition rule.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. Sourcing sets PASS and FAIL to 0 and defines the
# helpers. Each suite prints its own closing tally, in a shape run-all.sh's
# counts_of parses, and exits non-zero when FAIL is.
PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

# pass NAME and fail NAME [DETAIL], for checks whose predicate is not one of
# the comparisons below (exit codes, emptiness, a suite's own verdict).
pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [[ -z "${2:-}" ]] || printf '        %s\n' "$2"
}

# Every comparison takes GOT or its subject first and NAME third; the optional
# fourth argument is a file of stderr to print under a failure.
assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $want"
    printf '        got:      %s\n' "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_le() {
  local got="$1" bound="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -le "$bound" ]; then
    pass "$name"
  else
    fail "$name" "wanted: <= $bound"
    printf '        got:    %s\n' "$got"
    dump_stderr "$stderr_file"
  fi
}

# A substring match on the whole text, so a needle spanning lines must appear
# whole; `grep -F` would take each of its lines as a pattern of its own.
assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "wanted substring: $needle"
    printf '        in: %s\n' "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$name" "unwanted substring: $needle"
    printf '        in: %s\n' "$haystack"
    dump_stderr "$stderr_file"
  else
    pass "$name"
  fi
}

# The same two over a file's lines. An unreadable file fails either one: a
# file that is not there does not lack the text in the sense a row means.
assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ -f "$file" && -r "$file" ]] && grep -Fq -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name" "missing: $needle"
    printf '        file:    %s\n' "$file"
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    fail "$name" "unreadable file: $file"
  elif grep -Fq -- "$needle" "$file"; then
    fail "$name" "unwanted: $needle"
    printf '        file:      %s\n' "$file"
  else
    pass "$name"
  fi
}
