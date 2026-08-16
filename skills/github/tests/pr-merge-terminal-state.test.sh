#!/usr/bin/env bash
# Regression tests for pr-merge on a PR that has already left OPEN.
#
# `mergeable` is permanently UNKNOWN after a merge, so running the readiness
# checks against a merged PR invented blockers — `unknown:`, `ci_pending:` from
# post-merge runs, `unresolved_threads:` from post-merge bot comments — and
# returned BLOCKED, which drives a caller to re-arm a merge that already
# happened. A merged or closed PR is terminal and short-circuits every mode.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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
    if grep -qF -- "$needle" <<<"$haystack"; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    fi
}

mkdir -p "$TMPDIR/bin" "$TMPDIR/repo"
git -C "$TMPDIR/repo" init -q

# Stub gh. The post-merge shapes are the real ones a merged PR returns:
# mergeable UNKNOWN, a still-running post-merge workflow, and an unresolved
# thread from a bot comment posted after the merge.
cat >"$TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${STUB_CALL_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$STUB_CALL_LOG"
fi

case "${1:-}" in
    auth)
        if [[ "${2:-}" == "status" ]]; then
            echo "Logged in"
            exit 0
        fi
        ;;
    repo)
        if [[ "${2:-}" == "view" ]]; then
            echo '{"owner":{"login":"owner"},"name":"repo"}'
            exit 0
        fi
        ;;
    api)
        if [[ "${2:-}" == "graphql" ]]; then
            if [[ "$*" == *"mergeQueueEntry"* ]]; then
                jq -cn \
                    --arg state "${STUB_POST_STATE:-OPEN}" \
                    --arg head "${STUB_HEAD:-test-head}" \
                    '{data:{repository:{pullRequest:{state:$state,headRefOid:$head,headRefName:"issue-123",mergeCommit:null,autoMergeRequest:null,isInMergeQueue:false,mergeQueueEntry:null}}}}'
                exit 0
            fi
            if [[ -n "${STUB_THREADS_JSON:-}" ]]; then
                jq -cn --argjson nodes "$STUB_THREADS_JSON" \
                    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
                exit 0
            fi
            jq -cn '{data:{repository:{pullRequest:{reviewThreads:{
                nodes:[{id:"PRRT_post_merge_bot",isResolved:false,isOutdated:false,path:"src/lib.rs",line:3,
                        comments:{nodes:[{author:{login:"review-bot"},body:"post-merge nit"}]}}],
                pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
            exit 0
        fi
        ;;
    pr)
        case "${2:-}" in
            view)
                if [[ "$*" == *"--json state,mergedAt"* ]]; then
                    if [[ -n "${STUB_STATE_STDERR:-}" ]]; then
                        printf '%s\n' "$STUB_STATE_STDERR" >&2
                        exit "${STUB_STATE_EXIT:-1}"
                    fi
                    if [[ "${STUB_STATE_SILENT_FAIL:-false}" == "true" ]]; then
                        exit "${STUB_STATE_EXIT:-1}"
                    fi
                    if [[ "${STUB_PR_MISSING:-false}" == "true" ]]; then
                        echo "no pull requests found" >&2
                        exit 1
                    fi
                    jq -cn \
                        --arg state "${STUB_STATE:-OPEN}" \
                        --arg merged_at "${STUB_MERGED_AT:-}" \
                        '{state:$state,mergedAt:(if $merged_at == "" then null else $merged_at end)}'
                    exit 0
                fi
                if [[ "$*" == *"--json headRefOid"* ]]; then
                    echo "${STUB_HEAD:-test-head}"
                    exit 0
                fi
                if [[ "$*" == *"--json mergeable"* ]]; then
                    echo "${STUB_MERGEABLE:-UNKNOWN}"
                    exit 0
                fi
                if [[ "$*" == *"--json reviewDecision,latestReviews"* ]]; then
                    echo '{"reviewDecision":"APPROVED","latestReviews":[{"state":"APPROVED"}]}'
                    exit 0
                fi
                ;;
            merge)
                echo "merge command accepted"
                exit 0
                ;;
            checks)
                # Required: a terminal PR must never reach this call, so an
                # unset value fails the run instead of passing silently.
                printf '%s\n' "${STUB_CHECKS:?}"
                exit "${STUB_CHECKS_EXIT:-8}"
                ;;
        esac
        ;;
