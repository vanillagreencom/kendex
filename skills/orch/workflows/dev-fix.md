# Dev Fix Workflow

Delegate fix items to a specialist dev agent. Works standalone (user-initiated) or managed (from review-pr).

## Inputs

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for specific issue |
| (from review-pr workflow) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 3) | `"self"` (default, standalone).
- `dev_agent` (optional): name of alive dev agent for fix delegation. If absent, determine from state/labels.
- `issue_id` (optional): workflow-state key — the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number. If absent, extracted from branch.
- `items` (optional): formatted review items. If absent, build from conversation context.
- `source` (optional): `pr-review` | `qa-review` | `review` | `local-review`. Default: `conversation`.
- `qa_agent` (optional): QA agent name (for qa-review source).

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

## 1. Build Fix Items

**If `items` provided** (managed): Use directly → § 2.

**If standalone**: Synthesize from conversation context.

1. **Gather context**: Identify what needs fixing. Read relevant files if needed.

2. **Format each fix item**:
   ```
   ---
   #[N] | [conversation] | [location or "TBD"]
   Description: "[WHAT IS WRONG]"
   Recommendation: "[HOW TO FIX]"
   ---
   ```

3. **Present to user**:

   <output_format>

   ### Fix Items — [ISSUE_ID]

   | # | Location | Description | Recommendation |
   |---|----------|-------------|----------------|
   | 1 | [location] | [description] | [recommendation] |

   </output_format>

4. **Ask user**: `Fix all` | Multi-select: `#N: [TITLE]` | `Cancel`

   | Choice | Action |
   |--------|--------|
   | Cancel | → END |
   | Items selected | → § 2 |

## 2. Delegate

1. **Determine agent**:
   - If `dev_agent` provided → use it (already alive)
   - Otherwise: from workflow state or issue labels
     ```bash
     .agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
     ```
     ```bash
     .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.agent // empty'
     ```
     ```bash
     .agents/skills/orch/scripts/tracker-for-issue [ISSUE_ID]
     ```
     Run each block as its own tool call. If state exists, use the second output as `AGENT`; otherwise leave `AGENT` empty. Use the tracker output as `TRACKER`.

     If `AGENT` is empty and `TRACKER` is `linear`, look up the Linear agent label:

     ```bash
     .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --format=compact
     ```
     Read the first `agent:*` label from the JSON output and use the suffix as `AGENT`.

     GitHub items: use `gh issue view ${ISSUE_ID#issue-} --json labels`, or infer from component paths.

2. **Group items by agent domain** if multi-domain. Order per [agent-sequencing.md](agent-sequencing.md).

