#!/usr/bin/env bash
# pr-merge: the --check readiness JSON and its stderr verdict, whose review
# threads are read by check-review-replies alone, the terminal states (a merged or closed PR short-circuits
# every mode, before and after a state lookup that failed once), the guarded
# mutation and its post-call outcomes, the --auto arm's approval gate, the
# retired override flags, the retired merge settings no mode reads, the
# immediate merge's route past a merge queue: --admin where the queue is all
# it would skip and the PR is not queue-only, the queue otherwise, the
# queue-only class read off harness-ci's classifier for the pull request's
# range; and the arm at creation, which arms nothing where that route reads
# admin. The row format and the world words are
# lib/pr-merge-world.sh's.
set -euo pipefail

# shellcheck source=lib/pr-merge-world.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-merge-world.sh"

# ci-classify-refusal and orch merge-pr consume the unknown: issue prefix.
# The cause field distinguishes GitHub's UNKNOWN answer from an unreadable read.
printf '\n \t\ngh: Server Error (HTTP 502)\nsecond diagnostic\n' >"$TMPDIR/mergeable.err"
mutant_copy lost-mergeable-error \
  '        issues+=("unknown: cause=read-failed $mergeable_detail; retry, or arm with --auto")' \
  '        issues+=("unknown: GitHub still computing mergeable status; retry, or arm with --auto")' >/dev/null
UNKNOWN_OPEN="state=OPEN mergeable=UNKNOWN at=-"
READ_FAILED="unknown: cause=read-failed gh: Server Error (HTTP 502); retry, or arm with --auto"
run_table "the mergeable read" "\
a failed mergeable read keeps its first nonblank stderr line|checks:ci-required env:STUB_MERGEABLE_EXIT=1 env:STUB_MERGEABLE_STDERR_FILE=$TMPDIR/mergeable.err|check|0|merge=false transient=true $UNKNOWN_OPEN runs=- issues=[$READ_FAILED] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>|check-mutant:lost-mergeable-error
a failed mergeable read refuses the immediate merge with no mutation|checks:ci-required env:STUB_MERGEABLE_EXIT=1 env:STUB_MERGEABLE_STDERR_FILE=$TMPDIR/mergeable.err|immediate|1|-|{blocked};{transient};✗ unknown: cause=read-failed gh: Server Error (HTTP 502)\\; retry, or arm with --auto;{hint-auto}|calls=$CHECK auth=<unset>
a real UNKNOWN answer names computing|checks:ci-required env:STUB_MERGEABLE=UNKNOWN|check|0|merge=false transient=true $UNKNOWN_OPEN runs=- issues=[unknown: cause=computing GitHub still computing mergeable status; retry, or arm with --auto] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a silent mergeable failure names gh and its exit code|checks:ci-required env:STUB_MERGEABLE_EXIT=4|check|0|merge=false transient=true $UNKNOWN_OPEN runs=- issues=[unknown: cause=read-failed gh pr view exited 4 with no diagnostic; retry, or arm with --auto] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
an invalid successful mergeable answer is an unreadable read|checks:ci-required env:STUB_MERGEABLE=null|check|0|merge=false transient=true $UNKNOWN_OPEN runs=- issues=[unknown: cause=read-failed gh pr view returned invalid mergeable answer 'null'; retry, or arm with --auto] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
"

run_table "the readiness check" "\
pending checks block, transiently, one issue naming each|checks:pending2 checks-exit:8|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a failed check blocks permanently|checks:failed|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Lint (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a red check the base branch does not require blocks nothing and is named as a warning|checks:optional-red required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a red required context still blocks|checks:optional-red required:CodeQL|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a base that requires no context counts every check|checks:optional-red repo:no-rule|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a classic protection context supplies the required set too|checks:optional-red classic:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
the legacy classic contexts array supplies it as well as checks[]|checks:optional-red classic-contexts:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset rule that gates on no check keeps the required set readable|checks:optional-red rule-type:pull_request|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a code-scanning rule is the same unnameable gate|checks:optional-red rule-type:code_scanning|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a Copilot review rule demands a review, not a check, so the required set stands|checks:optional-red rule-type:copilot_code_review|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset read that errors discards the contexts classic protection did supply|checks:optional-red classic:Lint rules:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a branch-protection read that errors discards the contexts the ruleset did supply|checks:optional-red required:Lint branch:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a required context that registered no check is pending, never a pass|checks:unregistered required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup with a required context is pending, not unconfigured|checks:none required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup on a base that requires nothing stays unconfigured|checks:none|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_unconfigured: No status checks configured] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
an optional check still running blocks nothing either|checks:optional-pending checks-exit:8 required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a branch answer carrying no protection object is unreadable, so every check counts|checks:optional-red required:Lint repo:no-protection|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
pending and failed together are not transient, both named|checks:mixed checks-exit:8|check|0|merge=false transient=false $OPEN runs=- issues=[ci_pending: Unit Tests (IN_PROGRESS);ci_failed: Lint (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
success and skipped checks merge with no issue|checks:pass-skip|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a superseded run's cancelled jobs are not failures: only the current run's pending check blocks, transiently|checks:superseded-pending checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099680623 issues=[ci_pending: Changes (IN_PROGRESS)] warnings=[] $KEYS|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a job the current run re-created and passed is not blocked by the old run's cancelled copy|checks:superseded-replaced|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[] $KEYS|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
the current run's own cancellation is a failure|checks:current-cancel checks-exit:8|check|0|merge=false transient=false $OPEN runs=29099680623 issues=[ci_failed: Integration (CANCELLED)] warnings=[] $KEYS|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a clean run: the verdict is mergeable and head-run names the scoped run|checks:clean-run|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[] $KEYS|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
a commit status with no workflow supplies its own run id|checks:status-only checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099700000 issues=[ci_pending: CI Required (PENDING)] warnings=[] $KEYS|blocked;head-run: 29099700000|calls=$CHECK auth=<unset>
a changes-requested reviewDecision blocks permanently|checks:ci-required review:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a changes-requested latest review blocks when the decision does not say so|checks:ci-required review:REVIEW_REQUIRED review-latest:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a PR with no approval is named not_approved, a warning that blocks nothing here|checks:ci-required review:REVIEW_REQUIRED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[not_approved: Review status is 'REVIEW_REQUIRED'] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
an approving latest review clears not_approved where the decision is empty|checks:ci-required review:none review-latest:APPROVED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a native-approved PR whose decline names no mechanism is blocked by the live reply check|checks:ci-required replies:unreasoned|check|0|merge=false transient=false $OPEN runs=- issues=[review_replies: unreasoned-decline count=1] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
two failing reply rules join into one issue, each rule line kept|checks:ci-required replies:two|check|0|merge=false transient=false $OPEN runs=- issues=[review_replies: untracked-claim count=1; unreasoned-decline count=1] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a reply check that cannot read the threads blocks, naming its refusal|checks:ci-required replies:fail|check|0|merge=false transient=false $OPEN runs=- issues=[review_replies_unread: check-review-replies: read-failed pr=123] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a merged PR reports its state and timestamp, no issues, no check fetched|state:MERGED merged-at|check|0|merge=false transient=false state=MERGED mergeable=UNKNOWN at=2026-08-15T09:41:12Z runs=- issues=[] warnings=[] $KEYS|merged;head-run: none|calls=view:state auth=<unset>
a closed PR reports its state, no issues|state:CLOSED|check|0|merge=false transient=false state=CLOSED mergeable=UNKNOWN at=- runs=- issues=[] warnings=[] $KEYS|closed;head-run: none|calls=view:state auth=<unset>
a missing PR is not_found|pr:missing|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
GitHub's own missing-PR wording is not_found too|state-err:graphql-notfound|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
an auth failure is gh_error with its diagnostic, never not_found|state-err:401|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh: Bad credentials (HTTP 401)] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
a rate limit keeps its diagnostic|state-err:ratelimit|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: API rate limit exceeded for user ID 1.] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
a silent failure names gh and its exit code|state-err:silent4|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh pr view exited 4 with no diagnostic] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
"

