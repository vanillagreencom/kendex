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
assert_file_contains "$orch_skill" 'Replace polling loops with the orch waiters `.agents/skills/orch/scripts/ci-wait`' "orch skill routes CI polling loops to the pathed orch ci-wait (vstack#662)"
assert_file_contains "$orch_skill" '`.agents/skills/orch/scripts/approval-wait` (review approval)' "orch skill routes approval polling to the pathed orch approval-wait"
assert_file_contains "$dev_skill" 'approval required by policy, but AskForApproval is set to Never' "dev skill carries the never-approval runtime pointer"

# vstack#661 — the same Codex policy also rejects some porcelain verbs (top-level
# `git rebase`) outright; the runtime block must route that rejection to the
# worktree skill's guarded restack path and its documented cherry-pick replay
# fallback instead of improvised history rewrites or force-pushes. The fallback
# section's own contract is linted in skills/worktree/tests/restack_fallback_doc.sh.
worktree_skill="$REPO_ROOT/skills/worktree/SKILL.md"
assert_file_contains "$orch_skill" 'Policy-blocked rebase (cherry-pick replay fallback)' "orch skill routes policy-rejected rebases to the worktree fallback section"
assert_file_contains "$orch_skill" 'worktree restack continue|skip|abort' "orch skill names the guarded restack controls for policy-rejected rebases"
assert_file_contains "$worktree_skill" '### Policy-blocked rebase (cherry-pick replay fallback)' "worktree skill carries the fallback section the orch pointer targets"

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

# vstack#644 — bounded reviewer waves under an agent-slot budget:
# REVIEWER_SLOT_BUDGET (default 0 = unlimited/persistent) is read via
# orch-env; when the reviewer set exceeds the available slots (budget minus
# the primary minus live persistent dev/QA sessions), review workflows run
# reviewers in sequential waves — launch up to the available slots, validate
# each report artifact, retire the completed session to release its slot,
# launch the next wave. Re-review recreates retired reviewers fresh and
# points them at the current diff plus their prior report artifact; the
# invariant is that review state lives in on-disk artifacts and workflow
# state, never in reviewer session memory. The all-reviewers-persistent
# mandate is budget-conditional, not absolute.
review_pr_workflow="$REPO_ROOT/skills/orch/workflows/review-pr.md"
review_workflow="$REPO_ROOT/skills/orch/workflows/review.md"
codebase_workflow="$REPO_ROOT/skills/orch/workflows/review-codebase.md"
orch_readme="$REPO_ROOT/skills/orch/README.md"
orch_development="$REPO_ROOT/skills/orch/DEVELOPMENT.md"
state_schema="$REPO_ROOT/skills/orch/schemas/workflow-state.md"

assert_file_contains "$review_pr_workflow" 'orch-env REVIEWER_SLOT_BUDGET 0' "review-pr reads the reviewer slot budget via orch-env"
assert_file_contains "$review_pr_workflow" 'REVIEWER_SLOTS = SLOT_BUDGET - 1 - LIVE_AGENTS' "review-pr derives available slots from budget minus primary minus live sessions"
assert_file_contains "$review_pr_workflow" 'sequential waves of up to `REVIEWER_SLOTS`' "review-pr documents bounded sequential waves"
assert_file_contains "$review_pr_workflow" 'persistent when the budget allows, waves when it does not' "review-pr states the single budget-conditional policy"
assert_file_contains "$review_pr_workflow" 'never in reviewer session memory' "review-pr states the artifact-state invariant"
assert_file_contains "$review_pr_workflow" "re-stamp immediately before each wave's delegation batch" "review-pr re-stamps the freshness boundary per wave"
assert_file_contains "$review_pr_workflow" '.review_wave_done += ["[AGENT]"]' "review-pr records wave completion in workflow state"
assert_file_contains "$review_pr_workflow" 'shut the reviewer'"'"'s session down (retiring each completed reviewer releases its slot for the next wave)' "review-pr retires each completed reviewer in wave mode"
assert_file_contains "$review_pr_workflow" 'return to § 2.2 for the next wave' "review-pr loops back to launch the next wave"
assert_file_contains "$review_pr_workflow" 'recreate it fresh' "review-pr recreates retired reviewers fresh on re-review"
assert_file_contains "$review_pr_workflow" 'Read your prior report [PRIOR_REPORT_PATH] and re-read the current diff before reviewing.' "review-pr delegation points recreated reviewers at diff and prior report"
assert_file_contains "$review_pr_workflow" 'collab spawn failed: agent thread limit reached' "review-pr names the runtime thread-limit error for spawn fallback"
assert_file_not_contains "$review_pr_workflow" 'Do NOT shutdown reviewers — needed for re-review in § 4.' "review-pr drops the unconditional persistent-reviewer mandate"

