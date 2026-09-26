#!/usr/bin/env bash
# Tests for lib/assertions.sh, the assertion library every other orch suite
# judges with. Each row sources it in a child shell, runs one snippet, and
# compares the counters the child ends with, `PASS FAIL`, against the row.
#
# This suite keeps its own counters rather than sourcing the library: a
# library whose assert_eq passed everything would pass its own test. The
# mismatch row is the library's must-fail control.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
printf 'present\n' > "$TMP_ROOT/file"

OK=0
BAD=0
verdict() { # GOT WANT NAME
  if [[ "$1" == "$2" ]]; then
    OK=$((OK + 1)); printf '  ok    %s\n' "$3"
  else
    BAD=$((BAD + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

# counters SNIPPET — the child's `PASS FAIL` after SNIPPET, or `exit=N` when
# the child died before printing them.
counters() {
  bash -c 'set -euo pipefail; . "$1"; eval "$2" >/dev/null; printf "%s %s" "$PASS" "$FAIL"' \
    bash "$LIB" "$1" || printf 'exit=%s' "$?"
}

# table ROW... — a row is `label|snippet|PASS FAIL`.
table() {
  local row label snippet want
  for row in "$@"; do
    IFS='|' read -r label snippet want <<<"$row"
    [[ -n "$want" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    verdict "$(counters "$snippet")" "$want" "$label"
  done
}

echo "=== each comparison counts a pass or a failure, never both ==="
table \
  'assert_eq on equal values passes|assert_eq x x n|1 0' \
  'must-fail control: assert_eq on unequal values fails|assert_eq x y n|0 1' \
  'assert_le within the bound passes|assert_le 3 3 n|1 0' \
  'assert_le over the bound fails|assert_le 4 3 n|0 1' \
  'assert_le on a non-number fails|assert_le x 3 n|0 1' \
  'assert_contains on a substring passes|assert_contains abc b n|1 0' \
  'assert_contains without it fails|assert_contains abc z n|0 1' \
  "assert_contains takes a needle spanning lines whole|assert_contains \$'a\\nx\\nb' \$'a\\nb' n|0 1" \
  'assert_not_contains without the substring passes|assert_not_contains abc z n|1 0' \
  'assert_not_contains with it fails|assert_not_contains abc b n|0 1' \
  "assert_file_contains on a line of the file passes|assert_file_contains $TMP_ROOT/file pres n|1 0" \
  "assert_file_contains on a missing file fails|assert_file_contains $TMP_ROOT/none x n|0 1" \
  "assert_file_not_contains on text the file lacks passes|assert_file_not_contains $TMP_ROOT/file x n|1 0" \
  "assert_file_not_contains on text the file holds fails|assert_file_not_contains $TMP_ROOT/file pres n|0 1" \
  "assert_file_not_contains on a missing file fails|assert_file_not_contains $TMP_ROOT/none x n|0 1" \
  'pass counts a pass|pass n|1 0' \
  'fail counts a failure, with its detail|fail n detail|0 1'

echo "=== a suite with a failed assertion exits non-zero ==="
# The closing line every suite ends with, after one mismatch.
bash -c 'set -euo pipefail; . "$1"; assert_eq x y n >/dev/null; [[ "$FAIL" -eq 0 ]]' bash "$LIB" \
  && rc=0 || rc=$?
verdict "$rc" "1" "an assert_eq mismatch reddens the suite that made it"

echo
printf 'pass: %d   fail: %d\n' "$OK" "$BAD"
[[ "$BAD" -eq 0 ]]
