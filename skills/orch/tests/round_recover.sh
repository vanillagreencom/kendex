#!/usr/bin/env bash
# Tests for round-recover, which closes a stalled dev round from the agent's own
# transcript instead of messaging an agent the harness no longer reaches.
#
# A transcript whose last assistant text is a report closes the round: the
# artifact it writes is accepted by dev-artifact-check and records
# recovered_from. A transcript with no report, or one the disk contradicts, is
# one re-delegation under a fresh round id; the re-delegated round's own stall
# is exhausted, never a second re-delegation.

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

# A worktree on its own branch one commit past main, with a workflow state
# for ISSUE at round RID and a finished validation run whose sentinel reads
# guard-exit=EXIT.
new_round() { # NAME ISSUE RID EXIT
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" switch -q -c "$2"
  printf 'work\n' > "$dir/work.txt"
  git -C "$dir" add work.txt
  git -C "$dir" commit -q -m work
  init_growth_state "$STATE" "$dir" "$2" "$3"
  mkdir -p "$dir/tmp/dev-validate-20260101T000000Z-1"
  printf 'guard-exit=%s at=2026-01-01T00:00:00Z\n' "$4" > "$dir/tmp/dev-validate-20260101T000000Z-1/exit"
  printf '%s' "$dir"
}

# One transcript line per harness shape holding TEXT as the assistant's turn.
turn() { # HARNESS TEXT
  case "$1" in
    claude) jq -cn --arg t "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' ;;
    pi) jq -cn --arg t "$2" '{type: "message", message: {role: "assistant", content: [{type: "text", text: $t}]}}' ;;
    codex) jq -cn --arg t "$2" '{type: "response_item", payload: {type: "message", role: "assistant", content: [{type: "output_text", text: $t}]}}' ;;
    *) printf 'turn: unknown harness %s\n' "$1" >&2; exit 1 ;;
  esac
}

# A transcript of HARNESS: a tool call, then TEXT as the last turn when given.
transcript() { # FILE HARNESS [TEXT]
  {
    jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {command: "git commit"}}]}}'
    [[ -z "${3:-}" ]] || turn "$2" "$3"
  } > "$1"
}

implement_report() { # COMMIT VALIDATE
  printf 'Branch: b\nCommit: %s\nQA: needs-review\nValidate: %s\nProposed rule: none\nSummary: ISSUE ok\n' "$1" "$2"
}

OUT=""
RC=0
run() { # ARG...
  set +e
  OUT="$("$RECOVER" "$@" 2>"$TMP_ROOT/stderr")"
  RC=$?
  set -e
}

state_get() { # WORKTREE ISSUE FIELD
  "$STATE" --state-dir "$1/tmp" get "$2" ".$3 // empty"
}

echo "=== a report in the transcript closes the round, for every harness shape ==="
for harness in claude pi codex; do
  WT="$(new_round "impl-$harness" "is-$harness" 1-1 0)"
  ORCH_STATE_DIR="$WT/tmp"
  HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
  transcript "$TMP_ROOT/$harness.jsonl" "$harness" "$(implement_report "$HEAD_SHA" pass)"
  run --worktree "$WT" --issue "is-$harness" --round-id 1-1 --transcript "$TMP_ROOT/$harness.jsonl"
  ARTIFACT="$WT/tmp/dev-return-is-$harness-1-1.json"
  assert_eq "rc=$RC $OUT" "rc=0 round-recover: recovered artifact=$ARTIFACT" "$harness: the report is written as the round's artifact" "$TMP_ROOT/stderr"
  assert_eq "$(jq -r '[.recovered_from, .commit, .validate, (.qa_labels | join(","))] | join(" ")' "$ARTIFACT")" \
    "transcript $HEAD_SHA pass needs-review" "$harness: the artifact carries the report's fields and recovered_from"
  assert_eq "$("$CHECK" --worktree "$WT" --issue "is-$harness" --round-id 1-1 | jq -r .verdict)" "accept" \
    "$harness: dev-artifact-check accepts the recovered round"
done

echo "=== a fix round's report closes against its item record ==="
# dev-round-write measures the branch against the issue's expected delta, read
# here through a gh stub over a cached issue body.
FW="$(new_round fix issue-778 2-2 1)"
ORCH_STATE_DIR="$FW/tmp"
mkdir -p "$FW/.cache/linear" "$TMP_ROOT/bin"
printf '[{"identifier":"issue-778","description":"**Expected delta**: 100 lines, 100 test lines"}]\n' \
  > "$FW/.cache/linear/issues.json"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/linear/issues.json
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
"$ROUND_WRITE" --worktree "$FW" --issue issue-778 --round-id 2-2 \
  --item 1 "fix nil deref" "tools/guard on a staged render" --item 2 "rename" "tools/guard on a staged render" >/dev/null
