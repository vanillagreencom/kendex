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
#  check1-8: PR_REVIEW_CHECK check-run evidence (vstack#654) — a "success"
#      conclusion of the configured check name on the CURRENT head opens the
#      review gate (newest run of that name wins; review_evidence "check",
#      review_evidence_surface "check_run"); stale-sha and failure
#      conclusions do not; unresolved threads and a standing
#      CHANGES_REQUESTED still block; empty PR_REVIEW_CHECK ignores
#      check-runs entirely; the review-object path still works with the
#      feature on (review_evidence "review"); text mode names the check-run
#      and its app slug
#  status1-8: PR_REVIEW_CHECK commit-status evidence (vstack#681) — with no
#      matching check-run, a "success" commit status with the configured
#      context on the CURRENT head opens the gate (newest of the context
#      wins; review_evidence "check", review_evidence_surface "status"); a
#      matching check-run wins first and skips the status query entirely;
#      pending/failure/error states are not evidence; stale-sha statuses
#      never count; empty PR_REVIEW_CHECK ignores both surfaces; a review
#      object still takes precedence (no surface field); unresolved threads
#      still block; text mode names the status context and its creator
#  22+ --resolve-mode precedence: PR_REVIEW_GATE beats legacy PR_APPROVAL_GATE
#      (on -> approval, off -> off), default approval, settings-file source,
#      invalid value falls back to approval
#  nudge1-5: PR_REVIEW_NUDGE/PR_REVIEW_NUDGE_SECS — once per head, clock reset
#      on head change, empty-body fallback to reviewer re-request (or silence
#      with nobody to re-request), approval-mode parity
#  transient1-4: transient GitHub API failures (vstack#748) — an HTTP 503
#      from the reviews listing (or approval-mode pr view) is absorbed with
#      backoff inside the wait budget and reported as transient_api_errors
#      on the eventual success; a persistent 503 becomes terminal only when
#      the budget expires, preserving the original error message plus the
#      count; an HTTP 404 stays immediately terminal with no count
#   proceed1-13: PR_REVIEW_ON_TIMEOUT reviewer-down flexibility — a deadline
#      reached with zero unresolved threads AND no reviewer evidence AND an
#      unchanged head degrades to "proceeded" (exit 0) under "proceed" (review
#      and approval modes; also via the --on-timeout flag), while open threads
#      still return "comments", a standing CHANGES_REQUESTED still blocks, an
#      active COMMENTED review in approval mode still times out (not silence), a
#      head change during the wait falls back to timeout (no fair window on the
#      new commit), a present-but-not-success trusted check/status (failed or
#      pending) in review mode still times out (engagement, not silence), a head
#      that moved in the final last-poll->emit confirm window falls back to
#      timeout (no proceed/marker on a superseded head), the
#      default is "block" (timeout), and an unrecognized value falls back to
#      block with a warning
#   marker1-6: PR_REVIEW_OUTAGE_CONTEXT reviewer-outage attestation — a
#      review-mode proceed posts the configured context as a success status on
#      the current head (JSON outage_marker "posted"); posts nothing when the
#      context is empty, the deadline did not proceed (timeout), a thread is
#      open, or the mode is approval (review-mode only — approval's silence
#      signal excludes reviewer checks); and a rejected POST still proceeds but
#      reports outage_marker "failed" + a loud warning so the caller can retry/
#      stop rather than idle ci-wait against a gate that got no signal
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
#   Check-runs: `api repos/*/commits/<sha>/check-runs` answers per the sha in
#   the URL — STUB_CHECKS_MODE=success_at_head/failure_at_head publishes a
#   "Review Bot" run (older failure + newer terminal run, plus an unrelated
#   "Other Check") on headsha1 only; success_stale publishes it on oldsha
#   only, so the current-head query finds nothing.
#   Commit statuses: `api repos/*/commits/<sha>/status` (combined status)
#   answers likewise — STUB_STATUS_MODE=success_at_head/pending_at_head/
#   failure_at_head/error_at_head publishes a "Review Bot" context (older
#   pending entry + newer terminal status, plus an unrelated "Other Status")
#   on headsha1 only; success_stale publishes it on oldsha only. Each status
#   query appends to STUB_STATUS_LOG (when set) so tests can assert the
#   fallback is skipped once a check-run matches.
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
    # Outage-marker POST: repos/<repo>/statuses/<sha> (plural — distinct from
    # the singular commits/<sha>/status read). Log the full arg line when a
    # test opts in via STUB_MARKER_LOG so it can assert the context and head.
    if [[ "$*" == *"/statuses/"* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      [[ -n "${STUB_MARKER_LOG:-}" ]] && printf 'marker:%s\n' "$*" >> "$STUB_MARKER_LOG"
      # STUB_MARKER_FAIL simulates a rejected status POST (e.g. no statuses:write).
      if [[ -n "${STUB_MARKER_FAIL:-}" ]]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
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
      if [[ "$mode" == "flaky_503" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -le 2 ]]; then
          echo "HTTP 503: No server is currently available to service your request." >&2
          exit 1
        fi
        mode="commented_at_head"
      fi
      if [[ "$mode" == "flaky_429" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -le 2 ]]; then
          echo "HTTP 429: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2
          exit 1
        fi
        mode="commented_at_head"
      fi
      if [[ "$mode" == "http_503" ]]; then
        echo "HTTP 503: No server is currently available to service your request." >&2
        exit 1
      fi
      if [[ "$mode" == "http_404" ]]; then
        echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/pulls/1/reviews)" >&2
        exit 1
      fi
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
    if [[ "${2:-}" == repos/*/commits/*/check-runs ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      sha="${2##*/commits/}"
      sha="${sha%/check-runs}"
      mode="${STUB_CHECKS_MODE:-none}"
      run_sha="headsha1"
      [[ "$mode" == "success_stale" ]] && run_sha="oldsha"
      conclusion="success"
      [[ "$mode" == "failure_at_head" ]] && conclusion="failure"
      if [[ "$mode" != "none" && "$sha" == "$run_sha" ]]; then
        # Older same-name failure + newer terminal run of "Review Bot" (the
        # newest of the name must win) + an unrelated always-green check (the
        # name filter must exclude it).
        printf '{"total_count":3,"check_runs":[{"name":"Review Bot","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","app":{"slug":"review-bot"}},{"name":"Review Bot","conclusion":"%s","started_at":"2026-01-02T00:00:00Z","app":{"slug":"review-bot"}},{"name":"Other Check","conclusion":"success","started_at":"2026-01-03T00:00:00Z","app":{"slug":"other-app"}}]}\n' "$conclusion"
      else
        echo '{"total_count":0,"check_runs":[]}'
      fi
      exit 0
    fi
    if [[ "${2:-}" == repos/*/commits/*/status ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ -n "${STUB_STATUS_LOG:-}" ]]; then
        echo "status:$2" >> "$STUB_STATUS_LOG"
      fi
      sha="${2##*/commits/}"
      sha="${sha%/status}"
      mode="${STUB_STATUS_MODE:-none}"
      run_sha="headsha1"
      [[ "$mode" == "success_stale" ]] && run_sha="oldsha"
      state="success"
      case "$mode" in
        pending_at_head) state="pending" ;;
        failure_at_head) state="failure" ;;
        error_at_head) state="error" ;;
      esac
      if [[ "$mode" != "none" && "$sha" == "$run_sha" ]]; then
        # Older same-context pending entry + newer terminal status of
        # "Review Bot" (the newest of the context must win) + an unrelated
        # always-green context (the context filter must exclude it).
        printf '{"state":"pending","total_count":3,"statuses":[{"context":"Review Bot","state":"pending","updated_at":"2026-01-01T00:00:00Z","creator":{"login":"review-bot[bot]"}},{"context":"Review Bot","state":"%s","updated_at":"2026-01-02T00:00:00Z","creator":{"login":"review-bot[bot]"}},{"context":"Other Status","state":"success","updated_at":"2026-01-03T00:00:00Z","creator":{"login":"other-bot"}}]}\n' "$state"
      else
        echo '{"state":"pending","total_count":0,"statuses":[]}'
      fi
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
      # Head-only confirm query (`--json headRefOid -q .headRefOid`), distinct
      # from the poll snapshots: return the raw sha. STUB_CONFIRM_HEAD overrides
      # it to simulate a push in the last-poll -> emit window; default matches
      # the poll head so a stable wait confirms and proceeds.
      if [[ "$*" == *"-q .headRefOid"* ]]; then
        printf '%s\n' "${STUB_CONFIRM_HEAD:-headsha1}"
        exit 0
      fi
      if [[ "$*" == *reviewDecision* ]]; then
        mode="${STUB_APPROVAL_MODE:-none}"
        if [[ "$mode" == "approved_after_503" ]]; then
          count="$(_bump_count)"
          if [[ "$count" -le 2 ]]; then
            echo "HTTP 503: No server is currently available to service your request." >&2
            exit 1
          fi
          mode="approved_decision"
        fi
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

