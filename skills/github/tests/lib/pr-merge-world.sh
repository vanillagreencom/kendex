#!/usr/bin/env bash
# The world pr-merge.test.sh runs in, sourced after `set -euo pipefail`. It
# sources lib/check-stub.sh for the gh stub, as ci-classify-refusal.test.sh
# does. Sourced, never run, so it lives one level below the suite glob.
#
# A row is `label|world|argv|rc|out|err|calls`:
#   world  words for the stub, later words overriding earlier ones:
#     checks:<name>  a checks fixture; checks-exit:<n> gh's exit for it
#     state:<MERGED|CLOSED>, merged-at, pr:missing
#     state-err:<401|ratelimit|graphql-notfound|silent4|once>
#     head:<sha>, post:<MERGED|OPEN>, post-head:<sha>, post-auto, post-queue
#     (in the queue with an entry), post-entry (an entry only), post-state:<s>
#     merge-commit:<oid>, merge-fail:<already-queued|policy|transport|queue-required>
#     graphql:fail (the queue query fails, the REST fallback answers),
#     post-view-fail (that REST fallback fails too)
#     replies:<unreasoned|two|fail> the review threads check-review-replies
#     reads: one thread whose author declined with a label alone, that
#     thread beside one whose author claims tracking and names no issue, or
#     a read that fails
#     review:<decision|none> GitHub's reviewDecision, none being empty, with
#     no latest review; review-latest:<state> one latest review in that state
#     require-token (the stub refuses a mutation without the bot token)
#     repo:no-auto (allow_auto_merge=false), repo:no-rule (no ruleset rule),
#     repo:classic (no ruleset, one classic required context)
#     approvals:<n>/<t>/<d>[,<n>/<t>/<d>...] the ruleset pull_request rules
#     alone, one per entry, each requiring n approvals, thread resolution t
#     and stale-approval dismissal d (true|false); null leaves that
#     parameter out
#     required:<context> a ruleset requiring that one context, `+` a space;
#     classic:<context> no ruleset, classic protection naming it under
#     checks[]; classic-contexts:<context> the same under the legacy
#     contexts array;
#     rule-type:<type> a ruleset rule of that type beside one requiring Lint
#     rules:fail, branch:fail the ruleset or the branch-protection read errors
#     repo:no-protection a branch answer carrying no protection object
#     methods:<m+m|-> the repository's allowed merge methods, `+` a space,
#     `-` none; repo:pushless the repository answer with no allow_* flags
#     and no delete_branch_on_merge, as for a token without push access;
#     deletes-on-merge:<true|false|null> its delete_branch_on_merge;
#     cross-repository the PR's head is a fork's;
#     queue:<METHOD> a merge_queue rule with that merge_method on main, or on
#     the branch queue-on:<branch> names; rule-methods:<m+m> a pull_request
#     rule allowing those methods
#     base:<branch> the PR's base; gate reads answer only its encoded path
#     post-graphql:partial  the post-merge read answers HTTP 200 with an
#     errors array beside data
#     route:<true|false|-|fail|range-fail>  the classifier stub's queue-only
#     line for the pull request's range: queue_only=true on a CI workflow,
#     queue_only=false, no line, a classifier that fails, or a range read
#     that fails; head-moved:<sha> after it, the head every read but the
#     range's answers
#     queue-rule:<value|absent|fail>  a merge_queue rule on the base
#     from ruleset 20569265, beside a required check from ruleset 24148610
#     that answers never, whose read answers current_user_can_bypass
#     <value>, carries no such field, or fails; after it, queue-mixed puts a
#     pull_request rule in the queue ruleset, other-bypass:<value> is the
#     checks ruleset's answer, and
#     protection:on turns classic branch protection on, protection:unknown
#     answers a protection object with no enabled field
#     queue-two:<a>,<b>  two merge_queue rulesets, 20569265 answering <a> and
#     20569266 answering <b>, beside the checks ruleset answering never
#     queue-rule-method:<METHOD> after a queue-rule word, the queue's
#     merge_method in place of SQUASH
#     queue-entries:<count|fail> the base queue's entry count or a failed read
#     env:NAME=value  the caller's environment
#   argv   check | auto | immediate | with:<flag+flag> (the flags alone,
#          `+` a space, no --keep-branch) | mutant:<name>:<flag+flag> (the
#          same, run from the mutant_copy named <name>) |
#          expected:<sha> (--auto with --expected-head) | router:<flags> |
#          auto-mutant:<name> (--auto, run from the copy pr-merge.test.sh
#          builds under that name with one line of pr-merge.sh replaced) |
#          force | admin | admin-credential (the retired flags) |
#          auto-classified | immediate-classified |
#          classified-with:<flag+flag> (the immediate merge with those flags,
#          `+` a space) (run from the mirror tree
#          whose harness-ci sibling is the classifier stub, which
#          pr-merge.test.sh builds as $MIRROR) | immediate-classless (the
#          immediate merge from that suite's mirror with no harness-ci
#          sibling, $CLASSLESS_PR_MERGE, on $CLASSLESS_PATH, which holds no
#          change-class) | route-mutant:<name> | auto-route-mutant:<name> (the
#          immediate merge, or the arm at creation, from the copy mutant_copy
#          built as <name>, with the classifier stub beside it)
#   out    check: `merge=<bool> transient=<bool> state=<S> mergeable=<M>
#          at=<mergedAt|-> runs=<ids|-> issues=[a;b] warnings=[c]
#          keys=[<the JSON's keys>]`; otherwise stdout, `-` when empty
#   err    stderr's lines joined by `;`, leading spaces dropped, blank lines
#          dropped, `{word}` macros expanded (see err_macro)
#   calls  `calls=<each gh call by kind, in order> auth=<the GH_TOKEN each
#          call saw, distinct values in order>`

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"
GITHUB="$REPO_ROOT/skills/github/scripts/github.sh"

