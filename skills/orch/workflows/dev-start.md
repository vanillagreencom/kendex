# Dev Implementation Workflow

Delegate the implementation of one issue, or of a bundled multi-agent work item, to a specialist dev agent, then accept the round from its receipt. Run it first line to last for one round.

| Command | Behavior |
|---------|----------|
| `dev-start` | Implement the current branch's issue |
| `dev-start [ISSUE_ID]` | Implement a specific issue |
| (from start-worktree / review-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 4) or `"self"` (default); `issue_id`, the workflow-state key ([workflow-state.md § Keys](../schemas/workflow-state.md#keys)), never the bare GitHub issue number.

**Standalone init** (`lifecycle: "self"`). Use the argument as `ISSUE_ID`, else:

```bash
.agents/skills/orch/scripts/git-context issue-from-branch .
```

Resolve `TRACKER` first. `github` skips the Linear-only launch preflight.

**Launch preflight** (Linear only, before any workflow state exists). Fetch the bundle with `--with-bundle`:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID] --with-bundle
```

Apply the Ancestor gate ([references/skill-rules.md § Coordination](../references/skill-rules.md#coordination)). A container is refused before anything is initialized, with its unblocked children surfaced as the startable items. A blocked item stops with its live blockers named. A parent whose read reports `in_pr_bundle` takes the gate's in-PR bundle rule and the § 2 Bundled issue delegation. That rule does not bypass the blocker check.

Apply [Worktree Scope](../SKILL.md#workflow-execution) and resolve `WT_PATH` as `git-context repo-root "[DIR]"`. Inside a worktree `[DIR]` is `.`; from the main repo it is `worktree path [ISSUE_ID]` when that exists, and ask the user before creating one when it does not.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

Initialize state unless it exists:

```bash
.agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]
```

```bash
.agents/skills/orch/scripts/git-context branch [WT_PATH]
```

```bash
.agents/skills/orch/scripts/orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch "[BRANCH_FROM_PREVIOUS_COMMAND]"
```

## 1. Determine Agent

Select the agent through [dev § Implementer selection](../../dev/SKILL.md#implementer-selection).

```bash
# Linear
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID] --format=compact
# GitHub
gh issue view [N] --repo [OWNER/REPO] --json labels --jq '.labels[].name'
```

## 2. Delegate

Apply [Delegation](../references/skill-rules.md#delegation) for the target worktree before choosing a stored dev agent or starting a replacement. Persistence follows [Agent Lifecycle](../references/skill-rules.md#agent-lifecycle).

Before every implementation delegation, managed entry at § 1 and each group's delegation in bundled mode included, repeat the Linear launch preflight from current facts:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID] --with-bundle
```

