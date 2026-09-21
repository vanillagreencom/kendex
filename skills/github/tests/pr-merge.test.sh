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
#     class:<verdict>  the change classifier's answer; absent, it answers none
#     behind:<n>  commits the base has that the head lacks; compare:fail
#     admin-queue, admin-auto  the PR is queued / auto-merge armed
#     admin-node:-  GitHub returns no node id for it
#     dequeue:fail  the queue mutations are refused
#     env:NAME=value  the caller's environment
#   argv   check | auto | immediate | force | admin | admin-dry | force-auto |
#          expected:<sha> (--auto with --expected-head) | router:<flags> |
#          admin-credential:<sha> | admin-credential-auto:<sha> |
#          admin-credential-bare
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

# The admin-credential route's own world: a gh config directory that exists on
# this "control host", a 40-character head for --expected-head, and a change
# classifier on PATH whose verdict a row supplies. With no verdict it exits
# nonzero, which is the route's no-classifier case.
ADMIN_DIR="$TMPDIR/gh-admin"
mkdir -p "$ADMIN_DIR"
AHEAD=1111111111111111111111111111111111111111
BHEAD=2222222222222222222222222222222222222222
cat >"$TMPDIR/bin/change-class" <<'EOF'
#!/usr/bin/env bash
# The route must pass --base and --head with the resolved base and expected
# head; a call missing either flag or carrying the wrong SHA fails instead of
# echoing a class, so dropping them from the caller is caught.
[[ -n "${STUB_CLASS:-}" ]] || exit 1
base="" head="" prev=""
for a in "$@"; do
  case "$prev" in --base) base="$a" ;; --head) head="$a" ;; esac
  prev="$a"
done
[[ "$base" == "${STUB_EXPECT_BASE:-base-oid}" ]] || { echo "change-class: bad --base '$base'" >&2; exit 3; }
[[ "$head" == "${STUB_EXPECT_HEAD:?STUB_EXPECT_HEAD unset}" ]] || { echo "change-class: bad --head '$head'" >&2; exit 3; }
printf '%s\n' "$STUB_CLASS"
EOF
chmod +x "$TMPDIR/bin/change-class"
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
    review:*) W_ENV+=("STUB_REVIEW_DECISION=$v" "STUB_REVIEW_LATEST=[]") ;;
    review-partial) W_ENV+=("STUB_REVIEW_DECISION=REVIEW_REQUIRED" 'STUB_REVIEW_LATEST=[{"state":"APPROVED"}]') ;;
    ruleset:*) W_ENV+=("STUB_GATE_RULES=$(printf '%s' "$v" | tr ',' '\n' | jq -R -s -c 'split("\n") | map(select(. != "") | {type: .})')") ;;
    reread-fail) W_ENV+=("STUB_REREAD_FAIL=true") ;;
    behind:*) W_ENV+=("STUB_BEHIND_BY=$v") ;;
    compare:fail) W_ENV+=("STUB_COMPARE_FAIL=true") ;;
    base-moved) W_ENV+=("STUB_BASE_MOVED=true") ;;
    admin-queue) W_ENV+=("STUB_ADMIN_IN_QUEUE=true") ;;
    admin-auto) W_ENV+=("STUB_ADMIN_AUTO=true") ;;
    admin-node:-) W_ENV+=("STUB_PR_NODE_ID=") ;;
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
    auto) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch ;;
    immediate) printf '%s\n' "$PR_MERGE" 123 --keep-branch ;;
    force) printf '%s\n' "$PR_MERGE" 123 --force --keep-branch ;;
    admin) printf '%s\n' "$PR_MERGE" 123 --admin --keep-branch ;;
    admin-dry) printf '%s\n' "$PR_MERGE" 123 --admin --dry-run --keep-branch ;;
    force-auto) printf '%s\n' "$PR_MERGE" 123 --force --auto --keep-branch ;;
    expected:*) printf '%s\n' "$PR_MERGE" 123 --auto --keep-branch --expected-head "${1#expected:}" ;;
    admin-credential:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch --expected-head "${1#admin-credential:}" ;;
    admin-credential-auto:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --auto --keep-branch --expected-head "${1#admin-credential-auto:}" ;;
    admin-credential-check:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --check --keep-branch --expected-head "${1#admin-credential-check:}" ;;
    admin-credential-force:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --force --keep-branch --expected-head "${1#admin-credential-force:}" ;;
    admin-credential-admin:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --admin --keep-branch --expected-head "${1#admin-credential-admin:}" ;;
    admin-credential-dry:*) printf '%s\n' "$PR_MERGE" 123 --admin-credential --dry-run --keep-branch --expected-head "${1#admin-credential-dry:}" ;;
    admin-credential-bare) printf '%s\n' "$PR_MERGE" 123 --admin-credential --keep-branch ;;
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
  if [[ "$1" == check ]]; then check_text <"$TMPDIR/stdout"; return; fi
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  sed 's/;/\\;/g' "$TMPDIR/stdout" | paste -s -d ';' -
}
err_lines() {
  sed -e 's/^[[:space:]]*//' -e '/^$/d' -e 's/;/\\;/g' "$TMPDIR/stderr" | paste -s -d ';' -
}

