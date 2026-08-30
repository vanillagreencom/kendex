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

2. **Group items by agent domain** when multi-domain, ordered per [SKILL.md § Coordination](../SKILL.md#coordination). Prefer two scoped rounds over one broad round past roughly eight items — one 24-item round injected 8 new blockers, 2 of them P1.

3. **Gather decision context**:

   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```

   The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory. Verify each before injecting it, one command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

4. **Stamp the round**, as separate tool calls immediately before delegating, then arm the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

   ```bash
   .agents/skills/orch/scripts/worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
   ```

   `worktree-claim` exit 75 aborts the delegation (another session holds this worktree; stderr names the holder); exit 1 stops the workflow and is reported. Its printed token is the delegation's `Worktree Lease:` line.

   Then persist the delegated item set on disk. Write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file-write tool as a JSON array of `{"n": [N], "text": "[ITEM_TEXT]"}`, one per delegated item. `[ITEM_TEXT]` is that item's formatted block verbatim.

   Decide whether this fix round may add protected files. [`../schemas/dev-round.md` § Protected additions](../schemas/dev-round.md#protected-additions) is the sole scope definition. The default is none.

   When the list is non-empty, write `[WORKTREE_PATH]/tmp/dev-round-adds-[DEV_ROUND_ID].json` with the harness file-write tool as a JSON array of exact repository-relative paths. Render the same array after `Adds:` in the delegation, preserving JSON string boundaries, including `Adds: ["tools/one path.sh"]` and `Adds: ["tools/one path.sh","skills/x/scripts/check;safe"]`. Pass only the data-file path to the writer:

   ```bash
   .agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json [--adds-file [WORKTREE_PATH]/tmp/dev-round-adds-[DEV_ROUND_ID].json]
   ```

   `--issue` takes the normalized workflow-state key — the value the delegation's `Artifact Key:` line carries. Only when every item's text is plain (no backticks or quotes) may you pass `--item [N] '[ITEM_TEXT]'` pairs inline in one command instead.

   **An analysis (read-only) round has no delegated item set** — skip `dev-round-write` entirely and run step 6's Check A without an expected-set flag.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` is the technical fix, never procedure steps — the agent owns validate, commit, and return.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   Worktree Lease: [WORKTREE_LEASE]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]
   QA: [QA_AGENT]
   [If the round may add files: "Adds: [REPO_RELATIVE_PATHS_JSON_ARRAY]"]

   Decisions:
   [For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
   [For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
   [If none: "- No linked decisions found."]

   Review items:
   [FORMATTED_ITEMS]
   </delegation_format>

5. **Accept the round.** Acceptance is a pure function of **A** (the round-scoped artifact) and **B** (git completion), never the return message.

   **Check A** — two tool calls:

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
   ```
   ```bash
   .agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
   ```

   `--expect-items-from-round` reads the step-4 record and its immutable authorization under the repository's git common directory. It requires an exact match and requires the artifact's `items[]` to cover that set, each item once with no unknowns or duplicates, valid decisions, and non-empty reasoning. Exit 2 means authorization cannot be established. Never recreate either record after delegation and never fall back to `--expect-items`; mint and delegate a fresh round.

   **Check B**:

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   git -C "[WORKTREE_PATH]" log -1 --oneline
   ```

   `B = pass` when the worktree is clean and the reported fix commit resolves in the log — or when the round applied nothing and made no commit.

   | A (verdict) | B (git) | Action |
   |---|---|---|
   | `accept` | pass | **Accept.** First confirm exact-commit binding: the artifact's `.commit` equals `git -C [WORKTREE_PATH] rev-parse HEAD` (an all-skipped round's `.commit` is the unchanged HEAD). Then read the item decisions, commits, and validate status from the return when present, else from the artifact. → step 6. |
   | `accept` | fail | The artifact claims done but the worktree is dirty or the commit is missing. Re-read git ONCE after a brief pause, then re-delegate only the missing step: commit, or revert leftover work. |
   | `wait` | pass | Do NOT re-run the fix and do NOT accept on git alone. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`dev-return-write --kind fix … --round-id [DEV_ROUND_ID]` with one `--item` per review item; if the delegation is gone from your context, your item set is on disk at `tmp/dev-round-[ISSUE_ID]-[DEV_ROUND_ID].json`) and re-report your item decisions; do NOT re-run the fix."* Accept only when a valid artifact for THIS round appears. |
   | `wait` | fail | **Not done.** Wait to the deadline, then escalate per [SKILL.md § Round Closure](../SKILL.md#round-closure). |
| `retry` | any | An artifact for THIS round exists but fails a gate. The check's `reason` names it. `unapproved_additions` also returns every refused path in `files`; start a fresh round that names each deliberate path in `Adds:`, or order the files cut. A failing `validate` re-delegates fixing the validation; an identity/schema failure gets the report-only tail-rewrite nudge. Never accept, and never treat it as absent. |

   **Analysis rounds** run Check A without an expected-set flag, and B expects no new commit and a clean worktree. On accept, read the `summary` recommendation and decide the next step: delegate the actual fixes as a fresh round, or close and re-scope with reasoning.

6. **Record the outcome** — one write per item, and the item's own text never enters a shell word:

   Write the item's entry to `tmp/state-item-[ISSUE_ID].json` with the harness file tool, one item at a time. Fixed:

   ```json
   {"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}
   ```

   Escalated, `[OUTCOME]` carrying the item's accepted decision — Blocked → `"blocked"`, Skipped → `"skipped"`:

   ```json
   {"description":"[DESC]","location":"[LOC]","reason":"[REASON]","outcome":"[OUTCOME]","source":"[SOURCE]"}
   ```

   Then bind that file into the write for the bucket the item lands in. Fixed:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile item tmp/state-item-[ISSUE_ID].json '$item[0] as $e | .fixed_items = ((.fixed_items // []) | map(select(.location != $e.location or .description != $e.description))) | .escalated_items = ((.escalated_items // []) | map(select(.location != $e.location or .description != $e.description))) | .fixed_items += [$e]'
   ```

   Escalated:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile item tmp/state-item-[ISSUE_ID].json '$item[0] as $e | .fixed_items = ((.fixed_items // []) | map(select(.location != $e.location or .description != $e.description))) | .escalated_items = ((.escalated_items // []) | map(select(.location != $e.location or .description != $e.description))) | .escalated_items += [$e]'
   ```

   A fixed item's root cause is recorded too, in `pr_comment_review.patched_causes` — the one record [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence) reads, whichever loop patched the cause. `pr-review`, `qa-review`, and `review` rounds reach that rule through this step, and a cause missing from it is one the next pass reads as never patched and answers with an ordinary patch round. One entry per fixed item, through a file like the entry above:

   ```json
   {"cause": "[ONE_LINE]", "commit": "[SHA]"}
   ```

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile cause tmp/patched-cause-[ISSUE_ID].json '$cause[0] as $e | .pr_comment_review.patched_causes = ((.pr_comment_review.patched_causes // []) + [$e])'
   ```

   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] cycles
   ```

   A re-reported item whose recorded fix did not hold takes a second disposition while a bucket still lists it against the SHA of the failed fix, and an item escalated in one cycle can be fixed in a later one, so each write clears the item from BOTH buckets before appending its own entry. The match is the RECORDED entry's (location, description), the § 8 key: a re-reporting reviewer copies those two fields verbatim off the delegation's Fixed line, and the sha it names rides in the finding's recommendation, which no key reads. One write per item, and the item stands in exactly one bucket, once.

   The entry goes through a file, never `--arg` or `--argjson`. A double quote in the description invalidates a pasted JSON argument and an apostrophe ends the shell word, and a write that fails leaves the stale entry standing with nothing recorded.

   `cycles` is the general fix-round tally that fills review-pr § 1.2's previous-cycle block; it decides no cap. The re-review budget is `rereview_cycles`, raised only by review-pr § 4's `rereview_panel` write, so no fix round spends it and neither does § 7's QA re-check.


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
