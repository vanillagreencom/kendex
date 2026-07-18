#!/usr/bin/env bash
# Regression tests for orch/scripts/approval-wait (vstack#538, vstack#642).
#
# approval-wait is the GitHub-native reviewer-gate poller that replaced
# bot-review-wait: it reads ONLY formal review verdicts
# (`gh pr view --json reviewDecision,latestReviews`, and in --mode review the
# REST pulls/reviews listing pinned to the current head) plus the unresolved
# review-thread count — never emoji reactions, sticky comments, or checklist
# prose. Covers:
#   1. reviewDecision APPROVED               -> approved, exit 0
#   2. empty reviewDecision + latest APPROVED -> approved via fallback, exit 0
#   3. latest CHANGES_REQUESTED               -> changes_requested, exit 1
#   4. COMMENTED-only latest reviews          -> no verdict, timeout, exit 1
#   5. unresolved threads, no verdict         -> comments early return, exit 1
#   6. nothing at all at the deadline         -> timeout, exit 1
#   7. REVIEW_REQUIRED + latest APPROVED      -> NOT approved (protection wants
#                                                more), timeout
#   8. APPROVED with unresolved threads       -> approved, unresolved_count
#                                                reported for the caller's gate
#   9. verdict arriving on a later poll       -> approved after polling
#  10. auth failure with --json               -> parseable error object, exit 3
#  11. text mode always prints a result line; approval-mode lines for
#      changes-requested, comments, and error pinned verbatim (vstack#649)
#  12. review mode: COMMENTED at head, 0 threads -> reviewed, exit 0
#  13. review mode: review at head + threads     -> comments early return
#  14. review mode: review at stale commit only  -> timeout (head pinning)
#  15. review mode: PR author's own review only  -> timeout (author excluded)
#  16. review mode: DISMISSED review only        -> timeout (dismissal excluded)
#  17. review mode: standing CHANGES_REQUESTED   -> changes_requested, exit 1
#  18. review mode: CHANGES_REQUESTED superseded by COMMENTED -> reviewed
#  19. review mode: APPROVED counts as a review  -> reviewed, exit 0
#  20. review mode: review arriving on a later poll -> reviewed after polling
#  21. review mode text output names the review gate for reviewed,
#      changes-requested, comments, timeout, and error — never "Approval"
#      (vstack#649)
#  22+ --resolve-mode precedence: PR_REVIEW_GATE beats legacy PR_APPROVAL_GATE
#      (on -> approval, off -> off), default approval, settings-file source,
#      invalid value falls back to approval
#  nudge1-5: PR_REVIEW_NUDGE/PR_REVIEW_NUDGE_SECS — once per head, clock reset
#      on head change, empty-body fallback to reviewer re-request (or silence
#      with nobody to re-request), approval-mode parity
# Same always-emit-JSON discipline and exit-code contract as ci-wait.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Parametrized `gh` stub (same auth model as the ci_wait stub).
#   STUB_APPROVAL_MODE selects the canned `pr view --json
#   reviewDecision,latestReviews` payload; STUB_THREADS_UNRESOLVED sets the
#   unresolved count returned by the `api graphql` reviewThreads query.
#   STUB_APPROVAL_COUNT_FILE turns *_later modes into poll-count-driven
#   sequences (first poll pending, second poll terminal).
#   Review mode: `pr view --json headRefOid,author` reports head "headsha1"
#   and author "pr-author" (STUB_HEAD_MODE=changes flips to "headsha2" after
#   two calls via STUB_HEAD_COUNT_FILE); STUB_REVIEWS_MODE selects the canned
#   REST pulls/reviews payload, with STUB_REVIEWS_COUNT_FILE driving the
#   reviewed_later poll sequence.
#   Nudges: `pr comment` bodies and requested_reviewers POSTs append to
#   STUB_NUDGE_LOG so tests can count them; STUB_REVIEW_REQUESTS=some makes
#   `pr view --json reviewRequests` report one requested reviewer.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

_stub_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ -n "${STUB_GH_VALID_TOKEN:-}" && "$tok" == "$STUB_GH_VALID_TOKEN" ]] && return 0
    return 1
  fi
  [[ "${STUB_GH_DENY_KEYRING:-0}" == "1" ]] && return 1
  return 0
}