run() {
  local rc=0
  local -a argv
  while IFS= read -r line; do argv+=("$line"); done < <(argv_for "$1")
  # Every token name and GH_REPO come off: a row pins whole stderr lines and
  # the token each call saw, so a lane's own environment would decide them.
  (cd "$REPO" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    -u ORCH_ADMIN_MERGE_GH_CONFIG_DIR -u ORCH_ADMIN_MERGE_CLASSES -u GH_CONFIG_DIR \
    STUB_CALL_LOG="$CALL_LOG" STUB_AUTH_LOG="$AUTH_LOG" STUB_QUEUE_CLEARED_FILE="$QUEUE_CLEARED" \
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
EXCL="Error: --admin-credential checks every merge condition and merges immediately\\; it cannot be combined with --check, --auto, --force, --admin or --dry-run"

run_table "the admin-credential route" "\
the route is off where no config directory is set: nothing is read at all|checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=off class=- head-match=- review=- checks=- base=- dequeue=- reason=route-off|REFUSED PR #123 — the admin-credential route is off: ORCH_ADMIN_MERGE_GH_CONFIG_DIR is empty;Nothing dequeued, nothing merged.|calls=- auth=-
a config directory that is not one is not the control host|admin-dir:missing checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=off class=- head-match=- review=- checks=- base=- dequeue=- reason=no-config-dir|REFUSED PR #123 — ORCH_ADMIN_MERGE_GH_CONFIG_DIR is not a directory here, so this is not the control host;Nothing dequeued, nothing merged.|calls=- auth=-
a head that moved refuses before the base, the checks and any mutation|admin-dir checks:ci-required head:$BHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=- head-match=moved review=- checks=- base=- dequeue=- reason=head-moved|REFUSED PR #123 — the head moved (expected=$AHEAD, actual=$BHEAD);Nothing dequeued, nothing merged.|calls=view:state,view:head auth=<unset>
a green unqueued PR merges as the owner credential, nothing to dequeue|admin-dir checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid env:GH_TOKEN=ghp_user|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a green queued PR is dequeued first, then merged|admin-dir checks:ci-required head:$AHEAD admin-queue post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=done|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue,queue-state,view:head,view:base,merge:admin,graphql:queue auth=<unset>
an armed PR is disarmed before it is dequeued|admin-dir checks:ci-required head:$AHEAD admin-queue admin-auto post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=done|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,dequeue,queue-state,view:head,view:base,merge:admin,graphql:queue auth=<unset>
the review gate is met and every required context green merges|admin-dir checks:ci-required head:$AHEAD required:CI+Required post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a PR under review-required with no approval refuses, from GitHub's reviewDecision|admin-dir checks:ci-required head:$AHEAD review:REVIEW_REQUIRED|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
review-required with one approval present still refuses, not inferred from the warning|admin-dir checks:ci-required head:$AHEAD review-partial|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=required checks=ok base=- dequeue=- reason=review-required|REFUSED PR #123 — the review gate is not met: GitHub reviewDecision is REVIEW_REQUIRED;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
no status checks configured refuses: no required context can be proven green|admin-dir checks:none head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ci_unconfigured base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — no status checks are configured, so no required context can be proven green;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a required context absent from the head rollup refuses, on the one projection|admin-dir checks:ci-required head:$AHEAD required:Absent+Check|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=- checks=ci_pending base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_pending: Absent Check (missing);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a check the scoped classification dropped still blocks the admin re-check under an empty required set|admin-dir checks:superseded-abandoned head:$AHEAD repo:no-rule|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=missing-context base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — required context(s) not green on this head: macOS;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
an unreadable protection read is that same empty set, never a merge over the red check|admin-dir checks:optional-red head:$AHEAD required:Lint branch:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=- checks=ci_failed base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_failed: CodeQL (FAILURE);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
an unhandled ruleset gate type refuses: --admin must not bypass what it cannot read|admin-dir checks:ci-required head:$AHEAD ruleset:required_status_checks,required_deployments|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=unhandled-gate base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the base branch has ruleset gate type(s) the route does not handle: required_deployments;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
one unresolved thread refuses with nothing dequeued and nothing merged|admin-dir checks:ci-required threads:actionable head:$AHEAD admin-queue|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=- checks=unresolved_threads base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: {threads:1};Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a failed check refuses the same way|admin-dir checks:failed head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=- checks=ci_failed base=- dequeue=- reason=checks-unmet|REFUSED PR #123 — the readiness check does not pass: ci_failed: Lint (FAILURE);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK auth=<unset>
a head behind its base refuses: the merge never lands an unrebased branch|admin-dir checks:ci-required head:$AHEAD behind:2|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=behind=2 dequeue=- reason=base-stale|REFUSED PR #123 — the head is 2 commit(s) behind main;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare auth=<unset>
an unreadable compare is unproven containment, never fresh|admin-dir checks:ci-required head:$AHEAD compare:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=unreadable dequeue=- reason=base-unreadable|REFUSED PR #123 — the compare endpoint did not answer, so base containment is unproven;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare auth=<unset>
an unreadable base head refuses before the class and the checks|admin-dir checks:ci-required head:$AHEAD base-oid:-|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=- head-match=ok review=- checks=- base=unreadable dequeue=- reason=base-unreadable|REFUSED PR #123 — the base branch head could not be resolved;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a class inside the list merges, the class read from the classifier alone|admin-dir admin-classes:render,trivial class:render checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=render head-match=ok review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a class outside the list refuses before the checks|admin-dir admin-classes:render,trivial class:standard checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=standard head-match=ok review=- checks=- base=- dequeue=- reason=class-not-allowed|REFUSED PR #123 — class standard is outside ORCH_ADMIN_MERGE_CLASSES=render,trivial;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a space-separated list is the same list|admin-dir admin-classes:render+trivial class:trivial checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=trivial head-match=ok review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a class list with no classifier to answer it refuses, never assumes a class|admin-dir admin-classes:render checks:ci-required head:$AHEAD|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=unreadable head-match=ok review=- checks=- base=- dequeue=- reason=class-unreadable|REFUSED PR #123 — ORCH_ADMIN_MERGE_CLASSES is set and no change classifier answered;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE auth=<unset>
a refused dequeue leaves the PR queued and merges nothing|admin-dir checks:ci-required head:$AHEAD admin-queue dequeue:fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=failed reason=dequeue-failed|REFUSED PR #123 — dequeuePullRequest failed;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue auth=<unset>
a disarm that lands but a dequeue that fails is recorded disarmed, not untouched|admin-dir checks:ci-required head:$AHEAD admin-queue admin-auto dequeue:only-fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=disarmed reason=dequeue-failed|REFUSED PR #123 — dequeuePullRequest failed;Auto-merge was disarmed, but the PR was not dequeued and not merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,dequeue auth=<unset>
an armed-but-unqueued PR is disarmed then merged, recorded disarmed not done|admin-dir checks:ci-required head:$AHEAD admin-auto post:MERGED merge-commit:admin-merge-oid|admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=disarmed|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,disarm,queue-state,view:head,view:base,merge:admin,graphql:queue auth=<unset>
a dequeue that succeeds then an unreadable re-read refuses naming the dequeue|admin-dir checks:ci-required head:$AHEAD admin-queue reread-fail|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=done reason=dequeue-failed|REFUSED PR #123 — the merge-queue state could not be re-read after the dequeue;The PR was dequeued but not merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,dequeue,queue-state auth=<unset>
a queued PR with no node id cannot be dequeued, so it is not merged|admin-dir checks:ci-required head:$AHEAD admin-queue admin-node:-|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=failed reason=dequeue-failed|REFUSED PR #123 — the PR is queued or armed and GitHub returned no node id to dequeue it by;Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state auth=<unset>
a failed gh pr merge on the open route stays refused, the mutation confirmed not landed|admin-dir checks:ci-required head:$AHEAD merge-fail:policy|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none reason=blocked|BLOCKED PR #123 — gh pr merge failed;failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
a merge whose post-state cannot be read is unconfirmed, never a clean refused|admin-dir checks:ci-required head:$AHEAD graphql:fail post-view-fail|admin-credential:$AHEAD|1|$REC unconfirmed pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none reason=merge-outcome-unconfirmed|BLOCKED PR #123 — gh reported success but state=UNKNOWN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,view:head,view:base,merge:admin,graphql:queue,view:post auth=<unset>
a base that advanced after the containment check refuses before the merge|admin-dir checks:ci-required head:$AHEAD base-moved|admin-credential:$AHEAD|1|$REC refused pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=moved dequeue=none reason=base-moved|REFUSED PR #123 — the base advanced after the containment check (checked=base-oid, now=base-oid-moved);Nothing dequeued, nothing merged.|calls=$ADMIN_PRE,$ADMIN_CHECK,compare,queue-state,view:head,view:base auth=<unset>
GitHub enrolling the PR after merge:admin records enrolled and exits 75|admin-dir checks:ci-required head:$AHEAD post-entry|admin-credential:$AHEAD|75|$REC enrolled pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none|QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
an already merged PR carries a real head-match, no other condition reached|admin-dir state:MERGED merged-at head:$AHEAD|admin-credential:$AHEAD|0|$REC already-merged pr=123 head=$AHEAD route=on class=- head-match=ok review=- checks=- base=- dequeue=-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:head auth=<unset>
the router promotes no token for --admin-credential, and makes no user call|admin-dir checks:ci-required head:$AHEAD post:MERGED merge-commit:admin-merge-oid env:GH_BOT_TOKEN=ghp_test_token|router-admin-credential:$AHEAD|0|$REC merged pr=123 head=$AHEAD route=on class=any head-match=ok review=ok checks=ok base=fresh dequeue=none|MERGED PR #123|calls=$ADMIN_PRE,$ADMIN_CHECK,$ADMIN_MERGE_CALLS auth=<unset>
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
