#!/usr/bin/env bash
# pr-timeline: the stamps and CI wall times it reads from one GraphQL
# response, the check-suite and check-run pages it reads past that
# response's first, and its refusal of a connection longer than the page it
# read or still open at its page cap.
#
# Each case stages one response through the shared gh fake and asserts the
# output whole. The world is one merged PR:
#   commits      the first authored at 09:00; the final head committed 10:10
#   force push   10:20, over a head whose gate had passed at 10:05
#   reviews      a user's at 09:30, then a Bot's at 09:40 and 10:30, and the
#                PR author's own, an app's, answering a thread at 10:35
#   gate         the final head's success at 10:25
#   head CI      a pull_request suite 10:20-10:40 and an app suite with no
#                workflow run 10:22-10:45; the merge commit's merge_group
#                suite 11:00-11:15, and a push suite there that is no one's
#   merge flow   auto-merge enabled 10:26 and again 10:50, queued 10:55,
#                merged 11:20
#   head branch  `feature`, whose activity log holds an earlier life of the
#                name (created 08:00, deleted 08:30), then this one: created
#                09:05, a push at 09:50 of a head the force push later
#                rewrote, the final head's push at 10:12, the force push at
#                10:20, and the deletion after the merge at 11:21
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_TIMELINE="$REPO_ROOT/skills/github/scripts/commands/pr-timeline.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# The response, with a jq edit applied for the case: `.` for the world above.
response() {
  jq -cn '
    def t($hm): "2026-09-20T\($hm):00Z";
    def run($name; $s; $e): {name: $name, status: "COMPLETED", conclusion: "SUCCESS", startedAt: t($s), completedAt: t($e),
                             detailsUrl: "https://checks.example/\($name)"};
    def suite($event; $runs): {workflowRun: (if $event == null then null
                                 else {event: $event, url: "https://github.com/owner/repo/actions/runs/\($event | length)00",
                                       workflow: {name: "ci-\($event)"}} end),
                               checkRuns: {pageInfo: {hasNextPage: false}, nodes: $runs}};
    def gate($state; $hm): {status: {context: {state: $state, createdAt: t($hm)}}};
    {data: {repository: {pullRequest: {
      number: 42, state: "MERGED", createdAt: t("09:10"), mergedAt: t("11:20"), author: {login: "lane-app"},
      headRefName: "feature", headRepository: {nameWithOwner: "owner/repo"},
      mergeCommit: {oid: "m1", checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
        suite("merge_group"; [run("test"; "11:00"; "11:15")]), suite("push"; [run("test"; "11:21"; "11:40")])]}},
      firstCommit: {nodes: [{commit: {authoredDate: t("09:00")}}]},
      headCommit: {nodes: [{commit: ({oid: "h2", committedDate: t("10:10")} + gate("SUCCESS"; "10:25")
        + {checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
            suite("pull_request"; [run("lint"; "10:20"; "10:30"), run("test"; "10:21"; "10:40")]),
            suite(null; [run("scan"; "10:22"; "10:45")])]}})}]},
      commits: {totalCount: 1, nodes: [{commit: {oid: "h2", committedDate: t("10:10")}}]},
      reviews: {totalCount: 4, nodes: [
        {submittedAt: t("09:30"), author: {__typename: "User", login: "someone"}},
        {submittedAt: t("09:40"), author: {__typename: "Bot", login: "reviewer"}},
        {submittedAt: t("10:30"), author: {__typename: "Bot", login: "reviewer"}},
        {submittedAt: t("10:35"), author: {__typename: "Bot", login: "lane-app"}}]},
      timelineItems: {pageInfo: {hasNextPage: false}, nodes: [
        {__typename: "HeadRefForcePushedEvent", createdAt: t("10:20"), beforeCommit: {oid: "b1"}},
        {__typename: "AutoMergeEnabledEvent", createdAt: t("10:26")},
        {__typename: "AutoMergeEnabledEvent", createdAt: t("10:50")},
        {__typename: "AddedToMergeQueueEvent", createdAt: t("10:55")}]}
    }}}} | '"$1"
}

