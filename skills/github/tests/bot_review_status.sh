#!/usr/bin/env bash
# Unit tests for bot_review_status_compute (the multi-bot review-signal
# abstraction) and the multi-reviewer verdict aggregation built on it (used
# by pr-review-status consumers).
#
# All tests are fixture-driven — they call bot_review_status_compute with
# preloaded JSON inputs and assert on the returned status/signals. No `gh`
# calls are made.
#
# Run:  bash skills/github/tests/bot_review_status.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
LIB="$TEST_DIR/../scripts/lib/github-api.sh"
PR_REVIEW_STATUS="$TEST_DIR/../scripts/commands/pr-review-status.sh"
SCRIPTS_DIR="$TEST_DIR/../scripts"

# get_repo_info / project root helpers in github-api.sh shell out to gh + git.
# Stub project root to the test dir so `set -u` does not blow up at source time.
PROJECT_ROOT="$TEST_DIR"
# shellcheck source=/dev/null
source "$LIB"

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

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    fi
}

assert_file_eq() {
    local got_file="$1" want="$2" name="$3"
    local got
    got="$(cat "$got_file")"
    assert_eq "$got" "$want" "$name"
}

fx() { cat "$FIXTURES/$1"; }

echo "=== bot_review_status_compute ==="

# --- 1. Claude checklist pending then approved ---
echo "Test 1: Claude checklist pending then approved"

