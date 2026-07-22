#!/usr/bin/env bash
# Regression tests for pr-merge --check CI readiness classification.
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
                if [[ "${STUB_POST_GRAPHQL_FAIL:-false}" == "true" ]]; then
                    echo '{"errors":[{"message":"queue fields unavailable"}]}'
                    exit 1
                fi
                if [[ "${STUB_REQUIRE_TOKEN:-false}" == "true" && "${GH_TOKEN:-}" != "ghp_test_token" ]]; then
                    echo "missing effective token for post-merge GraphQL" >&2
                    exit 41
                fi
                jq -cn \
                    --arg state "${STUB_POST_STATE:-OPEN}" \
                    --arg head "${STUB_POST_HEAD:-${STUB_HEAD:-test-head}}" \
                    --arg branch "${STUB_HEAD_BRANCH:-issue-123}" \
                    --arg commit "${STUB_MERGE_COMMIT:-}" \
                    --arg queue_state "${STUB_POST_QUEUE_STATE:-}" \
                    --argjson auto "${STUB_POST_AUTO_JSON:-null}" \
                    --argjson in_queue "${STUB_POST_IN_QUEUE:-false}" \
                    --argjson queue_entry "${STUB_POST_QUEUE_ENTRY_JSON:-null}" \
                    '{data:{repository:{pullRequest:{state:$state,headRefOid:$head,headRefName:$branch,mergeCommit:(if $commit == "" then null else {oid:$commit} end),autoMergeRequest:$auto,isInMergeQueue:$in_queue,mergeQueueEntry:$queue_entry}}}}'
                exit 0
            fi
            if [[ "${STUB_THREADS_FETCH_FAIL:-false}" == "true" ]]; then
                echo '{"errors":[{"message":"review threads unavailable"}]}'
                exit 1
            fi
            if [[ "${STUB_THREADS_LARGE_PAGE:-false}" == "true" ]]; then
                jq -cn '{data:{repository:{pullRequest:{reviewThreads:{
                    nodes: [range(0; 40) | {
                        id: ("PRRT_large_" + tostring),
                        isResolved: true,
                        isOutdated: false,
                        path: "src/large-page.rs",
                        line: .,
                        comments: {nodes: [{author: {login: "reviewer"}, body: ("x" * 65536)}]}
                    }],
                    pageInfo:{hasNextPage:false,endCursor:null}
                }}}}}'
                exit 0
            fi
            if [[ "$*" == *"cursor=cursor-page-2"* ]]; then
                if [[ "${STUB_THREADS_PAGE2_FETCH_FAIL:-false}" == "true" ]]; then
                    echo '{"errors":[{"message":"second review thread page unavailable"}]}'
                    exit 1
                fi
                if [[ "${STUB_THREADS_PAGE2_MALFORMED:-false}" == "true" ]]; then
                    jq -cn --argjson nodes "${STUB_THREADS_PAGE2_JSON:-[]}" \
                        '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:true,endCursor:null}}}}}}'
                    exit 0
                fi
                jq -cn --argjson nodes "${STUB_THREADS_PAGE2_JSON:-[]}" \
                    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
                exit 0
            fi
            if [[ -n "${STUB_THREADS_PAGE2_JSON:-}" ]]; then
                jq -cn --argjson nodes "${STUB_THREADS_JSON:-[]}" \
                    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:true,endCursor:"cursor-page-2"}}}}}}'
            else
                jq -cn --argjson nodes "${STUB_THREADS_JSON:-[]}" \
                    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
            fi
            exit 0
        fi
        ;;
    pr)
        case "${2:-}" in
            view)
                if [[ "$*" == *"--json title"* ]]; then
                    echo '{"title":"Test PR"}'
                    exit 0
                fi
                if [[ "$*" == *"--json headRefName"* ]]; then
                    echo "${STUB_HEAD_BRANCH:-issue-123}"
                    exit 0
                fi
                if [[ "$*" == *"--json headRefOid"* ]]; then
                    if [[ "${STUB_REQUIRE_TOKEN:-false}" == "true" && "${GH_TOKEN:-}" != "ghp_test_token" ]]; then
                        echo "missing effective token for head guard" >&2
                        exit 42
                    fi
                    echo "${STUB_HEAD:-test-head}"
                    exit 0
                fi
                if [[ "$*" == *"--json mergeable"* ]]; then
                    echo "MERGEABLE"
                    exit 0
                fi
                if [[ "$*" == *"--json reviewDecision,latestReviews"* ]]; then
                    echo '{"reviewDecision":"APPROVED","latestReviews":[{"state":"APPROVED"}]}'
                    exit 0
                fi
                if [[ "$*" == *"--json state,headRefOid,headRefName,mergeCommit,autoMergeRequest"* ]]; then
                    jq -cn \
                        --arg state "${STUB_POST_STATE:-OPEN}" \
                        --arg head "${STUB_POST_HEAD:-${STUB_HEAD:-test-head}}" \
                        --arg branch "${STUB_HEAD_BRANCH:-issue-123}" \
                        --arg commit "${STUB_MERGE_COMMIT:-}" \
                        --argjson auto "${STUB_POST_AUTO_JSON:-null}" \
                        '{state:$state,headRefOid:$head,headRefName:$branch,mergeCommit:(if $commit == "" then null else {oid:$commit} end),autoMergeRequest:$auto}'
                    exit 0
                fi
                ;;
            merge)
                if [[ "$*" != *"--match-head-commit ${STUB_HEAD:-test-head}"* ]]; then
                    echo "missing exact --match-head-commit guard" >&2
                    exit 43
                fi
                if [[ "${STUB_REQUIRE_TOKEN:-false}" == "true" && "${GH_TOKEN:-}" != "ghp_test_token" ]]; then
                    echo "missing effective token for merge" >&2
                    exit 44
                fi
                if [[ "${STUB_MERGE_EXIT:-0}" != "0" ]]; then
                    printf '%s\n' "${STUB_MERGE_STDERR:-failed to run merge}" >&2
                    exit "${STUB_MERGE_EXIT}"
                fi
                echo "merge command accepted"
                exit 0
                ;;
            checks)
                printf '%s\n' "${STUB_CHECKS:?}"
                exit "${STUB_CHECKS_EXIT:-0}"
                ;;
        esac
        ;;