3. **Detect team context**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.team_name // empty'
   ```
   Use the output as `TEAM`.

4. **Gather decision context** (decider skill):
   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```
   Collect decision IDs, summaries, and file paths from the JSON output for the `Decisions:` section below. Issue-linked lookup is exactly `decisions search --issue [ISSUE_ID]` — the decisions CLI has no bare `issue` action; never shorten the command in delegation guidance.

   The `path` fields in this JSON output are the ONLY authorized source for decision file paths in delegation guidance — the CLI resolves them from the decision index; never compose or recall a decision path from memory, however plausible the `DXXX-slug` looks (vstack#696). Verify every collected path before injecting it (belt-and-suspenders against index drift) — one simple command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   **If the check fails**: omit that path and carry the one-line note `- decision index lookup failed for [DECISION_ID]` in the `Decisions:` block instead — a broken path must never reach a specialist.

5. **Stamp the round, then delegate** to `[AGENT_TYPE]` agent (reuse existing dev agent if available). `dev_round_id` binds step 6 `dev-artifact-check` acceptance to THIS cycle's receipt (deterministic identity — vstack#776); `dev_delegated_at` is the watchdog deadline. Run each as its own tool call, immediately before the delegation:

   ```bash
   .agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
   ```
   Use the printed token as `[DEV_ROUND_ID]`. Also note the delegated review-item numbers (the `#[N]` in `[FORMATTED_ITEMS]`) as `[ITEM_NUMBERS]` (comma-separated) for step 6's exact item-set check.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` = technical fix, not procedure steps. The agent owns validate/commit/return per `dev/workflows/dev-fix.md`.
   - ✅ `"Read X from parent state and forward to child — fix in parent so descendants inherit."`
   - ❌ `"1. Apply fix. 2. Run validate. 3. Commit. 4. Let orchestrator handle linkage."`

   <delegation_format>
   Ultrathink.

   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]
   [If qa_agent:] QA: [QA_AGENT]

   Decisions:
   [For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
   [For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
   [If none: "- No linked decisions found."]

   Review items:
   [FORMATTED_ITEMS]
   </delegation_format>

6. **Wait for completion, then accept deterministically.** Acceptance is a function of two checks — **A** (the round-scoped on-disk artifact) and **B** (git completion for this fix round) — never the return message, which is informational for display (a return can be lost to a harness tool timeout mid-tail, vstack#770).

   **Check A** — read `dev_round_id`, then run `dev-artifact-check` in round mode with the delegated item numbers (run each as its own tool call):

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
   ```
   ```bash
   .agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items [ITEM_NUMBERS]
   ```
   `--expect-items [ITEM_NUMBERS]` requires the artifact's `items[]` to cover EXACTLY the delegated set (each item present once, no unknown/duplicate, decisions valid, reasoning non-empty) — a 1-item artifact cannot satisfy a 10-item group. The round id guarantees only THIS cycle's receipt is read (vstack#776).

   **Check B** — the fix commit landed and nothing was left behind:

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   # Must be empty (clean worktree).
   git -C "[WORKTREE_PATH]" log -1 --oneline
   # Shows the fix commit reported by the artifact/return.
   ```
   `B = pass` when the worktree is clean and the reported fix commit resolves in the log — or the round applied nothing and correctly made no new commit (an all-items-skipped fix legitimately leaves HEAD unchanged; B passes on a clean worktree).

   **Decision table** (pure function of A and B):

   | A (artifact) | B (git) | Action |
   |---|---|---|
   | `ok==true` | pass | **Accept** — first confirm exact-commit binding (artifact `.commit` == `git -C [WORKTREE_PATH] rev-parse HEAD`; an all-items-skipped round's `.commit` is the unchanged HEAD), then parse item decisions (Applied/Skipped/Blocked), commits, and validate from the return when present, else from the artifact's `items[]`/`commit`/`validate` (recovery, vstack#770). → step 7. |
   | `ok==true` | fail | Artifact claims done but the worktree is dirty / the commit is missing. **Re-read git ONCE after a brief pause** (transient lag) before classifying B failed; if still failing → re-delegate only the specific missing step (commit or revert leftover work). |
   | `ok==false` | pass | Fix code appears landed but the round did **not** finish (its per-item decisions are unproven — B shows a clean tree, not that THIS round's tail ran). Do NOT re-run the fix and do NOT accept on git alone. Send ONE **report-only tail-reconciliation** nudge: *"re-run only your completion tail — write your dev-return artifact (`dev-return-write --kind fix … --round-id [DEV_ROUND_ID]` with one `--item` per review item) and re-report your item decisions; do NOT re-run the fix."* Accept only once a valid artifact for THIS `dev_round_id` appears (→ the `ok==true` row). |
   | `ok==false` | fail | **Not done** — no completion evidence. Wait to the per-delegation deadline, then escalate (ping → respawn) per [SKILL escalation](../SKILL.md#wait-for-agent-return-before-acting). |

   **Dev-vs-reviewer asymmetry (do not "align").** Dev accepts on the round-scoped artifact plus git; reviewers have no such independent signal (their JSON is the deliverable) and re-delegate on `ok==false`. Do not import the reviewer rule here — full rationale in [SKILL § Wait for Agent Return Before Acting](../SKILL.md#wait-for-agent-return-before-acting).

7. **Update state** — run each block as its own tool call; the appends run once per item, so they can't be folded into a single expression:
   ```bash
   # For each applied item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] fixed_items '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
   ```
   ```bash
   # For each escalated/skipped item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] escalated_items '{"description":"[DESC]","location":"[LOC]","reason":"[REASON]","source":"[SOURCE]"}'
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] cycles
   ```

---

## 3. Return

**If standalone**:

1. **Present results**:

   <output_format>

   ### Fix Results — [ISSUE_ID]

   | # | Decision | Reasoning |
   |---|----------|-----------|
   | N | Applied/Skipped/Blocked | [explanation] |

   Commits: [SHAs or "none"]
   Validate: [status]

   </output_format>

2. **END**

**If managed**: Return parsed results to caller (item decisions, commits, validation status), then return to parent workflow.
