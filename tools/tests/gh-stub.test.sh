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

echo "=== one call, one key: an unstaged invocation is never answered ==="

# The key a call resolves to has to name that call and no other. Two shapes
# collided while the words went into the key unencoded: the two-word join made
# `api user` and the one-word `api-user` the same key, and a `/` written as
# `%` made `api a/b` and `api 'a%b'` the same key. Either collision serves a
# staged answer to a call nobody staged, which is the fail-open the converted
# suites came here to escape.
gh_stub_reset
if out="$(gh api-user 2>&1)"; then
  bad "the one-word api-user was answered" "with the seeded api user answer: $out"
else
  ok "must-fail: staging api user does not answer a bare api-user"
fi
# The control: the seeded answer still reaches the call it was staged for, so
# the refusal above is about the one-word spelling and not about the seeding
# having gone missing.
eq "$(gh api user)" "test-user" "must-fail control: api user still answers"

gh_stub_answer 'api-a/b' 'slashed'
if out="$(gh api 'a%b' 2>&1)"; then
  bad "a percent path was answered" "with the staged api a/b answer: $out"
else
  ok "must-fail: staging api a/b does not answer api 'a%b'"
fi
eq "$(gh api 'a/b')" "slashed" "must-fail control: api a/b still answers"
# And the percent path answers once staged under its own key, so the refusal
# is about the key and not about `%` being unstageable.
gh_stub_answer 'api-a%b' 'percent'
eq "$(gh api 'a%b')" "percent" "the percent path answers under its own key"
eq "$(gh api 'a/b')" "slashed" "the slashed path keeps its own answer"

echo "=== the stub and the staging helpers derive one key ==="

# The stub resolves what the helpers stage only while both spell a call the
# same way, and the two spellings live in two files. The refusal names the key
# the stub derived, so they can be compared rather than assumed.
gh_stub_reset
stub_key() { # stub_key ARGV... — the key the stub derives for this call
  local out
  out="$(gh "$@" 2>&1)" && return 1
  out="${out#*nothing staged for }"
  printf '%s' "${out%% (argv:*}"
}
same_key() { # same_key VERB ARGV... — the helpers' key is the stub's key
  local verb="$1"
  shift
  eq "$(stub_key "$@")" "$(_gh_stub_key "$verb")" "one key for $verb"
}
same_key pr-merge pr merge 42 --squash
same_key api-repos/o/r/pulls/1 api repos/o/r/pulls/1
same_key repo-set-default repo set-default
same_key 'api-a%b' api 'a%b'

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

echo "=== restaging a verb that was already served starts a new sequence ==="

# A scenario that stages an answer for a verb the previous scenario already
# consumed is saying "from here, this". Serving the earlier staging instead
# is the fail-open shape: the suite goes green over the wrong response.
gh_stub_reset
gh_stub_answer pr-list 'first-scenario'
gh pr list >/dev/null
gh pr list >/dev/null
gh_stub_answer_seq pr-list 'second-scenario'
status=0
out="$(gh pr list 2>&1)" || status=$?
eq "$status" "0" "a sequence staged over a consumed answer is not refused"
eq "$out" "second-scenario" "the new sequence answers from its first element"

# The same, with a partly consumed sequence: the unconsumed tail of the old
# one must not answer the new scenario's call.
gh_stub_reset
gh_stub_answer_seq pr-list 'old-one'
gh_stub_answer_seq pr-list 'old-two'
eq "$(gh pr list)" "old-one" "the old sequence answers its first call"
gh_stub_answer_seq pr-list 'new-one'
eq "$(gh pr list)" "new-one" "restaging drops the old sequence's unconsumed tail"
if gh pr list >/dev/null 2>&1; then
  bad "a second call was answered" "the new sequence holds one element"
else
  ok "must-fail: the new sequence ends where it was staged to end"
fi

# The control: staging twice before any call still APPENDS, so the rule above
# is about a served call and not about every restaging clobbering the last.
gh_stub_reset
gh_stub_answer_seq pr-list 'page-one'
gh_stub_answer_seq pr-list 'page-two'
eq "$(gh pr list)" "page-one" "must-fail control: an unserved verb still appends (1)"
eq "$(gh pr list)" "page-two" "must-fail control: an unserved verb still appends (2)"

echo "=== a staging helper aborts when STUB_DIR is empty ==="

# The helpers delete by glob under $STUB_DIR. An empty STUB_DIR would make
# those globs absolute — `rm -f /*.out` — so the expansion has to abort the
# shell instead. Each helper is run in a subshell, which is what the abort
# ends.
aborts_empty() { # aborts_empty HELPER [ARGS...]
  local status=0 out
  out="$(
    export STUB_DIR=""
    "$@" 2>&1
  )" || status=$?
  if [ "$status" -ne 0 ] && [ "${out#*STUB_DIR}" != "$out" ]; then
    ok "must-fail: $1 aborts on an empty STUB_DIR"
  else
    bad "$1 did not abort on an empty STUB_DIR" "status=$status out=$out"
  fi
}

aborts_empty gh_stub_answer pr-list x
aborts_empty gh_stub_answer_seq pr-list x
aborts_empty gh_stub_fail pr-list 1
aborts_empty gh_stub_reset

# The control: the same calls succeed with STUB_DIR set, so the aborts above
# are about the empty value and not about the helpers being broken.
gh_stub_reset
status=0
{ gh_stub_answer pr-list x && gh_stub_answer_seq pr-list y &&
  gh_stub_fail pr-list 1 && gh_stub_reset; } || status=$?
eq "$status" "0" "must-fail control: the same helpers succeed with STUB_DIR set"

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
