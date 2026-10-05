#!/usr/bin/env bash
# pr-timeline: the stamps and CI wall times it reads from one GraphQL
# response, the check-suite and check-run pages it reads past that
# response's first, the review and fix rounds it reads from the reviews and
# pushes, and its refusal of a connection longer than the page it read or
# still open at its page cap.
#
# Each case stages one response through the shared gh fake and asserts the
# output whole. The world is one merged PR:
#   commits      the first authored at 09:00; the final head committed 10:10
#   pushes       b1 at 09:20, the first check suite on it; h2 at 10:20
#   force push   10:20, over b1, whose gate had passed at 10:05
#   reviews      a user's at 09:30 and a Bot's at 09:40 on b1, a Bot's at
#                10:30 on h2, and the PR author's own, an app's, answering a
#                thread on h2 at 10:35; none of them an approval
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
    def pushed($oid; $hm): {oid: $oid, firstSuite: {nodes: [{createdAt: t($hm)}]}};
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
      commits: {totalCount: 1, nodes: [{commit: (pushed("h2"; "10:20") + {committedDate: t("10:10")})}]},
      reviews: {totalCount: 4, nodes: [
        {state: "COMMENTED", submittedAt: t("09:30"), author: {__typename: "User", login: "someone"}, commit: pushed("b1"; "09:20")},
        {state: "COMMENTED", submittedAt: t("09:40"), author: {__typename: "Bot", login: "reviewer"}, commit: pushed("b1"; "09:20")},
        {state: "COMMENTED", submittedAt: t("10:30"), author: {__typename: "Bot", login: "reviewer"}, commit: pushed("h2"; "10:20")},
        {state: "COMMENTED", submittedAt: t("10:35"), author: {__typename: "Bot", login: "lane-app"}, commit: pushed("h2"; "10:20")}]},
      timelineItems: {pageInfo: {hasNextPage: false}, nodes: [
        {__typename: "HeadRefForcePushedEvent", createdAt: t("10:20"), beforeCommit: pushed("b1"; "09:20")},
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
# PR_SELECTOR is the text the PR query must carry for the response to answer
# it; a case staging an event only some requested item type returns names
# that type, as GitHub returns no event of a type the query did not request.
PR_SELECTOR="pullRequest(number"
run() { # EDIT [ARGS...]
  local edit="$1" rc=0
  shift
  gh_stub_reset
  gh_stub_answer "api-graphql:$PR_SELECTOR" "$(response "$edit")"
  stage_pages
  gh_stub_answer "api-repos/owner/repo/commits/b1/statuses?per_page=100" "$(status_history "$HISTORY_B1")"
  gh_stub_answer "api-repos/owner/repo/commits/h2/statuses?per_page=100" "$(status_history "$HISTORY_H2")"
  gh_stub_answer "api-repos/owner/repo/commits/b2/statuses?per_page=100" "$(status_history "")"
  gh_stub_answer "$ACTIVITY_PATH" "$(activity_log "$ACTIVITY")"
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    bash "$BIN" 42 "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s' "$rc"
}

echo "=== the stamps and wall times of a merged PR ==="
WANT='{"pr":42,"repo":"owner/repo","state":"MERGED","head":"h2","merge_commit":"m1","stamps":{"first_commit":"2026-09-20T09:00:00Z","created":"2026-09-20T09:10:00Z","last_push":"2026-09-20T10:20:00Z","first_bot_review":"2026-09-20T09:40:00Z","first_gate_met":"2026-09-20T10:05:00Z","gate_met":"2026-09-20T10:25:00Z","ci_green":"2026-09-20T10:45:00Z","armed":"2026-09-20T10:50:00Z","queued":"2026-09-20T10:55:00Z","merged":"2026-09-20T11:20:00Z"},"ci_head_secs":1500,"ci_merge_group_secs":900,"open_secs":7800,"bot_reviews":2,"push_times":["2026-09-20T09:05:00Z","2026-09-20T09:50:00Z","2026-09-20T10:12:00Z","2026-09-20T10:20:00Z"],"bot_review_times":["2026-09-20T09:40:00Z","2026-09-20T10:30:00Z"],"rounds":[{"kind":"review","head":"b1","start":"2026-09-20T09:20:00Z","end":"2026-09-20T09:30:00Z","secs":600},{"kind":"fix","head":"b1","start":"2026-09-20T09:30:00Z","end":"2026-09-20T10:20:00Z","secs":3000},{"kind":"review","head":"h2","start":"2026-09-20T10:20:00Z","end":"2026-09-20T10:30:00Z","secs":600}]}'
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
no force push leaves the head's push, its first check suite, the last push@.data.repository.pullRequest.timelineItems.nodes |= map(select(.__typename != "HeadRefForcePushedEvent"))@[.stamps.last_push, .stamps.first_gate_met] == ["2026-09-20T10:20:00Z", "2026-09-20T10:25:00Z"]
a final head with no check suite and no force push falls back to its commit date@.data.repository.pullRequest |= (.timelineItems.nodes |= map(select(.__typename != "HeadRefForcePushedEvent")) | (.commits.nodes[0], .reviews.nodes[2,3]).commit.firstSuite.nodes = [])@[.stamps.last_push, .stamps.first_gate_met] == ["2026-09-20T10:10:00Z", "2026-09-20T10:25:00Z"]
ROWS

echo "=== armed is the latest arm of any merge method ==="
# The 10:50 arm made with another method, after the 10:26 merge-method arm:
# `gh pr merge --squash --auto` and `--rebase --auto` record their own event
# type. The stub answers createdAt on every node, while GitHub answers it
# only through the event type's own fragment, so a row also counts that
# fragment in the query the stub received.
#   label|item type|event type
arm_row() { # ITEM_TYPE EVENT
  local got
  PR_SELECTOR="$1"
  got="$(run ".data.repository.pullRequest.timelineItems.nodes[2].__typename = \"$2\"")"
  printf '%s %s %s' "$got" "$(jq -c '.stamps.armed' "$TMP_ROOT/stdout")" \
    "$(gh_stub_calls | grep -oF -- "... on $2 { createdAt }" | wc -l | tr -d ' ')"
  PR_SELECTOR="pullRequest(number"
}
while IFS='|' read -r label item_type event; do
  [[ -n "$label" ]] || continue
  assert_eq "$(arm_row "$item_type" "$event")" 'rc=0 "2026-09-20T10:50:00Z" 1' "$label"
done <<'ROWS'
a squash arm|AUTO_SQUASH_ENABLED_EVENT|AutoSquashEnabledEvent
a rebase arm|AUTO_REBASE_ENABLED_EVENT|AutoRebaseEnabledEvent
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
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
  bash "$BIN" 42 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
assert_eq "rc=$rc out=$(cat "$TMP_ROOT/stdout")" "rc=1 out=" "an activity log that does not read prints nothing"

echo "=== the review and fix rounds ==="
# Each row asserts the rounds as [kind, head, start, end, secs], each stamp
# as its hours and minutes.
REPLY='.data.repository.pullRequest.reviews.nodes += [{submittedAt: "2026-09-20T10:22:00Z", author: {__typename: "Bot", login: "lane-app"}, commit: .data.repository.pullRequest.commits.nodes[0].commit}]'
# h2 force-pushed over b2, pushed at 09:50 after the b1 review and reviewed
# by nobody, so beforeCommit alone names it.
B2='.data.repository.pullRequest.timelineItems.nodes[0].beforeCommit = pushed("b2"; "09:50")'
# The viewer's own pending review, which GitHub returns unsubmitted, and a
# review whose commit the schema leaves null.
PENDING='.data.repository.pullRequest.reviews.nodes += [{submittedAt: null, author: {__typename: "User", login: "someone"}, commit: pushed("b1"; "09:20")}]'
NO_COMMIT='.data.repository.pullRequest.reviews.nodes += [{submittedAt: t("09:25"), author: {__typename: "User", login: "someone"}, commit: null}]'
ROUNDS='[["review","b1","09:20","09:30",600],["fix","b1","09:30","10:20",3000],["review","h2","10:20","10:30",600]]'
# b1's reviews submitted at 10:32, after h2's review: a stale review on an
# older head, whose round starts before h2's.
STALE_REVIEW='.data.repository.pullRequest.reviews.nodes[0,1].submittedAt = t("10:32")'
STALE_ROUNDS='[["review","b1","09:20","10:32",4320],["review","h2","10:20","10:30",600]]'
NO_START='.data.repository.pullRequest |= (.timelineItems.nodes[0].beforeCommit.firstSuite.nodes = [] | .reviews.nodes[0,1].commit.firstSuite.nodes = [])'
NO_START_ROUNDS='[["review","b1","-","09:30",null],["fix","b1","09:30","10:20",3000],["review","h2","10:20","10:30",600]]'
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c '[.rounds[] | [.kind, .head, (.start | if . == null then "-" else .[11:16] end), (.end | .[11:16]), .secs]]' "$TMP_ROOT/stdout")" "$want" "$label"
done <<ROWS
the PR author's thread reply on the new head ends no round@$REPLY@$ROUNDS
a fix round ends at the first push after its review, an unreviewed force-pushed-over head's included@$B2@[["review","b1","09:20","09:30",600],["fix","b1","09:30","09:50",1200],["review","h2","10:20","10:30",600]]
a pending review ends no round@$PENDING@$ROUNDS
a review on no commit ends no round@$NO_COMMIT@$ROUNDS
a head with no check suite is no push, so its round has no start and sorts by its end, before its fix@$NO_START@$NO_START_ROUNDS
a stale review on an older head sorts by its round's start@$STALE_REVIEW@$STALE_ROUNDS
a PR nobody reviewed has no round@.data.repository.pullRequest.reviews.nodes = []@[]
ROWS

