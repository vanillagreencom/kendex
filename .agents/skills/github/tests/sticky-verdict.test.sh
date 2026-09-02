#!/usr/bin/env bash
# Unit tests for the two sticky-comment readers in github-api.sh:
# `compute_sticky_verdict_from_body`, which turns a review comment body into
# approved/changes/pending, and `select_sticky_comment_from_comments`, whose
# known-bot fallback must not adopt an unrelated bot's status comment.
# Fixture-driven — no `gh` calls.
#
# Run:  bash skills/github/tests/sticky-verdict.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
LIB="$TEST_DIR/../scripts/lib/github-api.sh"

# The lib resolves PROJECT_ROOT itself at source time; both readers under
# test are pure string functions that never reach it, gh, or the network.
# shellcheck source=/dev/null
source "$LIB"

# Read up front so a missing or unreadable fixture fails the suite under
# set -e rather than passing an empty body into an assertion.
summary_fixture="$(cat "$FIXTURES/claude_review_summary_comments.json")"
untrusted_fixture="$(cat "$FIXTURES/untrusted_status_comments.json")"

PASS=0
FAIL=0

assert_eq() {
    local got="$1" want="$2" name="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    fi
}

verdict() { compute_sticky_verdict_from_body "$1"; }

echo "=== compute_sticky_verdict_from_body ==="
assert_eq "$(verdict "View job\n- [ ] todo")" "pending" "checklist with no review section = pending"
assert_eq "$(verdict "## Review\n✅ Approved")" "approved" "review section + ✅ + approved = approved"
assert_eq "$(verdict "## Review\n⚠️ changes requested")" "changes" "review section + ⚠️ = changes"
assert_eq "$(verdict "## Review\n✅ Approved with ⚠️ caveats")" "changes" "mixed signals = changes"
summary_body="$(jq -r '.[0].body' <<<"$summary_fixture")"
assert_eq "$(verdict "$summary_body")" "approved" "Claude Review Summary approved despite unrelated changes prose"
assert_eq "$(verdict "Verdict: changes")" "changes" "bare Verdict: changes = changes"
assert_eq "$(verdict "Status: changes")" "changes" "bare Status: changes = changes"
assert_eq "$(verdict "Recommendation: approve")" "approved" "bare Recommendation: approve = approved"
assert_eq "$(verdict "Recommendation: do not approve")" "changes" "negated Recommendation approval = changes"
assert_eq "$(verdict "Verdict: approval not recommended")" "changes" "approval-not-recommended verdict = changes"
assert_eq "$(verdict "Status: pending approval")" "pending" "pending approval directive stays pending"
assert_eq "$(verdict "Status: approval required")" "pending" "approval required directive stays pending"
assert_eq "$(verdict "Verdict: approved; no changes requested but cannot merge")" "changes" "real blocker wins over approved plus no changes requested"
assert_eq "$(verdict "Status: not ready for approval")" "pending" "not-ready-for-approval text stays pending"
assert_eq "$(verdict "Status: not yet approved")" "pending" "not-yet-approved text stays pending"
assert_eq "$(verdict "Status: not ready to approve")" "pending" "not-ready-to-approve text stays pending"
assert_eq "$(verdict "Verdict: approval denied")" "changes" "approval denied text = changes"
assert_eq "$(verdict "Verdict: approval withheld")" "changes" "approval withheld text = changes"
assert_eq "$(verdict "Verdict: rejected")" "changes" "rejected verdict = changes"
assert_eq "$(verdict "Verdict: denied")" "changes" "denied verdict = changes"
assert_eq "$(verdict "Recommendation: no approval")" "changes" "no approval text = changes"

echo
echo "=== select_sticky_comment_from_comments ==="
# The empty selection is only meaningful if the fixture held candidates to
# reject: assert it is non-empty before asserting nothing was picked.
assert_eq "$(jq 'length' <<<"$untrusted_fixture")" "1" "untrusted fixture holds one comment to reject"
selected=$(select_sticky_comment_from_comments "$untrusted_fixture" "review-bot[bot]" true)
assert_eq "$selected" "" "known-bot fallback ignores a non-review bot status comment"
selected=$(select_sticky_comment_from_comments "$summary_fixture" "claude[bot]" false)
assert_eq "$(jq -r '.user.login' <<<"$selected")" "claude[bot]" "the requested bot's own review summary is selected"

echo
echo "----"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
