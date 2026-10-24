# Issue Lifecycle

The caller applies [orch § Delegation](../../orch/references/skill-rules.md#delegation) before selecting an agent for each round.

Read [code-quality](../../code-quality/SKILL.md) before writing or modifying code, including for ad-hoc requests.

The workflow for a dev or QA agent receiving a work-item delegation. Skip every tracker update for ad-hoc requests (no issue reference).

Run `pwd -P` before the first repo-relative command; it must print the delegation's `Worktree:` path. On any other path, stop and report where the shell started.

| Delegation | Detection | Flow |
|------|-----------|------|
| Single | `Issue: [ISSUE_ID]`, `GitHub Issue: OWNER/REPO#N`, or ad-hoc | § 1 → § 2 → § 4-10 → return |
| Bundled | `Parent: [ISSUE_ID]` + `Sub-Issues: [...]` | § 1 → § 2 → [§ 4-10]×N → § 11 |

**A bundle needs `in_pr_bundle`.** A parent with children is a CONTAINER, whatever its title, unless its safe read reports `in_pr_bundle`, the review audit's in-PR bundle root. A leaf issue carrying an internal checklist is one work item, delegated single. Read the parent before the first sub-issue; with `in_pr_bundle` false, stop and report the mis-delegation:

```bash
.agents/skills/linear/scripts/linear.sh issues get [PARENT_ID]
```

In the sub-issue tree, implement blockers before the issues they block. The delegation's group list marks earlier groups' implemented children `(completed)` regardless of tracker state; these entries are context only and are skipped in the § 4 loop.

An optional `Near-ceiling:` line, one per binary blob, is a `byte-ceiling` record a previous round produced: the path, its bytes, the ceiling in bytes and the percent reached. Plan or perform a move to Git LFS, an asset store or generation before the blob grows further. If that remedy cannot be applied here, state why in the return. With no line, no binary blob is known to be within reach of the ceiling.

---

## 1. Environment Setup

Every path is worktree-scoped: `git -C [WORKTREE_PATH] ...` for Bash, `[WORKTREE_PATH]/...` for file tools, once the working-directory check at the top of this file has passed.

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

---

## 2. Activate Work Item

### 2.1 Claim And Read Context

Determine the tracker: `Issue:`/`Parent: ABC-123` → Linear; `GitHub Issue: OWNER/REPO#N` → GitHub; no reference → ad-hoc (delegation text is the source of truth; skip every tracker write).

Linear only — activate the issue, or the parent alone if bundled (sub-issues activate individually in § 4):

```bash
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh comments list [ISSUE_ID]
```

Every read is live. A failed read or activation stops the round with its exact diagnostic, an auth, API or configuration failure; a rate-limited activation is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds. Never run this Linear preflight for GitHub-tracked or ad-hoc work.

GitHub only:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Ad-hoc: no tracker reads.

**If bundled with siblings marked `(completed)` in the delegation's group list**, read their comments too, all of them in one `linear.sh comments bulk-list [COMPLETED_SIBLING_ID_1] [COMPLETED_SIBLING_ID_2]` call, for handoff notes. Use the list, not tracker state, to select these implemented siblings. A refusal carrying `missing` names siblings Linear has no issue for, because they are deleted or mistyped: stop and report those identifiers.

### 2.2 Research Context

Read the issue description — `.description` from the read above, or `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`. For a sub-issue, read the parent's description too; for a bundle, read the unique paths across its sub-issues.

Cited research, decision, and context files are mandatory reading; how the research applies is yours to decide. Evaluate it against existing patterns and the principle docs; a doc whose claim the change makes false is updated in the change. Reference an already-recorded decision (`.agents/skills/decider/scripts/decisions search --issue [RESEARCH_ISSUE_ID]`, and `decisions search "[KEYWORDS]"` for the area) rather than duplicating it, reading the full record and its status before treating it as binding; record a new one only under the decider bar.

For a missing planning or research path in a brief, find it by the route the project-management skill's SKILL.md § Planning artifacts gives for the work item's tracker before classifying the context as missing.

### 2.3 Evaluate Feasibility

Check your domain's code before planning: do the required APIs and types exist, is another domain's work a prerequisite, is an existing issue blocking? Search prior decisions with `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` and read the full decision file rather than the index summary — never implement an approach a decision explicitly rejects, and report back with the reference if the issue description contradicts one. Optimization work with no `baseline` label takes the label now, before any code change.

Blocked → **§ 3**, then STOP. Clear → § 2.4.

### 2.4 Plan Approach

- Linear only, when scope differs from the estimate: `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --estimate N` (1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+).
- **If bundled**: order sub-issues by dependency and overlap.
- A required command written as `VAR=value cmd args` is normalized here into an ambient-environment precondition plus the bare `cmd args` (orch SKILL.md § Harness-Safe Shell). An unsatisfiable precondition is a blocker to report, never a license to run under the wrong environment.

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
[This work is stopped until the prerequisite provides the needed result, and what that delays.]

BLOCKED: Cross-domain prerequisite needed.

**Required Domain**: [DOMAIN]
**Suggested Labels**: agent:[DOMAIN], [COMPONENT]
**Prerequisite Issue**: [One-line description]

**Why Blocking**:
[What this issue needs, why it cannot proceed, what the prerequisite must provide]

**Suggested Scope**:
- [Deliverable 1]

**Evidence**: [SOURCE_OF_THE_BLOCKER]

**Next**: Requesting orchestrator create prerequisite issue.
```

Your return states the blocker, the domain and labels for the new issue, and that the description is ready for creation. When a blocker later resolves: `linear.sh issues unblock [ISSUE_ID]`.

---

## 4. Implement

**If bundled**: each sub-issue is its own task through § 4-10. Work only the sub-issue named in the current task, activating it first with `linear.sh issues activate [SUB_ISSUE_ID] --agent [AGENT_TYPE]`.

### 4.1 Verify Branch

`git branch --show-current` must report `[BRANCH_NAME]` — the parent's branch when bundled.

Record `git -C [WORKTREE_PATH] rev-parse HEAD` as `[ROUND_BASE]` before implementation. A fix round uses its delegated record's `base_sha` instead.

### 4.2 Implement

Implement per your domain expertise and run quality gates before completion.

Before writing a refusal, a validator, a lock, a retry, or a test, read [dev SKILL.md § Engineering Rules](../SKILL.md#engineering-rules).

When writing a new or changed check, apply [code-quality § Tests](../../code-quality/SKILL.md#tests) at this step.

- **Scope growing?** Report the discovered scope in § 9 for every tracker; never create issues here. Follow [skill-rules.md § Coordination](../../orch/references/skill-rules.md#coordination) for issue creation.
- **Work outside scope?** Note it under Discovered Work in § 9.
- **Need deeper research?** Add the `needs-research` label, pause, report.

For every callee whose call the change deletes, run `git grep -n -F --untracked --exclude-standard -e <callee> --`, then apply [code-quality § Cleanup](../../code-quality/SKILL.md#cleanup).

### 4.3 Update Documentation And Decisions

Update a doc when the implementation makes a claim in it false. A code change alone owes no doc change.

**Skip decision recording if** the choice is below the decider bar, the decider skill's `SKILL.md` § What warrants a decision record, and why: that reason is a comment at the code. Otherwise follow the decider skill's create-decision workflow: `.agents/skills/decider/scripts/decisions next-id`, the file per `schemas/decision-format.md` from `templates/decision-entry.md`, the INDEX.md row per `templates/index-row.md`, `// REVISIT(DXXX):` markers in code where applicable, and the decision ID cited in the § 9 summary.

### 4.4 Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect). Complete every repository edit from reflection before validation.

---

## 5. Validate

Stage the final edits before running these checks, using the index policy in [§ 7. Commit](#7-commit).

```bash
git -C [WORKTREE_PATH] add -A
```

The validation gate is this complete list:

- The affected suite passes. It consists of installed preflight and doc-limits gates, the delegation's required verification commands in their § 2.4 normalized form, and Visual QA under the current workflow's rule below.
- Run the must-fail controls [code-quality § Tests](../../code-quality/SKILL.md#tests) requires, each scoped as [§ Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards) sets. A workflow sentence has no test and adds no control. A changed test file takes no run of its own: the runner's result covers it, locally or through required CI.
- `DEV_VALIDATE_CMD` passes once against the round's final worktree contents, run through `.agents/skills/orch/scripts/dev-validate-run` as [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation) sets out. The runner hands the command the diff's change class as `DEV_VALIDATE_CLASS`, with the docs verdict and changed paths beside it (`dev-validate-run --help`). A full battery the class does not need is a failure of the project's `DEV_VALIDATE_CMD` configuration, which reads the class to stand lanes down; the round's verdict is still the run's `validate=` value, and the agent never picks a class or a narrower command by hand. An empty value is a validation failure named `DEV_VALIDATE_CMD`, which that runner refuses before starting anything, with the note `DEV_VALIDATE_CMD is empty; set it in kendex.settings.toml [env] to the project's full test, lint and typecheck command`. Run nothing in its place.
- A project whose own policy forbids `dev-validate-run` and requires its validation entry point in the foreground runs that entry point here, in the foreground as the policy sets out, in place of `dev-validate-run`, and records the run in `[WORKTREE_PATH]/tmp/validate-record-[ARTIFACT_KEY]-[DEV_ROUND_ID]`. An admitted recovery below uses `[WORKTREE_PATH]/tmp/validate-record-[ARTIFACT_KEY]-[DEV_ROUND_ID]-recovery` instead and preserves the original record. Before the entry point starts, write the lines `validate-mode=full`, `head=` with `git -C [WORKTREE_PATH] rev-parse HEAD`, and `started-at=` with `date -u +%Y-%m-%dT%H:%M:%SZ`. After it ends, add `ended-at=` the same way, `exit=` with its exit status, and `selection=` and `lanes=` from its `validate:` line, or `selection=unreported` where it printed none. A run cut off before its exit status is known is `FAILING: [ENTRY_POINT]`. Preserve its unfinished record and log, omit both evidence flags, and explain the interruption in `--validate-note`. `dev-return-write --help` gives each line's grammar.
- A run ended by the bound or an unavailable host check prints `validate=no-verdict`: neither a pass nor a failure. So does a start that an earlier run's bound already answered, which runs nothing (`dev-validate-run --help`). Read the run's record with `.agents/skills/orch/scripts/dev-validate-run --record --run-dir [RUN_DIR]`. A record carrying `validate-mode=ci` takes no further run: required CI, the merge group for queue-only work, holds the full proof. A scoped record whose `validate-mode` is not `ci` takes no further start. A record that is not scoped and whose `validate-mode` is not `ci` takes at most one further runner start, `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH] --validate-mode ci --base [ROUND_BASE]`, and the round's verdict is that run's. Run no suite list by hand in place of either. A final `no-verdict` is `--validate no-verdict` with its run's `run-dir=` as `--validate-run-dir` and a `--validate-note` naming the host cause or timeout, and the return reads `Validate: no-verdict: [CAUSE]`. Only a final record with `validate-mode=ci` leaves the proof to required CI. Any other final `no-verdict` is unproved: its `--validate-note` says so, and the round never presents it as covered by CI.
- `fleet-mac-run test` passes once for an item the Apple gate in `dev-return-write --help` names, run through the orch job runner as [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation) sets out. The gate names an item when the base branch holds its workflow and an entry of the delegation's `Labels:` line, or a path the branch changes, matches its trigger. Fleet installs `fleet-mac-run` on the `PATH` of a lane in a repository it runs Apple builds for. A nonzero exit, or no `fleet-mac-run` on `PATH`, is `FAILING: mac run test`. A pass is the `--validate-note` line `mac run test: pass run=[RUN_ID]`, with the run id `fleet-mac-run` prints. An item the gate does not name runs nothing here.
- A `ci` run accepts completed local edits and records CI as pending. Where the project sets `DEV_VALIDATE_SELECTION_CMD`, it first runs that selector's changed-file suites once, scoped, at the round's final contents, and a red scoped run is a failing `validate=` value like any other. It starts no local full command and waits on no unpublished head. This does not satisfy a CI gate; submit's existing § 5 wait proves the required checks on the exact published head.
- After the dev agent returns its local result, the orchestrator gets green CI and a passing review gate. The dev agent does not claim or reproduce these downstream results.

A start `dev-validate-run` refuses as `run-live`, with exit 2 and the line `dev-validate-run: run-live run-dir=[RUN_DIR] pid=[PID]`, ran nothing: another run in the worktree still holds the host. It is no verdict on the change, never a validation failure, and does not end the round. Wait for that run with `.agents/skills/orch/scripts/dev-validate-run --wait --run-dir [RUN_DIR]`, polled as a cut-off start is, or end it with `.agents/skills/orch/scripts/dev-validate-run --stop --worktree [WORKTREE_PATH]` where it belongs to an abandoned round, then start the run again. The verdict of a run that refusal named is this round's only where this round started that run.

For a test-only PR whose validation runs longer than 30 minutes and fails, run the failed target alone once under load, as an investigation run under [dev SKILL.md § Validation](../SKILL.md#validation). Record both results in `--validate-note` with the prefix `Test-only validation ceiling:`. Report the result and do not extend validation.

A `validate=FAILING`, a failing required verification command, or another failing run in this gate permits one recovery sequence when every failing check has a named cause fixed within the delegated scope. Stage the repaired final contents. Run the focused failed checks once to prove the repair. If that proof fails or remains unread, stop. Read the existing native project preview for those contents with the original base and validation mode, and compare its usable time estimate with the unchanged configured bound. An absent, unread or over-bound estimate stops. `--resolve-mode` and `selection=subset` alone prove no duration. Add no estimate provider, selector override, smaller base or replacement command.

When all those conditions hold and this round has not spent its correction/rerun allowance, run the unchanged configured validation once through its existing execution owner, preserving the real base, mode and bound. A failed required verification command's focused rerun above must pass first. Record the causes, scoped repair, focused execution, native preview, estimate and bound, both evidence locations and final verdict in the round notes, summary and `--validate-note`. Existing fix-round calls into this section keep their delegated fix base and mode. This sequence grants no additional allowance after an earlier correction/rerun, validation refresh or recovery attempt.

An unknown or outside-scope cause, unproved repair/admission, refused start, another failed gate, timeout, lost run or unproved result stops this sequence. Keep the existing `run-live` wait ownership. Do not chain recovery into another start through the no-verdict route. The no-verdict and recorded context-handoff routes above still govern their original results; they grant no new allowance after recovery. Preserve the result and complete the tail.

A stopped round whose failed receipt already exists uses the same qualification above and the original delegation, round id and baseline. For every caller using the foreground route, commit any tracked repair after focused proof and admission, before the configured recovery entry point records HEAD. Use the active workflow's commit instructions and metadata. Reuse that commit through completion and skip that workflow's later commit step. The native route keeps its staged-tree binding. After the admitted attempt, complete the active workflow's tail with `dev-return-write --recovery` and the actual round commit and validation result. Keep the original failed receipt and run records. Evidence-only recovery can name the same round commit; create no empty commit. The fixed companion is terminal even when failing or unproved. Its immutable slot preserves evidence; this workflow controls the execution allowance.

For this validation gate, run no proof, rerun, receipt, isolation step, or approval step outside this list. Investigation runs follow [dev SKILL.md § Validation](../SKILL.md#validation). If an agent believes the list misses a rule, it records the proposal once under `### Proposed Rules` in the completion summary and in the matching return line. The orchestrator puts it once in the PR body. Neither role performs the proposed rule.

Run preflight when installed (`test -x .agents/skills/preflight/scripts/preflight`) through the orch job runner per [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation):

```bash
.agents/skills/preflight/scripts/preflight --repo [WORKTREE_PATH]
```

Use the same orch job runner route for doc-limits when installed (`test -x .agents/skills/doc-limits/scripts/doc-limits`):

```bash
.agents/skills/doc-limits/scripts/doc-limits
```

Run the delegation's required verification commands through their route in [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation). Then run `DEV_VALIDATE_CMD` through `dev-validate-run`, or the project's entry point by the foreground route above. Record the full validation result in the completion artifact for submit to reuse on the same contents.

A script written only to produce a number for the issue is not committed; report its result in the return for the orchestrator to put in the PR body. An uncommitted measurement is not a check the change adds or modifies.

**Visual QA** — **skip if** the issue has no `design` label. Otherwise use the project's visual QA skills to confirm what your change affects renders correctly, not the full checklist. Do NOT capture golden baselines.

---

## 6. Reflect

Reflection is complete in § 4.4. Make no repository edit here.

---

## 7. Commit

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
git -C [WORKTREE_PATH] log -1 --oneline
```

Use the CURRENT sub-issue ID when bundled, not the parent's. Never stage lock files the project gitignores — stage specific files by name. When validation failures remain, add `[validate: FAILING_CHECK]` to the body as a second `-m`, never to the header.

---

## 8. Record QA Signals

Based on the FINAL validated code, decide which extra QA passes the change needs. Record them in the completion artifact (§ 10 `--qa-label`, one per signal), not a tracker mutation.

| Trigger | Signal |
|---------|--------|
| Unsafe code, atomics, lock-free | `needs-safety-audit` |
| Hot path, latency-sensitive, or shared/main-build perf risk | `needs-perf-test` |
| New module, public API | `needs-review` |
| Changed view, layout, styling or UI copy | `needs-ui-review` |

A round that raises `needs-ui-review`, or changes a file a `QA_UI_PATHS` glob matches (`.agents/skills/orch/scripts/orch-env QA_UI_PATHS ""`), builds each changed view to the polish bar in [code-quality references/ui.md](../../code-quality/references/ui.md) and the design-system doc `QA_UI_DESIGN_DOC` names (`.agents/skills/orch/scripts/orch-env QA_UI_DESIGN_DOC ""`), and captures its screenshot set by [code-quality references/ui.md § Screenshots](../../code-quality/references/ui.md#screenshots), listed in § 9.1's Screenshots section. The `needs-ui-review` QA pass judges each view from that set.

Work isolated behind a development-only feature gate does not take `needs-perf-test`: run the feature-gated checks locally and signal only if shared or feature-off paths are affected.

A signal is never silently dropped: every triggered row appears in the artifact and in the return's `QA:` line, and `none` is an explicit answer, not a default.

---

## 9. Post Completion Summary

### 9.1 Completion Comment

Always required. Linear posts it to the issue you implemented: write `tmp/completion-summary-[ISSUE_ID].md`, then `linear.sh comments create [ISSUE_ID] --body-file tmp/completion-summary-[ISSUE_ID].md`, with one `--attach` per screenshot § 8 captured. GitHub and ad-hoc rounds return the same content to the orchestrator instead and ALSO carry it in the artifact via `--summary-file` (§ 10).

**Validation routes.** Before writing a completion, fix, session or merge summary, read each actual run's native `start` and `dev-validate-run --record --run-dir [RUN_DIR]` evidence while available. Use `--record` for its reported fields and `start` for that run's actual `timeout-secs` bound. Include one row per run, with its original round id and kind, run directory, recorded head/start identity, and source references. Keep implementation, fix and restack runs separate; a restack has no dev round id. Preserve earlier attempts and recovery or reused-run references rather than replacing their outcomes with the final verdict.

Print every field in the Validation routes template below. Each missing, legacy or unread field is `unknown`, including absent `scoped` or `ci-fallback`; retain reported values such as `selection=unreported` and `verdict=unfinished`. An unread source keeps its reference and diagnostic. Preserve `FAILING` and required CI's `pending` separately from local `pass`. Keep native bound-hit and host-caused `no-verdict` classifications in `outcome`, with the native ending or sentinel and any bound-run source reference; never infer fallback, scope or a bound hit from prose or elapsed seconds. `dev-validate-run --help` owns those classifications. A refused start is recorded as such and creates no validation run or verdict.

A validation-routing check reads these durable comments on the originating item. When it needs raw evidence, use the retained archive within its retention window or the operator's dated snapshot; an unavailable source stays unread.

```markdown
[What the implemented change does and whether acceptance is complete, failed or still pending.]

## Completion Summary

**Agent**: [AGENT_NAME]

**Branch**: `[BRANCH]`

**Revision**: [COMMIT_AND_SOURCE]

### Evidence

- Box [N]: [PROVED_RESULT_AND_ARTIFACT_LINK_AT_REVISION_WITH_CONDITIONS; PENDING_CI_OR_LIVE_ACCEPTANCE_STAYS_EXPLICIT]

### Validation routes

- round=[ORIGINAL_ROUND_ID_OR_UNKNOWN] kind=[implement|fix|restack] run-dir=[RUN_DIR_OR_UNKNOWN] head=[RECORDED_HEAD_OR_UNKNOWN] start=[RECORDED_START_OR_UNKNOWN] source=[NATIVE_START_AND_RECORD_REFERENCES] validate-mode=[VALUE_OR_UNKNOWN] selection=[VALUE_OR_UNKNOWN] ci-fallback=[VALUE_OR_UNKNOWN] scoped=[VALUE_OR_UNKNOWN] seconds=[VALUE_OR_UNKNOWN] timeout-secs=[ACTUAL_BOUND_OR_UNKNOWN] verdict=[VALUE_OR_UNKNOWN] outcome=[NATIVE_CLASSIFICATION_OR_UNKNOWN]

### Key Decisions

1. Decision and reasoning (link DXXX if recorded)

### Files Created/Modified

- `path/to/file` - Meaningful change, including skills, documentation and rules

### Domain Metrics

[Actual reading beside its target, scope, observation time and source.]

### Screenshots

- `tmp/ui-shots/[FILE]` - [View], [before|after], [THEME]

### Discovered Work

- [Type]: Description (estimate: N)

### Handoff Notes

[What the next agent in this bundle needs for its current-scope work: struct changes, API contracts, file locations]

### Proposed Rules

- [Rule the validation list is missing]
```

Omit any section that has nothing in it. Link each proof once in Evidence and bind checked boxes to that comment rather than copying the proof. Keep pending proof explicit. Discovered Work is backlog work beyond this scope; Handoff Notes are for the next agent only, with no aspirational suggestions.

**Discovered Work marker prefixes.** A bullet belonging to a later stage of THIS PR rather than to the backlog carries a marker as the first token of the bullet text, before `[Type]`. Unmarked bullets go through the TPM audit as backlog work.

- `handoff_to_submit_pr:` — content the upcoming submit-pr step produces, e.g. PR-body material.
- `handoff_to_merge_pr:` — something the eventual merge-pr step handles.
- `current_workflow_action:` — something the current review-pr cycle should handle itself.

### 9.2 Downstream Handoff

**Skip if** the tracker is not Linear, this issue blocks nothing, or completion alone unblocks the downstream work.

Read `.blocks` from `linear.sh issues get [ISSUE_ID]` and read the downstream comments for an existing `Handoff from [ISSUE_ID]:`. Reuse that handoff unless the dependency changed again. Post to a downstream issue **only if** this work changed an API, interface, file, or contract it depends on: write `tmp/downstream-handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md` beginning `Handoff from [ISSUE_ID]:`, naming the changed API, interface, file or decision, its source and the downstream action, then post it with `linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file [THAT_FILE]`. Never post it to the completed issue.

---

## 10. Finalize

With every applicable section above complete, write the artifact per [dev SKILL.md § Round Contract](../SKILL.md#round-contract):

`[BASE_BRANCH]` is what § 1's `resolve-base-branch` reported; `--near-ceiling-base` takes it as `origin/[BASE_BRANCH]` because § 1 fetched that remote ref and left the local branch where it was.

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|no-verdict|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR] | --validate-record [FILE]] [--validate-note [TEXT]] [--label [LABEL]]... [--no-labels] [--qa-label [LABEL]]... --near-ceiling-base origin/[BASE_BRANCH]
```

`[RUN_DIR]` is the `run-dir=` value `dev-validate-run` printed, and a `pass` needs that run to have passed, a `no-verdict` a run that recorded that result; omit the flag when validation failed before any run started or when § 5's interrupted foreground route has no completed record. A project whose own policy forbids `dev-validate-run` and runs its validation entry point in the foreground passes `--validate-record [FILE]` in place of `--validate-run-dir`, `[FILE]` being the original or recovery record § 5's foreground route wrote for this attempt.

One `--qa-label` per § 8 signal, none if nothing triggered. One `--label` per entry of the delegation's `Labels:` line, or `--no-labels` when it reads `none`.

Every single round appends `--summary-file tmp/completion-summary-[ISSUE_ID].md`; GitHub and ad-hoc rounds also append `--no-summary`. Bundled rounds add `--bundled` and one `--item` per sub-issue — § 11.

**Issue state.** A bundled Linear sub-issue stays In Progress through the dev round; make no tracker state write here. Read its current description, tick each branch-provable Done-when box verified by this round, and add a nonblank indented `Evidence:` line directly below each ticked box. Cite the proving artifact at its revision and conditions. Save the updated description under `tmp/` and run `linear.sh issues update [SUB_ISSUE_ID] --description-file [DESCRIPTION_FILE]` with no state flag. Leave unproved boxes open. Its proof also stays in its completion summary and the bundle artifact's `--item` result (§ 11). Orch's merge-pr workflow § 5 alone owns the completion-time box selections, writes its evidence file and completes the child at merge. The worktree's top-level managed issue stays In Progress or In Review until the PR merges. GitHub and ad-hoc issues close through the PR body or merge, never here.

Carry a child with proved branch work and open post-merge checks into the parent summary in its current started state. The parent follows orch's submit-pr and merge-pr child handoff. Post-merge completion supplies the shared PR's merge time before moving the child to Verifying.

**If single**, return now:

<output_format>
Branch: [BRANCH_NAME]
Commit: [SHA]
QA: [signals or "none"]
Validate: [pass, "no-verdict: [CAUSE]", or "FAILING: check1, check2"]
Proposed rule: [proposal or "none"]
Summary: [ISSUE_ID] ✓
</output_format>

**If bundled**, mark the task completed and take the next sub-issue as a separate task, or go to § 11 when none remain.

---

## 11. Return (Bundled)

**Skip if** single — you returned at § 10.

1. **Aggregate QA signals across sub-issues** (including nested ones) into the bundle artifact's `--qa-label` flags — the union of every sub-issue's § 8 signals. No tracker mutation. The near-ceiling lines need no union: the writer's probe measures the whole branch, every sub-issue's commits included.

2. **Post the parent summary** (Linear only): write `tmp/bundle-summary-[PARENT_ID].md`, then `linear.sh comments create [PARENT_ID] --body-file tmp/bundle-summary-[PARENT_ID].md`, with one `--attach` per screenshot. Its Screenshots section is the union of the sub-issues' lists. Link child summaries for detailed files, decisions and metrics; file and commit counts do not replace acceptance proof.

   ```markdown
   [The combined effect and each child’s acceptance state, including pending proof.]

   ## Bundle Complete

   **Agent**: [NAME] | **Branch**: [BRANCH]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1] ✓ | blocks: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_2] ✓ | blocked by: [SUB_ISSUE_1]
      ↳ [SUB_ISSUE_3] ✓  ← nested
   Files: N | Commits: N | QA: [LABELS]

   ### Evidence

   - [CHILD_SUMMARY_LINK]: [RESULT_AND_REMAINING_PROOF]

   ### Validation routes

   [Each child’s original fixed-field rows, retaining run identities and outcomes.]

   ### Screenshots
   - `tmp/ui-shots/[FILE]` - [SUB_ISSUE], [View], [before|after], [THEME]

   ### Proposed Rules
   - [Rule the validation list is missing]
   ```

3. **Write the artifact**, keyed to the Parent ID, with that group's `Round ID:` when the bundle was delegated in groups:

   ```bash
   .agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [LAST_SUBISSUE_HEAD_SHA] --validate [pass|no-verdict|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR] | --validate-record [FILE]] [--validate-note [TEXT]] --summary-file tmp/bundle-summary-[PARENT_ID].md --bundled --item [N] [DECISION] [REASONING] [--item ...] [--label [LABEL]]... [--no-labels] [--qa-label [LABEL]]... --near-ceiling-base origin/[BASE_BRANCH]
   ```

   `--bundled` requires one `--item` per sub-issue result — `DECISION` is Applied, Skipped, or Blocked and `REASONING` non-empty plain text with no backticks — populated from the sub-issue tree. `--commit` is the last sub-issue's HEAD.

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
