#!/usr/bin/env bash
# sticky-verdict: the two sticky-comment readers in github-api.sh.
# `compute_sticky_verdict_from_body` turns a review comment body into one of
# approved/changes/pending; `select_sticky_comment_from_comments`, whose
# known-bot fallback must not adopt an unrelated bot's status comment, is
# driven by fixtures below the table. Both are pure string functions: no gh,
# no network.
#
# A row is `label|body|verdict`:
#   body     the comment body, `\n` standing for a newline as GitHub delivers
#            it; `@<name>` is the first comment's body in fixtures/<name>.json
#   verdict  the word the reader prints: approved, changes or pending
set -euo pipefail

# The lib reads the repository root through git at source time; a suite
# running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would point that read elsewhere.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
LIB="$TEST_DIR/../scripts/lib/github-api.sh"
# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# Read up front so a missing or unreadable fixture fails the suite under
# set -e rather than passing an empty body into an assertion.
summary_fixture="$(cat "$FIXTURES/claude_review_summary_comments.json")"
untrusted_fixture="$(cat "$FIXTURES/untrusted_status_comments.json")"

body_of() {
  case "$1" in
    @*) jq -r '.[0].body' "$FIXTURES/${1#@}.json" ;;
    *) printf '%b' "$1" ;;
  esac
}

run() {
  printf 'verdict=%s' "$(compute_sticky_verdict_from_body "$(body_of "$1")")"
}

run_table() {
  local title="$1" rows="$2" label body verdict got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label body verdict <<<"$row"
    for field in "$label" "$body" "$verdict"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run "$body")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "verdict=$verdict" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "compute_sticky_verdict_from_body" "\
an empty body is pending|\\n|pending
a checklist with no review signal is pending|Checklist\\n- [ ] todo|pending
a review section carrying a check mark and approved is approved|## Review\\n✅ Approved|approved
a check-mark approval line outside any section is approved|Looks good.\\n✅ Approved|approved
a review section carrying a warning sign is changes|## Review\\n⚠️ Please take another look|changes
mixed signals under one section are changes|## Review\\n✅ Approved with ⚠️ caveats|changes
the review summary fixture is approved despite prose mentioning changes|@claude_review_summary_comments|approved
a blocker sentence under a review summary heading is changes|### Review Summary\\nThis PR cannot merge until the flaky test is fixed.|changes
a bare Verdict: changes is changes|Verdict: changes|changes
a bare Status: changes is changes|Status: changes|changes
a bare Recommendation: approve is approved|Recommendation: approve|approved
a negated recommendation to approve is changes|Recommendation: do not approve|changes
an approval-not-recommended verdict is changes|Verdict: approval not recommended|changes
a pending-approval status stays pending|Status: pending approval|pending
an approval-required status stays pending|Status: approval required|pending
a pending clause outranks approval text|## Review\\n✅ Approved for merge, awaiting approval from a maintainer|pending
a real blocker wins over approved plus no changes requested|Verdict: approved; no changes requested but cannot merge|changes
a not-ready-for-approval status stays pending|Status: not ready for approval|pending
a not-yet-approved status stays pending|Status: not yet approved|pending
a not-ready-to-approve status stays pending|Status: not ready to approve|pending
an approval-denied verdict is changes|Verdict: approval denied|changes
an approval-withheld verdict is changes|Verdict: approval withheld|changes
a rejected verdict is changes|Verdict: rejected|changes
a denied verdict is changes|Verdict: denied|changes
a no-approval recommendation is changes|Recommendation: no approval|changes
"

echo
echo "=== select_sticky_comment_from_comments ==="
# The empty selection is only meaningful if the fixture held candidates to
# reject: assert it is non-empty before asserting nothing was picked.
assert_eq "$(jq 'length' <<<"$untrusted_fixture")" "1" "untrusted fixture holds one comment to reject"
selected=$(select_sticky_comment_from_comments "$untrusted_fixture" "review-bot[bot]" true)
assert_eq "$selected" "" "known-bot fallback ignores a non-review bot status comment"
selected=$(select_sticky_comment_from_comments "$summary_fixture" "claude[bot]" false)
assert_eq "$(jq -r '.user.login' <<<"$selected")" "claude[bot]" "the requested bot's own review summary is selected"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
