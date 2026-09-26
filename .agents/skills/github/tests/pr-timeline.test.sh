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
    def run($s; $e): {status: "COMPLETED", conclusion: "SUCCESS", startedAt: t($s), completedAt: t($e)};
    def suite($event; $runs): {workflowRun: (if $event == null then null else {event: $event} end),
                               checkRuns: {pageInfo: {hasNextPage: false}, nodes: $runs}};
    def gate($state; $hm): {status: {context: {state: $state, createdAt: t($hm)}}};
    {data: {repository: {pullRequest: {
      number: 42, state: "MERGED", createdAt: t("09:10"), mergedAt: t("11:20"),
      mergeCommit: {oid: "m1", checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
        suite("merge_group"; [run("11:00"; "11:15")]), suite("push"; [run("11:21"; "11:40")])]}},
      firstCommit: {nodes: [{commit: {authoredDate: t("09:00")}}]},
      headCommit: {nodes: [{commit: ({oid: "h2", committedDate: t("10:10")} + gate("SUCCESS"; "10:25")
        + {checkSuites: {pageInfo: {hasNextPage: false}, nodes: [
            suite("pull_request"; [run("10:20"; "10:30"), run("10:21"; "10:40")]),
            suite(null; [run("10:22"; "10:45")])]}})}]},
      commits: {totalCount: 1, nodes: [{commit: gate("SUCCESS"; "10:25")}]},
      reviews: {totalCount: 3, nodes: [
        {submittedAt: t("09:30"), author: {__typename: "User"}},
        {submittedAt: t("09:40"), author: {__typename: "Bot"}},
        {submittedAt: t("10:30"), author: {__typename: "Bot"}}]},
      timelineItems: {pageInfo: {hasNextPage: false}, nodes: [
        {__typename: "HeadRefForcePushedEvent", createdAt: t("10:20"), beforeCommit: gate("SUCCESS"; "10:05")},
        {__typename: "AutoMergeEnabledEvent", createdAt: t("10:26")},
        {__typename: "AutoMergeEnabledEvent", createdAt: t("10:50")},
        {__typename: "AddedToMergeQueueEvent", createdAt: t("10:55")}]}
    }}}} | '"$1"
}

BIN="$PR_TIMELINE"
run() { # EDIT [ARGS...]
  local edit="$1" rc=0
  shift
  gh_stub_reset
  gh_stub_answer api-graphql "$(response "$edit")"
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
# Each planted defect runs from a copy of the scripts, so the mutant sources
# the same lib and the source tree is never written.
cp -R "$REPO_ROOT/skills/github/scripts" "$TMP_ROOT/scripts"
mutant() { # NAME ANCHOR REPLACEMENT
  assert_eq "$(grep -Fc -- "$2" "$PR_TIMELINE")" "1" "the $1 control finds its anchor"
  BIN="$TMP_ROOT/scripts/commands/pr-timeline.$1.sh"
  A="$2" R="$3" awk '{ i = index($0, ENVIRON["A"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["R"] substr($0, i + length(ENVIRON["A"])); print }' \
    "$PR_TIMELINE" > "$BIN"
}
mutant group-suites 'select(.workflowRun.event == "merge_group") end]' 'select(true) end]'
run . >/dev/null
assert_eq "$(jq -c '.ci_merge_group_secs' "$TMP_ROOT/stdout")" "2400" \
  "control: without the merge_group filter the merge commit's push suite joins the merge-group figure"
mutant no-truncation 'if ($truncated | length) > 0 then' 'if false then'
assert_eq "$(run '.data.repository.pullRequest.reviews.totalCount = 101')" "rc=0" \
  "control: without the truncation check a partial review list prints stamps"
BIN="$PR_TIMELINE"

echo
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