esac

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMPDIR/bin/gh"

call_log="$TMPDIR/calls.log"

run_pr_merge() { # env assignments come from the caller's environment
    : >"$call_log"
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN \
        STUB_CALL_LOG="$call_log" "$PR_MERGE" 123 "$@" 2>&1)
}

echo "=== already-merged PR short-circuits every merge mode ==="

set +e
out=$(STUB_STATE=MERGED STUB_MERGED_AT=2026-08-15T09:41:12Z run_pr_merge --auto --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "--auto on a merged PR exits MERGED (0)"
assert_contains "$out" "ALREADY MERGED PR #123 2026-08-15T09:41:12Z" "--auto reports the already-merged outcome with mergedAt"
assert_not_contains "$out" "BLOCKED" "--auto on a merged PR never reports BLOCKED"
assert_not_contains "$out" "unknown:" "no invented mergeable-UNKNOWN issue"
assert_not_contains "$out" "ci_pending:" "no post-merge CI run reported as a blocker"
assert_not_contains "$out" "unresolved_threads" "no post-merge comment thread reported as a blocker"
assert_not_contains "$(cat "$call_log")" "pr merge" "merged PR never reaches gh pr merge"
assert_not_contains "$(cat "$call_log")" "pr checks" "merged PR never fetches CI checks"
assert_not_contains "$(cat "$call_log")" "graphql" "merged PR never fetches threads or queue state"

set +e
out=$(STUB_STATE=MERGED STUB_MERGED_AT=2026-08-15T09:41:12Z run_pr_merge --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "immediate merge on a merged PR exits MERGED (0)"
assert_contains "$out" "ALREADY MERGED PR #123" "immediate mode reports the already-merged outcome"
assert_not_contains "$(cat "$call_log")" "pr merge" "immediate mode attempts no mutation"

set +e
out=$(STUB_STATE=MERGED STUB_MERGED_AT=2026-08-15T09:41:12Z run_pr_merge --force --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "--force on a merged PR exits MERGED (0)"
assert_contains "$out" "ALREADY MERGED PR #123" "--force reports the already-merged outcome"
assert_not_contains "$(cat "$call_log")" "pr merge" "--force attempts no mutation on a merged PR"

set +e
out=$(STUB_STATE=MERGED run_pr_merge --auto --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "merged PR without a mergedAt timestamp still exits 0"
assert_eq "$out" "ALREADY MERGED PR #123" "missing mergedAt emits the bare line, no trailing field"

echo
echo "=== closed-unmerged PR is a distinct terminal refusal ==="

set +e
out=$(STUB_STATE=CLOSED run_pr_merge --auto --keep-branch)
status=$?
set -e
assert_eq "$status" "1" "--auto on a closed PR exits 1"
assert_eq "$(head -1 <<<"$out")" "CLOSED (not merged) PR #123" \
    "closed PR's first line is exactly the machine-readable state line"
assert_not_contains "$out" "unknown:" "closed PR reports no mergeable-UNKNOWN issue"
assert_not_contains "$out" "ci_pending:" "closed PR reports no CI issue"
assert_not_contains "$out" "unresolved_threads" "closed PR reports no thread issue"
assert_not_contains "$out" "ALREADY MERGED" "closed PR is never reported as merged"
assert_not_contains "$(cat "$call_log")" "pr merge" "closed PR never reaches gh pr merge"

echo
echo "=== --check reports the terminal state instead of issues ==="

out=$(STUB_STATE=MERGED STUB_MERGED_AT=2026-08-15T09:41:12Z run_pr_merge --check)
assert_eq "$(jq -r .state <<<"$out")" "MERGED" "--check reports state MERGED"
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "--check on a merged PR cannot merge"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "0" "--check on a merged PR reports no issues"
assert_eq "$(jq -r '.warnings | length' <<<"$out")" "0" "--check on a merged PR reports no warnings"
assert_eq "$(jq -r .transient <<<"$out")" "false" "--check on a merged PR is not transient"
assert_not_contains "$(cat "$call_log")" "pr checks" "--check on a merged PR fetches no CI"

out=$(STUB_STATE=CLOSED run_pr_merge --check)
assert_eq "$(jq -r .state <<<"$out")" "CLOSED" "--check reports state CLOSED"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "0" "--check on a closed PR reports no issues"

out=$(STUB_PR_MISSING=true run_pr_merge --check)
assert_eq "$(jq -r .state <<<"$out")" "UNKNOWN" "--check on a missing PR reports UNKNOWN state"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "not_found: PR #123 not found" "--check still reports a missing PR"

echo
echo "=== a failed state lookup names its real cause ==="

out=$(STUB_STATE_STDERR="GraphQL: Could not resolve to a PullRequest with the number of 123. (repository.pullRequest)" \
    run_pr_merge --check)
assert_contains "$(jq -r '.issues[]' <<<"$out")" "not_found: PR #123 not found" \
    "GitHub's own missing-PR wording stays not_found"

out=$(STUB_STATE_STDERR="gh: Bad credentials (HTTP 401)" STUB_STATE_EXIT=1 run_pr_merge --check)
assert_contains "$(jq -r '.issues[]' <<<"$out")" "gh_error: gh: Bad credentials (HTTP 401)" \
    "an auth failure is reported as gh_error with its diagnostic"
assert_not_contains "$(jq -r '.issues[]' <<<"$out")" "not_found" \
    "an auth failure is never reported as a missing PR"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "1" "a failed state lookup emits one issue"
assert_eq "$(jq -r .state <<<"$out")" "UNKNOWN" "a failed state lookup reports UNKNOWN state"

out=$(STUB_STATE_STDERR="API rate limit exceeded for user ID 1." STUB_STATE_EXIT=1 run_pr_merge --check)
assert_contains "$(jq -r '.issues[]' <<<"$out")" "gh_error: API rate limit exceeded" \
    "a rate-limit failure keeps its own diagnostic"

out=$(STUB_STATE_SILENT_FAIL=true STUB_STATE_EXIT=4 run_pr_merge --check)
assert_contains "$(jq -r '.issues[]' <<<"$out")" "gh_error: gh pr view exited 4 with no diagnostic" \
    "a silent failure still names gh and its exit code"

# The merge path must see the same cause: a failed lookup is not cached, so the
# checks re-read it instead of inheriting an empty state and inventing issues.
set +e
out=$(STUB_STATE_STDERR="gh: Bad credentials (HTTP 401)" run_pr_merge --keep-branch)
status=$?
set -e
assert_eq "$status" "1" "a failed state lookup blocks the merge"
assert_contains "$out" "gh_error: gh: Bad credentials (HTTP 401)" "the merge path reports the real cause"
assert_not_contains "$out" "not_found" "the merge path never reports a missing PR for an auth failure"
assert_not_contains "$out" "ALREADY MERGED" "an unreadable state is never treated as merged"

echo
echo "=== an open PR is unaffected ==="

checks='[{"name":"CI Required","state":"SUCCESS","bucket":"pass"}]'

out=$(STUB_STATE=OPEN STUB_MERGEABLE=MERGEABLE STUB_CHECKS="$checks" STUB_CHECKS_EXIT=0 run_pr_merge --check)
assert_eq "$(jq -r .state <<<"$out")" "OPEN" "--check reports state OPEN for a live PR"
assert_eq "$(jq -r .mergeable <<<"$out")" "MERGEABLE" "--check still reports the live mergeable value"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "unresolved_threads" "--check still gates a live PR on its open thread"

set +e
out=$(STUB_STATE=OPEN STUB_POST_STATE=MERGED STUB_MERGEABLE=MERGEABLE \
    STUB_CHECKS="$checks" STUB_CHECKS_EXIT=0 run_pr_merge --force --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "an open PR still merges"
assert_contains "$out" "MERGED PR #123" "open PR reports the live merge outcome"
assert_not_contains "$out" "ALREADY MERGED" "a live merge is not reported as already merged"
assert_contains "$(cat "$call_log")" "pr merge" "open PR still reaches gh pr merge"

# The state read is shared: the terminal-state guard and the readiness checks
# must not each spend a round trip on the same field.
set +e
out=$(STUB_STATE=OPEN STUB_POST_STATE=MERGED STUB_MERGEABLE=MERGEABLE \
    STUB_THREADS_JSON='[]' STUB_CHECKS="$checks" STUB_CHECKS_EXIT=0 \
    run_pr_merge --keep-branch)
status=$?
set -e
assert_eq "$status" "0" "a checked open PR still merges"
assert_eq "$(grep -c -- '--json state,mergedAt' "$call_log")" "1" \
    "an open PR reads its state exactly once"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
