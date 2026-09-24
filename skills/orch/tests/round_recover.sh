#!/usr/bin/env bash
# Tests for round-recover, which closes a stalled dev round from the agent's own
# transcript instead of messaging an agent the harness no longer reaches.
#
# A report the agent sent after this round's delegation closes the round: the
# artifact it writes is accepted by dev-artifact-check and records
# recovered_from. No report, or one the disk contradicts, is one re-delegation
# under a fresh round id; the re-delegated round's own failure is exhausted,
# never a second re-delegation.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
RECOVER="$REPO_ROOT/skills/orch/scripts/round-recover"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
ROUND_WRITE="$REPO_ROOT/skills/orch/scripts/dev-round-write"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export ORCH_STATE_DIR

# dev-round-write measures a fix round's branch against the issue's expected
# delta, read here through a gh stub over each worktree's cached issue body.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/linear/issues.json
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

NOW="$(date +%s)"
DEAD_PID="$(sh -c 'printf "%s" $$')"

# A validation run started AGE seconds ago whose child recorded guard-exit=EXIT,
# or with EXIT "-" none recorded, its pid file naming PID.
add_run() { # WORKTREE NAME AGE EXIT PID
  local run="$1/tmp/dev-validate-$2"
  mkdir -p "$run"
  printf 'start=%s\ncap-secs=3640\npoll-secs=30\n' "$(( NOW - $3 ))" > "$run/start"
  printf '%s\n' "$5" > "$run/pid"
  [[ "$4" == - ]] || printf 'guard-exit=%s at=2026-01-01T00:00:00Z\n' "$4" > "$run/exit"
}

# A worktree on its own branch one commit past main, a workflow state for
# ISSUE at round RID delegated 50 seconds ago, and, unless EXIT is "none", a
# validation run started since whose sentinel reads guard-exit=EXIT. Sets WT, HEAD_SHA, BASE_SHA and
# OTHER_SHA, a commit off main that HEAD does not reach.
new_round() { # NAME ISSUE RID EXIT
  WT="$TMP_ROOT/$1"
  mkdir -p "$WT"
  git -C "$WT" init -q -b main
  git -C "$WT" config gc.auto 0
  git -C "$WT" config maintenance.auto false
  git -C "$WT" config user.email test@example.com
  git -C "$WT" config user.name Test
  git -C "$WT" config commit.gpgsign false
  git -C "$WT" commit -q --allow-empty -m base
  git -C "$WT" switch -q -c "$2"
  printf 'work\n' > "$WT/work.txt"
  git -C "$WT" add work.txt
  git -C "$WT" commit -q -m work
  BASE_SHA="$(git -C "$WT" rev-parse main)"
  HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
  OTHER_SHA="$(git -C "$WT" commit-tree -p main -m other "$(git -C "$WT" rev-parse 'HEAD^{tree}')")"
  init_growth_state "$STATE" "$WT" "$2" "$3"
  "$STATE" --state-dir "$WT/tmp" set "$2" dev_delegated_at "$(( NOW - 50 ))" >/dev/null
  [[ "$4" == none ]] || add_run "$WT" 1 10 "$4" "$DEAD_PID"
  ORCH_STATE_DIR="$WT/tmp"
}

# new_round for a fix round: the round record holds items 1 and 2.
new_fix_round() { # NAME N RID EXIT
  new_round "$1" "issue-$2" "$3" "$4"
  mkdir -p "$WT/.cache/linear"
  printf '[{"identifier":"issue-%s","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' "$2" \
    > "$WT/.cache/linear/issues.json"
  "$ROUND_WRITE" --worktree "$WT" --issue "issue-$2" --round-id "$3" \
    --item 1 "fix nil deref" "tools/guard on a staged render" --item 2 "rename" "tools/guard on a staged render" >/dev/null
}

