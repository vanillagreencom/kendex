# Dev Fix Workflow

Delegate a set of fix items to a dev agent, then accept the round from its receipt. A user starts it standalone; a review workflow starts it managed. Run it first line to last for one fix round.

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for a specific issue |
| (from a review workflow) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 3) or `"self"` (default); `dev_agent`, a live dev agent; `issue_id`, the workflow-state key ([workflow-state.md § Keys](../schemas/workflow-state.md#keys)), never the bare GitHub issue number; `items`, formatted review items; `source`, `pr-review` | `pr-comments` | `qa-review` | `review` | `local-review` (default `conversation`); `qa_agent`.

## Start

With `lifecycle: "managed"`, `ISSUE_ID` is the caller's `issue_id` and `[WORKTREE_PATH]` its `worktree`. With `lifecycle: "self"`, resolve `ISSUE_ID` as [dev-start.md § Start](dev-start.md#start) step 1 does, and `[WORKTREE_PATH]` as its step 3 does. `[WORKTREE_PATH]` fills every `Worktree:` line below.

## 1. Build Fix Items

Managed: take the caller's `items` under [dev-round.md § Item text](../schemas/dev-round.md#item-text), then go to § 2.

Standalone: read the relevant files. Write each item from the conversation as:

```text
#[N] | [conversation] | [location or "TBD"]
Description: "[WHAT IS WRONG]"
Recommendation: "[HOW TO FIX]"
Owner: [OWNER]
```

Include the `Owner:` line only when the finding has an `owner`.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Fix Items — [ISSUE_ID]

| # | Location | Description | Recommendation |
|---|----------|-------------|----------------|
| 1 | [location] | [description] | [recommendation] |

</output_format>

Then read the decision mode:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

`auto-recommended` takes the recommended option, `Fix all`, without asking. Any other value asks `Fix all` | multi-select `#N: [TITLE]` | `Cancel`. The ask set in [communication-modes.md](../references/communication-modes.md) § Ask set applies in every mode. `Cancel` ends the workflow; a selection goes to § 2.

## 2. Delegate

Before every fix round, apply [Delegation](../references/skill-rules.md#delegation) for the target worktree to the selected dev agent, a caller-supplied `dev_agent` included.

### Base freshness

Check the round's base before stamping or delegating the round:

```bash
.agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]
```

- **Exit 0.** The base is current. Keep the current validation route, the later `restack-skip` check included.
- **Exit 4.** The base is stale.
  1. Unarm any open PR through [Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop).
  2. Ask the live-round owner. Write `[WORKTREE_PATH]/tmp/live-round-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "check-live-round", "worktree": "[WORKTREE_PATH]"}` and run it:

     ```bash
     .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/live-round-[ISSUE_ID].json
     ```

  3. Only exit 0 permits `.agents/skills/worktree/scripts/worktree create [ISSUE_ID] --restack`. Any other exit stops before rebasing; finish or recover a live round before the gate runs again.
  4. Resolve conflicts and run `.agents/skills/worktree/scripts/worktree restack continue [ISSUE_ID]` until the restack completes.
  5. Apply Rules reload after a rebase from [SKILL.md § The Cycle](../SKILL.md#the-cycle).
  6. Run `base-freshness` again. Only its exit 0 permits stamping the round on the rebased HEAD.

- **Any other exit, or an incomplete restack.** Unarm any open PR through [Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop), then stop delegation and validation. Never validate the stale head first.

### Finding occurrences

Before stamping any group's round, apply [Finding occurrences § Query and admission](../schemas/workflow-state.md#query-and-admission) to the proposed fix set. Write `[WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json` from the source review items, or from a failed receipt's exact check tokens. Then read:

```bash
.agents/skills/orch/scripts/orch-runtime state findings query --item [ISSUE_ID] [WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json
```

- A nonzero exit or `ok: false` is a failed query.
- Otherwise save the reply's `result`, the `{prior, classes}` object, unchanged with the harness file tool as `[WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json`.
- Take the [finding-specific design read](../references/design-review.md#inputs-and-actions) before minting the round, pruning it or recording its delegation time.
- Carry this JSON in the ask or status and in the brief's `Finding occurrences:` line.
- An unknown or failed intake stays unknown along that route.
- The read grants no fix and no validation allowance.

### Steps

1. **Determine the agent.** `dev_agent` wins. Otherwise read state, and fall back to the issue's `agent:*` label or the component paths:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /agent
   ```

2. **Group the items** by agent domain where they span several, ordered per [skill-rules.md § Sequencing](../references/skill-rules.md#sequencing).
   - Past roughly eight items, prefer two scoped rounds over one broad round.
   - Each group is its own round: run steps 3 to 6 for one group, then the next.
   - With more than one group, every group but the last may hand its work over to the next. The last group's round validates.

3. **Gather decision context:**

   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```

   ```bash
   .agents/skills/decider/scripts/decisions search "[KEYWORDS_OF_THE_CHANGED_AREA]"
   ```

   - The `path` fields of these replies are the ONLY source of decision file paths; never compose or recall one.
   - A decision binds only after you read its full record and status. A superseded decision binds only what its status leaves active; a retired one binds nothing.
   - Check each path before injecting it, one command per path:

     ```bash
     test -f [DECISION_FILE_PATH]
     ```

   - On a failed check, leave the path out and carry `- decision index lookup failed for [DECISION_ID]` instead.

4. **Stamp and delegate.** Run each command as its own tool call, immediately before delegating.

   Stamp the round as [dev-start.md § 2](dev-start.md#2-delegate) steps 3 to 8 do.

   - Arm the watchdog per [Round Closure](../references/skill-rules.md#round-closure).
   - Where step 2 made more than one group, the `begin-round` request carries `"group": {"n": [N], "of": [GROUPS]}`.
   - An `exception` follows dev-start's rule.

   Write the delegated item set to `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file tool:

   - It is a JSON array of `{"n": [N], "text": "[ITEM_TEXT]", "reach": "[REACH]"}`, one entry per delegated item.
   - Copy `[ITEM_TEXT]` and name `[REACH]` under [dev-round.md § Item text](../schemas/dev-round.md#item-text).
   - Disposition an item with no reach per [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar) instead of delegating it.

   Decide whether this round may add protected files. [dev-round.md § Protected additions](../schemas/dev-round.md#protected-additions) is the one scope definition; the default is none. Where the list is not empty:

   - Pass the exact repository-relative paths as one blank-separated `--adds` value.
   - Render the same list after `Adds:` in the brief: `Adds: tools/one-helper.sh` for one path, `Adds: tools/one-helper.sh skills/x/scripts/check` for two.
   - A path holding whitespace cannot be authorized ([dev-round.md § Item text](../schemas/dev-round.md#item-text)); check for one before you write the line.

   Write the round record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime round --text stamp --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --source [SOURCE] --finding-occurrences-file [WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json [--adds "[REPO_RELATIVE_PATHS]"]
   ```

   - A nonzero exit is a refusal or an environment failure, named on stderr: report it and stop.
   - `--issue` is the normalized workflow-state key, the brief's `Artifact Key:`.
   - `--item [N] '[ITEM_TEXT]' '[REACH]'` groups may replace `--items-file` in one command only where every item's text is plain, with no backticks or quotes.

   **Cuts.** When a reviewer or the orchestrator decides a cut, mint a fresh round. Delegate the cut back to the Done-when as its items, and stamp the record with `--cut`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime round --text stamp --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --source [SOURCE] --finding-occurrences-file [WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json --cut
   ```

   - Never improvise a finding-shaped `reach` for a cut item: [dev-round.md § Declared cuts](../schemas/dev-round.md#declared-cuts) states its reach, the cut declaration and its retry rule.
   - Accept the cut round through step 5.
   - Declare a cut only on the round that does the cutting.

   `[LABELS]` is the issue's labels as [dev-start.md § 1](dev-start.md#1-determine-agent) renders them, or `none` where the round's key names no issue.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../references/skill-rules.md#format-tags-are-literal)).

   `Recommendation:` is the technical fix, never procedure steps; the agent owns validate, commit and return.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md
   Follow its § 2 Apply rule for the scope of this round.

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]
   Labels: [LABELS]
   Validation admission: .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json
   QA: [QA_AGENT]
   Finding occurrences: [UNCHANGED_QUERY_JSON]
   [If the round may add files: "Adds: [REPO_RELATIVE_PATHS]"]
   [Where step 2 made more than one group: "Group: [N] of [GROUPS]"]
   [Where N is below GROUPS: "Hand-over: this group may commit its work and write its receipt with --validate handed-over; the last group validates"]
   [Where the round began with an exception: "Exception: [WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json — pass it as --exception-file beside a FAILING run of an excused check"]
   [For each near_ceiling line read from workflow state: "Near-ceiling: [LINE]"]

   Decisions:
   [For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
   [For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
   [If none: "- No linked decisions found."]

   Review items:
   [FORMATTED_ITEMS]
   </delegation_format>

5. **Accept the round.** Accept from **A**, the round's receipt, and **B**, git, never from the return message.

   **Check A.** Read the round's token, then check its receipt against the step 4 record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
   ```

   - `--expect-items-from-round` holds the receipt's `items[]` to the step 4 record ([dev-return.md § Kind rules](../schemas/dev-return.md#kind-rules)).
   - Exit 2 means the expected set cannot be established: mint and delegate a fresh round.
   - Never recreate the record after delegation, and never fall back to `--expect-items`.
   - The verdict words, and what the check records, are [dev-start.md § Check A](dev-start.md#check-a)'s; a fix round never answers `no-change`.

   **Check B:**

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   ```

   ```bash
   git -C "[WORKTREE_PATH]" log -1 --oneline
   ```

   - `B = pass` when the worktree is clean and the receipt's fix commit resolves in the log.
   - It also passes when the round applied nothing and made no commit.
   - On `hand-over`, B also needs the receipt's `.commit` to equal HEAD.

   A `ci` receipt accepts the local edits on the current commit. Required CI stays pending until the published head's run proves it. Acceptance starts no wait on the unpublished head.

   A round that meets the [Stalled round](../references/skill-rules.md#stalled-round) conditions goes to recovery as [dev-start.md § Stalled round](dev-start.md#stalled-round) runs it, whatever B reads. Never nudge or re-message its agent.

   Every other round takes the table below. Its stages close through [dev-start.md § Close The Round's Stages](dev-start.md#close-the-rounds-stages).

| A (verdict) | B (git) | Action |
|---|---|---|
| `accept` | pass | Accept and close with `pass` |
| `accept-excused` | pass | Accept and close with `pass-excused` |
| `hand-over` | pass | Close with `handed-over` |
| `accept`, `accept-excused` or `hand-over` | fail | Re-read git once, then re-delegate the missing step |
| `wait` | pass | Send one report-only nudge |
| `wait` | fail | **Not done.** Wait to the deadline, then escalate |
| `retry` | any | Route by the reply's `reason` |

Each row's steps:

- **`accept`, pass.** **Accept.**
  1. First confirm the receipt's `.commit` equals `git -C [WORKTREE_PATH] rev-parse HEAD`; an all-skipped round's `.commit` is the unchanged HEAD.
  2. Read the item decisions, commits and validate status from the return where present, else from the receipt.
  3. Run [dev-start.md § Close The Round's Stages](dev-start.md#close-the-rounds-stages) with `pass`, then [Store Proposed Rules](dev-start.md#store-proposed-rules) and [Store Near-Ceiling Lines](dev-start.md#store-near-ceiling-lines): a fix round records its own list.
  4. → step 6.
- **`accept-excused`, pass.**
  1. **Accept** as the `accept` row does, closing with `pass-excused`.
  2. Tell the caller the round closed `pass-excused` with its exception file.
  3. → step 6.
- **`hand-over`, pass.**
  1. Close The Round's Stages with `handed-over`, then Store Proposed Rules and Store Near-Ceiling Lines.
  2. → step 6, then the next group.
- **`accept`, `accept-excused` or `hand-over`, fail.** The receipt claims done, but the worktree is dirty or the commit is missing.
  1. Re-read git ONCE after a brief pause.
  2. Then re-delegate only the missing step: the commit, or the revert of leftover work.
- **`wait`, pass.**
  1. Do NOT re-run the fix and do NOT accept on git alone.
  2. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`orch-runtime dev-return --text write --kind fix … --round-id [DEV_ROUND_ID]` with one `--item` per review item; if the delegation is gone from your context, your item set is on disk at `tmp/dev-round-[ISSUE_ID]-[DEV_ROUND_ID].json`) and re-report your item decisions; do NOT re-run the fix."*
  3. Accept only when a valid receipt for THIS round appears.
- **`wait`, fail.** Wait to the deadline, then escalate per [Round Closure](../references/skill-rules.md#round-closure).
- **`retry`, any.** A receipt for THIS round exists but fails a gate. The reply's `reason` names the gate; the reasons below take their own action.
  - A structurally valid receipt with a failing `validate` is final under [validation.md § Recovery](../../dev/references/validation.md#recovery), after any permitted in-round correction and rerun:
    1. Close The Round's Stages with `fail`, then Store Proposed Rules and Store Near-Ceiling Lines.
    2. Then end the workflow and report, without another validation round.
  - An identity or schema failure gets the `wait` row's report-only nudge where the receipt's `validate` is not `FAILING`.
    - Over a `FAILING` receipt the writer refuses `receipt-exists`:
      - Under a run's name, the nudge asks for the round's next admitted attempt under the dev skill's validation.md § Recovery, whose receipt lands under its own run id.
      - Under the round's no-run name the receipt is final, and the round closes as a failing `validate` does.

**Retry reasons** with their own action:

| `reason` | Action |
|---|---|
| `unapproved_additions` | Start a fresh round that names each deliberate path the reply's `files` lists in `Adds:`, or order the files cut |
| `comparison_failed` | Mint a fresh round; the dev agent has nothing to repair |
| `additions_unattributable` | Settle the paths as [dev-round.md § Protected additions](../schemas/dev-round.md#protected-additions) states; the blocked round closes through the fresh round |
| `mode_mismatch` | Send ONE nudge to validate again and rewrite the receipt |

- `mode_mismatch`: its pass does not cover the round as submit reads it. The nudge asks the agent to validate as [dev-fix.md § 3](../../dev/workflows/dev-fix.md#3-validate-and-commit) starts the run, and rewrite the receipt, without re-running the fix.

6. **Record the outcome**, one write per item. An item's own text never enters a shell word or `--arg`.

   Write each item's entry to `[WORKTREE_PATH]/tmp/state-item-[ISSUE_ID].json` with the harness file tool, one item at a time. A fixed item:

   ```json
   {"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}
   ```

   An escalated item, `[OUTCOME]` carrying its accepted decision: Blocked → `"blocked"`, Skipped → `"skipped"`.

   - A Skipped item whose disposition is introduced-or-armed lands here with `"skipped"`: the fix introduced or armed the defect it names.
   - The orchestrator re-delegates it in the next fix round instead of ending the review on it.

   The escalated entry:

   ```json
   {"description":"[DESC]","location":"[LOC]","reason":"[REASON]","outcome":"[OUTCOME]","source":"[SOURCE]"}
   ```

   Bind the file into the write for the item's bucket. Fixed:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"fixed","drop":["fixed","escalated"],"file":"[WORKTREE_PATH]/tmp/state-item-[ISSUE_ID].json"}'
   ```

   Escalated:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"escalated","drop":["fixed","escalated"],"file":"[WORKTREE_PATH]/tmp/state-item-[ISSUE_ID].json"}'
   ```

   Each write first removes the item from BOTH buckets, matched on the recorded entry's location and description, then appends its own entry. The item stands in exactly one bucket, once.

   Record each fixed item's root cause in `pr_comment_review.patched_causes`, whichever loop patched the cause. It is the one record [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) reads. `pr-review`, `qa-review` and `review` rounds reach that rule through this step.

   1. Write one entry per fixed item to `[WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json`.
   2. Copy `[LOCATION]` from the item's header and `[OWNER]` from its `Owner:` line as written; leave out `owner` where the item has no such line:

   ```json
   {"cause": "[ONE_LINE]", "commit": "[SHA]", "location": "[LOCATION]", "owner": "[OWNER]"}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"patched-cause","file":"[WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json"}'
   ```

   Then count the round:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"counted","counter":"fix"}'
   ```

## 3. Return

**Standalone**:

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Fix Results — [ISSUE_ID]

| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [explanation] |

Commits: [SHAs or "none"]
Validate: [status]

</output_format>

**Managed**: return the item decisions, commits and validation status to the caller, naming `pass-excused` or `handed-over` where the round closed with that word.
