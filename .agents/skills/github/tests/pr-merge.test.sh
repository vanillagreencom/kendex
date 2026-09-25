#!/usr/bin/env bash
# pr-merge: the --check readiness JSON and its stderr verdict, the
# review-thread gate, the terminal states (a merged or closed PR
# short-circuits every mode, before and after a state lookup that failed
# once), the guarded mutation and its post-call outcomes, the two
# overrides, and the retired merge settings. Its sibling ci-classify-refusal.test.sh and this file both
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
#     post-graphql:partial  the post-merge read answers HTTP 200 with an
#     errors array beside data
#     class-policy:<class|-|range-fail|unmeasured|range-absent>  an active
#     review-gate class policy, and the classifier stub's answer for the
#     pull request's range
#     env:NAME=value  the caller's environment
#   argv   check | auto | immediate | force | admin | admin-dry | force-auto |
#          expected:<sha> (--auto with --expected-head) | router:<flags> |
#          admin-credential (the retired flag) | check-classified |
#          auto-classified (run from the mirror tree whose harness-ci sibling
#          is the classifier stub)
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

# One checkout per project settings source, each planting a retired key the way
# that source spells it. A settings table is exported by the loader and a
# private env file line is not, so a row run from each checkout proves the
# refusal reads the key where that source leaves it.
settings_fixture() { # NAME RELPATH CONTENT
  local dir="$TMPDIR/settings-$1"
  git init -q "$dir"
  git -C "$dir" config maintenance.auto false
  mkdir -p "$(dirname "$dir/$2")"
  printf '%s\n' "$3" >"$dir/$2"
}
settings_fixture toml kendex.settings.toml $'[env]\nORCH_MERGE_BYPASS = "fast-path"'
settings_fixture dot-kendex .kendex/settings.toml $'[env]\nORCH_ADMIN_MERGE_CLASSES = "render"'
settings_fixture env-local .env.local 'ORCH_ADMIN_MERGE_GH_CONFIG_DIR=/home/dev/.config/gh-admin'

# The class policy is asked of review-gate's review-policy beside the scripts
# tree pr-merge runs from, and review-policy resolves the change classifier
# beside itself. So the class-policy rows run pr-merge.sh out of a mirror of
# the scripts tree: real directories holding a symlink per file, with the
# mirror's own harness-ci sibling written as the stub. Production resolution is
# untouched — a run from the real tree still reaches the shipped classifier.
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
for mirrored in github review-gate; do mirror_tree "$MIRROR" "$mirrored"; done

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
# from the caller is caught. With no STUB_CLASS it answers nothing at all,
# which is the unreadable-policy case.
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
printf 'change_class=%s\n' "$STUB_CLASS"
EOF
chmod +x "$MIRROR/skills/harness-ci/scripts/change-class"

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
    # An ACTIVE review-gate class policy. The value is the supported table; `-` leaves the classifier with no class to
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
    auto) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch ;;
    immediate) printf '%s\n' "$PR_MERGE" 123 --keep-branch ;;
    force) printf '%s\n' "$PR_MERGE" 123 --force --keep-branch ;;
    admin) printf '%s\n' "$PR_MERGE" 123 --admin --keep-branch ;;
    admin-dry) printf '%s\n' "$PR_MERGE" 123 --admin --dry-run --keep-branch ;;
    force-auto) printf '%s\n' "$PR_MERGE" 123 --force --auto --keep-branch ;;
    expected:*) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected:}" ;;
    admin-credential) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch ;;
    router-in:*) printf '%s\n' "$GITHUB" -C "$TMPDIR/settings-${1#router-in:}" pr-merge 123 --auto --keep-branch ;;
    router:*) printf '%s\n' "$GITHUB" -C "$REPO" pr-merge 123 "${1#router:}" --keep-branch ;;
    *) echo "UNKNOWN-ARGV: $1" >&2; exit 2 ;;
  esac
}

