#!/usr/bin/env bash
# pr-merge: the --check readiness JSON and its stderr verdict, the
# review-thread gate, the terminal states (a merged or closed PR
# short-circuits every mode, before and after a state lookup that failed
# once), the guarded mutation and its post-call outcomes, and the two
# overrides. Its sibling ci-classify-refusal.test.sh and this file both
# source lib/check-stub.sh for the gh stub.
#
# A row is `label|world|argv|rc|out|err|calls`:
#   world  words for the stub, later words overriding earlier ones:
#     checks:<name>  a checks fixture; checks-exit:<n> gh's exit for it
#     threads:<actionable|outdated|malformed|large|bot|resolved100|->
#     threads:page2:<name>  a second page holding that fixture
#     threads:<fetch-fail|page2-fail|page2-malformed>
#     state:<MERGED|CLOSED>, merged-at, pr:missing
#     state-err:<401|ratelimit|graphql-notfound|silent4|once>
#     head:<sha>, post:<MERGED|OPEN>, post-head:<sha>, post-auto, post-queue
#     (in the queue with an entry), post-entry (an entry only), post-state:<s>
#     merge-commit:<oid>, merge-fail:<already-queued|policy|transport|queue-required>
#     graphql:fail (the queue query fails, the REST fallback answers)
#     require-token (the stub refuses a mutation without the bot token)
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
#     base-oid:<sha> the base branch's head, or `-` for none
#     admin-dir | admin-dir:missing  ORCH_ADMIN_MERGE_GH_CONFIG_DIR, a real
#     directory or a path that is not one; absent leaves the route off
#     admin-classes:<list>  ORCH_ADMIN_MERGE_CLASSES; `+` stands for a space
#     gate-mode:<approval|review|off>  the checkout's resolved reviewer-gate
#     mode, set through PR_REVIEW_GATE; absent, the sandbox resolves approval.
#     gate-mode:unresolvable  a settings file the engine refuses, so the
#     resolver answers nothing at all
#     gate-context:<name>  REVIEW_GATE_CONTEXT, `+` a space
#     gate-status:<state>  the review-gate commit status on the head, under
#     the context "Review gate" and behind an unrelated newer row, so a read
#     that took the newest row of any context would take the wrong one.
#     gate-status:absent a head carrying no status; gate-status:fail the read
#     errors; gate-status:garbage a page that is not a status page. Every
#     gate-status knob binds the statuses read to $AHEAD: any other ref's
#     statuses answer Not Found.
#     review:none  no review decision and no review at all, the shape a
#     review-mode repository answers on every pull request
#     review:none+approved  no review decision beside one approving review,
#     the shape a base with no approval rule answers once someone approves
#     class:<verdict>  the sibling change classifier's answer, as one
#     change_class= line; absent, it answers nothing at all.
#     class-bare:<verdict>  the same verdict as a bare word, the shape the
#     route must refuse
#     behind:<n>  commits the base has that the head lacks; compare:fail
#     admin-queue, admin-auto  the PR is queued / auto-merge armed
#     admin-node:-  GitHub returns no node id for it
#     threads-after-dequeue:<set>  the threads the query answers once the
#     dequeue has run, so a gate turns red inside that window
#     merge-methods:<a+b>  a ruleset pull_request rule whose
#     allowed_merge_methods names those methods; linear-history a ruleset
#     required_linear_history rule; thread-resolution a pull_request rule
#     whose required_review_thread_resolution is true
#     protection:<inert|held|conversation|linear|unknown|unknown-shape|
#     unknown-values>  the base's classic branch protection; absent, the base
#     carries none. protection:read-fail  the protection read errors some
#     other way
#     queue-partial, post-graphql:partial  the queue-state read / the
#     post-merge read answers HTTP 200 with an errors array beside data
#     dequeue:fail  the queue mutations are refused
#     env:NAME=value  the caller's environment
#   argv   check | auto | immediate | force | admin | admin-dry | force-auto |
#          expected:<sha> (--auto with --expected-head) | router:<flags> |
#          admin-credential:<sha> | admin-credential-merge:<sha> (--merge) |
#          admin-credential-classified:<sha> (run from the mirror tree whose
#          harness-ci sibling is the classifier stub) |
#          admin-credential-auto:<sha> |
#          admin-credential-bare |
#          admin-credential-lone:<sha> (run from a tree holding github's
#          scripts alone, so no gate-mode resolver is reachable)
#   out    check: `merge=<bool> transient=<bool> state=<S> mergeable=<M>
#          at=<mergedAt|-> runs=<ids|-> issues=[a;b] warnings=[c]`;
#          otherwise stdout, `-` when empty
#   err    stderr's lines joined by `;`, leading spaces dropped, blank lines
#          dropped, `{word}` macros expanded (see err_macro)
#   calls  `calls=<each gh call by kind, in order> auth=<the GH_TOKEN each
#          call saw, distinct values in order>`
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"
GITHUB="$REPO_ROOT/skills/github/scripts/github.sh"

# shellcheck source=lib/check-stub.sh
source "$TEST_DIR/lib/check-stub.sh"
REPO="$TMPDIR/repo"

# The class policy asks a classifier to read the diff between two commits, and
# pr-merge refuses a range this checkout does not hold. So the fixture repo is
# a real repository with two commits, and the class-policy rows name them. No
# remote is added: the slug resolution and the volatile note below still read
# what they read for a checkout that names no GitHub repository locally.
git -C "$REPO" init -q
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

# The admin-credential route's own world: a gh config directory that exists on
# this "control host", and a 40-character head for --expected-head.
ADMIN_DIR="$TMPDIR/gh-admin"
mkdir -p "$ADMIN_DIR"
AHEAD=1111111111111111111111111111111111111111
BHEAD=2222222222222222222222222222222222222222

# The route resolves its change classifier and its gate-mode resolver beside
# the scripts tree it runs from, preferring those siblings over PATH, and this
# repository ships both there. So the class rows run pr-merge.sh out of a
# mirror of the scripts tree: real directories holding a symlink per file, with
# the mirror's own harness-ci sibling written as the stub. Production
# resolution is untouched — a run from the real tree still reaches the shipped
# classifier. orch and review-gate are mirrored whole beside github, the
# sibling layout the route feature-detects, so a mirror run resolves the mode
# and the gate context exactly as a run from the real tree does.
MIRROR="$TMPDIR/tree"
mirror_tree() { # DEST SKILL
  local dest="$1" skill="$2" f d
  while IFS= read -r f; do
    d=""
    d=$(dirname -- "$f") || exit 2
    mkdir -p "$dest/skills/$skill/scripts/$d"
    ln -s "$REPO_ROOT/skills/$skill/scripts/$f" "$dest/skills/$skill/scripts/$f"
  done < <(cd "$REPO_ROOT/skills/$skill/scripts" && find . -type f | sed 's|^\./||')
}
for mirrored in github orch review-gate; do mirror_tree "$MIRROR" "$mirrored"; done

# What CHECKOUT CODE sees. The route runs four things out of the checkout: the
# change classifier, the gate-mode resolver, the review gate's class-policy
# owner, and the settings library the gate context is read from. The first is
# the stub below; the other three all reach the settings library, so replacing
# the mirror's symlink to it with a recorder that then sources the real one
# puts a canary on every entry. Each writes one line naming the entry and the
# owner credential's directory as it found it, and the admin-credential group
# below requires every one of them to have found none.
CHECKOUT_ENV_LOG="$TMPDIR/checkout-env.log"
: >"$CHECKOUT_ENV_LOG"
MIRROR_SETTINGS_LIB="$MIRROR/skills/review-gate/scripts/lib/settings.sh"
[[ -L "$MIRROR_SETTINGS_LIB" ]] || { echo "mirror is missing the review-gate settings library" >&2; exit 2; }
rm -f -- "${MIRROR_SETTINGS_LIB:?}"
cat >"$MIRROR_SETTINGS_LIB" <<EOF
# shellcheck shell=bash
printf 'settings-lib|CFG=%s\n' "\${GH_CONFIG_DIR:-<unset>}" >>"$CHECKOUT_ENV_LOG"
. "$REPO_ROOT/skills/review-gate/scripts/lib/settings.sh"
EOF
MIRROR_PR_MERGE="$MIRROR/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$MIRROR_PR_MERGE" ]] || { echo "mirror is missing pr-merge.sh" >&2; exit 2; }
[[ -x "$MIRROR/skills/orch/scripts/approval-wait" ]] || { echo "mirror is missing approval-wait" >&2; exit 2; }

