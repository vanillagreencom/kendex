#!/usr/bin/env bash
# Shared harness for the pr-merge, ci-classify-refusal and pr-create suites:
# the PASS/FAIL counters and assert helpers, a scratch repo, and the `gh` stub that
# serves every fixture through STUB_* variables (and logs argv to
# STUB_CALL_LOG when set; the state lookup's failures through
# STUB_STATE_STDERR, STUB_STATE_EXIT, STUB_STATE_SILENT_FAIL, STUB_PR_MISSING
# and STUB_STATE_FAIL_ONCE, a marker path the first lookup of a run creates;
# the branch-rule reads' failures through STUB_RULES_EXIT and
# STUB_BRANCH_EXIT; a ruleset read's answer through STUB_RULESET_JSON_<id>,
# per ruleset id, and its failure through STUB_RULESET_EXIT). STUB_POST_GRAPHQL_PARTIAL makes the
# post-merge read a GraphQL 200 carrying an errors array beside data, and
# STUB_POST_VIEW_FAIL fails its pr-view fallback. STUB_BASE_OID is the base end of the pull
# request's range, whose head end is STUB_RANGE_HEAD where set, else
# STUB_HEAD, and STUB_RANGE_FAIL fails that
# read. STUB_REVIEW_DECISION and STUB_REVIEW_LATEST are the readiness check's
# reviewDecision and latestReviews, and STUB_REQUIRE_TOKEN refuses a
# merge-path call without the bot token. The repository read answers
# STUB_MERGE_METHODS, STUB_DELETE_BRANCH_ON_MERGE, STUB_DEFAULT_BRANCH and
# STUB_REPO_PUSHLESS, or fails on STUB_REPO_EXIT; check-review-replies' reads
# answer the pull request by STUB_HEAD (default test-head) and its author
# by the account pr-author, id 1001, its identity read (`api graphql`
# naming viewer) the fixed account lanes-app[bot], id 2002, set by no
# STUB_* variable, its review threads STUB_THREADS (a JSON array of thread nodes, failing on
# STUB_THREADS_FAIL, and only a read selecting isResolved, pr-threads', on
# STUB_THREAD_STATE_FAIL), its reviews STUB_REVIEWS and its PR-level comments
# STUB_ISSUE_COMMENTS, each of those three collections `[]` when unset. The
# viewer arm precedes the reviewThreads arm and answers any GraphQL call
# whose argv holds `viewer`, so a threads query naming a viewer field would
# get the login. The branch-rule read adds
# STUB_QUEUE_METHOD's queue on STUB_QUEUE_BRANCH and STUB_RULE_METHODS's
# pull_request rule; STUB_NO_REPO fails `repo view`. A merge call passing
# neither --auto nor --admin on a base holding a merge_queue rule (in
# STUB_GATE_RULES, or STUB_QUEUE_METHOD's on STUB_BASE) is refused as GitHub
# refuses it: gh warns and exits 0, and where STUB_MERGE_REFUSED names a
# file, the refusal creates it and every later post-merge read answers the
# PR open, unqueued and unarmed.
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
# A refused merge changed nothing, whatever outcome the row's world set.
if [[ -n "${STUB_MERGE_REFUSED:-}" && -f "$STUB_MERGE_REFUSED" ]]; then
    unset STUB_POST_STATE STUB_POST_AUTO_JSON STUB_POST_IN_QUEUE STUB_POST_QUEUE_ENTRY_JSON STUB_POST_QUEUE_STATE STUB_MERGE_COMMIT
fi