# Each gh call by kind, in order. The log holds one call per `printf`, so a
# multi-line argv (the threads query) spills over several lines; only a line
# beginning with a gh verb starts a call, the rest are its continuation.
calls() {
  local line out="" kind
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
      "api graphql"*) out="$out,graphql:threads" ;;
      "api user"*) out="$out,user" ;;
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
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  if [[ "$1" == check || "$1" == check-classified ]]; then check_text <"$TMPDIR/stdout"; return; fi
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
  # The retired merge settings come off too, so only a row's own env: word
  # sets one.
  (cd "$RUN_DIR" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u KENDEX_ENV_FILE \
    -u ORCH_ADMIN_MERGE_GH_CONFIG_DIR -u ORCH_ADMIN_MERGE_CLASSES -u ORCH_MERGE_BYPASS -u GH_CONFIG_DIR \
    -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u REVIEW_GATE_CONTEXT \
    -u REVIEW_GATE_SETTINGS_FILE -u REVIEW_GATE_CLASS_POLICY \
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
    retired:*) printf 'The overseer'"'"'s admin merge and the ORCH_MERGE_BYPASS fast path are retired (kendex decision D003): every merge goes through the merge queue, armed with --auto.;Remove %s from kendex.settings.toml [env], .kendex/settings.toml [env], the private env file (.env.local unless KENDEX_ENV_FILE names another) and the environment, then retry.' "$(printf '%s' "${1#retired:}" | tr '+' ' ')" ;;
    arm-remedy) printf 'Nothing mutated. Enable auto-merge and a required status check or review rule on the base branch, or merge through orch merge-pr with the explicit consumer-only answer under submit-pr.md § 6.2.' ;;
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

# No path merges past the merge queue. On a base that requires one, the lane's
# routes pass no --admin and GitHub enrolls the PR, so the only merge they can
# cause is the queue's own. The must-fail inverse is an unconditional --admin
# on the command: each row's trace then names merge:admin and reds. The retired
# settings refuse every mode before the first GitHub call; the inverse is every
# other row in this file, which runs with all three keys unset and reaches gh.
run_table "the merge queue and the retired settings" "\
on a queue base the immediate merge enrolls the PR and passes no --admin|checks:ci-required post-queue|immediate|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge,graphql:queue auth=<unset>
on a queue base --auto enrolls the PR and passes no --admin|checks:ci-required post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
on a queue base --force skips the checks but not the queue|checks:ci-required post-queue|force|75|-|{override-skip};{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=view:state,view:head,merge,graphql:queue auth=<unset>
a partial post-merge answer is no outcome: the pr-view fallback decides|checks:ci-required post-graphql:partial post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue,view:post auth=<unset>
the admin-credential verb is gone: an unknown option, refused before any call|-|admin-credential|1|-|Error: Unknown option: --admin-credential|calls=- auth=-
a set ORCH_ADMIN_MERGE_GH_CONFIG_DIR refuses before any call|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_ADMIN_MERGE_GH_CONFIG_DIR=/home/dev/.config/gh-admin|immediate|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
a set ORCH_ADMIN_MERGE_CLASSES refuses before any call|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_ADMIN_MERGE_CLASSES=render|immediate|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
a set ORCH_MERGE_BYPASS refuses --auto before any call|checks:ci-required post-queue env:ORCH_MERGE_BYPASS=fast-path|auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key set to the empty string is still set, and --check refuses too|checks:ci-required env:ORCH_MERGE_BYPASS=|check|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
two keys set name each on its own first line|checks:ci-required env:ORCH_ADMIN_MERGE_CLASSES= env:ORCH_MERGE_BYPASS=off|force|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_ADMIN_MERGE_CLASSES+ORCH_MERGE_BYPASS}|calls=- auth=-
the router refuses a set key the same way|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_MERGE_BYPASS=off|router:--auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in kendex.settings.toml [env] refuses the direct call|checks:ci-required post-queue cwd:toml|auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in .kendex/settings.toml [env] refuses the direct call|checks:ci-required post-queue cwd:dot-kendex|auto|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
an unexported .env.local line refuses the direct call|checks:ci-required post-queue cwd:env-local|auto|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
a key in kendex.settings.toml [env] refuses through the router|checks:ci-required post-queue|router-in:toml|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in .kendex/settings.toml [env] refuses through the router|checks:ci-required post-queue|router-in:dot-kendex|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
an unexported .env.local line refuses through the router, which sources it without exporting it|checks:ci-required post-queue|router-in:env-local|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
