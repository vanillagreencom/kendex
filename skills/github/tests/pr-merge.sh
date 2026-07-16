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

mkdir -p "$TMPDIR/bin" "$TMPDIR/repo"
git -C "$TMPDIR/repo" init -q

cat >"$TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
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
                echo "merge command accepted"
                exit "${STUB_MERGE_EXIT:-0}"
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
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