# One transcript line: a user turn saying TEXT, or the agent returning TEXT
# through HARNESS's channel.
user_turn() { # HARNESS TEXT
  case "$1" in
    codex) jq -cn --arg t "$2" '{type: "response_item", payload: {type: "message", role: "user", content: [{type: "input_text", text: $t}]}}' ;;
    pi) jq -cn --arg t "$2" '{type: "message", message: {role: "user", content: [{type: "text", text: $t}]}}' ;;
    *) jq -cn --arg t "$2" '{type: "user", message: {role: "user", content: $t}}' ;;
  esac
}
tool_turn() {
  jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {command: "git log"}}]}}'
}
report_turn() { # HARNESS TEXT
  case "$1" in
    claude-send)
      jq -cn --arg t "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "SendMessage", input: {to: "team-lead", message: $t}}]}}'
      jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "The round is done and reported."}]}}'
      ;;
    claude-text) jq -cn --arg t "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' ;;
    pi) jq -cn --arg t "$2" '{type: "message", message: {role: "assistant", content: [{type: "text", text: $t}]}}' ;;
    codex)
      jq -cn --arg t "$2" '{type: "response_item", payload: {type: "function_call", name: "send_input", arguments: ({id: "lead", message: $t} | tojson)}}'
      jq -cn '{type: "response_item", payload: {type: "message", role: "assistant", content: [{type: "output_text", text: "Reported."}]}}'
      ;;
    *) printf 'report_turn: unknown harness %s\n' "$1" >&2; exit 1 ;;
  esac
}

# A transcript for round RID: its delegation, a tool call, then REPORT through
# HARNESS's channel when REPORT is not empty.
transcript() { # FILE HARNESS RID REPORT
  {
    user_turn "$2" "Follow workflow: dev-implement.md
Round ID: $3"
    tool_turn
    [[ -z "$4" ]] || report_turn "$2" "$4"
  } > "$1"
}

# An implement report; `-` drops a line.
implement_report() { # COMMIT VALIDATE QA [BRANCH] [PROPOSED] [SUMMARY]
  local line
  for line in "Branch: ${4:-b}" "Commit: $1" "QA: $3" "Validate: $2" "Proposed rule: ${5:-none}" "Summary: ${6:-KEN-1 ✓}"; do
    [[ "${line#*: }" == - ]] || printf '%s\n' "$line"
  done
}
fix_report() { # COMMITS VALIDATE [ROWS]
  printf '| # | Decision | Reasoning |\n|---|---|---|\n'
  [[ "${3:-yes}" == no ]] || printf '| 1 | Applied | guarded the empty buffer |\n| 2 | Skipped | contradicts D010 |\n'
  printf '\n'
  [[ "$1" == - ]] || printf 'Commits: %s\n' "$1"
  printf 'Validate: %s\nProposed rule: none\n' "$2"
}

OUT=""
RC=0
run() { # ARG...
  set +e
  OUT="$("$RECOVER" "$@" 2>"$TMP_ROOT/stderr")"
  RC=$?
  set -e
}
state_get() { # ISSUE FIELD
  "$STATE" --state-dir "$WT/tmp" get "$1" ".$2 // empty"
}
artifact_has() { # PATH JQ
  jq -r "$2" "$1" 2>/dev/null || printf 'UNREADABLE'
}

echo "=== a report through each harness's return channel closes the round ==="
# Claude Code's report is a SendMessage call's message, followed here by prose
# the text fallback would pick; Codex's is a send_input call's message.
for harness in claude-send claude-text pi codex; do
  new_round "impl-$harness" "KEN-$harness" 1-1 0
  transcript "$TMP_ROOT/$harness.jsonl" "$harness" 1-1 "$(implement_report "$HEAD_SHA" pass needs-review)"
  run --worktree "$WT" --issue "KEN-$harness" --round-id 1-1 --transcript "$TMP_ROOT/$harness.jsonl"
  ARTIFACT="$WT/tmp/dev-return-KEN-$harness-1-1.json"
  assert_eq "rc=$RC $OUT" "rc=0 round-recover: recovered artifact=$ARTIFACT" "$harness: the report is written as the round's artifact" "$TMP_ROOT/stderr"
  assert_eq "$(artifact_has "$ARTIFACT" '"\(.recovered_from) \(.commit) \(.validate) \(.qa_labels | join(","))"')" \
    "transcript $HEAD_SHA pass needs-review" "$harness: the artifact carries the report's fields and recovered_from"
  assert_eq "$("$CHECK" --worktree "$WT" --issue "KEN-$harness" --round-id 1-1 | jq -r .verdict)" "accept" \
    "$harness: dev-artifact-check accepts the recovered round"