assert_file_contains "$review_workflow" 'orch-env REVIEWER_SLOT_BUDGET 0' "review reads the reviewer slot budget via orch-env"
assert_file_contains "$review_workflow" 'sequential waves of up to the available slots' "review documents bounded sequential waves"
assert_file_contains "$review_workflow" 'never in reviewer session memory' "review states the artifact-state invariant"

assert_file_contains "$codebase_workflow" 'orch-env REVIEWER_SLOT_BUDGET 0' "review-codebase honors the reviewer slot budget"

assert_file_contains "$orch_skill" 'orch-env REVIEWER_SLOT_BUDGET 0' "orch skill documents the slot-budget read"
assert_file_contains "$orch_skill" 'persistent when the budget allows, waves when it does not' "orch skill states the budget-conditional lifecycle policy"
assert_file_contains "$orch_skill" 'never in reviewer session memory' "orch skill states the artifact-state invariant"
assert_file_contains "$orch_skill" 'collab spawn failed: agent thread limit reached' "orch skill Codex note names the thread-limit error"
assert_file_contains "$orch_skill" 'REVIEWER_SLOT_BUDGET = "4"' "orch skill Codex note sets the four-slot budget"
assert_file_contains "$orch_readme" 'REVIEWER_SLOT_BUDGET' "orch README documents the reviewer slot budget setting"
assert_file_contains "$orch_development" '## Reviewer Slot Budget' "orch DEVELOPMENT carries the slot-budget design rationale"
assert_file_contains "$state_schema" 'review_wave_done' "workflow-state schema documents wave completion tracking"

# The root settings example ships only in the vstack source checkout, not in
# downstream installs — assert on it only when present.
settings_example="$REPO_ROOT/vstack.settings.toml.example"
if [[ -f "$settings_example" ]]; then
  assert_file_contains "$settings_example" 'REVIEWER_SLOT_BUDGET = "0"' "settings example documents the reviewer slot budget default"
fi

# vstack#715 — a configured-unlimited REVIEWER_SLOT_BUDGET does not override
# the runtime's real thread cap. When a persistent launch hits the runtime
# thread-limit error, review-pr must demote the cycle to bounded waves in
# place: the reviewers that did spawn become the first wave, the observed
# spawn count becomes the persisted wave size (reviewer_slots_observed),
# re-review cycles stay in waves, and the user gets a one-line
# recommendation to set the observed budget. The former manual workaround
# (running the wave invariant by hand with persisted artifacts) is the
# documented automatic behavior.
assert_file_contains "$review_pr_workflow" 'Persistent-mode thread-limit recovery' "review-pr documents persistent-mode thread-limit recovery"
assert_file_contains "$review_pr_workflow" 'observed successful spawn count' "review-pr sizes recovery waves from the observed spawn count"
assert_file_contains "$review_pr_workflow" '.reviewer_slots_observed = [OBSERVED_SPAWN_COUNT] | .review_wave_done = []' "review-pr persists the demotion and resets wave tracking in one write"
assert_file_contains "$review_pr_workflow" ".reviewer_slots_observed // 0" "review-pr § 2 checks for a recorded demotion before choosing persistent mode"
assert_file_contains "$review_pr_workflow" 'set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in vstack.settings.toml [env]' "review-pr recommends the observed runtime budget to the user"
assert_file_contains "$review_pr_workflow" 'documented automatic behavior' "review-pr states the manual wave workaround is now automatic"
assert_file_contains "$review_workflow" 'persistent-mode thread-limit recovery' "review routes unlimited-budget spawn failures to the recovery rule"
assert_file_contains "$codebase_workflow" 'persistent-mode thread-limit recovery' "review-codebase routes unlimited-budget spawn failures to the recovery rule"
assert_file_contains "$state_schema" 'reviewer_slots_observed' "workflow-state schema documents the observed wave size"
assert_file_contains "$orch_skill" 'demote the cycle to bounded waves automatically' "orch skill Codex note documents automatic demotion at unlimited budget"
assert_file_contains "$orch_skill" 'persisted as `reviewer_slots_observed`' "orch skill lifecycle section persists the observed wave size"
assert_file_contains "$orch_development" 'advisory, the runtime cap authoritative (vstack#715)' "orch DEVELOPMENT records the runtime-authority rationale"
assert_file_contains "$orch_readme" 'demote to bounded waves automatically' "orch README documents automatic demotion"