# Each head's status history, newest first as the REST endpoint lists it:
# `when:state` pairs for the gate context, beside another context's success
# that never counts. The force-pushed-over head b1 passed at 10:05; the final
# head h2 at 10:25.
status_history() { # PAIRS
  jq -cn --arg pairs "$1" '[($pairs | split(" ")[] | select(. != "") | split(":") as $p
      | {context: "Review gate", state: $p[2], created_at: "2026-09-20T\($p[0]):\($p[1]):00Z"}),
    {context: "CI", state: "success", created_at: "2026-09-20T08:00:00Z"}]'
}
HISTORY_B1="10:05:success"
HISTORY_H2="10:25:success"

# The head branch's activity log, newest first as the REST endpoint lists it:
# `when:type` pairs.
activity_log() { # PAIRS
  jq -cn --arg pairs "$1" '[$pairs | split(" ")[] | select(. != "") | split(":") as $p
    | {timestamp: "2026-09-20T\($p[0]):\($p[1]):00Z", activity_type: $p[2]}]'
}
ACTIVITY="11:21:branch_deletion 10:20:force_push 10:12:push 09:50:push 09:05:branch_creation 08:30:branch_deletion 08:00:branch_creation"
ACTIVITY_PATH="api-repos/owner/repo/activity?ref=refs%2Fheads%2Ffeature&per_page=100"

# The pages past the first, staged by the paging cases; every other case
# stages none. The PR response is staged under a selector its query alone
# carries, so a page the code asks for in such a case is refused rather than
# answered with the PR.
stage_pages() { :; }

BIN="$PR_TIMELINE"
run() { # EDIT [ARGS...]
  local edit="$1" rc=0
  shift
  gh_stub_reset
  gh_stub_answer "api-graphql:pullRequest(number" "$(response "$edit")"
  stage_pages
  gh_stub_answer "api-repos/owner/repo/commits/b1/statuses?per_page=100" "$(status_history "$HISTORY_B1")"
  gh_stub_answer "api-repos/owner/repo/commits/h2/statuses?per_page=100" "$(status_history "$HISTORY_H2")"
  gh_stub_answer "$ACTIVITY_PATH" "$(activity_log "$ACTIVITY")"
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u REVIEW_GATE_CONTEXT \
    bash "$BIN" 42 "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s' "$rc"
}

echo "=== the stamps and wall times of a merged PR ==="
WANT='{"pr":42,"repo":"owner/repo","state":"MERGED","head":"h2","merge_commit":"m1","stamps":{"first_commit":"2026-09-20T09:00:00Z","created":"2026-09-20T09:10:00Z","last_push":"2026-09-20T10:20:00Z","first_bot_review":"2026-09-20T09:40:00Z","first_gate_met":"2026-09-20T10:05:00Z","gate_met":"2026-09-20T10:25:00Z","ci_green":"2026-09-20T10:45:00Z","armed":"2026-09-20T10:50:00Z","queued":"2026-09-20T10:55:00Z","merged":"2026-09-20T11:20:00Z"},"ci_head_secs":1500,"ci_merge_group_secs":900,"open_secs":7800,"bot_reviews":2,"push_times":["2026-09-20T09:05:00Z","2026-09-20T09:50:00Z","2026-09-20T10:12:00Z","2026-09-20T10:20:00Z"],"bot_review_times":["2026-09-20T09:40:00Z","2026-09-20T10:30:00Z"]}'
assert_eq "$(run .) $(cat "$TMP_ROOT/stdout")" "rc=0 $WANT" \
  "the force-pushed-over head's gate is the first pass, the merge group's runs stay out of the head's CI, the author's own review is no bot's, and the pushes are the branch log's for this life of the name"