# The same mirror without its orch sibling: the route finds no gate-mode
# resolver at all there. An approval-wait installed on this machine's PATH
# would answer the route's fallback and leave that row asserting nothing, so
# the fixture refuses instead of running.
LONE="$TMPDIR/lone-tree"
mirror_tree "$LONE" github
LONE_PR_MERGE="$LONE/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$LONE_PR_MERGE" ]] || { echo "lone tree is missing pr-merge.sh" >&2; exit 2; }
if command -v approval-wait >/dev/null 2>&1; then
  echo "approval-wait resolves on PATH, so the absent-resolver row would assert nothing" >&2
  exit 2
fi

# A settings file the review-gate engine refuses, so approval-wait --resolve-mode
# exits without printing a mode: the route's other unresolvable-mode shape.
BAD_SETTINGS="$TMPDIR/refused.settings.toml"
printf '[env]\nREVIEW_GATE_MODE = "enforce"\nREVIEW_GATE_MODE = "enforce"\n' >"$BAD_SETTINGS"

mkdir -p "$MIRROR/skills/harness-ci/scripts"
cat >"$MIRROR/skills/harness-ci/scripts/change-class" <<'EOF'
#!/usr/bin/env bash
# The shipped classifier's contract. A measured class needs
# --event pull_request, so a call without it is the wiring error the real
# classifier exits 2 on; stdout is one change_class=<class> line and nothing
# else. The route must also pass --base and --head with the resolved base and
# the expected head, and --repo with the checkout it runs in: a call missing a
# flag or carrying the wrong value fails instead of answering, so dropping one
# from the caller is caught. With no STUB_CLASS it answers nothing at all,
# which is the route's no-classifier case; STUB_CLASS_SHAPE=bare prints the
# bare word the route must refuse.
# The owner credential's gh config directory must never reach checkout code.
# Recorded first, then refused, so a leak both reds whatever the row was for
# and shows up in the canary group at the end of this suite.
printf 'change-class|CFG=%s\n' "${GH_CONFIG_DIR:-<unset>}" >>"${CHECKOUT_ENV_LOG:-/dev/null}"
[[ -z "${GH_CONFIG_DIR:-}" ]] || { echo "change-class: cause=credential-leak dir=$GH_CONFIG_DIR" >&2; exit 4; }
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
# The class line, whose measured= marker says whether a rule earned this class
# or the classifier fell back to standard. review-policy reads it and refuses
# an answer marked unmeasured, so a row can turn a waiver into a refusal
# without changing the class on stdout.
if [[ "${STUB_MARKER:-yes}" == yes ]]; then
  printf 'class: class=%s measured=%s cause=stub\n' "$STUB_CLASS" "${STUB_MEASURED:-true}" >&2
fi
if [[ "${STUB_CLASS_SHAPE:-}" == bare ]]; then
  printf '%s\n' "$STUB_CLASS"
else
  printf 'change_class=%s\n' "$STUB_CLASS"
fi
EOF
chmod +x "$MIRROR/skills/harness-ci/scripts/change-class"
QUEUE_CLEARED="$TMPDIR/queue-cleared"

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
    actionable) printf '[{"id":"PRRT_actionable","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":12,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Fix this safety bug"}]}}]' ;;
    outdated) printf '[{"id":"PRRT_outdated","isResolved":false,"isOutdated":true,"path":"src/old.rs","line":7,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Stale diff"}]}}]' ;;
    # isResolved null, missing, and a string
    malformed) printf '[{"id":"PRRT_null","isResolved":null,"isOutdated":false,"path":"src/null.rs","line":1,"comments":{"nodes":[]}},{"id":"PRRT_missing","isOutdated":false,"path":"src/missing.rs","line":2,"comments":{"nodes":[]}},{"id":"PRRT_string","isResolved":"false","isOutdated":false,"path":"src/string.rs","line":3,"comments":{"nodes":[]}}]' ;;
    # a bot's unresolved thread posted after a merge
    bot) printf '[{"id":"PRRT_post_merge_bot","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":3,"comments":{"nodes":[{"author":{"login":"review-bot"},"body":"post-merge nit"}]}}]' ;;
    # a full first page of resolved threads
    resolved100) jq -cn '[range(0; 100) | {id: ("PRRT_resolved_" + tostring), isResolved: true, isOutdated: false, path: "src/first-page.rs", line: ., comments: {nodes: [{author: {login: "reviewer"}, body: "Resolved"}]}}]' ;;
    -) printf '[]' ;;
    *) echo "UNKNOWN-THREADS: $1" >&2; exit 2 ;;
  esac
}