# shellcheck source=lib/check-stub.sh
source "$TEST_DIR/lib/check-stub.sh"
# shellcheck source=lib/mutant-copy.sh
source "$TEST_DIR/lib/mutant-copy.sh"
# A child that resolves symlinks prints the sandbox's physical path, under
# /private on macOS, so err_lines maps that spelling to <tmp> as well.
TMPDIR_PHYSICAL="$(cd "$TMPDIR" && pwd -P)"
REPO="$TMPDIR/repo"

# The merge route asks a classifier to read the diff between two commits, and
# pr-merge reads a range this checkout does not hold as queue-only. So the
# fixture repo is a real repository with two commits, and the route rows name
# them. No remote is added: the slug resolution and the volatile note below
# still read what they read for a checkout that names no GitHub repository
# locally.
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.email tests@example.invalid
git -C "$REPO" config user.name "pr-merge tests"
printf 'base\n' >"$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -q -m base
printf 'head\n' >"$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -q -m head
RANGE_BASE="$(git -C "$REPO" rev-parse HEAD~1)"
RANGE_HEAD="$(git -C "$REPO" rev-parse HEAD)"

# A checkout whose settings still carry a retired merge key, which no mode
# reads any more.
settings_fixture() { # NAME RELPATH CONTENT
  local dir="$TMPDIR/settings-$1"
  git init -q "$dir"
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  mkdir -p "$(dirname "$dir/$2")"
  printf '%s\n' "$3" >"$dir/$2"
}
settings_fixture toml kendex.settings.toml $'[env]\nORCH_MERGE_BYPASS = "fast-path"'


