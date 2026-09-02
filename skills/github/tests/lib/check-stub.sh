#!/usr/bin/env bash
# Shared harness for the pr-merge and ci-classify-refusal suites: the PASS/
# FAIL counters and assert helpers, a scratch repo, and the `gh` stub that
# serves every fixture through STUB_* variables (and logs argv to
# STUB_CALL_LOG when set). Sourced, never run — CI's suite glob picks up
# skills/*/tests/*.sh only, so this file lives one level down.
#
# After sourcing: $TMPDIR holds bin/gh and repo/, and is removed on exit.
# The suite prints its own pass/fail summary from $PASS/$FAIL.

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
[[ -z "${STUB_AUTH_LOG:-}" ]] || printf 'GH=%s|GITHUB=%s|%s\n' "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "$*" >>"$STUB_AUTH_LOG"

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
                if [[ "$*" == *"--json state,mergedAt"* ]]; then
                    jq -cn \
                        --arg state "${STUB_STATE:-OPEN}" \
                        --arg merged_at "${STUB_MERGED_AT:-}" \
                        '{state:$state,mergedAt:(if $merged_at == "" then null else $merged_at end)}'
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
                # Project the fixture onto the requested --json field list,
                # like real gh: a field the caller did not ask for must not
                # arrive. This is what lets a missing startedAt in a fetch
                # show up as wrong run ordering instead of passing silently.
                fields=""
                prev=""
                for a in "$@"; do
                    if [[ "$prev" == "--json" ]]; then fields="$a"; fi
                    prev="$a"
                done
                if [[ -n "$fields" ]]; then
                    jq -c --arg f "$fields" \
                        'map(. as $c | ($f | split(",")) | map({key: ., value: ($c[.] // null)}) | from_entries | with_entries(select(.value != null)))' \
                        <<<"${STUB_CHECKS:?}"
                else
                    printf '%s\n' "${STUB_CHECKS:?}"
                fi
                exit "${STUB_CHECKS_EXIT:-0}"
                ;;
        esac
        ;;
esac

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMPDIR/bin/gh"
