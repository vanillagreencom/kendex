#!/usr/bin/env bash
# The predicate is env-driven and takes no positional arguments. An unknown
# argument is a configuration error: exit 2 with NO verdict line, before any
# settings or evidence read — a misspelled wrapper flag must never fall
# through to a normal gate evaluation.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREDICATE="$(cd "$TEST_DIR/.." && pwd)/scripts/review-predicate.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== review-predicate rejects unknown arguments without a verdict ==="

# Validation is by argument count, not position: an explicitly empty
# argument, an empty argument smuggling a flag behind it, and any list of
# two or more arguments — help forms included — all reject.
reject_case() {
  local name="$1"; shift
  local out code err
  set +e
  out=$("$PREDICATE" "$@" 2>"$TEST_DIR/.stderr")
  code=$?
  err=$(cat "$TEST_DIR/.stderr"); rm -f "$TEST_DIR/.stderr"
  set -e
  [[ "$code" -eq 2 ]] && ok "$name exits 2" || bad "$name exits 2 (got $code)"
  grep -qF "unknown argument" <<<"$err" && ok "$name names the rejection" || bad "$name names the rejection"
  if grep -q "^verdict=" <<<"$out"; then
    bad "$name emits no verdict line"
  else
    ok "$name emits no verdict line"
  fi
}

reject_case "'--wibble'" --wibble
reject_case "'-x'" -x
reject_case "'extra'" extra
reject_case "'--help=1'" "--help=1"
reject_case "explicitly empty argument" ""
reject_case "empty argument then flag" "" --wibble
reject_case "--help with a trailing argument" --help extra
reject_case "repeated -h" -h -h

out=$("$PREDICATE" --help)
grep -qF "no positional arguments" <<<"$out" && ok "--help states the no-positionals contract" || bad "--help states the no-positionals contract"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
