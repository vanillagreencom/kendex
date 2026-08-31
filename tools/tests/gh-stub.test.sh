#!/usr/bin/env bash
# Proof for tools/tests/lib/gh-stub.sh.
#
# A fake that answers wrongly is worse than no fake: the suite it serves goes
# green over a call the code should never have made. So every rule the
# library states is exercised here in both directions — the staged call is
# answered, and the call nobody staged is REFUSED.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
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
. "$REPO_ROOT/tools/tests/lib/gh-stub.sh"

GH_STUB_DIR="$TMP/stage"
export GH_STUB_DIR
gh_stub_install "$TMP/bin" || {
  echo "gh_stub_install failed" >&2
  exit 1
}
PATH="$TMP/bin:$PATH"
export PATH

echo "=== the install ==="

[ -x "$TMP/bin/gh" ] && ok "install writes an executable gh" ||
  bad "install writes an executable gh" "not executable"
eq "$(gh auth status)" "Logged in" "auth status is seeded"
eq "$(gh api user)" "test-user" "api user is seeded"
eq "$(gh repo view --json nameWithOwner | tr -d ' ')" \
  '{"owner":{"login":"owner"},"name":"repo","nameWithOwner":"owner/repo"}' \
  "repo view is seeded"

echo "=== a staged verb answers, an unstaged one is refused ==="

gh_stub_answer pr-list '[]'
eq "$(gh pr list --state open --limit 5)" "[]" "a staged verb answers"

status=0
out="$(gh pr merge 42 --squash 2>&1)" || status=$?
if [ "$status" -ne 0 ] && [ "${out#*nothing staged}" != "$out" ]; then
  ok "must-fail: an unstaged verb is refused, naming the key"
else
  bad "an unstaged verb was not refused" "status=$status out=$out"
fi

# The control for the control: the refusal has to be about staging, not
# about the stub being broken for everything. The same call answers once it
# is staged, through the same stub.
gh_stub_answer pr-merge 'merged'
eq "$(gh pr merge 42 --squash)" "merged" "the refused call answers once staged"

echo "=== the verb is the first two words, flags dropped ==="

gh_stub_answer api-repos/owner/repo/labels/bug '{"name":"bug"}'
eq "$(gh api repos/owner/repo/labels/bug)" '{"name":"bug"}' \
  "an api path is part of the verb"
# A different path is a different verb, so it is refused rather than served
# the first path's answer.
if gh api repos/owner/repo/labels/other >/dev/null 2>&1; then
  bad "a different api path was answered" "the path is not part of the key"
else
  ok "must-fail: a different api path is a different verb"
fi
# The second word is dropped when it is flag-shaped, so `pr list` and
# `pr list --state x` are one verb while `pr --help` keys on `pr` alone.
gh_stub_answer pr 'usage'
eq "$(gh pr --help)" "usage" "a flag-shaped second word is not part of the verb"

# The first word alone is the fallback for every path a suite did not name.
# It is a fallback and not an override: the exact path staged above still
# answers with its own text.
gh_stub_answer api '[]'
eq "$(gh api repos/owner/repo/labels/other)" '[]' \
  "the one-word key answers an unnamed api path"
eq "$(gh api repos/owner/repo/labels/bug)" '{"name":"bug"}' \
  "the named path still wins over the one-word fallback"

echo "=== a sequence answers each call once ==="

gh_stub_answer_seq api-graphql 'page-one'
gh_stub_answer_seq api-graphql 'page-two'
eq "$(gh api graphql -f query=x)" "page-one" "the first call takes the first answer"
eq "$(gh api graphql -f query=x)" "page-two" "the second call takes the second"
if gh api graphql -f query=x >/dev/null 2>&1; then
  bad "a third call was answered" "a sequence past its end must refuse"
else
  ok "must-fail: a call past the last staged answer is refused"
fi
# And it refuses even with the one-word key staged: an exhausted sequence is
# the suite saying the call should not have happened, so a broad `api`
# answer must not swallow it.
gh_stub_answer api '[]'
if gh api graphql -f query=x >/dev/null 2>&1; then
  bad "the one-word key answered an exhausted sequence" \
    "a known key must refuse rather than fall back"
else
  ok "must-fail: the one-word key does not rescue an exhausted sequence"
fi

echo "=== a selector picks between calls of one verb ==="

gh_stub_reset
gh_stub_answer 'api-graphql:mergeQueueEntry' '{"queue":true}'
gh_stub_answer 'api-graphql:reviewThreads' '{"threads":[]}'
eq "$(gh api graphql -f query='{ mergeQueueEntry { id } }')" '{"queue":true}' \
  "the queue selector answers the queue query"
eq "$(gh api graphql -f query='{ reviewThreads { id } }')" '{"threads":[]}' \
  "the threads selector answers the threads query"
# No selector matches and no plain verb is staged: refused, not served the
# first selector's answer.
if gh api graphql -f query='{ somethingElse { id } }' >/dev/null 2>&1; then
  bad "an unmatched query was answered" "a selector must not catch everything"
else
  ok "must-fail: a query matching no selector is refused"
fi
# The plain verb is the fallback when one is staged.
gh_stub_answer api-graphql '{"fallback":true}'
eq "$(gh api graphql -f query='{ somethingElse { id } }')" '{"fallback":true}' \
  "the plain verb catches what no selector matched"

echo "=== a staged failure carries its code and its stderr ==="

gh_stub_reset
gh_stub_fail repo-view 41 'gh: Not Found (HTTP 404)'
err="$TMP/err"
status=0
gh repo view >/dev/null 2>"$err" || status=$?
eq "$status" "41" "the staged exit code is what the stub exits"
if grep -q 'HTTP 404' "$err"; then
  ok "the staged stderr reaches stderr"
else
  bad "the staged stderr was lost" "$(cat "$err")"
fi
# The control: without gh_stub_fail the same verb exits 0, so the assertion
# above is about the staging and not about repo-view always failing.
gh_stub_answer repo-view 'owner/repo'
status=0
gh repo view >/dev/null 2>&1 || status=$?
eq "$status" "0" "must-fail control: the same verb exits 0 when not staged to fail"

echo "=== every call is logged, and reset forgets everything ==="

gh_stub_reset
gh auth status >/dev/null 2>&1
gh api user >/dev/null 2>&1
eq "$(gh_stub_calls | wc -l | tr -d ' ')" "2" "the log holds one line per call"
eq "$(gh_stub_calls | head -1)" "auth status" "the log holds the argv"

gh_stub_answer pr-list '[]'
gh pr list >/dev/null 2>&1
gh_stub_reset
if gh pr list >/dev/null 2>&1; then
  bad "a staged answer survived reset" "reset must clear the staging"
else
  ok "must-fail: reset forgets a staged answer"
fi
eq "$(gh_stub_calls | wc -l | tr -d ' ')" "1" "reset forgets the call log"

echo "=== the stub refuses when it was never staged at all ==="

# A suite that puts the stub on PATH but loses STUB_DIR must not have its
# gh calls silently succeed: an unset STUB_DIR is a broken harness, and a
# broken harness is not a pass.
status=0
out="$(env -u STUB_DIR "$TMP/bin/gh" auth status 2>&1)" || status=$?
if [ "$status" -eq 70 ] && [ "${out#*STUB_DIR}" != "$out" ]; then
  ok "must-fail: an unset STUB_DIR is refused, not answered"
else
  bad "an unset STUB_DIR was not refused" "status=$status out=$out"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
