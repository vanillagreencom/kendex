#!/usr/bin/env bash
# pr-timeline: the stamps and CI wall times it reads from one GraphQL
# response, and its refusal of a connection longer than the page it read.
#
# Each case stages one response through the shared gh fake and asserts the
# output whole. The world is one merged PR:
#   commits      the first authored at 09:00; the final head committed 10:10
#   force push   10:20, over a head whose gate had passed at 10:05
#   reviews      a user's at 09:30, then a Bot's at 09:40 and 10:30
#   gate         the final head's success at 10:25
#   head CI      a pull_request suite 10:20-10:40 and an app suite with no
#                workflow run 10:22-10:45; the merge commit's merge_group
#                suite 11:00-11:15, and a push suite there that is no one's
#   merge flow   auto-merge enabled 10:26 and again 10:50, queued 10:55,
#                merged 11:20
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
      number: 42, state: "MERGED", createdAt: t("09:10"), mergedAt: t("11:20"),
      mergeCommit: {oid: "m1", checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
        suite("merge_group"; [run("test"; "11:00"; "11:15")]), suite("push"; [run("test"; "11:21"; "11:40")])]}},
      firstCommit: {nodes: [{commit: {authoredDate: t("09:00")}}]},
      headCommit: {nodes: [{commit: ({oid: "h2", committedDate: t("10:10")} + gate("SUCCESS"; "10:25")
        + {checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
            suite("pull_request"; [run("lint"; "10:20"; "10:30"), run("test"; "10:21"; "10:40")]),
            suite(null; [run("scan"; "10:22"; "10:45")])]}})}]},
      commits: {totalCount: 1, nodes: [{commit: {oid: "h2"}}]},
      reviews: {totalCount: 3, nodes: [
        {submittedAt: t("09:30"), author: {__typename: "User"}},
        {submittedAt: t("09:40"), author: {__typename: "Bot"}},
        {submittedAt: t("10:30"), author: {__typename: "Bot"}}]},
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

BIN="$PR_TIMELINE"
run() { # EDIT [ARGS...]
  local edit="$1" rc=0
  shift
  gh_stub_reset
  gh_stub_answer api-graphql "$(response "$edit")"
  gh_stub_answer "api-repos/owner/repo/commits/b1/statuses?per_page=100" "$(status_history "$HISTORY_B1")"
  gh_stub_answer "api-repos/owner/repo/commits/h2/statuses?per_page=100" "$(status_history "$HISTORY_H2")"
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u REVIEW_GATE_CONTEXT \
    bash "$BIN" 42 "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s' "$rc"
}

echo "=== the stamps and wall times of a merged PR ==="
WANT='{"pr":42,"repo":"owner/repo","state":"MERGED","head":"h2","merge_commit":"m1","stamps":{"first_commit":"2026-09-20T09:00:00Z","created":"2026-09-20T09:10:00Z","last_push":"2026-09-20T10:20:00Z","first_bot_review":"2026-09-20T09:40:00Z","first_gate_met":"2026-09-20T10:05:00Z","gate_met":"2026-09-20T10:25:00Z","ci_green":"2026-09-20T10:45:00Z","armed":"2026-09-20T10:50:00Z","queued":"2026-09-20T10:55:00Z","merged":"2026-09-20T11:20:00Z"},"ci_head_secs":1500,"ci_merge_group_secs":900,"open_secs":7800,"bot_reviews":2}'
assert_eq "$(run .) $(cat "$TMP_ROOT/stdout")" "rc=0 $WANT" \
  "the force-pushed-over head's gate is the first pass, and the merge group's runs stay out of the head's CI"

echo "=== each stamp a PR did not reach is null ==="
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c "$want" "$TMP_ROOT/stdout")" "true" "$label"
done <<'ROWS'
an open PR has no merge, merge-group CI or open time@.data.repository.pullRequest |= (.mergedAt = null | .mergeCommit = null)@[.stamps.merged, .merge_commit, .ci_merge_group_secs, .open_secs] == [null, null, null, null]
a failing head run leaves CI never green, its wall time still read@.data.repository.pullRequest.headCommit.nodes[0].commit.checkSuites.nodes[0].checkRuns.nodes[1].conclusion = "FAILURE"@[.stamps.ci_green, .ci_head_secs] == [null, 1500]
a pending gate is not met@.data.repository.pullRequest.headCommit.nodes[0].commit.status.context.state = "PENDING"@.stamps.gate_met == null
no Bot review leaves the first one null and the count zero@.data.repository.pullRequest.reviews.nodes |= map(.author.__typename = "User")@[.stamps.first_bot_review, .bot_reviews] == [null, 0]
no force push leaves the head's commit date the last push@.data.repository.pullRequest.timelineItems.nodes |= map(select(.__typename != "HeadRefForcePushedEvent"))@[.stamps.last_push, .stamps.first_gate_met] == ["2026-09-20T10:10:00Z", "2026-09-20T10:25:00Z"]
ROWS

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
check-suites|.data.repository.pullRequest.mergeCommit.checkSuites.pageInfo.hasNextPage = true
check-runs|.data.repository.pullRequest.headCommit.nodes[0].commit.checkSuites.nodes[1].checkRuns.pageInfo.hasNextPage = true
ROWS

assert_eq "$(run '.data.repository.pullRequest |= (.commits.totalCount = 100 | .reviews.totalCount = 100)') $(jq -c .pr "$TMP_ROOT/stdout")" \
  "rc=0 42" "a hundred commits and reviews fit the page and print"

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

echo "=== control ==="
# The suite's one planted defect: the head checks read without
# scope_current_run. It runs from a private copy of pr-timeline.sh beside a
# link to the shipped lib, so the source tree is never written.
mkdir -p "$TMP_ROOT/scripts/commands"
ln -s "$REPO_ROOT/skills/github/scripts/lib" "$TMP_ROOT/scripts/lib"
BIN="$TMP_ROOT/scripts/commands/pr-timeline.sh"
ANCHOR="head_checks=\$(jq -c '._checks.head' <<<\"\$result\" | scope_current_run)"
assert_eq "$(grep -Fc -- "$ANCHOR" "$PR_TIMELINE")" "1" "the control finds its one site"
A="$ANCHOR" R="head_checks=\$(jq -c '._checks.head' <<<\"\$result\")" \
  awk '{ i = index($0, ENVIRON["A"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["R"] substr($0, i + length(ENVIRON["A"])); print }' \
  "$PR_TIMELINE" > "$BIN"
assert_eq "$(grep -Fc -- "$ANCHOR" "$BIN")" "0" "the control applied its mutation"
run "$STALE_HEAD" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs]' "$TMP_ROOT/stdout")" '[null,2400]' \
  "control: without scope_current_run the superseded failed run is read and timed"
BIN="$PR_TIMELINE"

echo
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
