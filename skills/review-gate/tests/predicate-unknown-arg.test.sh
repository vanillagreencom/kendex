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

for arg in --wibble -x extra "--help=1"; do
  set +e
  out=$("$PREDICATE" "$arg" 2>"$TEST_DIR/.stderr")
  code=$?
  err=$(cat "$TEST_DIR/.stderr"); rm -f "$TEST_DIR/.stderr"
  set -e
  [[ "$code" -eq 2 ]] && ok "'$arg' exits 2" || bad "'$arg' exits 2 (got $code)"
  grep -qF "unknown argument" <<<"$err" && ok "'$arg' names the rejection" || bad "'$arg' names the rejection"
  if grep -q "^verdict=" <<<"$out"; then
    bad "'$arg' emits no verdict line"
  else
    ok "'$arg' emits no verdict line"
  fi
done

out=$("$PREDICATE" --help)
grep -qF "no positional arguments" <<<"$out" && ok "--help states the no-positionals contract" || bad "--help states the no-positionals contract"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
