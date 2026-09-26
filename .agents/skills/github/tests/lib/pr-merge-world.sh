#!/usr/bin/env bash
# The world the pr-merge suites share: pr-merge.test.sh and
# pr-merge-thread-waiver.test.sh source it after `set -euo pipefail`. It
# sources lib/check-stub.sh for the gh stub, as ci-classify-refusal.test.sh
# does. Sourced, never run, so it lives one level below the suite glob.
#
# A row is `label|world|argv|rc|out|err|calls`:
#   world  words for the stub, later words overriding earlier ones:
#     checks:<name>  a checks fixture; checks-exit:<n> gh's exit for it
#     threads:<actionable|outdated|malformed|large|bot|resolved100|->, and
#     the bot-thread shapes threads:<bot-outdated|bot-and-person|two-bots|
#     codeql|bot-with-reply|bot-partial|waived-resolved>;
#     `actionable` and `outdated` are a person's, typed User by GitHub
#     threads:page2:<name>  a second page holding that fixture
#     threads:<fetch-fail|page2-fail|page2-malformed>
#     state:<MERGED|CLOSED>, merged-at, pr:missing
#     state-err:<401|ratelimit|graphql-notfound|silent4|once>
#     head:<sha>, post:<MERGED|OPEN>, post-head:<sha>, post-auto, post-queue
#     (in the queue with an entry), post-entry (an entry only), post-state:<s>
#     merge-commit:<oid>, merge-fail:<already-queued|policy|transport|queue-required>
#     graphql:fail (the queue query fails, the REST fallback answers),
#     post-view-fail (that REST fallback fails too)
#     review:<decision|none> GitHub's reviewDecision, none being empty, with
#     no latest review; review-latest:<state> one latest review in that state
#     require-token (the stub refuses a mutation without the bot token)
#     reply:fail, resolve:fail, reopen:fail  that thread mutation errors
#     repo:no-auto (allow_auto_merge=false), repo:no-rule (no ruleset check),
#     repo:pr-rule (a ruleset pull_request rule only), repo:classic (no ruleset,
#     one classic required context)
#     required:<context> a ruleset requiring that one context, `+` a space;
#     classic:<context> no ruleset, classic protection naming it under
#     checks[]; classic-contexts:<context> the same under the legacy
#     contexts array;
#     rule-type:<type> a ruleset rule of that type beside one requiring Lint
#     rules:fail, branch:fail the ruleset or the branch-protection read errors
#     repo:no-protection a branch answer carrying no protection object
#     base:<branch> the PR's base; gate reads answer only its encoded path
#     post-graphql:partial  the post-merge read answers HTTP 200 with an
#     errors array beside data
#     class-policy:<class|-|range-fail|unmeasured|range-absent>  an active
#     review-gate class policy, and the classifier stub's answer for the
#     pull request's range; head-moved:<sha> after it, the head every read
#     but the policy's answers once the class was measured
#     env:NAME=value  the caller's environment
#   argv   check | auto | immediate |
#          expected:<sha> (--auto with --expected-head) | router:<flags> |
#          force | admin | admin-credential (the retired flags) | check-classified |
#          auto-classified | immediate-classified | expected-classified:<sha>
#          (run from the mirror tree whose harness-ci sibling is the classifier
#          stub, which pr-merge-thread-waiver.test.sh builds as $MIRROR)
#   out    check: `merge=<bool> transient=<bool> state=<S> mergeable=<M>
#          at=<mergedAt|-> runs=<ids|-> issues=[a;b] warnings=[c]`;
#          check-classified adds ` waiver=<class>@<head>[<ids>]`, or
#          ` waiver=-` for none; otherwise stdout, `-` when empty
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
# A child that resolves symlinks prints the sandbox's physical path, under
# /private on macOS, so err_lines maps that spelling to <tmp> as well.
TMPDIR_PHYSICAL="$(cd "$TMPDIR" && pwd -P)"
REPO="$TMPDIR/repo"

# The class policy asks a classifier to read the diff between two commits, and
# pr-merge refuses a range this checkout does not hold. So the fixture repo is
# a real repository with two commits, and the class-policy rows name them. No
# remote is added: the slug resolution and the volatile note below still read
# what they read for a checkout that names no GitHub repository locally.
git -C "$REPO" init -q
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
ABSENT_SHA=3333333333333333333333333333333333333333