# --- the checks fixtures -------------------------------------------------------
RUN_OLD=https://github.com/owner/repo/actions/runs/29098545030/job
RUN_NEW=https://github.com/owner/repo/actions/runs/29099680623/job
checks_of() {
  case "$1" in
    pending2) printf '[{"name":"Linux Integration","state":"IN_PROGRESS","bucket":"pending"},{"name":"Cross-Platform","state":"PENDING","bucket":"pending"}]' ;;
    failed) printf '[{"name":"Unit Tests","state":"SUCCESS","bucket":"pass"},{"name":"Lint","state":"FAILURE","bucket":"fail"}]' ;;
    mixed) printf '[{"name":"Unit Tests","state":"IN_PROGRESS","bucket":"pending"},{"name":"Lint","state":"FAILURE","bucket":"fail"}]' ;;
    pass-skip) printf '[{"name":"Unit Tests","state":"SUCCESS","bucket":"pass"},{"name":"Optional Job","state":"SKIPPED","bucket":"skipping"}]' ;;
    ci-required) printf '[{"name":"CI Required","state":"SUCCESS","bucket":"pass"}]' ;;
    # a green context beside a red one, and beside one still running
    optional-red) printf '[{"name":"Lint","state":"SUCCESS","bucket":"pass"},{"name":"CodeQL","state":"FAILURE","bucket":"fail"}]' ;;
    # the same red check with no entry for the required context at all
    unregistered) printf '[{"name":"CodeQL","state":"FAILURE","bucket":"fail"}]' ;;
    optional-pending) printf '[{"name":"Lint","state":"SUCCESS","bucket":"pass"},{"name":"CodeQL","state":"IN_PROGRESS","bucket":"pending"}]' ;;
    # an old run's cancelled jobs beside the current run's pending one
    superseded-pending) printf '[{"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"%s/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},{"name":"Linux Integration","state":"CANCELLED","bucket":"cancel","link":"%s/102","workflow":"CI","startedAt":"2026-07-10T10:00:01Z"},{"name":"macOS","state":"CANCELLED","bucket":"cancel","link":"%s/103","workflow":"CI","startedAt":"2026-07-10T10:00:02Z"},{"name":"Changes","state":"IN_PROGRESS","bucket":"pending","link":"%s/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"License Key Guard","state":"SUCCESS","bucket":"pass","link":"%s/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}]' "$RUN_OLD" "$RUN_OLD" "$RUN_OLD" "$RUN_NEW" "$RUN_NEW" ;;
    # the old run cancelled a job the current run never re-created
    superseded-abandoned) printf '[{"name":"macOS","state":"CANCELLED","bucket":"cancel","link":"%s/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"Changes","state":"SUCCESS","bucket":"pass","link":"%s/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}]' "$RUN_OLD" "$RUN_NEW" "$RUN_NEW" ;;
    # the current run re-created and passed the job the old run left cancelled
    superseded-replaced) printf '[{"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"%s/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"Changes","state":"SUCCESS","bucket":"pass","link":"%s/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}]' "$RUN_OLD" "$RUN_NEW" "$RUN_NEW" ;;
    # the current run's own cancellation, no newer run
    current-cancel) printf '[{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"Integration","state":"CANCELLED","bucket":"cancel","link":"%s/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}]' "$RUN_NEW" "$RUN_NEW" ;;
    clean-run) printf '[{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"Changes","state":"SUCCESS","bucket":"pass","link":"%s/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}]' "$RUN_NEW" "$RUN_NEW" ;;
    # a commit status with no workflow, linking to a run
    status-only) printf '[{"name":"CI Required","state":"PENDING","bucket":"pending","link":"https://github.com/owner/repo/actions/runs/29099700000","workflow":""}]' ;;
    none) printf '[]' ;;
    *) echo "UNKNOWN-CHECKS: $1" >&2; exit 2 ;;
  esac
}

merge_stderr_of() {
  case "$1" in
    already-queued) printf 'failed to run merge: GraphQL: Pull request Pull request is already queued to merge (enablePullRequestAutoMerge)' ;;
    policy) printf 'failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge' ;;
    transport) printf 'failed to read the completed mutation response' ;;
    queue-required) printf 'failed to run merge: merge queue is required' ;;
    *) echo "UNKNOWN-MERGE-FAIL: $1" >&2; exit 2 ;;
  esac
}