echo "=== the final head's gate is its first approval, else its historical status ==="
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c '.stamps.gate_met' "$TMP_ROOT/stdout")" "$want" "$label"
done <<'ROWS'
an approval on the final head is its gate pass, ahead of the historical status@.data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"@"2026-09-20T10:30:00Z"
two approvals on the final head: the first@.data.repository.pullRequest.reviews.nodes[2,3].state = "APPROVED"@"2026-09-20T10:30:00Z"
an approval on an older head is not the final head's gate@.data.repository.pullRequest.reviews.nodes[1].state = "APPROVED"@"2026-09-20T10:25:00Z"
a final head with an approval and no gate status@.data.repository.pullRequest |= (.headCommit.nodes[0].commit.status = null | .reviews.nodes[2].state = "APPROVED")@"2026-09-20T10:30:00Z"
ROWS

echo "=== the first gate pass is the first approval on any head, else each head's status history ==="
# The Bot review on b1, dismissed when the force push came, as a ruleset
# dismissing stale approvals on push leaves it: the review reads DISMISSED
# and its dismissal event names the state it held before.
dismissed() { # PREVIOUS_STATE
  printf '.data.repository.pullRequest |= (.reviews.nodes[1].state = "DISMISSED" | .timelineItems.nodes += [{__typename: "ReviewDismissedEvent", previousReviewState: "%s", review: {submittedAt: .reviews.nodes[1].submittedAt}}])' "$1"
}
DISMISSED_APPROVAL=$(dismissed APPROVED)
DISMISSED_CHANGES=$(dismissed CHANGES_REQUESTED)
# Each row asserts first_gate_met and how many status histories were read.
while IFS='@' read -r label edit want; do
  [[ -n "$label" ]] || continue
  run "$edit" >/dev/null
  assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout") $(gh_stub_calls | grep -c 'statuses' || :)" "$want" "$label"