# One checkout per project settings source, each planting a retired key the way
# that source spells it. A settings table is exported by the loader and a
# private env file line is not, so a row run from each checkout proves the
# refusal reads the key where that source leaves it. `bad-settings` carries a
# settings file the loader rejects.
settings_fixture() { # NAME RELPATH CONTENT
  local dir="$TMPDIR/settings-$1"
  git init -q "$dir"
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  mkdir -p "$(dirname "$dir/$2")"
  printf '%s\n' "$3" >"$dir/$2"
}
settings_fixture toml kendex.settings.toml $'[env]\nORCH_MERGE_BYPASS = "fast-path"'
settings_fixture dot-kendex .kendex/settings.toml $'[env]\nORCH_ADMIN_MERGE_CLASSES = "render"'
settings_fixture env-local .env.local 'ORCH_ADMIN_MERGE_GH_CONFIG_DIR=/home/dev/.config/gh-admin'
settings_fixture bad-settings kendex.settings.toml $'[env]\nORCH_TMUX_VERIFY_SECS = "15"\nORCH_TMUX_VERIFY_SECS = "15"'


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

threads_of() {
  case "$1" in
    actionable) printf '[{"id":"PRRT_actionable","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":12,"comments":{"nodes":[{"author":{"login":"reviewer","__typename":"User"},"body":"Fix this safety bug"}]}}]' ;;
    outdated) printf '[{"id":"PRRT_outdated","isResolved":false,"isOutdated":true,"path":"src/old.rs","line":7,"comments":{"nodes":[{"author":{"login":"reviewer","__typename":"User"},"body":"Stale diff"}]}}]' ;;
    # isResolved null, missing, and a string
    malformed) printf '[{"id":"PRRT_null","isResolved":null,"isOutdated":false,"path":"src/null.rs","line":1,"comments":{"nodes":[]}},{"id":"PRRT_missing","isOutdated":false,"path":"src/missing.rs","line":2,"comments":{"nodes":[]}},{"id":"PRRT_string","isResolved":"false","isOutdated":false,"path":"src/string.rs","line":3,"comments":{"nodes":[]}}]' ;;
    # a bot's unresolved thread posted after a merge
    bot) printf '[{"id":"PRRT_post_merge_bot","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":3,"comments":{"totalCount":1,"nodes":[{"author":{"login":"review-bot","__typename":"Bot"},"body":"post-merge nit"}]}}]' ;;
    # the bot shapes of a waived class: Copilot's reviewer carries no [bot]
    # suffix in this view, so the type is the only thing marking it a bot
    bot-outdated) printf '[{"id":"PRRT_bot_outdated","isResolved":false,"isOutdated":true,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":1,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Stale nit"}]}}]' ;;
    bot-and-person) printf '[{"id":"PRRT_bot","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":1,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Issue KEN-1 does not exist"}]}},{"id":"PRRT_person","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":9,"comments":{"nodes":[{"author":{"login":"reviewer","__typename":"User"},"body":"This contradicts the code"}]}}]' ;;
    two-bots) printf '[{"id":"PRRT_bot_a","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":1,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Issue KEN-1 does not exist"}]}},{"id":"PRRT_bot_b","isResolved":false,"isOutdated":true,"path":"docs/plans/a.md","line":7,"comments":{"totalCount":1,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Stale nit"}]}}]' ;;
    # a full first page of resolved threads
    resolved100) jq -cn '[range(0; 100) | {id: ("PRRT_resolved_" + tostring), isResolved: true, isOutdated: false, path: "src/first-page.rs", line: ., comments: {nodes: [{author: {login: "reviewer"}, body: "Resolved"}]}}]' ;;
    # a code-scanning alert: a Bot, and not a review bot the gate reads
    codeql) printf '[{"id":"PRRT_codeql","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":1,"nodes":[{"author":{"login":"github-advanced-security","__typename":"Bot"},"body":"Code scanning alert"}]}}]' ;;
    # a review bot's thread a person has answered in
    bot-with-reply) printf '[{"id":"PRRT_bot_reply","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":2,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Issue KEN-1 does not exist"},{"author":{"login":"reviewer","__typename":"User"},"body":"It does, and this line is wrong"}]}}]' ;;
    # a review bot's thread whose comments were not all read
    bot-partial) printf '[{"id":"PRRT_bot_partial","isResolved":false,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":101,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Issue KEN-1 does not exist"}]}}]' ;;
    # a thread the merge route resolved under an earlier waiver
    waived-resolved) printf '[{"id":"PRRT_waived","isResolved":true,"isOutdated":false,"path":"docs/plans/a.md","line":4,"comments":{"totalCount":2,"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"Issue KEN-1 does not exist"},{"author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"},"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY"}]}}]' ;;
    -) printf '[]' ;;
    *) echo "UNKNOWN-THREADS: $1" >&2; exit 2 ;;
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
word() {
  local v="${1#*:}"
  case "$1" in
    checks:*) W_ENV+=("STUB_CHECKS=$(checks_of "$v")") ;;
    checks-exit:*) W_ENV+=("STUB_CHECKS_EXIT=$v") ;;
    threads:fetch-fail) W_ENV+=("STUB_THREADS_FETCH_FAIL=true") ;;
    threads:page2-fail) W_ENV+=("STUB_THREADS_PAGE2_JSON=[]" "STUB_THREADS_PAGE2_FETCH_FAIL=true") ;;
    threads:page2-malformed) W_ENV+=("STUB_THREADS_PAGE2_JSON=[]" "STUB_THREADS_PAGE2_MALFORMED=true") ;;
    threads:page2:*) W_ENV+=("STUB_THREADS_PAGE2_JSON=$(threads_of "${v#page2:}")") ;;
    threads:large) W_ENV+=("STUB_THREADS_LARGE_PAGE=true") ;;
    threads:*) W_ENV+=("STUB_THREADS_JSON=$(threads_of "$v")") ;;
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
    review:none) W_ENV+=("STUB_REVIEW_DECISION=" "STUB_REVIEW_LATEST=[]") ;;
    review:*) W_ENV+=("STUB_REVIEW_DECISION=$v" "STUB_REVIEW_LATEST=[]") ;;
    review-latest:*) W_ENV+=("STUB_REVIEW_LATEST=[{\"state\":\"$v\"}]") ;;
    require-token) W_ENV+=("STUB_REQUIRE_TOKEN=true") ;;
    reply:fail) W_ENV+=("STUB_REPLY_FAIL=true") ;;
    resolve:fail) W_ENV+=("STUB_RESOLVE_FAIL=true") ;;
    reopen:fail) W_ENV+=("STUB_REOPEN_FAIL=true") ;;
    repo:no-auto) W_ENV+=("STUB_ALLOW_AUTO_MERGE=false") ;;
    repo:no-rule) W_ENV+=("STUB_GATE_RULES=[]") ;;
    repo:pr-rule) W_ENV+=('STUB_GATE_RULES=[{"type":"pull_request"}]') ;;
    repo:classic) W_ENV+=("STUB_GATE_RULES=[]" 'STUB_CLASSIC_JSON={"protection":{"required_status_checks":{"contexts":["CI Required"],"checks":[]}}}') ;;
    required:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg c "$(printf '%s' "$v" | tr '+' ' ')" '[{type: "required_status_checks", parameters: {required_status_checks: [{context: $c}]}}]' <<<null)") ;;
    classic:*) W_ENV+=("STUB_GATE_RULES=[]" "STUB_CLASSIC_JSON=$(jq -c --arg c "$v" '{protection: {required_status_checks: {contexts: [], checks: [{context: $c}]}}}' <<<null)") ;;
    classic-contexts:*) W_ENV+=("STUB_GATE_RULES=[]" "STUB_CLASSIC_JSON=$(jq -c --arg c "$v" '{protection: {required_status_checks: {contexts: [$c], checks: []}}}' <<<null)") ;;
    rule-type:*) W_ENV+=("STUB_GATE_RULES=$(jq -c --arg t "$v" '[{type: $t}, {type: "required_status_checks", parameters: {required_status_checks: [{context: "Lint"}]}}]' <<<null)") ;;
    rules:fail) W_ENV+=("STUB_RULES_EXIT=1") ;;
    branch:fail) W_ENV+=("STUB_BRANCH_EXIT=1") ;;
    repo:no-protection) W_ENV+=('STUB_CLASSIC_JSON={"name":"main","protected":true}') ;;
    base:*) W_ENV+=("STUB_BASE=$v") ;;
    # An ACTIVE review-gate class policy. The value is the supported table; `-` leaves the classifier with no class to
    # answer, which is the unreadable-policy shape.
    class-policy:-) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS=$TRUSTED_LOGINS" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    class-policy:range-fail) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS=$TRUSTED_LOGINS" "STUB_POLICY_RANGE_FAIL=true") ;;
    # A class the classifier did not measure: it names one on stdout and marks
    # the answer a fallback, which is not a class any policy row applies to.
    class-policy:unmeasured) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS=$TRUSTED_LOGINS" "STUB_CLASS=render" "STUB_MEASURED=false" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    # A base the fixture repository does not hold, and no origin to fetch it
    # from: the range is unreadable and no class can be measured.
    class-policy:range-absent) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS=$TRUSTED_LOGINS" "STUB_CLASS=render" "STUB_BASE_OID=$ABSENT_SHA" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$ABSENT_SHA" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    class-policy:*) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS=$TRUSTED_LOGINS" "STUB_CLASS=$v" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    # The head moved after the class was measured: the policy read its range
    # at the fixture head, and every later read answers this one.
    head-moved:*) W_ENV+=("STUB_POLICY_HEAD=$RANGE_HEAD" "STUB_HEAD=$v") ;;
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
  rm -f "$FAIL_ONCE"
  for w in "$@"; do word "$w"; done
}