# --- the world ------------------------------------------------------------------
W_ENV=()
RUN_DIR=""
CALL_LOG="$TMPDIR/calls.log"
AUTH_LOG="$TMPDIR/auth.log"
FAIL_ONCE="$TMPDIR/state-failed-once"
MERGE_REFUSED="$TMPDIR/merge-refused"
word() {
  local v="${1#*:}"
  case "$1" in
    checks:*) W_ENV+=("STUB_CHECKS=$(checks_of "$v")") ;;
    checks-exit:*) W_ENV+=("STUB_CHECKS_EXIT=$v") ;;
    state:*) W_ENV+=("STUB_STATE=$v") ;;
    merged-at) W_ENV+=("STUB_MERGED_AT=2026-08-15T09:41:12Z") ;;
    pr:missing) W_ENV+=("STUB_PR_MISSING=true") ;;
    state-err:401) W_ENV+=("STUB_STATE_STDERR=gh: Bad credentials (HTTP 401)") ;;
    state-err:ratelimit) W_ENV+=("STUB_STATE_STDERR=API rate limit exceeded for user ID 1.") ;;
    state-err:graphql-notfound) W_ENV+=("STUB_STATE_STDERR=GraphQL: Could not resolve to a PullRequest with the number of 123. (repository.pullRequest)") ;;
    state-err:silent4) W_ENV+=("STUB_STATE_SILENT_FAIL=true" "STUB_STATE_EXIT=4") ;;
    state-err:once) W_ENV+=("STUB_STATE_FAIL_ONCE=$FAIL_ONCE") ;;
    head:*) W_ENV+=("STUB_HEAD=$v") ;;
    post:*) W_ENV+=("STUB_POST_STATE=$v") ;;
    post-head:*) W_ENV+=("STUB_POST_HEAD=$v") ;;
    post-auto) W_ENV+=('STUB_POST_AUTO_JSON={"enabledAt":"2026-07-15T00:00:00Z"}') ;;
    post-queue) W_ENV+=("STUB_POST_IN_QUEUE=true" 'STUB_POST_QUEUE_ENTRY_JSON={"state":"QUEUED"}' "STUB_POST_QUEUE_STATE=QUEUED") ;;
    post-entry) W_ENV+=('STUB_POST_QUEUE_ENTRY_JSON={"state":"QUEUED"}' "STUB_POST_QUEUE_STATE=QUEUED") ;;
    merge-commit:*) W_ENV+=("STUB_MERGE_COMMIT=$v") ;;
    merge-fail:*) W_ENV+=("STUB_MERGE_EXIT=1" "STUB_MERGE_STDERR=$(merge_stderr_of "$v")") ;;
    graphql:fail) W_ENV+=("STUB_POST_GRAPHQL_FAIL=true") ;;
    post-view-fail) W_ENV+=("STUB_POST_VIEW_FAIL=true") ;;
    replies:unreasoned) W_ENV+=('STUB_THREADS=[{"comments":{"totalCount":1,"nodes":[{"author":{"login":"pr-author","__typename":"User","databaseId":1001},"body":"Declined: frozen"}]}}]') ;;
    replies:two) W_ENV+=('STUB_THREADS=[{"comments":{"totalCount":1,"nodes":[{"author":{"login":"pr-author","__typename":"User","databaseId":1001},"body":"Out of scope, tracked."}]}},{"comments":{"totalCount":1,"nodes":[{"author":{"login":"pr-author","__typename":"User","databaseId":1001},"body":"Declined: frozen"}]}}]') ;;
    replies:fail) W_ENV+=("STUB_THREADS_FAIL=true") ;;
    review:none) W_ENV+=("STUB_REVIEW_DECISION=" "STUB_REVIEW_LATEST=[]") ;;
    review:*) W_ENV+=("STUB_REVIEW_DECISION=$v" "STUB_REVIEW_LATEST=[]") ;;
    review-latest:*) W_ENV+=("STUB_REVIEW_LATEST=[{\"state\":\"$v\"}]") ;;
    require-token) W_ENV+=("STUB_REQUIRE_TOKEN=true") ;;
    repo:no-auto) W_ENV+=("STUB_ALLOW_AUTO_MERGE=false") ;;
    repo:no-rule) W_ENV+=("STUB_GATE_RULES=[]") ;;
    approvals:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg s "$v" '$s | split(",") | map(split("/") as [$n, $t, $d] | {type: "pull_request", parameters: ((if $n == "null" then {} else {required_approving_review_count: ($n | tonumber)} end) + (if $t == "null" then {} else {required_review_thread_resolution: ($t | fromjson)} end) + (if $d == "null" then {} else {dismiss_stale_reviews_on_push: ($d | fromjson)} end))})' <<<null)") || exit 2 ;;
    repo:classic) W_ENV+=("STUB_GATE_RULES=[]" 'STUB_CLASSIC_JSON={"protection":{"required_status_checks":{"contexts":["CI Required"],"checks":[]}}}') ;;
    required:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg c "$(printf '%s' "$v" | tr '+' ' ')" '[{type: "required_status_checks", parameters: {required_status_checks: [{context: $c}]}}]' <<<null)") ;;
    classic:*) W_ENV+=("STUB_GATE_RULES=[]" "STUB_CLASSIC_JSON=$(jq -c --arg c "$v" '{protection: {required_status_checks: {contexts: [], checks: [{context: $c}]}}}' <<<null)") ;;
    classic-contexts:*) W_ENV+=("STUB_GATE_RULES=[]" "STUB_CLASSIC_JSON=$(jq -c --arg c "$v" '{protection: {required_status_checks: {contexts: [$c], checks: []}}}' <<<null)") ;;
    rule-type:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg t "$v" '[{type: $t}, {type: "required_status_checks", parameters: {required_status_checks: [{context: "Lint"}]}}]' <<<null)") ;;
    rules:fail) W_ENV+=("STUB_RULES_EXIT=1") ;;
    branch:fail) W_ENV+=("STUB_BRANCH_EXIT=1") ;;
    repo:no-protection) W_ENV+=('STUB_CLASSIC_JSON={"name":"main","protected":true}') ;;
    base:*) W_ENV+=("STUB_BASE=$v") ;;
    methods:-) W_ENV+=("STUB_MERGE_METHODS=") ;;
    methods:*) W_ENV+=("STUB_MERGE_METHODS=$(printf '%s' "$v" | tr '+' ' ')") ;;
    repo:pushless) W_ENV+=("STUB_REPO_PUSHLESS=true") ;;
    deletes-on-merge:*) W_ENV+=("STUB_DELETE_BRANCH_ON_MERGE=$v") ;;
    cross-repository) W_ENV+=("STUB_CROSS_REPOSITORY=true") ;;
    queue:*) W_ENV+=("STUB_QUEUE_METHOD=$v") ;;
    queue-on:*) W_ENV+=("STUB_QUEUE_BRANCH=$v") ;;
    rule-methods:*) W_ENV+=("STUB_RULE_METHODS=$(printf '%s' "$v" | tr '+' ' ')") ;;
    # The classifier stub's queue-only line for the pull request's range.
    route:range-fail) W_ENV+=("STUB_RANGE_FAIL=true") ;;
    route:fail) W_ENV+=("STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD") ;;
    route:-) W_ENV+=("STUB_CLASS=standard" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    route:true) W_ENV+=("STUB_CLASS=standard" "STUB_QUEUE_LINE=$QUEUE_TRUE" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    # The head every read but the range's answers, the range still at the
    # head the classifier measured.
    head-moved:*) W_ENV+=("STUB_RANGE_HEAD=$RANGE_HEAD" "STUB_HEAD=$v") ;;
    route:false) W_ENV+=("STUB_CLASS=standard" "STUB_QUEUE_LINE=$QUEUE_FALSE" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    # The base's merge_queue rule and the answer its ruleset read gives.
    queue-entries:*) W_ENV+=("STUB_QUEUE_ENTRIES=$v") ;;
    queue-rule:fail) W_ENV+=("STUB_GATE_RULES=$QUEUE_RULES" "STUB_RULESET_EXIT=1") ;;
    queue-rule:absent) W_ENV+=("STUB_GATE_RULES=$QUEUE_RULES" 'STUB_RULESET_JSON_20569265={"id":20569265}' "$CHECKS_NEVER") ;;
    queue-rule:*) W_ENV+=("STUB_GATE_RULES=$QUEUE_RULES" "$(ruleset_answer 20569265 "$v")" "$CHECKS_NEVER") ;;
    queue-mixed) W_ENV+=("STUB_GATE_RULES=$(jq -c '. + [{type: "pull_request", ruleset_id: 20569265}]' <<<"$QUEUE_RULES")") ;;
    other-bypass:absent) W_ENV+=('STUB_RULESET_JSON_24148610={"id":24148610}') ;;
    other-bypass:*) W_ENV+=("$(ruleset_answer 24148610 "$v")") ;;
    protection:on) W_ENV+=('STUB_CLASSIC_JSON={"protection":{"enabled":true,"required_status_checks":{"contexts":[],"checks":[]}}}') ;;
    protection:unknown) W_ENV+=('STUB_CLASSIC_JSON={"protection":{"required_status_checks":{"contexts":[],"checks":[]}}}') ;;
    queue-rule-method:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg m "$v" '[.[] | if .type == "merge_queue" then .parameters.merge_method = $m else . end]' <<<"$QUEUE_RULES")") ;;
    queue-two:*) W_ENV+=("STUB_GATE_RULES=$(jq -c '[.[0], (.[0] | .ruleset_id = 20569266)] + .[1:]' <<<"$QUEUE_RULES")" \
      "$(ruleset_answer 20569265 "${v%,*}")" "$(ruleset_answer 20569266 "${v#*,}")" "$CHECKS_NEVER") ;;
    post-graphql:partial) W_ENV+=("STUB_POST_GRAPHQL_PARTIAL=true") ;;
    cwd:*) RUN_DIR="$TMPDIR/settings-$v" ;;
    env:*) W_ENV+=("$v") ;;
    -) ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

