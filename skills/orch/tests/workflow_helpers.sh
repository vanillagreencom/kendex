#!/usr/bin/env bash
# Regression tests for Codex-safe orch helper commands.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

echo "=== orch Codex-safe helper commands ==="

state_dir="$TMP_ROOT/state"
ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" init issue-353 --worktree "$REPO_ROOT" --branch issue-353 >/dev/null

exists_json="$(ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" exists --json issue-353)"
assert_eq "$(jq -r '.exists' <<<"$exists_json")" "true" "workflow-state exists --json reports existing state"
assert_eq "$(jq -r '.issue_id' <<<"$exists_json")" "issue-353" "workflow-state exists --json includes issue id"

missing_json="$(ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" exists --json issue-404)"
assert_eq "$(jq -r '.exists' <<<"$missing_json")" "false" "workflow-state exists --json reports missing state"

default_branch="$(WORKTREE_DEFAULT_BRANCH=trunk "$REPO_ROOT/skills/orch/scripts/resolve-base-branch" "$REPO_ROOT")"
assert_eq "$default_branch" "trunk" "resolve-base-branch honors WORKTREE_DEFAULT_BRANCH"

fallback_branch="$("$REPO_ROOT/skills/orch/scripts/resolve-base-branch" "$TMP_ROOT/not-a-git-repo")"
assert_eq "$fallback_branch" "main" "resolve-base-branch falls back to main"

assert_eq "$("$REPO_ROOT/skills/orch/scripts/tracker-for-issue" issue-353)" "github" "tracker-for-issue detects GitHub ids"
assert_eq "$("$REPO_ROOT/skills/orch/scripts/tracker-for-issue" CC-353)" "linear" "tracker-for-issue detects Linear ids"

issue_repo="$TMP_ROOT/issue-repo"
git init -q "$issue_repo"
git -C "$issue_repo" checkout -q -b cc-536
assert_eq "$("$REPO_ROOT/skills/orch/scripts/git-context" issue-from-branch "$issue_repo")" "CC-536" "git-context uppercases lower-case Linear branch ids"

git -C "$issue_repo" checkout -q --orphan issue-369
assert_eq "$("$REPO_ROOT/skills/orch/scripts/git-context" issue-from-branch "$issue_repo")" "issue-369" "git-context keeps GitHub issue branch ids lowercase"

