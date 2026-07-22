# Dev Implementation Workflow

Delegate development work to specialist agent(s). Handles single issues and bundled multi-agent work.

## Inputs

| Command | Behavior |
|---------|----------|
| `dev-start` | Implement current branch's issue |
| `dev-start [ISSUE_ID]` | Implement specific issue (or sub-issue from start-new session) |
| (from start-worktree / review-pr workflows) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 4) | `"self"` (default, standalone).
- `issue_id` (optional): workflow-state key — the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number. If absent, extracted from branch.

**Standalone init** (`lifecycle: "self"` only):
```bash
# If ARG was provided, use it as ISSUE_ID. Otherwise:
.agents/skills/orch/scripts/git-context issue-from-branch .
```
Use the output as `ISSUE_ID`.

Apply [Worktree Scope](../SKILL.md#worktree-scope): if in a worktree and `ISSUE_ID` ≠ the current branch's issue, ask the user before proceeding. Resolve `WT_PATH`:
- Inside a worktree → use current directory as `WT_PATH`
- Main repo, worktree exists → run `.agents/skills/worktree/scripts/worktree path [ISSUE_ID]` and use the output as `WT_PATH`
- Main repo, worktree missing → ask the user before creating

```bash
.agents/skills/orch/scripts/tracker-for-issue [ISSUE_ID]
```
Use the output as `TRACKER`.

If workflow state already exists, skip initialization:

```bash
.agents/skills/orch/scripts/workflow-state exists --json "$ISSUE_ID"
```

If `.exists` is `false`, initialize workflow state. Linear only: first check for parent context from a start-new sub-issue:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --format=compact
```
Read `.parent.identifier // empty` from the JSON output and use it as `PARENT_ID`.

If `PARENT_ID` is non-empty, check whether the parent workflow state exists:

```bash
.agents/skills/orch/scripts/workflow-state exists --json "$PARENT_ID"
```

If `.exists` is `true`, read the parent team and worktree:

```bash
.agents/skills/orch/scripts/workflow-state get [PARENT_ID] '.team_name // empty'
```
```bash
.agents/skills/orch/scripts/workflow-state get [PARENT_ID] '.worktree // empty'
```
Run each block as its own tool call (a `// empty` default can't be folded into a combined object without collapsing it). Use the outputs as `TEAM` and `WT_PATH`.

Then initialize child state with the inherited context:

```bash
.agents/skills/orch/scripts/git-context branch "$WT_PATH"
.agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "[BRANCH_FROM_PREVIOUS_COMMAND]" --team "$TEAM"
```

Otherwise, initialize state with the current worktree:

```bash
.agents/skills/orch/scripts/git-context branch "$WT_PATH"
.agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "[BRANCH_FROM_PREVIOUS_COMMAND]"
```

## 1. Determine Agent

`agent:X` label → X | No label → infer from component paths.

```bash
# Linear
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --format=compact
# Read `.labels[]` from the JSON output.

# GitHub
gh issue view ${ISSUE_ID#issue-} --json labels --jq '.labels[].name'
```

---

## 2. Delegate to Specialist Agent(s)

**Dev agents persist for the entire session.** Never shutdown dev agents — they stay alive for fix cycles, pending children, and PR review fixes. Only the caller's finalization step shuts them down.

**Codex runtime agent type rule**: The selected `[AGENT_TYPE]` is the Codex `agent_type` for the first harness spawn call. The Codex `task_name` schema accepts only `[a-z0-9_]` and rejects hyphenated names before launch (vstack#751): a hyphenated `[AGENT_TYPE]` spawns with hyphens translated to underscores in the runtime `task_name` only (`agent_type` unchanged), attempted before any `worker` fallback; `child_sessions` keys, reports, and delegation records keep the canonical hyphenated name. Do not launch `worker` and simulate the selected dev identity in the prompt unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated `agent_type`. In that fallback, spawn `agent_type=worker` but keep the logical selected agent name in bootstrap/delegation text, reports, and workflow-state keys. Use `worker` only when no matching custom agent exists, when the selected agent is intentionally generic, or after the generated-agent spawn is rejected/unavailable; record the runtime `agent_type` and fallback reason in status and workflow state.

Before each implementation delegation — the single delegation, and **every group's delegation in bundled mode** — capture the current `HEAD`, record the delegation timestamp, and mint a fresh per-delegation round id. `dev_round_id` binds § 3 `dev-artifact-check` acceptance to exactly THIS delegation's receipt — deterministic identity, immune to a stale or cross-round receipt at a shared path (vstack#776); `dev_delegated_at` is the watchdog deadline (SKILL § Wait for Agent Return). Run each as its own tool call:

```bash
.agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
```
```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```
Use the printed token as `[DEV_ROUND_ID]` and embed it in the delegation prompt (`Round ID:` line) so the agent passes `--round-id [DEV_ROUND_ID]` to `dev-return-write`. In bundled mode, re-mint it per group (§ 2.d).

**After each spawn**, persist the agent session:
```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.child_sessions["[AGENT_TYPE]"] = {"status": "active", "agent_id": "[AGENT_OR_TASK_ID]", "runtime_agent_type": "[RUNTIME_AGENT_TYPE]", "agent_type_fallback": [FALLBACK_REASON_JSON_OR_NULL]}'
```

`"status": "active"` marks the session live for reviewer slot accounting (`review-pr.md` § 2 counts active child sessions when computing wave sizes) — omitting it makes a live dev agent free a phantom reviewer slot (vstack#698). Only the caller's finalization step retires the record (`start-worktree.md` § 5.5 sets `status` to `"closed"`).

### If Single Issue

Delegate to a `[AGENT_TYPE]` agent. Wait for completion. Parse: Branch, Commit, QA Labels, Summary.

**Single issue delegation prompt:**

<delegation_format>
Ultrathink.

Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [LABELS]
Blocks: [BLOCKED_ISSUE_IDS or "none"]
</delegation_format>

**GitHub items**: replace the `Issue:` line with `GitHub Issue: [OWNER/REPO]#[N]`. Leave `Artifact Key:` as `[ISSUE_ID]` — the normalized workflow-state key (`issue-N`), which is what orch's `dev-artifact-check --issue [ISSUE_ID]` resolves; the agent must key the artifact to it, never to the tracker-native `OWNER/REPO#N`.

### If Bundled Issue

**Agent grouping**: Group pending sub-issues by `agent:[TYPE]` label. See [agent-sequencing.md](agent-sequencing.md) for ordering. Process sequentially: first group → wait for completion → validate (§ 3) → collect handoff notes → next group.

**Handoff collection** (between agent groups): After each group returns and passes § 3 validation, before delegating the next group:

a. For each sub-issue completed by any prior agent group (cumulative):
   ```bash
   .agents/skills/linear/scripts/linear.sh cache comments list [COMPLETED_ISSUE_ID]
   ```
   Read bodies containing `Handoff Notes` from the JSON output.
b. Extract "Handoff Notes" sections. Combine into a single block.
c. Include in next delegation as `Handoff from prior agents:` (see below). Omit if none found.
d. Re-run the § 2 pre-delegation stamps for this group — **all three**: `set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]`, `set-now [ISSUE_ID] dev_delegated_at`, AND `new-round-id [ISSUE_ID] dev_round_id` — immediately before delegating it, and embed the freshly printed `[DEV_ROUND_ID]` in this group's delegation. Each group's round id scopes its own artifact path (`tmp/dev-return-[PARENT_ID]-[DEV_ROUND_ID].json`), so a prior group's receipt can never be mis-accepted for this group (vstack#776).

Delegate to a `[AGENT_TYPE]` agent. Wait for completion. Parse: Branch, Commit, QA Labels, Summary.

**Bundled issue delegation prompt:**

<delegation_format>
Ultrathink.

Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Parent: [ISSUE_ID]
Sub-Issues:
[For completed sub-issues:]
↳ [SUB_ISSUE_1] (completed): [TITLE]
[For pending sub-issues assigned to this agent:]
↳ [SUB_ISSUE_2]: [TITLE] | blocks: [SUB_ISSUE_3]
↳ [SUB_ISSUE_3]: [TITLE] | blocked by: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_4]: [TITLE]  ← nested child of [SUB_ISSUE_3]

Worktree: [WORKTREE_PATH]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [parent labels]
Blocks: [blocked-issue-ids or "none"]

**Work pending issues only** (completed listed for context). Respect blocking order: complete blockers before blocked issues.

**Scope**: Implement YOUR assigned sub-issues only. You may fix/connect prior agents' code if needed, but do not implement work belonging to other agents' pending sub-issues.

Current status of issue bundle: [Brief summary of what was already done from other agents.]

[If handoff notes collected from prior agent groups:]
Handoff from prior agents:
[[ISSUE_ID] (agent:[TYPE])]:
- [extracted handoff notes]
</delegation_format>

## 3. Validate Agent Return

**Expected format**: `Branch: ... | Commit: [SHA] | QA Labels: ... | Summary: Posted ✓`

Acceptance is a deterministic function of two checks — **A** (the on-disk completion artifact) and **B** (git/tracker completion) — never of the return message, which is informational for display only. A return can be lost when a long validation exceeds the harness tool timeout mid-tail and ends the turn (vstack#770); acceptance must not depend on it.

**Check A — completion artifact.** Read `dev_round_id`, then validate the round-scoped receipt (run each as its own tool call):

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
```
```bash
.agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]
```
`A` = the `ok` field (`ok == true` / `ok == false`). The check resolves `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[DEV_ROUND_ID].json` and confirms its internal `round_id` matches, so ONLY this delegation's receipt can satisfy A — a stale, same-second, or cross-group receipt cannot (vstack#776).

**Check B — git/tracker completion.** Run ALL checks; `B = pass` only when every one passes:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pre_delegate_sha // empty'
.agents/skills/orch/scripts/git-context head [WORKTREE_PATH]

# Check the implementation produced committed work.
git -C "[WORKTREE_PATH]" log -1 --oneline
# The previous two SHA outputs must differ unless pre_delegate_sha was empty.

# Check no implemented files were left outside the commit.
git -C "[WORKTREE_PATH]" status --porcelain
# The status output must be empty.

# Linear only: check state + summary (auto-includes pending children from bundle)
.agents/skills/linear/scripts/linear.sh issues validate-completion [ISSUE_ID] --include-children-of [ISSUE_ID]
```

**GitHub/ad-hoc**: no tracker validation — `B` requires a new commit (`HEAD` advanced from `pre_delegate_sha`) and a clean worktree.

Per-field B failures and the targeted re-delegation each one implies (used by the decision table's re-delegate action):

| Field | Expected | Missing-step re-delegation |
|-------|----------|----------------------------|
| commit | `HEAD` advanced from `pre_delegate_sha` | Re-delegate § 2: commit the work |
| worktree | `git status --porcelain` empty | Re-delegate § 2: commit or revert leftover files |
| `.all_ok` | `true` | Check `.results[]` below |
| `.results[].state_ok` | `true` | Re-delegate § 2 |
| `.results[].has_summary` | `true` | Re-delegate § 2: post the summary |

`state_ok` checks the per-role managed state: bundle-expanded sub-issues (from `--include-children-of`) must be `Done`, while the primary target — the managed session-root issue, **whether or not it has a parent** — must be in a pre-merge state (`In Progress` or `In Review`, per `start-worktree.md` § 5.3). Do not expect `Done` for the session root before merge.

**Decision table** — the acceptance action is a pure function of A and B (never the return message):

| A (artifact) | B (git/tracker) | Action |
|---|---|---|
| `ok==true` | pass | **Accept** — completion confirmed even if no return message arrived (recovery, vstack#770). First confirm **exact-commit binding**: the artifact's `.commit` must equal current `git -C [WORKTREE_PATH] rev-parse HEAD` — reject/flag a mismatch so a later unrelated commit is never attributed to this round. → Store QA state. |
| `ok==true` | fail | Artifact claims done but git/tracker disagree. **Re-read git/tracker ONCE after a brief pause** before classifying B failed (a transient tracker/API lag must not trigger a duplicate-summary/label re-delegation). If still failing → re-delegate only the specific missing step(s) from the table above (uncommitted / leftover work). Do NOT proceed. |
| `ok==false` | pass | Code appears landed but the round did **not** finish — B proves code landed, not that the tail ran (validate, labels, a summary belonging to THIS round, and this agent's authorship are unproven; an unrelated commit advances HEAD and Linear `validate-completion` matches any prior "Completion Summary"). Do NOT declare complete and do NOT re-run the implementation. Send ONE **report-only tail-reconciliation** nudge: *"re-run only your completion tail — write your dev-return artifact (`dev-return-write … --round-id [DEV_ROUND_ID]`) and re-report validate status / QA labels / summary; do NOT re-run the implementation."* Accept only once a valid artifact for THIS `dev_round_id` appears (→ the `ok==true` row). |
| `ok==false` | fail | **Not done** — no completion evidence. Do NOT proceed; wait to the per-delegation deadline, then escalate (ping → respawn) per [SKILL escalation](../SKILL.md#wait-for-agent-return-before-acting). |

**Why `A=false, B=pass` recovers the tail rather than accepting** (external-review hardening): B (HEAD advanced + clean worktree + tracker state) proves code *appears* landed, not that the delegated round completed — an unrelated commit advances HEAD, and Linear `validate-completion` matches any prior completion comment with no per-round freshness bound. Only a valid artifact for the current `dev_round_id` proves THIS agent finished THIS round's tail, so acceptance always converges on the `ok==true` path.

**Dev-vs-reviewer asymmetry (do not "align").** Dev accepts on the round-scoped artifact plus git/tracker; reviewers have no such independent signal (their JSON is the deliverable) and re-delegate on `ok==false`. Do not import the reviewer's re-delegate-on-`ok==false` rule here — full rationale in [SKILL § Wait for Agent Return Before Acting](../SKILL.md#wait-for-agent-return-before-acting).

When a return message DID arrive it stays authoritative for display; A and B decide acceptance. Never proceed on a fail with "may have a different format" or similar excuses.

**Store QA state** (on Accept):
```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.qa_labels = [QA_LABELS_ARRAY] | .sub_issues = [SUB_ISSUE_IDS_ARRAY]'
```

**If validate failures reported**: Investigate, suggest sub-issue (summary, steps, agent). Ask user before creating.

---

## 4. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — dev implementation complete.