FIX_HEAD="$(git -C "$FW" rev-parse HEAD)"
transcript "$TMP_ROOT/fix.jsonl" claude "$(printf '| # | Decision | Reasoning |\n|---|---|---|\n| 1 | Applied | guarded the empty buffer |\n| 2 | Skipped | contradicts D010 |\n\nCommits: %s\nValidate: FAILING: lint\n' "${FIX_HEAD:0:9}")"
run --worktree "$FW" --issue issue-778 --round-id 2-2 --transcript "$TMP_ROOT/fix.jsonl"
assert_eq "$RC" "0" "a fix report is recovered" "$TMP_ROOT/stderr"
assert_eq "$(jq -r '[.kind, .validate, (.items | map("\(.n):\(.decision)") | join(","))] | join(" ")' "$FW/tmp/dev-return-issue-778-2-2.json")" \
  "fix FAILING: lint 1:Applied,2:Skipped" "the fix artifact carries the table's items and the FAILING verdict"
assert_eq "$("$CHECK" --worktree "$FW" --issue issue-778 --round-id 2-2 --expect-items-from-round | jq -r '"\(.ok) \(.verdict)"')" "true retry" \
  "the recovered items match the round record, and the FAILING verdict is retry, never accept"

echo "=== no report is one re-delegation under a fresh round id, then exhausted ==="
WT="$(new_round empty is-empty 3-3 0)"
ORCH_STATE_DIR="$WT/tmp"
transcript "$TMP_ROOT/empty.jsonl" claude
run --worktree "$WT" --issue is-empty --round-id 3-3 --transcript "$TMP_ROOT/empty.jsonl"
NEW="$(state_get "$WT" is-empty dev_round_id)"
assert_eq "rc=$RC $OUT" "rc=3 round-recover: redelegate round-id=$NEW from=3-3 reason=no-report" \
  "an empty transcript re-delegates under the round id it minted" "$TMP_ROOT/stderr"
assert_eq "$([[ -n "$NEW" && "$NEW" != 3-3 ]] && echo fresh || echo "stale:$NEW") $(state_get "$WT" is-empty recovery_round_id)" \
  "fresh $NEW" "the minted id is fresh and recorded as the recovery round"
assert_eq "$([[ -e "$WT/tmp/dev-return-is-empty-3-3.json" ]] && echo written || echo none)" "none" \
  "no artifact is written for a round with no report"
run --worktree "$WT" --issue is-empty --round-id "$NEW" --transcript "$TMP_ROOT/empty.jsonl"
assert_eq "rc=$RC $OUT $(state_get "$WT" is-empty dev_round_id)" "rc=1 round-recover: exhausted round-id=$NEW reason=no-report $NEW" \
  "the re-delegated round's own stall is exhausted and mints nothing" "$TMP_ROOT/stderr"

echo "=== a report the disk contradicts is no report ==="
# One row per check: the reported commit is not HEAD, a reported pass has no
# passing sentinel, and a harness that kept no transcript.
row=0
for case in "commit-mismatch|0|base" "validate-unproven|1|head" "no-transcript|0|none"; do
  IFS='|' read -r reason sentinel commit <<<"$case"
  row=$((row + 1))
  WT="$(new_round "contra-$row" "is-c$row" 4-4 "$sentinel")"
  ORCH_STATE_DIR="$WT/tmp"
  case "$commit" in
    base) sha="$(git -C "$WT" rev-parse main)" ;;
    *) sha="$(git -C "$WT" rev-parse HEAD)" ;;
  esac
  transcript "$TMP_ROOT/contra-$row.jsonl" claude "$(implement_report "$sha" pass)"
  args=(--worktree "$WT" --issue "is-c$row" --round-id 4-4)
  [[ "$commit" == none ]] || args+=(--transcript "$TMP_ROOT/contra-$row.jsonl")
  run "${args[@]}"
  assert_eq "rc=$RC ${OUT##* }" "rc=3 reason=$reason" "$reason re-delegates" "$TMP_ROOT/stderr"
done

echo "=== a validation run still going is a live round, not a stall ==="
WT="$(new_round live is-live 5-5 0)"
ORCH_STATE_DIR="$WT/tmp"
LIVE="$WT/tmp/dev-validate-20260102T000000Z-2"
mkdir -p "$LIVE"
printf '%s\n' "$$" > "$LIVE/pid"
transcript "$TMP_ROOT/live.jsonl" claude
run --worktree "$WT" --issue is-live --round-id 5-5 --transcript "$TMP_ROOT/live.jsonl"
assert_eq "rc=$RC $OUT $(state_get "$WT" is-live dev_round_id)" "rc=4 round-recover: round-live pid=$$ run-dir=$LIVE 5-5" \
  "a live validation child refuses recovery and mints nothing" "$TMP_ROOT/stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
