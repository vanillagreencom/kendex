#!/usr/bin/env bash
# Proof that gh-stub.sh refuses a colliding restage.
#
# A verb's key is a file stem, so `api-a/b` and `api-a%b` name one file. The
# second staging used to overwrite the first without a word, which hands the
# first verb's answer to a call nobody staged. That is the fail-open a fake
# exists to prevent, so the second staging is refused instead.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}
eq() { # eq GOT WANT NAME
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "wanted [$2], got [$1]"; fi
}

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"

GH_STUB_DIR="$TMP/stage"
export GH_STUB_DIR
gh_stub_install "$TMP/bin" || {
  echo "gh_stub_install failed" >&2
  exit 1
}
PATH="$TMP/bin:$PATH"
export PATH

echo "=== a second verb on one key is refused ==="

gh_stub_answer 'api-a/b' 'slashed'

status=0
err="$TMP/err"
gh_stub_answer 'api-a%b' 'percent' 2>"$err" || status=$?
if [ "$status" -ne 0 ]; then
  ok "must-fail: a second verb on the same key is refused"
else
  bad "the colliding staging was accepted" "gh_stub_answer exited 0"
fi
if grep -q 'api-a/b' "$err" && grep -q 'api-a%b' "$err"; then
  ok "the refusal names the key and the verb holding it"
else
  bad "the refusal named neither verb" "$(cat "$err")"
fi
eq "$(gh api 'a/b')" "slashed" "the first verb keeps its answer"

echo "=== the same verb still restages ==="

# The control: the refusal is about a SECOND verb, not about staging twice.
# Restaging is how a suite says "from here, this", and the seeded identity
# answers exist to be overridden that way.
gh_stub_answer 'api-a/b' 'restaged'
eq "$(gh api 'a/b')" "restaged" "must-fail control: one verb restages itself"
gh_stub_answer api-user 'someone-else'
eq "$(gh api user)" "someone-else" "must-fail control: a seeded answer restages"

echo "=== reset releases the key ==="

# A scenario boundary clears the claim, so the next scenario is free to stage
# the other spelling.
gh_stub_reset
gh_stub_answer 'api-a%b' 'percent'
eq "$(gh api 'a%b')" "percent" "the other verb stages after a reset"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