out=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx empty.json)" \
    "$(fx claude_pending_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "pending" "1a status=pending"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:pending" "1a signals contain sticky:pending"

out=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx claude_approved_reviews.json)" \
    "$(fx claude_approved_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "1b status=approved (formal review)"
assert_contains "$(echo "$out" | jq -c .signals)" "formal_review:approved" "1b signals contain formal_review:approved"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:approved" "1b signals contain sticky:approved"

out=$(bot_review_status_compute \
    "claude[bot]" \
    "$(fx empty.json)" \
    "$(fx claude_review_summary_comments.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "1c status=approved (Claude Review Summary comment only)"
assert_contains "$(echo "$out" | jq -c .signals)" "sticky:approved" "1c signals contain sticky:approved"

# --- 2. Codex 👀 only = pending ---
echo "Test 2: Codex eyes-reaction only = pending"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "pending" "2 status=pending"
assert_contains "$(echo "$out" | jq -c .signals)" "reaction:eyes" "2 signals contain reaction:eyes"

# --- 3. Codex inline comments = changes ---
echo "Test 3: Codex inline unresolved threads = changes"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx codex_inline_threads.json)")
assert_eq "$(echo "$out" | jq -r .status)" "changes" "3 status=changes"
assert_eq "$(echo "$out" | jq -r .unresolved_threads)" "1" "3 unresolved_threads=1 (resolved+outdated excluded)"
assert_contains "$(echo "$out" | jq -c .signals)" "inline:1" "3 signals contain inline:1"

# --- 4. Codex 👍 + no unresolved threads = approved ---
echo "Test 4: Codex thumbs-up + no unresolved threads = approved"
out=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_thumbs_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "approved" "4 status=approved"
assert_contains "$(echo "$out" | jq -c .signals)" "reaction:+1" "4 signals contain reaction:+1"

# --- 7. No configured reviewers / no signal = unknown (not approved) ---
echo "Test 7: No signal of any kind = unknown"
out=$(bot_review_status_compute \
    "some-bot[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
assert_eq "$(echo "$out" | jq -r .status)" "unknown" "7 status=unknown"

# --- Aggregation tests (multi-reviewer verdict over compute entries) ---
echo
echo "=== aggregation (verdict + completion) ==="

# Reference aggregate_verdict implementation kept inline so this script does not
# need to source any wrapper (which would also pull in .env loading).
agg() {
    jq -r '
        [.[] | select(.status != "skipped")] as $effective |
        if   ($effective | any(.status == "changes"))  then "changes"
        elif ($effective | any(.status == "pending"))  then "pending"
        elif ($effective | any(.status == "unknown") and ($effective | all(.status != "approved"))) then "pending"
        elif ($effective | any(.status == "approved")) then "approved"
        else "pending" end
    ' <<<"$1"
}
any_blocking() {
    local n
    n=$(jq '[.[] | select(.status == "pending" or .status == "unknown")] | length' <<<"$1")
    [[ "$n" -gt 0 ]]
}

# --- 5. Claude done but Codex pending = pending verdict + blocking ---
echo "Test 5: Claude approved + Codex pending = pending (blocking, not complete)"
claude_entry=$(bot_review_status_compute \
    "review-bot[bot]" \
    "$(fx claude_approved_reviews.json)" \
    "$(fx claude_approved_comments.json)" \
    "$(fx empty.json)" "$(fx empty.json)" "$(fx empty.json)")
codex_entry=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_eyes_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$codex_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "pending" "5 verdict=pending"
if any_blocking "$combined"; then
    PASS=$((PASS + 1)); echo "  ok    5 any_blocking=true (would emit timeout, not complete)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL  5 any_blocking should be true"
fi
# pending_reviewers list includes Codex
pending_list=$(echo "$combined" | jq -c '[.[] | select(.status == "pending" or .status == "unknown") | .reviewer]')
assert_eq "$pending_list" '["chatgpt-codex-connector[bot]"]' "5 pending_reviewers=[codex]"

# --- 6. Both terminal = complete ---
echo "Test 6: Claude approved + Codex approved = complete"
codex_entry=$(bot_review_status_compute \
    "chatgpt-codex-connector[bot]" \
    "$(fx empty.json)" \
    "$(fx empty.json)" \
    "$(fx codex_thumbs_body_reactions.json)" \
    "$(fx empty.json)" \
    "$(fx empty.json)")
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$codex_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "approved" "6 verdict=approved"
if any_blocking "$combined"; then
    FAIL=$((FAIL + 1)); echo "  FAIL  6 any_blocking should be false"
else
    PASS=$((PASS + 1)); echo "  ok    6 any_blocking=false (would emit complete)"
fi

# --- 7b. Skipped reviewer does not block ---
echo "Test 7b: Skipped reviewer is excluded from verdict and blocking"
skipped_entry=$(jq -c -n '{reviewer:"chatgpt-codex-connector[bot]",status:"skipped",signals:["config:skipped"],updated_at:"",unresolved_threads:0}')
combined=$(jq -c -n --argjson a "$claude_entry" --argjson b "$skipped_entry" '[$a, $b]')
assert_eq "$(agg "$combined")" "approved" "7b verdict=approved (skipped excluded)"
if any_blocking "$combined"; then
    FAIL=$((FAIL + 1)); echo "  FAIL  7b any_blocking should be false (skipped is terminal)"
else
    PASS=$((PASS + 1)); echo "  ok    7b skipped is treated as terminal"
fi

# --- 7c. Empty reviewer set (no signal anywhere) = pending verdict ---
echo "Test 7c: Empty reviewer set aggregates to pending (not approved)"
assert_eq "$(agg '[]')" "pending" "7c agg([])=pending"

# --- Review-signal auto-detection ---
echo
echo "=== detect_bot_reviewers_from_inputs ==="
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx mixed_bot_comments.json)" "$(fx empty.json)" | paste -sd, -)
assert_eq "$detected" "claude[bot]" "detect excludes non-review bot linkback comments"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx untrusted_status_comments.json)" "$(fx empty.json)" | paste -sd, -)
assert_eq "$detected" "" "detect excludes untrusted non-review bot status comment"
selected=$(select_sticky_comment_from_comments "$(fx untrusted_status_comments.json)" "review-bot[bot]" true)
assert_eq "$selected" "" "sticky fallback ignores non-review bot status comment"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx empty.json)" "$(fx codex_eyes_body_reactions.json)" | paste -sd, -)
assert_eq "$detected" "chatgpt-codex-connector[bot]" "detect includes known review bot PR-body reaction"
detected=$(detect_bot_reviewers_from_inputs "$(fx empty.json)" "$(fx empty.json)" "$(fx untrusted_body_reactions.json)" | paste -sd, -)
assert_eq "$detected" "" "detect excludes untrusted bot PR-body reaction"

# --- Reaction normalization (REST + GraphQL forms) ---
echo
echo "=== reaction normalization ==="
assert_eq "$(_normalize_reaction_content THUMBS_UP)" "+1"   "norm THUMBS_UP -> +1"
assert_eq "$(_normalize_reaction_content +1)"        "+1"   "norm +1 -> +1"
assert_eq "$(_normalize_reaction_content EYES)"      "eyes" "norm EYES -> eyes"
assert_eq "$(_normalize_reaction_content eyes)"      "eyes" "norm eyes -> eyes"