echo "=== each stamp a PR did not reach is null ==="
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c "$want" "$TMP_ROOT/stdout")" "true" "$label"
done <<'ROWS'
an open PR has no merge, merge-group CI or open time@.data.repository.pullRequest |= (.mergedAt = null | .mergeCommit = null)@[.stamps.merged, .merge_commit, .ci_merge_group_secs, .open_secs] == [null, null, null, null]
a failing head run leaves CI never green, its wall time still read@.data.repository.pullRequest.headCommit.nodes[0].commit.checkSuites.nodes[0].checkRuns.nodes[1].conclusion = "FAILURE"@[.stamps.ci_green, .ci_head_secs] == [null, 1500]
a pending gate is not met@.data.repository.pullRequest.headCommit.nodes[0].commit.status.context.state = "PENDING"@.stamps.gate_met == null
no Bot review leaves the first one null, the count zero and the times empty@.data.repository.pullRequest.reviews.nodes |= map(.author.__typename = "User")@[.stamps.first_bot_review, .bot_reviews, .bot_review_times] == [null, 0, []]
a PR whose author GitHub no longer names counts every Bot review@.data.repository.pullRequest.author = null@[.bot_reviews, .bot_review_times[-1]] == [3, "2026-09-20T10:35:00Z"]
no force push leaves the head's commit date the last push@.data.repository.pullRequest.timelineItems.nodes |= map(select(.__typename != "HeadRefForcePushedEvent"))@[.stamps.last_push, .stamps.first_gate_met] == ["2026-09-20T10:10:00Z", "2026-09-20T10:25:00Z"]
ROWS

echo "=== the pushes are read from the head branch's activity log ==="
while IFS='|' read -r label log edit want; do
  [[ -n "$label" ]] || continue
  ACTIVITY="$log"
  run "$edit" >/dev/null
  assert_eq "$(jq -c '.push_times' "$TMP_ROOT/stdout")" "$want" "$label"
done <<'ROWS'
a log with no deletion yet reads the whole life|10:12:push 09:05:branch_creation|.|["2026-09-20T09:05:00Z","2026-09-20T10:12:00Z"]
a log holding no push of this life leaves the pushes null|11:21:branch_deletion 08:30:branch_deletion 08:00:branch_creation|.|null
a PR whose head repository is gone leaves the pushes null|10:12:push|.data.repository.pullRequest.headRepository = null|null
ROWS
ACTIVITY="11:21:branch_deletion 10:20:force_push 10:12:push 09:50:push 09:05:branch_creation 08:30:branch_deletion 08:00:branch_creation"
run . >/dev/null
assert_eq "$(gh_stub_calls | grep -c 'activity?ref=refs%2Fheads%2Ffeature&per_page=100 --paginate')" "1" \
  "the log is read once, for the head ref, through every page"
gh_stub_reset
gh_stub_answer "api-graphql:pullRequest(number" "$(response .)"
gh_stub_answer "api-repos/owner/repo/commits/b1/statuses?per_page=100" "$(status_history "$HISTORY_B1")"
gh_stub_answer "api-repos/owner/repo/commits/h2/statuses?per_page=100" "$(status_history "$HISTORY_H2")"
gh_stub_fail "$ACTIVITY_PATH" 1 'HTTP 500'
rc=0
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u REVIEW_GATE_CONTEXT \
  bash "$BIN" 42 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
assert_eq "rc=$rc out=$(cat "$TMP_ROOT/stdout")" "rc=1 out=" "an activity log that does not read prints nothing"

echo "=== the first gate pass is read from each head's status history ==="
while IFS='|' read -r label b1 h2 want; do
  [[ -n "$label" ]] || continue
  HISTORY_B1="$b1" HISTORY_H2="$h2"
  run . >/dev/null
  assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout")" "$want" "$label"
done <<'ROWS'
a success, then a failure, then a success on one head: the first success|10:30:pending|10:25:success 10:24:failure 10:02:success|"2026-09-20T10:02:00Z"
a head whose latest gate status is a failure keeps its earlier pass|10:30:pending|10:40:failure 10:15:success|"2026-09-20T10:15:00Z"
no head ever passed|10:30:pending|10:40:failure|null
ROWS
HISTORY_B1="10:05:success" HISTORY_H2="10:25:success"
run . >/dev/null
assert_eq "$(gh_stub_calls | grep 'statuses' | sed 's/^api repos.owner.repo.commits.//' | tr '\n' ';')" \
  "b1/statuses?per_page=100 --paginate;h2/statuses?per_page=100 --paginate;" "each head's history is read once, through every page"
