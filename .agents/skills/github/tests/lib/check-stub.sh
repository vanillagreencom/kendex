#!/usr/bin/env bash
# Shared harness for the pr-merge, ci-classify-refusal and pr-create suites:
# the PASS/FAIL counters and assert helpers, a scratch repo, and the `gh` stub that
# serves every fixture through STUB_* variables (and logs argv to
# STUB_CALL_LOG when set; the state lookup's failures through
# STUB_STATE_STDERR, STUB_STATE_EXIT, STUB_STATE_SILENT_FAIL, STUB_PR_MISSING
# and STUB_STATE_FAIL_ONCE, a marker path the first lookup of a run creates;
# the branch-rule reads' failures through STUB_RULES_EXIT and
# STUB_BRANCH_EXIT).
# The admin-credential world adds STUB_BASE_OID, STUB_BEHIND_BY,
# STUB_COMPARE_FAIL, STUB_ADMIN_IN_QUEUE, STUB_ADMIN_AUTO, STUB_PR_NODE_ID,
# STUB_DEQUEUE_FAIL and STUB_QUEUE_CLEARED_FILE, the marker a successful
# dequeue writes so the re-read answers cleared.
# Sourced, never run — CI's suite glob picks up skills/*/tests/*.sh only, so
# this file lives one level down.
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
[[ -z "${STUB_AUTH_LOG:-}" ]] || printf 'GH=%s|GITHUB=%s|CFG=%s|%s\n' "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "${GH_CONFIG_DIR-<unset>}" "$*" >>"$STUB_AUTH_LOG"

