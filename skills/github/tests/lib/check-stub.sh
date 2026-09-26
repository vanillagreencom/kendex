#!/usr/bin/env bash
# Shared harness for the pr-merge, ci-classify-refusal and pr-create suites:
# the PASS/FAIL counters and assert helpers, a scratch repo, and the `gh` stub that
# serves every fixture through STUB_* variables (and logs argv to
# STUB_CALL_LOG when set; the state lookup's failures through
# STUB_STATE_STDERR, STUB_STATE_EXIT, STUB_STATE_SILENT_FAIL, STUB_PR_MISSING
# and STUB_STATE_FAIL_ONCE, a marker path the first lookup of a run creates;
# the branch-rule reads' failures through STUB_RULES_EXIT and
# STUB_BRANCH_EXIT). STUB_POST_GRAPHQL_PARTIAL makes the post-merge read a
# GraphQL 200 carrying an errors array beside data, STUB_POST_VIEW_FAIL fails
# its pr-view fallback, and STUB_BASE_OID is the base end of the class-policy
# range, whose head end is STUB_POLICY_HEAD where set, else STUB_HEAD. STUB_REVIEW_DECISION and STUB_REVIEW_LATEST are the readiness check's
# reviewDecision and latestReviews. STUB_REPLY_FAIL and STUB_RESOLVE_FAIL
# make the review-thread reply and resolve mutations answer a GraphQL error,
# STUB_REOPEN_FAIL the unresolve mutation,
# and STUB_REQUIRE_TOKEN refuses either without the bot token.
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
            if [[ "$*" == *"mergeQueueEntry"* ]]; then
                if [[ "${STUB_POST_GRAPHQL_FAIL:-false}" == "true" ]]; then
                    echo '{"errors":[{"message":"queue fields unavailable"}]}'
                    exit 1
                fi
                # The same partial answer on the post-merge read: data beside
                # errors, with the queue field the caller needs left null.
                if [[ "${STUB_POST_GRAPHQL_PARTIAL:-false}" == "true" ]]; then
                    jq -cn --arg state "${STUB_POST_STATE:-OPEN}" \
                        --arg head "${STUB_POST_HEAD:-${STUB_HEAD:-test-head}}" \
                        '{errors:[{message:"partial"}],data:{repository:{pullRequest:{state:$state,headRefOid:$head,headRefName:"issue-123",mergeCommit:null,autoMergeRequest:null,isInMergeQueue:null,mergeQueueEntry:null}}}}'
                    exit 0
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
            # The thread mutations post-reply.sh and resolve-thread.sh send.
            if [[ "$*" == *unresolveReviewThread* ]]; then
                if [[ "${STUB_REOPEN_FAIL:-false}" == "true" ]]; then
                    echo '{"errors":[{"message":"reopen refused"}]}'
                    exit 1
                fi
                echo '{"data":{"unresolveReviewThread":{"thread":{"id":"PRRT_x","isResolved":false}}}}'
                exit 0
            fi
            if [[ "$*" == *addPullRequestReviewThreadReply* || "$*" == *resolveReviewThread* ]]; then
                if [[ "${STUB_REQUIRE_TOKEN:-false}" == "true" && "${GH_TOKEN:-}" != "ghp_test_token" ]]; then
                    echo "missing effective token for thread mutation" >&2
                    exit 45
                fi
                if [[ "$*" == *addPullRequestReviewThreadReply* ]]; then
                    if [[ "${STUB_REPLY_FAIL:-false}" == "true" ]]; then
                        echo '{"errors":[{"message":"reply refused"}]}'
                        exit 1
                    fi
                    echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_1","url":"https://github.com/owner/repo/pull/123#discussion_r1"}}}}'
                    exit 0
                fi
                if [[ "${STUB_RESOLVE_FAIL:-false}" == "true" ]]; then
                    echo '{"errors":[{"message":"resolve refused"}]}'
                    exit 1
                fi
                echo '{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_x","isResolved":true}}}}'
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
                # The review gate's class-policy range, read only where a
                # class policy is active. Matched before the headRefOid
                # handler, whose pattern this one contains.
                if [[ "$*" == *"--json baseRefOid,headRefOid"* ]]; then
                    if [[ "${STUB_POLICY_RANGE_FAIL:-false}" == "true" ]]; then
                        echo "could not read the pull request endpoints" >&2
                        exit 1
                    fi
                    jq -cn --arg b "${STUB_BASE_OID-base-oid}" --arg h "${STUB_POLICY_HEAD:-${STUB_HEAD:-test-head}}" \
                        '{baseRefOid:(if $b == "" then null else $b end),headRefOid:$h}'
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
                    # Unset is a PR nobody set a decision for, which GitHub
                    # answers APPROVED here. Set-but-empty is the answer a base
                    # with no required-review rule gives, so the default must
                    # not swallow it: `-`, never `:-`.
                    jq -cn --arg d "${STUB_REVIEW_DECISION-APPROVED}" --argjson l "$latest" \
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