gh_stub_reset
gh_stub_answer api-graphql "$(response .)"
gh_stub_fail "api-repos/owner/repo/commits/b1/statuses?per_page=100" 1 'HTTP 500'
rc=0
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u REVIEW_GATE_CONTEXT \
  bash "$BIN" 42 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
assert_eq "rc=$rc out=$(cat "$TMP_ROOT/stdout")" "rc=1 out=" "a status history that does not read prints nothing"

echo "=== each workflow's current run is the one lib/ci-run-correlation.sh keeps ==="
# A second run of a workflow beside the fixture's own: its suite carries
# another run id, and scope_current_run decides which run's checks count.
# extra_run prints the jq edit that appends it.
extra_run() { # PATH RUNID EVENT CONCLUSION START END
  printf '%s.checkSuites.nodes += [{workflowRun: {event: "%s", url: "https://github.com/owner/repo/actions/runs/%s", workflow: {name: "ci-%s"}}, checkRuns: {pageInfo: {hasNextPage: false}, nodes: [{name: "test", status: "COMPLETED", conclusion: "%s", startedAt: "2026-09-20T%s:00Z", completedAt: "2026-09-20T%s:00Z", detailsUrl: "x"}]}}]' \
    "$1" "$3" "$2" "$3" "$4" "$5" "$6"
}
HEAD_PATH='.data.repository.pullRequest.headCommit.nodes[0].commit'
GROUP_PATH='.data.repository.pullRequest.mergeCommit'
# The fixture's head run is runs/1200 (pull_request) and the group's
# runs/1100 (merge_group); an earlier failed run of each takes a lower id.
STALE_HEAD="$(extra_run "$HEAD_PATH" 5 pull_request FAILURE 10:05 10:06)"
STALE_GROUP="$(extra_run "$GROUP_PATH" 5 merge_group FAILURE 10:57 10:58)"
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" "$want" "$label"
done <<ROWS
a failed run on the head, then a later run that passed: CI green, the later run alone timed@$STALE_HEAD@["2026-09-20T10:45:00Z",1500,900]
a failed run in the merge group, then a later run: the later run alone timed@$STALE_GROUP@["2026-09-20T10:45:00Z",1500,900]
a later all-skipped run keeps the substantive run current@$(extra_run "$HEAD_PATH" 9999 pull_request SKIPPED 10:50 10:51)@["2026-09-20T10:45:00Z",1500,900]
a later run that failed leaves CI never green@$(extra_run "$HEAD_PATH" 9999 pull_request FAILURE 10:46 10:47)@[null,1500,900]
ROWS

echo "=== a connection longer than its page refuses ==="
while IFS='|' read -r connection edit; do
  [[ -n "$connection" ]] || continue
  assert_eq "$(run "$edit") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr")" \
    "rc=1  {\"error\":\"truncated: $connection\"}" "$connection past one page"
done <<'ROWS'
commits|.data.repository.pullRequest.commits.totalCount = 101
reviews|.data.repository.pullRequest.reviews.totalCount = 101
timeline|.data.repository.pullRequest.timelineItems.pageInfo.hasNextPage = true
ROWS

assert_eq "$(run '.data.repository.pullRequest |= (.commits.totalCount = 100 | .reviews.totalCount = 100)') $(jq -c .pr "$TMP_ROOT/stdout")" \
  "rc=0 42" "a hundred commits and reviews fit the page and print"

echo "=== check suites and check runs are read through every page ==="
# The first page of the head's suites filled to 50: the fixture's two plus
# 48 app suites whose one run each sits inside the head's CI span, open at
# cursor c50. The 51st suite, on the second page, ends the head's CI at
# 10:50 in place of 10:45.
FIFTY_SUITES='.data.repository.pullRequest.headCommit.nodes[0].commit.checkSuites |= (
  .nodes += [range(48) | suite(null; [run("fill"; "10:30"; "10:31")])]
  | .pageInfo = {hasNextPage: true, endCursor: "c50"})'
