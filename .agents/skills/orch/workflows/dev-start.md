# Dev Implementation Workflow

Delegate implementation to specialist agent(s). Handles a single issue and a bundled multi-agent work item.

| Command | Behavior |
|---------|----------|
| `dev-start` | Implement the current branch's issue |
| `dev-start [ISSUE_ID]` | Implement a specific issue |
| (from start-worktree / review-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 4) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number; `audit_bundle` — `true` only from review-pr's post-audit path.

**Standalone init** (`lifecycle: "self"`). Use the argument as `ISSUE_ID`, else:

```bash
.agents/skills/orch/scripts/git-context issue-from-branch .
```

Resolve `TRACKER` first — `github` skips the Linear-only container preflight.

**Container preflight** (Linear only, before any workflow state exists). Fetch the bundle with `--with-bundle`:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

Apply the Ancestor gate ([SKILL.md § Coordination](../SKILL.md#coordination)). A container is refused before anything is initialized, with its unblocked children surfaced as the startable items. A `(one PR)` ancestor promotion is TERMINAL for this invocation: stop and route to `/orch start [PARENT_ID]` rather than continuing with the child's id. A blocked child stops with its live blockers named. Caller context `audit_bundle: true` is equivalent to the `(one PR)` marker: skip the refusal for that parent and carry `Audit Bundle: yes` in the delegation. Managed callers already ran this gate.

Apply [Worktree Scope](../SKILL.md#workflow-execution) and resolve `WT_PATH` as `git-context repo-root "[DIR]"`. Inside a worktree `[DIR]` is `.`; from the main repo it is `worktree path [ISSUE_ID]` when that exists, and ask the user before creating one when it does not.

Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.

Initialize state unless it exists:

```bash
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```
```bash
.agents/skills/orch/scripts/git-context branch [WT_PATH]
```
```bash
.agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree [WT_PATH] --branch "[BRANCH_FROM_PREVIOUS_COMMAND]"
```

## 1. Determine Agent

An `agent:X` label selects X; with no label, infer from the component paths the issue touches.

```bash
# Linear
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --format=compact
# GitHub
gh issue view [N] --json labels --jq '.labels[].name'
```

## 2. Delegate

Dev agents persist for the whole session — never shut one down here; only the caller's finalization step does.

Before EVERY implementation delegation, including each group's delegation in bundled mode, run these four as separate tool calls:

```bash
.agents/skills/orch/scripts/worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]
```
```bash
.agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
```
```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

`worktree-claim` exit 75 aborts the delegation: another session holds this worktree (stderr names the holder) — coordinate with that owner, never re-run to take the tree. Exit 1: stop and report it. Embed its printed token as `[WORKTREE_LEASE]` in the delegation's `Worktree Lease:` line, the round token as `[DEV_ROUND_ID]` in the `Round ID:` line, and arm the watchdog (backgrounded `dev-artifact-check --wait 600 …`) per [SKILL.md § Round Closure](../SKILL.md#round-closure). On Codex, resolve spawn parameters with `scripts/spawn-adapter spawn [AGENT_TYPE]`.

After each spawn, persist the session:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.child_sessions["[AGENT_TYPE]"] = {"status": "active", "agent_id": "[AGENT_OR_TASK_ID]", "runtime_agent_type": "[RUNTIME_AGENT_TYPE]", "agent_type_fallback": [FALLBACK_REASON_JSON_OR_NULL]}'
```

### Single issue

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command; it must print [WORKTREE_PATH]. On any other path, stop and report where the shell started.
Worktree Lease: [WORKTREE_LEASE]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [LABELS]
</delegation_format>

**GitHub items** replace the `Issue:` line with `GitHub Issue: [OWNER/REPO]#[N]`. `Artifact Key:` stays `[ISSUE_ID]`, never `OWNER/REPO#N`.

### Bundled issue

Group pending sub-issues by `agent:[TYPE]` label and order them per [SKILL.md § Coordination](../SKILL.md#coordination) sequencing. Process groups sequentially: delegate → wait → validate (§ 3) → collect handoff notes → next group.

Between groups, read each completed sub-issue's comments for a `Handoff Notes` section and combine them into the next delegation. Re-run all four § 2 stamps immediately before each group's delegation.

Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Parent: [ISSUE_ID]
Sub-Issues:
↳ [SUB_ISSUE_1] (completed): [TITLE]
↳ [SUB_ISSUE_2]: [TITLE] | blocks: [SUB_ISSUE_3]
↳ [SUB_ISSUE_3]: [TITLE] | blocked by: [SUB_ISSUE_2]

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command; it must print [WORKTREE_PATH]. On any other path, stop and report where the shell started.
Worktree Lease: [WORKTREE_LEASE]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [parent labels]
Audit Bundle: [yes — only when caller context `audit_bundle: true`; omit otherwise]
Parent Title: [PARENT_TITLE — the `.title` from the preflight bundle read, verbatim]

**Work pending issues only** (completed ones are listed for context). Complete blockers before blocked issues.

**Scope**: implement YOUR assigned sub-issues only. You may fix or connect prior agents' code, but do not implement work belonging to another agent's pending sub-issues.

Current status of the bundle: [what other agents already did]

Handoff from prior agents:
[[ISSUE_ID] (agent:[TYPE])]:

- [extracted handoff notes]
</delegation_format>

## 3. Accept The Round

Acceptance is a pure function of **A** (the on-disk artifact) and **B** (git and tracker completion). The return message is display-only — run A/B on the § 2 watchdog deadline rather than waiting for one.

**Check A** — two tool calls:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
```
```bash
.agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]
```

`A` is the `verdict` field — `accept`, `wait`, or `retry`. The check resolves `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[DEV_ROUND_ID].json` and matches its internal `round_id`.

**Check B** — `B = pass` only when every check passes:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pre_delegate_sha // empty'
.agents/skills/orch/scripts/git-context head [WORKTREE_PATH]
git -C "[WORKTREE_PATH]" status --porcelain
.agents/skills/linear/scripts/linear.sh issues validate-completion [ISSUE_ID] --include-children-of [ISSUE_ID]
```

`HEAD` must differ from `pre_delegate_sha`, `status --porcelain` must be empty, and the Linear validation (Linear only) must report `.all_ok`. `--include-children-of` expands explicit single-PR bundles and audit-created sub-issues worked in this session. `state_ok` expects bundle-expanded sub-issues `Done` and the session-root issue in a pre-merge state (`In Progress` or `In Review`) — never `Done` before merge. GitHub and ad-hoc rounds skip tracker validation: B is the new commit plus the clean worktree.

| A (verdict) | B (git/tracker) | Action |
|---|---|---|
| `accept` | pass | **Accept** even with no return message. First confirm exact-commit binding — the artifact's `.commit` must equal `git -C [WORKTREE_PATH] rev-parse HEAD`. → Store QA state. |
| `accept` | fail | Re-read ONCE after a brief pause; if still failing, re-delegate only the specific missing step: commit the work, or commit/revert leftover files, or post the summary. Do not proceed. |
| `wait` | pass | Do NOT re-run the implementation. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`dev-return-write … --round-id [DEV_ROUND_ID]`) and re-report validate status, QA labels, and summary; do NOT re-run the implementation."* Accept only when a valid artifact for THIS round appears. |
| `wait` | fail | **Not done.** Wait to the deadline, then escalate per [SKILL.md § Round Closure](../SKILL.md#round-closure). |
| `retry` | any | An artifact for THIS round exists but fails a gate — the check's `reason` names it. A failing `validate` re-delegates fixing the validation; an identity/schema failure gets the report-only tail-rewrite nudge. Never accept, and never treat it as absent. |

**Analysis rounds.** When THIS round was delegated as investigate-and-recommend, the receipt is `kind: analysis`: no `commit`, no `validate`, the recommendation in `summary`. B expects NO new commit and a clean worktree, with no exact-commit binding and no validate gate. On A `accept` + B pass, read the recommendation and decide the next step: delegate implementation as a fresh round, close with reasoning, or re-scope. A `kind` that does not match what was delegated → the `retry` row.

Do not import the reviewer's re-delegate-on-invalid rule ([references/artifact-checks.md](../references/artifact-checks.md)).

**Store QA state** on accept:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.qa_labels = [QA_LABELS_ARRAY] | .sub_issues = [SUB_ISSUE_IDS_ARRAY]'
```

Map each Done-when item to the files serving it, in the PR body; every round measures against that map, never against its own last state, and an unmapped hunk is cut unless it is a [landing enabler](../../dev/SKILL.md#engineering-rules).

## 4. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
