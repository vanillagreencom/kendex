#!/usr/bin/env bash
# Regression tests for orch/scripts/approval-wait (vstack#538).
#
# approval-wait is the GitHub-native approval poller that replaced
# bot-review-wait: it reads ONLY formal review verdicts
# (`gh pr view --json reviewDecision,latestReviews`) plus the unresolved
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
#  11. text mode always prints a result line
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
    if [[ "${2:-}" == "user" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
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
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
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
          echo '{"reviewDecision":"APPROVED","latestReviews":[{"author":{"login":"greptile[bot]"},"state":"APPROVED"}]}'
          ;;
        approved_latest)
          echo '{"reviewDecision":"","latestReviews":[{"author":{"login":"greptile[bot]"},"state":"APPROVED"},{"author":{"login":"colleague"},"state":"COMMENTED"}]}'
          ;;
        changes)
          echo '{"reviewDecision":"","latestReviews":[{"author":{"login":"greptile[bot]"},"state":"CHANGES_REQUESTED"},{"author":{"login":"colleague"},"state":"APPROVED"}]}'
          ;;
        commented_only)
          echo '{"reviewDecision":"","latestReviews":[{"author":{"login":"greptile[bot]"},"state":"COMMENTED"}]}'
          ;;
        required_pending)
          echo '{"reviewDecision":"REVIEW_REQUIRED","latestReviews":[{"author":{"login":"colleague"},"state":"APPROVED"}]}'
          ;;
        none|*)
          echo '{"reviewDecision":"","latestReviews":[]}'
          ;;
      esac
      exit 0
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