# One page of suites, as a suitesPage query answers it: one app suite holding
# RUNS, its runs open at RUNS_CURSOR when one is given, and its pageInfo.
suites_page() { # RUNS HAS_NEXT CURSOR [RUNS_CURSOR]
  jq -cn --argjson runs "$1" --argjson next "$2" --arg cursor "$3" --arg rcursor "${4:-}" '{data: {repository: {object: {checkSuites: {
    pageInfo: {hasNextPage: $next, endCursor: $cursor},
    nodes: [{id: "S\($cursor)", workflowRun: null,
             checkRuns: {pageInfo: (if $rcursor == "" then {hasNextPage: false} else {hasNextPage: true, endCursor: $rcursor} end), nodes: $runs}}]}}}}}'
}
# One page of check runs, as a runsPage query answers it.
runs_page() { # RUNS HAS_NEXT CURSOR
  jq -cn --argjson runs "$1" --argjson next "$2" --arg cursor "$3" \
    '{data: {node: {checkRuns: {pageInfo: {hasNextPage: $next, endCursor: $cursor}, nodes: $runs}}}}'
}
LATE_HEAD_RUN='[{name: "late", status: "COMPLETED", conclusion: "SUCCESS", startedAt: "2026-09-20T10:46:00Z", completedAt: "2026-09-20T10:50:00Z", detailsUrl: "x"}]'
LATE_GROUP_RUN='[{name: "late", status: "COMPLETED", conclusion: "SUCCESS", startedAt: "2026-09-20T11:16:00Z", completedAt: "2026-09-20T11:30:00Z", detailsUrl: "x"}]'

stage_pages() { gh_stub_answer "api-graphql:query suitesPage" "$(suites_page "$(jq -cn "$LATE_HEAD_RUN")" false null)"; }
run "$FIFTY_SUITES" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" \
  '["2026-09-20T10:50:00Z",1800,900]' "a 51-suite head: the suite on the second page ends its CI"
assert_eq "$(gh_stub_calls | grep -c 'query suitesPage') $(gh_stub_calls | grep -o -- '-f oid=h2 -f cursor=c50')" \
  "1 -f oid=h2 -f cursor=c50" "the second page is asked for once, at the head and the first page's cursor"

# The 51st suite, on the second page, arrives with its runs open at r1: the
# run on its second runs page ends the head's CI at 10:50. The runs walk
# reads the suite list after the suite walk, so a suite past page one is
# walked too.
FILL_RUN='[{name: "fill", status: "COMPLETED", conclusion: "SUCCESS", startedAt: "2026-09-20T10:30:00Z", completedAt: "2026-09-20T10:31:00Z", detailsUrl: "x"}]'
stage_pages() {
  gh_stub_answer "api-graphql:query suitesPage" "$(suites_page "$(jq -cn "$FILL_RUN")" false c51 r1)"
  gh_stub_answer "api-graphql:query runsPage" "$(runs_page "$(jq -cn "$LATE_HEAD_RUN")" false null)"
}
run "$FIFTY_SUITES" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" \
  '["2026-09-20T10:50:00Z",1800,900]' "a second-page suite with runs past its first page: the run on its second runs page ends the head's CI"
assert_eq "$(gh_stub_calls | grep -c 'query runsPage') $(gh_stub_calls | grep -o -- '-f id=Sc51 -f cursor=r1')" \
  "1 -f id=Sc51 -f cursor=r1" "the second-page suite's runs are asked for once, at its id and its first page's cursor"