done

echo "=== only this round's turns hold its report ==="
# A persistent agent's earlier round reported above this round's delegation,
# and this round made only tool calls: no report.
new_round prior KEN-2 2-2 0
{
  user_turn claude "Round ID: 2-1"
  report_turn claude-send "$(implement_report "$HEAD_SHA" pass none)"
  user_turn claude "Round ID: 2-2"
  tool_turn
} > "$TMP_ROOT/prior.jsonl"
run --worktree "$WT" --issue KEN-2 --round-id 2-2 --transcript "$TMP_ROOT/prior.jsonl"
assert_eq "rc=$RC ${OUT##* } $([[ -e "$WT/tmp/dev-return-KEN-2-2-2.json" ]] && echo written || echo none)" \
  "rc=3 reason=no-report none" "an earlier round's report does not close this round"
# Two reports in this round and a user turn after them: the last report wins,
# a round id that only begins with this one is another round, and the agent
# quoting its own round id is no delegation.
new_round latest KEN-3 3-3 0
{
  user_turn claude "Round ID: 3-3"
  report_turn claude-send "$(implement_report "$HEAD_SHA" pass none)"
  report_turn claude-send "$(implement_report "$HEAD_SHA" pass needs-review)"
  report_turn claude-text "Done with Round ID: 3-3"
  user_turn claude "Round ID: 3-30"
  user_turn claude "<system-reminder>idle</system-reminder>"
} > "$TMP_ROOT/latest.jsonl"
run --worktree "$WT" --issue KEN-3 --round-id 3-3 --transcript "$TMP_ROOT/latest.jsonl"
assert_eq "rc=$RC $(artifact_has "$WT/tmp/dev-return-KEN-3-3-3.json" '.qa_labels | join(",")')" "rc=0 needs-review" \
  "the round's last report is the one recovered" "$TMP_ROOT/stderr"

echo "=== the recovered implement record ==="
# QA: none is no labels and a list is every label; a backticked commit
# resolves; a proposed rule becomes the section Store Proposed Rules reads; a
# GitHub key or a Summary: line with no check mark posted no summary.
row=0
for case in \
  "QA none^KEN-10^%H^none^none^KEN-10 ✓^.qa_labels|tojson^[]" \
  "a QA list^KEN-11^%H^needs-review, needs-safety-audit^none^KEN-11 ✓^.qa_labels|join(\",\")^needs-review,needs-safety-audit" \
  "a backticked commit^KEN-12^\`%H\`^none^none^KEN-12 ✓^.commit^%H" \
  "a proposed rule^KEN-13^%H^none^Name the reach^KEN-13 ✓^.summary|split(\"### Proposed Rules\")[1]|ltrimstr(\"\\n\\n\")^- Name the reach" \
  "a Linear summary with a check mark^KEN-14^%H^none^none^KEN-14 ✓^.summary_posted^true" \
  "a GitHub key^issue-15^%H^none^none^issue-15 ✓^.summary_posted^false" \
  "a Summary line with no check mark^KEN-16^%H^none^none^KEN-16^.summary_posted^false"; do
  row=$((row + 1))
  IFS='^' read -r label key commit qa proposed summary filter want <<<"$case"
  new_round "rec-$row" "$key" 4-4 0
  commit="${commit//%H/$HEAD_SHA}"; want="${want//%H/$HEAD_SHA}"
  transcript "$TMP_ROOT/rec-$row.jsonl" claude-send 4-4 "$(implement_report "$commit" pass "$qa" b "$proposed" "$summary")"
  run --worktree "$WT" --issue "$key" --round-id 4-4 --transcript "$TMP_ROOT/rec-$row.jsonl"
  assert_eq "rc=$RC $(artifact_has "$WT/tmp/dev-return-$key-4-4.json" "$filter")" "rc=0 $want" "$label" "$TMP_ROOT/stderr"