done <<ROWS
an approval still standing on a force-pushed-over head is the first pass, and no status history is read@.data.repository.pullRequest.reviews.nodes[1].state = "APPROVED"@"2026-09-20T09:40:00Z" 0
an approval dismissed on a force-pushed-over head is the first pass, and no status history is read@$DISMISSED_APPROVAL@"2026-09-20T09:40:00Z" 0
approvals on two heads, the older one dismissed: the first@$DISMISSED_APPROVAL | .data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"@"2026-09-20T09:40:00Z" 0
a dismissed review that requested changes is no pass@$DISMISSED_CHANGES@"2026-09-20T10:05:00Z" 2
an approval on the final head stands ahead of an older head's earlier status pass@.data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"@"2026-09-20T10:30:00Z" 0
no approval reads every head's status history@.@"2026-09-20T10:05:00Z" 2
ROWS

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
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
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
  "pullRequest defined: gate pushed runPage suitePage suites spread: gate pushed runPage suitePage suites;runsPage defined: runPage spread: runPage;suitesPage defined: runPage suitePage spread: runPage suitePage;" \
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

# The historical status default is part of the command contract, independent
# of the retired package's settings.
mutate 'gate="Review gate"' 'gate="Other status"'
run . >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout")" 'null' \
  'control: changing the historical status default loses the first gate stamp'