# --- compute_sticky_verdict_from_body ---
echo
echo "=== compute_sticky_verdict_from_body ==="
assert_eq "$(compute_sticky_verdict_from_body "View job\n- [ ] todo")" "pending" "checklist with no review section = pending"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n✅ Approved")" "approved" "review section + ✅ + approved = approved"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n⚠️ changes requested")" "changes" "review section + ⚠️ = changes"
assert_eq "$(compute_sticky_verdict_from_body "## Review\n✅ Approved with ⚠️ caveats")" "changes" "mixed signals = changes"
assert_eq "$(compute_sticky_verdict_from_body "$(jq -r '.[0].body' "$FIXTURES/claude_review_summary_comments.json")")" "approved" "Claude Review Summary approved despite unrelated changes prose"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: changes")" "changes" "bare Verdict: changes = changes"
assert_eq "$(compute_sticky_verdict_from_body "Status: changes")" "changes" "bare Status: changes = changes"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: approve")" "approved" "bare Recommendation: approve = approved"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: do not approve")" "changes" "negated Recommendation approval = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval not recommended")" "changes" "approval-not-recommended verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Status: pending approval")" "pending" "pending approval directive stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: approval required")" "pending" "approval required directive stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approved; no changes requested but cannot merge")" "changes" "real blocker wins over approved plus no changes requested"
assert_eq "$(compute_sticky_verdict_from_body "Status: not ready for approval")" "pending" "not-ready-for-approval text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: not yet approved")" "pending" "not-yet-approved text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Status: not ready to approve")" "pending" "not-ready-to-approve text stays pending"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval denied")" "changes" "approval denied text = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: approval withheld")" "changes" "approval withheld text = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: rejected")" "changes" "rejected verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Verdict: denied")" "changes" "denied verdict = changes"
assert_eq "$(compute_sticky_verdict_from_body "Recommendation: no approval")" "changes" "no approval text = changes"

# --- pr-review-status production command ---
echo
echo "=== pr-review-status reviewer selection ==="
PR_STATUS_ROOT="$(mktemp -d)"
trap 'rm -rf "$PR_STATUS_ROOT"' EXIT
mkdir -p "$PR_STATUS_ROOT/commands" "$PR_STATUS_ROOT/lib"
cp "$PR_REVIEW_STATUS" "$PR_STATUS_ROOT/commands/pr-review-status.sh"
cp "$FIXTURES/pr-review-status/github-api.sh" "$PR_STATUS_ROOT/lib/github-api.sh"
cp "$FIXTURES/pr-review-status/sticky-comment.sh" "$PR_STATUS_ROOT/commands/sticky-comment.sh"
cp "$FIXTURES/pr-review-status/pr-threads.sh" "$PR_STATUS_ROOT/commands/pr-threads.sh"
chmod +x "$PR_STATUS_ROOT/commands/pr-review-status.sh"
chmod +x "$PR_STATUS_ROOT/commands/sticky-comment.sh"
chmod +x "$PR_STATUS_ROOT/commands/pr-threads.sh"
REVIEW_CALL_LOG="$PR_STATUS_ROOT/reviewer-calls"

status_out=$(BOT_REVIEWERS=' pending-bot , pending-bot-extra , approved-live , unknown-bot , approved-bot ' \
    BOT_SKIPPED_REVIEWERS=' pending-bot , approved-bot ' \
    BOT_REVIEW_STATUS_CALL_LOG="$REVIEW_CALL_LOG" \
    "$PR_STATUS_ROOT/commands/pr-review-status.sh" 42)
assert_eq "$(echo "$status_out" | jq -c '.pending_bot_reviewers')" \
    '["pending-bot-extra","unknown-bot"]' \
    "exact skipped-reviewer matching preserves pending reviewer order"
assert_eq "$(echo "$status_out" | jq -r '.reason')" \
    "pending_bot_reviewer" \
    "remaining pending reviewers keep the pending-bot decision"
assert_file_eq "$REVIEW_CALL_LOG" $'pending-bot-extra\napproved-live\nunknown-bot' \
    "skipped reviewers are not queried and similar reviewer names do not collide"

# Guard every shipped GitHub script, including commands that fixture-driven
# unit tests do not otherwise execute, against Bash 4-only syntax.
echo
echo "=== Bash 3.2 portability ==="
BASH32_PATTERN='mapfile|readarray|declare -[a-zA-Z]*A|local -[a-zA-Z]*A'
BASH32_PATTERN="$BASH32_PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
BASH32_PATTERN="$BASH32_PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'
portability_violations="$(grep -rnE "$BASH32_PATTERN" "$SCRIPTS_DIR" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
assert_eq "$portability_violations" "" "all shipped GitHub scripts avoid Bash 4-only constructs"

echo
echo "----"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