# vstack#714 — a required command with an env-assignment prefix (e.g.
# `LC_ALL=C tools/test-ci-changes`) is rejected under Codex approval=never
# for the prefix shape alone, even when an issue spec or delegated
# verification list requires it verbatim. The canonical normalization
# happens where the command is ACCEPTED into the workflow (prepare /
# delegation assembly), not where it runs: confirm the ambient environment
# satisfies the precondition, then run the bare command unchanged; the
# `env VAR=value cmd` wrapper is not the documented substitute.
dev_implement="$REPO_ROOT/skills/dev/workflows/dev-implement.md"
assert_file_contains "$orch_skill" 'Env-assignment prefixes are normalized at acceptance' "orch skill states the acceptance-time normalization rule"
assert_file_contains "$orch_skill" 'run the bare `cmd args` unchanged' "orch skill keeps the bare required command exact"
assert_file_contains "$orch_skill" 'not the documented substitute' "orch skill rules out the env wrapper as the canonical form"
assert_file_contains "$orch_skill" 'never survives delegation' "orch skill normalizes delegated command lists before delegation"
assert_file_contains "$dev_skill" 'env-assignment prefix' "dev skill carries the normalization rule"
assert_file_contains "$dev_skill" 'not an acceptable substitute' "dev skill rules out the env wrapper"
assert_file_contains "$dev_implement" 'Normalize env-prefixed required commands' "dev-implement normalizes env-prefixed commands at acceptance"
assert_file_contains "$dev_implement" 'ambient precondition check first, then the bare command' "dev-implement § 5 runs the normalized form"

# vstack#721 — a literal backtick anywhere in a generated command is
# classified as command substitution under Codex approval=never and rejected
# before it runs, even for a read-only search over Markdown inline code. The
# canonical rule (regex hex escape `\x60` in single quotes, regex mode, one
# simple command) lives in reviewer SKILL.md § Harness-Safe Shell; the dev
# sites that generate validation/audit search commands must carry the concise
# rule and point back at it rather than duplicating the essay.
reviewer_skill="$REPO_ROOT/skills/reviewer/SKILL.md"
dev_fix="$REPO_ROOT/skills/dev/workflows/dev-fix.md"
assert_file_contains "$reviewer_skill" 'regex hex escape `\x60` in single quotes' "reviewer skill holds the canonical hex-escape rule"
assert_file_contains "$reviewer_skill" "rg -n '\\x60vstack refresh\\x60' skills/" "reviewer skill shows the worked safe-search example"
assert_file_contains "$orch_skill" 'command substitution to the classifier' "orch Harness-Safe Shell bans literal backticks in generated commands"
assert_file_contains "$orch_skill" 'reviewer SKILL.md § Harness-Safe Shell' "orch skill cross-references the canonical backtick rule"
assert_file_contains "$dev_skill" 'Never put a literal backtick in a generated search command' "dev skill carries the backtick prohibition"
assert_file_contains "$dev_skill" '`\x60`' "dev skill shows the hex-escape replacement"
assert_file_contains "$dev_implement" 'regex hex escape `\x60` in single quotes' "dev-implement § 5 prescribes the hex-escape search shape"
assert_file_contains "$dev_fix" 'never put a literal backtick in the command' "dev-fix § 1 carries the backtick prohibition"