# The merge group's suite, its runs open at cursor r100 under the id the
# runsPage query takes: the run on the second page ends the group's CI at
# 11:30 in place of 11:15.
OPEN_GROUP_RUNS='.data.repository.pullRequest.mergeCommit.checkSuites.nodes[0] |= (.id = "MG" | .checkRuns.pageInfo = {hasNextPage: true, endCursor: "r100"})'
stage_pages() { gh_stub_answer "api-graphql:query runsPage" "$(runs_page "$(jq -cn "$LATE_GROUP_RUN")" false null)"; }
run "$OPEN_GROUP_RUNS" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" \
  '["2026-09-20T10:45:00Z",1500,1800]' "a suite with runs past its first page: the run on the second page ends its CI"
assert_eq "$(gh_stub_calls | grep -c 'query runsPage') $(gh_stub_calls | grep -o -- '-f id=MG -f cursor=r100')" \
  "1 -f id=MG -f cursor=r100" "the second page is asked for once, at the suite's id and the first page's cursor"

# The merge commit's suites open at cursor c50: the merge_group suite on the
# second page ends the group's CI at 11:30 in place of 11:15.
OPEN_MERGE_SUITES='.data.repository.pullRequest.mergeCommit.checkSuites.pageInfo = {hasNextPage: true, endCursor: "c50"}'
stage_pages() {
  gh_stub_answer "api-graphql:query suitesPage" "$(suites_page "$(jq -cn "$LATE_GROUP_RUN")" false null \
    | jq -c '.data.repository.object.checkSuites.nodes[0].workflowRun = {event: "merge_group", url: "https://github.com/owner/repo/actions/runs/1100", workflow: {name: "ci-merge_group"}}')"
}
run "$OPEN_MERGE_SUITES" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" \
  '["2026-09-20T10:45:00Z",1500,1800]' "a merge commit with suites past its first page: the merge_group suite on the second page ends its CI"
assert_eq "$(gh_stub_calls | grep -c 'query suitesPage') $(gh_stub_calls | grep -o -- '-f oid=m1 -f cursor=c50')" \
  "1 -f oid=m1 -f cursor=c50" "the second page is asked for once, at the merge commit and the first page's cursor"

# Every query on the wire in one run that reads all three: each defines
# exactly the fragments it spreads, which GitHub refuses otherwise and the
# stub never judges.
stage_pages() {
  gh_stub_answer "api-graphql:query suitesPage" "$(suites_page "$(jq -cn "$LATE_HEAD_RUN")" false null)"
  gh_stub_answer "api-graphql:query runsPage" "$(runs_page "$(jq -cn "$LATE_GROUP_RUN")" false null)"
}
run "$FIFTY_SUITES | $OPEN_GROUP_RUNS" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs, .ci_merge_group_secs]' "$TMP_ROOT/stdout")" \
  '["2026-09-20T10:50:00Z",1800,1800]' "the head's suites and the group's runs page in one run"
# Each GraphQL call's operation name with the fragments it defines and the
# ones it spreads, both as sorted sets.
fragments_per_query() {
  gh_stub_calls | awk '
    function flush() { if (name != "") printf "%s defined:%s spread:%s\n", name, sorted(d), sorted(u) }
    function sorted(set,   k, n, keys, i, j, t, out) {
      n = 0; for (k in set) keys[++n] = k
      for (i = 2; i <= n; i++) { t = keys[i]; for (j = i - 1; j >= 1 && keys[j] > t; j--) keys[j + 1] = keys[j]; keys[j + 1] = t }
      out = ""; for (i = 1; i <= n; i++) out = out " " keys[i]
      return out }
    /^api graphql/ { flush(); name = ""; delete d; delete u
      name = ($0 ~ /query [A-Za-z]+\(/) ? substr($0, match($0, /query [A-Za-z]+\(/) + 6, RLENGTH - 7) : "pullRequest" }
    /^[^a]/ || /^api graphql/ { line = $0
      while (match(line, /fragment [A-Za-z]+/)) { d[substr(line, RSTART + 9, RLENGTH - 9)] = 1; line = substr(line, RSTART + RLENGTH) }
      line = $0
      while (match(line, /\.\.\.[A-Za-z]+/)) { u[substr(line, RSTART + 3, RLENGTH - 3)] = 1; line = substr(line, RSTART + RLENGTH) } }
    END { flush() }'
}
assert_eq "$(fragments_per_query | sort | tr '\n' ';')" \
  "pullRequest defined: gate runPage suitePage suites spread: gate runPage suitePage suites;runsPage defined: runPage spread: runPage;suitesPage defined: runPage suitePage spread: runPage suitePage;" \
  "each query defines the fragments it spreads and no other"

echo "=== a page that cannot be followed refuses ==="
stage_pages() { :; }
assert_eq "$(run "$OPEN_MERGE_SUITES | .data.repository.pullRequest.mergeCommit.checkSuites.pageInfo.endCursor = null") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr")" \
  'rc=1  {"error":"pr-timeline: check-suites of m1 page past the first names no cursor"}' "an open connection with no cursor cannot be followed"
stage_pages() { gh_stub_answer "api-graphql:query suitesPage" '{"data":{"repository":{"object":null}}}'; }
assert_eq "$(run "$FIFTY_SUITES") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr")" \
  'rc=1  {"error":"pr-timeline: check-suites of h2 page after c50 carries no connection"}' "a suites page answering no commit refuses"
