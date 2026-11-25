# Dev implementation round

Read [code-quality](../../code-quality/SKILL.md) before writing or modifying code, including for ad-hoc requests.

The workflow for a dev or QA agent receiving a work-item delegation. Run it first line to last for one round. Skip every tracker update for ad-hoc requests (no issue reference).

Run `pwd -P` before the first repo-relative command; it must print the delegation's `Worktree:` path. On any other path, stop and report where the shell started.

| Delegation | Detection | Flow |
|------|-----------|------|
| Single | `Issue: [ISSUE_ID]`, `GitHub Issue: OWNER/REPO#N`, or ad-hoc | § 1 → § 2 → § 4-10 → return |
| Bundled | `Parent: [ISSUE_ID]` + `Sub-Issues: [...]` | § 1 → § 2 → [§ 4-10]×N → § 11 |

A single round on § 2.3's no-change route runs § 1 → § 2 → § 9.1 → § 10 → return.

**A bundle needs `in_pr_bundle`.** A parent with children is a CONTAINER, whatever its title, unless its safe read reports `in_pr_bundle`, the review audit's in-PR bundle root. A leaf issue carrying an internal checklist is one work item, delegated single. Read the parent before the first sub-issue; with `in_pr_bundle` false, stop and report the mis-delegation:

```bash
.agents/skills/linear/scripts/linear.sh issues get [PARENT_ID]
```

In the sub-issue tree, implement blockers before the issues they block. The delegation's group list marks earlier groups' implemented children `(completed)` regardless of tracker state; these entries are context only and are skipped in the § 4 loop.

An optional `Near-ceiling:` line, one per binary blob, is a `byte-ceiling` record a previous round produced: the path, its bytes, the ceiling in bytes and the percent reached.

- Plan or perform a move to Git LFS, an asset store or generation before the blob grows further.
- If that remedy cannot be applied here, state why in the return.

With no line, no binary blob is known to be within reach of the ceiling.

---

## 1. Environment Setup

Every path is worktree-scoped: `git -C [WORKTREE_PATH] ...` for Bash, `[WORKTREE_PATH]/...` for file tools, once the working-directory check at the top of this file has passed.

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
```

If `[WORKTREE_PATH]/.agents/skills/github/scripts/git-https-auth` is installed and executable, use it for the baseline fetch:

```bash
[WORKTREE_PATH]/.agents/skills/github/scripts/git-https-auth -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

Otherwise use git:

```bash
git -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

---

## 2. Activate Work Item

### 2.1 Claim And Read Context

Determine the tracker: `Issue:`/`Parent: ABC-123` → Linear; `GitHub Issue: OWNER/REPO#N` → GitHub; no reference → ad-hoc (delegation text is the source of truth; skip every tracker write).

Linear only: activate the issue, or the parent alone if bundled (sub-issues activate individually in § 4):

```bash
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh comments list [ISSUE_ID]
```

- Every read is live.
- A failed read or activation stops the round with its exact diagnostic, an auth, API or configuration failure.
- A rate-limited activation is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds.
- Never run this Linear preflight for GitHub-tracked or ad-hoc work.

GitHub only:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Ad-hoc: no tracker reads.

**If bundled with siblings marked `(completed)` in the delegation's group list**, read their comments too, all of them in one `linear.sh comments bulk-list [COMPLETED_SIBLING_ID_1] [COMPLETED_SIBLING_ID_2]` call, for handoff notes. Use the list, not tracker state, to select these implemented siblings. A refusal carrying `missing` names siblings Linear has no issue for, because they are deleted or mistyped: stop and report those identifiers.

### 2.2 Research Context

- Read the issue description, `.description` from the read above, or `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`.
- For a sub-issue, read the parent's description too.
- For a bundle, read the unique paths across its sub-issues.

Before the first edit, read each page that the repository's `AGENTS.md`, and the `AGENTS.md` nearest each path the change touches, routes for those paths.

- Cited research, decision, and context files are mandatory reading; how the research applies is yours to decide.
- Evaluate it against existing patterns and the principle docs, the pages that routed read names.
- Reference an already-recorded decision (`.agents/skills/decider/scripts/decisions search --issue [RESEARCH_ISSUE_ID]`, and `decisions search "[KEYWORDS]"` for the area) rather than duplicating it, reading the full record and its status before treating it as binding.