# The head checks read without scope_current_run.
mutate "head_checks=\$(jq -c '._checks.head' <<<\"\$result\" | scope_current_run)" \
  "head_checks=\$(jq -c '._checks.head' <<<\"\$result\")"
run "$STALE_HEAD" >/dev/null
assert_eq "$(jq -c '[.stamps.ci_green, .ci_head_secs]' "$TMP_ROOT/stdout")" '[null,2400]' \
  "control: without scope_current_run the superseded failed run is read and timed"

# The rounds without the author filter: the author's own thread reply on
# the new head ends its review round.
mutate 'select($p.author == null or .author.login != $p.author.login)' 'select(true)'
run "$REPLY" >/dev/null
assert_eq "$(jq -c '.rounds[-1].end' "$TMP_ROOT/stdout")" '"2026-09-20T10:22:00Z"' \
  "control: without the author filter the author's reply ends the review round"

# The fix round ending at the last push after its review, not the first.
mutate 'select(. > $r.submittedAt)] | min)' 'select(. > $r.submittedAt)] | max)'
run "$B2" >/dev/null
assert_eq "$(jq -c '.rounds[1].end' "$TMP_ROOT/stdout")" '"2026-09-20T10:20:00Z"' \
  "control: the last push after a review ends its fix round in place of the first"

# The pushes without the force-pushed-over heads: b2's push is never known.
mutate '($pushes[] | .beforeCommit // empty), ' ''
run "$B2" >/dev/null
assert_eq "$(jq -c '.rounds[1].end' "$TMP_ROOT/stdout")" '"2026-09-20T10:20:00Z"' \
  "control: without the force-pushed-over heads the unreviewed b2 push ends no fix round"

# The rounds read a pending review.
mutate 'select(.submittedAt != null and .commit != null)' 'select(.commit != null)'
run "$PENDING" >/dev/null
assert_eq "$(jq -c '.rounds[0].end' "$TMP_ROOT/stdout")" 'null' \
  "control: without the submitted filter a pending review ends the b1 review round with no time"

# The rounds read a review on no commit.
mutate 'select(.submittedAt != null and .commit != null)' 'select(.submittedAt != null)'
assert_eq "$(run "$NO_COMMIT") $(tail -n 1 "$TMP_ROOT/stderr")" 'rc=1 {"error":"pr-timeline: unreadable response"}' \
  "control: without the commit filter a review on no commit fails the read"

# The rounds ordered by their ends: a stale review orders its round by its
# submission.
mutate 'sort_by([.start // .end, ' 'sort_by([.end, '
run "$STALE_REVIEW" >/dev/null
assert_eq "$(jq -c '[.rounds[].head]' "$TMP_ROOT/stdout")" '["h2","b1"]' \
  "control: ordered by end a stale review's round follows the newer head's"

# The rounds sorting a fix before a review at one time.
mutate '(if .kind == "review" then 0 else 1 end)' '(if .kind == "review" then 1 else 0 end)'
run "$NO_START" >/dev/null
assert_eq "$(jq -c '[.rounds[0,1].kind]' "$TMP_ROOT/stdout")" '["fix","review"]' \
  "control: with fix ranked first a startless review follows the fix that starts at its end"

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

# The final head's gate read from its historical status alone.
mutate 'gate_met: (([$approvals[] | select(.commit.oid == $head.oid) | .submittedAt] | min)' 'gate_met: (null'
run '.data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"' >/dev/null
assert_eq "$(jq -c '.stamps.gate_met' "$TMP_ROOT/stdout")" '"2026-09-20T10:25:00Z"' \
  "control: without the approval the final head's gate is its historical status"