# Required workflow names come from its head run's check suite, not its file
# name or display name. An unfinished run has only partial job evidence.
WORKFLOW_CHECK="view:state,view:mergeable,checks,view:head,view:reviews"
# Only the unreadable-source row delays the request writer. The old-call
# control waits for a later jq call to prove gh has closed the reader. Its
# completion marker keeps stderr from arriving after the row.
command -v jq >"$TMPDIR/bin/real-jq"
cat >"$TMPDIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_jq=$(cat "${0%/*}/real-jq")
if [[ -n "${STUB_JQ_REQUEST_MARKER:-}" ]]; then
    if [[ "${1:-}" == -cn && "${2:-}" == --argjson && "${3:-}" == ids ]]; then
        if [[ "${STUB_JQ_REQUEST_ASYNC:-false}" == true ]]; then
            while [[ ! -f "$STUB_JQ_REQUEST_MARKER.released" ]]; do sleep 0.01; done
        fi
        rc=0
        # jq must report EPIPE instead of dying on SIGPIPE on this platform.
        (trap '' PIPE; sleep 0.1; exec "$real_jq" "$@") || rc=$?
        : >"$STUB_JQ_REQUEST_MARKER.done"
        exit "$rc"
    fi
    if [[ -f "$STUB_JQ_REQUEST_MARKER.waiting" ]]; then
        : >"$STUB_JQ_REQUEST_MARKER.released"
        while [[ ! -f "$STUB_JQ_REQUEST_MARKER.done" ]]; do sleep 0.01; done
        rm -f -- "$STUB_JQ_REQUEST_MARKER.waiting" "$STUB_JQ_REQUEST_MARKER.done" "$STUB_JQ_REQUEST_MARKER.released"
    fi
fi
exec "$real_jq" "$@"
EOF
chmod +x "$TMPDIR/bin/jq"
mutant_copy workflow-request-pipe '                if ! request=$(jq -cn --argjson ids "$nodes" '\''{query: "query($ids:[ID!]!) { nodes(ids:$ids) { ... on CheckSuite { id databaseId workflowRun { databaseId runAttempt file { path repositoryName repositoryFileUrl viewerCanReadRepository } } } } }", variables:{ids:$ids}}'\'') \' '                if ! files=$(gh api graphql --input <(STUB_JQ_REQUEST_ASYNC=true jq -cn --argjson ids "$nodes" '\''{query: "query($ids:[ID!]!) { nodes(ids:$ids) { ... on CheckSuite { id databaseId workflowRun { databaseId runAttempt file { path repositoryName repositoryFileUrl viewerCanReadRepository } } } } }", variables:{ids:$ids}}'\'') 2>/dev/null) \' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-drop '                --argjson repository_id "$repo_id" --arg head "$head" '\''$bindings + [{definition: $definition.rule, consumer: {repository_id: $repository_id, head: $head}, runs: $runs}]'\'') || return 1' '                --argjson repository_id "$repo_id" --arg head "$head" '\''$bindings + [{definition: $definition.rule, consumer: {repository_id: $repository_id, head: $head}, runs: []}]'\'') || return 1' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-unfinished '                | if length == 0 or any(.[]; .status != "completed") then {state: "pending"}' '                | if length == 0 or any(.[]; .status != "completed") then {state: "ready", runs: map({id, suite_id: .check_suite_id})}' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-wrong-suite '                  else {state: "ready", runs: map({id, suite_id: .check_suite_id})} end' '                  else {state: "ready", runs: map({id, suite_id: .repository.id})} end' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-harmless '                              and .repository.id == $repo_id)]' '                              and $repo_id == .repository.id)]' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-source '                              and .repository.id == $repo_id)]' '                              and .repository.id == $workflow.repository_id)]' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-unreadable '            unreadable) can_merge=false; issues+=("ci_fetch_failed: Required workflow evidence unavailable") ;;' '            unreadable) ;;' >/dev/null
mutant_copy workflow-parameters "       else \"unreadable:workflows\" end)'" "       else \"unnameable:workflows\" end)'" lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-empty '                if [ "$checks" = '\''[]'\'' ]; then' '                if false; then' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-fallback '        fallback=true' "        echo '{\"state\":\"ready\",\"contexts\":[]}'; return 0" lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-membership '      or any($requirements.workflows[]?.runs[]?.checks[]?; .link == $check.link)' '      or any($requirements.workflows[]?.runs[]?.checks[]?; .name == $check.name)' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-definition '                           | select($file.path == $definition.rule.path' '                           | select(true or $file.path == $definition.rule.path' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-repository-id '                    map(select(.id == $rule.repository_id))' '                    map(select(true))' lib/ci-run-correlation.sh >/dev/null
mutant_copy workflow-reuse '                           | if ($claimed_runs | index($run.id)) != null then error("ambiguous source definition") else . end' '                           | if false then error("ambiguous source definition") else . end' lib/ci-run-correlation.sh >/dev/null
run_table "required workflows" "\
a required-workflows rule with unreadable parameters refuses|checks:workflow-green rule-type:workflows|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>|check-mutant:workflow-parameters
a required workflow adds its checks while red CodeQL stays optional|checks:workflow-optional-red workflow:matched|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-wrong-suite
an unfinished matched workflow with successful registered jobs holds the required workflow|checks:workflow-optional-red workflow:in-progress|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-unfinished
later run and check pages supply required workflow evidence|checks:workflow-optional-red workflow:paged|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
the required workflow own red check blocks|checks:workflow-required-red workflow:matched|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Request review (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
must-fail: dropping workflow contexts makes the required red job optional|checks:workflow-required-red workflow:matched|check-mutant:workflow-drop|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: Request review (FAILURE)] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a required workflow job absent from the rollup stays pending|checks:optional-red workflow:matched|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Request review (missing)] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a failed workflow-run read refuses the merge|checks:workflow-optional-red workflow:runs-fail|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a failed workflow check-suite read refuses the merge|checks:workflow-optional-red workflow:checks-fail|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a required workflow without a head run holds the required workflow|checks:workflow-optional-red workflow:missing|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a second required workflow without a head run holds the required workflow|checks:workflow-optional-red workflow:second-missing|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an incomplete run collection refuses the merge|checks:workflow-optional-red workflow:partial-runs|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an incomplete check collection refuses the merge|checks:workflow-optional-red workflow:partial-checks|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
another workflow path supplies no required workflow evidence|checks:workflow-optional-red workflow:wrong-path|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
another head supplies no required workflow evidence|checks:workflow-optional-red workflow:wrong-head|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
another execution repository supplies no required workflow evidence|checks:workflow-optional-red workflow:wrong-repository|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an empty workflow check suite holds the required workflow|checks:workflow-green workflow:empty-checks|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-empty
a source workflow executes in the consumer repository while CodeQL is pending|checks:workflow-optional-pending checks-exit:8 workflow:cross-repository|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-source
a source workflow executes in the consumer repository while CodeQL is queued|checks:workflow-optional-queued checks-exit:8 workflow:cross-repository|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an unnameable rule cannot hide an active required workflow|checks:workflow-green workflow:unnameable-active|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-fallback
unreadable classic protection cannot hide unreadable required workflow evidence|checks:workflow-green workflow:runs-fail branch:fail|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-fallback
an unnameable rule retains all-check fallback after required work passes|checks:workflow-optional-pending workflow:unnameable-completed|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: CodeQL (IN_PROGRESS)] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an active required workflow holds even when all visible jobs are green|checks:workflow-green workflow:in-progress|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-unfinished
a pending required job holds the merge|checks:workflow-required-pending checks-exit:8 workflow:in-progress|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
unreadable required run evidence refuses with every visible job green|checks:workflow-green workflow:runs-fail|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-unreadable
a completed run without a conclusion refuses green jobs|checks:workflow-green workflow:unreadable-result|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a failed required workflow holds green jobs|checks:workflow-green workflow:failed|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a newer successful run replaces a failed required run|checks:workflow-green workflow:newer-success|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an older active run cannot hold its completed replacement|checks:workflow-green workflow:older-active|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a successful rerun under an older ID replaces a failed newer run|checks:workflow-green workflow:rerun-success|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an older failed run finishing later cannot replace the newer successful run|checks:workflow-green workflow:older-finished-late|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a missing source file refuses|checks:workflow-green workflow:source-null|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a same-path local run cannot prove either source definition|checks:workflow-green workflow:source-repository-collision|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an unreadable documented source lookup refuses|checks:workflow-green workflow:source-lookup-unreadable|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a source name with the wrong repository ID cannot prove the rule|checks:workflow-green workflow:source-id-mismatch|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-repository-id
a proven pin cannot satisfy another pin in the same source|checks:workflow-green workflow:source-pin-collision|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a different source ref cannot prove the required revision|checks:workflow-green workflow:source-ref-collision|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Required workflow] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-definition
a pinned source definition passes in its consumer|checks:workflow-green workflow:source-pinned|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
two distinct refs at the same source pin lack unambiguous proof|checks:workflow-green workflow:source-same-pin-refs|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-reuse
older runs cannot supply the missing ref identity at the same pin|checks:workflow-green workflow:source-same-pin-ref-runs|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
identical definitions share their proved execution|checks:workflow-green workflow:source-duplicate|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a source ref URL proves its configured ref|checks:workflow-green workflow:source-ref|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
an unreadable source revision refuses|checks:workflow-green workflow:source-revision-unreadable|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>
a failed optional job with a required job name stays optional|checks:workflow-same-failure workflow:same-name|check|0|merge=true transient=false $OPEN runs=500,600 issues=[] warnings=[ci_optional_failed: Request review (FAILURE)] $KEYS|mergeable;head-run: 500,600|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-membership
a pending optional job with a required job name stays optional|checks:workflow-same-pending checks-exit:8 workflow:same-name|check|0|merge=true transient=false $OPEN runs=500,600 issues=[] warnings=[] $KEYS|mergeable;head-run: 500,600|calls=$WORKFLOW_CHECK auth=<unset>
a queued optional job with a required job name stays optional|checks:workflow-same-queued checks-exit:8 workflow:same-name|check|0|merge=true transient=false $OPEN runs=500,600 issues=[] warnings=[] $KEYS|mergeable;head-run: 500,600|calls=$WORKFLOW_CHECK auth=<unset>
an unchanged workflow decision survives a clean control fixture|checks:workflow-green workflow:matched|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|same:check-mutant:workflow-harmless
source metadata that cannot be read refuses|checks:workflow-green workflow:source-unreadable env:STUB_JQ_REQUEST_MARKER=$TMPDIR/workflow-request|check|0|merge=false transient=true $OPEN runs=- issues=[ci_fetch_failed: Required workflow evidence unavailable] warnings=[] $KEYS|blocked;head-run: none|calls=$WORKFLOW_CHECK auth=<unset>|check-mutant:workflow-request-pipe
"
assert_contains "$(cat "$TMPDIR/stderr")" 'jq: error: writing output failed: Broken pipe' 'the old request writer fails on the closed gh input'

WORKFLOW_HEAD=737bce791577e140436490e0fed5751bb5144a61
run_table "required workflows at the exact merge head" "\
optional pending CodeQL permits the exact-head merge|head:$WORKFLOW_HEAD checks:workflow-optional-pending checks-exit:8 workflow:cross-repository post:MERGED merge-commit:merged-oid|with:--expected-head+$WORKFLOW_HEAD+--keep-branch|0|-|{no-token};MERGED PR #123|calls=$WORKFLOW_CHECK,view:head,merge:squash,graphql:queue auth=<unset>
optional queued CodeQL permits the exact-head merge|head:$WORKFLOW_HEAD checks:workflow-optional-queued checks-exit:8 workflow:cross-repository post:MERGED merge-commit:merged-oid|with:--expected-head+$WORKFLOW_HEAD+--keep-branch|0|-|{no-token};MERGED PR #123|calls=$WORKFLOW_CHECK,view:head,merge:squash,graphql:queue auth=<unset>
an unfinished required run holds the exact-head merge with green jobs|head:$WORKFLOW_HEAD checks:workflow-green workflow:in-progress|with:--expected-head+$WORKFLOW_HEAD+--keep-branch|1|-|{blocked};{transient};✗ ci_pending: Required workflow;{hint-auto}|calls=$WORKFLOW_CHECK auth=<unset>
unreadable required run evidence refuses the exact-head merge with green jobs|head:$WORKFLOW_HEAD checks:workflow-green workflow:runs-fail|with:--expected-head+$WORKFLOW_HEAD+--keep-branch|1|-|{blocked};{transient};✗ ci_fetch_failed: Required workflow evidence unavailable;{hint-auto}|calls=$WORKFLOW_CHECK auth=<unset>
"

# GitHub's approval cannot read what a review reply says, so the readiness
# check runs check-review-replies live. Its must-fail control is a copy whose
# call to it is cut, so the reply check never runs.
mutant_copy no-replies '        replies_out=$(bash "$SCRIPT_DIR/check-review-replies.sh" "$pr_num" 2>"$replies_err") || replies_rc=$?' '        replies_out=""' >/dev/null

run_table "the merge path" "\
a failed check without --auto is blocked with the auto hint|checks:failed|immediate|1|-|{blocked};{permanent};✗ ci_failed: Lint (FAILURE);{hint-auto}|calls=$CHECK auth=<unset>
a native-approved PR with a bad disposition is not merged, and no auto hint is given|checks:ci-required replies:unreasoned post:MERGED merge-commit:merged-oid|immediate|1|-|{blocked};{permanent};✗ review_replies: unreasoned-decline count=1|calls=$CHECK auth=<unset>
must-fail: with the reply check's call cut, the same PR merges|checks:ci-required replies:unreasoned post:MERGED merge-commit:merged-oid|mutant:no-replies:--keep-branch|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
a red optional check does not stop the merge, and is named on the way|checks:optional-red required:Lint post:MERGED merge-commit:merged-oid|immediate|0|-|Warnings:;⚠ ci_optional_failed: CodeQL (FAILURE);{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
the router promotes the bot token for the mutation and the snapshot|checks:ci-required require-token post:MERGED merge-commit:merged-oid env:GH_BOT_TOKEN=ghp_test_token|router:--squash|0|-|Using GH_BOT_TOKEN as stub-user;MERGED PR #123|calls=user,$PRE,user,merge:squash,graphql:queue auth=ghp_test_token
a prepared head that drifted fails before arming|checks:ci-required head:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|expected:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|1|-|BLOCKED PR #123 — prepared head changed before merge attempt (expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, actual=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)|calls=$PRE auth=<unset>
an active queue entry after --auto is success-pending, exit 75, volatile|checks:ci-required head:28132e9b990a595417f79f4e213b4e984bf676fd post-entry require-token env:GH_BOT_TOKEN=ghp_test_token|auto|75|-|Using GH_BOT_TOKEN as stub-user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,user,merge:squash:auto,graphql:queue auth=<unset>+ghp_test_token
--auto refuses where auto-merge is off: nothing mutated|checks:ci-required repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{auto-remedy}|calls=$PRE auth=<unset>
the refusal is the first stderr line, ahead of the checks' warnings|checks:none repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{auto-remedy}|calls=$PRE auth=<unset>
a base branch with slashes is URL-encoded in the gate reads and arms|checks:ci-required post-auto base:release/foo/bar|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
classic auto-merge is success-pending, exit 75, volatile|checks:ci-required post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
an immediate merge whose snapshot is MERGED exits 0|checks:ci-required post:MERGED merge-commit:merged-oid|auto|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
OPEN, unqueued and unarmed after a zero exit is blocked, naming the absent proof|checks:ci-required|auto|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a snapshot on a newer head fails closed|checks:ci-required head:guarded-head post-head:newer-unreviewed-head post-queue|auto|1|-|{no-token};BLOCKED PR #123 — head changed during merge attempt (expected=guarded-head, actual=newer-unreviewed-head)|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a merge whose both post-merge reads fail is blocked, never a success|checks:ci-required merge-commit:merged-oid graphql:fail post-view-fail|immediate|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=UNKNOWN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:squash,graphql:queue,view:post auth=<unset>
the REST fallback keeps classic auto-merge when the queue query fails|checks:ci-required graphql:fail post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue,view:post auth=<unset>
a second --auto on a queued PR: gh's already-queued failure, the snapshot's entry wins|checks:ci-required head:already-queued-head merge-fail:already-queued post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a genuine merge failure with no proof stays blocked with gh's output|checks:ci-required merge-fail:policy|auto|1|-|{no-token};{merge-failed};failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a failed CLI is still a success when the exact-head snapshot is MERGED|checks:ci-required merge-fail:transport post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

# The --auto arm's gate. GitHub merges an armed PR the moment its required
# checks pass unless a ruleset requires an approval, on that approval past
# open threads unless one requires thread resolution, and on an approval of
# an earlier head unless one dismisses stale approvals on push, so the arm is
# made only where the base's pull_request rules, one or several, meet every
# row of merge_gate_gap's rule shape. --auto defers every readiness blocker
# to that gate but the reply check's, which no GitHub rule holds. Its
# must-fail controls, each a copy of the scripts tree with one whole line of
# pr-merge.sh replaced, the rest kept: each shape row cut, so a base missing
# that row's setting arms; the value-kind check answering true, so a missing
# count or flag is read as a setting rather than unverified; --auto's
# deferral cut, so a PR with a pending required check is refused rather than
# armed; the reply refusal cut, so a bad disposition arms; and the refusal's
# issue prefix narrowed to review_replies:, so a reply check that reached no
# verdict arms; and the refusal's state test cut, so a PR whose state both
# lookups failed to read arms with its replies unread.
mutant_copy no-refusal "        'required_approval required_approving_review_count count'" '' >/dev/null
mutant_copy no-thread-refusal "        'required_thread_resolution required_review_thread_resolution flag'" '' >/dev/null
mutant_copy no-stale-refusal "        'dismiss_stale_reviews dismiss_stale_reviews_on_push flag'" '' >/dev/null
mutant_copy no-kind-check '        def fits($kind): if $kind == "count" then type == "number" and . >= 0 and . == floor else type == "boolean" end;' '        def fits($kind): true;' >/dev/null
mutant_copy no-deferral '    if [ "$can_merge" != "true" ] && [ "$auto" != true ]; then' '    if [ "$can_merge" != "true" ]; then' >/dev/null
mutant_copy no-reply-refusal '    if [ "$auto" = true ] && auto_refused "$check_result"; then' '    if false; then' >/dev/null
mutant_copy no-unread-refusal "    jq -e '.state != \"OPEN\" or any(.issues[]; startswith(\"review_replies\"))' >/dev/null <<<\"\$1\"" "    jq -e '.state != \"OPEN\" or any(.issues[]; startswith(\"review_replies:\"))' >/dev/null <<<\"\$1\"" >/dev/null
mutant_copy no-state-refusal "    jq -e '.state != \"OPEN\" or any(.issues[]; startswith(\"review_replies\"))' >/dev/null <<<\"\$1\"" "    jq -e 'any(.issues[]; startswith(\"review_replies\"))' >/dev/null <<<\"\$1\"" >/dev/null

ARMED="{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>"
NO_APPROVAL="arm: no-merge-gate=required_approval repo=owner/repo;{approval-remedy}|calls=$PRE auth=<unset>"
NO_THREADS="arm: no-merge-gate=required_thread_resolution repo=owner/repo;{thread-remedy}|calls=$PRE auth=<unset>"
NO_STALE="arm: no-merge-gate=dismiss_stale_reviews repo=owner/repo;{stale-remedy}|calls=$PRE auth=<unset>"
UNVERIFIED="arm: no-merge-gate=unverified repo=owner/repo;{unverified-remedy}|calls=$PRE auth=<unset>"
run_table "the approval gate" "\
a base requiring 1 approval, thread resolution and stale dismissal arms|checks:ci-required post-auto approvals:1/true/true|auto|75|-|$ARMED
a base requiring 2 approvals, thread resolution and stale dismissal arms|checks:ci-required post-auto approvals:2/true/true|auto|75|-|$ARMED
a base requiring 0 approvals refuses, naming the repository: nothing mutated|checks:ci-required post-auto approvals:0/true/true|auto|1|-|$NO_APPROVAL
must-fail: with the approval row cut, the base requiring 0 approvals arms|checks:ci-required post-auto approvals:0/true/true|auto-mutant:no-refusal|75|-|$ARMED
a base with no pull_request rule refuses the same way|checks:ci-required post-auto repo:no-rule|auto|1|-|$NO_APPROVAL
a classic required check is no approval: it refuses|checks:ci-required post-auto repo:classic|auto|1|-|$NO_APPROVAL
two rules each requiring 0 approvals refuse, whatever their flags|checks:ci-required post-auto approvals:0/true/true,0/false/false|auto|1|-|$NO_APPROVAL
a base requiring an approval but not thread resolution refuses: nothing mutated|checks:ci-required post-auto approvals:1/false/true|auto|1|-|$NO_THREADS
must-fail: with the thread row cut, the base requiring no thread resolution arms|checks:ci-required post-auto approvals:1/false/true|auto-mutant:no-thread-refusal|75|-|$ARMED
a base keeping approvals past a push refuses: nothing mutated|checks:ci-required post-auto approvals:1/true/false|auto|1|-|$NO_STALE
must-fail: with the stale row cut, the base keeping approvals past a push arms|checks:ci-required post-auto approvals:1/true/false|auto-mutant:no-stale-refusal|75|-|$ARMED
the approval from one rule and thread resolution from another arm together|checks:ci-required post-auto approvals:1/false/true,0/true/true|auto|75|-|$ARMED
stale dismissal from another rule than the approval arms too|checks:ci-required post-auto approvals:1/true/false,0/false/true|auto|75|-|$ARMED
a pull_request rule whose count is missing is unverified, never a gate|checks:ci-required post-auto approvals:null/true/true|auto|1|-|$UNVERIFIED
a pull_request rule whose thread flag is missing is unverified, never a gate|checks:ci-required post-auto approvals:1/null/true|auto|1|-|$UNVERIFIED
a pull_request rule whose stale flag is missing is unverified, never a gate|checks:ci-required post-auto approvals:1/true/null|auto|1|-|$UNVERIFIED
a missing value in a rule beside a complete one is still unverified|checks:ci-required post-auto approvals:1/true/true,0/true/null|auto|1|-|$UNVERIFIED
must-fail: with the kind check answering true, the missing count reads as no approval|checks:ci-required post-auto approvals:null/true/true|auto-mutant:no-kind-check|1|-|$NO_APPROVAL
must-fail: with the kind check answering true, the missing flag beside a complete rule arms|checks:ci-required post-auto approvals:1/true/true,0/true/null|auto-mutant:no-kind-check|75|-|$ARMED
a ruleset read that fails refuses before an arm|checks:ci-required post-auto rules:fail|auto|1|-|pr-merge: merge-method-unreadable cause=rules|calls=$PRE auth=<unset>
--auto arms a PR whose required check is still pending: GitHub holds it|checks:pending2 checks-exit:8 post-auto approvals:1/true/true|auto|75|-|$ARMED
must-fail: with --auto's deferral cut, the pending PR is refused and nothing arms|checks:pending2 checks-exit:8 post-auto approvals:1/true/true|auto-mutant:no-deferral|1|-|{blocked};{transient};✗ ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS);{hint-auto}|calls=$CHECK auth=<unset>
--auto defers no reply-check blocker, which no GitHub rule holds an armed PR on|checks:ci-required replies:unreasoned post-auto approvals:1/true/true|auto|1|-|{blocked};{permanent};✗ review_replies: unreasoned-decline count=1|calls=$CHECK auth=<unset>
must-fail: with --auto's reply refusal cut, the same PR arms|checks:ci-required replies:unreasoned post-auto approvals:1/true/true|auto-mutant:no-reply-refusal|75|-|$ARMED
--auto refuses a reply check that reached no verdict as well|checks:ci-required replies:fail post-auto approvals:1/true/true|auto|1|-|{blocked};{permanent};✗ review_replies_unread: check-review-replies: read-failed pr=123|calls=$CHECK auth=<unset>
must-fail: with the refusal reading review_replies: alone, the unread PR arms|checks:ci-required replies:fail post-auto approvals:1/true/true|auto-mutant:no-unread-refusal|75|-|$ARMED
--auto refuses a PR whose state both lookups failed to read: its replies went unread|checks:ci-required state-err:401 post-auto approvals:1/true/true|auto|1|-|{blocked};{permanent};✗ gh_error: gh: Bad credentials (HTTP 401)|calls=view:state,view:state auth=<unset>
must-fail: with the refusal's state test cut, the same PR arms|checks:ci-required state-err:401 post-auto approvals:1/true/true|auto-mutant:no-state-refusal|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=view:state,view:state,view:head,merge:squash:auto,graphql:queue auth=<unset>
the same pending PR on a base requiring 0 approvals refuses before any mutation|checks:pending2 checks-exit:8 post-auto approvals:0/true/true|auto|1|-|$NO_APPROVAL
the immediate merge reads no approval rule: a base requiring 0 still merges|checks:ci-required post:MERGED merge-commit:merged-oid approvals:0/true/true|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

run_table "the terminal states" "\
--auto on a merged PR exits 0 with the timestamp: no check, no mutation|state:MERGED merged-at|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
the immediate merge on a merged PR|state:MERGED merged-at|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
no mergedAt: the bare line|state:MERGED|auto|0|-|ALREADY MERGED PR #123|calls=view:state auth=<unset>
a closed PR is a distinct refusal, exit 1|state:CLOSED|auto|1|-|{closed}|calls=view:state auth=<unset>
a failed state lookup blocks the merge with its real cause|state-err:401|immediate|1|-|{blocked};{permanent};✗ gh_error: gh: Bad credentials (HTTP 401)|calls=view:state,view:state auth=<unset>
a state resolved only on the retry still short-circuits --auto, the lookup retried not cached|state:MERGED merged-at state-err:once|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
a closed PR found on the retry keeps its line|state:CLOSED state-err:once|auto|1|-|{closed}|calls=view:state,view:state auth=<unset>
the immediate mode on a retry-resolved state|state:MERGED merged-at state-err:once|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
an open PR still merges, its state read once|checks:ci-required post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
GH_TOKEN alone is named with the installation it acts as, and no current-user warning|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghs_INSTALL|immediate|0|-|Using GH_TOKEN as GitHub App installation;MERGED PR #123|calls=$PRE,user,merge:squash,graphql:queue auth=ghs_INSTALL
a token whose user lookup fails any other way is named unverified, and the merge still runs|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghp_REVOKED|immediate|0|-|Using GH_TOKEN as unverified;MERGED PR #123|calls=$PRE,user,merge:squash,graphql:queue auth=ghp_REVOKED
"

# On a base whose rules hold no merge_queue rule, the default world, no route
# is read and no mode passes --admin: GitHub enrolls the PR, so the only
# merge these rows can cause is the queue's own. The must-fail inverse is an
# unconditional --admin on the command: each row's trace then names
# merge:squash:admin and reds. The retired merge settings are read by no mode: a set
# key changes nothing.
run_table "the merge queue and the retired settings" "\
on a queue base --auto enrolls the PR and passes no --admin|checks:ci-required post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a partial post-merge answer is no outcome: the pr-view fallback decides|checks:ci-required post-graphql:partial post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue,view:post auth=<unset>
the admin-credential verb is gone: an unknown option, refused before any call|-|admin-credential|1|-|Error: Unknown option: --admin-credential|calls=- auth=-
the admin request is gone: an unknown option, refused before any call|-|admin|1|-|Error: Unknown option: --admin|calls=- auth=-
the router passes --admin to the same refusal|-|router:--admin|1|-|Error: Unknown option: --admin|calls=- auth=-
the force override is gone: an unknown option, refused before any call|-|force|1|-|Error: Unknown option: --force|calls=- auth=-
the router passes --force to the same refusal|-|router:--force|1|-|Error: Unknown option: --force|calls=- auth=-
a set ORCH_MERGE_BYPASS no longer refuses: the immediate merge runs|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_MERGE_BYPASS=fast-path|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
a set ORCH_ADMIN_MERGE_GH_CONFIG_DIR no longer refuses --check|checks:ci-required env:ORCH_ADMIN_MERGE_GH_CONFIG_DIR=/home/dev/.config/gh-admin|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a key in kendex.settings.toml [env] no longer refuses the direct call|checks:ci-required post-queue cwd:toml|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a key in kendex.settings.toml [env] no longer refuses through the router|checks:ci-required post-queue|router-in:toml|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
"

# The merge route reads the queue-only class off harness-ci's change-class
# beside the scripts tree pr-merge runs from. So the route rows run pr-merge.sh out of a
# mirror of the scripts tree: real directories holding a symlink per file,
# with the mirror's own harness-ci sibling written as the stub. Production
# resolution is untouched: a run from the real tree still reaches the shipped
# classifier.
mirror_tree() { # DEST SKILL
  local dest="$1" skill="$2" f d
  while IFS= read -r f; do
    d=""
    d=$(dirname -- "$f") || exit 2
    mkdir -p "$dest/skills/$skill/scripts/$d"
    ln -s "$REPO_ROOT/skills/$skill/scripts/$f" "$dest/skills/$skill/scripts/$f"
  done < <(cd "$REPO_ROOT/skills/$skill/scripts" && find . -type f | sed 's|^\./||')
}
MIRROR="$TMPDIR/tree"
mirror_tree "$MIRROR" github
MIRROR_PR_MERGE="$MIRROR/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$MIRROR_PR_MERGE" ]] || { echo "mirror is missing pr-merge.sh" >&2; exit 2; }
mkdir -p "$MIRROR/skills/harness-ci/scripts"
cat >"$MIRROR/skills/harness-ci/scripts/change-class" <<'EOF'
#!/usr/bin/env bash
# The shipped classifier's contract. A measured class needs
# --event pull_request, so a call without it is the wiring error the real
# classifier exits 2 on; stdout is one change_class=<class> line and nothing
# else. The caller must also pass --base and --head with the pull request's
# base and head, and --repo with the checkout it runs in: a call missing a
# flag or carrying the wrong value fails instead of answering, so dropping one
# from the caller is caught. With no STUB_CLASS it answers nothing at all.
[[ -n "${STUB_CLASS:-}" ]] || exit 1
event="" base="" head="" repo="" prev=""
for a in "$@"; do
  case "$prev" in
    --event) event="$a" ;; --base) base="$a" ;; --head) head="$a" ;; --repo) repo="$a" ;;
  esac
  prev="$a"
done
[[ "$event" == pull_request ]] || { echo "change-class: cause=missing-event option=--event" >&2; exit 2; }
[[ "$base" == "${STUB_EXPECT_BASE:-base-oid}" ]] || { echo "change-class: bad --base '$base'" >&2; exit 3; }
[[ "$head" == "${STUB_EXPECT_HEAD:?STUB_EXPECT_HEAD unset}" ]] || { echo "change-class: bad --head '$head'" >&2; exit 3; }
[[ "$repo" == "." ]] || { echo "change-class: bad --repo '$repo'" >&2; exit 3; }
# The queue-only line, where the row names one, then the class line.
[[ -z "${STUB_QUEUE_LINE:-}" ]] || printf 'queue-only: %s\n' "$STUB_QUEUE_LINE" >&2
printf 'class: class=%s measured=true cause=stub\n' "$STUB_CLASS" >&2
printf 'change_class=%s\n' "$STUB_CLASS"
EOF
chmod +x "$MIRROR/skills/harness-ci/scripts/change-class"

# A github skill installed without harness-ci, run on this PATH less every
# directory holding a change-class, with the world's stub bin ahead of it:
# no classifier is found beside the scripts tree or on PATH.
CLASSLESS="$TMPDIR/classless-tree"
mirror_tree "$CLASSLESS" github
CLASSLESS_PR_MERGE="$CLASSLESS/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$CLASSLESS_PR_MERGE" && ! -e "$CLASSLESS/skills/harness-ci" ]] || { echo "the classless mirror is malformed" >&2; exit 2; }
CLASSLESS_PATH="$TMPDIR/bin"
IFS=: read -r -a path_dirs <<<"$PATH"
for path_dir in "${path_dirs[@]}"; do
  [[ -x "$path_dir/change-class" ]] || CLASSLESS_PATH+=":$path_dir"
done

# The immediate merge reads the route under the merge's token: every queue
# ruleset holding the queue rule alone and answering a bypass, every other
# ruleset answering never, no classic protection, an accepted method a direct
# merge allows, and a PR that is not queue-only take --admin, with that
# method. The control for each admin row is the no-bypass row beside it, whose trace names the queue's --auto merge; a failed read, the queue-only
# class and a class nothing could read keep the queue too. Every --auto
# attempt reads the route and refuses admin unless the queue is explicit. Every queue route passes --auto, since the gh
# stub refuses a merge on a queue base that passes neither --auto nor --admin,
# as GitHub does.
#
# Each rule that keeps --admin to the queue alone has its must-fail control, a
# copy of the scripts tree with that rule's line cut and the classifier stub
# beside it: every merge-queue ruleset judged, not the first; a queue ruleset
# holding another rule; another ruleset the token may bypass; classic
# protection; the classified head being the pinned head; the arm at
# creation's route read; and the direct method, both the read that leaves the
# queue's method out and the admin merge taking its answer; and the queue
# route's --auto, whose cut leaves the merge GitHub refuses. --queue
# without --auto is refused, and its control cuts that refusal.
route_mutant() { # NAME FROM TO
  mutant_copy "$@" >/dev/null || exit 2
  mkdir -p "$TMPDIR/$1/skills/harness-ci/scripts"
  cp -- "$MIRROR/skills/harness-ci/scripts/change-class" "$TMPDIR/$1/skills/harness-ci/scripts/change-class"
}
route_mutant route-every '            bypasses="${bypasses:+$bypasses,}$bypass"' '            bypasses="${bypasses:+$bypasses,}$bypass"; break'
route_mutant route-mixed '    if [ -n "$mixed" ]; then' '    if false; then'
route_mutant route-other '        elif [ "$bypass" != never ]; then' '        elif false; then'
route_mutant route-classic '    false) ;;' '    false | true) ;;'
mutant_copy route-autoless '    if [ "$queue" = true ] && [ "$auto" != true ]; then' '    if [ "$queue" = true ] && [ "$auto" != true ] && false; then' >/dev/null
route_mutant route-head '        if [ "$head_sha" != "$pinned" ]; then' '        if false; then'
route_mutant route-direct-read "    kinds='\"pull_request\"'" "    kinds='\"merge_queue\", \"pull_request\"'" lib/repo-settings.sh
route_mutant route-direct-take '        method="$MERGE_ROUTE_METHOD"' '        method=$(merge_method "$pr_num" "$token" "${accepted[@]}") || exit 1'
route_mutant route-queue-auto '    [ "$auto" != true ] && [ "$route" != queue ] || cmd+=(--auto)' '    [ "$auto" != true ] || cmd+=(--auto)'
route_mutant route-occupied '    if [[ "$queue_count" =~ [1-9] ]]; then' '    if false; then'
route_mutant route-unreadable '    if ! [[ "$queue_count" =~ ^[0-9]+$ ]]; then' '    if false; then'
ROUTE_PRE="$PRE,graphql:entries,view:range"
QUEUED="QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}"
run_table "the merge route past the queue" "\
a token that may always bypass the queue ruleset admin-merges a PR that is not queue-only|checks:ci-required queue-rule:always route:false post:MERGED merge-commit:merged-oid|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
a pull-request-mode bypass admin-merges too|checks:ci-required queue-rule:pull_requests_only route:false post:MERGED merge-commit:merged-oid|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=pull_requests_only;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
an occupied base queue skips the classifier and joins behind its entries|checks:ci-required queue-rule:always queue-entries:1 route:false post-queue|immediate-classified|75|-|merge-route: queue cause=queue-occupied;{route-queue:occupied};{no-token};$QUEUED|calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>
an empty base queue still admin-merges|checks:ci-required queue-rule:always queue-entries:0 route:false post:MERGED merge-commit:merged-oid|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
a failed base queue read skips the classifier and takes the queue|checks:ci-required queue-rule:always queue-entries:fail route:false post-queue|immediate-classified|75|-|merge-route: queue cause=queue-unreadable;{route-queue:queue-unreadable};{no-token};$QUEUED|calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>
a missing base queue count takes the queue|checks:ci-required queue-rule:always queue-entries:null route:false post-queue|immediate-classified|75|-|merge-route: queue cause=queue-unreadable;{route-queue:queue-unreadable};{no-token};$QUEUED|calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>
a nonwhole base queue count takes the queue|checks:ci-required queue-rule:always queue-entries:0.5 route:false post-queue|immediate-classified|75|-|merge-route: queue cause=queue-unreadable;{route-queue:queue-unreadable};{no-token};$QUEUED|calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>
a token that may never bypass takes the queue, naming the ruleset and its answer|checks:ci-required queue-rule:never route:false post-queue|immediate-classified|75|-|merge-route: queue cause=no-bypass ruleset=20569265 bypass=never;{route-queue:no-bypass};{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a ruleset answer with no bypass field takes the queue|checks:ci-required queue-rule:absent route:false post-queue|immediate-classified|75|-|merge-route: queue cause=no-bypass ruleset=20569265 bypass=absent;{route-queue:no-bypass};{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a failed ruleset read takes the queue and names the ruleset|checks:ci-required queue-rule:fail route:false post-queue|immediate-classified|75|-|merge-route: queue cause=ruleset-unreadable ruleset=20569265;{route-queue:ruleset};{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
the bypass is read under the merge's own token|checks:ci-required queue-rule:always route:false post:MERGED merge-commit:merged-oid require-token env:GH_BOT_TOKEN=ghp_test_token|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;Using GH_BOT_TOKEN as stub-user;MERGED PR #123|calls=$ROUTE_PRE,user,merge:squash:admin,graphql:queue auth=<unset>+ghp_test_token
a queue-only PR takes the queue whatever the token may bypass, naming the path that made it|checks:ci-required queue-rule:always route:true post-queue|immediate-classified|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};$QUEUE_TRUE;{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
a classifier that prints no queue-only line reads queue-only, its stderr replayed|checks:ci-required queue-rule:always route:- post-queue|immediate-classified|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};cause=classifier-unreadable;class: class=standard measured=true cause=stub;{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
a classifier that fails reads queue-only|checks:ci-required queue-rule:always route:fail post-queue|immediate-classified|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};cause=classifier-exit-1;{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
an unreadable pull request range reads queue-only, gh's words replayed|checks:ci-required queue-rule:always route:range-fail post-queue|immediate-classified|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};cause=range-unreadable;could not read the pull request endpoints;{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
no classifier beside the scripts tree or on PATH reads queue-only|checks:ci-required queue-rule:always post-queue|immediate-classless|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};cause=classifier-absent;{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>
two merge-queue rulesets the token may bypass admin-merge, both named|checks:ci-required queue-two:always,pull_requests_only route:false post:MERGED merge-commit:merged-oid|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265,20569266 bypass=always,pull_requests_only;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
a second merge-queue ruleset the token may not bypass takes the queue, naming it|checks:ci-required queue-two:always,never route:false post-queue|immediate-classified|75|-|merge-route: queue cause=no-bypass ruleset=20569266 bypass=never;{route-queue:no-bypass};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with only the first merge-queue ruleset judged, the second's never admin-merges|checks:ci-required queue-two:always,never route:false post:MERGED merge-commit:merged-oid|route-mutant:route-every|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
a merge-queue ruleset holding another rule takes the queue, naming the rule|checks:ci-required queue-rule:always queue-mixed route:false post-queue|immediate-classified|75|-|merge-route: queue cause=queue-ruleset-mixed ruleset=20569265 rule=pull_request;{route-queue:mixed};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with the mixed-ruleset check cut, the queue ruleset's other rule is admin-merged past|checks:ci-required queue-rule:always queue-mixed route:false post:MERGED merge-commit:merged-oid|route-mutant:route-mixed|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
another ruleset the token may bypass takes the queue, naming it and its answer|checks:ci-required queue-rule:always other-bypass:pull_requests_only route:false post-queue|immediate-classified|75|-|merge-route: queue cause=other-bypass ruleset=24148610 bypass=pull_requests_only;{route-queue:other-bypass};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
another ruleset answering no bypass field takes the queue|checks:ci-required queue-rule:always other-bypass:absent route:false post-queue|immediate-classified|75|-|merge-route: queue cause=other-bypass ruleset=24148610 bypass=absent;{route-queue:other-bypass};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with the other-ruleset check cut, a ruleset the token may bypass is admin-merged past|checks:ci-required queue-rule:always other-bypass:pull_requests_only route:false post:MERGED merge-commit:merged-oid|route-mutant:route-other|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
classic branch protection takes the queue|checks:ci-required queue-rule:always protection:on route:false post-queue|immediate-classified|75|-|merge-route: queue cause=classic-protection;{route-queue:classic};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a protection answer with no enabled field takes the queue|checks:ci-required queue-rule:always protection:unknown route:false post-queue|immediate-classified|75|-|merge-route: queue cause=protection-unreadable;{route-queue:protection};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with the classic check cut, classic protection is admin-merged past|checks:ci-required queue-rule:always protection:on route:false post:MERGED merge-commit:merged-oid|route-mutant:route-classic|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
a head that moved between the head read and the class read takes the queue, naming both|checks:ci-required queue-rule:always route:false head-moved:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb post-queue|immediate-classified|75|-|merge-route: queue cause=queue-only;{route-queue:queue-only};cause=head-moved classified=$RANGE_HEAD pinned=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;{no-token};$QUEUED|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with the head comparison cut, a head nobody classified is admin-merged|checks:ci-required queue-rule:always route:false head-moved:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb post:MERGED merge-commit:merged-oid|route-mutant:route-head|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
the arm at creation on an unapproved PR arms nothing where the route reads admin, the route its first stderr line|checks:none queue-rule:always route:false post-entry review:none|auto-classified|1|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{arm-admin}|calls=$ROUTE_PRE auth=<unset>
the arm at creation arms where the route reads queue|checks:none queue-rule:never route:false post-entry|auto-classified|75|-|merge-route: queue cause=no-bypass ruleset=20569265 bypass=never;{route-queue:no-bypass};Warnings:;⚠ ci_unconfigured: No status checks configured;{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
the arm at creation arms where the base holds no merge queue, naming no route|checks:ci-required post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
the arm at creation arms where the queue ruleset cannot be read, naming the read|checks:ci-required queue-rule:fail route:false post-entry|auto-classified|75|-|merge-route: queue cause=ruleset-unreadable ruleset=20569265;{route-queue:ruleset};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
the admin route merges with a method a direct merge allows, not the queue's|checks:ci-required queue-rule:always queue-rule-method:MERGE methods:squash route:false post:MERGED merge-commit:merged-oid|immediate-classified|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:squash:admin,graphql:queue auth=<unset>
must-fail: with the direct read taking the queue's method, the admin merge passes a method the repository does not allow|checks:ci-required queue-rule:always queue-rule-method:MERGE methods:squash route:false post:MERGED merge-commit:merged-oid|route-mutant:route-direct-read|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:merge:admin,graphql:queue auth=<unset>
must-fail: with the direct method not taken, the admin merge passes the queue's method|checks:ci-required queue-rule:always queue-rule-method:MERGE methods:squash route:false post:MERGED merge-commit:merged-oid|route-mutant:route-direct-take|0|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{no-token};MERGED PR #123|calls=$ROUTE_PRE,merge:merge:admin,graphql:queue auth=<unset>
a direct merge allowing none of the accepted methods takes the queue with the queue's method, naming both sets|checks:ci-required queue-rule:always queue-rule-method:MERGE methods:squash route:false post-queue|classified-with:--merge|75|-|merge-route: queue cause=direct-method allowed=squash accepted=merge;{route-queue:direct-method};{no-token};$QUEUED|calls=$PRE,merge:merge:auto,graphql:queue auth=<unset>
direct-merge methods that cannot be read take the queue, naming the read|checks:ci-required queue-rule:always repo:pushless route:false post-queue|immediate-classified|75|-|merge-route: queue cause=direct-method-unreadable read=settings;{route-queue:direct-unread};{no-token};$QUEUED|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
--auto refuses an admin route without arming or merging|checks:ci-required queue-rule:always route:false post-entry|auto-classified|1|-|merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{arm-admin}|calls=$ROUTE_PRE auth=<unset>
--auto --queue explicitly queues an admin-eligible PR, never passing --admin|checks:ci-required queue-rule:always route:false post-entry|classified-with:--auto+--queue|75|-|merge-route: queue cause=explicit-queue ruleset=20569265 bypass=always;{route-queue:explicit};$QUEUE_FALSE;{no-token};$QUEUED|calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>
must-fail: with the queue route's --auto cut, GitHub refuses the merge and nothing is queued|checks:ci-required queue-rule:never route:false post-queue|route-mutant:route-queue-auto|1|-|merge-route: queue cause=no-bypass ruleset=20569265 bypass=never;{route-queue:no-bypass};{no-token};BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;! The merge strategy for main is set by the merge queue|calls=$PRE,merge:squash,graphql:queue auth=<unset>
--queue without --auto is refused before any call|-|with:--queue|1|-|Error: --queue gates the --auto arm and needs --auto|calls=- auth=-
must-fail: with the needs-auto check cut, --queue alone runs the immediate merge|checks:ci-required post:MERGED merge-commit:merged-oid|mutant:route-autoless:--queue+--keep-branch|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

build checks:ci-required queue-rule:always queue-entries:1 route:false post-queue
queued="rc=75 out=- err=$(err_text "merge-route: queue cause=queue-occupied;{route-queue:occupied};{no-token};$QUEUED") calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>"
assert_mutant_fails "$(run route-mutant:route-occupied)" "$queued" 'an occupied base queue skips the classifier and joins behind its entries'
build checks:ci-required queue-rule:always queue-entries:fail route:false post-queue
queued="rc=75 out=- err=$(err_text "merge-route: queue cause=queue-unreadable;{route-queue:queue-unreadable};{no-token};$QUEUED") calls=$PRE,graphql:entries,merge:squash:auto,graphql:queue auth=<unset>"
assert_mutant_fails "$(run route-mutant:route-unreadable)" "$queued" 'a failed base queue read skips the classifier and takes the queue'

# Keep the refusal's matched condition and text, but remove its effect.
route_mutant route-refusal '    if [ "$auto" = true ] && [ "$route" = admin ]; then' '    if [ "$auto" = true ] && [ "$route" = admin ] && false; then'
build checks:ci-required queue-rule:always route:false post-entry
refusal="rc=1 out=- err=$(err_text "merge-route: admin cause=queue-bypass-safe ruleset=20569265 bypass=always;$QUEUE_FALSE;{arm-admin}") calls=$ROUTE_PRE auth=<unset>"
assert_mutant_fails "$(run auto-route-mutant:route-refusal)" "$refusal" '--auto refuses an admin route without arming or merging'
route_mutant route-explicit '    if [ "$queue" = true ]; then' '    if [ "$queue" = true ] && false; then'
build checks:ci-required queue-rule:always route:false post-entry
queued="rc=75 out=- err=$(err_text "merge-route: queue cause=explicit-queue ruleset=20569265 bypass=always;{route-queue:explicit};$QUEUE_FALSE;{no-token};$QUEUED") calls=$ROUTE_PRE,merge:squash:auto,graphql:queue auth=<unset>"
assert_mutant_fails "$(run mutant:route-explicit:--auto+--queue)" "$queued" '--auto --queue explicitly queues an admin-eligible PR'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
