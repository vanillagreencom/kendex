# Dev Fix Workflow

Delegate fix items to a specialist dev agent. Standalone (user-initiated) or managed (from a review workflow).

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for a specific issue |
| (from a review workflow) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 3) or `"self"` (default); `dev_agent` — a live dev agent; `issue_id` — the workflow-state key, the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number; `items` — formatted review items; `source` — `pr-review` | `qa-review` | `review` | `local-review` (default `conversation`); `qa_agent`.

**Standalone init** (`lifecycle: "self"`). Use the argument as `ISSUE_ID`, else `git-context issue-from-branch .`. Apply [Worktree Scope](../SKILL.md#workflow-execution) and resolve `WT_PATH` (inside a worktree, the current directory; from the main repo, `worktree path [ISSUE_ID]`, asking before creating).

## 1. Build Fix Items

`items` provided (managed) → use them directly, → § 2.

Standalone: synthesize from conversation context, reading the relevant files first. Format each as:

```text
---
#[N] | [conversation] | [location or "TBD"]
Description: "[WHAT IS WRONG]"
Recommendation: "[HOW TO FIX]"
---
```

<output_format>

### Fix Items — [ISSUE_ID]

| # | Location | Description | Recommendation |
|---|----------|-------------|----------------|
| 1 | [location] | [description] | [recommendation] |

</output_format>

Then resolve the decision mode:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

`auto-recommended` takes the recommended option (`Fix all`) without asking and logs it; anything else asks `Fix all` | multi-select `#N: [TITLE]` | `Cancel`. The always-ask set in [SKILL.md § The Cycle](../SKILL.md#the-cycle) applies in every mode.

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] auto_decisions '"auto-selected: Fix all — [REASON]"'
```

Cancel ends the workflow; a selection goes to § 2.

## 2. Delegate

1. **Determine the agent.** `dev_agent` wins. Otherwise read state, falling back to the issue's `agent:*` label or the component paths:

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.agent // empty'
   ```

2. **Group items by agent domain** when multi-domain, ordered per [SKILL.md § Coordination](../SKILL.md#coordination). Prefer two scoped rounds over one broad round past roughly eight items — a round large enough to lose focus injects new blockers instead of clearing them.

3. **Gather decision context**:

   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```

   The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory, however plausible the slug looks. Verify each before injecting it, one command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

4. **Stamp the round**, as separate tool calls immediately before delegating, then arm the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

   ```bash
   .agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
   ```

   Then persist the delegated item set on disk. Write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file-write tool — a JSON array of `{"n": [N], "text": "[ITEM_TEXT]"}`, one per delegated item, `[ITEM_TEXT]` being that item's formatted block verbatim — then:

   ```bash
   .agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json
   ```

   `--issue` takes the same normalized workflow-state key everything else here uses — the value the delegation's `Artifact Key:` line carries. A mismatch strands the record where no reader looks. The file route keeps backticks and quotes out of the command line; only when every item's text is plain may you pass `--item [N] '[ITEM_TEXT]'` pairs inline in one command instead. The record is what a respawned agent reads to recover its items and what step 6's exact-set check reads.

   **An analysis (read-only) round has no delegated item set** — skip `dev-round-write` entirely and run step 6's Check A without an expected-set flag.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` is the technical fix, never procedure steps — the agent owns validate, commit, and return.

   <delegation_format>
   Ultrathink.

   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]
   QA: [QA_AGENT]

   Decisions:
   [For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
   [For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
   [If none: "- No linked decisions found."]

   Review items:
   [FORMATTED_ITEMS]
   </delegation_format>

5. **Accept the round.** Acceptance is a pure function of **A** (the round-scoped artifact) and **B** (git completion), never the return message — a return is routinely absent when a long validation outlasts the agent's turn.

   **Check A** — two tool calls:

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
   ```
   ```bash
   .agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
   ```

   `--expect-items-from-round` reads the step-4 record and requires the artifact's `items[]` to cover EXACTLY that set — each item once, no unknowns or duplicates, valid decisions, non-empty reasoning — so a 1-item artifact cannot satisfy a 10-item group. On exit 2 (record missing) the step-4 persistence never ran: write the record now from the delegated items still in context and re-run; only if that context is also gone, fall back to `--expect-items [ITEM_NUMBERS]` with numbers you can still prove.

   **Check B**:

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   git -C "[WORKTREE_PATH]" log -1 --oneline
   ```

   `B = pass` when the worktree is clean and the reported fix commit resolves in the log — or when the round applied nothing and correctly made no commit, which legitimately leaves `HEAD` unchanged.

   | A (artifact) | B (git) | Action |
   |---|---|---|
   | `ok==true` | pass | **Accept.** First confirm exact-commit binding: the artifact's `.commit` equals `git -C [WORKTREE_PATH] rev-parse HEAD` (an all-skipped round's `.commit` is the unchanged HEAD). Then read the item decisions, commits, and validate status from the return when present, else from the artifact. → step 6. |
   | `ok==true` | fail | The artifact claims done but the worktree is dirty or the commit is missing. Re-read git ONCE after a brief pause, then re-delegate only the missing step: commit, or revert leftover work. |
   | `ok==false` | pass | Fix code appears landed but the round did not finish — its per-item decisions are unproven. Do NOT re-run the fix and do NOT accept on git alone. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`dev-return-write --kind fix … --round-id [DEV_ROUND_ID]` with one `--item` per review item; if you no longer have the delegation, your item set is on disk at `tmp/dev-round-[ISSUE_ID]-[DEV_ROUND_ID].json`) and re-report your item decisions; do NOT re-run the fix."* Accept only when a valid artifact for THIS round appears. |
   | `ok==false` | fail | **Not done.** Wait to the deadline, then escalate per [SKILL.md § Round Closure](../SKILL.md#round-closure). |

   **Analysis rounds** run Check A without an expected-set flag, and B expects no new commit and a clean worktree. On accept, read the `summary` recommendation and decide the next step: delegate the actual fixes as a fresh round, or close and re-scope with reasoning.

6. **Record the outcome** — one tool call per block; the appends run per item and cannot fold into one expression:

   ```bash
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] fixed_items '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] escalated_items '{"description":"[DESC]","location":"[LOC]","reason":"[REASON]","outcome":"[OUTCOME]","source":"[SOURCE]"}'
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] cycles
   ```

   `[OUTCOME]` carries the item's accepted decision: Blocked → `"blocked"`, Skipped → `"skipped"`. The audit builder maps it to distinct origins, so a deliberately skipped item is never filed as an unfixable blocker.

## 3. Return

**Standalone**:

<output_format>

### Fix Results — [ISSUE_ID]

| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [explanation] |

Commits: [SHAs or "none"]
Validate: [status]

</output_format>

**Managed**: return the parsed item decisions, commits, and validation status to the caller.