esac

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMPDIR/bin/gh"

run_check() {
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN "$PR_MERGE" 123 --check)
}

run_merge() {
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN "$PR_MERGE" 123 --auto --keep-branch)
}

run_merge_immediate() {
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN "$PR_MERGE" 123 --keep-branch)
}

run_merge_force() {
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN "$PR_MERGE" 123 --force --keep-branch)
}

run_merge_force_auto() {
    (cd "$TMPDIR/repo" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN "$PR_MERGE" 123 --force --auto --keep-branch)
}

echo "=== pr-merge --check CI classification ==="

checks='[{"name":"Linux Integration","state":"IN_PROGRESS","bucket":"pending"},{"name":"Cross-Platform","state":"PENDING","bucket":"pending"}]'
out=$(STUB_CHECKS="$checks" STUB_CHECKS_EXIT=8 run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "pending checks block merge"
assert_eq "$(jq -r .transient <<<"$out")" "true" "pending-only checks are transient"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "1" "pending-only emits one issue"
assert_contains "$(jq -r '.issues[0]' <<<"$out")" "ci_pending:" "pending issue uses ci_pending prefix"
assert_contains "$(jq -r '.issues[0]' <<<"$out")" "Linux Integration (IN_PROGRESS)" "pending issue names running check"

checks='[{"name":"Unit Tests","state":"SUCCESS","bucket":"pass"},{"name":"Lint","state":"FAILURE","bucket":"fail"}]'
out=$(STUB_CHECKS="$checks" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "failed checks block merge"
assert_eq "$(jq -r .transient <<<"$out")" "false" "failed checks are permanent"
assert_contains "$(jq -r '.issues[0]' <<<"$out")" "ci_failed: Lint (FAILURE)" "failed issue preserves ci_failed prefix"

checks='[{"name":"Unit Tests","state":"IN_PROGRESS","bucket":"pending"},{"name":"Lint","state":"FAILURE","bucket":"fail"}]'
out=$(STUB_CHECKS="$checks" STUB_CHECKS_EXIT=8 run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "mixed pending and failed checks block merge"
assert_eq "$(jq -r .transient <<<"$out")" "false" "mixed pending and failed checks are not transient"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "ci_pending: Unit Tests (IN_PROGRESS)" "mixed output includes pending issue"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "ci_failed: Lint (FAILURE)" "mixed output includes failed issue"

checks='[{"name":"Unit Tests","state":"SUCCESS","bucket":"pass"},{"name":"Optional Job","state":"SKIPPED","bucket":"skipping"}]'
out=$(STUB_CHECKS="$checks" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "true" "successful and skipped checks can merge"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "0" "successful and skipped checks emit no issues"
assert_eq "$(jq -r .transient <<<"$out")" "false" "mergeable PR is not transient"

echo
echo "=== pr-merge actionable review-thread safety gate (vstack#785) ==="

checks='[{"name":"CI Required","state":"SUCCESS","bucket":"pass"}]'
actionable_threads='[{"id":"PRRT_actionable","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":12,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Fix this safety bug"}]}}]'
out=$(STUB_CHECKS="$checks" STUB_THREADS_JSON="$actionable_threads" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "actionable unresolved thread blocks readiness"
assert_eq "$(jq -r .transient <<<"$out")" "false" "actionable unresolved thread is a permanent block"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "unresolved_threads: 1 actionable thread(s)" "actionable thread is a blocking issue"
assert_eq "$(jq -r '.warnings | map(select(startswith("unresolved_threads:"))) | length' <<<"$out")" "0" "actionable thread is never downgraded to warning"

call_log="$TMPDIR/review-thread-calls.log"
: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$actionable_threads" \
    STUB_CALL_LOG="$call_log" \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "--auto cannot bypass actionable review thread gate"
assert_contains "$out" "BLOCKED PR #123 — no merge attempted, none queued" "--auto reports fail-closed outcome"
assert_contains "$out" "Resolve the review-thread gate and retry" "blocked output does not recommend ineffective --auto bypass"
assert_not_contains "$(cat "$call_log")" "pr merge" "--auto never invokes gh pr merge"
assert_not_contains "$(cat "$call_log")" "mergeQueueEntry" "--auto never reaches post-mutation merge queue API"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$actionable_threads" \
    STUB_CALL_LOG="$call_log" \
    run_merge_immediate 2>&1)
status=$?
set -e
assert_eq "$status" "1" "immediate merge fails closed on actionable review thread"
assert_not_contains "$(cat "$call_log")" "pr merge" "immediate path never invokes gh pr merge"

outdated_threads='[{"id":"PRRT_outdated","isResolved":false,"isOutdated":true,"path":"src/old.rs","line":7,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Stale diff"}]}}]'
out=$(STUB_CHECKS="$checks" STUB_THREADS_JSON="$outdated_threads" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "true" "outdated unresolved thread is not actionable"

malformed_threads='[
  {"id":"PRRT_null","isResolved":null,"isOutdated":false,"path":"src/null.rs","line":1,"comments":{"nodes":[]}},
  {"id":"PRRT_missing","isOutdated":false,"path":"src/missing.rs","line":2,"comments":{"nodes":[]}},
  {"id":"PRRT_string","isResolved":"false","isOutdated":false,"path":"src/string.rs","line":3,"comments":{"nodes":[]}}
]'
out=$(STUB_CHECKS="$checks" STUB_THREADS_JSON="$malformed_threads" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "malformed thread state blocks readiness"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "review_threads_fetch_failed: GitHub returned malformed review thread data" "malformed node reaches trust-boundary validation"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$malformed_threads" \
    STUB_CALL_LOG="$call_log" \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "malformed thread state blocks --auto"
assert_not_contains "$(cat "$call_log")" "pr merge" "malformed thread state never invokes gh pr merge"

# Forty valid maximum-size comment bodies produce a ~2.5 MiB page, exceeding
# macOS ARG_MAX (and typical Linux ARG_MAX). The query boundary must stream
# this payload through jq stdin rather than fail while constructing argv.
out=$(STUB_CHECKS="$checks" STUB_THREADS_LARGE_PAGE=true run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "true" "large valid review page avoids ARG_MAX failure"

first_page_threads=$(jq -cn '[range(0; 100) | {
    id: ("PRRT_resolved_" + tostring),
    isResolved: true,
    isOutdated: false,
    path: "src/first-page.rs",
    line: .,
    comments: {nodes: [{author: {login: "reviewer"}, body: "Resolved"}]}
}]')
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$first_page_threads" \
    STUB_THREADS_PAGE2_JSON="$actionable_threads" \
    run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "actionable thread after first 100 blocks readiness"
assert_contains "$(jq -r '.issues[]' <<<"$out")" "unresolved_threads: 1 actionable thread(s)" "second-page blocker reaches merge gate"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$first_page_threads" \
    STUB_THREADS_PAGE2_JSON='[]' \
    STUB_THREADS_PAGE2_FETCH_FAIL=true \
    STUB_CALL_LOG="$call_log" \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "second-page fetch failure blocks --auto"
assert_contains "$out" "review_threads_fetch_failed:" "second-page failure reaches fail-closed merge gate"
assert_not_contains "$(cat "$call_log")" "pr merge" "second-page failure never invokes gh pr merge"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$first_page_threads" \
    STUB_THREADS_PAGE2_JSON='[]' \
    STUB_THREADS_PAGE2_MALFORMED=true \
    STUB_CALL_LOG="$call_log" \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "malformed second-page cursor state blocks --auto"
assert_contains "$out" "review_threads_fetch_failed:" "malformed pagination reaches fail-closed merge gate"
assert_not_contains "$(cat "$call_log")" "pr merge" "malformed pagination never invokes gh pr merge"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_FETCH_FAIL=true \
    STUB_CALL_LOG="$call_log" \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "review-thread lookup failure blocks --auto"
assert_contains "$out" "review_threads_fetch_failed:" "lookup failure has explicit blocking issue"
assert_not_contains "$(cat "$call_log")" "pr merge" "lookup failure never invokes gh pr merge"

: >"$call_log"
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_THREADS_JSON="$actionable_threads" \
    STUB_CALL_LOG="$call_log" \
    STUB_POST_STATE=MERGED \
    STUB_MERGE_COMMIT=forced-merge-oid \
    run_merge_force 2>&1)
status=$?
set -e
assert_eq "$status" "0" "documented --force remains a deliberate override"
assert_contains "$(cat "$call_log")" "pr merge" "--force deliberately invokes gh pr merge"

echo
echo "=== pr-merge --check superseded-run scoping (vstack#492/#494) ==="

# An OLD superseded run (RUN_ID 29098545030) left several CANCELLED named jobs;
# the NEW authoritative run (RUN_ID 29099680623) on the current head is still
# in progress ("Changes"). Scoping must drop the superseded run's CANCELLED jobs
# so they are NOT reported as ci_failed blockers — only the current run's
# still-pending check gates the merge (transient, retryable).
checks='[
  {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},
  {"name":"Linux Integration","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/102","workflow":"CI","startedAt":"2026-07-10T10:00:01Z"},
  {"name":"macOS","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/103","workflow":"CI","startedAt":"2026-07-10T10:00:02Z"},
  {"name":"Changes","state":"IN_PROGRESS","bucket":"pending","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},
  {"name":"License Key Guard","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}
]'
out=$(STUB_CHECKS="$checks" STUB_CHECKS_EXIT=8 run_check)
assert_eq "$(jq -r '[.issues[] | select(startswith("ci_failed:"))] | length' <<<"$out")" "0" "superseded CANCELLED jobs not reported as ci_failed"
assert_eq "$(jq -r .transient <<<"$out")" "true" "only current run's pending check blocks (transient)"
assert_contains "$out" "ci_pending: Changes (IN_PROGRESS)" "current run's pending check is the only blocker"
assert_eq "$(jq -r '.issues | map(select(test("Lint|Linux Integration|macOS"))) | length' <<<"$out")" "0" "no superseded CANCELLED job names leak into issues"

# The current-head run (RUN_ID 29099680623) has RE-CREATED and passed the jobs
# the old run (29098545030) left CANCELLED. Scoping keeps only the newer run, so
# the PR is cleanly mergeable — the stale CANCELLED copies must not block.
checks='[
  {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},
  {"name":"Lint","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},
  {"name":"Changes","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}
]'
out=$(STUB_CHECKS="$checks" run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "true" "superseded-then-replaced run is mergeable"
assert_eq "$(jq -r '.issues | length' <<<"$out")" "0" "no stale CANCELLED Lint blocks the merge"

# Guard: a genuinely-current cancellation (no newer run exists) must STILL be
# reported as a failure — scoping only drops superseded runs, it must not mask
# the latest run's own CANCELLED result.
checks='[
  {"name":"Lint","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},
  {"name":"Integration","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}
]'
out=$(STUB_CHECKS="$checks" STUB_CHECKS_EXIT=8 run_check)
assert_eq "$(jq -r .can_merge <<<"$out")" "false" "current-run CANCELLED still blocks merge"
assert_contains "$out" "ci_failed: Integration (CANCELLED)" "current-run CANCELLED reported as ci_failed"

echo
echo "=== pr-merge post-mutation outcomes (vstack#608) ==="

checks='[{"name":"CI Required","state":"SUCCESS","bucket":"pass"}]'

# Exact Hyprtrade PR #263 false-negative shape at head
# 28132e9b990a595417f79f4e213b4e984bf676fd: gh accepted the guarded
# mutation, the PR remained OPEN, autoMergeRequest was null, and the active
# mergeQueueEntry was authoritative proof that the operation succeeded.
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_HEAD="28132e9b990a595417f79f4e213b4e984bf676fd" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON='{"state":"QUEUED"}' \
    STUB_POST_QUEUE_STATE=QUEUED \
    STUB_REQUIRE_TOKEN=true \
    GH_BOT_TOKEN=ghp_test_token \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "75" "active mergeQueueEntry is success-pending"
assert_contains "$out" "QUEUED IN MERGE QUEUE PR #123" "merge-queue outcome is explicit"
assert_contains "$out" "queueState=QUEUED" "merge-queue state is preserved"

set +e
out=$(STUB_CHECKS="$checks" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON='{"enabledAt":"2026-07-15T00:00:00Z"}' \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "75" "classic auto-merge remains success-pending"
assert_contains "$out" "AUTO-MERGE ENABLED PR #123" "classic auto-merge outcome is distinct"

set +e
out=$(STUB_CHECKS="$checks" \
    STUB_POST_STATE=MERGED \
    STUB_MERGE_COMMIT=merged-oid \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "0" "immediate direct merge remains success"
assert_contains "$out" "MERGED PR #123" "merged outcome remains explicit"

set +e
out=$(STUB_CHECKS="$checks" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "OPEN and genuinely unqueued remains blocked"
assert_contains "$out" "mergeQueue=false" "blocked outcome names absent queue proof"

set +e
out=$(STUB_CHECKS="$checks" \
    STUB_HEAD=guarded-head \
    STUB_POST_HEAD=newer-unreviewed-head \
    STUB_POST_STATE=OPEN \
    STUB_POST_IN_QUEUE=true \
    STUB_POST_QUEUE_ENTRY_JSON='{"state":"QUEUED"}' \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "post-call head drift fails closed"
assert_contains "$out" "head changed during merge attempt" "head drift has clear diagnostic"

set +e
out=$(STUB_CHECKS="$checks" \
    STUB_POST_GRAPHQL_FAIL=true \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON='{"enabledAt":"2026-07-15T00:00:00Z"}' \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "75" "classic auto-merge survives queue-query fallback"
assert_contains "$out" "AUTO-MERGE ENABLED PR #123" "fallback preserves classic output"

echo
echo "=== pr-merge already-queued idempotency (vstack#616) ==="

# A SECOND `--auto` call on a PR already enrolled in a required merge queue:
# `gh pr merge --auto` returns NONZERO with GitHub's already-queued error, but
# the authoritative post-call snapshot still reports an active mergeQueueEntry
# (isInMergeQueue: true). The wrapper must take that snapshot instead of
# short-circuiting to BLOCKED, and report the queued/exit-75 contract.
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_HEAD="already-queued-head" \
    STUB_MERGE_EXIT=1 \
    STUB_MERGE_STDERR="failed to run merge: GraphQL: Pull request Pull request is already queued to merge (enablePullRequestAutoMerge)" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=true \
    STUB_POST_QUEUE_ENTRY_JSON='{"state":"QUEUED"}' \
    STUB_POST_QUEUE_STATE=QUEUED \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "75" "already-queued --auto re-invocation is queued, not blocked"
assert_contains "$out" "QUEUED IN MERGE QUEUE PR #123" "already-queued re-invocation reports merge-queue outcome"
assert_contains "$out" "queueState=QUEUED" "already-queued re-invocation preserves queue state"

# Fail-closed guard: a GENUINE `gh pr merge` failure — nonzero exit with NO
# active queue entry, no auto-merge, PR still OPEN — must stay BLOCKED and
# surface the raw gh output. The nonzero-exit path must not swallow real
# failures just because it now takes the snapshot.
set +e
out=$(STUB_CHECKS="$checks" \
    STUB_MERGE_EXIT=1 \
    STUB_MERGE_STDERR="failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge 2>&1)
status=$?
set -e
assert_eq "$status" "1" "genuine gh pr merge failure stays blocked"
assert_contains "$out" "BLOCKED PR #123 — gh pr merge failed" "genuine failure reports gh pr merge failed"
assert_contains "$out" "base branch policy prohibits the merge" "genuine failure surfaces raw gh output"

echo
echo "=== pr-merge --force immediate failure contract (vstack#782) ==="

# Force and auto request contradictory outcomes. Reject the combination before
# PR resolution, authentication, checks, or any merge/queue mutation.
call_log="$TMPDIR/force-auto-calls.log"
: >"$call_log"
set +e
out=$(STUB_CALL_LOG="$call_log" run_merge_force_auto 2>&1)
status=$?
set -e
assert_eq "$status" "1" "--force and --auto are rejected as conflicting modes"
assert_contains "$out" "--force and --auto cannot be combined" "conflicting modes report a clear usage error"
assert_eq "$(cat "$call_log")" "" "conflicting modes make no GitHub API or mutation calls"

# The authoritative exact-head postcondition wins over a CLI transport/status
# failure: the requested immediate outcome actually happened.
set +e
out=$(STUB_MERGE_EXIT=1 \
    STUB_MERGE_STDERR="failed to read the completed mutation response" \
    STUB_POST_STATE=MERGED \
    STUB_MERGE_COMMIT=forced-merge-oid \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge_force 2>&1)
status=$?
set -e
assert_eq "$status" "0" "failed CLI remains success when exact-head post-state is MERGED"
assert_contains "$out" "MERGED PR #123" "force reports the authoritative immediate postcondition"

# `--force` is an immediate-only operation. A pre-existing classic auto-merge
# request must not make a rejected immediate mutation appear successful.
set +e
out=$(STUB_MERGE_EXIT=1 \
    STUB_MERGE_STDERR="failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON='{"enabledAt":"2026-07-21T00:00:00Z"}' \
    STUB_POST_IN_QUEUE=false \
    STUB_POST_QUEUE_ENTRY_JSON=null \
    run_merge_force 2>&1)
status=$?
set -e
assert_eq "$status" "1" "failed --force stays blocked when classic auto-merge was already armed"
assert_contains "$out" "BLOCKED PR #123 — gh pr merge failed" "failed --force reports its immediate mutation failure"
assert_contains "$out" "base branch policy prohibits the merge" "failed --force preserves the immediate failure detail"

# Required-queue membership is likewise not proof that an immediate --force
# attempt succeeded. Queue idempotency remains reserved for non-force modes.
set +e
out=$(STUB_MERGE_EXIT=1 \
    STUB_MERGE_STDERR="failed to run merge: merge queue is required" \
    STUB_POST_STATE=OPEN \
    STUB_POST_AUTO_JSON=null \
    STUB_POST_IN_QUEUE=true \
    STUB_POST_QUEUE_ENTRY_JSON='{"state":"QUEUED"}' \
    STUB_POST_QUEUE_STATE=QUEUED \
    run_merge_force 2>&1)
status=$?
set -e
assert_eq "$status" "1" "failed --force stays blocked when a queue entry was already active"
assert_contains "$out" "BLOCKED PR #123 — gh pr merge failed" "queued --force failure is not reported as pending success"
assert_contains "$out" "merge queue is required" "queued --force failure preserves the immediate failure detail"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