Apply the Ancestor gate ([references/skill-rules.md § Coordination](../references/skill-rules.md#coordination)), with its in-PR bundle rule when this read reports `in_pr_bundle`. Complete any further reads the gate requires. Stop on refusal before stamping or delegating. Use this read for the bundle's pending work and parent title. An earlier caller preflight does not replace this read. GitHub skips this Linear-only step.

Then stamp the round and apply the cleanup condition in [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure). Run each selected command as a separate tool call:

```bash
.agents/skills/orch/scripts/orch-runtime state set-git-head --item [ISSUE_ID] /pre_delegate_sha --worktree [WORKTREE_PATH]
```

A standing dev round (`.dev_round_id` not null, as a bundled group's predecessor leaves it) is reconciled before the new round supersedes it, so its admitted runs close with their words: write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[PRIOR_DEV_ROUND_ID]"}` and run it with the command below; a run its reply reports `live` keeps running under the superseded round.

Mint the round through the runtime. A hosted lane's `orch-runtime` is built by the provider's `create` on the host from the clone's sources; the launch refuses a host whose launch record names no built runtime. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "dev"}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
```

`[DEV_ROUND_ID]` is the reply's `.result.report.round_id`. The one write mints the token, supersedes the open dev stage and opens the new one ([workflow-state.md](../schemas/workflow-state.md) `stages`).

Apply [Round Closure](../references/skill-rules.md#round-closure)'s cleanup condition to the round's prune: write `[WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json` with the harness file tool as `{"op": "prune-round", "field": "dev"}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
```

```bash
.agents/skills/orch/scripts/orch-runtime state set-now --item [ISSUE_ID] /dev_delegated_at
```

Then write the round's admission request, `[WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json`, with the harness file tool as `{"op": "record-validation-admission", "round_id": "[DEV_ROUND_ID]"}`. The delegation's `Validation admission:` line names the command that runs it; the dev agent runs it before each validation start, so the run is admitted, under the directory the runtime names, before any work starts.

Then read the near-ceiling lines. Both templates below render one `Near-ceiling:` line per entry of this read, which the round-id stamp does not disturb; a first round on a fresh key reads `[]`, and a state written before the field existed has none; either renders none.

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /near_ceiling
```

Embed the round token as `[DEV_ROUND_ID]` in the delegation's `Round ID:` line and arm the watchdog per [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure). On Codex, resolve spawn parameters with `scripts/spawn-adapter spawn [AGENT_TYPE]`.

After each spawn, persist the session:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /child_sessions/[AGENT_TYPE] '{"status": "active", "agent_id": "[AGENT_OR_TASK_ID]", "runtime_agent_type": "[RUNTIME_AGENT_TYPE]", "agent_type_fallback": [FALLBACK_REASON_JSON_OR_NULL]}'
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
[For each near_ceiling line read from workflow state: "Near-ceiling: [LINE]"]
</delegation_format>

`[LABELS]` is the item's labels from § 1's read, comma-separated, or `none` when it carries none. The dev agent passes them to `orch-runtime dev-return --text write`, whose Apple gate reads them. `Validation admission:` is the exact command the dev agent runs before each validation start; the dev workflow does not depend on orch for it. The start under the admitted id is the runtime's: `orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]` starts the admitted directory as `orch-runtime validate start` does, resolving the mode from the project's declaration, recording the run's proof and job on the admitted `validate` entry before the launch, launching the run's job and printing the started line the dev skill parses. The job closes the entry with the sentinel's word and sends the lane its end notice, through the mailbox's outbound directive route, when the run ends.

**GitHub items** replace the `Issue:` line with `GitHub Issue: [OWNER/REPO]#[N]`. `Artifact Key:` stays `[ISSUE_ID]`, never `OWNER/REPO#N`.

### Bundled issue

Group pending sub-issues by `agent:[TYPE]` label and order them per [references/skill-rules.md § Coordination](../references/skill-rules.md#coordination) sequencing. Process groups sequentially: delegate, wait, validate (§ 3), collect handoff notes, next group.

Between groups, read each completed sub-issue's comments for a `Handoff Notes` section and combine them into the next delegation. Re-run § 2's stamps immediately before each group's delegation.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

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
Labels: [the parent's labels and every sub-issue's labels, each once, comma-separated, or none]
Validation admission: .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json
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

Acceptance is a pure function of **A** (the on-disk artifact) and **B** (git and tracker completion). The return message is display-only: run A/B on the § 2 watchdog deadline rather than waiting for one.

**Check A**, two tool calls:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
```

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]
```

`A` is the `verdict` field: `accept`, `wait` or `retry`. The checker selects the round's receipt under [dev-return.md § Identity](../schemas/dev-return.md#identity-the-round-id), the receipt of the run the round's newest `validate` stage names, and matches its internal `round_id`. Read its returned `path` for every artifact field below and carry that path to submit.

**Check B**, `B = pass` only when every check passes:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pre_delegate_sha
.agents/skills/orch/scripts/git-context head [WORKTREE_PATH]
git -C "[WORKTREE_PATH]" status --porcelain
.agents/skills/linear/scripts/linear.sh issues validate-completion [ISSUE_ID] --include-children-of [ISSUE_ID]
```

`HEAD` must differ from `pre_delegate_sha`, or, where it did not move, the round's proof must be complete for `HEAD`'s tree: `.agents/skills/orch/scripts/orch-runtime read-proof --item [ISSUE_ID] --need round --tree "$(git -C "[WORKTREE_PATH]" rev-parse "HEAD^{tree}")"`, the runtime's proof reader over the round's `validate` entries, must answer `complete` in `.result.proof`. `status --porcelain` must be empty, and the Linear validation (Linear only) must report `.all_ok`. `--include-children-of` expands the audit-created sub-issues worked in this session. Bundle-expanded children follow the linear skill's `validate-completion` contract. Dev-implement § Issue state records verified branch-box ticks and Evidence through a description-only update while each child stays In Progress. Validation reads that persisted checklist, whether or not it has post-merge boxes. The session root stays In Progress or In Review before merge. Carry qualified started children into submit-pr's child `Closes` lines and merge-pr's post-merge completion step. GitHub and ad-hoc rounds skip tracker validation: B is the new commit plus the clean worktree.

A round that meets the Stalled round conditions of [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure) goes to `orch-runtime round --text recover` whatever B reads, and its agent is never nudged or re-messaged; the table below covers every other round. Before `orch-runtime round --text recover` replaces the round, reconcile its admitted runs: write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[DEV_ROUND_ID]"}` and run it with Close The Round's Stages' command, so a lost or stopped run is a closed stage before the round is replaced. On its `redelegate` line the printed round id is already `dev_round_id`: apply the cleanup condition to that round's prune with § 2's request file, then take the rest of the `redelegate` row of [Round Closure](../references/skill-rules.md#round-closure):

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
```

`orch-runtime dev-return --text check` sets the round entry's kind and records its validation time for every `reason` but `missing` and `invalid`. A retry or escalation keeps that time. The stage ends are the runtime's, closed in Close The Round's Stages below.

| A (verdict) | B (git/tracker) | Action |
|---|---|---|
| `accept` | pass | **Accept** even with no return message. First confirm exact-commit binding: the artifact's `.commit` must equal `git -C [WORKTREE_PATH] rev-parse HEAD`. With `validate_mode` `ci`, acceptance completes local edits and leaves required PR CI pending; submit's existing exact-head wait supplies the proof. → Close The Round's Stages with `pass`, then Store Proposed Rules, then Store Near-Ceiling Lines, then Store QA State. |
| `accept` | fail | Re-read ONCE after a brief pause; if still failing, re-delegate only the specific missing step: commit the work, or commit/revert leftover files, or write the summary. Do not proceed. |
| `wait` | pass | Do NOT re-run the implementation. Send ONE report-only nudge: *"re-run only your completion tail — write your dev-return artifact (`orch-runtime dev-return --text write … --round-id [DEV_ROUND_ID]`) and re-report validate status, QA labels, and summary; do NOT re-run the implementation."* Accept only when a valid artifact for THIS round appears. |
| `wait` | fail | **Not done.** Wait to the deadline, then escalate per [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure). |
| `retry` | any | An artifact for THIS round exists but fails a gate; the check's `reason` names it. A structurally valid receipt whose `validate` fails may take the one recovery [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate) admits, under the original delegation, `pre_delegate_sha` and Check B: the runtime admits the round's next attempt, which writes its own receipt under its own run id, and the checker then selects the receipt the round's newest `validate` stage names. Check A again when that run has ended. A failing selected receipt, or an original that qualifies for no recovery, is final: run Close The Round's Stages with `fail`, then Store Proposed Rules and Store Near-Ceiling Lines, then end the workflow and report without another validation round. An identity/schema failure gets the report-only tail-rewrite nudge. Never accept, and never treat it as absent. |

Do not import the reviewer's re-delegate-on-invalid rule ([references/artifact-checks.md](../references/artifact-checks.md)).

Each Store subsection below runs whatever the one before it did. `status: no_pr` in Store Proposed Rules ends that subsection, not the accept path.

### Close The Round's Stages

The runtime is the one writer of a stage's end ([workflow-state.md](../schemas/workflow-state.md) `stages`). Runs on the `accept` row and on a final `retry`, before the Store subsections. First the round's admitted validation runs. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[DEV_ROUND_ID]"}` and run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
```

The runtime reads each open `validate` entry's run directory, and the job it started by the identity the entry records, and closes the entry with the word the run supports: an ended run with its sentinel's verdict, `pass`, `fail` or `no-verdict`; an admitted directory never created, a refused or never attempted start, or a run `validate stop` ended, `stopped`; a run whose job or child is gone without its sentinel, or that never recorded one, `lost`. A run whose job or child still runs stays open and is reported `live`, or `live-unit` under a user manager; one the runtime could not read stays open and is reported `unreadable` with the cause. The reply's `runs` rows name each. A run the runtime started carries its mode on the entry's `proof`; read `orch-runtime validate entry --record --run-dir [RUN_DIR]` for a closed run's timing when the round's report needs it. The reconcile first sends the end notice a closed run still owes its lane.

Then the round's own entry, with the same command over `{"op": "accept-result", "round_id": "[DEV_ROUND_ID]", "outcome": "[WORD]", "summary_file": "[WORKTREE_PATH]/tmp/completion-summary-[ISSUE_ID].md", "attachments": [SCREENSHOTS]}`, `[SCREENSHOTS]` the artifact's `screenshots` list as `orch-runtime dev-return --text check` echoed it (`[]` where it echoed none): `pass` on the accept row, `fail` on a final retry. `outcome` is required; a request without it is refused `request-invalid`.

The request names no `authorization`: this close is the lane's own acceptance of its round, and it skips no ask [communication-modes.md](../references/communication-modes.md) owns. An item keyed `directive-[ID]` adds `"authorization": {"by": "owner-directive", "id": "[ID]"}`, the directive the change was made under; its round refuses a close without it as `authorization-missing`. A close adds `"authorization": {"by": "overseer", "id": "[ENVELOPE_ID]"}` only when the overseer has acted on this lane's own question: `[ENVELOPE_ID]` is the id of the envelope in the lane's inbox that answers the lane's `lane-question` for this step, or of an owner's directive the overseer relayed to the lane. A launch ruling, a fleet-log row or a session id is never that id, and no one but this workflow writes the field. submit-pr reads whichever authorization the record holds through `state inspect --item [ISSUE_ID]`, and takes each ask's `auto-recommended` action under a recorded one.

`summary_file` names the round's Completion Summary, the artifact's `summary` written to that path with the harness file tool. Omit it, and `attachments`, where `TRACKER` is GitHub, as [micro.md](micro.md) step 6 skips its post, since the Linear CLI refuses every post for a GitHub item, and for a bundled round, whose parent's one summary is the post [dev-implement.md § 11](../../dev/workflows/dev-implement.md#11-return-bundled) makes. After the close the runtime creates the item's comment headed `## Completion Summary` through the tracker CLI with one `--attach` per `attachments` path, records its id and its attachment links as `summary_comment`, and updates that one comment in place on every later acceptance with the recorded links rendered under the summary (a comment the list finds with no record is the acceptance's own, recorded and updated the same way), and reports `summary` with `posted` `created`, `updated`, `failed` or `unrecorded` and its cause, a failed post leaving the acceptance standing. A repeated accept closes nothing again: it reports the recorded end and word, and its summary updates the one comment as above; one naming another authorization is refused `authorization-differs`.

### Store Proposed Rules

Read the structurally valid artifact passed by the caller, including a failing-validation artifact, and get its `summary`. For each bullet under `### Proposed Rules`, use the harness file tool to write the rule as one JSON string in `tmp/proposed-rule-[ISSUE_ID].json`. Append each rule to workflow state through this deduplicating update. Skip this step when the summary has no such bullet. It is this file's one write through the `workflow-state` store: no runtime state verb appends to an array without repeating a value it holds.

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile rule tmp/proposed-rule-[ISSUE_ID].json '.pr_comment_review.proposed_rules = (((.pr_comment_review.proposed_rules // []) + [$rule[0]]) | unique)'
```

After all rules are stored, resolve the PR from the worktree:

```bash
.agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,body
```

`status: no_pr` ends this step. Normal PR creation reads the stored list. When a PR exists, read the complete stored list from workflow state:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pr_comment_review/proposed_rules
```

Write the remote `body` value to `[WORKTREE_PATH]/tmp/pr-body-proposed-rules-[ISSUE_ID].md` with the harness file tool. Replace only its `## Proposed rules` section with the stored list, or add that section when absent. Preserve every other line from the remote body. Post that file:

```bash
.agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/pr-body-proposed-rules-[ISSUE_ID].md
```

Do not rebuild the body from the local worktree or push a commit from this step. This is the sole publication owner for proposed rules.

### Store Near-Ceiling Lines

The accept paths, implement and fix alike, and the retry path for a structurally valid artifact with a failing `validate` run this subsection. It is the one writer of `.near_ceiling`.

`[NEAR_CEILING_ARRAY]` is the artifact's `near_ceiling` as `orch-runtime dev-return --text check` echoed it: a JSON array of strings, `[]` when the round recorded none, or `null` when the byte-ceiling probe did not answer: the lane exited other than 0 or 1, the lane path held a file or link that could not run, or the writer ran without `--near-ceiling-base`. On `null`, skip the write and name the echoed `near_ceiling_error` in the round's report; an empty list there would tell the next round no binary blob is near the ceiling. Each entry names a binary blob that round left within reach of the byte ceiling. The next round's delegation renders one `Near-ceiling:` line per entry so it can plan Git LFS, an asset store or generation before the blob grows. The write REPLACES the key: state describes the branch as the last recorded round left it. A blob moved out of Git stops being carried, and a blob pushed into the warn band starts being carried.

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /near_ceiling '[NEAR_CEILING_ARRAY]'
```

### Validation status

A run's cost stands in two records. `orch-runtime dev-return --text check` records each schema-valid receipt's validation seconds in `validate_rounds` before its verdict routes the round; the round's `validate` entry on `stages` is the runtime's, with the run's `start`, `end` and `proof` (`schemas/workflow-state.md` `stages`). `record-push` records a restack's validation after a successful push, in `validate_rounds` and `stages` together.

A lane under an overseer rewrites its status file's validation line from `.validate_rounds`, per [oversee.md § 3 Lane directive](oversee.md#lane-directive). It then lists each `.restack_skips` entry's condition and paths, which [merge-pr-restack.md](merge-pr-restack.md) step 2 writes.

### Store QA State

The implement path only; a fix round has no QA signals or sub-issue set to record.

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /qa_labels '[QA_LABELS_ARRAY]' /sub_issues '[SUB_ISSUE_IDS_ARRAY]'
```

Map each Done-when item to the files serving it, in the PR body; every round measures against that map, never against its own last state, and an unmapped hunk is cut unless it is a [landing enabler](../../dev/SKILL.md#engineering-rules).

## 4. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