# The base branch's classic protection object, the second spelling of the gates
# the admin route re-checks. `inert` carries every setting the gate skips, all
# on at once, beside the two it does read and one unaccounted key, all off.
# `held` carries the three settings that gate who may write the base branch:
# GitHub holds a merge on each, so each is unhandled rather than skipped.
# `unknown-shape` and `unknown-values` carry the value shapes the gate reads
# for on-ness: an object with no `enabled`, a bare true and a bare false, and a
# value that is neither object nor boolean.
protection_of() {
  case "$1" in
    inert) printf '{"url":"https://api.github.com/repos/owner/repo/branches/main/protection","required_status_checks":{"strict":true,"contexts":["CI Required"],"checks":[{"context":"CI Required"}]},"required_pull_request_reviews":{"required_approving_review_count":1},"enforce_admins":{"enabled":true},"block_creations":{"enabled":true},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":true},"allow_fork_syncing":{"enabled":true},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":false},"required_deployments":{"enabled":false}}' ;;
    held) printf '{"required_signatures":{"enabled":true},"lock_branch":{"enabled":true},"restrictions":{"users":[],"teams":[],"apps":[]}}' ;;
    conversation) printf '{"required_conversation_resolution":{"enabled":true}}' ;;
    linear) printf '{"required_linear_history":{"enabled":true}}' ;;
    unknown) printf '{"required_deployments":{"enabled":true}}' ;;
    unknown-shape) printf '{"future_gate":{"mode":"strict"}}' ;;
    unknown-values) printf '{"future_gate":"strict","future_flag":true,"future_off":false}' ;;
    *) echo "UNKNOWN-PROTECTION: $1" >&2; exit 2 ;;
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
    require-token) W_ENV+=("STUB_REQUIRE_TOKEN=true") ;;
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
    base-oid:-) W_ENV+=("STUB_BASE_OID=") ;;
    base-oid:*) W_ENV+=("STUB_BASE_OID=$v") ;;
    admin-dir) W_ENV+=("ORCH_ADMIN_MERGE_GH_CONFIG_DIR=$ADMIN_DIR") ;;
    admin-dir:missing) W_ENV+=("ORCH_ADMIN_MERGE_GH_CONFIG_DIR=$TMPDIR/absent-config") ;;
    admin-classes:*) W_ENV+=("ORCH_ADMIN_MERGE_CLASSES=$(printf '%s' "$v" | tr '+' ' ')") ;;
    class:*) W_ENV+=("STUB_CLASS=$v" "STUB_EXPECT_HEAD=$AHEAD" "STUB_EXPECT_BASE=base-oid") ;;
    # An ACTIVE review-gate class policy on an ordinary (non-admin) head. The
    # value is the supported table; `-` leaves the classifier with no class to
    # answer, which is the unreadable-policy shape.
    class-policy:-) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    class-policy:range-fail) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "STUB_POLICY_RANGE_FAIL=true") ;;
    # A class the classifier did not measure: it names one on stdout and marks
    # the answer a fallback, which is not a class any policy row applies to.
    class-policy:unmeasured) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "STUB_CLASS=render" "STUB_MEASURED=false" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    # A base the fixture repository does not hold, and no origin to fetch it
    # from: the range is unreadable and no class can be measured.
    class-policy:range-absent) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "STUB_CLASS=render" "STUB_BASE_OID=$ABSENT_SHA" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$ABSENT_SHA" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    class-policy:*) W_ENV+=("REVIEW_GATE_CLASS_POLICY=$CLASS_POLICY" "STUB_CLASS=$v" "STUB_BASE_OID=$RANGE_BASE" "STUB_HEAD=$RANGE_HEAD" "STUB_EXPECT_BASE=$RANGE_BASE" "STUB_EXPECT_HEAD=$RANGE_HEAD") ;;
    class-bare:*) W_ENV+=("STUB_CLASS=$v" "STUB_CLASS_SHAPE=bare" "STUB_EXPECT_HEAD=$AHEAD" "STUB_EXPECT_BASE=base-oid") ;;
    review:none) W_ENV+=("STUB_REVIEW_DECISION=" "STUB_REVIEW_LATEST=[]") ;;
    review:none+approved) W_ENV+=("STUB_REVIEW_DECISION=" 'STUB_REVIEW_LATEST=[{"state":"APPROVED"}]') ;;
    review:*) W_ENV+=("STUB_REVIEW_DECISION=$v" "STUB_REVIEW_LATEST=[]") ;;
    gate-mode:unresolvable) W_ENV+=("REVIEW_GATE_SETTINGS_FILE=$BAD_SETTINGS") ;;
    gate-mode:*) W_ENV+=("PR_REVIEW_GATE=$v") ;;
    gate-context:*) W_ENV+=("REVIEW_GATE_CONTEXT=$(printf '%s' "$v" | tr '+' ' ')") ;;
    gate-status:absent) W_ENV+=("STUB_GATE_STATUS_JSON=[]" "STUB_EXPECT_HEAD=$AHEAD") ;;
    gate-status:fail) W_ENV+=("STUB_GATE_STATUS_FAIL=true" "STUB_EXPECT_HEAD=$AHEAD") ;;
    gate-status:garbage) W_ENV+=('STUB_GATE_STATUS_JSON={"message":"Not Found"}' "STUB_EXPECT_HEAD=$AHEAD") ;;
    gate-status:*) W_ENV+=("STUB_GATE_STATUS_JSON=$(jq -cn --arg s "$v" '[{context:"CI Required",state:"failure"},{context:"Review gate",state:$s}]')" "STUB_EXPECT_HEAD=$AHEAD") ;;
    review-partial) W_ENV+=("STUB_REVIEW_DECISION=REVIEW_REQUIRED" 'STUB_REVIEW_LATEST=[{"state":"APPROVED"}]') ;;
    ruleset:*) W_ENV+=("STUB_GATE_RULES=$(printf '%s' "$v" | tr ',' '\n' | jq -R -s -c 'split("\n") | map(select(. != "") | {type: .})')") ;;
    merge-methods:*) W_ENV+=("STUB_GATE_RULES=$(printf '%s' "$v" | tr '+' '\n' | jq -R -s -c '[split("\n")[] | select(. != "")] as $m | [{type:"pull_request", parameters:{allowed_merge_methods:$m}}]')") ;;
    linear-history) W_ENV+=('STUB_GATE_RULES=[{"type":"required_linear_history"}]') ;;
    thread-resolution) W_ENV+=('STUB_GATE_RULES=[{"type":"pull_request","parameters":{"required_review_thread_resolution":true}}]') ;;
    protection:read-fail) W_ENV+=("STUB_CLASSIC_PROTECTION_EXIT=1") ;;
    protection:*) W_ENV+=("STUB_CLASSIC_PROTECTION_JSON=$(protection_of "$v")") ;;
    reread-fail) W_ENV+=("STUB_REREAD_FAIL=true") ;;
    threads-after-dequeue:*) W_ENV+=("STUB_THREADS_AFTER_DEQUEUE_JSON=$(threads_of "$v")") ;;
    behind:*) W_ENV+=("STUB_BEHIND_BY=$v") ;;
    compare:fail) W_ENV+=("STUB_COMPARE_FAIL=true") ;;
    base-moved) W_ENV+=("STUB_BASE_MOVED=true") ;;
    admin-queue) W_ENV+=("STUB_ADMIN_IN_QUEUE=true") ;;
    admin-auto) W_ENV+=("STUB_ADMIN_AUTO=true") ;;
    admin-node:-) W_ENV+=("STUB_PR_NODE_ID=") ;;
    queue-partial) W_ENV+=("STUB_QUEUE_PARTIAL=true") ;;
    post-graphql:partial) W_ENV+=("STUB_POST_GRAPHQL_PARTIAL=true") ;;
    dequeue:fail) W_ENV+=("STUB_DEQUEUE_FAIL=true") ;;
    dequeue:only-fail) W_ENV+=("STUB_DEQUEUE_ONLY_FAIL=true") ;;
    post-view-fail) W_ENV+=("STUB_POST_VIEW_FAIL=true") ;;
    env:*) W_ENV+=("$v") ;;
    -) ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

build() {
  local w
  W_ENV=()
  : >"$CALL_LOG"
  : >"$AUTH_LOG"
  rm -f "$FAIL_ONCE" "$QUEUE_CLEARED"
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
    auto) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch ;;
    immediate) printf '%s\n' "$PR_MERGE" 123 --keep-branch ;;
    force) printf '%s\n' "$PR_MERGE" 123 --force --keep-branch ;;
    admin) printf '%s\n' "$PR_MERGE" 123 --admin --keep-branch ;;
    admin-dry) printf '%s\n' "$PR_MERGE" 123 --admin --dry-run --keep-branch ;;
    force-auto) printf '%s\n' "$PR_MERGE" 123 --force --auto --keep-branch ;;
    expected:*) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected:}" ;;
    admin-credential:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch --expected-head "${1#admin-credential:}" ;;
    admin-credential-classified:*) printf '%s\n' "$MIRROR_PR_MERGE" 123 --admin-credential --keep-branch --expected-head "${1#admin-credential-classified:}" ;;
    admin-credential-merge:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --merge --keep-branch --expected-head "${1#admin-credential-merge:}" ;;
    admin-credential-auto:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --auto --keep-branch --expected-head "${1#admin-credential-auto:}" ;;
    admin-credential-check:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --check --keep-branch --expected-head "${1#admin-credential-check:}" ;;
    admin-credential-force:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --force --keep-branch --expected-head "${1#admin-credential-force:}" ;;
    admin-credential-admin:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --admin --keep-branch --expected-head "${1#admin-credential-admin:}" ;;
    admin-credential-dry:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --dry-run --keep-branch --expected-head "${1#admin-credential-dry:}" ;;
    admin-credential-bare) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch ;;
    admin-credential-lone:*) printf '%s\n' "$LONE_PR_MERGE" 123 --admin-credential --keep-branch --expected-head "${1#admin-credential-lone:}" ;;
    router-admin-credential:*) printf '%s\n' "$GITHUB" -C "$REPO" pr-merge 123 --admin-credential --keep-branch --expected-head "${1#router-admin-credential:}" ;;
    router:*) printf '%s\n' "$GITHUB" -C "$REPO" pr-merge 123 "${1#router:}" --keep-branch ;;
    *) echo "UNKNOWN-ARGV: $1" >&2; exit 2 ;;
  esac
}

# Each gh call by kind, in order. The log holds one call per `printf`, so a
# multi-line argv (the threads query) spills over several lines; only a line
# beginning with a gh verb starts a call, the rest are its continuation.
calls() {
  local line out=""
  while IFS= read -r line; do
    case "$line" in
      "pr "*|"api "*|"auth "*|"repo "*) ;;
      *) continue ;;
    esac
    case "$line" in
      "pr view 123 --json state,mergedAt"*) out="$out,view:state" ;;
      "pr view 123 --json mergeable"*) out="$out,view:mergeable" ;;
      "pr view 123 --json reviewDecision"*) out="$out,view:reviews" ;;
      "pr view 123 --json baseRefOid,headRefOid"*) out="$out,view:policy-range" ;;
      "pr view 123 --json headRefOid"*) out="$out,view:head" ;;
      "pr view 123 --json state,headRefOid"*) out="$out,view:post" ;;
      "pr view 123 --json baseRefName,baseRefOid"*) out="$out,view:base" ;;
      "pr checks"*) out="$out,checks" ;;
      "pr merge 123"*" --auto"*) out="$out,merge:auto" ;;
      "pr merge 123"*" --admin"*) out="$out,merge:admin" ;;
      "pr merge 123"*) out="$out,merge" ;;
      # The two queue mutations before the snapshot query: the dequeue's own
      # payload names mergeQueueEntry, so it would otherwise read as a read.
      "api graphql"*disablePullRequestAutoMerge*) out="$out,disarm" ;;
      "api graphql"*dequeuePullRequest*) out="$out,dequeue" ;;
      "api graphql"*mergeQueueEntry*) out="$out,graphql:queue" ;;
      "api graphql"*isInMergeQueue*) out="$out,queue-state" ;;
      "api graphql"*) out="$out,graphql:threads" ;;
      "api user"*) out="$out,user" ;;
      "api repos/{owner}/{repo}/compare/"*) out="$out,compare" ;;
      "api repos/{owner}/{repo}/commits/"*/statuses*) out="$out,gate-status" ;;
      "auth status"*|"repo view"*|"api repos/"*|"pr view 123 --json baseRefName"*) ;;
      *) out="$out,?($line)" ;;
    esac
  done <"$CALL_LOG"
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
  if [[ "$1" == check || "$1" == check-classified ]]; then check_text <"$TMPDIR/stdout"; return; fi
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  sed 's/;/\\;/g' "$TMPDIR/stdout" | paste -s -d ';' -
}
err_lines() {
  # The sandbox's own path is per-run, so a row that pins a child's diagnostic
  # pins <tmp> rather than a directory no second run produces.
  sed -e 's/^[[:space:]]*//' -e '/^$/d' -e 's/;/\\;/g' -e "s|$TMPDIR|<tmp>|g" "$TMPDIR/stderr" | paste -s -d ';' -
}