done

echo "=== a fix round's report closes against its item record ==="
new_fix_round fix 778 5-5 1
transcript "$TMP_ROOT/fix.jsonl" claude-send 5-5 "$(fix_report "${HEAD_SHA:0:9}" "FAILING: lint")"
run --worktree "$WT" --issue issue-778 --round-id 5-5 --transcript "$TMP_ROOT/fix.jsonl"
ARTIFACT="$WT/tmp/dev-return-issue-778-5-5.json"
assert_eq "rc=$RC $OUT" "rc=0 round-recover: recovered artifact=$ARTIFACT" "a fix report is recovered" "$TMP_ROOT/stderr"
assert_eq "$(artifact_has "$ARTIFACT" '"\(.recovered_from) \(.kind) \(.validate) \(.items | map("\(.n):\(.decision)") | join(","))"')" \
  "transcript fix FAILING: lint 1:Applied,2:Skipped" "the fix artifact carries the table's items, the FAILING verdict and recovered_from"
assert_eq "$("$CHECK" --worktree "$WT" --issue issue-778 --round-id 5-5 --expect-items-from-round | jq -r '"\(.ok) \(.verdict)"')" "true retry" \
  "the recovered items match the round record, and the FAILING verdict is retry, never accept"
new_fix_round fix-none 779 5-6 0
transcript "$TMP_ROOT/fix-none.jsonl" claude-send 5-6 "$(fix_report none pass)"
run --worktree "$WT" --issue issue-779 --round-id 5-6 --transcript "$TMP_ROOT/fix-none.jsonl"
assert_eq "rc=$RC $(artifact_has "$WT/tmp/dev-return-issue-779-5-6.json" .commit)" "rc=0 $HEAD_SHA" \
  "Commits: none records the unchanged HEAD" "$TMP_ROOT/stderr"

echo "=== no report is one re-delegation under a fresh round id, then exhausted ==="
new_round empty KEN-20 6-6 0
transcript "$TMP_ROOT/empty.jsonl" claude-send 6-6 ""
run --worktree "$WT" --issue KEN-20 --round-id 6-6 --transcript "$TMP_ROOT/empty.jsonl"
NEW="$(state_get KEN-20 dev_round_id)"
assert_eq "rc=$RC $OUT" "rc=3 round-recover: redelegate round-id=$NEW from=6-6 reason=no-report" \
  "an empty transcript re-delegates under the round id it minted" "$TMP_ROOT/stderr"
assert_eq "$([[ -n "$NEW" && "$NEW" != 6-6 ]] && echo fresh || echo "stale:$NEW") $(state_get KEN-20 recovery_round_id)" \
  "fresh $NEW" "the minted id is fresh and recorded as the recovery round"
assert_eq "$([[ -e "$WT/tmp/dev-return-KEN-20-6-6.json" ]] && echo written || echo none)" "none" \
  "no artifact is written for a round with no report"
transcript "$TMP_ROOT/empty2.jsonl" claude-send "$NEW" ""
run --worktree "$WT" --issue KEN-20 --round-id "$NEW" --transcript "$TMP_ROOT/empty2.jsonl"
assert_eq "rc=$RC $OUT $(state_get KEN-20 dev_round_id)" "rc=1 round-recover: exhausted round-id=$NEW reason=no-report $NEW" \
  "the re-delegated round's own stall is exhausted and mints nothing" "$TMP_ROOT/stderr"