build() {
  local w
  W_ENV=()
  RUN_DIR="$REPO"
  : >"$CALL_LOG"
  : >"$AUTH_LOG"
  rm -f "$FAIL_ONCE" "$MERGE_REFUSED"
  for w in "$@"; do word "$w"; done
}

# The command line for an argv word; --keep-branch throughout, so the
# deletion never reaches the stub.
argv_for() {
  case "$1" in
    check) printf '%s\n' "$PR_MERGE" 123 --check ;;
    # The mirrored tree, where the change classifier is the stub, so the
    # queue-only class is the row's own and not this repository's diff.
    auto-classified) printf '%s\n' "$MIRROR_PR_MERGE" 123 --auto --keep-branch ;;
    immediate-classified) printf '%s\n' "$MIRROR_PR_MERGE" 123 --keep-branch ;;
    classified-with:*) printf '%s\n' "$MIRROR_PR_MERGE" 123 --keep-branch; printf '%s' "${1#classified-with:}" | tr '+' '\n'; echo ;;
    immediate-classless) printf '%s\n' env "PATH=$CLASSLESS_PATH" "$CLASSLESS_PR_MERGE" 123 --keep-branch ;;
    auto) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch ;;
    immediate) printf '%s\n' "$PR_MERGE" 123 --keep-branch ;;
    with:*) printf '%s\n' "$PR_MERGE" 123; printf '%s' "${1#with:}" | tr '+' '\n'; echo ;;
    mutant:*)
      set -- "${1#mutant:}"
      printf '%s\n' "$TMPDIR/${1%%:*}/skills/github/scripts/commands/pr-merge.sh" 123
      printf '%s' "${1#*:}" | tr '+' '\n'
      echo
      ;;
    force) printf '%s\n' "$PR_MERGE" 123 --force --keep-branch ;;
    admin) printf '%s\n' "$PR_MERGE" 123 --admin --keep-branch ;;
    expected:*) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected:}" ;;
    auto-mutant:*) printf '%s\n' "$TMPDIR/${1#auto-mutant:}/skills/github/scripts/commands/pr-merge.sh" 123 --auto --keep-branch ;;
    route-mutant:*) printf '%s\n' "$TMPDIR/${1#route-mutant:}/skills/github/scripts/commands/pr-merge.sh" 123 --keep-branch ;;
    auto-route-mutant:*) printf '%s\n' "$TMPDIR/${1#auto-route-mutant:}/skills/github/scripts/commands/pr-merge.sh" 123 --auto --keep-branch ;;
    admin-credential) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch ;;
    router-in:*) printf '%s\n' "$GITHUB" -C "$TMPDIR/settings-${1#router-in:}" pr-merge 123 --auto --keep-branch ;;
    router:*) printf '%s\n' "$GITHUB" -C "$REPO" pr-merge 123 "${1#router:}" --keep-branch ;;
    *) echo "UNKNOWN-ARGV: $1" >&2; exit 2 ;;
  esac
}