echo "=== approval-wait PR_REVIEW_ON_TIMEOUT reviewer-down flexibility ==="

# proceed1: review mode, no evidence, zero threads, setting=proceed — the
# deadline degrades to "proceeded" (exit 0), so a credit-exhausted reviewer
# that posted nothing does not block the fleet.
stderr="$TMP_ROOT/proceed1.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "proceed1: reviewer-down proceed exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "proceeded" "proceed1: status proceeded" "$stderr"
assert_eq "$(json_field "$output" '.unresolved_count')" "0" "proceed1: proceeded only with zero unresolved threads" "$stderr"

# proceed2: the --on-timeout proceed flag drives the same behavior without the
# setting (and overrides it for explicit callers/tests).
stderr="$TMP_ROOT/proceed2.err"
set +e
output=$( (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
  env STUB_REVIEWS_MODE=none .agents/skills/orch/scripts/approval-wait 1 1 3 --json --mode review --on-timeout proceed) 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "proceed2: --on-timeout proceed flag exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "proceeded" "proceed2: flag yields status proceeded" "$stderr"

# proceed3: an unresolved thread ALWAYS blocks, even under proceed — it returns
# "comments" before the deadline, so a real open comment is never bypassed.
stderr="$TMP_ROOT/proceed3.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_THREADS_UNRESOLVED=2 PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed3: open threads still block under proceed" "$stderr"
assert_eq "$(json_field "$output" '.status')" "comments" "proceed3: status comments, not proceeded" "$stderr"

# proceed4: a standing CHANGES_REQUESTED still blocks under proceed — proceed
# only ever converts a no-verdict timeout, never a negative verdict.
stderr="$TMP_ROOT/proceed4.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=changes_standing PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed4: changes_requested still blocks under proceed" "$stderr"
assert_eq "$(json_field "$output" '.status')" "changes_requested" "proceed4: status changes_requested, not proceeded" "$stderr"

# proceed5: the default (setting unset) preserves block — no evidence times out.
stderr="$TMP_ROOT/proceed5.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed5: default is block (timeout)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed5: default status timeout" "$stderr"

# proceed6: approval mode degrades symmetrically — no approval verdict, zero
# threads, proceed -> proceeded, exit 0.
stderr="$TMP_ROOT/proceed6.err"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=none PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "proceed6: approval-mode proceed exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "proceeded" "proceed6: approval-mode status proceeded" "$stderr"

# proceed7: text output names the proceed reason instead of a timeout line.
stderr="$TMP_ROOT/proceed7.err"
set +e
output=$( (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
  env STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed .agents/skills/orch/scripts/approval-wait 1 1 3 --mode review) 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "proceed7: review-mode proceed text exits 0" "$stderr"
assert_contains "$output" "proceeding per PR_REVIEW_ON_TIMEOUT=proceed" "proceed7: text names the proceed reason"

# proceed8: an unrecognized value falls back to block (timeout) and warns.
stderr="$TMP_ROOT/proceed8.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=bogus 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed8: invalid value falls back to block" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed8: invalid value times out" "$stderr"
assert_contains "$(cat "$stderr")" "unrecognized PR_REVIEW_ON_TIMEOUT value" "proceed8: invalid value warns"

# proceed9: approval mode with an active COMMENTED review is NOT reviewer
# silence — a reviewer engaged but did not approve. proceed must NOT convert it
# (that would bypass a live approval gate), so it still times out (Copilot #795
# review of PR #795). Guards the "zero reviewer evidence" boundary in approval
# mode, where reaching the deadline does not by itself imply no review.
stderr="$TMP_ROOT/proceed9.err"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=commented_only PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed9: active COMMENTED review blocks proceed (approval mode)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed9: status timeout, not proceeded" "$stderr"

# proceed10: a head change DURING the wait (force-push near the deadline)
# disqualifies proceed — elapsed is measured from START_TIME, so proceed must
# not fire seconds after a new commit before the reviewer could re-review it.
# Falls back to timeout so the caller re-waits on the now-stable head (Copilot
# #795 review of PR #795, approval-wait:846).
stderr="$TMP_ROOT/proceed10.err"
head_count="$TMP_ROOT/proceed10-head-count"
set +e
output=$(cd "$TMP_ROOT/repo" \
  && PATH="$TMP_ROOT/bin:$PATH" \
     env STUB_REVIEWS_MODE=none STUB_HEAD_MODE=changes STUB_HEAD_COUNT_FILE="$head_count" \
         PR_REVIEW_ON_TIMEOUT=proceed \
         .agents/skills/orch/scripts/approval-wait 1 1 5 --json --mode review 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed10: head change during wait blocks proceed" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed10: status timeout, not proceeded (head moved)" "$stderr"

# proceed11: review mode with a FAILED trusted check-run at head is a real
# reviewer signal, not silence — the reviewer ran and did not pass. proceed
# must not fire (Copilot #795 review, approval-wait:874); it times out.
stderr="$TMP_ROOT/proceed11.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=failure_at_head \
  PR_REVIEW_CHECK="Review Bot" PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed11: failed trusted check blocks proceed (present, not silent)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed11: status timeout, not proceeded" "$stderr"

# proceed12: review mode with a PENDING trusted commit status at head means the
# reviewer is actively analyzing — presence, not silence. proceed must not fire
# on the status surface either; it times out.
stderr="$TMP_ROOT/proceed12.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_STATUS_MODE=pending_at_head \
  PR_REVIEW_CHECK="Review Bot" PR_REVIEW_ON_TIMEOUT=proceed 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed12: pending trusted status blocks proceed (present, not silent)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed12: status timeout, not proceeded" "$stderr"

# proceed13: a push in the final last-poll -> emit window (head confirmed
# different at the decision) falls back to timeout, preserving the head-unchanged
# guarantee — no proceed and no marker on a superseded commit (Copilot #796
# review, approval-wait:669). The head is stable across polls (so
# head_changed_during_wait stays false), only the emit-time confirm differs.
stderr="$TMP_ROOT/proceed13.err"
marker_log="$TMP_ROOT/proceed13.log"; : > "$marker_log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_CONFIRM_HEAD=headsha2 \
  STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "proceed13: head moved in the confirm window blocks proceed" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "proceed13: status timeout, not proceeded" "$stderr"
assert_eq "$(wc -l < "$marker_log" | tr -d ' ')" "0" "proceed13: no marker posted on a superseded head" "$stderr"

echo "=== approval-wait reviewer-outage marker (PR_REVIEW_OUTAGE_CONTEXT) ==="

# marker1: a proceed with PR_REVIEW_OUTAGE_CONTEXT set posts that context as a
# success status on the proceeded head, so a repo-side CI gate can accept it and
# its status re-fire bridge can re-run the gate.
stderr="$TMP_ROOT/marker1.err"
marker_log="$TMP_ROOT/marker1.log"; : > "$marker_log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "marker1: proceed still exits 0 with the marker configured" "$stderr"
assert_eq "$(json_field "$output" '.status')" "proceeded" "marker1: status proceeded" "$stderr"
assert_contains "$(cat "$marker_log")" "context=vstack-reviewer-outage" "marker1: posts the configured context" "$stderr"
assert_contains "$(cat "$marker_log")" "statuses/headsha1" "marker1: posts on the current head" "$stderr"
assert_eq "$(json_field "$output" '.outage_marker')" "posted" "marker1: JSON reports outage_marker posted" "$stderr"

# marker2: with PR_REVIEW_OUTAGE_CONTEXT empty (default), proceed posts NO
# marker — orch-side-only opt-in, the repo-side gate is untouched.
stderr="$TMP_ROOT/marker2.err"
marker_log="$TMP_ROOT/marker2.log"; : > "$marker_log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed \
  STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$(json_field "$output" '.status')" "proceeded" "marker2: status proceeded" "$stderr"
assert_eq "$(wc -l < "$marker_log" | tr -d ' ')" "0" "marker2: no marker posted when context empty" "$stderr"

# marker3: a non-proceed deadline (default block -> timeout) never posts the
# marker, even with the context set — only a genuine proceed attests an outage.
stderr="$TMP_ROOT/marker3.err"
marker_log="$TMP_ROOT/marker3.log"; : > "$marker_log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$(json_field "$output" '.status')" "timeout" "marker3: default block times out" "$stderr"
assert_eq "$(wc -l < "$marker_log" | tr -d ' ')" "0" "marker3: no marker on timeout (only proceed attests)" "$stderr"

# marker4: an open thread returns "comments" before the deadline, so no outage
# is attested despite the context being set — a real comment is never bypassed.
stderr="$TMP_ROOT/marker4.err"
marker_log="$TMP_ROOT/marker4.log"; : > "$marker_log"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_THREADS_UNRESOLVED=2 PR_REVIEW_ON_TIMEOUT=proceed \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$(json_field "$output" '.status')" "comments" "marker4: open thread returns comments, not proceeded" "$stderr"
assert_eq "$(wc -l < "$marker_log" | tr -d ' ')" "0" "marker4: no outage attested when a thread is open" "$stderr"

# marker5: approval mode posts NO marker even on a proceed — its engagement
# signal (last_reviews_present) excludes reviewer check-runs/statuses, and a
# commit status cannot satisfy native required-approvals anyway, so the outage
# marker is review-mode only (Copilot #796 review, approval-wait:949).
stderr="$TMP_ROOT/marker5.err"
marker_log="$TMP_ROOT/marker5.log"; : > "$marker_log"
set +e
output=$(run_wait_json_short STUB_APPROVAL_MODE=none PR_REVIEW_ON_TIMEOUT=proceed \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_MARKER_LOG="$marker_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$(json_field "$output" '.status')" "proceeded" "marker5: approval-mode still proceeds" "$stderr"
assert_eq "$(wc -l < "$marker_log" | tr -d ' ')" "0" "marker5: approval-mode posts no marker (review-mode only)" "$stderr"

# marker6: a FAILED marker POST (e.g. missing statuses:write) still exits 0 with
# status "proceeded" — the reviewer really is down — but reports
# outage_marker="failed" in the JSON and warns loudly, so a caller can tell the
# repo-side gate never got its signal (it cannot recover on its own) and
# retry/stop instead of idling ci-wait (Copilot #796 review, approval-wait:662).
stderr="$TMP_ROOT/marker6.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none PR_REVIEW_ON_TIMEOUT=proceed \
  PR_REVIEW_OUTAGE_CONTEXT="vstack-reviewer-outage" STUB_MARKER_FAIL=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "marker6: failed marker still exits 0 (proceed stands)" "$stderr"
assert_eq "$(json_field "$output" '.status')" "proceeded" "marker6: status still proceeded" "$stderr"
assert_eq "$(json_field "$output" '.outage_marker')" "failed" "marker6: JSON reports outage_marker failed" "$stderr"
assert_contains "$(cat "$stderr")" "outage-marker status" "marker6: warns about the failed marker" "$stderr"

echo "=== approval-wait --mode review check-run evidence (vstack#654) ==="

# Check 1: with PR_REVIEW_CHECK set and no review object anywhere, a "success"
# conclusion of that check name on the current head opens the gate. The stub
# payload also pins newest-of-name selection (an older failed "Review Bot" run
# precedes the success) and name filtering (an unrelated green check exists).
stderr="$TMP_ROOT/check1.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "check1: trusted check success at head exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "check1: status reviewed via check evidence" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence')" "check" "check1: review_evidence pinned to check" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence_surface')" "check_run" "check1: review_evidence_surface pinned to check_run" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "0" "check1: no review object at head" "$stderr"
assert_eq "$(json_field "$output" '.head_sha')" "headsha1" "check1: head_sha reported" "$stderr"

# Check 2: a check success on a STALE sha never opens the gate — the query
# targets the current head's check-runs, which report nothing.
stderr="$TMP_ROOT/check2.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_stale \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "check2: stale-sha check success exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "check2: stale-sha check success times out" "$stderr"

# Check 3: a non-success conclusion of the configured check is not evidence.
stderr="$TMP_ROOT/check3.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=failure_at_head \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "check3: failed check conclusion exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "check3: failed check conclusion times out" "$stderr"

# Check 4: unresolved threads still block — check evidence routes to the same
# "comments" early return as a review object would.
stderr="$TMP_ROOT/check4.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head \
  PR_REVIEW_CHECK="Review Bot" STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "check4: check success + open threads exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "comments" "check4: status comments despite check success" "$stderr"
assert_eq "$(json_field "$output" '.unresolved_count')" "2" "check4: unresolved_count reported" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds | . < 3')" "true" "check4: comments returns early, not at deadline" "$stderr"

# Check 5: a standing CHANGES_REQUESTED still blocks despite check success.
stderr="$TMP_ROOT/check5.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=changes_standing STUB_CHECKS_MODE=success_at_head \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "check5: standing CHANGES_REQUESTED exits 1 despite check success" "$stderr"
assert_eq "$(json_field "$output" '.status')" "changes_requested" "check5: status changes_requested despite check success" "$stderr"

# Check 6: empty PR_REVIEW_CHECK ignores check-runs entirely — the published
# success must not leak into the gate when the feature is off.
stderr="$TMP_ROOT/check6.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "check6: empty PR_REVIEW_CHECK exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "check6: empty PR_REVIEW_CHECK ignores check-runs" "$stderr"

# Check 7: the review-object path still works with the feature on, and wins
# the review_evidence label when a review is pinned to the head.
stderr="$TMP_ROOT/check7.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=commented_at_head STUB_CHECKS_MODE=none \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "check7: review object still opens the gate with the feature on" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "check7: status reviewed via review object" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence')" "review" "check7: review_evidence pinned to review" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence_surface')" "null" "check7: no surface field for review-object evidence" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "1" "check7: reviews_at_head counted" "$stderr"

# Check 8: text mode names the satisfying check-run and its app slug.
stderr="$TMP_ROOT/check8.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "check8: text-mode check evidence exits 0" "$stderr"
assert_contains "$output" "Review: reviewed" "check8: text mode still prints the reviewed line" "$stderr"
assert_contains "$output" "check-run 'Review Bot'" "check8: text mode names the check-run" "$stderr"
assert_contains "$output" "app: review-bot" "check8: text mode records the publishing app slug" "$stderr"

echo "=== approval-wait --mode review commit-status evidence (vstack#681) ==="

# Status 1: with PR_REVIEW_CHECK set, no review object, and no check-run of
# that name anywhere, a "success" commit status with that context on the
# current head opens the gate. The stub payload also pins newest-of-context
# selection (an older pending entry precedes the success) and context
# filtering (an unrelated green context exists).
stderr="$TMP_ROOT/status1.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=success_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "status1: trusted status success at head exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "status1: status reviewed via status evidence" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence')" "check" "status1: review_evidence stays check" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence_surface')" "status" "status1: review_evidence_surface pinned to status" "$stderr"
assert_eq "$(json_field "$output" '.reviews_at_head')" "0" "status1: no review object at head" "$stderr"
assert_eq "$(json_field "$output" '.head_sha')" "headsha1" "status1: head_sha reported" "$stderr"

# Status 2: a matching check-run wins first — the status endpoint is never
# queried, so bots that use check-runs cost no extra API call.
stderr="$TMP_ROOT/status2.err"
status_log="$TMP_ROOT/status2-status.log"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head \
  STUB_STATUS_MODE=success_at_head STUB_STATUS_LOG="$status_log" \
  PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "status2: check-run match still exits 0 with a status present" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence_surface')" "check_run" "status2: check-run surface wins over status" "$stderr"
assert_eq "$([[ -f "$status_log" ]] && wc -l < "$status_log" | tr -d ' ' || echo 0)" "0" "status2: status endpoint never queried when a check-run matches" "$stderr"

# Status 3a-3c: non-success status states are not evidence — pending,
# failure, and error all keep waiting to the timeout.
stderr="$TMP_ROOT/status3a.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=pending_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status3a: pending status exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "status3a: pending status times out" "$stderr"

stderr="$TMP_ROOT/status3b.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=failure_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status3b: failure status exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "status3b: failure status times out" "$stderr"

stderr="$TMP_ROOT/status3c.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=error_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status3c: error status exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "status3c: error status times out" "$stderr"

# Status 4: a status success on a STALE sha never opens the gate — the query
# targets the current head's combined status, which reports nothing.
stderr="$TMP_ROOT/status4.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=success_stale PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status4: stale-sha status success exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "status4: stale-sha status success times out" "$stderr"

# Status 5: empty PR_REVIEW_CHECK ignores BOTH surfaces — neither the
# published check-run success nor the status success leaks into the gate,
# and the status endpoint is never queried.
stderr="$TMP_ROOT/status5.err"
status_log="$TMP_ROOT/status5-status.log"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success_at_head \
  STUB_STATUS_MODE=success_at_head STUB_STATUS_LOG="$status_log" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status5: empty PR_REVIEW_CHECK exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "timeout" "status5: empty PR_REVIEW_CHECK ignores both surfaces" "$stderr"
assert_eq "$([[ -f "$status_log" ]] && wc -l < "$status_log" | tr -d ' ' || echo 0)" "0" "status5: status endpoint never queried with the feature off" "$stderr"

# Status 6: a review object pinned to the head still takes precedence over a
# status success — review_evidence "review", no surface field.
stderr="$TMP_ROOT/status6.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=commented_at_head STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=success_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "status6: review object still opens the gate over a status" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence')" "review" "status6: review_evidence pinned to review" "$stderr"
assert_eq "$(json_field "$output" '.review_evidence_surface')" "null" "status6: no surface field for review-object evidence" "$stderr"

# Status 7: unresolved threads still block — status evidence routes to the
# same "comments" early return as a review object or check-run would.
stderr="$TMP_ROOT/status7.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=success_at_head PR_REVIEW_CHECK="Review Bot" \
  STUB_THREADS_UNRESOLVED=2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "status7: status success + open threads exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "comments" "status7: status comments despite status success" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds | . < 3')" "true" "status7: comments returns early, not at deadline" "$stderr"

# Status 8: text mode names the satisfying status context and its creator.
stderr="$TMP_ROOT/status8.err"
set +e
output=$(run_review_text STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=none \
  STUB_STATUS_MODE=success_at_head PR_REVIEW_CHECK="Review Bot" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "status8: text-mode status evidence exits 0" "$stderr"
assert_contains "$output" "Review: reviewed" "status8: text mode still prints the reviewed line" "$stderr"
assert_contains "$output" "via status 'Review Bot'" "status8: text mode names the status context" "$stderr"
assert_contains "$output" "creator: review-bot[bot]" "status8: text mode records the publishing creator" "$stderr"

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

echo "=== approval-wait transient GitHub API errors (vstack#748) ==="

# Transient 1: the reviews listing 503s twice, then recovers — the waiter
# absorbs both failures with backoff inside the budget, still reaches the
# reviewed verdict, and reports the absorbed count.
stderr="$TMP_ROOT/transient1.err"
count_file="$TMP_ROOT/transient1-count"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=flaky_503 STUB_REVIEWS_COUNT_FILE="$count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "transient1: 503 twice then success exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "transient1: status reviewed despite transient 503s" "$stderr"
assert_eq "$(json_field "$output" '.transient_api_errors')" "2" "transient1: transient_api_errors counts the absorbed 503s" "$stderr"
assert_eq "$(cat "$count_file")" "3" "transient1: reviews endpoint retried until it recovered" "$stderr"
assert_contains "$(cat "$stderr")" "transient GitHub error" "transient1: each transient failure is logged to stderr"

# Transient 1b (vstack#752): HTTP 429 rate limits are transient too — twice
# then success recovers exactly like a 5xx.
stderr="$TMP_ROOT/transient1b.err"
count_file="$TMP_ROOT/transient1b-count"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=flaky_429 STUB_REVIEWS_COUNT_FILE="$count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "transient1b: 429 twice then success exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "reviewed" "transient1b: status reviewed despite rate limits" "$stderr"
assert_eq "$(json_field "$output" '.transient_api_errors')" "2" "transient1b: transient_api_errors counts the absorbed 429s" "$stderr"

# Transient 2: a persistent 503 becomes terminal only when the wait budget
# expires — the pre-#748 error message is preserved, plus the count.
stderr="$TMP_ROOT/transient2.err"
set +e
output=$(run_review_json_short STUB_REVIEWS_MODE=http_503 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "transient2: persistent 503 exits 1 at the deadline" "$stderr"
assert_eq "$(json_field "$output" '.status')" "error" "transient2: persistent 503 ends in status error" "$stderr"
assert_contains "$(json_field "$output" '.error')" "review listing failed" "transient2: terminal error message preserved" "$stderr"
assert_eq "$(json_field "$output" '.transient_api_errors >= 1')" "true" "transient2: transient_api_errors reported at the deadline" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds >= 3')" "true" "transient2: the full wait budget was spent retrying" "$stderr"

# Transient 3: an HTTP 404 is NOT transient — immediately terminal, exactly
# the pre-#748 behavior, with no transient_api_errors field.
stderr="$TMP_ROOT/transient3.err"
set +e
output=$(run_review_json STUB_REVIEWS_MODE=http_404 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "transient3: 404 exits 1" "$stderr"
assert_eq "$(json_field "$output" '.status')" "error" "transient3: 404 reports status error" "$stderr"
assert_contains "$(json_field "$output" '.error')" "review listing failed" "transient3: 404 keeps the terminal error message" "$stderr"
assert_eq "$(json_field "$output" '.transient_api_errors')" "null" "transient3: no transient count for a non-transient failure" "$stderr"
assert_eq "$(json_field "$output" '.elapsed_seconds | . < 3')" "true" "transient3: 404 terminates immediately, not at the deadline" "$stderr"

# Transient 4: approval-mode gh pr view gets the same treatment — 503 twice,
# then the APPROVED verdict lands.
stderr="$TMP_ROOT/transient4.err"
count_file="$TMP_ROOT/transient4-count"
set +e
output=$(run_wait_json STUB_APPROVAL_MODE=approved_after_503 STUB_APPROVAL_COUNT_FILE="$count_file" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "transient4: approval-mode 503s then approval exits 0" "$stderr"
assert_eq "$(json_field "$output" '.status')" "approved" "transient4: status approved despite transient 503s" "$stderr"
assert_eq "$(json_field "$output" '.transient_api_errors')" "2" "transient4: approval-mode pr view retries counted" "$stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