# Approvals read on any head: an older head's approval stands for the final one's.
mutate 'select(.commit.oid == $head.oid)' 'select(true)'
run '.data.repository.pullRequest.reviews.nodes[1].state = "APPROVED"' >/dev/null
assert_eq "$(jq -c '.stamps.gate_met' "$TMP_ROOT/stdout")" '"2026-09-20T09:40:00Z"' \
  "control: without the head binding an older head's approval is the final head's gate"

# The first gate pass read from the status history alone.
mutate 'first_gate_met: ($approvals | map(.submittedAt) + $dismissed_approvals | min),' 'first_gate_met: null,'
run '.data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"' >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout")" '"2026-09-20T10:05:00Z"' \
  "control: without the approvals the final head's approval is not the first gate pass"

# The first gate pass read from the final head's approvals alone: an approval
# still standing on the pushed-over head is lost.
mutate 'first_gate_met: ($approvals | map(.submittedAt)' 'first_gate_met: ($approvals | map(select(.commit.oid == $head.oid) | .submittedAt)'
run '.data.repository.pullRequest.reviews.nodes[1].state = "APPROVED"' >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout") $(gh_stub_calls | grep -c 'statuses' || :)" '"2026-09-20T10:05:00Z" 2' \
  "control: with the head binding an older head's standing approval is not the first gate pass"

# The first gate pass read from current approvals alone: the approval the
# ruleset dismissed on the pushed-over head is lost.
mutate '| map(.submittedAt) + $dismissed_approvals | min),' '| map(.submittedAt) | min),'
run "$DISMISSED_APPROVAL" >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout")" '"2026-09-20T10:05:00Z"' \
  "control: without the dismissal events a dismissed approval is not the first gate pass"

# Every dismissed review read as an approval: one that requested changes passes.
mutate 'select(.previousReviewState == "APPROVED")' 'select(true)'
run "$DISMISSED_CHANGES" >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout")" '"2026-09-20T09:40:00Z"' \
  "control: without the previous-state test a dismissed change request is the first gate pass"

# The status history read beside an approval: its earlier pass replaces it.
mutate 'if [ -z "$approved" ]; then' 'if :; then'
run '.data.repository.pullRequest.reviews.nodes[2].state = "APPROVED"' >/dev/null
assert_eq "$(jq -c '.stamps.first_gate_met' "$TMP_ROOT/stdout") $(gh_stub_calls | grep -c 'statuses' || :)" '"2026-09-20T10:05:00Z" 2' \
  "control: with the status history read beside an approval its older pass is the first gate pass"

# The arm read from merge-method events alone: a later squash arm is lost.
mutate 'select(.__typename | IN("AutoMergeEnabledEvent", "AutoSquashEnabledEvent", "AutoRebaseEnabledEvent"))' \
  'select(.__typename == "AutoMergeEnabledEvent")'
run '.data.repository.pullRequest.timelineItems.nodes[2].__typename = "AutoSquashEnabledEvent"' >/dev/null
assert_eq "$(jq -c '.stamps.armed' "$TMP_ROOT/stdout")" '"2026-09-20T10:26:00Z"' \
  "control: without the squash event type a later squash arm is not the arm"

# The squash item type left out of the query: GitHub returns no squash arm.
mutate 'AUTO_SQUASH_ENABLED_EVENT, ' ''
PR_SELECTOR=AUTO_SQUASH_ENABLED_EVENT
assert_eq "$(run '.data.repository.pullRequest.timelineItems.nodes[2].__typename = "AutoSquashEnabledEvent"')" 'rc=1' \
  "control: a query that does not request squash arms reads none"
PR_SELECTOR="pullRequest(number"

# The squash fragment left out of the query: GitHub answers a squash arm's
# node with no createdAt.
mutate '... on AutoSquashEnabledEvent { createdAt }' ''
assert_eq "$(arm_row AUTO_SQUASH_ENABLED_EVENT AutoSquashEnabledEvent)" 'rc=0 "2026-09-20T10:50:00Z" 0' \
  "control: a query without the squash fragment reads no squash arm's time"
BIN="$PR_TIMELINE"

echo
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