# The command line for an argv word; --keep-branch throughout, so the
# deletion never reaches the stub.
argv_for() {
  case "$1" in
    check) printf '%s\n' "$PR_MERGE" 123 --check ;;
    # The mirrored tree, where the change classifier is the stub: a row whose
    # verdict turns on the review gate's class policy runs here so the class
    # is the row's own and not this repository's diff.
    check-classified) printf '%s\n' "$MIRROR_PR_MERGE" 123 --check ;;
    auto-classified) printf '%s\n' "$MIRROR_PR_MERGE" 123 --auto --keep-branch ;;
    immediate-classified) printf '%s\n' "$MIRROR_PR_MERGE" 123 --keep-branch ;;
    expected-classified:*) printf '%s\n' "$MIRROR_PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected-classified:}" ;;
    auto) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch ;;
    immediate) printf '%s\n' "$PR_MERGE" 123 --keep-branch ;;
    force) printf '%s\n' "$PR_MERGE" 123 --force --keep-branch ;;
    admin) printf '%s\n' "$PR_MERGE" 123 --admin --keep-branch ;;
    expected:*) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected:}" ;;
    admin-credential) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch ;;
    router-in:*) printf '%s\n' "$GITHUB" -C "$TMPDIR/settings-${1#router-in:}" pr-merge 123 --auto --keep-branch ;;
    router:*) printf '%s\n' "$GITHUB" -C "$REPO" pr-merge 123 "${1#router:}" --keep-branch ;;
    *) echo "UNKNOWN-ARGV: $1" >&2; exit 2 ;;
  esac
}