# Each gh call by kind, in order. The log holds one call per `printf`, so a
# multi-line argv (a GraphQL query) spills over several lines; only a line
# beginning with a gh verb starts a call, the rest are its continuation and
# are joined onto it, so a query is classified by its whole text.
calls() {
  local line out="" kind
  while IFS= read -r line; do
    case "$line" in
      "pr view 123 --json state,mergedAt"*) out="$out,view:state" ;;
      "pr view 123 --json mergeable"*) out="$out,view:mergeable" ;;
      "pr view 123 --json reviewDecision"*) out="$out,view:reviews" ;;
      "pr view 123 --json headRefOid"*) out="$out,view:head" ;;
      "pr view 123 --json baseRefOid,headRefOid"*) out="$out,view:range" ;;
      "pr view 123 --json state,headRefOid"*) out="$out,view:post" ;;
      "pr checks"*) out="$out,checks" ;;
      # Each flag that changes what GitHub does with the merge is its own
      # suffix, so an --admin beside --auto shows rather than hiding behind it.
      # The method comes first: merge:<method>[:auto][:admin].
      "pr merge 123"*)
        kind=merge
        for class in squash merge rebase; do
          [[ " $line " != *" --$class "* ]] || kind="$kind:$class"
        done
        [[ " $line " != *" --auto "* ]] || kind="$kind:auto"
        [[ " $line " != *" --admin "* ]] || kind="$kind:admin"
        out="$out,$kind"
        ;;
      "api graphql"*"mergeQueue(branch:"*) out="$out,graphql:entries" ;;
      "api graphql"*mergeQueueEntry*) out="$out,graphql:queue" ;;
      "api user"*) out="$out,user" ;;
      "api -X DELETE repos/{owner}/{repo}/git/refs/heads/"*) out="$out,delete:${line##*/heads/}" ;;
      "auth status"*|"repo view"*|"api repos/"*|"api graphql"*reviewThreads*|"api graphql"*viewer*|"pr view 123 --json baseRefName"*) ;;
      *) out="$out,?($line)" ;;
    esac
  done < <(awk '/^(pr|api|auth|repo) / { if (call != "") print call; call = $0; next }
    { call = call " " $0 }
    END { if (call != "") print call }' "$CALL_LOG")
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf -- '-'
}
# The GH_TOKEN each call saw, distinct values in order. A multi-line argv
# spills into the log the same way, so only a line the stub started counts.
auth() {
  local out
  out="$(grep '^GH=' "$AUTH_LOG" | cut -d'|' -f1 | sed 's/^GH=//' | awk '!seen[$0]++' | paste -s -d '+' -)"
  printf '%s' "${out:--}"
}

