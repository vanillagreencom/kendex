#!/usr/bin/env bash
# Do the ORCHESTRATOR workflows relay what review-artifact-check reports?
# Split from review_artifact_check_item_schema.sh, which asks what the script
# itself does; every assertion here is about a call site.
#
# Only fail-OPEN contracts live here. A workflow that stops relaying one of
# these accepts a review it should not, and every behavioural suite stays
# green, so nothing else would notice:
#
#   valid_undermeasured + measurement_failed + measurement_suppressed
#       An ok=TRUE reason. A site that routes on ok alone records a review
#       whose own instrument produced nothing as an ordinary pass.
#   the --file freshness boundary
#       `review-artifact-check --file ART` with no boundary argument answers
#       valid for an artifact of any age; the boundary in the workflow prose
#       is the whole of staleness detection, so a site that drops it accepts
#       a previous round's artifact as this round's.
#   the two acceptance forms review-pr.md replaced
#       Return-message-only completion, and an inline `jq -e '.verdict'`
#       branch, are both weaker than the check they gave way to.
#
# Contracts whose loss costs a wasted round rather than a bad accept are NOT
# pinned here: the reviewer-side schema route and self-check are covered by
# skills/reviewer/tests/measurement-fail-closed.test.sh, and submit-pr's
# wait-protocol and launch-failure branches fail closed on their own.
#
# EACH CONTRACT IS PINNED IN TWO HALVES, and neither is sound alone. The
# off-branch half asserts that no mention sits outside an `ok == true` branch;
# on a file with no mentions at all it evaluates to zero and passes. The count
# half is what makes it mean something. Drop one and the pair goes vacuous.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
REVIEW_PR="$REPO_ROOT/skills/orch/workflows/review-pr.md"
SUBMIT_PR="$REPO_ROOT/skills/orch/workflows/submit-pr.md"

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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# wc, not grep -c: grep exits 1 on a zero count, which under `pipefail` would
# make "no bad lines" indistinguishable from a broken command.
mentions() { grep "$2" "$1" | wc -l | tr -d ' '; }
offbranch() { grep "$2" "$1" | grep -v 'ok == true' | wc -l | tr -d ' '; }

echo "=== review-artifact-check: what the orchestrator workflows relay ==="

# --- valid_undermeasured is named at every site that consumes the check ---
# The weaker "the file contains the word" form passed while submit-pr.md § 1
# had the clause hanging off its `ok == false` sentence, which is why the
# assertion is about the CONTEXT of each mention, not the token.
assert_eq "$(offbranch "$REVIEW_PR" valid_undermeasured)" "0" \
  "review-pr.md: every valid_undermeasured mention sits in an ok == true branch"
assert_eq "$(offbranch "$SUBMIT_PR" valid_undermeasured)" "0" \
  "submit-pr.md: every valid_undermeasured mention sits in an ok == true branch"
assert_eq "$(mentions "$REVIEW_PR" valid_undermeasured)" "2" \
  "review-pr.md names it at BOTH its call sites (§ 2.5 external, § 3.1 completion)"
assert_eq "$(mentions "$SUBMIT_PR" valid_undermeasured)" "1" \
  "submit-pr.md § 1 names the undermeasured reason once"
assert_file_contains "$REVIEW_PR" "measurement_failed" "review-pr.md relays the declaration string"
assert_file_contains "$SUBMIT_PR" "measurement_failed" "submit-pr.md relays the declaration string"

# measurement_suppressed exists so a suppression is not invisible, which makes
# a suppression invisible to its readers the one failure it cannot have.
assert_eq "$(offbranch "$REVIEW_PR" measurement_suppressed)" "0" \
  "review-pr.md: every measurement_suppressed mention sits in an ok == true branch"
assert_eq "$(offbranch "$SUBMIT_PR" measurement_suppressed)" "0" \
  "submit-pr.md: every measurement_suppressed mention sits in an ok == true branch"
assert_eq "$(mentions "$REVIEW_PR" measurement_suppressed)" "2" \
  "review-pr.md relays the suppression record at BOTH its call sites"
assert_eq "$(mentions "$SUBMIT_PR" measurement_suppressed)" "1" \
  "submit-pr.md § 1 relays the suppression record"

# --- the --file freshness boundary, and the acceptance forms it replaced ---
assert_file_contains "$REVIEW_PR" 'review-artifact-check --file "$EXTERNAL_OUTPUT"' \
  "review-pr validates external output via --file mode"
assert_file_contains "$REVIEW_PR" 'review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]' \
  "review-pr passes review_delegated_at as the --file freshness boundary"
assert_file_contains "$SUBMIT_PR" 'review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]' \
  "submit-pr passes a delegated-at boundary to the --file freshness check"
assert_file_not_contains "$REVIEW_PR" 'A return message arrives with `Verdict:` and `File:` lines, *or*' \
  "review-pr no longer accepts return-message-only completion"
assert_file_not_contains "$REVIEW_PR" "if jq -e '.verdict'" \
  "review-pr no longer prescribes inline if/redirection for external verdict check"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