# vstack#722 — Codex approval=never rejects the top-level `git rebase`
# porcelain verb itself; the classification is harness-side, so no user
# authorization or delegation can lift it. The canonical replacement for a
# clean linear issue branch (guarded worktree --reuse/--restack path, then
# the cherry-pick replay with its dirty-tree and merge-commit bailouts)
# lives in worktree SKILL.md § Policy-blocked rebase; orch and dev guidance
# must route agents there instead of letting them retry or force-push.
worktree_skill="$REPO_ROOT/skills/worktree/SKILL.md"
assert_file_contains "$worktree_skill" 'Policy-blocked rebase (cherry-pick replay fallback)' "worktree skill holds the canonical rebase-replacement recipe"
assert_file_contains "$worktree_skill" 'never replay over uncommitted changes' "worktree recipe refuses a dirty tree"
assert_file_contains "$worktree_skill" 'If the range contains a merge commit' "worktree recipe bails out on merge commits in the range"
assert_file_contains "$orch_skill" 'Never author a workflow step that assumes top-level `git rebase` will run' "orch Harness-Safe Shell forbids authoring rebase steps"
assert_file_contains "$orch_skill" 'no user authorization or delegation can lift' "orch skill states the rejection is harness-side classification"
assert_file_contains "$orch_skill" '§ Policy-blocked rebase (cherry-pick replay fallback)' "orch skill routes to the canonical worktree recipe"
assert_file_contains "$orch_skill" 'report a blocker instead of improvising' "orch skill makes dirty-tree/merge-commit ranges a blocker"
assert_file_contains "$dev_skill" 'a policy-blocked `git rebase` (vstack#722)' "dev skill carries the rebase-rejection rule"
assert_file_contains "$dev_skill" '§ Policy-blocked rebase (cherry-pick replay fallback)' "dev skill routes to the canonical worktree recipe"

# vstack#660 — GitHub-issue orchestration stores workflow state under the
# normalized `issue-N` key, so workflow docs must define `issue_id`/[ISSUE_ID]
# as that workflow-state key (never the bare GitHub issue number), and
# review-pr-comments § 6.1 step 8 must append replies under [ISSUE_ID] with
# the key clarified in place.
assert_file_contains "$comments_workflow" 'workflow-state append [ISSUE_ID] pr_comment_review.replied' "review-pr-comments § 6.1 step 8 appends replies under the [ISSUE_ID] state key"
assert_file_contains "$comments_workflow" '# [ISSUE_ID] is the workflow-state key (e.g. issue-290), matching the' "review-pr-comments § 6.1 step 8 clarifies the state key in place"
assert_file_contains "$comments_workflow" 'never the bare GitHub issue number' "review-pr-comments defines issue_id as the normalized state key"
assert_file_contains "$submit_workflow" 'never the bare GitHub issue number' "submit-pr defines issue_id as the workflow-state key"
for workflow_path in dev-fix dev-start initialize post-summary review-pr; do
  assert_file_contains "$REPO_ROOT/skills/orch/workflows/$workflow_path.md" \
    'workflow-state key — the normalized issue ID' \
    "$workflow_path defines caller issue_id as the normalized workflow-state key"
done
assert_file_contains "$orch_skill" 'never the bare GitHub issue number' "orch skill states the workflow-state key convention"
assert_file_contains "$state_schema" 'never the bare GitHub issue number' "workflow-state schema states the key convention"