# Each gh call by kind, in order. The log holds one call per `printf`, so a
# multi-line argv (a GraphQL query) spills over several lines; only a line
# beginning with a gh verb starts a call, the rest are its continuation and
# are joined onto it, so a query is classified by its whole text. A thread
# reply names its thread and the change class its body gives; a resolve names
# its thread.
calls() {
  local line out="" kind class
  while IFS= read -r line; do
    case "$line" in
      "pr view 123 --json state,mergedAt"*) out="$out,view:state" ;;
      "pr view 123 --json mergeable"*) out="$out,view:mergeable" ;;
      "pr view 123 --json reviewDecision"*) out="$out,view:reviews" ;;
      "pr view 123 --json baseRefOid,headRefOid"*) out="$out,view:policy-range" ;;
      "pr view 123 --json headRefOid"*) out="$out,view:head" ;;
      "pr view 123 --json state,headRefOid"*) out="$out,view:post" ;;
      "pr checks"*) out="$out,checks" ;;
      # Each flag that changes what GitHub does with the merge is its own
      # suffix, so an --admin beside --auto shows rather than hiding behind it.
      "pr merge 123"*)
        kind=merge
        [[ " $line " != *" --auto "* ]] || kind="$kind:auto"
        [[ " $line " != *" --admin "* ]] || kind="$kind:admin"
        out="$out,$kind"
        ;;
      "api graphql"*mergeQueueEntry*) out="$out,graphql:queue" ;;
      "api graphql"*addPullRequestReviewThreadReply*)
        kind="${line##*threadId=}"
        kind="${kind%% *}"
        class="?"
        [[ ! "$line" =~ change\ class\ ([a-z]+)\ at\ ([0-9a-f]{40}), ]] || class="${BASH_REMATCH[1]}@${BASH_REMATCH[2]:0:7}"
        out="$out,graphql:reply($kind:$class)"
        ;;
      "api graphql"*unresolveReviewThread*)
        kind="${line##*threadId=}"
        out="$out,graphql:reopen(${kind%% *})"
        ;;
      "api graphql"*resolveReviewThread*)
        kind="${line##*threadId=}"
        out="$out,graphql:resolve(${kind%% *})"
        ;;
      "api graphql"*) out="$out,graphql:threads" ;;
      "api user"*) out="$out,user" ;;
      "auth status"*|"repo view"*|"api repos/"*|"pr view 123 --json baseRefName"*) ;;
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
  jq -r '"merge=\(.can_merge) transient=\(.transient) state=\(.state) mergeable=\(.mergeable) at=\(if .merged_at == "" then "-" else .merged_at end) runs=\(if (.head_runs | length) == 0 then "-" else (.head_runs | join(",")) end) issues=[\(.issues | join(";"))] warnings=[\(.warnings | join(";"))]"' 2>/dev/null || printf 'unparseable'
}
stdout_text() {
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  if [[ "$1" == check ]]; then check_text <"$TMPDIR/stdout"; return; fi
  if [[ "$1" == check-classified ]]; then
    printf '%s' "$(check_text <"$TMPDIR/stdout")"
    jq -j '" waiver=" + (.thread_waiver | if . == null then "-" else "\(.class)@\(.head)[\(.threads | join(","))]" end)' <"$TMPDIR/stdout" 2>/dev/null || printf ' waiver=unparseable'
    return
  fi
  sed 's/;/\\;/g' "$TMPDIR/stdout" | paste -s -d ';' -
}
err_lines() {
  # The sandbox's own path is per-run, so a row that pins a child's diagnostic
  # pins <tmp> rather than a directory no second run produces.
  sed -e 's/^[[:space:]]*//' -e '/^$/d' -e 's/;/\\;/g' -e "s|$TMPDIR_PHYSICAL|<tmp>|g" -e "s|$TMPDIR|<tmp>|g" "$TMPDIR/stderr" | paste -s -d ';' -
}