stage_pages() { gh_stub_answer "api-graphql:query runsPage" '{"data":{"node":null}}'; }
assert_eq "$(run "$OPEN_GROUP_RUNS") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr")" \
  'rc=1  {"error":"pr-timeline: check-runs of suite MG page after r100 carries no connection"}' "a runs page answering no suite refuses"
stage_pages() { gh_stub_fail "api-graphql:query suitesPage" 1 'HTTP 502'; }
assert_eq "$(run "$FIFTY_SUITES") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr")" \
  'rc=1  {"error":"pr-timeline: check-suites of h2 page after c50 unreadable: GitHub API request failed"}' \
  "a suites page that does not read is one error naming its walk, cursor and the API's text"
stage_pages() { :; }

echo "=== a connection still open at the page cap refuses ==="
# Every page past the first is open at the next cursor, and the one page past
# the cap, 20 pages of suites and 10 of runs, would close the connection: the
# script never asks for it.
open_suite_pages() { # PAGES
  local n
  for n in $(seq 1 "$1"); do
    gh_stub_answer_seq "api-graphql:query suitesPage" "$(suites_page '[]' true "c$n")"
  done
  gh_stub_answer_seq "api-graphql:query suitesPage" "$(suites_page '[]' false null)"
}
open_run_pages() { # PAGES
  local n
  for n in $(seq 1 "$1"); do
    gh_stub_answer_seq "api-graphql:query runsPage" "$(runs_page '[]' true "r$n")"
  done
  gh_stub_answer_seq "api-graphql:query runsPage" "$(runs_page '[]' false null)"
}
# The cursor each further page was asked at, in call order: the stub answers
# by call ordinal, so the chain is what pins that each page carried the
# cursor the page before ended on. The last open page's cursor is never
# asked at: the cap refuses there.
cursor_chain() { # PREFIX FIRST LAST
  local n
  printf 'cursor=%s ' "$2"
  for n in $(seq 1 "$3"); do printf 'cursor=%s%s ' "$1" "$n"; done
}
cursors_asked() { gh_stub_calls | grep -o 'cursor=[^ ]*' | tr '\n' ' '; }
stage_pages() { open_suite_pages 19; }
assert_eq "$(run "$FIFTY_SUITES") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr") pages=$(gh_stub_calls | grep -c 'api graphql') $(cursors_asked)" \
  "rc=1  {\"error\":\"truncated: check-suites\"} pages=20 $(cursor_chain c c50 18)" "check suites open at the twentieth page, each asked at the cursor before it"
stage_pages() { open_run_pages 9; }
assert_eq "$(run "$OPEN_GROUP_RUNS") $(cat "$TMP_ROOT/stdout") $(cat "$TMP_ROOT/stderr") pages=$(gh_stub_calls | grep -c 'api graphql') $(cursors_asked)" \
  "rc=1  {\"error\":\"truncated: check-runs\"} pages=10 $(cursor_chain r r100 8)" "check runs open at the tenth page, each asked at the cursor before it"
stage_pages() { :; }

echo "=== the repository and gate context reach the query ==="
run . --repo other/place --gate-context "Custom gate" >/dev/null
calls="$(gh_stub_calls | tr '\n' ' ')"
assert_eq "$(grep -o 'owner=other -f name=place -F number=42 -f gate=Custom gate' <<<"$calls")" \
  "owner=other -f name=place -F number=42 -f gate=Custom gate" "--repo and --gate-context are the query's variables"
run . >/dev/null
calls="$(gh_stub_calls | tr '\n' ' ')"
assert_eq "$(grep -o 'owner=owner -f name=repo -F number=42 -f gate=Review gate' <<<"$calls")" \
  "owner=owner -f name=repo -F number=42 -f gate=Review gate" "the checkout's repository and the review gate's default context otherwise"
assert_eq "$(run . --bogus) $(cat "$TMP_ROOT/stderr")" 'rc=1 {"error":"Unknown option: --bogus"}' "an unknown option is refused"

echo "=== controls ==="
# Each planted defect runs from a private copy of pr-timeline.sh beside a
# link to the shipped lib, so the source tree is never written; mutate
# writes that copy with ANCHOR, found once in the source, replaced by R.
mkdir -p "$TMP_ROOT/scripts/commands"
ln -s "$REPO_ROOT/skills/github/scripts/lib" "$TMP_ROOT/scripts/lib"
BIN="$TMP_ROOT/scripts/commands/pr-timeline.sh"
mutate() { # ANCHOR REPLACEMENT
  assert_eq "$(grep -Fc -- "$1" "$PR_TIMELINE")" "1" "the control finds its one site"
  A="$1" R="$2" \
    awk '{ i = index($0, ENVIRON["A"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["R"] substr($0, i + length(ENVIRON["A"])); print }' \
    "$PR_TIMELINE" > "$BIN"
  assert_eq "$(grep -Fc -- "$1" "$BIN")" "0" "the control applied its mutation"
}

# The head checks read without scope_current_run.
mutate "head_checks=\$(jq -c '._checks.head' <<<\"\$result\" | scope_current_run)" \
  "head_checks=\$(jq -c '._checks.head' <<<\"\$result\")"
run "$STALE_HEAD" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs]' "$TMP_ROOT/stdout")" '[null,2400]' \
  "control: without scope_current_run the superseded failed run is read and timed"

