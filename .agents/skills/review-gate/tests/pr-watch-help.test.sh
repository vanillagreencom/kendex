#!/usr/bin/env bash
# pr-watch.sh -h/--help contract (KEN-556), split from pr-watch.test.sh at
# this seam (the reduction-table suites and their sandbox live there).
# --help must answer before the GH_REPO requirement, with the heredoc as
# the contract's sole home; nothing here needs the predicate or gh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
PW="$SKILL_ROOT/scripts/pr-watch.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted substring: %s\n' "$name" "$needle"
  fi
}

echo "=== pw71: --help answers before the GH_REPO requirement (KEN-556) ==="

# The -h/--help pre-scan runs BEFORE the GH_REPO check — that ordering is
# load-bearing: the contract must be readable with no environment at all.
# Token pins guard the heredoc, the contract's sole home (KEN-555).
set +e
out=$(cd "$TMP_ROOT" && env -u GH_REPO "$PW" --help 2>"$TMP_ROOT/help.err")
rc=$?
set -e
assert_eq "$rc" "0" "pw71: --help exits 0 with GH_REPO unset"
assert_contains "$out" "Usage: pr-watch.sh" "pw71: --help prints usage"
assert_contains "$out" "untracked-claim" "pw71: --help lists the untracked-claim kind"
assert_contains "$out" "unreasoned-decline" "pw71: --help lists the unreasoned-decline kind"
assert_contains "$out" "GLOBAL failures" "pw71: --help carries the exit-2 shapes"

set +e
out=$(cd "$TMP_ROOT" && env -u GH_REPO "$PW" -h 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "0" "pw71b: -h exits 0"
assert_contains "$out" "Usage: pr-watch.sh" "pw71b: -h prints usage"


echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