check_text() {
  jq -r '"merge=\(.can_merge) transient=\(.transient) state=\(.state) mergeable=\(.mergeable) at=\(if .merged_at == "" then "-" else .merged_at end) runs=\(if (.head_runs | length) == 0 then "-" else (.head_runs | join(",")) end) issues=[\(.issues | join(";"))] warnings=[\(.warnings | join(";"))] keys=[\(keys_unsorted | join(","))]"' 2>/dev/null || printf 'unparseable'
}
stdout_text() {
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  if [[ "$1" == check ]]; then check_text <"$TMPDIR/stdout"; return; fi
  sed 's/;/\\;/g' "$TMPDIR/stdout" | paste -s -d ';' -
}
err_lines() {
  # The sandbox's own path is per-run, so a row that pins a child's diagnostic
  # pins <tmp> rather than a directory no second run produces. An empty
  # stderr is `-`, as stdout's is.
  local text
  text="$(sed -e 's/^[[:space:]]*//' -e '/^$/d' -e 's/;/\\;/g' -e "s|$TMPDIR_PHYSICAL|<tmp>|g" -e "s|$TMPDIR|<tmp>|g" "$TMPDIR/stderr" | paste -s -d ';' -)" || return 1
  printf '%s' "${text:--}"
}

run() {
  local rc=0
  local -a argv
  while IFS= read -r line; do argv+=("$line"); done < <(argv_for "$1")
  # Every token name and GH_REPO come off: a row pins whole stderr lines and
  # the token each call saw, so a lane's own environment would decide them.
  (cd "$RUN_DIR" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u KENDEX_ENV_FILE \
    -u GH_CONFIG_DIR \
    STUB_CALL_LOG="$CALL_LOG" STUB_AUTH_LOG="$AUTH_LOG" STUB_MERGE_REFUSED="$MERGE_REFUSED" \
    ${W_ENV[@]+"${W_ENV[@]}"} "${argv[@]}" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s auth=%s' "$rc" "$(stdout_text "$1")" "$(err_lines)" "$(calls)" "$(auth)"
}

# A must-fail control's subject: lib/mutant-copy.sh's copy under
# $TMPDIR/NAME, one whole line of FILE (a path under scripts/, default
# commands/pr-merge.sh) replaced by TO. Prints the copy's pr-merge.sh, the
# command every control runs whichever file it edits.
mutant_copy() { # NAME FROM TO [FILE]
  mutant_copy_edit "$TMPDIR/$1" "$2" "$3" "${4:-commands/pr-merge.sh}" >/dev/null
  printf '%s\n' "$TMPDIR/$1/skills/github/scripts/commands/pr-merge.sh"
}

# --- the err macros ---------------------------------------------------------------
# The long fixed texts; a `{name}` in a row's err field expands to one.
err_macro() {
  case "$1" in
    blocked) printf 'BLOCKED PR #123 — no merge attempted, none queued' ;;
    permanent) printf '(permanent — needs fix or review action)' ;;
    transient) printf '(transient — GitHub still computing or CI pending)' ;;
    # git's own words for a fetch in a repository with no origin, replayed
    # under this command's fixed line. Pinned here, in one place, because the
    # point of the row is that git's account survives rather than being
    # flattened into one sentence; a git that rewords this moves this macro.
    fetch-no-origin) printf "pr-merge: the pull request's range is not in this checkout and the fetch of its two commits from origin failed:;fatal: 'origin' does not appear to be a git repository;fatal: Could not read from remote repository.;Please make sure you have the correct access rights;and the repository exists." ;;
    hint-auto) printf 'Use --auto to queue for auto-merge.' ;;
    volatile) printf 'NOTE: queue/auto-merge state is VOLATILE — an ejection or a failed protection check disarms it silently\\; follow orch merge-pr.md § 5 for PR #123;Block on .agents/skills/orch/scripts/queue-wait 123 --json once, with a poll interval and budget sized as orch merge-pr.md § 5 step 1 does\\; route its verdict by that same step, and never re-arm an unrecognized verdict. The fleet reducer is .agents/skills/review-gate/scripts/pr-watch.sh with GH_REPO set to the repository (not resolvable locally here)\\; repair what the cause names, then re-arm only through the merge route of orch merge-pr.md § 5 step 1, which picks the direct attempt or an explicit queue arm after readiness and approval checks' ;;
    merge-failed) printf 'BLOCKED PR #123 — gh pr merge failed' ;;
    no-token) printf 'Warning: GH_BOT_TOKEN not configured, using current user' ;;
    closed) printf 'CLOSED (not merged) PR #123;No merge attempted, none queued. Reopen the PR or supersede it.' ;;
    # route-queue:<why> the second line of a queue route; route-why:<name>
    # names the why.
    route-queue:*) printf '%s The merge call passes --auto and no --admin.' "$(err_macro "route-why:${1#route-queue:}")" ;;
    route-why:ruleset) printf 'The ruleset could not be read, so no bypass is proven.' ;;
    route-why:no-bypass) printf 'This token may not bypass the merge-queue ruleset.' ;;
    route-why:mixed) printf 'The merge-queue ruleset holds another rule, which --admin would skip too.' ;;
    route-why:other-bypass) printf 'This token may bypass another ruleset on the base, which --admin would skip too.' ;;
    route-why:classic) printf 'The base branch has classic branch protection, which --admin would skip too.' ;;
    route-why:protection) printf "The base branch's classic protection could not be read, so no bypass is proven." ;;
    route-why:explicit) printf 'The caller explicitly requested the queue for a PR eligible for a direct merge.' ;;
    arm-admin) printf 'Nothing armed: the immediate merge takes this PR past the queue once its gates pass, and an arm now would queue it first.' ;;
    route-why:direct-method) printf "A merge past the queue takes the repository's methods and the base's pull_request rules, which allow none of the accepted methods." ;;
    route-why:direct-unread) printf 'The methods a merge past the queue may take could not be read.' ;;
    route-why:queue-only) printf 'A queue-only change runs in a merge group before it lands.' ;;
    route-why:occupied) printf 'The base queue holds entries, so a direct merge would repeat their CI.' ;;
    route-why:queue-unreadable) printf "The base queue's entry count could not be read as a whole number." ;;
    auto-remedy) printf 'Nothing mutated. Enable auto-merge on the repository.' ;;
    approval-remedy) printf "Nothing mutated. No ruleset on the base branch requires an approval, so GitHub would merge the armed PR before review\\; require at least 1 approval, thread resolution and stale-approval dismissal in its pull_request rule." ;;
    thread-remedy) printf "Nothing mutated. No ruleset on the base branch requires thread resolution, so GitHub would merge the armed PR on its first approval past open review threads\\; require review threads resolved in its pull_request rule." ;;
    stale-remedy) printf "Nothing mutated. No ruleset on the base branch dismisses stale approvals on push, so GitHub would merge the armed PR on an approval of an earlier head, with no review of the pushed one\\; dismiss stale approvals on push in its pull_request rule." ;;
    unverified-remedy) printf "Nothing mutated. The base branch's rules could not be read, so no merge gate is proven\\; retry once they read." ;;
    *) printf 'UNKNOWN-MACRO:%s' "$1" ;;
  esac
}
err_text() {
  local text="$1" name
  while [[ "$text" =~ \{([A-Za-z0-9:_+-]+)\} ]]; do
    name="${BASH_REMATCH[1]}"
    text="${text//\{$name\}/$(err_macro "$name")}"
  done
  printf '%s' "$text"
}