run() {
  local rc=0
  local -a argv
  while IFS= read -r line; do argv+=("$line"); done < <(argv_for "$1")
  # Every token name and GH_REPO come off: a row pins whole stderr lines and
  # the token each call saw, so a lane's own environment would decide them.
  # The retired merge settings come off too, so only a row's own env: word
  # sets one.
  (cd "$RUN_DIR" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u KENDEX_ENV_FILE \
    -u ORCH_ADMIN_MERGE_GH_CONFIG_DIR -u ORCH_ADMIN_MERGE_CLASSES -u ORCH_MERGE_BYPASS -u GH_CONFIG_DIR \
    -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u REVIEW_GATE_CONTEXT \
    -u REVIEW_GATE_SETTINGS_FILE -u REVIEW_GATE_CLASS_POLICY -u REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS \
    STUB_CALL_LOG="$CALL_LOG" STUB_AUTH_LOG="$AUTH_LOG" \
    ${W_ENV[@]+"${W_ENV[@]}"} "${argv[@]}" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s auth=%s' "$rc" "$(stdout_text "$1")" "$(err_lines)" "$(calls)" "$(auth)"
}

# --- the err macros ---------------------------------------------------------------
# The long fixed texts; a `{name}` in a row's err field expands to one.
err_macro() {
  case "$1" in
    blocked) printf 'BLOCKED PR #123 — no merge attempted, none queued' ;;
    permanent) printf '(permanent — needs fix or review action)' ;;
    transient) printf '(transient — GitHub still computing or CI pending)' ;;
    hint-threads) printf 'Resolve the review-thread gate and retry.' ;;
    # git's own words for a fetch in a repository with no origin, replayed
    # under this command's fixed line. Pinned here, in one place, because the
    # point of the row is that git's account survives rather than being
    # flattened into one sentence; a git that rewords this moves this macro.
    fetch-no-origin) printf "pr-merge: the class-policy range is not in this checkout and the fetch of its two commits from origin failed:;fatal: 'origin' does not appear to be a git repository;fatal: Could not read from remote repository.;Please make sure you have the correct access rights;and the repository exists." ;;
    hint-auto) printf 'Use --auto to queue for auto-merge.' ;;
    hint-await) printf 'Hint: github.sh await-mergeable 123 && retry' ;;
    volatile) printf 'NOTE: queue/auto-merge state is VOLATILE — an ejection or a failed protection check disarms it silently\\; follow orch merge-pr.md § 5 for PR #123;Block on .agents/skills/orch/scripts/queue-wait 123 --json once, with a poll interval and budget sized as orch merge-pr.md § 5 step 1 does\\; route its verdict by that same step, and never re-arm an unrecognized verdict. The fleet reducer is .agents/skills/review-gate/scripts/pr-watch.sh with GH_REPO set to the repository (not resolvable locally here)\\; repair what the cause names before re-arming with .agents/skills/github/scripts/github.sh pr-merge 123 --auto' ;;
    merge-failed) printf 'BLOCKED PR #123 — gh pr merge failed' ;;
    no-token) printf 'Warning: GH_BOT_TOKEN not configured, using current user' ;;
    closed) printf 'CLOSED (not merged) PR #123;No merge attempted, none queued. Reopen the PR or supersede it.' ;;
    threads:*) printf 'unresolved_threads: %s actionable thread(s) need attention' "${1#threads:}" ;;
    fetch-failed) printf 'review_threads_fetch_failed: Failed to fetch actionable review threads from GitHub' ;;
    malformed) printf 'review_threads_fetch_failed: GitHub returned malformed review thread data' ;;
    retired:*) printf 'The overseer'"'"'s admin merge and the ORCH_MERGE_BYPASS fast path are retired (kendex decision D003): every merge goes through the merge queue, armed with --auto.;Remove %s from kendex.settings.toml [env], .kendex/settings.toml [env], the private env file (.env.local unless KENDEX_ENV_FILE names another) and the environment, then retry.' "$(printf '%s' "${1#retired:}" | tr '+' ' ')" ;;
    arm-remedy) printf 'Nothing mutated. Enable auto-merge and a required status check or review rule on the base branch.' ;;
    waived:*) printf "unresolved_threads_waived: %s review-bot thread(s) open, waived by the review gate's class policy for this change, and the merge route resolves them before it arms" "${1#waived:}" ;;
    # resolved:<thread>:<class>
    resolved:*) printf 'RESOLVED THREAD %s — change class %s, review evidence none' "$(printf '%s' "$1" | cut -d: -f2)" "$(printf '%s' "$1" | cut -d: -f3)" ;;
    unreadable) printf "review_policy_unreadable: The review gate's class policy could not be resolved for this pull request" ;;
    reopened:*) printf 'REOPENED THREAD %s — the waiver that resolved it no longer covers this pull request' "${1#reopened:}" ;;
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

# The calls a --check makes on an open PR, and a merge's calls before the mutation.
CHECK="view:state,view:mergeable,checks,graphql:threads,view:reviews"
# The supported class policy, the one value the review-gate README documents.
CLASS_POLICY="render:none;trivial:none;micro:none;small:bot;standard:current"
# The review gate's trusted logins beside it: two review bots and a person, so
# --review-bots names the bots and drops the person.
TRUSTED_LOGINS="copilot-pull-request-reviewer[bot];review-bot[bot];bmethod"
# Its extra call: with a thread open, an active policy reads the pull request's
# own endpoints once. A clean PR asks nothing and the trace is unchanged.
CHECK_POLICY="view:state,view:mergeable,checks,graphql:threads,view:policy-range,view:reviews"
PRE="view:state,view:mergeable,checks,graphql:threads,view:reviews,view:head"
OPEN="state=OPEN mergeable=MERGEABLE at=-"