echo "=== a report the disk contradicts, or cannot be read, is no report ==="
# One planted defect per row; %H, %B and %O are HEAD, main and a commit HEAD
# does not reach. A fix row's report is fix_report's COMMITS|VALIDATE|ROWS.
row=0
for case in \
  "commit-mismatch|implement|0|%B|pass|needs-review|b" \
  "validate-unproven|implement|1|%H|pass|needs-review|b" \
  "unparsed|implement|0|%H|passing|needs-review|b" \
  "unparsed|implement|0|%H|pass|needs-review|-" \
  "unparsed|implement|0|-|pass|needs-review|b" \
  "unparsed|implement|0|%H|pass|-|b" \
  "commit-mismatch|fix|0|0000000deadbeef|pass|yes" \
  "commit-mismatch|fix|0|%O, %H|pass|yes" \
  "commit-mismatch|fix|0|%B|pass|yes" \
  "unparsed|fix|0|%H|pass|no" \
  "unparsed|fix|0|-|pass|yes"; do
  row=$((row + 1))
  IFS='|' read -r reason kind sentinel commits validate qa branch <<<"$case"
  if [[ "$kind" == fix ]]; then
    new_fix_round "contra-$row" "8$row" 7-7 "$sentinel"
    key="issue-8$row"
  else
    new_round "contra-$row" "KEN-8$row" 7-7 "$sentinel"
    key="KEN-8$row"
  fi
  commits="${commits//%H/$HEAD_SHA}"; commits="${commits//%B/$BASE_SHA}"; commits="${commits//%O/$OTHER_SHA}"
  if [[ "$kind" == fix ]]; then
    report="$(fix_report "$commits" "$validate" "$qa")"
  else
    report="$(implement_report "$commits" "$validate" "$qa" "$branch")"
  fi
  transcript "$TMP_ROOT/contra-$row.jsonl" claude-send 7-7 "$report"
  run --worktree "$WT" --issue "$key" --round-id 7-7 --transcript "$TMP_ROOT/contra-$row.jsonl"
  assert_eq "rc=$RC ${OUT##* }" "rc=3 reason=$reason" "row $row ($kind): $reason re-delegates" "$TMP_ROOT/stderr"
done
# A passing run that started before this round's delegation validated older
# contents, and a harness that kept no transcript left no report.
new_round stale KEN-90 7-7 none
add_run "$WT" 0-stale 1000 0 "$DEAD_PID"
transcript "$TMP_ROOT/stale.jsonl" claude-send 7-7 "$(implement_report "$HEAD_SHA" pass none)"
run --worktree "$WT" --issue KEN-90 --round-id 7-7 --transcript "$TMP_ROOT/stale.jsonl"
assert_eq "rc=$RC ${OUT##* }" "rc=3 reason=validate-unproven" "a pass older than the delegation is unproven" "$TMP_ROOT/stderr"
new_round none KEN-91 7-7 0
run --worktree "$WT" --issue KEN-91 --round-id 7-7
assert_eq "rc=$RC ${OUT##* }" "rc=3 reason=no-transcript" "no transcript re-delegates" "$TMP_ROOT/stderr"

echo "=== dev-validate-run decides whether the round's run is still going ==="
new_round live KEN-95 8-8 0
add_run "$WT" 2-live 5 - "$$"
transcript "$TMP_ROOT/live.jsonl" claude-send 8-8 ""
run --worktree "$WT" --issue KEN-95 --round-id 8-8 --transcript "$TMP_ROOT/live.jsonl"
assert_eq "rc=$RC $OUT $(state_get KEN-95 dev_round_id)" "rc=4 round-recover: round-live run-dir=$WT/tmp/dev-validate-2-live 8-8" \
  "a live validation child refuses recovery and mints nothing" "$TMP_ROOT/stderr"
new_round lost KEN-96 8-8 0
add_run "$WT" 2-lost 5 - "$DEAD_PID"
transcript "$TMP_ROOT/lost.jsonl" claude-send 8-8 "$(implement_report "$HEAD_SHA" "FAILING: lost" none)"
run --worktree "$WT" --issue KEN-96 --round-id 8-8 --transcript "$TMP_ROOT/lost.jsonl"
assert_eq "rc=$RC ${OUT%% artifact=*}" "rc=0 round-recover: recovered" \
  "a run whose child exited with no verdict is lost, not live, and recovery proceeds" "$TMP_ROOT/stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