preflight_repo="$TMP_ROOT/preflight-repo"
git init -q "$preflight_repo"
git -C "$preflight_repo" config user.name "Test User"
git -C "$preflight_repo" config user.email "test@example.com"
git -C "$preflight_repo" config commit.gpgsign false
mkdir -p "$preflight_repo/.codex/agents"
cat >"$preflight_repo/.gitignore" <<'EOF'
/.codex/**
EOF
cat >"$preflight_repo/.codex/agents/reviewer-test.toml" <<'EOF'
name = "reviewer-test"
EOF

preflight_untracked="$("$REPO_ROOT/skills/orch/scripts/codex-app-agent-preflight" "$preflight_repo")"
assert_eq "$(jq -r '.status' <<<"$preflight_untracked")" "untracked" "codex app preflight warns for ignored generated agents"
assert_eq "$(jq -r '.severity' <<<"$preflight_untracked")" "warning" "codex app preflight classifies ignored generated agents as warning"
assert_eq "$(jq -r '.ok' <<<"$preflight_untracked")" "false" "codex app preflight still marks ignored generated agents not ok"
assert_eq "$(jq -r '.requires_confirmation' <<<"$preflight_untracked")" "true" "codex app preflight asks for confirmation on warning"
assert_eq "$(jq -r '.tracked_agents' <<<"$preflight_untracked")" "0" "codex app preflight reports no tracked agents"
assert_eq "$(jq -r '.visible_agents' <<<"$preflight_untracked")" "1" "codex app preflight reports visible ignored agent"

cat >"$preflight_repo/.gitignore" <<'EOF'
/.codex/**
!/.codex/
!/.codex/agents/
!/.codex/agents/*.toml
EOF
git -C "$preflight_repo" add .gitignore .codex/agents/reviewer-test.toml
git -C "$preflight_repo" commit -q -m 'track codex agent' >/dev/null

preflight_ok="$("$REPO_ROOT/skills/orch/scripts/codex-app-agent-preflight" "$preflight_repo")"
assert_eq "$(jq -r '.status' <<<"$preflight_ok")" "ok" "codex app preflight accepts tracked generated agents"
assert_eq "$(jq -r '.severity' <<<"$preflight_ok")" "info" "codex app preflight classifies tracked generated agents as info"
assert_eq "$(jq -r '.requires_confirmation' <<<"$preflight_ok")" "false" "codex app preflight does not ask confirmation when tracked agents exist"
assert_eq "$(jq -r '.tracked_agents' <<<"$preflight_ok")" "1" "codex app preflight reports tracked agent count"

orch_skill="$REPO_ROOT/skills/orch/SKILL.md"
submit_workflow="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
comments_workflow="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
merge_workflow="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
qa_workflow="$REPO_ROOT/skills/reviewer/workflows/qa-review.md"

assert_file_contains "$orch_skill" "#### Harness-Safe Shell" "orch skill documents Harness-Safe Shell section"
assert_file_contains "$orch_skill" 'Avoid inline `$(...)`, shell `for`/`while` loops' "Harness-Safe Shell section bans unsafe shell helper shapes"

# vstack#548 — runtime guidance for Codex never-approval shell-shape rejections:
# the Codex runtime block in the orch skill must pin the exact rejection string,
# the rewrite instruction (one simple command per tool call), and the
# ci-wait / approval-wait replacements for polling loops; the dev skill carries
# the one-line runtime pointer for dev agents that hit the same rejection.
dev_skill="$REPO_ROOT/skills/dev/SKILL.md"
assert_file_contains "$orch_skill" 'approval required by policy, but AskForApproval is set to Never' "orch skill pins the exact Codex never-approval rejection string"
assert_file_contains "$orch_skill" 'rewrite as one simple command per tool call' "orch skill tells runtime agents to rewrite rejected shapes as single commands"
assert_file_contains "$orch_skill" 'Replace polling loops with `ci-wait`' "orch skill routes CI polling loops to ci-wait"
assert_file_contains "$orch_skill" '`approval-wait` (review approval)' "orch skill routes approval polling to approval-wait"
assert_file_contains "$dev_skill" 'approval required by policy, but AskForApproval is set to Never' "dev skill carries the never-approval runtime pointer"

for workflow in "$submit_workflow" "$comments_workflow"; do
  workflow_name="$(basename "$workflow")"
  assert_file_not_contains "$workflow" 'BOT_WAIT_ARGS' "$workflow_name avoids bot wait arrays"
  assert_file_not_contains "$workflow" "IFS=',' read -ra REVIEW_BOTS" "$workflow_name avoids IFS reviewer splitting"
  assert_file_not_contains "$workflow" 'for BOT in "${REVIEW_BOTS[@]}"' "$workflow_name avoids reviewer shell loops"
  assert_file_not_contains "$workflow" '--reviewers "$BOT_REVIEWERS"' "$workflow_name avoids required BOT_REVIEWERS expansion"
  assert_file_not_contains "$workflow" 'printenv BOT_REVIEWERS' "$workflow_name avoids optional reviewer probing"
done

# vstack#638 + vstack#642 — reviewer gate: PR_REVIEW_GATE selects
# approval|review|off, with the legacy PR_APPROVAL_GATE mapping on -> approval
# and off -> off. The derivation is implemented ONCE in
# `approval-wait --resolve-mode`; workflows must read the mode through it,
# record pr_review.mode, pass the mode to the wait loop, and document the off
# semantics (skip wait, not-applicable gate, informational not_approved) and
# the review-mode obligation (triage, reply, resolve before CI verify).
# Auto-detection is forbidden by design.
assert_file_contains "$submit_workflow" 'approval-wait --resolve-mode' "submit-pr resolves the gate mode via approval-wait --resolve-mode"
assert_file_contains "$submit_workflow" 'PR_REVIEW_GATE' "submit-pr documents the PR_REVIEW_GATE setting"
assert_file_contains "$submit_workflow" '`on` → `approval` and `off` → `off`' "submit-pr documents the legacy PR_APPROVAL_GATE mapping"
assert_file_contains "$submit_workflow" 'pr_review.mode' "submit-pr records the resolved gate mode"
assert_file_contains "$submit_workflow" 'pr_approval.gate' "submit-pr records the off gate as not applicable"
assert_file_contains "$submit_workflow" 'no auto-detection' "submit-pr states the mode is explicit config only"
assert_file_contains "$submit_workflow" '--mode [GATE_MODE]' "submit-pr passes the resolved mode to approval-wait"
assert_file_contains "$submit_workflow" 'commenting-only review bots' "submit-pr names review mode as the commenting-only-bot setting"
assert_file_contains "$submit_workflow" 'triage every reviewer comment, reply to each thread, and resolve all threads' "submit-pr documents the review-mode triage obligation"
assert_file_contains "$submit_workflow" '| `reviewed` | Review of the current head recorded' "submit-pr routes the reviewed terminal status"
assert_file_contains "$submit_workflow" 'a force-push resets the wait' "submit-pr documents head re-read on force-push"
assert_file_not_contains "$submit_workflow" 'orch-env PR_APPROVAL_GATE' "submit-pr no longer re-derives the gate from orch-env"
assert_file_contains "$merge_workflow" 'approval-wait --resolve-mode' "merge-pr resolves the gate mode via approval-wait --resolve-mode"
assert_file_contains "$merge_workflow" 'informational only' "merge-pr demotes not_approved when the gate is off"
assert_file_contains "$merge_workflow" '--json --mode review' "merge-pr polls review mode with approval-wait --mode review"
assert_file_contains "$merge_workflow" 'treat `reviewed` as the met gate' "merge-pr treats reviewed as the met review-mode gate"
assert_file_not_contains "$merge_workflow" 'orch-env PR_APPROVAL_GATE' "merge-pr no longer re-derives the gate from orch-env"

# vstack#642 nudge — approval-wait nudges silent reviewers (once per head,
# clock reset on push, user-configured PR_REVIEW_NUDGE comment with a
# GitHub-native re-request fallback); submit-pr documents the settings and
# the full push -> new review -> resolve -> CI -> merge cycle.
assert_file_contains "$submit_workflow" 'PR_REVIEW_NUDGE_SECS' "submit-pr documents the nudge window setting"
assert_file_contains "$submit_workflow" 'PR_REVIEW_NUDGE' "submit-pr documents the nudge comment setting"
assert_file_contains "$submit_workflow" 'nudged at most once' "submit-pr documents the once-per-head nudge rule"
assert_file_contains "$submit_workflow" 'wait for a NEW review of the new head' "submit-pr states the push-to-re-review cycle explicitly"
assert_file_contains "$merge_workflow" 'PR_REVIEW_NUDGE' "merge-pr notes the nudge settings on the review-mode poll"

# drovr migration lesson — reruns re-execute the workflow definition pinned
# at the original event; gate/CI behavior changes only show on a fresh head.
assert_file_contains "$submit_workflow" 'pinned at the original triggering event' "submit-pr carries the rerun-pinning caveat"
assert_file_contains "$merge_workflow" 'pinned at the original triggering event' "merge-pr carries the rerun-pinning caveat"

# vstack#643 — Greptile is gone; orch docs and workflows must stay
# reviewer-agnostic ('reptile' catches both capitalizations).
for doc in "$REPO_ROOT"/skills/orch/workflows/*.md "$orch_skill" "$REPO_ROOT/skills/orch/README.md" "$REPO_ROOT/skills/orch/DEVELOPMENT.md"; do
  assert_file_not_contains "$doc" 'reptile' "$(basename "$doc") carries no stale Greptile reference"
done

# vstack#538 — bot reviews are async and bot-review-wait is RETIRED: no
# workflow may reference it, and bot-SPECIFIC prose (emoji reactions, sticky
# comments, checklist text) is never parsed as a gate. Local second-opinion
# review pre-PR drains bot-class findings at local speed; merge gates are
# internal review + CI green + zero unresolved comments + a GitHub-native
# approval verdict (reviewDecision / latestReviews) polled by approval-wait,
# with a 15-minute force-merge prompt when no verdict arrives.
for workflow in "$REPO_ROOT"/skills/orch/workflows/*.md; do
  workflow_name="$(basename "$workflow")"
  assert_file_not_contains "$workflow" 'bot-review-wait' "$workflow_name does not reference the retired bot-review-wait"
done
assert_file_not_contains "$orch_skill" 'bot-review-wait' "orch SKILL.md scripts docs drop the retired bot-review-wait"
assert_file_not_contains "$submit_workflow" 'defer-ci' "submit-pr no longer queues bot review via the defer-ci label"
assert_file_not_contains "$submit_workflow" 'Wait for Bot Review' "submit-pr drops the blocking bot review section"
assert_file_not_contains "$submit_workflow" 'checklist_timeout' "submit-pr drops bot checklist timeout routing"
assert_file_contains "$submit_workflow" '.agents/skills/second-opinion/scripts/second-opinion review' "submit-pr runs the local pre-PR review via second-opinion"
assert_file_contains "$submit_workflow" '.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 900 --json --mode [GATE_MODE]' "submit-pr polls the review gate via approval-wait"
assert_file_contains "$submit_workflow" 'reviewDecision == "APPROVED"' "submit-pr approval mode reads the GitHub-native reviewDecision"
assert_file_contains "$submit_workflow" 'latest review is APPROVED' "submit-pr approval mode documents the latestReviews fallback"
assert_file_contains "$submit_workflow" 'No [GATE_MODE]-gate verdict' "submit-pr prompts the user when no gate verdict arrives"
assert_file_contains "$submit_workflow" 'Force merge' "submit-pr offers an explicit force-merge override"
assert_file_contains "$submit_workflow" 'pr-threads [PR_NUMBER] --unresolved' "submit-pr merge gate checks unresolved threads deterministically"
assert_file_contains "$submit_workflow" '`status=complete`, `verdict=pass`' "submit-pr merge gate requires green CI"

# vstack#541 — the review gate (§ 4) must run BEFORE CI verification (§ 5):
# approval-gated repos only start CI once a review verdict exists, so the
# reverse order would deadlock. Compare section-header line numbers.
review_gate_line="$(grep -n -m1 '^## 4\. Review Gate' "$submit_workflow" | cut -d: -f1)"
ci_verify_line="$(grep -n -m1 '^## 5\. Verify CI' "$submit_workflow" | cut -d: -f1)"
submit_ordering="missing-sections"
if [[ -n "$review_gate_line" && -n "$ci_verify_line" && "$review_gate_line" -lt "$ci_verify_line" ]]; then
  submit_ordering="review-before-ci"
fi
assert_eq "$submit_ordering" "review-before-ci" "submit-pr orders the review gate (§ 4) before CI verify (§ 5)"
assert_file_contains "$submit_workflow" 'CI_WAIT_NO_CHECKS_GRACE' "submit-pr documents the ci-wait no-checks grace window"
assert_file_not_contains "$comments_workflow" 'Wait for All Bot Reviews' "review-pr-comments drops the bot completion pre-check"
assert_file_not_contains "$comments_workflow" 'sleep 300' "review-pr-comments does not sleep-wait for bot re-review"

assert_file_not_contains "$merge_workflow" "fetch --all --prune" "merge-pr avoids all-remote fetch during sync"
assert_file_not_contains "$merge_workflow" "git-https-auth -C [MAIN_REPO_ROOT] pull" "merge-pr avoids pull during post-merge sync"
assert_file_not_contains "$merge_workflow" "git -C [MAIN_REPO_ROOT] pull" "merge-pr avoids plain git pull during post-merge sync"
assert_file_not_contains "$merge_workflow" "git-https-auth -C [MAIN_REPO_ROOT] merge" "merge-pr keeps local merge outside HTTPS credential wrapper"
assert_file_contains "$merge_workflow" 'If `CHECK.transient == true`, route by the transient issue prefix' "merge-pr routes transient readiness before prompting"
assert_file_contains "$merge_workflow" '`ci_pending:` (checks still running)' "merge-pr treats pending CI as transient readiness"
assert_file_contains "$merge_workflow" 'Treat `CHECK.transient` as the' "merge-pr uses pr-merge transient contract"
assert_file_contains "$merge_workflow" '.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600' "merge-pr uses bounded CI wait for pending checks"
assert_file_contains "$merge_workflow" 'Do not repeat § 3.1 indefinitely' "merge-pr forbids unbounded transient wait loops"
assert_file_contains "$merge_workflow" 'git-https-auth -C [MAIN_REPO_ROOT] fetch --prune origin "+refs/heads/[BASE_BRANCH]:refs/remotes/origin/[BASE_BRANCH]"' "merge-pr sync fetches explicit origin base branch through HTTPS auth helper"
assert_file_contains "$merge_workflow" 'git -C [MAIN_REPO_ROOT] merge --ff-only "origin/[BASE_BRANCH]"' "merge-pr sync fast-forwards to quoted fetched origin base branch with plain git"
assert_file_not_contains "$merge_workflow" 'branch -D "$PR_BRANCH"' "merge-pr § 5a no longer force-deletes the PR branch unconditionally"
assert_file_contains "$merge_workflow" 'branch refs/heads/[PR_BRANCH]' "merge-pr § 5a guards branch delete against worktree checkout"
assert_file_contains "$merge_workflow" 'a GitHub-native approval verdict is required' "merge-pr treats not_approved as a merge gate in approval mode"
assert_file_contains "$merge_workflow" 'pr-merge [PR_NUMBER] --auto' "merge-pr re-runs check/queue-blocked merges with pr-merge --auto"
assert_file_contains "$merge_workflow" 'QUEUED FOR AUTO-MERGE' "merge-pr treats pr-merge exit 75 as success-pending"
assert_file_contains "$merge_workflow" 'gh pr view [PR_NUMBER] --json state,mergedAt' "merge-pr watches queued merges via PR state on a bounded poll"
assert_file_contains "$merge_workflow" 'isInMergeQueue mergeQueueEntry { state }' "merge-pr watch loop reads queue membership via GraphQL"
assert_file_contains "$merge_workflow" 'workflows/ci-fix.md [PR_NUMBER] § 1-7 → § 5 step 2' "merge-pr routes queue ejection / disarmed auto-merge into ci-fix recovery"
assert_file_contains "$merge_workflow" 'merge-group** run (workflow event `merge_group`)' "merge-pr points ci-fix at the failing merge-group run on ejection"
assert_file_contains "$merge_workflow" '.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]' "merge-pr re-confirms the review gate after a recovery push"

# vstack#543 — the ci-fix cycle caps are configurable via CI_FIX_MAX_CYCLES
# (default 6), read deterministically through orch-env; at the cap both
# workflows must report the failing checks and per-cycle attempts, never a
# bare "CI failing" / "persistent failure".
assert_file_contains "$merge_workflow" 'orch-env CI_FIX_MAX_CYCLES 6' "merge-pr reads the configurable ci-fix cycle budget via orch-env"
assert_file_contains "$merge_workflow" 'Max [MAX_CYCLES] recovery cycles per merge-pr run' "merge-pr bounds queued-merge recovery cycles by the configured budget"
assert_file_contains "$merge_workflow" 'report the failing check names' "merge-pr cap report names the failing checks"
assert_file_contains "$merge_workflow" 'what each cycle attempted' "merge-pr cap report lists per-cycle attempts"
assert_file_contains "$submit_workflow" 'orch-env CI_FIX_MAX_CYCLES 6' "submit-pr reads the configurable ci-fix cycle budget via orch-env"
assert_file_contains "$submit_workflow" 'Max [MAX_CYCLES] ci-fix cycles' "submit-pr bounds ci-fix cycles by the configured budget"
assert_file_contains "$submit_workflow" 'what each cycle attempted' "submit-pr cap report lists per-cycle attempts"
assert_file_not_contains "$submit_workflow" 'Max 2 ci-fix cycles' "submit-pr drops the hardcoded ci-fix cycle cap"
assert_file_not_contains "$merge_workflow" 'Max 2 recovery cycles' "merge-pr drops the hardcoded recovery cycle cap"

assert_file_not_contains "$qa_workflow" "Pipe benchmark output" "qa-review avoids pipe-based benchmark recording"
assert_file_not_contains "$qa_workflow" "pipe results" "qa-review avoids pipe-based perf capture guidance"
assert_file_contains "$qa_workflow" "Do not use shell pipelines" "qa-review bans Codex-unsafe benchmark shell plumbing"
assert_file_contains "$qa_workflow" "benchmark recorder fails closed on all-zero counters" "qa-review documents all-zero recorder fallback"
assert_file_contains "$qa_workflow" "targeted regression command reports numeric regressions" "qa-review reports targeted numeric regressions"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