_bump_count() {
  local count=0
  if [[ -f "${STUB_APPROVAL_COUNT_FILE:?}" ]]; then
    count="$(cat "$STUB_APPROVAL_COUNT_FILE")"
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$STUB_APPROVAL_COUNT_FILE"
  printf '%s' "$count"
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if _stub_auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "auth failed" >&2
      exit 1
    fi
    ;;
  api)
    if [[ "$*" == *requested_reviewers* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      payload="$(cat)"
      echo "rerequest:$payload" >> "${STUB_NUDGE_LOG:?}"
      echo '{}'
      exit 0
    fi
    if [[ "${2:-}" == "user" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    if [[ "${2:-}" == repos/*/pulls/*/reviews ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      mode="${STUB_REVIEWS_MODE:-none}"
      if [[ "$mode" == "reviewed_later" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -lt 2 ]]; then
          mode="none"
        else
          mode="commented_at_head"
        fi
      fi
      case "$mode" in
        commented_at_head)
          echo '[{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        commented_stale)
          echo '[{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"oldsha"}]'
          ;;
        author_only)
          echo '[{"user":{"login":"pr-author"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        dismissed_only)
          echo '[{"user":{"login":"reviewer1"},"state":"DISMISSED","commit_id":"headsha1"}]'
          ;;
        changes_standing)
          echo '[{"user":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","commit_id":"headsha1"}]'
          ;;
        changes_superseded)
          echo '[{"user":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","commit_id":"oldsha"},{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        approved_at_head)
          echo '[{"user":{"login":"reviewer1"},"state":"APPROVED","commit_id":"headsha1"}]'
          ;;
        none|*)
          echo '[]'
          ;;
      esac
      exit 0
    fi
    if [[ "${2:-}" == "graphql" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      unresolved="${STUB_THREADS_UNRESOLVED:-0}"
      nodes=""
      for ((i=0; i<unresolved; i++)); do
        [[ -n "$nodes" ]] && nodes+=","
        nodes+='{"isResolved":false}'
      done
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[%s]}}}}}\n' "$nodes"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "comment" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "comment:$*" >> "${STUB_NUDGE_LOG:?}"
      exit 0
    fi
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ "$*" == *reviewRequests* ]]; then
        if [[ "${STUB_REVIEW_REQUESTS:-none}" == "some" ]]; then
          echo '{"reviewRequests":[{"login":"reviewer1"}]}'
        else
          echo '{"reviewRequests":[]}'
        fi
        exit 0
      fi
      if [[ "$*" == *reviewDecision* ]]; then
        mode="${STUB_APPROVAL_MODE:-none}"
        if [[ "$mode" == "approved_later" ]]; then
          count="$(_bump_count)"
          if [[ "$count" -lt 2 ]]; then
            mode="none"
          else
            mode="approved_decision"
          fi
        fi
        case "$mode" in
          approved_decision)
            echo '{"reviewDecision":"APPROVED","headRefOid":"headsha1","latestReviews":[{"author":{"login":"reviewer1"},"state":"APPROVED"}]}'
            ;;
          approved_latest)
            echo '{"reviewDecision":"","headRefOid":"headsha1","latestReviews":[{"author":{"login":"reviewer1"},"state":"APPROVED"},{"author":{"login":"colleague"},"state":"COMMENTED"}]}'
            ;;
          changes)
            echo '{"reviewDecision":"","headRefOid":"headsha1","latestReviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED"},{"author":{"login":"colleague"},"state":"APPROVED"}]}'
            ;;
          commented_only)
            echo '{"reviewDecision":"","headRefOid":"headsha1","latestReviews":[{"author":{"login":"reviewer1"},"state":"COMMENTED"}]}'
            ;;
          required_pending)
            echo '{"reviewDecision":"REVIEW_REQUIRED","headRefOid":"headsha1","latestReviews":[{"author":{"login":"colleague"},"state":"APPROVED"}]}'
            ;;
          none|*)
            echo '{"reviewDecision":"","headRefOid":"headsha1","latestReviews":[]}'
            ;;
        esac
        exit 0
      fi
      if [[ "$*" == *headRefOid* ]]; then
        head="headsha1"
        if [[ "${STUB_HEAD_MODE:-static}" == "changes" ]]; then
          count=0
          if [[ -f "${STUB_HEAD_COUNT_FILE:?}" ]]; then
            count="$(cat "$STUB_HEAD_COUNT_FILE")"
          fi
          count=$((count + 1))
          printf '%s' "$count" > "$STUB_HEAD_COUNT_FILE"
          if [[ "$count" -gt 2 ]]; then
            head="headsha2"
          fi
        fi
        printf '{"headRefOid":"%s","author":{"login":"pr-author"}}\n' "$head"
        exit 0
      fi
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Run approval-wait via the .agents symlink, exactly how it's invoked in
# production. `env "$@"` injects test-controlled env tokens / stub flags.
run_wait_json() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 30 --json)
}

