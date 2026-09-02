# Dev Fix Workflow

Delegate fix items to a specialist dev agent. Standalone (user-initiated) or managed (from a review workflow).

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for a specific issue |
| (from a review workflow) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 3) or `"self"` (default); `dev_agent` — a live dev agent; `issue_id` — the workflow-state key, the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number; `items` — formatted review items; `source` — `pr-review` | `qa-review` | `review` | `local-review` (default `conversation`); `qa_agent`.

**Standalone init** (`lifecycle: "self"`). Use the argument as `ISSUE_ID`, else `git-context issue-from-branch .`. Apply [Worktree Scope](../SKILL.md#workflow-execution) and resolve `WT_PATH` as `git-context repo-root "[DIR]"` (inside a worktree `[DIR]` is `.`; from the main repo, `worktree path [ISSUE_ID]`, asking before creating).

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

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
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

`auto-recommended` takes the recommended option (`Fix all`) without asking; anything else asks `Fix all` | multi-select `#N: [TITLE]` | `Cancel`. The always-ask set in [SKILL.md § The Cycle](../SKILL.md#the-cycle) applies in every mode.

Cancel ends the workflow; a selection goes to § 2.

## 2. Delegate

1. **Determine the agent.** `dev_agent` wins. Otherwise read state, falling back to the issue's `agent:*` label or the component paths:

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.agent // empty'
   ```

2. **Group items by agent domain** when multi-domain, ordered per [references/skill-rules.md § Coordination](../references/skill-rules.md#coordination). Prefer two scoped rounds over one broad round past roughly eight items.

3. **Gather decision context**:

   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```

   The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory. Verify each before injecting it, one command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

4. **Stamp the round**, as separate tool calls immediately before delegating, then arm the watchdog per [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure):

   ```bash
   .agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
   ```

   Then persist the delegated item set on disk. Write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file-write tool as a JSON array of `{"n": [N], "text": "[ITEM_TEXT]", "reach": "[REACH]"}`, one per delegated item. `[ITEM_TEXT]` is that item's formatted block verbatim. `[REACH]` names the shipped producer, user action, or fixture that reaches the finding — a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix: disposition it per [`../references/finding-disposition.md` § Filing bar](../references/finding-disposition.md#filing-bar) instead of delegating it. The writer refuses a short list of shapes, enumerated in [`../schemas/dev-round.md`](../schemas/dev-round.md) and in `dev-round-write --help`; it is a backstop and not the judgement — a reach it accepts has been recorded, not approved.

   Decide whether this fix round may add protected files. [`../schemas/dev-round.md` § Protected additions](../schemas/dev-round.md#protected-additions) is the sole scope definition. The default is none.

   When the list is non-empty, pass those exact repository-relative paths to the writer as one blank-separated `--adds` value, and render the same list after `Adds:` in the delegation — one path is `Adds: tools/one-helper.sh`, several are `Adds: tools/one-helper.sh skills/x/scripts/check`. A blank or tab separates, so a path containing whitespace is read as two paths and cannot be authorized as one — check for that before you write the line.

   ```bash
   .agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json [--adds "[REPO_RELATIVE_PATHS]"]
   ```

   Exit 3 is the branch-size refusal. Stop before delegation, discard this item set, and report the current and baseline counts with `Cut required`. Every other nonzero exit is an environment or authorization failure and also stops the workflow.

   **The cut is a round of its own**, and the only one that runs while the branch is over the cap. Mint a fresh round id for it, delegate cutting back to the Done-when as its items, and stamp the record with `--cut`, which skips the over-limit refusal and nothing else — the branch is still measured, so an unreadable or non-positive `pr.baseline_lines` still exits 2 here:

   ```bash
   .agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --cut
   ```

   A cut item's `reach` is the branch this round shrinks — cut items name work, not a finding, so do not improvise a finding-shaped value; `the finding` is on the writer's refusal list and exits 2.

   Accept it through step 5 like any other round: its item set is checked the same way, and `--expect-items-from-round` additionally refuses the receipt unless the branch came back to the cap. Declare `--cut` only on the round that does the cutting — a round declared a cut that leaves the branch oversized cannot be accepted at all. Resume the item-by-item fix path with another fresh round once the branch is under the cap.

   `--issue` takes the normalized workflow-state key — the value the delegation's `Artifact Key:` line carries. Only when every item's text is plain (no backticks or quotes) may you pass `--item [N] '[ITEM_TEXT]' '[REACH]'` groups inline in one command instead.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../references/skill-rules.md#format-tags-are-literal)). `Recommendation:` is the technical fix, never procedure steps — the agent owns validate, commit, and return.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]
   QA: [QA_AGENT]
   [If the round may add files: "Adds: [REPO_RELATIVE_PATHS]"]

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

   `--expect-items-from-round` reads the step-4 record. It requires the artifact's `items[]` to cover that record's set, each item once with no unknowns or duplicates, valid decisions, and non-empty reasoning. Exit 2 means the expected set cannot be established. Never recreate the record after delegation and never fall back to `--expect-items`; mint and delegate a fresh round.

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
   | `wait` | fail | **Not done.** Wait to the deadline, then escalate per [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure). |
| `retry` | any | An artifact for THIS round exists but fails a gate. The check's `reason` names it. `unapproved_additions` also returns every refused path in `files`; start a fresh round that names each deliberate path in `Adds:`, or order the files cut. A failing `validate` re-delegates fixing the validation; an identity/schema failure gets the report-only tail-rewrite nudge. `comparison_failed` means git cannot compare the round's recorded base commit against HEAD, so the dev agent has nothing to repair; mint a fresh round. `additions_unattributable` means a rebase moved that base off the branch, so the round's additions were never gated and no path is named. A fresh round does not recover the gate — `dev-round-write` stamps its `base_sha` at the rebased HEAD, which already contains anything this round added — so read the blocked round's own commits for paths in [`../schemas/dev-round.md` § Protected additions](../schemas/dev-round.md#protected-additions), name each deliberate one in the fresh round's `Adds:` line, and cut the rest before delegating it. That `Adds:` line is the authorization itself here, not something the fresh round's gate re-derives from its base, which is why the reading is not optional. The blocked round then closes through the fresh round, as it does for any other retry reason. `cut_not_shrunk` means a round declared a cut left the branch above the cap — the cut is unfinished, so delegate the rest of it in a fresh `--cut` round. `cut_unmeasurable` means the cap itself could not be read, which is an environment failure, not the agent's; fix the state or the base ref and re-run the check. Never accept, and never treat it as absent. |

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
   .agents/skills/orch/scripts/workflow-state append-file [ISSUE_ID] pr_comment_review.patched_causes tmp/patched-cause-[ISSUE_ID].json
   ```

   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] cycles
   ```

   Each write clears the item from BOTH buckets before appending its own entry, matched on the RECORDED entry's (location, description), the § 8 key. One write per item, and the item stands in exactly one bucket, once.

   The entry goes through a file, never `--arg` or `--argjson`.

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
