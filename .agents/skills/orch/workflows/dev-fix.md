# Dev Fix Workflow

Delegate a set of fix items to a dev agent, then accept the round from its receipt. A user starts it standalone; a review workflow starts it managed. Run it first line to last for one fix round.

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for a specific issue |
| (from a review workflow) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 3) or `"self"` (default); `dev_agent`, a live dev agent; `issue_id`, the workflow-state key ([workflow-state.md § Keys](../schemas/workflow-state.md#keys)), never the bare GitHub issue number; `items`, formatted review items; `source`, `pr-review` | `pr-comments` | `qa-review` | `review` | `local-review` (default `conversation`); `qa_agent`.

## Start

With `lifecycle: "managed"`, `ISSUE_ID` is the caller's `issue_id` and `[WORKTREE_PATH]` its `worktree`. With `lifecycle: "self"`, resolve `ISSUE_ID` as [dev-start.md § Start](dev-start.md#start) step 1 does and `[WORKTREE_PATH]` as its step 3 does. `[WORKTREE_PATH]` fills every `Worktree:` line below.

## 1. Build Fix Items

Managed: use the caller's `items` under [dev-round.md § Item text](../schemas/dev-round.md#item-text), then go to § 2.

Standalone: read the relevant files, then write each item from the conversation as:

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

Apply [Delegation](../references/skill-rules.md#delegation) for the target worktree to the selected dev agent before every fix round, a caller-supplied `dev_agent` included.

### Base freshness

Check the round's base before stamping or delegating it:

```bash
.agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]
```

- **Exit 0.** The base is current. Keep the current validation route, the later `restack-skip` check included.
- **Exit 4.** The base is stale. Unarm any open PR through [Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop). Then ask the live-round owner: write `[WORKTREE_PATH]/tmp/live-round-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "check-live-round", "worktree": "[WORKTREE_PATH]"}` and run it:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/live-round-[ISSUE_ID].json
  ```

  Only exit 0 permits `.agents/skills/worktree/scripts/worktree create [ISSUE_ID] --restack`; any other exit stops before rebasing, and a live round is finished or recovered before the gate runs again. Resolve conflicts and run `.agents/skills/worktree/scripts/worktree restack continue [ISSUE_ID]` until the restack completes. Apply Rules reload after a rebase from [SKILL.md § The Cycle](../SKILL.md#the-cycle), then run `base-freshness` again. Only its exit 0 permits stamping the round on the rebased HEAD.

- **Any other exit, or an incomplete restack.** Unarm any open PR through [Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop), then stop delegation and validation. Never validate the stale head first.

### Finding occurrences

Before any group's round is stamped, apply [Finding occurrences § Query and admission](../schemas/workflow-state.md#query-and-admission) to the proposed fix set. Write `[WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json` from its source review items, or from a failed receipt's exact check tokens, then read:

```bash
.agents/skills/orch/scripts/orch-runtime state findings query --item [ISSUE_ID] [WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json
```

A nonzero exit or `ok: false` is a failed query. Otherwise save the reply's `result`, the `{prior, classes}` object, unchanged with the harness file tool as `[WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json`. Take the [finding-specific design read](../references/design-review.md#inputs-and-actions) before the round is minted, pruned or given its delegation time. Carry this JSON in the ask or status and in the brief's `Finding occurrences:` line; an unknown or failed intake stays unknown along that route. The read grants no fix and no validation allowance.

### Steps

1. **Determine the agent.** `dev_agent` wins. Otherwise read state, and fall back to the issue's `agent:*` label or the component paths:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /agent
   ```

2. **Group the items** by agent domain where they span several, ordered per [skill-rules.md § Sequencing](../references/skill-rules.md#sequencing). Prefer two scoped rounds over one broad round past roughly eight items. Each group is its own round: run steps 3 to 6 for one group, then the next. Where more than one group runs, every group but the last may hand its work over to the next, and the last group's round validates.

3. **Gather decision context:**

   ```bash
   .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
   ```

   ```bash
   .agents/skills/decider/scripts/decisions search "[KEYWORDS_OF_THE_CHANGED_AREA]"
   ```

   The `path` fields of these replies are the ONLY source of decision file paths; never compose or recall one. A decision binds only after its full record and status are read: a superseded one binds only what its status leaves active, and a retired one binds nothing. Check each path before injecting it, one command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   A failed check leaves the path out and carries `- decision index lookup failed for [DECISION_ID]` instead.

4. **Stamp and delegate.** Run each command as its own tool call, immediately before delegating.

   Read the pull request's state:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] --json state
   ```

   `[PR_OPEN]` is `true` for `OPEN`, and `false` for `status: no_pr`, `CLOSED` or `MERGED`. An unknown state or a failed read stops delegation. The round record keeps `[PR_OPEN]` as a fact ([dev-round.md](../schemas/dev-round.md) `pr_open`).

   Stamp the round as [dev-start.md § 2](dev-start.md#2-delegate) steps 3 to 8 do: reconcile the standing dev round, mint the round with `begin-round` kind `dev`, prune it under the cleanup condition, record the delegation time, write the admission request, and read the near-ceiling lines. Arm the watchdog per [Round Closure](../references/skill-rules.md#round-closure). Where step 2 made more than one group, the `begin-round` request carries `"group": {"n": [N], "of": [GROUPS]}`; an `exception` follows dev-start's rule.

   Write the delegated item set to `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file tool, a JSON array of `{"n": [N], "text": "[ITEM_TEXT]", "reach": "[REACH]"}`, one entry per delegated item. Copy `[ITEM_TEXT]` under [dev-round.md § Item text](../schemas/dev-round.md#item-text). `[REACH]` names the shipped producer, user action or fixture that reaches the finding: a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix: disposition it per [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar) instead of delegating it. The writer refuses a short list of reach shapes ([dev-round.md](../schemas/dev-round.md)); that list is a backstop, and a reach it accepts is recorded, not approved.

   Decide whether this round may add protected files. [dev-round.md § Protected additions](../schemas/dev-round.md#protected-additions) is the one scope definition; the default is none. Where the list is not empty, pass the exact repository-relative paths as one blank-separated `--adds` value and render the same list after `Adds:` in the brief: `Adds: tools/one-helper.sh` for one path, `Adds: tools/one-helper.sh skills/x/scripts/check` for two. A blank or a tab separates paths, so a path holding whitespace cannot be authorized; check for one before you write the line.

   Write the round record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime round --text stamp --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --source [SOURCE] --pr-open [PR_OPEN] --finding-occurrences-file [WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json [--adds "[REPO_RELATIVE_PATHS]"]
   ```

   A nonzero exit is a refusal or an environment failure, named on stderr. Report it and stop. `--issue` is the normalized workflow-state key, the brief's `Artifact Key:`. Only where every item's text is plain, with no backticks or quotes, may `--item [N] '[ITEM_TEXT]' '[REACH]'` groups replace `--items-file` in one command.

   **Cuts.** When a reviewer or the orchestrator decides a cut, mint a fresh round, delegate the cut back to the Done-when as its items, and stamp the record with `--cut`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime round --text stamp --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --source [SOURCE] --pr-open [PR_OPEN] --finding-occurrences-file [WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json --cut
   ```

   A cut item's `reach` is the branch the round shrinks: cut items name work, not a finding. Never improvise a finding-shaped value; `the finding` is on the writer's refusal list. Accept the cut round through step 5. The cut declaration and its retry rule are [dev-round.md § Declared cuts](../schemas/dev-round.md#declared-cuts); declare a cut only on the round that does the cutting.

   `[LABELS]` is the issue's labels as [dev-start.md § 1](dev-start.md#1-determine-agent) renders them, or `none` for a round whose key names no issue.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../references/skill-rules.md#format-tags-are-literal)). `Recommendation:` is the technical fix, never procedure steps: the agent owns validate, commit and return.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

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

5. **Accept the round.** Acceptance is a function of **A**, the round's receipt, and **B**, git, never of the return message.

   **Check A.** Read the round's token, then check its receipt against the step 4 record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
   ```

   `--expect-items-from-round` reads the step 4 record and requires the receipt's `items[]` to cover its set: each item once, no unknown or duplicate number, a valid decision and non-empty reasoning. A fix receipt checked without it is refused. Exit 2 means the expected set cannot be established. Never recreate the record after delegation and never fall back to `--expect-items`; mint and delegate a fresh round. The verdict words are [dev-start.md § Check A](dev-start.md#check-a)'s; a fix round never answers `no-change`. The check sets the round entry's kind and records its validation time before B or the reason routes the round.

   **Check B:**

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   ```

   ```bash
   git -C "[WORKTREE_PATH]" log -1 --oneline
   ```

   `B = pass` when the worktree is clean and the receipt's fix commit resolves in the log, or when the round applied nothing and made no commit. On `hand-over`, B also needs the receipt's `.commit` to equal HEAD.

   A `ci` receipt accepts the local edits on the current commit. Required CI stays pending until the published head's run proves it: the merge-group run where the run record names `ci-event=merge_group`, as every queue-only change's does, and the pull-request run otherwise, which submit's § 5 wait reads. A red queue run returns the change to its lane under the Recovery cycle of [merge-pr.md § 5](merge-pr.md#5-execute-the-merge). Acceptance starts no wait on the unpublished head.

   A round that meets the [Stalled round](../references/skill-rules.md#stalled-round) conditions goes to recovery as [dev-start.md § Stalled round](dev-start.md#stalled-round) runs it, whatever B reads. Never nudge or re-message its agent. Every other round takes the table below; its stage ends close through [dev-start.md § Close The Round's Stages](dev-start.md#close-the-rounds-stages).

| A (verdict) | B (git) | Action |
|---|---|---|
| `accept` | pass | **Accept.** First confirm the receipt's `.commit` equals `git -C [WORKTREE_PATH] rev-parse HEAD`; an all-skipped round's `.commit` is the unchanged HEAD. Read the item decisions, commits and validate status from the return where present, else from the receipt. Run [dev-start.md § Close The Round's Stages](dev-start.md#close-the-rounds-stages) with `pass`, then [Store Proposed Rules](dev-start.md#store-proposed-rules) and [Store Near-Ceiling Lines](dev-start.md#store-near-ceiling-lines): a fix round records its own list. → step 6. |
| `accept-excused` | pass | **Accept** as the `accept` row does, closing with `pass-excused`. Tell the caller the round closed `pass-excused` with its exception file. → step 6. |
| `hand-over` | pass | Close The Round's Stages with `handed-over`, then Store Proposed Rules and Store Near-Ceiling Lines. → step 6, then the next group. |
| `accept`, `accept-excused` or `hand-over` | fail | The receipt claims done but the worktree is dirty or the commit is missing. Re-read git ONCE after a brief pause, then re-delegate only the missing step: the commit, or the revert of leftover work. |
| `wait` | pass | Do NOT re-run the fix and do NOT accept on git alone. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`orch-runtime dev-return --text write --kind fix … --round-id [DEV_ROUND_ID]` with one `--item` per review item; if the delegation is gone from your context, your item set is on disk at `tmp/dev-round-[ISSUE_ID]-[DEV_ROUND_ID].json`) and re-report your item decisions; do NOT re-run the fix."* Accept only when a valid receipt for THIS round appears. |
| `wait` | fail | **Not done.** Wait to the deadline, then escalate per [Round Closure](../references/skill-rules.md#round-closure). |
| `retry` | any | A receipt for THIS round exists but fails a gate; the reply's `reason` names it, and the reasons below take their own action. A structurally valid receipt with a failing `validate` is final under [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate), after any permitted in-round correction and rerun: Close The Round's Stages with `fail`, then Store Proposed Rules and Store Near-Ceiling Lines, then end the workflow and report without another validation round. An identity or schema failure gets the report-only nudge of the `wait` row where the receipt's `validate` is not `FAILING`. Over a `FAILING` receipt the writer refuses `receipt-exists`: under a run's name, the nudge asks for the round's next admitted attempt under dev-implement.md § 5, whose receipt lands under its own run id; under the round's no-run name the receipt is final, and the round closes as a failing `validate` does. |

**Retry reasons** with their own action:

| `reason` | Meaning | Action |
|---|---|---|
| `unapproved_additions` | The round added protected files its record does not authorize; the reply's `files` lists each. | Start a fresh round that names each deliberate path in `Adds:`, or order the files cut. |
| `comparison_failed` | Git cannot compare the round's recorded base commit with HEAD; the dev agent has nothing to repair. | Mint a fresh round. |
| `additions_unattributable` | A rebase moved the round's base off the branch, so its additions were never gated and no path is named. | A fresh round does not recover the gate: `round --text stamp` records its `base_sha` at the rebased HEAD, which already holds what this round added. Read the blocked round's own commits for paths under [dev-round.md § Protected additions](../schemas/dev-round.md#protected-additions), name each deliberate one in the fresh round's `Adds:` line, and cut the rest before delegating it. That `Adds:` line is the authorization itself, so the reading is not optional. The blocked round closes through the fresh round. |
| `mode_mismatch` | The receipt records another validation mode than the run's admitted entry holds, or records `ci` with no admitted entry on a round stamped `--pr-open false` whose `pr-order` is not `push-first`. Its pass does not cover the round the way submit reads it. | Send ONE nudge to validate as [dev-fix.md § 3](../../dev/workflows/dev-fix.md#3-validate-and-commit) starts the run and rewrite the receipt, without re-running the fix. |

6. **Record the outcome**, one write per item. An item's own text never enters a shell word or `--arg`.

   Write the item's entry to `[WORKTREE_PATH]/tmp/state-item-[ISSUE_ID].json` with the harness file tool, one item at a time. A fixed item:

   ```json
   {"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}
   ```

   An escalated item, `[OUTCOME]` carrying its accepted decision: Blocked → `"blocked"`, Skipped → `"skipped"`. A Skipped item whose disposition is introduced-or-armed, the fix having introduced or armed the defect it names, lands here with `"skipped"`, and the orchestrator re-delegates it in the next fix round instead of ending the review on it:

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

   Each write removes the item from BOTH buckets, matched on the recorded entry's location and description, before appending its own entry, so the item stands in exactly one bucket, once.

   Record each fixed item's root cause in `pr_comment_review.patched_causes`, the one record [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) reads, whichever loop patched the cause. `pr-review`, `qa-review` and `review` rounds reach that rule through this step; a cause missing from it is one the next pass reads as never patched. Write one entry per fixed item to `[WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json`, copying `[LOCATION]` from the item's header and `[OWNER]` from its `Owner:` line as written, and leaving out `owner` where the item has no such line:

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
