#!/usr/bin/env bash
# Regression tests for review-init issue-id case normalization (VST-194).
#
# review-init extracted the branch's issue id with `grep -oiP` and used the RAW
# match, so on lowercase-branch repos (issue-vst-177) it derived a lowercase
# workflow-state key while session-init — and every other GH_ISSUE_PATTERN
# consumer — canonicalizes to uppercase. workflow-state keys are case-sensitive,
# so one logical issue silently got two case-variant state files and two
# independent flocks. review-init must derive the same canonical key as
# session-init and reuse a pre-existing canonical state file.
#
# The test builds a hermetic git repo plus a real `git worktree add` on a
# lowercase issue branch, runs both real scripts from there against an isolated
# ORCH_STATE_DIR, and requires their derived keys to agree on one state file.
set -euo pipefail

# The invoking shell's auth env must not leak into session-init's probes.
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN LINEAR_API_KEY LINEAR_TEAM

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
REVIEW_INIT="$SCRIPTS_DIR/review-init"
SESSION_INIT="$SCRIPTS_DIR/session-init"
WORKFLOW_STATE="$SCRIPTS_DIR/workflow-state"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Stub gh so session-init's worktree auth probe never touches the network.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/gh"

# Hermetic repo with a lowercase-convention issue branch in a linked worktree,
# so session-init takes its worktree fast path against the same branch.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
WT="$TMP_ROOT/wt-issue-vst-177"
git -C "$REPO" worktree add -q -b issue-vst-177 "$WT" >/dev/null

STATE_DIR="$TMP_ROOT/state"
PATTERN='VST-[0-9]+'

run_review_init() {
  (cd "$WT" && PATH="$BIN:$PATH" GH_ISSUE_PATTERN="$PATTERN" ORCH_STATE_DIR="$STATE_DIR" "$REVIEW_INIT")
}

state_file_count() {
  find "$STATE_DIR" -maxdepth 1 -name 'workflow-state-*.json' | wc -l | tr -d ' '
}

echo "=== review-init issue-id normalization ==="

# Case 1: lowercase branch yields the canonical uppercase state key.
ri_out="$(run_review_init)"
ri_issue="$(jq -r '.issue_id' <<<"$ri_out")"
ri_state="$(jq -r '.state_path' <<<"$ri_out")"
assert_eq "$ri_issue" "VST-177" "lowercase branch derives uppercase issue id"
assert_eq "$(basename "$ri_state")" "workflow-state-VST-177.json" "state path uses canonical uppercase key"
assert_eq "$(jq -r '.initialized' <<<"$ri_out")" "true" "first run initializes state"
assert_eq "$(state_file_count)" "1" "exactly one state file created"

# Case 2: review-init and session-init must derive the SAME key for one branch —
# the invariant whose breakage split state across two case-variant files.
si_out="$(cd "$WT" && PATH="$BIN:$PATH" GH_ISSUE_PATTERN="$PATTERN" "$SESSION_INIT" --json)"
si_issue="$(jq -r '.issue_id' <<<"$si_out")"
assert_eq "$si_issue" "$ri_issue" "session-init derives the same issue id for the same branch"

# Case 3: a canonical state file created by another consumer is reused —
# review-init must not mint a lowercase twin with its own flock.
rm -rf "$STATE_DIR"
(cd "$WT" && ORCH_STATE_DIR="$STATE_DIR" "$WORKFLOW_STATE" init VST-177 >/dev/null)
ri2_out="$(run_review_init)"
assert_eq "$(jq -r '.initialized' <<<"$ri2_out")" "false" "pre-existing canonical state is detected"
assert_eq "$(basename "$(jq -r '.state_path' <<<"$ri2_out")")" "workflow-state-VST-177.json" "pre-existing canonical state path is reused"
assert_eq "$(state_file_count)" "1" "no duplicate case-variant state file"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
