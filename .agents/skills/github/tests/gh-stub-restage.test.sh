#!/usr/bin/env bash
# Proof that gh-stub.sh keeps one stem to one verb.
#
# A verb's key is a file stem, so `api-a/b` and `api-a%b` name one file. The
# second staging would overwrite the first without a word, and a call spelled
# either way would take whichever answer landed there. Both hand a staged
# answer to a call nobody staged, which is the fail-open a fake exists to
# prevent, so the second staging is refused and the other spelling's call
# finds nothing.
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

# The resolution half: the claimed stem is not this call's, so it is unstaged
# rather than served the claimant's answer.
if out="$(gh api 'a%b' 2>&1)"; then
  bad "the other spelling was answered" "with the api-a/b answer: $out"
else
  ok "must-fail: the other spelling finds the stem unstaged"
fi

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
# And the refusal runs the other way round: the claim is whichever verb got
# there first, not one spelling the stub prefers.
if out="$(gh api 'a/b' 2>&1)"; then
  bad "the slashed spelling was answered" "with the api-a%b answer: $out"
else
  ok "must-fail: the claim refuses in both directions"
fi

echo "=== a foreign claim falls through to the broad key ==="

# Unstaged for this call is not the same as refused. A stem another verb
# claimed is not KNOWN to this call either, so the one-word `api` staging
# still answers a path the suite never named one at a time — the fallback
# is what makes a claim narrow the answer rather than block the call.
gh_stub_reset
gh_stub_answer 'api-a/b' 'slashed'
gh_stub_answer api 'broad'
eq "$(gh api 'a%b')" "broad" "the foreign spelling falls through to the one-word key"
eq "$(gh api 'a/b')" "slashed" "the claimant still gets its own answer"

echo "=== a one-word call does not take a two-word claim ==="

# The join is blind to arity: the two-word `api user` and the one-word
# command `api-user` both key on `api-user`. The claim is what keeps them
# apart, and without it a suite goes green after the code under test ran a
# command gh does not have.
gh_stub_reset
eq "$(gh api user)" "test-user" "must-fail control: the two-word call still resolves"
if out="$(gh api-user 2>&1)"; then
  bad "the one-word call took the two-word answer" "got: $out"
else
  ok "must-fail: a one-word call does not take a two-word claim"
fi

echo "=== @ is reserved for selector slots ==="

# The stub mints `<stem>@<id>` for a selector's slot. A verb or a call
# carrying `@` addresses one of those slots without ever having staged it,
# and the verb claim above cannot see it because the two names have
# different owners.
gh_stub_reset

status=0
gh_stub_answer 'api-x@1' 'LITERAL' 2>"$err" || status=$?
if [ "$status" -ne 0 ]; then
  ok "must-fail: a staged verb carrying @ is refused"
else
  bad "the reserved verb was staged" "gh_stub_answer exited 0"
fi

gh_stub_answer 'api-graphql:needle' 'SELECTOR'
if out="$(gh api 'graphql@1' 2>&1)"; then
  bad "a call carrying @ reached a selector slot" "got: $out"
else
  ok "must-fail: a call carrying @ does not reach a selector slot"
fi
# The control: the selector still answers the call it was staged for.
eq "$(gh api graphql -f q=needle)" "SELECTOR" "must-fail control: the selector still answers"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