For a missing planning or research path in a brief, find it by the route the project-management skill's references/planning-artifacts.md gives for the work item's tracker before classifying the context as missing.

### 2.3 Evaluate Feasibility

- Check your domain's code before planning: do the required APIs and types exist, is another domain's work a prerequisite, is an existing issue blocking?
- Search prior decisions with `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` and read the full decision file rather than the index summary.
- Never implement an approach a decision explicitly rejects.
- If the issue description contradicts a decision, report back with the reference.
- Optimization work with no `baseline` label takes the label now, before any code change.

**No change needed.** A Linear item whose description permits ending with no change, by a sentence such as "if no change is needed, record the comparison and make no commit", takes the no-change route when the comparison that sentence names finds no change needed:

- Make no edit and no commit, and run no check.
- Write the comparison as § 9.1's summary.
- Write § 10's no-change receipt quoting that sentence.

Ask no one whether the round may end so: orch's acceptance judges the quoted sentence. A round on a GitHub or ad-hoc item, or one whose item holds no such sentence, takes the normal route.

Blocked → **§ 3**, then STOP. No change needed → § 9.1, then § 10. Clear → § 2.4.

### 2.4 Plan Approach

- Linear only, when scope differs from the estimate: `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --estimate N`, a relative size class from 1, smallest, through 5, largest (project-management references/filing.md § Estimate).
- **If bundled**: order sub-issues by dependency and overlap.
- A delegation's `Admitted paths:` line bounds the paths the plan may change: check the plan against it under [dev SKILL.md § Round Contract](../SKILL.md#round-contract) before any edit. A path outside the set takes that section's steps 3 and 4, then STOP; § 3 does not apply.
- A required command the delegation names runs in the shape orch's SKILL.md § Harness-Safe Shell admits. A command whose environment this session cannot satisfy is a blocker to report, never a license to run it under the wrong environment.

### 2.5 Domain Setup