run_wait_json_short() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 3 --json)
}

run_wait_text_short() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 3)
}

run_review_json() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 30 --json --mode review)
}

run_review_json_short() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 3 --json --mode review)
}

run_review_text() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait 1 1 3 --mode review)
}

run_resolve_mode() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait --resolve-mode)
}

json_field() {
  jq -r "$2" <<<"$1" 2>/dev/null || echo "UNPARSEABLE"
}

echo "=== approval-wait verdict detection ==="

# Case 1: reviewDecision APPROVED (branch-protection aggregate).
stderr="$TMP_ROOT/case1.err"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=approved_decision 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case1: reviewDecision APPROVED exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "approved" "case1: status approved" "$stderr"
assert_eq "$(json_field "$output" '.review_decision')" "APPROVED" "case1: review_decision reported" "$stderr"
assert_eq "$(json_field "$output" '.approvals')" "1" "case1: approvals counted" "$stderr"

# Case 2: no required-review protection (empty reviewDecision); one latest
# APPROVED and no CHANGES_REQUESTED approves via the latestReviews fallback.
stderr="$TMP_ROOT/case2.err"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=approved_latest 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case2: latestReviews fallback exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "approved" "case2: status approved via fallback" "$stderr"
assert_eq "$(json_field "$output" '.review_decision')" "" "case2: empty review_decision preserved" "$stderr"
assert_eq "$(json_field "$output" '.approvals')" "1" "case2: COMMENTED latest review not counted as approval" "$stderr"

# Case 3: a reviewer whose latest review is CHANGES_REQUESTED blocks even
# when another reviewer approved.
stderr="$TMP_ROOT/case3.err"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=changes 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case3: changes requested exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "changes_requested" "case3: status changes_requested" "$stderr"
assert_eq "$(json_field "$output" '.changes_requested')" "1" "case3: changes_requested count reported" "$stderr"

# Case 4: COMMENTED-only latest reviews are not a verdict — times out.
stderr="$TMP_ROOT/case4.err"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=commented_only 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case4: commented-only exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case4: commented-only times out (no verdict)" "$stderr"
assert_eq "$(json_field "$output" '.approvals')" "0" "case4: COMMENTED never counts as approval" "$stderr"

# Case 5: unresolved threads with no verdict return early as "comments" so
# the caller can triage instead of idling out the timeout.
stderr="$TMP_ROOT/case5.err"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=none STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case5: pending comments exit 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "comments" "case5: status comments" "$stderr"
assert_eq "$(json_field "$output" '.unresolved_count')" "2" "case5: unresolved_count reported" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds | . < 3')" "true" "case5: comments returns early, not at deadline" "$stderr"

# Case 6: nothing at all by the deadline — timeout, never silent success.
stderr="$TMP_ROOT/case6.err"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=none 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case6: no verdict at deadline exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case6: status timeout" "$stderr"

# Case 7: REVIEW_REQUIRED means branch protection still wants approvals — a
# latest APPROVED review must NOT approve via the fallback.
stderr="$TMP_ROOT/case7.err"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=required_pending 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case7: REVIEW_REQUIRED does not fall back to latestReviews" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case7: status timeout while protection pending" "$stderr"
assert_eq "$(json_field "$output" '.review_decision')" "REVIEW_REQUIRED" "case7: review_decision reported" "$stderr"

# Case 8: approved with unresolved threads still reports approved — the
# caller's zero-unresolved gate owns thread routing — and carries the count.
stderr="$TMP_ROOT/case8.err"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=approved_decision STUB_THREADS_UNRESOLVED=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case8: approved with open threads exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "approved" "case8: status approved" "$stderr"
assert_eq "$(json_field "$output" '.unresolved_count')" "1" "case8: unresolved_count carried for the merge gate" "$stderr"