# Apply the unchanged assertion to a disposable mutant. Its red output is
# part of the suite log, which is the control receipt.
assert_mutant_fails() { # GOT WANT NAME
  local rc=0
  (FAIL=0; assert_eq "$1" "$2" "$3"; [[ "$FAIL" -eq 0 ]]) || rc=$?
  assert_eq "$rc" 1 "must-fail control: $3"
}

run_table() {
  local title="$1" rows="$2" n=0 label world argv rc out err want got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world argv rc out err want <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$err" "$want"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build $world
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$(err_text "$err") $want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

# The calls a --check makes on an open PR, and a merge's calls before the
# mutation. Each also makes the reply check's viewer and review-thread
# reads, which calls() filters out of the pin: the review_replies rows and
# the no-replies mutant prove those reads.
CHECK="view:state,view:mergeable,checks,view:reviews"
PRE="view:state,view:mergeable,checks,view:reviews,view:head"
OPEN="state=OPEN mergeable=MERGEABLE at=-"
# The readiness JSON's keys, in order: no thread term among them.
KEYS="keys=[can_merge,issues,warnings,mergeable,review,transient,state,merged_at,head_runs,checks,required_contexts]"
# The classifier's queue-only lines, as harness-ci's change-class prints them.
QUEUE_TRUE="queue_only=true cause=queue-path path=.github/workflows/ci.yml glob=.github/workflows/*"
QUEUE_FALSE="queue_only=false cause=no-queue-path"
# The base's rules: a merge_queue rule from ruleset 20569265, and a required
# check and the default world's pull_request rule from ruleset 24148610, and
# the answer of that checks ruleset for a token that may not bypass it.
QUEUE_RULES='[{"type":"merge_queue","ruleset_id":20569265,"parameters":{"merge_method":"SQUASH"}},{"type":"required_status_checks","ruleset_id":24148610},{"type":"pull_request","ruleset_id":24148610,"parameters":{"required_approving_review_count":1,"required_review_thread_resolution":true,"dismiss_stale_reviews_on_push":true}}]'
CHECKS_NEVER='STUB_RULESET_JSON_24148610={"id":24148610,"current_user_can_bypass":"never"}'
# The environment word for a ruleset read answering current_user_can_bypass.
ruleset_answer() { # ID VALUE
  printf 'STUB_RULESET_JSON_%s={"id":%s,"current_user_can_bypass":"%s"}' "$1" "$1" "$2"
}