Confirm the delegated role against [dev § Implementer selection](../SKILL.md#implementer-selection). Follow your agent definition for architecture docs, code paths, and skills to load.

### 2.6 Capture Baseline

**Skip if** the issue has no `baseline` label. Otherwise identify the affected component and, when a benchmarking skill is installed, follow its baseline workflow.

---

## 3. Block Issue

**Skip if** § 2.3 routed you to § 2.4. GitHub and ad-hoc work reports the blocker in the return message instead of writing tracker state.

Linear only, when an existing issue blocks this one:

```bash
.agents/skills/linear/scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "Cannot proceed until [REASON]"
```

When the prerequisite issue does not exist yet, label the issue `blocked` (`linear.sh issues update [ISSUE_ID] --labels "agent:[AGENT_TYPE],[COMPONENT],blocked"`), then write `tmp/blocked-[ISSUE_ID].md` and post it with `linear.sh comments create [ISSUE_ID] --body-file tmp/blocked-[ISSUE_ID].md`:

```markdown
[What stays stopped until the prerequisite lands, and what that delays for the person.]

BLOCKED: Cross-domain prerequisite needed.

**Required Domain**: [DOMAIN]

**Suggested Labels**: agent:[DOMAIN], [COMPONENT]

**Prerequisite Issue**: [One-line description]

**Why Blocking**: [What this issue needs, why it cannot proceed, what the prerequisite must provide]

**Suggested Scope**:

- [Deliverable 1]

**Evidence**: [Where the blocker was read]

**Next**: Requesting orchestrator create prerequisite issue.
```

Your return states the blocker, the domain and labels for the new issue, and that the description is ready for creation. When a blocker later resolves: `linear.sh issues unblock [ISSUE_ID]`.

---

## 4. Implement

**If bundled**: each sub-issue is its own task through § 4-10. Work only the sub-issue named in the current task, activating it first with `linear.sh issues activate [SUB_ISSUE_ID] --agent [AGENT_TYPE]`.

### 4.1 Verify Branch

`git branch --show-current` must report `[BRANCH_NAME]`, the parent's branch when bundled.

Record `git -C [WORKTREE_PATH] rev-parse HEAD` as `[ROUND_BASE]` before implementation. A fix round uses its delegated record's `base_sha` instead.

### 4.2 Implement

Implement per your domain expertise; § 5 runs the quality gates.

Before writing a refusal, a validator, a lock, a retry, or a test, read [dev SKILL.md § Engineering Rules](../SKILL.md#engineering-rules).

- **Scope growing?** Report the discovered scope in § 9 for every tracker; never create issues here. Follow [skill-rules.md § Coordination](../../orch/references/skill-rules.md#coordination) for issue creation.
- **Work outside scope?** Note it under Discovered Work in § 9.
- **Need deeper research?** Add the `needs-research` label, pause, report.

For every callee whose call the change deletes, run `git grep -n -F --untracked --exclude-standard -e <callee> --`, then apply [code-quality § Cleanup](../../code-quality/SKILL.md#cleanup).

### 4.3 Update Documentation And Decisions

Update a doc when the implementation makes a claim in it false. A code change alone owes no doc change.

**Skip decision recording if** the choice is below the decider bar, the decider skill's `SKILL.md` § What warrants a decision record, and why: that reason is a comment at the code. Otherwise:

- Follow the decider skill's create-decision workflow.
- Cite the decision ID in the § 9 summary.

### 4.4 Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect). Complete every repository edit from reflection before validation.

---

## 5. Validate

**Skip if** the round takes § 2.3's no-change route: it runs no check, and its receipt records `not-run`.

[references/validation.md](../references/validation.md) holds the gate's contract; each step below names its section there. Run the gate in this order:

1. Stage the final edits, using the index policy in [§ 7. Commit](#7-commit):

   ```bash
   git -C [WORKTREE_PATH] add -A
   ```

2. Where the delegation carries a `Validation admission:` line, run that exact command before every validation start of this round (§ Admission).
3. Start the validation entry (§ Validation entry). A project whose own policy forbids orch's validation runner takes § Foreground route in its place. A start refused `run-live` takes § Run-live refusal.
4. On the runner route, wait for the entry's verdict before running the delegation's required verification commands and the must-fail controls (§ Verification scope, § Must-fail controls). On the project foreground route, run those commands and controls before the project's entry point. Use [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation) to run the checks.
5. Where the Apple gate names the item, run `fleet-mac-run test` (§ Apple gate).
6. A `validate=no-verdict` takes § No-verdict. If a check fails after the runner starts, use § Recovery for any in-scope repair; a test-only PR also takes § Test-only validation ceiling. An earlier verdict cannot prove the repaired contents.
7. Read the run's selection and per-check time (§ Selection and time readings).
8. Run the commit-time checks and Visual QA below.
9. Record the validation result in the completion artifact for submit to reuse on the same contents.

A script written only to produce a number for the issue is not committed; report its result in the return for the orchestrator to put in the PR body. An uncommitted measurement is not a check the change adds or modifies.

### Commit-time checks

Where `orch-runtime validate policy --stage git-hooks`, with `--base-checkout` naming the main checkout, answers `run`, and `.agents/skills/commit-guards/scripts/install-git-hooks --check --repo [WORKTREE_PATH]` exits 0, the round's commit through those hooks runs preflight and doc-limits. Otherwise use the two standalone stage routes below, including for CI rounds.

Where `orch-runtime validate policy --stage preflight`, with `--base-checkout` naming the main checkout, answers `run`, run preflight when installed (`test -x .agents/skills/preflight/scripts/preflight`) through the orch job runner per [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation). Where it answers `skip`, run no preflight:

```bash
.agents/skills/preflight/scripts/preflight --repo [WORKTREE_PATH]
```

Where `orch-runtime validate policy --stage doc-limits`, with `--base-checkout` naming the main checkout, answers `run`, use the same orch job runner route for doc-limits when installed (`test -x .agents/skills/doc-limits/scripts/doc-limits`). Where it answers `skip`, run no doc-limits:

```bash
.agents/skills/doc-limits/scripts/doc-limits
```

### Visual QA

**Skip if** the issue has no `design` label. Otherwise use the project's visual QA skills to confirm what your change affects renders correctly, not the full checklist. Do NOT capture golden baselines.

---

## 7. Commit

**Skip if** the round takes § 2.3's no-change route: HEAD stays where the round started.

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
git -C [WORKTREE_PATH] log -1 --oneline
```

- Use the CURRENT sub-issue ID when bundled, not the parent's.
- Never stage lock files the project gitignores; stage specific files by name.
- When validation failures remain, add `[validate: FAILING_CHECK]` to the body as a second `-m`, never to the header.

---

## 8. Record QA Signals

Based on the FINAL validated code, decide which extra QA passes the change needs. Record them in the completion artifact (§ 10 `--qa-label`, one per signal), not a tracker mutation.

| Trigger | Signal |
|---------|--------|
| Unsafe code, atomics, lock-free | `needs-safety-audit` |
| A named hot-path, latency-sensitive or shared-build operation whose cost the change can alter, with a measurement route (below) | `needs-perf-test` |
| New module, public API | `needs-review` |
| Changed view, layout, styling or UI copy | `needs-ui-review` |

A round that raises `needs-ui-review`, or changes a file a `QA_UI_PATHS` glob matches (`.agents/skills/orch/scripts/orch-env QA_UI_PATHS ""`):

- builds each changed view to the polish bar in [code-quality references/ui.md](../../code-quality/references/ui.md) and the design-system doc `QA_UI_DESIGN_DOC` names (`.agents/skills/orch/scripts/orch-env QA_UI_DESIGN_DOC ""`);
- captures its screenshot set by [reviewer references/ui-screenshots.md § Screenshots](../../reviewer/references/ui-screenshots.md#screenshots), listed in § 9.1's Screenshots section and named to the writer, one `--screenshot` per file (§ 10).

The `needs-ui-review` QA pass judges each view from that set.

`needs-perf-test` needs a performance surface and a measurement route.

- The surface is the operation or path the final code changes, and the reason the change can alter its cost. A broad label such as "shared build" gives no reason, and an identity or permission change alone has no performance surface.
- The route is the project's documented benchmark, runner or regression check, with a workload and a baseline that can answer that concern.
- Work isolated behind a development-only feature gate does not take `needs-perf-test`: run the feature-gated checks locally and signal only if shared or feature-off paths are affected.
- Record the surface, the reason and the route in the Completion Summary's Key Decisions (§ 9.1).
- A real concern with no measurement route takes no signal: record the concern and the exact missing prerequisite (workload, baseline or runner) there, for disposition.
- Never report a missing benchmark as evidence that the change is safe or at risk.

A signal is never silently dropped: every triggered row appears in the artifact and in the return's `QA:` line, and `none` is an explicit answer, not a default.

---

## 9. Write the Completion Summary

### 9.1 Completion Summary File

Always required. The summary carries the outcome only: what changed, each check that ran with its verdict, and what is still open. It links the round's evidence file, which holds the proof.

- On § 2.3's no-change route it holds the comparison: what was compared, against what, and the finding that no change is needed. The round writes no evidence file, and its Checks section holds one line, `none: no check ran (no-change route)`.
- Write `tmp/completion-summary-[ISSUE_ID].md`, in a bundled round `tmp/completion-summary-[SUB_ISSUE_ID].md` for the current sub-issue. A single round's artifact carries it via `--summary-file` (§ 10).
- A single round posts nothing: on Linear, orch's acceptance of the round posts this file to the issue as the item's one Completion Summary comment, with the screenshots § 10 names attached, and updates that comment on every later round.
- A bundled round's acceptance posts no summary, since its request names no `summary_file`. So on Linear, post each sub-issue's summary yourself once its commit stands and its evidence file is attached: `linear.sh comments create [SUB_ISSUE_ID] --body-file tmp/completion-summary-[SUB_ISSUE_ID].md`, with one `--attach` per screenshot § 8 captured for it. § 11 posts the parent's.
- GitHub and ad-hoc rounds attach nothing. They return the summary to the orchestrator with the evidence file's sections appended after it.

**Evidence file.** Write `tmp/evidence-[ISSUE_ID]-[DEV_ROUND_ID].md`, in a bundled round `tmp/evidence-[SUB_ISSUE_ID]-[DEV_ROUND_ID].md`, in the evidence template below. It holds each Done-when box's proof and the full Validation Routes record.

- On Linear, attach it once its commit stands, in an attach-only call: `linear.sh issues update [ISSUE_ID] --attach tmp/evidence-[ISSUE_ID]-[DEV_ROUND_ID].md`, the sub-issue's ID and file in a bundled round.
- Each round attaches its own file. Earlier rounds' files stay on the item.
- Put the URL of the returned `attachments[0]` in the summary's `**Evidence file**` line. On a GitHub or ad-hoc round, that line names the path with no link.
- If the attach fails, stop the round with its diagnostic.

**Where the records live.** [references/validation.md § Where the records live](../references/validation.md#where-the-records-live) states where each round's Validation Routes rows live.

**Validation routes.** Before writing a completion, fix, session or merge summary, read each actual run's native `start` and `orch-runtime validate entry --record --run-dir [RUN_DIR]` evidence while available.

- Use `--record` for its reported fields and `start` for that run's actual `quiet-secs`.
- Include one row per run, with its original round id and kind, run directory, recorded head/start identity, and source references.
- Keep implementation, fix and restack runs separate; a restack has no dev round id.
- Preserve earlier attempts and recovery or reused-run references rather than replacing their outcomes with the final verdict.

Print every field of the Validation Routes row in the evidence template below.

- Each field a record does not carry, or a source left unread, is `unknown`, including absent `scoped` or `ci-fallback`.
- Retain reported values such as `selection=unreported` and `verdict=unfinished`.
- An unread source keeps its reference and diagnostic.
- Preserve `FAILING` and required CI's `pending` separately from local `pass`.
- Keep native `cause=stalled` and host-caused `no-verdict` classifications in `outcome`, with the native ending or sentinel. Never infer fallback, scope or a stall from prose or elapsed seconds: the run's `--record` line and its sentinel own those classifications.
- A refused start is recorded as such and creates no validation run or verdict.

```markdown
## Completion Summary

[What the implemented change does for the person, and whether acceptance is complete, failed or still pending.]

**Agent**: [AGENT_NAME]

**Branch**: `[BRANCH]`

**Revision**: [COMMIT_SHA] from base [ROUND_BASE]

**Evidence file**: [`tmp/evidence-[ISSUE_ID]-[DEV_ROUND_ID].md`]([ATTACHMENT_URL])

### Checks

- [CHECK]: [pass|FAILING|no-verdict|pending in required CI]

### Open

- [An unproved box, a pending CI check or a post-merge check]

### Key Decisions

1. Decision and reasoning (link DXXX if recorded)

### Files Created/Modified

- `path/to/file` - One meaningful change, skill, doc and rule changes included

### Domain Metrics

- [Actual reading beside its target, with scope, observation time and source]

### Screenshots

- `tmp/ui-shots/[FILE]` - [View], [before|after], [THEME]

### Discovered Work

- [Type]: Description (estimate: N)

### Handoff Notes

[What the next agent in this bundle needs for its current-scope work: struct changes, API contracts, file locations]

### Proposed Rules

- [Rule the validation list is missing]
```

The evidence template:

```markdown
# Evidence: [ISSUE_ID], round [DEV_ROUND_ID]

**Revision**: [COMMIT_SHA] from base [ROUND_BASE]

## Done-when proof

- Box [N]: [Proving artifact link at the revision, with its conditions. Pending CI and live acceptance stay explicit.]

## Validation Routes

- round=[ORIGINAL_ROUND_ID_OR_UNKNOWN] kind=[implement|fix|restack] run-dir=[RUN_DIR_OR_UNKNOWN] head=[RECORDED_HEAD_OR_UNKNOWN] start=[RECORDED_START_OR_UNKNOWN] source=[NATIVE_START_AND_RECORD_REFERENCES] validate-mode=[VALUE_OR_UNKNOWN] selection=[VALUE_OR_UNKNOWN] ci-fallback=[VALUE_OR_UNKNOWN] scoped=[VALUE_OR_UNKNOWN] seconds=[VALUE_OR_UNKNOWN] quiet-secs=[ACTUAL_QUIET_SECS_OR_UNKNOWN] verdict=[VALUE_OR_UNKNOWN] outcome=[NATIVE_CLASSIFICATION_OR_UNKNOWN]
```

- Keep `## Completion Summary` as the first line. Orch's acceptance finds the item's summary comment by that heading. The opening paragraph follows it.
- Do not repeat the issue's Story or Why this matters.
- Omit any section that has nothing in it.
- Link each proof once, under the evidence file's Done-when proof. The summary states no proof.
- Name each check once under Checks, with its verdict. The Validation Routes row behind it stays in the evidence file.
- In a bundled round, a sub-issue box § 10 ticks names its proof in a one-line `Evidence:` line. A single round's boxes take their Evidence lines at merge from the PR body's `## Done-when evidence` ([merge-pr.md § 5](../../orch/workflows/merge-pr.md#5-execute-the-merge)).
- Discovered Work is backlog work beyond this scope.
- Handoff Notes are for the next agent only, with no aspirational suggestions.

**Discovered Work marker prefixes.** A bullet belonging to a later stage of THIS PR rather than to the backlog carries a marker as the first token of the bullet text, before `[Type]`. Unmarked bullets go through the TPM audit as backlog work.

- `handoff_to_submit_pr:`, content the upcoming submit-pr step produces, e.g. PR-body material.
- `handoff_to_merge_pr:`, something the eventual merge-pr step handles.
- `current_workflow_action:`, something the current review-pr cycle should handle itself.

### 9.2 Downstream Handoff

**Skip if** the tracker is not Linear, this issue blocks nothing, or completion alone unblocks the downstream work.

1. Read `.blocks` from `linear.sh issues get [ISSUE_ID]`.
2. Post to a downstream issue **only if** this work changed an API, interface, file, or contract it depends on.
3. Read the downstream issue's comments first. Where a `Handoff from [ISSUE_ID]:` comment already names the same change, post nothing.
4. Write `tmp/downstream-handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md` in the form below, then post it with `linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file [THAT_FILE]`.
5. Never post it to the completed issue.

```markdown
Handoff from [ISSUE_ID]: [The changed API, file, interface or decision, in one sentence.]

**Source**: [Commit, file or decision that changed it]

**Next**: [What the downstream work does differently]
```

---

## 10. Finalize

With every applicable section above complete, write the artifact per [dev SKILL.md § Round Contract](../SKILL.md#round-contract):

`[BASE_BRANCH]` is what § 1's `resolve-base-branch` reported; `--near-ceiling-base` takes it as `origin/[BASE_BRANCH]` because § 1 fetched that remote ref and left the local branch where it was.

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|no-verdict|handed-over|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR] | --validate-record [FILE]] [--exception-file [FILE]] [--validate-note [TEXT]] [--label [LABEL]]... [--no-labels] [--qa-label [LABEL]]... [--screenshot [PATH]]... --near-ceiling-base origin/[BASE_BRANCH]
```

On § 2.3's no-change route, write this receipt in its place, `[HEAD_SHA]` being the HEAD the round started at and `[ITEM_SENTENCE]` the item's sentence that permits the route, quoted as the description holds it:

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA] --validate not-run --no-change "[ITEM_SENTENCE]" --summary-file tmp/completion-summary-[ISSUE_ID].md [--label [LABEL]]... [--no-labels] --near-ceiling-base origin/[BASE_BRANCH]
```

The writer refuses it where the item's description does not hold the sentence, HEAD moved, the tree is dirty or a run is named ([dev-return.md § No-change receipt](../../orch/schemas/dev-return.md#no-change-receipt)). Report a refusal's line in the return; never rewrite the round as a pass.

- `[RUN_DIR]` is the `run-dir=` value the validation entry printed.
- A `pass` needs that run to have passed, a `no-verdict` a run that recorded that result. Omit the flag when validation failed before any run started or when an interrupted run on [validation.md § Foreground route](../references/validation.md#foreground-route) has no completed record.
- A project whose own policy forbids orch's validation runner and runs its validation entry point in the foreground passes `--validate-record [FILE]` in place of `--validate-run-dir`, `[FILE]` being the original or recovery record [validation.md § Foreground route](../references/validation.md#foreground-route) wrote for this attempt.
- `--validate handed-over`, with no run flag, passes a group's committed work to the group after it, which validates: the writer takes it only where the round began with a group that is not the last, the commit moved past the round's base and the receipt names its items.
- `--exception-file [FILE]` cites, beside a `FAILING` run, the exception `{by, id, excused}` the round began with; the receipt keeps its `FAILING` line.

- One `--qa-label` per § 8 signal, none if nothing triggered.
- One `--label` per entry of the delegation's `Labels:` line, or `--no-labels` when it reads `none`.
- One `--screenshot` per file § 8 captured, the path the Screenshots section lists. The writer refuses a path it cannot read, and the acceptance attaches each to the summary comment.

- Every single round appends `--summary-file tmp/completion-summary-[ISSUE_ID].md`.
- GitHub and ad-hoc rounds also append `--no-summary`.
- Bundled rounds add `--bundled` and one `--item` per sub-issue, § 11.

**Issue state.**

- A bundled Linear sub-issue stays In Progress through the dev round; make no tracker state write here.
- Read its current description, tick each branch-provable Done-when box verified by this round, and add a nonblank indented `Evidence:` line directly below each ticked box.
- The `Evidence:` line is one short line that names its proof: a commit, a run, a test name or the evidence file § 9.1 attached. The proof itself stays in that file.
- Save the updated description under `tmp/` and run `linear.sh issues update [SUB_ISSUE_ID] --description-file [DESCRIPTION_FILE]` with no state flag.
- Leave unproved boxes open.
- Its proof also stays in its evidence file and the bundle artifact's `--item` result (§ 11).
- Orch's merge-pr workflow § 5 alone owns the completion-time box selections, writes the `--evidence-file` its completion reads and completes the child at merge.
- The worktree's top-level managed issue stays In Progress or In Review until the PR merges.
- GitHub and ad-hoc issues close through the PR body or merge, never here.

Carry a child with proved branch work and open post-merge checks into the parent summary in its current started state. The parent follows orch's submit-pr and merge-pr child handoff. Post-merge completion supplies the shared PR's merge time before moving the child to Verifying.

**If single**, return now:

<output_format>
Branch: [BRANCH_NAME]
Commit: [SHA]
QA: [signals or "none"]
Validate: [pass, "no-verdict: [CAUSE]", "FAILING: check1, check2", or "not-run: no change"]
Proposed rule: [proposal or "none"]
Summary: [ISSUE_ID] ✓
</output_format>

**If bundled**, mark the task completed and take the next sub-issue as a separate task, or go to § 11 when none remain.

---

## 11. Return (Bundled)

**Skip if** single: you returned at § 10.

1. **Aggregate QA signals across sub-issues** (including nested ones) into the bundle artifact's `--qa-label` flags, the union of every sub-issue's § 8 signals. No tracker mutation. The near-ceiling lines need no union: the writer's probe measures the whole branch, every sub-issue's commits included.

2. **Post the parent summary** (Linear only), beside each sub-issue's own from § 9.1: write `tmp/bundle-summary-[PARENT_ID].md`, then `linear.sh comments create [PARENT_ID] --body-file tmp/bundle-summary-[PARENT_ID].md`, with one `--attach` per screenshot. Its Screenshots section is the union of the sub-issues' lists.

   ```markdown
   ## Bundle Complete

   [The combined effect for the person, and each child's acceptance state, pending proof included.]

   **Agent**: [NAME] | **Branch**: [BRANCH]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1] ✓ | blocks: [SUB_ISSUE_2] | [CHILD_SUMMARY_LINK]
   ↳ [SUB_ISSUE_2] ✓ | blocked by: [SUB_ISSUE_1] | [CHILD_SUMMARY_LINK]
      ↳ [SUB_ISSUE_3] ✓ | [CHILD_SUMMARY_LINK]  ← nested
   Files: N | Commits: N | QA: [LABELS]

   ### Screenshots

   - `tmp/ui-shots/[FILE]` - [SUB_ISSUE], [View], [before|after], [THEME]

   ### Proposed Rules

   - [Rule the validation list is missing]
   ```

   - Link each child's summary for its files, decisions and metrics, and the evidence file its `**Evidence file**` line links for its proof. File and commit counts do not replace that proof.

3. **Write the artifact**, keyed to the Parent ID, with that group's `Round ID:` when the bundle was delegated in groups:

   ```bash
   .agents/skills/orch/scripts/orch-runtime dev-return --text write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [LAST_SUBISSUE_HEAD_SHA] --validate [pass|no-verdict|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR] | --validate-record [FILE]] [--validate-note [TEXT]] --summary-file tmp/bundle-summary-[PARENT_ID].md --bundled --item [N] [DECISION] [REASONING] [--item ...] [--label [LABEL]]... [--no-labels] [--qa-label [LABEL]]... --near-ceiling-base origin/[BASE_BRANCH]
   ```

   `--bundled` requires one `--item` per sub-issue result: `DECISION` is Applied, Skipped, or Blocked and `REASONING` non-empty plain text with no backticks, populated from the sub-issue tree. `--commit` is the last sub-issue's HEAD.

4. **Return.** Posting the parent summary is not a return.

   <output_format>
   Parent: [ISSUE_ID]
   Sub-Issues: [tree format with ✓]
   Branch: [BRANCH]
   Commits: [COUNT] ([SHAS])
   QA: [AGGREGATED_SIGNALS or "none"]
   Proposed rule: [proposal or "none"]
   Summaries: [all issue IDs ✓]
   </output_format>