# Case 9: verdict arriving on a later poll is picked up (first poll empty,
# second poll APPROVED).
stderr="$TMP_ROOT/case9.err"
count_file="$TMP_ROOT/case9-count"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=approved_later STUB_APPROVAL_COUNT_FILE="$count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case9: later approval exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "approved" "case9: status approved after polling" "$stderr"
assert_eq "$(cat "$count_file")" "2" "case9: approval-wait polled again for the verdict" "$stderr"

echo "=== approval-wait output contract ==="

# Case 10: auth failure with --json still yields a parseable error object.
stderr="$TMP_ROOT/case10.err"
set +e
output=$(run_wait_json GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case10: json auth failure exits 3" "$stderr"
assert_eq "$(json_field "$output" '.status')" "error" "case10: json auth failure reports status error" "$stderr"
assert_contains "$(json_field "$output" '.error')" "auth" "case10: json auth failure names auth in error"

# Case 11: text mode always prints a result line.
stderr="$TMP_ROOT/case11.err"
set +e
output=$(run_wait_text_short STUB_APPROVAL_MODE=none 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case11: text-mode timeout exits 1" "$stderr"
assert_contains "$output" "Approval timeout" "case11: text-mode timeout prints result on stdout"

stderr="$TMP_ROOT/case11b.err"
set +e
output=$(run_wait_text_short STUB_APPROVAL_MODE=approved_decision 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case11b: text-mode approval exits 0" "$stderr"
assert_contains "$output" "Approval: approved" "case11b: text-mode approval prints result on stdout"

# Cases 11c-11e: approval-mode text lines are pinned verbatim — the
# review-mode labeling fix (vstack#649) must not touch them.
stderr="$TMP_ROOT/case11c.err"
set +e
output=$(run_wait_text_short STUB_APPROVAL_MODE=changes 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case11c: text-mode changes requested exits 1" "$stderr"
assert_contains "$output" "Approval: changes requested (1 reviewer(s), unresolved threads: 0)" "case11c: approval-mode changes-requested line unchanged"

stderr="$TMP_ROOT/case11d.err"
set +e
output=$(run_wait_text_short STUB_APPROVAL_MODE=none STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case11d: text-mode pending comments exits 1" "$stderr"
assert_contains "$output" "Approval: 2 unresolved review thread(s) pending triage, no approval verdict yet" "case11d: approval-mode comments line unchanged"

stderr="$TMP_ROOT/case11e.err"
set +e
output=$(run_wait_text_short GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case11e: text-mode auth failure exits 3" "$stderr"
assert_contains "$output" "Approval error: no working GitHub auth path" "case11e: approval-mode error line unchanged"

echo "=== approval-wait --mode review gating ==="

# Case 12: a COMMENTED review pinned to the current head with zero unresolved
# threads satisfies the review gate — the commenting-only-bot happy path.
stderr="$TMP_ROOT/case12.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=commented_at_head 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case12: COMMENTED at head exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "case12: status reviewed" "$stderr"
assert_eq "$(json_field "$output" '.mode')" "review" "case12: mode reported" "$stderr"
assert_eq "$(json_field "$output" '.head_sha')" "headsha1" "case12: head_sha reported" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "1" "case12: reviews_at_head counted" "$stderr"

# Case 13: a review at head with unresolved threads is NOT the gate — early
# "comments" return so the caller triages, replies, and resolves first.
stderr="$TMP_ROOT/case13.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=commented_at_head STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case13: review at head + open threads exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "comments" "case13: status comments" "$stderr"
assert_eq "$(json_field "$output" '.unresolved_count')" "2" "case13: unresolved_count reported" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds | . < 3')" "true" "case13: comments returns early, not at deadline" "$stderr"

# Case 14: head pinning — a review of a superseded commit never satisfies the
# gate (this is also the force-push reset: the head is re-read every poll).
stderr="$TMP_ROOT/case14.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=commented_stale 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case14: stale-commit review exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case14: stale-commit review times out" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "0" "case14: stale review not counted at head" "$stderr"

# Case 15: the PR author's own review never satisfies the gate.
stderr="$TMP_ROOT/case15.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=author_only 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case15: author-only review exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case15: author-only review times out" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "0" "case15: author review excluded from head count" "$stderr"

# Case 16: DISMISSED reviews are excluded.
stderr="$TMP_ROOT/case16.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=dismissed_only 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case16: dismissed-only review exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "case16: dismissed-only review times out" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "0" "case16: dismissed review excluded from head count" "$stderr"

# Case 17: a standing CHANGES_REQUESTED from a non-author reviewer blocks the
# review gate even though it is also a review of the head.
stderr="$TMP_ROOT/case17.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=changes_standing 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case17: standing CHANGES_REQUESTED exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "changes_requested" "case17: status changes_requested" "$stderr"
assert_eq "$(json_field "$output" '.changes_requested')" "1" "case17: changes_requested count reported" "$stderr"

# Case 18: a later review by the same reviewer supersedes their earlier
# CHANGES_REQUESTED — latest-per-reviewer, same as GitHub's standing verdict.
stderr="$TMP_ROOT/case18.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=changes_superseded 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case18: superseded CHANGES_REQUESTED exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "case18: status reviewed after supersession" "$stderr"
assert_eq "$(json_field "$output" '.changes_requested')" "0" "case18: superseded verdict no longer stands" "$stderr"

# Case 19: an APPROVED review at head satisfies review mode too — an approval
# is also a review.
stderr="$TMP_ROOT/case19.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=approved_at_head 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case19: APPROVED at head exits 0 in review mode" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "case19: status reviewed for an approval" "$stderr"

# Case 20: a review arriving on a later poll is picked up (first poll no
# reviews, second poll COMMENTED at head).
stderr="$TMP_ROOT/case20.err"
count_file="$TMP_ROOT/case20-count"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=reviewed_later STUB_REVIEWS_COUNT_FILE="$count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case20: later review exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "case20: status reviewed after polling" "$stderr"
assert_eq "$(cat "$count_file")" "2" "case20: approval-wait polled again for the review" "$stderr"

# Case 21: review-mode text output prints a Review result line.
stderr="$TMP_ROOT/case21.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=commented_at_head 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case21: text-mode reviewed exits 0" "$stderr"
assert_contains "$output" "Review: reviewed" "case21: text-mode reviewed prints result on stdout"

# Cases 21b-21e: every review-mode text line names the review gate, never the
# approval gate (vstack#649).
stderr="$TMP_ROOT/case21b.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=changes_standing 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case21b: text-mode review changes requested exits 1" "$stderr"
assert_contains "$output" "Review: changes requested (1 reviewer(s), unresolved threads: 0)" "case21b: review-mode changes-requested names the review gate"

stderr="$TMP_ROOT/case21c.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=commented_at_head STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case21c: text-mode review comments exits 1" "$stderr"
assert_contains "$output" "Review: 2 unresolved review thread(s) pending triage" "case21c: review-mode comments names the review gate"

stderr="$TMP_ROOT/case21d.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=none 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "case21d: text-mode review timeout exits 1" "$stderr"
assert_contains "$output" "Review timeout after" "case21d: review-mode timeout names the review gate"

stderr="$TMP_ROOT/case21e.err"
set +e
output=$(run_review_text GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case21e: text-mode review auth failure exits 3" "$stderr"
assert_contains "$output" "Review error: no working GitHub auth path" "case21e: review-mode error names the review gate"

echo "=== approval-wait --resolve-mode precedence ==="

# PR_REVIEW_GATE wins outright, including over a conflicting legacy value.
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=review)" "review" "resolve: PR_REVIEW_GATE=review"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=off)" "off" "resolve: PR_REVIEW_GATE=off"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=approval)" "approval" "resolve: PR_REVIEW_GATE=approval"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=review PR_APPROVAL_GATE=off)" "review" "resolve: PR_REVIEW_GATE beats legacy PR_APPROVAL_GATE"

# Legacy derivation when PR_REVIEW_GATE is unset: on -> approval, off -> off.
assert_eq "$(run_resolve_mode PR_APPROVAL_GATE=on)" "approval" "resolve: legacy on maps to approval"
assert_eq "$(run_resolve_mode PR_APPROVAL_GATE=off)" "off" "resolve: legacy off maps to off"

# Both unset defaults to approval.
assert_eq "$(run_resolve_mode)" "approval" "resolve: default approval"

# An unrecognized PR_REVIEW_GATE fails safe to approval (gate stays on).
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=bogus 2>/dev/null)" "approval" "resolve: invalid value falls back to approval"

# vstack.settings.toml [env] is read with orch-env precedence: the settings
# value applies when the process env is silent, and process env wins over it.
cat > "$TMP_ROOT/repo/vstack.settings.toml" <<'EOF'
[env]
PR_REVIEW_GATE = "review"
EOF
assert_eq "$(run_resolve_mode)" "review" "resolve: settings-file PR_REVIEW_GATE applies"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=approval)" "approval" "resolve: process env beats settings file"
rm -f "$TMP_ROOT/repo/vstack.settings.toml"

echo "=== approval-wait nudge behavior ==="

nudge_log_lines() {
  if [[ -f "$1" ]]; then
    wc -l < "$1" | tr -d ' '
  else
    echo 0
  fi
}

# Nudge 1: with PR_REVIEW_NUDGE set and the review silent past
# PR_REVIEW_NUDGE_SECS, the configured comment is posted exactly ONCE for the
# unchanged head, no matter how many further nudge windows elapse before the
# overall timeout.
stderr="$TMP_ROOT/nudge1.err"
nudge_log="$TMP_ROOT/nudge1.log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_NUDGE_LOG="$nudge_log" \
  PR_REVIEW_NUDGE_SECS=1 PR_REVIEW_NUDGE="please review" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "nudge1: silent review still times out" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "nudge1: status timeout after nudging" "$stderr"
assert_eq "$(nudge_log_lines "$nudge_log")" "1" "nudge1: nudge posted once per head, never re-posted" "$stderr"
assert_contains "$(cat "$nudge_log" 2>/dev/null)" "please review" "nudge1: nudge posts the configured body" "$stderr"

# Nudge 2: a head change (push/force-push) restarts the nudge clock and
# re-arms the once-per-head nudge — one nudge for each head, two total.
stderr="$TMP_ROOT/nudge2.err"
nudge_log="$TMP_ROOT/nudge2.log"
head_count="$TMP_ROOT/nudge2-head-count"
set +e
output=$(cd "$TMP_ROOT/repo" \
  && PATH="$TMP_ROOT/bin:$PATH" \
     env STUB_REVIEWS_MODE=none STUB_NUDGE_LOG="$nudge_log" \
         STUB_HEAD_MODE=changes STUB_HEAD_COUNT_FILE="$head_count" \
         PR_REVIEW_NUDGE_SECS=1 PR_REVIEW_NUDGE="please review" \
         .agents/skills/orch/scripts/approval-wait 1 1 5 --json --mode review 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "nudge2: still times out across the head change" "$stderr"
assert_eq "$(nudge_log_lines "$nudge_log")" "2" "nudge2: head change re-arms the nudge (one per head)" "$stderr"

# Nudge 3: empty PR_REVIEW_NUDGE falls back to a GitHub-native re-review
# request of the PR's requested reviewers — no comment is posted.
stderr="$TMP_ROOT/nudge3.err"
nudge_log="$TMP_ROOT/nudge3.log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_NUDGE_LOG="$nudge_log" \
  STUB_REVIEW_REQUESTS=some PR_REVIEW_NUDGE_SECS=1 2>"$stderr")
rc=$?
set -e
assert_eq "$(nudge_log_lines "$nudge_log")" "1" "nudge3: empty nudge body re-requests reviewers once" "$stderr"
assert_contains "$(cat "$nudge_log" 2>/dev/null)" "rerequest:" "nudge3: fallback uses the re-review request path" "$stderr"
assert_contains "$(cat "$nudge_log" 2>/dev/null)" "reviewer1" "nudge3: requested reviewer is re-requested" "$stderr"

# Nudge 4: empty nudge body with nobody to re-request (no requested reviewers,
# no past reviews) nudges nothing and just keeps waiting.
stderr="$TMP_ROOT/nudge4.err"
nudge_log="$TMP_ROOT/nudge4.log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_NUDGE_LOG="$nudge_log" \
  PR_REVIEW_NUDGE_SECS=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "nudge4: silent wait still times out with no nudge target" "$stderr"
assert_eq "$(nudge_log_lines "$nudge_log")" "0" "nudge4: nobody to re-request posts nothing" "$stderr"

# Nudge 5: approval mode nudges too — same window, same once-per-head rule.
stderr="$TMP_ROOT/nudge5.err"
nudge_log="$TMP_ROOT/nudge5.log"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=none STUB_NUDGE_LOG="$nudge_log" \
  PR_REVIEW_NUDGE_SECS=1 PR_REVIEW_NUDGE="please review" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "nudge5: approval-mode silent wait still times out" "$stderr"
assert_eq "$(nudge_log_lines "$nudge_log")" "1" "nudge5: approval mode nudges once per head" "$stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