case "${1:-}" in
    auth)
        if [[ "${2:-}" == "status" ]]; then
            echo "Logged in"
            exit 0
        fi
        ;;
    repo)
        if [[ "${2:-}" == "view" ]]; then
            # The bare slug: this stub does not apply gh's own --json / -q
            # filters, and the shared resolver asks for nameWithOwner.
            echo 'owner/repo'
            exit 0
        fi
        ;;
    api)
        # The branch-rule reads: the arming gate's presence check and the
        # required-context read share these endpoints, so both fixtures serve
        # the caller's own --jq. The default world has auto-merge and a
        # ruleset check requiring no named context.
        # A slash after branches/ is an unencoded branch name: no answer.
        rules='[{"type":"required_status_checks"}]'
        [[ -z "${STUB_GATE_RULES:-}" ]] || rules="$STUB_GATE_RULES"
        classic='{"protection":{"required_status_checks":{"contexts":[],"checks":[]}}}'
        [[ -z "${STUB_CLASSIC_JSON:-}" ]] || classic="$STUB_CLASSIC_JSON"
        jq_filter=""
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--jq" ]]; then jq_filter="$a"; fi
            prev="$a"
        done
        case "${2:-}" in
            # An installation token (ghs_) has no user: gh's integration 403.
            # A revoked token (*_REVOKED) gets gh's plain 401.
            user)
                if [[ "${GH_TOKEN:-}" == ghs_* ]]; then
                    echo "gh: Resource not accessible by integration (HTTP 403)" >&2
                    exit 1
                fi
                if [[ "${GH_TOKEN:-}" == *_REVOKED ]]; then
                    echo "gh: Bad credentials (HTTP 401)" >&2
                    exit 1
                fi
                echo stub-user
                exit 0
                ;;
            'repos/{owner}/{repo}/rules/branches/'*/* | 'repos/{owner}/{repo}/branches/'*/*) ;;
            # The base-containment read: how many commits the base has that the
            # PR head does not.
            'repos/{owner}/{repo}/compare/'*)
                if [[ "${STUB_COMPARE_FAIL:-false}" == "true" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit 1
                fi
                echo "${STUB_BEHIND_BY:-0}"
                exit 0
                ;;
            'repos/{owner}/{repo}') echo "${STUB_ALLOW_AUTO_MERGE:-true}"; exit 0 ;;
            'repos/{owner}/{repo}/rules/branches/'*)
                if [[ "${STUB_RULES_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_RULES_EXIT"
                fi
                jq -r "$jq_filter" <<<"$rules"
                exit 0
                ;;
            # The gate's presence check filters with --jq; the required-context
            # read takes the whole branch object and filters in-shell.
            'repos/{owner}/{repo}/branches/'*)
                if [[ "${STUB_BRANCH_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_BRANCH_EXIT"
                fi
                if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter" <<<"$classic"; else printf '%s\n' "$classic"; fi
                exit 0
                ;;
        esac
        if [[ "${2:-}" == "graphql" ]]; then
            # The admin-credential route's own reads and mutations: its queue
            # snapshot asks for the node id beside the two merge-state facts,
            # and a successful dequeue clears the state the next read returns.
            if [[ "$*" == *"dequeuePullRequest"* || "$*" == *"disablePullRequestAutoMerge"* ]]; then
                if [[ "${STUB_DEQUEUE_FAIL:-false}" == "true" ]] \
                    || { [[ "${STUB_DEQUEUE_ONLY_FAIL:-false}" == "true" ]] && [[ "$*" == *"dequeuePullRequest"* ]]; }; then
                    echo '{"errors":[{"message":"queue mutation refused"}]}'
                    exit 1
                fi
                [[ -z "${STUB_QUEUE_CLEARED_FILE:-}" ]] || : >"$STUB_QUEUE_CLEARED_FILE"
                # The shared verb checks the mutation's own payload is present, so
                # the response names it rather than an empty data object.
                if [[ "$*" == *"dequeuePullRequest"* ]]; then
                    echo '{"data":{"dequeuePullRequest":{"mergeQueueEntry":null}}}'
                else
                    echo '{"data":{"disablePullRequestAutoMerge":{"clientMutationId":"x"}}}'
                fi
                exit 0
            fi
            if [[ "$*" == *"isInMergeQueue"* && "$*" != *"mergeQueueEntry"* ]]; then
                in_queue="${STUB_ADMIN_IN_QUEUE:-false}"
                auto="${STUB_ADMIN_AUTO:-false}"
                # After a successful dequeue the same read answers cleared.
                if [[ -n "${STUB_QUEUE_CLEARED_FILE:-}" && -f "$STUB_QUEUE_CLEARED_FILE" ]]; then
                    # The post-dequeue re-read (the cleared marker is present).
                    # STUB_REREAD_FAIL makes only that read fail.
                    if [[ "${STUB_REREAD_FAIL:-false}" == "true" ]]; then
                        echo "queue re-read unavailable" >&2
                        exit 1
                    fi
                    in_queue=false
                    auto=false
                fi
                jq -cn \
                    --arg id "${STUB_PR_NODE_ID-PR_node_1}" \
                    --argjson in_queue "$in_queue" \
                    --argjson auto "$auto" \
                    '{data:{repository:{pullRequest:{id:(if $id == "" then null else $id end),isInMergeQueue:$in_queue,autoMergeRequest:(if $auto then {enabledAt:"2026-09-21T00:00:00Z"} else null end)}}}}'
                exit 0
            fi
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
            create)
                echo "https://github.com/owner/repo/pull/124"
                exit 0
                ;;
            view)
                if [[ "$*" == *"--json state,mergedAt"* ]]; then
                    if [[ -n "${STUB_STATE_STDERR:-}" ]]; then
                        printf '%s\n' "$STUB_STATE_STDERR" >&2
                        exit "${STUB_STATE_EXIT:-1}"
                    fi
                    if [[ "${STUB_STATE_SILENT_FAIL:-false}" == "true" ]]; then
                        exit "${STUB_STATE_EXIT:-1}"
                    fi
                    # Transient failure: only the first lookup of a run fails.
                    if [[ -n "${STUB_STATE_FAIL_ONCE:-}" && ! -f "$STUB_STATE_FAIL_ONCE" ]]; then
                        : >"$STUB_STATE_FAIL_ONCE"
                        echo "error connecting to api.github.com" >&2
                        exit 1
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
                # The admin route reads the head and the base in one call; it
                # must match before the headRefOid and baseRefName,baseRefOid
                # handlers, whose patterns it contains as substrings.
                if [[ "$*" == *"--json headRefOid,baseRefName,baseRefOid"* ]]; then
                    jq -cn --arg h "${STUB_HEAD:-test-head}" --arg b "${STUB_BASE:-main}" \
                        --arg oid "${STUB_BASE_OID-base-oid}" \
                        '{headRefOid:$h,baseRefName:$b,baseRefOid:(if $oid == "" then null else $oid end)}'
                    exit 0
                fi
                if [[ "$*" == *"--json baseRefName,baseRefOid"* ]]; then
                    # The admin route's pre-merge base re-read. STUB_BASE_MOVED
                    # makes it differ from the preflight combined read, so the
                    # base-moved guard fires.
                    oid="${STUB_BASE_OID-base-oid}"
                    [[ "${STUB_BASE_MOVED:-false}" != "true" ]] || oid="base-oid-moved"
                    jq -cn --arg b "${STUB_BASE:-main}" --arg oid "$oid" \
                        '{baseRefName:$b,baseRefOid:(if $oid == "" then null else $oid end)}'
                    exit 0
                fi
                if [[ "$*" == *"--json baseRefName"* ]]; then
                    echo "${STUB_BASE:-main}"
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
                    echo "${STUB_MERGEABLE:-MERGEABLE}"
                    exit 0
                fi
                if [[ "$*" == *"--json reviewDecision,latestReviews"* ]]; then
                    latest="${STUB_REVIEW_LATEST:-}"
                    [[ -n "$latest" ]] || latest='[{"state":"APPROVED"}]'
                    jq -cn --arg d "${STUB_REVIEW_DECISION:-APPROVED}" --argjson l "$latest" \
                        '{reviewDecision:$d,latestReviews:$l}'
                    exit 0
                fi
                if [[ "$*" == *"--json state,headRefOid,headRefName,mergeCommit,autoMergeRequest"* ]]; then
                    if [[ "${STUB_POST_VIEW_FAIL:-false}" == "true" ]]; then
                        echo "post-merge view unavailable" >&2
                        exit 1
                    fi
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