# vstack#696 — decision-path provenance: during an orch re-review wave the
# delegation prompt cited two non-existent decision files composed from
# memory, and a reviewer burned a cycle discovering the real ones. Every
# workflow that injects decision references must (a) source paths ONLY from
# the decider CLI's JSON output (the CLI resolves them from the decision
# index) and (b) verify each path with a single `test -f` before injection,
# omitting failures with a one-line lookup-failure note instead of passing
# the broken path through. The delegation templates carry a slot for that
# note, submit-pr applies the same rule to PR-body decision citations, and
# the reviewer workflow carries the receiving-side fallback so a stray bad
# path never costs another review cycle.
reviewer_review_workflow="$REPO_ROOT/skills/reviewer/workflows/review.md"
for workflow_path in dev-fix review review-pr review-pr-comments; do
  workflow="$REPO_ROOT/skills/orch/workflows/$workflow_path.md"
  assert_file_contains "$workflow" 'ONLY authorized source' "$workflow_path pins the decider CLI JSON output as the only decision-path source"
  assert_file_contains "$workflow" 'never compose or recall a decision path from memory' "$workflow_path bans memory-composed decision paths"
  assert_file_contains "$workflow" 'test -f [DECISION_FILE_PATH]' "$workflow_path verifies each decision path before injection"
  assert_file_contains "$workflow" 'decision index lookup failed for [DECISION_ID]' "$workflow_path omits failed paths with the lookup-failure note"
  assert_file_contains "$workflow" 'For each decision whose path failed verification' "$workflow_path delegation template carries the failed-verification slot"
  assert_file_not_contains "$workflow" 'For each matching decision: "' "$workflow_path delegation template injects only verified decisions"
done
assert_file_contains "$submit_workflow" 'test -f [DECISION_FILE_PATH]' "submit-pr verifies decision paths cited in the PR body"
assert_file_contains "$submit_workflow" 'omit entries whose path fails' "submit-pr omits unverified decision paths from the PR body"
assert_file_contains "$reviewer_review_workflow" 'decision-path provenance rule' "reviewer review workflow names the provenance rule on broken paths"
assert_file_contains "$reviewer_review_workflow" 'do not hunt for the intended file' "reviewer review workflow stops reviewers from burning a cycle on bad paths"
assert_file_contains "$reviewer_review_workflow" 'decisions search "[RELEVANT_KEYWORDS]"' "reviewer review workflow routes recovery through the decider CLI"

# vstack#698 — dev-session status in reviewer slot accounting: the dev-start
# persistence write recorded child_sessions without a status field while the
# review-pr live-session query counted only status == "active", so a live
# persistent dev agent freed a phantom slot and reviewer fan-out hit the
# runtime thread limit. Both sides are fixed for defense in depth: the writer
# stamps status "active", the reader defaults a missing status to active
# (legacy records persist in workflow-state files across sessions), the
# schema documents the back-compat rule, and the start-worktree shutdown
# step retires records to "closed".
dev_start_workflow="$REPO_ROOT/skills/orch/workflows/dev-start.md"
start_worktree_workflow="$REPO_ROOT/skills/orch/workflows/start-worktree.md"
assert_file_contains "$dev_start_workflow" '.child_sessions["[AGENT_TYPE]"] = {"status": "active"' "dev-start persistence write stamps status active"
assert_file_contains "$dev_start_workflow" 'marks the session live for reviewer slot accounting' "dev-start explains why the status stamp matters"
assert_file_contains "$review_pr_workflow" '(.value.status // "active") == "active"' "review-pr live-session count defaults a missing status to active"
assert_file_not_contains "$review_pr_workflow" 'select(.value.status == "active")' "review-pr drops the strict status match that missed legacy records"
assert_file_contains "$review_pr_workflow" 'record with no `status` field counts as active' "review-pr documents the legacy-record back-compat rule"
assert_file_contains "$state_schema" 'missing `status` field as active' "workflow-state schema documents missing-status-means-active"
assert_file_contains "$state_schema" '"status": "active"' "workflow-state schema example shows an active child session"
assert_file_contains "$start_worktree_workflow" '.value.status = "closed"' "start-worktree shutdown retires child sessions to closed"
assert_file_contains "$orch_skill" 'a record with no `status` field counts as active' "orch skill slot-accounting note carries the back-compat rule"

assert_file_not_contains "$qa_workflow" "Pipe benchmark output" "qa-review avoids pipe-based benchmark recording"
assert_file_not_contains "$qa_workflow" "pipe results" "qa-review avoids pipe-based perf capture guidance"
assert_file_contains "$qa_workflow" "Do not use shell pipelines" "qa-review bans Codex-unsafe benchmark shell plumbing"
assert_file_contains "$qa_workflow" "benchmark recorder fails closed on all-zero counters" "qa-review documents all-zero recorder fallback"
assert_file_contains "$qa_workflow" "targeted regression command reports numeric regressions" "qa-review reports targeted numeric regressions"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