run() {
  local rc=0
  local -a argv
  while IFS= read -r line; do argv+=("$line"); done < <(argv_for "$1")
  # Every token name and GH_REPO come off: a row pins whole stderr lines and
  # the token each call saw, so a lane's own environment would decide them.
  # The class policy is assigned empty unless the row's W_ENV assigns it.
  (cd "$REPO" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    -u ORCH_ADMIN_MERGE_GH_CONFIG_DIR -u ORCH_ADMIN_MERGE_CLASSES -u GH_CONFIG_DIR \
    -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u REVIEW_GATE_CONTEXT \
    -u REVIEW_GATE_SETTINGS_FILE REVIEW_GATE_CLASS_POLICY= \
    STUB_CALL_LOG="$CALL_LOG" STUB_AUTH_LOG="$AUTH_LOG" STUB_QUEUE_CLEARED_FILE="$QUEUE_CLEARED" \
    CHECKOUT_ENV_LOG="$CHECKOUT_ENV_LOG" \
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
    hint-threads) printf 'Resolve the review-thread gate and retry. Use --force or --admin only after an explicit decision to override it.' ;;
    # git's own words for a fetch in a repository with no origin, replayed
    # under this command's fixed line. Pinned here, in one place, because the
    # point of the row is that git's account survives rather than being
    # flattened into one sentence; a git that rewords this moves this macro.
    fetch-no-origin) printf "pr-merge: the class-policy range is not in this checkout and the fetch of its two commits from origin failed:;fatal: 'origin' does not appear to be a git repository;fatal: Could not read from remote repository.;Please make sure you have the correct access rights;and the repository exists." ;;
    hint-auto) printf 'Use --auto to queue for auto-merge, or --force after an explicit decision to override safety checks.' ;;
    hint-await) printf 'Hint: github.sh await-mergeable 123 && retry' ;;
    volatile) printf 'NOTE: queue/auto-merge state is VOLATILE — an ejection or a failed protection check disarms it silently\\; follow orch merge-pr.md § 5 for PR #123;Block on .agents/skills/orch/scripts/queue-wait 123 --json once, with a poll interval and budget sized as orch merge-pr.md § 5 step 1 does\\; route its verdict by that same step, and never re-arm an unrecognized verdict. The fleet reducer is .agents/skills/review-gate/scripts/pr-watch.sh with GH_REPO set to the repository (not resolvable locally here)\\; repair what the cause names before re-arming with .agents/skills/github/scripts/github.sh pr-merge 123 --auto' ;;
    merge-failed) printf 'BLOCKED PR #123 — gh pr merge failed' ;;
    no-token) printf 'Warning: GH_BOT_TOKEN not configured, using current user' ;;
    admin-skip) printf '⚠ current-user admin mode: Skipping safety checks' ;;
    override-skip) printf '⚠ override: Skipping safety checks' ;;
    closed) printf 'CLOSED (not merged) PR #123;No merge attempted, none queued. Reopen the PR or supersede it.' ;;
    threads:*) printf 'unresolved_threads: %s actionable thread(s) need attention' "${1#threads:}" ;;
    fetch-failed) printf 'review_threads_fetch_failed: Failed to fetch actionable review threads from GitHub' ;;
    malformed) printf 'review_threads_fetch_failed: GitHub returned malformed review thread data' ;;
    arm-remedy) printf 'Nothing mutated. Enable auto-merge and a required status check or review rule on the base branch, or merge through orch merge-pr with the explicit consumer-only answer under submit-pr.md § 6.2.' ;;
    *) printf 'UNKNOWN-MACRO:%s' "$1" ;;
  esac
}
err_text() {
  local text="$1" name
  while [[ "$text" =~ \{([a-z0-9:-]+)\} ]]; do
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
# Its extra call: with a thread open, an active policy reads the pull request's
# own endpoints once. A clean PR asks nothing and the trace is unchanged.
CHECK_POLICY="view:state,view:mergeable,checks,graphql:threads,view:policy-range,view:reviews"
PRE="view:state,view:mergeable,checks,graphql:threads,view:reviews,view:head"
OPEN="state=OPEN mergeable=MERGEABLE at=-"

run_table "the readiness check" "\
pending checks block, transiently, one issue naming each|checks:pending2 checks-exit:8|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a failed check blocks permanently|checks:failed|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Lint (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a red check the base branch does not require blocks nothing and is named as a warning|checks:optional-red required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a red required context still blocks|checks:optional-red required:CodeQL|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a base that requires no context counts every check|checks:optional-red repo:no-rule|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a classic protection context supplies the required set too|checks:optional-red classic:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
the legacy classic contexts array supplies it as well as checks[]|checks:optional-red classic-contexts:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset rule that gates on no check keeps the required set readable|checks:optional-red rule-type:pull_request|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a required-workflows rule gates on a check it never names, so every check counts|checks:optional-red rule-type:workflows|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a code-scanning rule is the same unnameable gate|checks:optional-red rule-type:code_scanning|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a Copilot review rule demands a review, not a check, so the required set stands|checks:optional-red rule-type:copilot_code_review|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset read that errors discards the contexts classic protection did supply|checks:optional-red classic:Lint rules:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a branch-protection read that errors discards the contexts the ruleset did supply|checks:optional-red required:Lint branch:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a required context that registered no check is pending, never a pass|checks:unregistered required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[ci_optional_failed: CodeQL (FAILURE)]|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup with a required context is pending, not unconfigured|checks:none required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup on a base that requires nothing stays unconfigured|checks:none|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_unconfigured: No status checks configured]|mergeable;head-run: none|calls=$CHECK auth=<unset>
an optional check still running blocks nothing either|checks:optional-pending checks-exit:8 required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a branch answer carrying no protection object is unreadable, so every check counts|checks:optional-red required:Lint repo:no-protection|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
pending and failed together are not transient, both named|checks:mixed checks-exit:8|check|0|merge=false transient=false $OPEN runs=- issues=[ci_pending: Unit Tests (IN_PROGRESS);ci_failed: Lint (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
success and skipped checks merge with no issue|checks:pass-skip|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a superseded run's cancelled jobs are not failures: only the current run's pending check blocks, transiently|checks:superseded-pending checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099680623 issues=[ci_pending: Changes (IN_PROGRESS)] warnings=[]|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a job the current run re-created and passed is not blocked by the old run's cancelled copy|checks:superseded-replaced|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[]|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
the current run's own cancellation is a failure|checks:current-cancel checks-exit:8|check|0|merge=false transient=false $OPEN runs=29099680623 issues=[ci_failed: Integration (CANCELLED)] warnings=[]|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a clean run: the verdict is mergeable and head-run names the scoped run|checks:clean-run|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[]|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
a commit status with no workflow supplies its own run id|checks:status-only checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099700000 issues=[ci_pending: CI Required (PENDING)] warnings=[]|blocked;head-run: 29099700000|calls=$CHECK auth=<unset>
an actionable unresolved thread blocks permanently, never a warning|checks:ci-required threads:actionable|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a class the policy sends for review keeps the thread gate|checks:ci-required threads:actionable class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the policy waives keeps the count and gates nothing with it|checks:ci-required threads:actionable class-policy:render|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[unresolved_threads_waived: 1 actionable thread(s) open, waived by the review gate's class policy for this change]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class policy the classifier cannot answer blocks rather than waive, and the owner's own diagnostic reaches stderr|checks:ci-required threads:actionable class-policy:-|check-classified|0|merge=false transient=false $OPEN runs=- issues=[review_policy_unreadable: The review gate's class policy could not be resolved for this pull request;unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|review-gate-error=policy-classifier-call value=<tmp>/tree/skills/review-gate/scripts/../../harness-ci/scripts/change-class;review-policy: the harness-ci change classifier could not answer;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the classifier did not measure blocks rather than waive, whatever it named|checks:ci-required threads:actionable class-policy:unmeasured|check-classified|0|merge=false transient=false $OPEN runs=- issues=[review_policy_unreadable: The review gate's class policy could not be resolved for this pull request;unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|class: class=render measured=false cause=stub;review-gate-error=policy-unmeasured value=cause=stub;review-policy: the change classifier fell back to standard instead of measuring a class;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a range naming a commit this checkout lacks blocks rather than waive|checks:ci-required threads:actionable class-policy:range-absent|check-classified|0|merge=false transient=false $OPEN runs=- issues=[review_policy_unreadable: The review gate's class policy could not be resolved for this pull request;unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|{fetch-no-origin};blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an unreadable pull request range blocks rather than waive|checks:ci-required threads:actionable class-policy:range-fail|check-classified|0|merge=false transient=false $OPEN runs=- issues=[review_policy_unreadable: The review gate's class policy could not be resolved for this pull request;unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an outdated unresolved thread is not actionable|checks:ci-required threads:outdated|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a malformed thread state blocks at the trust boundary|checks:ci-required threads:malformed|check|0|merge=false transient=false $OPEN runs=- issues=[review_threads_fetch_failed: GitHub returned malformed review thread data] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a page past ARG_MAX is streamed, not passed as an argument|checks:ci-required threads:large|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
an actionable thread on the second page blocks|checks:ci-required threads:resolved100 threads:page2:actionable|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a merged PR reports its state and timestamp, no issues, no check fetched|state:MERGED merged-at|check|0|merge=false transient=false state=MERGED mergeable=UNKNOWN at=2026-08-15T09:41:12Z runs=- issues=[] warnings=[]|merged;head-run: none|calls=view:state auth=<unset>
a closed PR reports its state, no issues|state:CLOSED|check|0|merge=false transient=false state=CLOSED mergeable=UNKNOWN at=- runs=- issues=[] warnings=[]|closed;head-run: none|calls=view:state auth=<unset>
a missing PR is not_found|pr:missing|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
GitHub's own missing-PR wording is not_found too|state-err:graphql-notfound|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
an auth failure is gh_error with its diagnostic, never not_found|state-err:401|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh: Bad credentials (HTTP 401)] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a rate limit keeps its diagnostic|state-err:ratelimit|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: API rate limit exceeded for user ID 1.] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a silent failure names gh and its exit code|state-err:silent4|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh pr view exited 4 with no diagnostic] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a live PR is still gated on its open thread|checks:ci-required threads:bot|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
"

run_table "the merge path" "\
--auto cannot bypass an actionable thread: no mutation, no queue query|checks:ci-required threads:actionable|auto|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK auth=<unset>
a waived class lets --auto arm past an open thread, with no override flag|checks:ci-required threads:actionable class-policy:render post-entry|auto-classified|75|-|Warnings:;⚠ unresolved_threads_waived: 1 actionable thread(s) open, waived by the review gate's class policy for this change;Warning: GH_BOT_TOKEN not configured, using current user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=view:state,view:mergeable,checks,graphql:threads,view:policy-range,view:reviews,view:head,merge:auto,graphql:queue auth=<unset>
the immediate merge fails closed on it too|checks:ci-required threads:actionable|immediate|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK auth=<unset>
a malformed thread state blocks --auto|checks:ci-required threads:malformed|auto|1|-|{blocked};{permanent};✗ {malformed};{hint-threads}|calls=$CHECK auth=<unset>
a second-page fetch failure blocks --auto|checks:ci-required threads:resolved100 threads:page2-fail|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a malformed second-page cursor blocks --auto|checks:ci-required threads:resolved100 threads:page2-malformed|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a thread lookup failure blocks --auto|checks:ci-required threads:fetch-fail|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=$CHECK auth=<unset>
a failed check without --auto is blocked with the auto hint|checks:failed|immediate|1|-|{blocked};{permanent};✗ ci_failed: Lint (FAILURE);{hint-auto}|calls=$CHECK auth=<unset>
a red optional check does not stop the merge, and is named on the way|checks:optional-red required:Lint post:MERGED merge-commit:merged-oid|immediate|0|-|Warnings:;⚠ ci_optional_failed: CodeQL (FAILURE);{no-token};MERGED PR #123|calls=$PRE,merge,graphql:queue auth=<unset>
--force merges past the thread gate without admin mode|checks:ci-required threads:actionable post:MERGED merge-commit:forced-merge-oid|force|0|-|{override-skip};{no-token};MERGED PR #123|calls=view:state,view:head,merge,graphql:queue auth=<unset>
--admin merges past it in current-user mode, naming the mode|checks:ci-required threads:actionable post:MERGED merge-commit:admin-merge-oid|admin|0|-|{admin-skip};MERGED PR #123|calls=view:state,view:head,merge:admin,graphql:queue auth=<unset>
the admin dry run names the mode and mutates nothing|checks:ci-required|admin-dry|0|Would merge PR #123 (--squash, mode=immediate, delete_branch=false, token=current-user admin mode)|{admin-skip}|calls=view:state auth=<unset>
--admin clears the caller's own token before every call, without the router's help|checks:ci-required post:MERGED merge-commit:admin-merge-oid env:GH_TOKEN=ghp_user|admin|0|-|{admin-skip};MERGED PR #123|calls=view:state,view:head,merge:admin,graphql:queue auth=<unset>
the admin router clears the caller's token and never promotes the bot's|checks:ci-required post:MERGED merge-commit:admin-merge-oid env:GH_TOKEN=ghp_user env:GH_BOT_TOKEN=ghp_test_token|router:--admin|0|-|{admin-skip};MERGED PR #123|calls=view:state,view:head,merge:admin,graphql:queue auth=<unset>
the non-admin router promotes the bot token for the mutation and the snapshot|checks:ci-required require-token post:MERGED merge-commit:forced-merge-oid env:GH_BOT_TOKEN=ghp_test_token|router:--force|0|-|{override-skip};Using GH_BOT_TOKEN as stub-user;MERGED PR #123|calls=user,view:state,view:head,user,merge,graphql:queue auth=ghp_test_token
a prepared head that drifted fails before arming|checks:ci-required head:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|expected:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|1|-|BLOCKED PR #123 — prepared head changed before merge attempt (expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, actual=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)|calls=$PRE auth=<unset>
an active queue entry after --auto is success-pending, exit 75, volatile|checks:ci-required head:28132e9b990a595417f79f4e213b4e984bf676fd post-entry require-token env:GH_BOT_TOKEN=ghp_test_token|auto|75|-|Using GH_BOT_TOKEN as stub-user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,user,merge:auto,graphql:queue auth=<unset>+ghp_test_token
--auto refuses where auto-merge is off: nothing mutated|checks:ci-required repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
--auto refuses where the base branch has no required check or review rule|checks:ci-required repo:no-rule|auto|1|-|arm: no-merge-gate=required_check repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
the refusal is the first stderr line, ahead of the checks' warnings|checks:none repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
a ruleset pull_request rule alone is a gate: it arms|checks:ci-required post-auto repo:pr-rule|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a classic required check with no ruleset is a gate: it arms|checks:ci-required post-auto repo:classic|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a classic required check stored under checks[] rather than contexts is a gate too|checks:ci-required post-auto classic:Lint|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a base branch with slashes is URL-encoded in the gate reads and arms|checks:ci-required post-auto base:release/foo/bar|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
classic auto-merge is success-pending, exit 75, volatile|checks:ci-required post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
an immediate merge whose snapshot is MERGED exits 0|checks:ci-required post:MERGED merge-commit:merged-oid|auto|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:auto,graphql:queue auth=<unset>
OPEN, unqueued and unarmed after a zero exit is blocked, naming the absent proof|checks:ci-required|auto|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a snapshot on a newer head fails closed|checks:ci-required head:guarded-head post-head:newer-unreviewed-head post-queue|auto|1|-|{no-token};BLOCKED PR #123 — head changed during merge attempt (expected=guarded-head, actual=newer-unreviewed-head)|calls=$PRE,merge:auto,graphql:queue auth=<unset>
the REST fallback keeps classic auto-merge when the queue query fails|checks:ci-required graphql:fail post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue,view:post auth=<unset>
a second --auto on a queued PR: gh's already-queued failure, the snapshot's entry wins|checks:ci-required head:already-queued-head merge-fail:already-queued post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a genuine merge failure with no proof stays blocked with gh's output|checks:ci-required merge-fail:policy|auto|1|-|{no-token};{merge-failed};failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$PRE,merge:auto,graphql:queue auth=<unset>
--force and --auto are refused before any call|-|force-auto|1|-|Error: --force/--admin and --auto cannot be combined\\; overrides are immediate-only|calls=- auth=-
a failed CLI is still a success when the exact-head snapshot is MERGED|checks:ci-required merge-fail:transport post:MERGED merge-commit:forced-merge-oid|force|0|-|{override-skip};{no-token};MERGED PR #123|calls=view:state,view:head,merge,graphql:queue auth=<unset>
a failed --force stays blocked when classic auto-merge was already armed|checks:ci-required merge-fail:policy post-auto|force|1|-|{override-skip};{no-token};{merge-failed};failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=view:state,view:head,merge,graphql:queue auth=<unset>
a failed --force stays blocked when a queue entry was already active|checks:ci-required merge-fail:queue-required post-queue|force|1|-|{override-skip};{no-token};{merge-failed};failed to run merge: merge queue is required|calls=view:state,view:head,merge,graphql:queue auth=<unset>
"

run_table "the terminal states" "\
--auto on a merged PR exits 0 with the timestamp: no check, no thread, no mutation|state:MERGED merged-at threads:bot|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
the immediate merge on a merged PR|state:MERGED merged-at|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
--force on a merged PR|state:MERGED merged-at|force|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
no mergedAt: the bare line|state:MERGED|auto|0|-|ALREADY MERGED PR #123|calls=view:state auth=<unset>
a closed PR is a distinct refusal, exit 1|state:CLOSED threads:bot|auto|1|-|{closed}|calls=view:state auth=<unset>
a failed state lookup blocks the merge with its real cause|state-err:401|immediate|1|-|{blocked};{permanent};✗ gh_error: gh: Bad credentials (HTTP 401);{hint-auto}|calls=view:state,view:state auth=<unset>
a state resolved only on the retry still short-circuits --auto, the lookup retried not cached|state:MERGED merged-at state-err:once|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
a closed PR found on the retry keeps its line|state:CLOSED state-err:once|auto|1|-|{closed}|calls=view:state,view:state auth=<unset>
the immediate mode on a retry-resolved state|state:MERGED merged-at state-err:once|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
an open PR still merges, its state read once|checks:ci-required post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge,graphql:queue auth=<unset>
GH_TOKEN alone is named with the installation it acts as, and no current-user warning|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghs_INSTALL|immediate|0|-|Using GH_TOKEN as GitHub App installation;MERGED PR #123|calls=$PRE,user,merge,graphql:queue auth=ghs_INSTALL
a token whose user lookup fails any other way is named unverified, and the merge still runs|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghp_REVOKED|immediate|0|-|Using GH_TOKEN as unverified;MERGED PR #123|calls=$PRE,user,merge,graphql:queue auth=ghp_REVOKED
"

# --- the admin-credential route -----------------------------------------------
# The record line on stdout is the caller's fleet-log and `## Merge decision`
# entry, so each row pins it whole. The must-fail inverse of the checks
# precondition is the merge-path row "--admin merges past it in current-user
# mode": the unpatched override merges the same PR with its thread open.
REC="admin-merge"
ADMIN_PRE="view:state,view:head"
ADMIN_CHECK="view:mergeable,checks,graphql:threads,view:reviews"
ADMIN_MERGE_CALLS="compare,queue-state,view:head,view:base,merge:admin,graphql:queue"
# The readiness check with an open thread and an active class policy: the
# policy owner is asked, so the range read joins the trace.
ADMIN_CHECK_POLICY="view:mergeable,checks,graphql:threads,view:policy-range,view:reviews"
EXCL="Error: --admin-credential checks every merge condition and merges immediately\\; it cannot be combined with --check, --auto, --force, --admin or --dry-run"

run_table "the admin-credential route" "\
the route is off where no config directory is set: nothing is read at all|checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=off class=- head-match=- review-mode=- review=- checks=- base=- dequeue=- reason=route-off|REFUSED PR #123 — the admin-credential route is off: ORCH_ADMIN_MERGE_GH_CONFIG_DIR is empty;Nothing dequeued, nothing merged.|calls=- auth=-
a config directory that is not one is not the control host|admin-dir:missing checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=off class=- head-match=- review-mode=- review=- checks=- base=- dequeue=- reason=no-config-dir|REFUSED PR #123 — ORCH_ADMIN_MERGE_GH_CONFIG_DIR is not a directory here, so this is not the control host;Nothing dequeued, nothing merged.|calls=- auth=-
a head that moved refuses before the base, the checks and any mutation|admin-dir checks:ci-required head:$BHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=- head-match=moved review-mode=- review=- checks=- base=- dequeue=- reason=head-moved|REFUSED PR #123 — the head moved (expected=$AHEAD, actual=$BHEAD);Nothing dequeued, nothing merged.|calls=view:state,view:head auth=<unset>
a green unqueued PR merges as the owner credential, nothing to dequeue|admin-dir checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid env:GH_TOKEN=ghp_user|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a green queued PR is dequeued first, then merged|admin-dir checks:ci-required head:$AHEAD admin-queue post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=done|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue,queue-state,view:head,view:base,$ADMIN_CHECK,merge:admin,graphql:queue auth=<unset>
an armed PR is disarmed before it is dequeued|admin-dir checks:ci-required head:$AHEAD admin-queue admin-auto post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=done|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,dequeue,queue-state,view:head,view:base,$ADMIN_CHECK,merge:admin,graphql:queue auth=<unset>
the review gate is met and every required context green merges|admin-dir checks:ci-required head:$AHEAD required:CI+Required post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a PR under review-required with no approval refuses, from GitHub's reviewDecision|admin-dir checks:ci-required head:$AHEAD review:REVIEW_REQUIRED|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
approval mode with an empty reviewDecision and no approving review refuses on the not_approved warning|admin-dir checks:ci-required head:$AHEAD review:none|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: not_approved: Review status is '';Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
approval mode with an empty reviewDecision and one approving review merges|admin-dir checks:ci-required head:$AHEAD review:none+approved post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
review-required with one approval present still refuses, not inferred from the warning|admin-dir checks:ci-required head:$AHEAD review-partial|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
review mode reads the gate context out of the checkout's settings library, which is handed no credential|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:success post:MERGED merge-commit:admin-merge-oid|admin-credential-classified:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=ok checks=ok base=fresh dequeue=none|Warnings:;⚠ not_approved: Review status is '';MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status,$ADMIN_MERGE_CALLS auth=<unset>
review mode judges the review-gate status on this head, not an approval GitHub never required|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:success post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=ok checks=ok base=fresh dequeue=none|Warnings:;⚠ not_approved: Review status is '';MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status,$ADMIN_MERGE_CALLS auth=<unset>
review mode refuses a pending gate status, naming the context and the state|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:pending|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: the 'Review gate' status on this head is pending;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
review mode refuses a failure gate status, naming the context and the state|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:failure|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: the 'Review gate' status on this head is failure;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
a head carrying no gate status at all refuses: an unwritten gate is never a met one|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:absent|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: the 'Review gate' status on this head is absent;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
the context is REVIEW_GATE_CONTEXT, so a renamed gate is read under its new name and the shipped default is not|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-context:Renamed+gate gate-status:success|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: the 'Renamed gate' status on this head is absent;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
an empty REVIEW_GATE_CONTEXT leaves the gate no context to read, so the route refuses before reading any status|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-context: gate-status:success|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=context-unreadable checks=ok base=- dequeue=- reason=review-context-unreadable|REFUSED PR #123 — REVIEW_GATE_CONTEXT could not be resolved, so the review gate has no context to read on this head;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a gate-status read that did not answer refuses: an unread gate is never a met one|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=unreadable checks=ok base=- dequeue=- reason=review-unreadable|REFUSED PR #123 — the head's commit statuses could not be read, so the review gate 'Review gate' is unproven;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
a page that is not a status page is a broken read, never an absent status|admin-dir gate-mode:review review:none checks:ci-required head:$AHEAD gate-status:garbage|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=unreadable checks=ok base=- dequeue=- reason=review-unreadable|REFUSED PR #123 — the head's commit statuses could not be parsed, so the review gate 'Review gate' is unproven;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,gate-status auth=<unset>
review mode still honours a server-side review requirement: a green gate status does not stand in for GitHub's verdict|admin-dir gate-mode:review review:REVIEW_REQUIRED gate-status:success checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=review review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a changes-requested review still blocks in review mode, raised by the readiness check before the mode is read|admin-dir gate-mode:review review:CHANGES_REQUESTED gate-status:success checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=changes_requested base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: changes_requested: Reviewer requested changes;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
off mode accepts an empty reviewDecision and reads no gate status, and the merge lands|admin-dir gate-mode:off review:none checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=off review=ok checks=ok base=fresh dequeue=none|Warnings:;⚠ not_approved: Review status is '';MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
off mode still honours a server-side review requirement: no mode turns GitHub's verdict off|admin-dir gate-mode:off review:REVIEW_REQUIRED checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=off review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
off mode narrows the review gate and nothing else: one actionable thread still refuses|admin-dir gate-mode:off review:none threads:actionable checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=unresolved_threads base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: {threads:1};Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a mode resolver that answers nothing refuses with its own reason, and both children that read the broken file say so|admin-dir gate-mode:unresolvable checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=mode-unreadable checks=ok base=- dequeue=- reason=gate-mode-unreadable|review-gate-error=settings-duplicate value=REVIEW_GATE_MODE;::error::<tmp>/refused.settings.toml: REVIEW_GATE_MODE is assigned more than once in [env] (each key must be unique in the table);review-gate-error=settings-duplicate value=REVIEW_GATE_MODE;::error::<tmp>/refused.settings.toml: REVIEW_GATE_MODE is assigned more than once in [env] (each key must be unique in the table);approval-wait: mode-resolution setting=REVIEW_GATE_MODE;approval-wait: REVIEW_GATE_MODE could not be resolved through the review-gate settings lib (see error above);REFUSED PR #123 — the reviewer-gate mode of the checkout this route runs in could not be resolved, so the review gate cannot be judged;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a tree with no mode resolver beside it refuses the same way, never falling back to a default mode|admin-dir checks:ci-required head:$AHEAD|admin-credential-lone:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=mode-unreadable checks=ok base=- dequeue=- reason=gate-mode-unreadable|REFUSED PR #123 — the reviewer-gate mode of the checkout this route runs in could not be resolved, so the review gate cannot be judged;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
no status checks configured refuses: no required context can be proven green|admin-dir checks:none head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ci_unconfigured base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — no status checks are configured, so no required context can be proven green;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a required context absent from the head rollup refuses, on the one projection|admin-dir checks:ci-required head:$AHEAD required:Absent+Check|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=ci_pending base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_pending: Absent Check (missing);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a check the scoped classification dropped still blocks the admin re-check under an empty required set|admin-dir checks:superseded-abandoned head:$AHEAD repo:no-rule|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=missing-context base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — required context(s) not green on this head: macOS;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
an unreadable protection read still counts the red check, so the readiness check refuses|admin-dir checks:optional-red head:$AHEAD required:Lint branch:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=ci_failed base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_failed: CodeQL (FAILURE);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
an unreadable branch-protection read refuses: an unread list cannot be re-checked|admin-dir checks:ci-required head:$AHEAD branch:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=contexts-unreadable base=- dequeue=- reason=checks-unreadable|REFUSED PR #123 — the base branch's required contexts could not be read;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a branch answer with no protection object is that same unread list|admin-dir checks:ci-required head:$AHEAD repo:no-protection|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=contexts-unreadable base=- dequeue=- reason=checks-unreadable|REFUSED PR #123 — the base branch's required contexts could not be read;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a ruleset allowing only merge and rebase refuses the route's default squash|admin-dir checks:ci-required head:$AHEAD merge-methods:merge+rebase|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=merge-method base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch forbids the merge this route would issue: the pull_request rule allows merge,rebase, not squash;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a ruleset naming squash among its methods merges|admin-dir checks:ci-required head:$AHEAD merge-methods:squash+merge post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
required_linear_history refuses a --merge, whose merge commit it forbids|admin-dir checks:ci-required head:$AHEAD linear-history|admin-credential-merge:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=merge-method base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch forbids the merge this route would issue: required_linear_history forbids the merge commit --merge creates;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a base requiring every conversation resolved refuses on an outdated thread the readiness gate lets pass|admin-dir checks:ci-required head:$AHEAD thread-resolution threads:outdated|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unresolved_threads base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch requires every review conversation resolved, outdated included: 1 unresolved thread(s);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
the same rule with every conversation resolved lets the gate pass and merges|admin-dir checks:ci-required head:$AHEAD thread-resolution threads:resolved100 post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
classic protection requiring every conversation resolved refuses on the outdated thread the readiness gate lets pass|admin-dir checks:ci-required head:$AHEAD protection:conversation threads:outdated|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unresolved_threads base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch requires every review conversation resolved, outdated included: 1 unresolved thread(s);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
the same classic setting with every conversation resolved merges|admin-dir checks:ci-required head:$AHEAD protection:conversation threads:resolved100 post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
classic required_linear_history refuses a --merge just as its ruleset spelling does|admin-dir checks:ci-required head:$AHEAD protection:linear|admin-credential-merge:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=merge-method base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch forbids the merge this route would issue: classic required_linear_history forbids the merge commit --merge creates;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
the same setting permits the route's default squash, which creates no merge commit|admin-dir checks:ci-required head:$AHEAD protection:linear post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a classic protection key the route cannot account for refuses, as its ruleset twin does|admin-dir checks:ci-required head:$AHEAD protection:unknown|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: classic protection required_deployments;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a classic protection value whose shape says nothing about being off reads as on|admin-dir checks:ci-required head:$AHEAD protection:unknown-shape|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: classic protection future_gate;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a bare true is on and a bare false is off, and a value that is neither object nor boolean reads as on|admin-dir checks:ci-required head:$AHEAD protection:unknown-values|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: classic protection future_flag,classic protection future_gate;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
every setting the route re-checks elsewhere, that removes the bypass, or that cannot hold a merge is skipped, and an off key is off|admin-dir checks:ci-required head:$AHEAD protection:inert post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
the three settings gating who may write the base branch refuse, each named, with no merge issued|admin-dir checks:ci-required head:$AHEAD protection:held|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: classic protection lock_branch,classic protection required_signatures,classic protection restrictions;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a protection read that failed some other way refuses: an unread gate is never bypassed|admin-dir checks:ci-required head:$AHEAD protection:read-fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=protection-unreadable base=- dequeue=- reason=checks-unreadable|REFUSED PR #123 — the base branch's classic protection settings could not be read;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
an unhandled ruleset gate type refuses: --admin must not bypass what it cannot read|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,required_deployments|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: required_deployments;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a ruleset update rule refuses: it holds the very ref update the merge performs|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,update|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has gate type(s) the route does not handle: update;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a Copilot review rule requests a review and holds no merge, so it is merged past|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,copilot_code_review post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a required merge queue is the one the route dequeues from, so it is merged past|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,merge_queue post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
the ref-shape rules that cannot hold a PR merge are still merged past|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,creation,deletion,non_fast_forward post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
one unresolved thread refuses with nothing dequeued and nothing merged|admin-dir checks:ci-required threads:actionable head:$AHEAD admin-queue|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=unresolved_threads base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: {threads:1};Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a failed check refuses the same way|admin-dir checks:failed head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=- review=- checks=ci_failed base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_failed: Lint (FAILURE);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a head behind its base refuses: the merge never lands an unrebased branch|admin-dir checks:ci-required head:$AHEAD behind:2|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=behind=2 dequeue=- reason=base-stale|REFUSED PR #123 — the head is 2 commit(s) behind main;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare auth=<unset>
an unreadable compare is unproven containment, never fresh|admin-dir checks:ci-required head:$AHEAD compare:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=unreadable dequeue=- reason=base-unreadable|REFUSED PR #123 — the compare endpoint did not answer, so base containment is unproven;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare auth=<unset>
an unreadable base head refuses before the class and the checks|admin-dir checks:ci-required head:$AHEAD base-oid:-|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=- head-match=ok review-mode=- review=- checks=- base=unreadable dequeue=- reason=base-unreadable|REFUSED PR #123 — the base branch head could not be resolved;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
an open thread a waiving class policy waives still merges, and no child of the route saw the credential directory|admin-dir class-policy:render threads:actionable checks:ci-required post:MERGED merge-commit:admin-merge-oid|admin-credential-classified:$RANGE_HEAD|0|$REC merged pr=123 head=$RANGE_HEAD route=on class=any head-match=ok review-mode=exempt review=ok checks=ok base=fresh dequeue=none|Warnings:;⚠ unresolved_threads_waived: 1 actionable thread(s) open, waived by the review gate's class policy for this change;MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK_POLICY,$ADMIN_MERGE_CALLS auth=<unset>
a class inside the list merges, the class read from the classifier alone|admin-dir admin-classes:render,trivial class:render checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid|admin-credential-classified:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=render head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a class outside the list refuses before the checks|admin-dir admin-classes:render,trivial class:standard checks:ci-required head:$AHEAD|admin-credential-classified:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=standard head-match=ok review-mode=- review=- checks=- base=- dequeue=- reason=class-not-allowed|REFUSED PR #123 — class standard is outside ORCH_ADMIN_MERGE_CLASSES=render,trivial;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a space-separated list is the same list|admin-dir admin-classes:render+trivial class:trivial checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid|admin-credential-classified:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=trivial head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a classifier that answers nothing refuses, never assumes a class|admin-dir admin-classes:render checks:ci-required head:$AHEAD|admin-credential-classified:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=unreadable head-match=ok review-mode=- review=- checks=- base=- dequeue=- reason=class-unreadable|REFUSED PR #123 — ORCH_ADMIN_MERGE_CLASSES is set and no change classifier answered;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a bare-word answer is the old shape and is not a class the route can read|admin-dir admin-classes:render class-bare:render checks:ci-required head:$AHEAD|admin-credential-classified:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=unreadable head-match=ok review-mode=- review=- checks=- base=- dequeue=- reason=class-unreadable|class: class=render measured=true cause=stub;REFUSED PR #123 — ORCH_ADMIN_MERGE_CLASSES is set and no change classifier answered;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a refused dequeue leaves the PR queued and merges nothing|admin-dir checks:ci-required head:$AHEAD admin-queue dequeue:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=failed reason=dequeue-failed|REFUSED PR #123 — dequeuePullRequest failed;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue auth=<unset>
a disarm that lands but a dequeue that fails is recorded disarmed, not untouched|admin-dir checks:ci-required head:$AHEAD admin-queue admin-auto dequeue:only-fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=disarmed reason=dequeue-failed|REFUSED PR #123 — dequeuePullRequest failed;Auto-merge was disarmed, but the PR was not dequeued and not merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,dequeue auth=<unset>
an armed-but-unqueued PR is disarmed then merged, recorded disarmed not done|admin-dir checks:ci-required head:$AHEAD admin-auto post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=disarmed|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,queue-state,view:head,view:base,$ADMIN_CHECK,merge:admin,graphql:queue auth=<unset>
a thread opened while the dequeue ran refuses: --admin would bypass it|admin-dir checks:ci-required head:$AHEAD admin-queue threads-after-dequeue:actionable|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=unresolved_threads base=fresh dequeue=done reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: {threads:1};The PR was dequeued but not merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue,queue-state,view:head,view:base,$ADMIN_CHECK auth=<unset>
a dequeue that succeeds then an unreadable re-read refuses naming the dequeue|admin-dir checks:ci-required head:$AHEAD admin-queue reread-fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=done reason=dequeue-failed|REFUSED PR #123 — the merge-queue state could not be re-read after the dequeue;The PR was dequeued but not merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue,queue-state auth=<unset>
a queued PR with no node id is an unreadable queue, not a dequeue target|admin-dir checks:ci-required head:$AHEAD admin-queue admin-node:-|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=unreadable reason=queue-unreadable|REFUSED PR #123 — the PR's merge-queue state could not be read;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state auth=<unset>
a queue-state read carrying errors beside data is unreadable, so nothing is dequeued and nothing merged|admin-dir checks:ci-required head:$AHEAD queue-partial|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=unreadable reason=queue-unreadable|REFUSED PR #123 — the PR's merge-queue state could not be read;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state auth=<unset>
a failed gh pr merge on the open route stays refused, the mutation confirmed not landed|admin-dir checks:ci-required head:$AHEAD merge-fail:policy|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none reason=blocked|BLOCKED PR #123 — gh pr merge failed;failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a post-merge fallback that cannot see the queue is unconfirmed, never a clean refused|admin-dir checks:ci-required head:$AHEAD graphql:fail|admin-credential:$AHEAD|1|$REC unconfirmed pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none reason=merge-outcome-unconfirmed|BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS,view:post auth=<unset>
a post-merge read carrying errors beside data is unconfirmed, never a clean refused|admin-dir checks:ci-required head:$AHEAD post-graphql:partial|admin-credential:$AHEAD|1|$REC unconfirmed pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none reason=merge-outcome-unconfirmed|BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS,view:post auth=<unset>
a merge whose post-state cannot be read is unconfirmed, never a clean refused|admin-dir checks:ci-required head:$AHEAD graphql:fail post-view-fail|admin-credential:$AHEAD|1|$REC unconfirmed pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none reason=merge-outcome-unconfirmed|BLOCKED PR #123 — gh reported success but state=UNKNOWN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,view:head,view:base,merge:admin,graphql:queue,view:post auth=<unset>
a base that advanced after the containment check refuses before the merge|admin-dir checks:ci-required head:$AHEAD base-moved|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=moved dequeue=none reason=base-moved|REFUSED PR #123 — the base advanced after the containment check (checked=base-oid, now=base-oid-moved);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,view:head,view:base auth=<unset>
GitHub enrolling the PR after merge:admin records enrolled and exits 75|admin-dir checks:ci-required head:$AHEAD post-entry|admin-credential:$AHEAD|75|$REC enrolled pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
an already merged PR carries a real head-match, no other condition reached|admin-dir state:MERGED merged-at head:$AHEAD|admin-credential:$AHEAD|0|$REC already-merged pr=123 head=$AHEAD route=on class=- head-match=ok review-mode=- review=- checks=- base=- dequeue=-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:head auth=<unset>
the router promotes no token for --admin-credential, and makes no user call|admin-dir checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid env:GH_BOT_TOKEN=ghp_test_token|router-admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review-mode=approval review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
--admin-credential and --auto are refused before any call|-|admin-credential-auto:$AHEAD|1|-|$EXCL|calls=- auth=-
--admin-credential and --check are refused before any call|-|admin-credential-check:$AHEAD|1|-|$EXCL|calls=- auth=-
--admin-credential and --force are refused before any call|-|admin-credential-force:$AHEAD|1|-|$EXCL|calls=- auth=-
--admin-credential and --admin are refused before any call|-|admin-credential-admin:$AHEAD|1|-|$EXCL|calls=- auth=-
--admin-credential and --dry-run are refused before any call|-|admin-credential-dry:$AHEAD|1|-|$EXCL|calls=- auth=-
--admin-credential without a prepared head is refused before any call|admin-dir|admin-credential-bare|1|-|Error: --admin-credential requires --expected-head|calls=- auth=-
"

# The credential itself never leaves its config directory: every call the route
# makes runs there, with the caller's own tokens cleared.
build admin-dir checks:ci-required "head:$AHEAD" post:MERGED merge-commit:admin-merge-oid env:GH_TOKEN=ghp_user
run "admin-credential:$AHEAD" >/dev/null
echo "=== the admin credential's environment ==="
assert_eq "$(grep -o '|CFG=[^|]*' "$AUTH_LOG" | sort -u | paste -sd, -)" "|CFG=$ADMIN_DIR" \
  "every gh call runs under the admin config directory, and under no other"
assert_eq "$(grep -o '^GH=[^|]*|GITHUB=[^|]*' "$AUTH_LOG" | sort -u | paste -sd, -)" "GH=<unset>|GITHUB=<unset>" \
  "no gh call carries the caller's own token"

# The other side of the same promise, and the one nothing asserted before: the
# gh process gets that directory and checkout code gets none of it. Both
# entries are required present, so a canary that stopped being reached fails
# here rather than passing an empty set.
assert_eq "$(cut -d'|' -f1 <"$CHECKOUT_ENV_LOG" | sort -u | paste -sd, -)" "change-class,settings-lib" \
  "both checkout-code canaries were reached"
assert_eq "$(cut -d'|' -f2 <"$CHECKOUT_ENV_LOG" | sort -u | paste -sd, -)" "CFG=<unset>" \
  "no checkout code ever saw the admin config directory"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
