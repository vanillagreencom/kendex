# shellcheck shell=bash
#
# The shared assertion vocabulary of the orch waiter suites: the pass/fail
# counters, the stderr dump a failure prints, and the comparisons those suites
# assert with. Each of these stood in the suites as its own copy, so a failure's
# shape depended on which copy a suite happened to hold; here a suite reaches
# for the one it needs rather than deriving it again.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. Sourcing sets PASS and FAIL to 0 and defines the
# helpers; the suite prints its own `pass: N   fail: M` line at the end.
PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

# For checks whose predicate is not a string comparison (exit codes, emptiness).
pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_le() {
  local got="$1" bound="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -le "$bound" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: <= %s\n        got:    %s\n' "$name" "$bound" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}