case "${1:-}" in
    auth)
        if [[ "${2:-}" == "status" ]]; then
            echo "Logged in"
            exit 0
        fi
        ;;
    repo)
        # STUB_NO_REPO: a checkout gh finds no GitHub repository for.
        if [[ "${2:-}" == "view" && "${STUB_NO_REPO:-false}" == "true" ]]; then
            echo "none of the git remotes configured for this repository point to a known GitHub host" >&2
            exit 1
        fi
        if [[ "${2:-}" == "view" ]]; then
            # The bare slug: this stub does not apply gh's own --json / -q
            # filters, and the shared resolver asks for nameWithOwner.
            echo 'owner/repo'
            exit 0
        fi
        ;;
    api)
        # The branch-rule reads: the arming gate's approval count and the
        # required-context read share these endpoints, so both fixtures serve
        # the caller's own --jq. The default world has auto-merge, a ruleset
        # check requiring no named context, and a pull_request rule requiring
        # 1 approval, thread resolution and stale-approval dismissal.
        # A slash after branches/ is an unencoded branch name: no answer.
        rules='[{"type":"required_status_checks"},{"type":"pull_request","parameters":{"required_approving_review_count":1,"required_review_thread_resolution":true,"dismiss_stale_reviews_on_push":true}}]'
        [[ -z "${STUB_GATE_RULES:-}" ]] || rules="$STUB_GATE_RULES"
        classic='{"protection":{"enabled":false,"required_status_checks":{"contexts":[],"checks":[]}}}'
        [[ -z "${STUB_CLASSIC_JSON:-}" ]] || classic="$STUB_CLASSIC_JSON"
        jq_filter=""
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--jq" ]]; then jq_filter="$a"; fi
            prev="$a"
        done
        case "${2:-}" in
            'repositories/'*)
                [[ "${STUB_SOURCE_EXIT:-0}" == 0 ]] || exit "$STUB_SOURCE_EXIT"
                id=${2#repositories/}
                case "$id" in 123) source_name=owner/repo ;; 999) source_name=org/source ;; 888) source_name=org/other ;; *) exit 1 ;; esac
                jq -cn --argjson id "$id" --arg name "$source_name" '{id:$id,full_name:$name,default_branch:"main"}'
                exit 0 ;;
            'repos/'*'/commits/'*)
                [[ "${STUB_SOURCE_REVISION_EXIT:-0}" == 0 ]] || exit "$STUB_SOURCE_REVISION_EXIT"
                echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                exit 0 ;;
            graphql)
                if [[ "${3:-}" == --input ]]; then
                    [[ "${STUB_WORKFLOW_FILES_EXIT:-0}" == 0 ]] || exit "$STUB_WORKFLOW_FILES_EXIT"
                    request=$(cat -- "$4")
                    if [[ -n "${STUB_WORKFLOW_FILES:-}" ]]; then
                        printf '%s\n' "$STUB_WORKFLOW_FILES"
                    else
                        jq -cn --argjson request "$request" --argjson pages "$STUB_WORKFLOW_RUNS" \
                            --arg source "${STUB_WORKFLOW_SOURCE_REPO:-owner/repo}" \
                            --arg revision "${STUB_WORKFLOW_SOURCE_REVISION:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" '
                            {data:{nodes:[$pages[].workflow_runs[] | . as $run
                                | select($request.variables.ids | index($run.check_suite_node_id))
                                | {id:.check_suite_node_id,databaseId:.check_suite_id,workflowRun:{databaseId:.id,runAttempt:(.run_attempt // 1),file:{path:.path,repositoryName:$source,repositoryFileUrl:("https://github.com/" + $source + "/blob/" + $revision + "/" + .path),viewerCanReadRepository:true}}}] | unique_by(.id)}}'
                    fi
                    exit 0
                fi ;;
            'repos/{owner}/{repo}/actions/runs?head_sha='*)
                [[ "${STUB_WORKFLOW_RUNS_EXIT:-0}" == 0 ]] || exit "$STUB_WORKFLOW_RUNS_EXIT"
                printf '%s\n' "${STUB_WORKFLOW_RUNS:-[]}"
                exit 0
                ;;
            'repos/{owner}/{repo}/check-suites/'*'/check-runs?per_page=100')
                [[ "${STUB_WORKFLOW_CHECKS_EXIT:-0}" == 0 ]] || exit "$STUB_WORKFLOW_CHECKS_EXIT"
                suite=${2#repos/\{owner\}/\{repo\}/check-suites/}
                suite=${suite%%/*}
                jq -ce --arg suite "$suite" '
                    if has($suite) then .[$suite] else error("unmatched check suite") end
                ' <<<"${STUB_WORKFLOW_CHECKS:-null}"
                exit 0
                ;;
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
            # A ruleset the merge route reads for current_user_can_bypass.
            'repos/{owner}/{repo}/rulesets/'*)
                if [[ "${STUB_RULESET_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_RULESET_EXIT"
                fi
                # The bypass answer is the caller's own, so it is read with
                # the merge's token or not at all.
                if [[ "${STUB_REQUIRE_TOKEN:-false}" == "true" && "${GH_TOKEN:-}" != "ghp_test_token" ]]; then
                    echo "missing effective token for the ruleset read" >&2
                    exit 41
                fi
                ruleset_var="STUB_RULESET_JSON_${2##*/}"
                ruleset='{}'
                [[ -z "${!ruleset_var:-}" ]] || ruleset="${!ruleset_var}"
                jq -r "$jq_filter" <<<"$ruleset"
                exit 0
                ;;
            # The repository, by gh's placeholder or by the slug `repo view`
            # answers: the allowed merge methods are STUB_MERGE_METHODS, and
            # STUB_REPO_PUSHLESS drops every setting GitHub withholds from a
            # token without push access.
            'repos/{owner}/{repo}' | 'repos/owner/repo')
                if [[ "${STUB_REPO_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_REPO_EXIT"
                fi
                repo_json=$(jq -cn \
                    --argjson id "${STUB_REPO_ID:-123}" \
                    --argjson auto "${STUB_ALLOW_AUTO_MERGE:-true}" \
                    --arg methods "${STUB_MERGE_METHODS-squash merge rebase}" \
                    --argjson deletes "${STUB_DELETE_BRANCH_ON_MERGE:-false}" \
                    --arg default "${STUB_DEFAULT_BRANCH:-main}" \
                    --argjson pushless "${STUB_REPO_PUSHLESS:-false}" \
                    '($methods | split(" ")) as $m
                    | {id: $id, allow_auto_merge: $auto, default_branch: $default}
                    + if $pushless then {} else {allow_squash_merge: ($m | index("squash") != null), allow_merge_commit: ($m | index("merge") != null), allow_rebase_merge: ($m | index("rebase") != null), delete_branch_on_merge: $deletes} end')
                if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter" <<<"$repo_json"; else printf '%s\n' "$repo_json"; fi
                exit 0
                ;;
            # check-review-replies' REST reads, by the slug `repo view`
            # answers. The reviews endpoint comes before the pull request's
            # own, whose pattern it matches.
            'repos/owner/repo/pulls/'*'/reviews'*)
                printf '%s\n' "${STUB_REVIEWS:-[]}"
                exit 0
                ;;
            'repos/owner/repo/issues/'*'/comments'*)
                printf '%s\n' "${STUB_ISSUE_COMMENTS:-[]}"
                exit 0
                ;;
            'repos/owner/repo/pulls/'*)
                jq -cn --arg head "${STUB_HEAD:-test-head}" '{user:{login:"pr-author",id:1001},head:{sha:$head}}'
                exit 0
                ;;
            # A merge queue on STUB_QUEUE_BRANCH with STUB_QUEUE_METHOD, and
            # a pull_request rule allowing STUB_RULE_METHODS, join the rules.
            'repos/{owner}/{repo}/rules/branches/'*)
                if [[ "${STUB_RULES_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_RULES_EXIT"
                fi
                if [[ -n "${STUB_QUEUE_METHOD:-}" && "${2#repos/\{owner\}/\{repo\}/rules/branches/}" == "${STUB_QUEUE_BRANCH:-main}" ]]; then
                    rules=$(jq -c --arg m "$STUB_QUEUE_METHOD" '. + [{type: "merge_queue", parameters: {merge_method: $m}}]' <<<"$rules")
                fi
                if [[ -n "${STUB_RULE_METHODS:-}" ]]; then
                    rules=$(jq -c --arg m "$STUB_RULE_METHODS" '. + [{type: "pull_request", parameters: {allowed_merge_methods: ($m | split(" "))}}]' <<<"$rules")
                fi
                jq -r "$jq_filter" <<<"$rules"
                exit 0
                ;;
            # The required-context read takes the whole branch object and
            # filters in-shell; the merge route's classic-protection read
            # filters with --jq.
            'repos/{owner}/{repo}/branches/'*)
                if [[ "${STUB_BRANCH_EXIT:-0}" != "0" ]]; then
                    echo "gh: Not Found (HTTP 404)" >&2
                    exit "$STUB_BRANCH_EXIT"
                fi
                if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter" <<<"$classic"; else printf '%s\n' "$classic"; fi
                exit 0
                ;;
        esac
        # check-review-replies' reading identity.
        if [[ "${2:-}" == "graphql" && "$*" == *"viewer"* ]]; then
            jq -cn '{data:{viewer:{login:"lanes-app[bot]",databaseId:2002}}}'
            exit 0
        fi
        if [[ "${2:-}" == "graphql" && "$*" == *"reviewThreads"* ]]; then
            # A GraphQL error body fails the read at once, where a bare
            # nonzero exit would be retried.
            if [[ "${STUB_THREADS_FAIL:-false}" == "true" || ("${STUB_THREAD_STATE_FAIL:-false}" == "true" && "$*" == *isResolved*) ]]; then
                echo '{"errors":[{"type":"FORBIDDEN","message":"review threads unavailable"}]}'
                exit 1
            fi
            jq -cn --argjson nodes "${STUB_THREADS:-[]}" \
                '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
            exit 0
        fi
        if [[ "${2:-}" == "graphql" ]]; then
            if [[ "$*" == *"mergeQueue(branch:"* ]]; then
                [[ " $* " == *" -f branch=${STUB_BASE:-main} "* ]] || exit 2
                [[ "${STUB_REQUIRE_TOKEN:-false}" != true || "${GH_TOKEN:-}" == ghp_test_token ]] || exit 2
                [[ "${STUB_QUEUE_ENTRIES:-0}" != fail ]] || exit 1
                jq -cn --argjson count "${STUB_QUEUE_ENTRIES:-0}" \
                    '{data:{repository:{mergeQueue:{entries:{totalCount:$count}}}}}' | jq -r "${jq_filter:-.}"
                exit 0
            fi
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
                # isCrossRepository answers only a query that names it, as
                # GitHub answers only the fields a query selects.
                jq -cn \
                    --arg state "${STUB_POST_STATE:-OPEN}" \
                    --arg head "${STUB_POST_HEAD:-${STUB_HEAD:-test-head}}" \
                    --arg branch "${STUB_HEAD_BRANCH:-issue-123}" \
                    --arg commit "${STUB_MERGE_COMMIT:-}" \
                    --arg queue_state "${STUB_POST_QUEUE_STATE:-}" \
                    --argjson auto "${STUB_POST_AUTO_JSON:-null}" \
                    --argjson in_queue "${STUB_POST_IN_QUEUE:-false}" \
                    --argjson queue_entry "${STUB_POST_QUEUE_ENTRY_JSON:-null}" \
                    --argjson cross "${STUB_CROSS_REPOSITORY:-false}" \
                    --argjson asked "$([[ "$*" == *isCrossRepository* ]] && echo true || echo false)" \
                    '{data:{repository:{pullRequest:({state:$state,headRefOid:$head,headRefName:$branch,mergeCommit:(if $commit == "" then null else {oid:$commit} end),autoMergeRequest:$auto,isInMergeQueue:$in_queue,mergeQueueEntry:$queue_entry} + (if $asked then {isCrossRepository:$cross} else {} end))}}}'
                exit 0
            fi
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
                # The pull request's range, read only by the merge route.
                # Matched before the headRefOid handler, whose pattern this
                # one contains.
                if [[ "$*" == *"--json baseRefOid,headRefOid"* ]]; then
                    if [[ "${STUB_RANGE_FAIL:-false}" == "true" ]]; then
                        echo "could not read the pull request endpoints" >&2
                        exit 1
                    fi
                    jq -cn --arg b "${STUB_BASE_OID-base-oid}" --arg h "${STUB_RANGE_HEAD:-${STUB_HEAD:-test-head}}" \
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
                if [[ "$*" == *"--json state,headRefOid,headRefName,isCrossRepository,mergeCommit,autoMergeRequest"* ]]; then
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
                        --argjson cross "${STUB_CROSS_REPOSITORY:-false}" \
                        '{state:$state,headRefOid:$head,headRefName:$branch,isCrossRepository:$cross,mergeCommit:(if $commit == "" then null else {oid:$commit} end),autoMergeRequest:$auto}'
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
                if [[ " $* " != *" --auto "* && " $* " != *" --admin "* ]]; then
                    queue_base=false
                    if [[ -n "${STUB_QUEUE_METHOD:-}" && "${STUB_BASE:-main}" == "${STUB_QUEUE_BRANCH:-main}" ]]; then
                        queue_base=true
                    elif jq -e 'any(.[]; .type == "merge_queue")' <<<"${STUB_GATE_RULES:-[]}" >/dev/null; then
                        queue_base=true
                    fi
                    if [[ "$queue_base" == true ]]; then
                        [[ -z "${STUB_MERGE_REFUSED:-}" ]] || : >"$STUB_MERGE_REFUSED"
                        echo "! The merge strategy for ${STUB_BASE:-main} is set by the merge queue" >&2
                        exit 0
                    fi
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
