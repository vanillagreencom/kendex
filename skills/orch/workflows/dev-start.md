# Dev Implementation Workflow

Delegate one implementation round to a dev agent, then accept the round from its receipt. A single issue takes one round. A bundled issue takes one round per agent group, one group after another. Run the workflow first line to last for each round.

| Command | Behavior |
|---------|----------|
| `dev-start` | Implement the current branch's issue |
| `dev-start [ISSUE_ID]` | Implement a specific issue |
| (from start-worktree / review-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 4) or `"self"` (default); `issue_id`, the workflow-state key ([workflow-state.md § Keys](../schemas/workflow-state.md#keys)), never the bare GitHub issue number.

## Start

1. **Issue.** With `lifecycle: "managed"`, `ISSUE_ID` is the caller's `issue_id`. With `lifecycle: "self"`, it is the argument, or the branch's issue where no argument is given:

   ```bash
   .agents/skills/orch/scripts/git-context issue-from-branch .
   ```

2. **Tracker.** Resolve `TRACKER` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). Run the [Linear launch preflight](#linear-launch-preflight) now, before any workflow state exists.

3. **Worktree.** With `lifecycle: "managed"`, `[WORKTREE_PATH]` is the caller's `worktree`. Otherwise apply the worktree-scope rule of [SKILL.md § Workflow Execution](../SKILL.md#workflow-execution) and pick `[DIR]`: `.` inside a worktree; from the main checkout, the path `.agents/skills/worktree/scripts/worktree path [ISSUE_ID]` prints. Where no worktree exists for the item, ask the user before creating one. Then resolve the root, which fills every `Worktree:` line below:

   ```bash
   .agents/skills/orch/scripts/git-context repo-root "[DIR]"
   ```

4. **State.** Check whether the item's workflow state exists:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]
   ```

   Where the reply's `exists` is `false`, read the branch, then create the state with it:

   ```bash
   .agents/skills/orch/scripts/git-context branch [WORKTREE_PATH]
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime state init --item [ISSUE_ID] --worktree [WORKTREE_PATH] --branch "[BRANCH]"
   ```

### Linear launch preflight

**Linear only.** Read the item. The plain read carries the bundle and its `in_pr_bundle` flag:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
```

Apply the [Ancestor gate](../references/skill-rules.md#ancestor-gate) to this read, and complete every further read the gate requires:

- A container is refused before anything is written. Name its unblocked children as the startable items.
- A blocked item stops, its live blockers named.
- An item the read reports `in_pr_bundle` takes the gate's in-PR bundle rule and is delegated as a [bundled issue](#bundled-issue). That rule does not bypass the blocker check.

Stop on any refusal before stamping or delegating.

## 1. Determine Agent

Read the item's labels:

```bash
# Linear
.agents/skills/linear/scripts/linear.sh graphql --query 'query { issue(id: "[ISSUE_ID]") { labels { pageInfo { hasNextPage } nodes { name } } } }'
# GitHub
gh issue view [N] --repo [OWNER/REPO] --json labels --jq '.labels[].name'
```

Select the agent through [dev § Implementer selection](../../dev/SKILL.md#implementer-selection). `[LABELS]` is these labels, comma-separated, or `none` where the item has none. The dev agent passes them to `orch-runtime dev-return --text write`, whose Apple gate reads them.

## 2. Delegate

Apply [Delegation](../references/skill-rules.md#delegation) for the target worktree before reusing a stored dev agent or starting a new one. Persistence follows [Agent Lifecycle](../references/skill-rules.md#agent-lifecycle).

Run the steps below for every delegation: once for a single issue, once per group of a bundled issue. Run each command as its own tool call.

1. **Preflight.** Run the [Linear launch preflight](#linear-launch-preflight) again from current facts, a managed entry included. An earlier preflight, the caller's or the start's, does not replace it. For a bundle, this read gives the pending sub-issues and the parent's title.

2. **Base.** Record the checkout's HEAD as the round's base, `pre_delegate_sha`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"base","worktree":"[WORKTREE_PATH]"}'
   ```

3. **Standing round.** Read the item's last dev round:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
   ```

   Where it is not null, as a bundled group's predecessor leaves it, reconcile that round before the new one supersedes it. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[PRIOR_DEV_ROUND_ID]"}` and run it with the `op --request` command of [Close The Round's Stages](#close-the-rounds-stages). A run the reply reports `live` keeps running under the superseded round.

4. **Mint the round.** Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "dev"}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
   ```

   `[DEV_ROUND_ID]` is the reply's `.result.report.round_id`. The one write mints the token, supersedes the open dev stage and opens the new one ([workflow-state.md](../schemas/workflow-state.md) `stages`). The request may carry two more members:

   - `"group": {"n": [N], "of": [GROUPS]}` for a bundled group: group `N` of `GROUPS`, counted from 1. The runtime refuses `round-group` where `N` is 0 or above `GROUPS`.
   - `"exception": {"by": "overseer", "id": "[ENVELOPE_ID]", "excused": ["[CHECK]"]}` only where the overseer's answer to this lane's question, or with `"by": "owner-directive"` the owner's directive, grants the round known failing checks. Name each check as a receipt's `FAILING:` list names it. Write the same JSON to `[WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json` with the harness file tool for the brief's `Exception:` line. The runtime refuses an exception with an empty `id` or no check as `exception-invalid`.

5. **Prune.** Apply [Round Closure](../references/skill-rules.md#round-closure)'s cleanup condition to the round's prune. Where it applies, write `[WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json` with the harness file tool as `{"op": "prune-round", "field": "dev"}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
   ```

6. **Delegation time.** Record it after the prune, so the cleanup does not count against the agent's quiet window:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"dev"}'
   ```

7. **Admission request.** Write `[WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json` with the harness file tool as `{"op": "record-validation-admission", "round_id": "[DEV_ROUND_ID]"}`. The brief's `Validation admission:` line is the exact command the dev agent runs before each validation start, so every run is admitted before any work starts.

8. **Near-ceiling lines.** Read them:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /near_ceiling
   ```

   The brief renders one `Near-ceiling:` line per entry. A first round reads `[]` and renders none.

9. **Spawn.** Delegate with the brief below for a [single issue](#single-issue) or a [bundled issue](#bundled-issue), and arm the watchdog per [Round Closure](../references/skill-rules.md#round-closure). On Codex, resolve the spawn parameters first:

   ```bash
   .agents/skills/agent-runtime/scripts/agent-runtime subagent spawn --harness codex [AGENT_TYPE]
   ```

10. **Record the session.** After each spawn:

    ```bash
    .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"child-open","agent_type":"[AGENT_TYPE]","agent_id":"[AGENT_OR_TASK_ID]","runtime_agent_type":"[RUNTIME_AGENT_TYPE]","agent_type_fallback":[FALLBACK_REASON_JSON_OR_NULL]}'
    ```

### Single issue

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [LABELS]
Validation admission: .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json
[Where the round began with an exception: "Exception: [WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json — pass it as --exception-file beside a FAILING run of an excused check"]
[For each near_ceiling line read from workflow state: "Near-ceiling: [LINE]"]
</delegation_format>

A GitHub item replaces the `Issue:` line with `GitHub Issue: [OWNER/REPO]#[N]`. `Artifact Key:` stays `[ISSUE_ID]`, never `OWNER/REPO#N`.

### Bundled issue

Group the pending sub-issues by `agent:[TYPE]` label and order the groups per [references/skill-rules.md § Sequencing](../references/skill-rules.md#sequencing). Run the groups one after another: § 2 with the round's `group`, then § 3, then the next group. Every group but the last may hand its work over to the next group; the last group's round always validates, and only its acceptance runs the bundle's tracker validation.

Between groups, read each completed sub-issue's comments for a `Handoff Notes` section and combine them into the next group's brief.

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Parent: [ISSUE_ID]
Sub-Issues:
↳ [SUB_ISSUE_1] (completed): [TITLE]
↳ [SUB_ISSUE_2]: [TITLE] | blocks: [SUB_ISSUE_3]
↳ [SUB_ISSUE_3]: [TITLE] | blocked by: [SUB_ISSUE_2]

Worktree: [WORKTREE_PATH]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Group: [N] of [GROUPS]
[Where N is below GROUPS: "Hand-over: this group may commit its work and write its receipt with --validate handed-over; the last group validates"]
Labels: [the parent's labels and every sub-issue's labels, each once, comma-separated, or none]
Validation admission: .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json
[Where the round began with an exception: "Exception: [WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json — pass it as --exception-file beside a FAILING run of an excused check"]
[For each near_ceiling line read from workflow state: "Near-ceiling: [LINE]"]
Parent Title: [PARENT_TITLE — the `.title` from the preflight bundle read, verbatim]

**Work pending issues only** (completed ones are listed for context). Complete blockers before blocked issues.

**Scope**: implement YOUR assigned sub-issues only. You may fix or connect prior agents' code, but do not implement work belonging to another agent's pending sub-issues.

Current status of the bundle: [what other agents already did]

Handoff from prior agents:
[[ISSUE_ID] (agent:[TYPE])]:

- [extracted handoff notes]
</delegation_format>

## 3. Accept The Round

Acceptance is a function of **A**, the receipt on disk, and **B**, git and the tracker. The agent's return message is display only. Run A and B when the § 2 watchdog answers or its deadline passes, never waiting on a message.

### Check A

Read the round's token, then check its receipt:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
```

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]
```

A is the reply's `verdict`:

| Verdict | The receipt |
|---|---|
| `accept` | Valid; its run passed, or ended `no-verdict`. |
| `accept-excused` | Valid; its run failed only on checks the round's exception excuses. |
| `no-change` | Valid; it ran no check and quotes, as `no_change`, the item's sentence that permits ending the round with no change ([dev-return.md § No-change receipt](../schemas/dev-return.md#no-change-receipt)). |
| `hand-over` | Valid; a group that is not the last committed its work and handed it over. |
| `wait` | Missing. |
| `retry` | Present but failing a gate the reply's `reason` names, or a valid receipt with a failing run no exception excuses. |

The check selects the receipt of the run the round's newest `validate` stage names ([dev-return.md § Identity](../schemas/dev-return.md#identity-the-round-id)) and matches its `round_id`. Read every receipt field below from the reply's `path`, and carry that path to submit. For every `reason` but `missing` and `invalid`, the check sets the round entry's kind and records the run's validation time; a retry or an escalation keeps that time.

### Check B

`B = pass` only when every check below passes:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pre_delegate_sha
```

```bash
.agents/skills/orch/scripts/git-context head [WORKTREE_PATH]
```

```bash
git -C "[WORKTREE_PATH]" status --porcelain
```

```bash
.agents/skills/linear/scripts/linear.sh issues validate-completion [ISSUE_ID] --include-children-of [ISSUE_ID]
```

- **HEAD.** On `no-change`, B reads no HEAD: the check's answer already holds the unmoved HEAD. On `hand-over`, HEAD must differ from `pre_delegate_sha`. Otherwise HEAD must differ from `pre_delegate_sha`, or, where it did not move, the round's proof must be complete for HEAD's tree. Read the tree, then the runtime's proof reader over the round's `validate` entries, which must answer `complete` in `.result.proof`:

  ```bash
  git -C "[WORKTREE_PATH]" rev-parse "HEAD^{tree}"
  ```

  ```bash
  .agents/skills/orch/scripts/orch-runtime read-proof --item [ISSUE_ID] --need round --tree [TREE]
  ```

- **Clean tree.** `status --porcelain` must print nothing. The runtime does not check the tree on a hand-over; this check holds it.
- **Tracker.** **Linear only**, and only on a final acceptance: a single issue's round, or a bundle's last group. Every row must report `state_ok`, `[.results[].state_ok] | all`. A hand-over group runs no tracker validation. GitHub and ad-hoc rounds skip it: their B is the HEAD rule and the clean tree.

`--include-children-of` expands the bundle's children and the audit-created sub-issues worked in this session; the linear skill's `validate-completion` contract judges them. Dev-implement § Issue state ticks verified branch boxes and records Evidence through a description-only update while each child stays In Progress, and the validation reads that persisted checklist. The session root stays In Progress or In Review before merge. Carry the qualified started children into submit-pr's child `Closes` lines and merge-pr's post-merge completion step.

The item's summary comment is the acceptance's own post after the close, so B never waits on it.

### Stalled round

A round that meets the [Stalled round](../references/skill-rules.md#stalled-round) conditions goes to `orch-runtime round --text recover`, whatever B reads. Never nudge or re-message its agent.

1. Reconcile the round's admitted runs first, so a lost or stopped run is a closed stage before the round is replaced: write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[DEV_ROUND_ID]"}` and run it with the `op --request` command of [Close The Round's Stages](#close-the-rounds-stages).
2. Run the recovery per [Stalled round](../references/skill-rules.md#stalled-round).
3. On its `redelegate` line the printed round id is already `dev_round_id`. Apply the cleanup condition to that round's prune with § 2 step 5's request file, then take the rest of the `redelegate` row:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
   ```

### Acceptance table

The table covers every round that is not stalled.

| A (verdict) | B (git/tracker) | Action |
|---|---|---|
| `accept` | pass | **Accept** even with no return message. First confirm the receipt's `.commit` equals `git -C [WORKTREE_PATH] rev-parse HEAD`. With `validate_mode` `ci`, acceptance completes the local edits and leaves the pull request's required CI pending; submit's exact-head wait supplies the proof. → Close The Round's Stages with `pass`, then Store Proposed Rules, Store Near-Ceiling Lines and Store QA State. |
| `accept-excused` | pass | **Accept** as the `accept` row does. → Close The Round's Stages with `pass-excused`, then Store Proposed Rules, Store Near-Ceiling Lines and Store QA State. Tell the caller the round closed `pass-excused` with its exception file. |
| `accept` or `accept-excused` | fail | Re-read once after a brief pause. If B still fails, re-delegate only the missing step: commit the work (none is missing where HEAD did not move and the round's proof is complete), or commit or revert the leftover files. Do not proceed. |
| `hand-over` | pass | → Close The Round's Stages with `handed-over`, then Store Proposed Rules and Store Near-Ceiling Lines, then delegate the next group through § 2. |
| `hand-over` | fail | Re-read once after a brief pause. If B still fails, re-delegate only the missing commit, or the commit or revert of the leftover files. Do not proceed. |
| `no-change` | pass | Read the echoed `no_change` sentence in the item's description from § 2's read. Where it permits ending this round with no change → Close The Round's Stages with `no-change`, then Store Proposed Rules, then end the workflow and return `no-change` to the caller. Where it does not, the round is final → Close The Round's Stages with `fail`, then Store Proposed Rules, then end the workflow and report. Neither route asks the overseer. |
| `no-change` | fail | Re-read once after a brief pause. If B still fails, report the failing check and stop without closing the round. |
| `wait` | pass | Do NOT re-run the implementation. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`orch-runtime dev-return --text write … --round-id [DEV_ROUND_ID]`) and re-report validate status, QA labels, and summary; do NOT re-run the implementation."* Accept only when a valid receipt for THIS round appears. |
| `wait` | fail | **Not done.** Wait to the deadline, then escalate per [Round Closure](../references/skill-rules.md#round-closure). |
| `retry` | any | A receipt for THIS round exists but fails a gate; the reply's `reason` names it. A structurally valid receipt whose `validate` fails may take the one recovery [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate) admits, under the original brief, `pre_delegate_sha` and Check B: the runtime admits the round's next attempt, which writes its own receipt under its own run id, and the check then selects the receipt the round's newest `validate` stage names. Check A again when that run has ended. A failing selected receipt, or an original that qualifies for no recovery, is final → Close The Round's Stages with `fail`, then Store Proposed Rules and Store Near-Ceiling Lines, then end the workflow and report without another validation round. An identity or schema failure gets the report-only nudge of the `wait` row. Never accept a `retry`, and never treat it as absent. |

Do not import the reviewer's re-delegate-on-invalid rule ([references/artifact-checks.md](../references/artifact-checks.md)).

Each Store subsection runs whatever the one before it did. `status: no_pr` in Store Proposed Rules ends that subsection, not the accept path.

### Close The Round's Stages

The runtime is the one writer of a stage's end ([workflow-state.md](../schemas/workflow-state.md) `stages`).

1. **Runs.** Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[DEV_ROUND_ID]"}` and run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
   ```

   The reply's `runs` rows name each open `validate` entry the call read. A row `closed` carries the word: the sentinel's `pass`, `fail` or `no-verdict` for an ended run; `stopped` for an admitted directory never created, a refused or never attempted start, or a run `validate stop` ended; `lost` for a run whose job or child is gone without its sentinel. A row `live`, or `live-unit` under a user manager, is a run still running; a row `unreadable` names the cause the runtime could not read past. Both stay open. For a closed run's timing in the round's report, read `orch-runtime validate entry --record --run-dir [RUN_DIR]`.

2. **The round.** Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as the request below, then run step 1's command again:

   ```json
   {"op": "accept-result", "round_id": "[DEV_ROUND_ID]", "outcome": "[WORD]", "summary_file": "[WORKTREE_PATH]/tmp/completion-summary-[ISSUE_ID].md", "attachments": [SCREENSHOTS]}
   ```

   - `outcome` is the table's word: `pass`, `pass-excused`, `handed-over`, `no-change` or `fail`. A request without it is refused `request-invalid`. `pass-excused` is refused `exception-unbegun` where the round began with no exception.
   - `summary_file` is the receipt's `summary`, written to that path with the harness file tool. `[SCREENSHOTS]` is the receipt's `screenshots` as the check echoed it, `[]` where it echoed none.
   - Omit `summary_file` and `attachments` for a bundled round, whose dev agent posts each sub-issue's summary under [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-summary-file) and the parent's under [§ 11](../../dev/workflows/dev-implement.md#11-return-bundled).
   - **GitHub.** Omit both on every close but `no-change`. A `no-change` close on an `issue-N` item names `summary_file`: the runtime posts it on the issue, records it as `summary_comment`, then closes the issue as completed, and reports the close as `issue`. Without the file the close is `held`. The runtime refuses `repo-unresolved` where neither the item's lane record nor its recorded checkout names the repository.
   - Add no `authorization` to the lane's own acceptance of its round: it skips no ask [communication-modes.md](../references/communication-modes.md) owns. An item keyed `directive-[ID]` adds `"authorization": {"by": "owner-directive", "id": "[ID]"}`, the directive the change was made under; its round refuses a close without it as `authorization-missing`. A close adds `"authorization": {"by": "overseer", "id": "[ENVELOPE_ID]"}` only when the overseer has acted on this lane's own question: `[ENVELOPE_ID]` is the id of the envelope in the lane's inbox that answers the lane's `lane-question` for this step, or of an owner's directive the overseer relayed to the lane. A launch ruling, a fleet-log row or a session id is never that id. Only this workflow writes the field.

   After the close the runtime creates the item's comment headed `## Completion Summary` through the tracker CLI, with one `--attach` per `attachments` path, and records its id and attachment links as `summary_comment`. Every later acceptance updates that one comment in place, with the recorded links rendered under the summary. The reply's `summary.posted` is `created`, `updated`, `failed` or `unrecorded`, with its cause; a failed post leaves the acceptance standing. A repeated close closes nothing again: it reports the recorded end and word, and refuses a request naming another authorization as `authorization-differs`.

### The exception file

A round closed `pass-excused` leaves its exception at `[WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json`, the file § 2 step 4 wrote. [submit-pr.md](submit-pr.md) and [merge-pr-restack.md](merge-pr-restack.md) pass that path to `orch-runtime read-proof --exception-file`, which counts the failed run as proof only for a round closed `pass-excused` with exactly that exception. The round's `stages` entry records the same object as its `exception`:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /stages
```

Where the file is absent, or a later round's exception replaced it, write the closed round's `exception` object from that read to the same path with the harness file tool before the proof read.

### Store Proposed Rules

Read the receipt's `summary`, a failing-validation receipt's included. Skip to the PR read where it has no bullet under `### Proposed Rules`. For each bullet, write the rule as one JSON string to `[WORKTREE_PATH]/tmp/proposed-rule-[ISSUE_ID].json` with the harness file tool, then append it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"proposed-rule","file":"[WORKTREE_PATH]/tmp/proposed-rule-[ISSUE_ID].json"}'
```

The entry appends a rule once: a rule the ledger already holds is not appended again.

Then resolve the PR from the worktree:

```bash
.agents/skills/orch/scripts/orch-runtime pr view "[WORKTREE_PATH]" --json number,body
```

`status: no_pr` ends this subsection; PR creation reads the stored list. Where a PR exists, read the whole stored list:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pr_comment_review/proposed_rules
```

Write the remote `body` to `[WORKTREE_PATH]/tmp/pr-body-proposed-rules-[ISSUE_ID].md` with the harness file tool. Replace only its `## Proposed rules` section with the stored list, or add the section where it is absent, and keep every other line of the remote body. Post that file:

```bash
.agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/pr-body-proposed-rules-[ISSUE_ID].md
```

Never rebuild the body from the local worktree, and never push a commit from this step. This subsection is the one publisher of proposed rules.

### Store Near-Ceiling Lines

The accept, hand-over and final-retry routes of implement and fix rounds run this subsection. It is the one writer of `.near_ceiling`.

`[NEAR_CEILING_ARRAY]` is the receipt's `near_ceiling` as the check echoed it: a JSON array of strings, `[]` where the round left none. It is `null` where the byte-ceiling probe gave no answer, and the echoed `near_ceiling_error` names why: no `--near-ceiling-base`, a broken link or a lane that cannot run, or a lane exit other than 0 or 1. On `null`, skip the write and name `near_ceiling_error` in the round's report: an empty list would tell the next round no binary blob is near the ceiling.

Each entry names a binary blob the round left within reach of the byte ceiling, so the next round can plan Git LFS, an asset store or generation before the blob grows. The write replaces the key: state describes the branch as the last recorded round left it.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-dev-return","near_ceiling":[NEAR_CEILING_ARRAY]}'
```

### Validation status

A run's cost stands in two records. The check records each schema-valid receipt's validation seconds in `validate_rounds` before its verdict routes the round. The round's `validate` entry on `stages` is the runtime's, with the run's `start`, `end` and `proof` ([workflow-state.md](../schemas/workflow-state.md) `stages`). `record-push` records a restack's validation, after a successful push, in both.

A lane under an overseer rewrites its status file's validation line from `.validate_rounds` per [oversee.md § Lane directive](oversee.md#lane-directive), and lists each `.restack_skips` entry's condition and paths, which [merge-pr-restack.md](merge-pr-restack.md) step 2 writes.

### Store QA State

The implement path only: a fix round has no QA signals or sub-issue set to record. `[QA_LABELS_ARRAY]` is the receipt's `qa_labels`; `[SUB_ISSUE_IDS_ARRAY]` is the bundle's sub-issue ids, `[]` for a single issue.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-dev-return","qa_labels":[QA_LABELS_ARRAY],"sub_issues":[SUB_ISSUE_IDS_ARRAY]}'
```

Map each Done-when item to the files serving it in the PR body's `## Done-when evidence` section, one `N: text` line per branch-provable box ([submit-pr.md § 2](submit-pr.md#2-push-and-submit) step 3). Every round measures against that map, never against its own last state. Cut an unmapped hunk unless it is a [landing enabler](../../dev/SKILL.md#engineering-rules).

## 4. Return

**Managed**: return to the parent workflow's next section, naming `no-change` or `pass-excused` where the round closed with that word. **Standalone**: the session is complete.