# The page walk without its cap: the one page past the cap, which closes the
# connection, is read, and the PR prints.
mutate '[ "$pages" -lt "$cap" ] || break' '[ "$pages" -lt "$cap" ] || :'
stage_pages() { open_suite_pages 19; }
assert_eq "$(run "$FIFTY_SUITES") pages=$(gh_stub_calls | grep -c 'api graphql') $(jq -c .pr "$TMP_ROOT/stdout")" \
  "rc=0 pages=21 42" "control: without the cap the walk reads the twenty-first page and prints"
stage_pages() { :; }

# The branch log read without the bound of this life: the earlier life's
# creation counts as a push.
mutate '| select(($from == null or .timestamp > $from) and ($to == null or .timestamp <= $to))' '| select(true)'
run . >/dev/null
assert_eq "$(jq -c '.push_times[0]' "$TMP_ROOT/stdout")" '"2026-09-20T08:00:00Z"' \
  "control: without the life's bounds an earlier branch of the same name lends its pushes"

# The Bot reviews read without the author test: the PR author's own reply
# counts as a bot's review of the PR.
mutate '      and .author.login != $p.author.login)] as $bot' '      )] as $bot'
run . >/dev/null
assert_eq "$(jq -c '[.bot_reviews, .bot_review_times[-1]]' "$TMP_ROOT/stdout")" '[3,"2026-09-20T10:35:00Z"]' \
  "control: without the author test the PR author's own review is counted and timed"
BIN="$PR_TIMELINE"

echo
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
