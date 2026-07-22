# Issue Lifecycle

**The workflow for all dev/QA agents receiving work-item delegations.**

Skip issue tracker updates for ad-hoc requests (no issue reference).

## Delegation Types

| Type | Detection | Flow |
|------|-----------|------|
| Single | `Issue: [ISSUE_ID]`, `GitHub Issue: OWNER/REPO#N`, or ad-hoc task | § 1 → § 2 → § 4 → § 5 → § 6 → § 7 → § 8 → § 9 → § 10 → return |
| Bundled | `Parent: [ISSUE_ID]` + `Sub-Issues (tree): [...]` | § 1 → § 2 → [§ 4-10]×N → § 11 → return |

**If bundled**: Execute § 4-10 per **pending** sub-issue (one task each), then § 11 aggregates and returns.

**Nested sub-issues**: Sub-issues may have children (3-level hierarchy: parent → sub → nested). Blocking relations shown when present:
```
↳ [SUB_ISSUE_1]: [TITLE] | blocks: [SUB_ISSUE_2]
↳ [SUB_ISSUE_2]: [TITLE] | blocked by: [SUB_ISSUE_1]
   ↳ [SUB_ISSUE_3]: [TITLE]  ← child of [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_4]: [TITLE]  ← child of [SUB_ISSUE_2]
```
Respect blocking order: complete blockers before blocked issues.

**Completed sub-issues**: Marked `(completed)` in delegation — context only, skip in § 4 loop.

---

## 1. Environment Setup

- Bash: `git -C [WORKTREE_PATH] ...`
- Read/Write/Edit/Grep/Glob: `[WORKTREE_PATH]/...`
- Keep shell commands harness-safe: use one simple command per call with explicit arguments. Avoid inline shell loops, command substitution, heredocs, pipelines used only to pass values, and redirected writes to `tmp/`; Codex may treat those helper shapes as approval-required under `never` approval. For required multi-file reads, read each file directly. For generated Markdown/JSON files, use the harness file-write/edit tool or `apply_patch` instead of shell redirection.

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

---

## 2. Activate Work Item

### 2.1 Claim & Get Context

Determine tracker:
- `Issue: ABC-123` or `Parent: ABC-123` → `TRACKER=linear`
- `GitHub Issue: OWNER/REPO#N` → `TRACKER=github`
- no tracker reference → `TRACKER=none`

Linear only:

```bash
# Establish the worktree-local cache before any mandatory cache read. This is
# a full sync in a fresh worktree and an incremental reconcile otherwise.
.agents/skills/linear/scripts/linear.sh sync --reconcile
# Activate issue (or parent if bundled), replace [AGENT_TYPE] with your agent type
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

The `sync --reconcile` command must succeed before activation or cache reads.
A missing cache before that command is expected in a fresh worktree. If sync
fails, stop and preserve its exact diagnostic: that is a sync/auth/API/config
failure, not a missing-cache result. If a mandatory cache read reports `No
cache found` after sync succeeded, stop and report a cache-initialization
defect. Never run this Linear preflight for GitHub-tracked or ad-hoc work.

GitHub only:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Ad-hoc: use delegation text as source of truth, skip tracker writes.

**If bundled**: Activate parent only. Sub-issues activated individually during § 4 loop.

**If bundled with completed siblings**: Also read completed sibling comments for handoff notes:
```bash
.agents/skills/linear/scripts/linear.sh cache comments list [COMPLETED_SIBLING_ID]
```

### 2.2 Check for Research Context

```bash
# Linear
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
# Read `.description` from the JSON output.

# GitHub
gh issue view [N] --repo [OWNER/REPO] --json body --jq .body
```

**If bundled**: Also check each sub-issue for research refs. Aggregate unique paths.

**If sub-issue**: Also check the parent issue's description. Sub-issues inherit parent research context.

**If research/decision/context references found**: Read the cited files — mandatory context, not optional. Follow § 2.2.1, then continue.

#### 2.2.1 Research-Informed Implementation

You have domain context the orchestrator lacks. You decide how research applies.

1. **Read and evaluate**: Read project research documents. Consider how they apply to existing patterns and architecture docs.

2. **Check for existing decision** (decider skill): `.agents/skills/decider/scripts/decisions search --issue [RESEARCH_ISSUE_ID]`. If a prior research-complete already recorded a decision, reference it — don't duplicate. Only create new decisions for additional decisions revealed by your evaluation.

3. **Update architecture docs** if research changes documented patterns.

4. **Update `vstack.toml`** if research reveals project-specific context that should persist (under `[agent-launch-instructions]`, `[agent-additional-instructions]`, or `[skill-instructions]`).

### 2.3 Evaluate Feasibility

Before planning, check your domain's code (per your agent's Domain Setup):

- **Prior decisions?** `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` — read the full decision file, not just the index summary. Report back to orchestrator with decision reference if the description contradicts a decision — do not implement approaches a decision explicitly rejects.
- **Can you proceed?** Do required APIs/types exist?
- **Cross-domain dependency?** Need work in another domain first?
- **Blocked by existing issue?**
- **Optimization work without `baseline` label?** Add label now (before any code changes).

**If blocked** → **Jump to § 3**, then STOP.

**If clear** → continue to § 2.4.

### 2.4 Plan Approach

- Linear only: update estimate if scope differs: `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --estimate N`
  - Estimates: 1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+
- **If bundled**: Plan sub-issue order based on dependencies/overlap.
- **Normalize env-prefixed required commands** (vstack#714). If the issue spec or delegation carries a required command shaped `VAR=value cmd args` (e.g. `LC_ALL=C tools/test-ci-changes`), accept it as the bare `cmd args` plus an environment precondition — never the prefixed shape, which Codex `approval=never` rejects. Before running it (§ 5), confirm the ambient environment satisfies the precondition with one simple command (`printenv VAR`; `locale` for locale variables), then run the bare command unchanged. `env VAR=value cmd args` is not an acceptable substitute. If the ambient environment cannot satisfy the precondition, report it as a blocker in your return instead of running under the wrong environment. Canonical rule: orch SKILL.md § Harness-Safe Shell.

### 2.5 Domain-Specific Setup

Follow your agent definition for architecture docs, code paths, skills to load.

If multiple architecture or policy documents are required, read them as separate file reads or separate simple commands. Do not use shell `for` loops to satisfy mandatory context reads.

### 2.6 Capture Baseline (if `baseline` label)

**Check labels** from § 2.1. If `baseline` label present:

1. Identify the affected component (backend, frontend, etc.)
2. **If a benchmarking skill is installed**, follow its baseline workflow to capture pre-implementation baselines.

The performance QA agent uses the baseline file during QA review.

---

## 3. Block Issue (if dependency discovered)

**Skip if** not blocked — § 2.3 routed to § 2.4.

### 3.1 Blocked by Existing Issue

Linear only:

```bash
.agents/skills/linear/scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "Cannot proceed until [REASON]"
```

GitHub/ad-hoc: report the blocker in the return message; do not invent tracker state.

### 3.2 Cross-Domain Dependency Discovery

When work in another domain must happen first (prerequisite issue doesn't exist):

1. **Add blocked label** (Linear only):
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --labels "agent:[AGENT_TYPE],[COMPONENT],blocked"
   ```

2. **Post structured comment** (Linear only). Create `tmp/blocked-[ISSUE_ID].md` with:

   ```markdown
   BLOCKED: Cross-domain prerequisite needed.

   **Required Domain**: [DOMAIN]
   **Suggested Labels**: agent:[DOMAIN], [COMPONENT]
   **Prerequisite Issue**: [One-line description]

   **Why Blocking**:
   [What this issue needs, why it can't proceed, what prerequisite must provide]

   **Suggested Scope**:
   - [Deliverable 1]
   - [Deliverable 2]

   Requesting orchestrator create prerequisite issue.
   ```

   Then post it:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file tmp/blocked-[ISSUE_ID].md
   ```

3. **Report to orchestrator**: Final message must state the blocker, domain and labels for the new issue, and that the issue description is ready for creation.

**Orchestrator**: Creates prerequisite, sets blocking relation, delegates.

### 3.3 Unblocked

When blocker resolves:
```bash
.agents/skills/linear/scripts/linear.sh issues unblock [ISSUE_ID]
```

GitHub/ad-hoc: skip.

---

## 4. Implement Solution

**If bundled**: Each sub-issue is a separate task (§ 4-10). Work only the sub-issue named in your current task.

### 4.1 Verify Branch

`git branch --show-current` — should be `[BRANCH_NAME]` (auto-links PR to issue tracker).

**If bundled**: Branch is parent's.

### 4.2 Implement

**If bundled**: Before implementing this sub-issue:
```bash
.agents/skills/linear/scripts/linear.sh issues activate [SUB_ISSUE_ID] --agent [AGENT_TYPE]
```

Implement per your agent's domain expertise. Run quality gates before completion.

**Scope growing?** Linear: create sub-issues with `linear.sh issues create --parent [PARENT_ID]`. GitHub/ad-hoc: report discovered scope in § 9; do not create issues without orchestrator approval.

**Found work outside scope?** Note in completion summary under "Discovered Work".

**Need deeper research?** Add "needs-research" label. Pause. Report to orchestrator.

### 4.3 Update Documentation

Update relevant docs if implementation changes documented APIs or architecture.

**If significant path choices made**, follow the decider skill's create-decision workflow:

1. Get next ID: `.agents/skills/decider/scripts/decisions next-id`
2. Select template from `templates/decision-entry.md` (minimal/standard/comprehensive)
3. Create decision file per `schemas/decision-format.md`
4. Add row to INDEX.md per `templates/index-row.md`
5. Use `// REVISIT(DXXX):` in code where applicable
6. Include decision ID in § 9 completion comment

**Skip decision recording if** no alternatives were considered or trade-offs made.

**If bundled**: Complete § 5-10 for this sub-issue before marking task done.

---

## 5. Validate

```bash
# Run the project's build/test/lint validation command
```

Run required verification commands in their normalized form from § 2.4 — ambient precondition check first, then the bare command; never an env-assignment prefix, and never an `env`-wrapped substitute.

Validation or audit searches over backtick-bearing text (Markdown inline code) never carry a literal backtick in the command — write the pattern with the regex hex escape `\x60` in single quotes as one simple command (vstack#721; canonical rule: reviewer SKILL.md § Harness-Safe Shell).

**Long-running validation (harness-timeout safety, vstack#770).** A `tools/validate`-class command or full hermetic suite that can exceed the harness tool timeout (~10 min; 15-30 min runs are at risk) must NOT be run as a plain foreground command the turn blocks on — a tool timeout ends the turn mid-checklist, so the completion tail (commit → QA labels → summary → artifact → return in § 7-10) is lost and the orchestrator sees only absence and burns its stall ladder. Run it so the turn survives: prefer the harness background/polling mechanism (start in background, poll status/exit code), or set an explicit generous tool timeout for that one command. If such a command IS interrupted by a tool timeout, do NOT end the turn — re-check its actual outcome (still running? exit code? log tail?) and resume the checklist in the SAME turn. Never treat a tool-timeout error on a long command as completion or as license to go idle.

**On failure:**
- **First run**: Use `--fail-fast` to stop early, fix, then `--recheck`
- **Simple + related to your work** → fix it, `--recheck`
- **Complex or unrelated** → still commit your work, note failure in commit message, report in return
- **Stuck** (same failure 3+ times) → stop looping, commit, report details

Always report unresolved validation failures to orchestrator.

---

### 5.1 Visual QA

**Skip if** the issue does not have the `design` label.

Use visual QA skills to validate that UI changes render correctly. Focus on what your changes affect — not the full checklist. Do NOT capture golden baselines — that happens at submit-pr time.

---

## 6. Reflect & Update Documentation

**Skip if** implementation was straightforward with no repeated issues and no notable discoveries.

**Trigger**: Any of these during § 4-5:
- Fixed same problem 2+ times (lint, pattern, API usage, test approach)
- Discovered non-obvious gotcha worth remembering
- Spent multiple cycles on something a rule could prevent
- Discovered optimal approaches that differ from documented patterns

**Action**: Update the relevant documentation:

- **Architecture docs** → Update if patterns, APIs, or documented behavior changed.
- **Project config** → Add to `./vstack.toml` (`[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`). Run `vstack refresh` to apply.

Criteria: Would this save 5+ minutes in a future session? If yes, update. One surgical addition per lesson. No verbose examples.

**If you can't update directly** (wrong domain, needs discussion): note in § 9 Discovered Work with type `[process]`.

---

## 7. Commit Changes

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
```

**If bundled**: Use CURRENT sub-issue ID, not parent ID.

**Worktree caveat**: Never stage lock files listed in the project-specific gitignore. Stage specific files by name.

**If unresolved validation failures**: Append `[validate: FAILING_CHECK]` to commit message.

**Verify commit exists** before proceeding:
```bash
git -C [WORKTREE_PATH] log -1 --oneline
```

---

## 8. Apply QA Labels

Based on FINAL validated code:

| Trigger | Label |
|---------|-------|
| Unsafe code, atomics, lock-free | `needs-safety-audit` |
| Hot path, latency-sensitive, or shared/main-build perf risk | `needs-perf-test` |
| New module, public API | `needs-review` |

Full triggers: see the project label application guide.
Development-only feature exception: do not apply `needs-perf-test` for work isolated behind a development-only feature gate. Run the feature-gated checks locally and only add the label if shared or feature-off paths are affected.

Every label selected by this table is required policy, not an optional
repository capability. When this workflow is responsible for applying a label
to an existing GitHub PR or issue, use the GitHub helper's required mode so it
checks the live label inventory and uses GitHub's authoritative label endpoint
to verify the selected token's effective write capability:

```bash
.agents/skills/github/scripts/github.sh -C [WORKTREE_PATH] label-add [PR_OR_ISSUE] [QA_LABEL] --required
```

Add `--issue` when the target is a GitHub issue. If preflight reports
`configuration_error` (required label missing) or `capability_error`
(insufficient permission), stop and report that supported outcome; do not
silently omit the QA gate, substitute `--optional`, or return `QA Labels: none`.
`--optional` is reserved for a label that project policy explicitly declares
non-gating.

---

## 9. Post Completion Summary

### 9.1 Completion Comment

**Always required** — documents the FINAL state after all validation passes.

**Target issue**: Linear posts to the issue you just implemented. GitHub/ad-hoc returns the same content to the orchestrator instead of posting a tracker comment — and because a lost return would lose that content, GitHub/ad-hoc rounds ALSO carry the summary in the completion artifact via `--summary-file` (§ 10), keeping `summary_posted` honest (`false`, since nothing was posted to a tracker).

Create `tmp/completion-summary-[ISSUE_ID].md` with:

```markdown
## Completion Summary

**Agent**: [AGENT_NAME]
**Branch**: `[BRANCH]`

### Files Created/Modified
- `path/to/file` - Description

### Key Decisions
1. Decision and rationale
2. DXXX recorded (if research-informed)

### Skills/Docs/Rules Updated
- `skill-name`: Updated X
(Skip if none)

### Domain Metrics
[Your agent-specific metrics: frame time, latency, etc.]
(Skip if not applicable)

### Discovered Work
- [Type]: Description (estimate: N)
Future work beyond current scope. NOT for the next agent — for backlog/orchestrator.
(Skip if none)

**Marker prefixes** — for bullets that belong to a later lifecycle stage of the current PR, not to the backlog. The orchestrator's `review-pr.md` § 9 audit drops these so they are not converted into new tracked issues. The marker MUST be the first token of the bullet text (before `[Type]`):

- `- handoff_to_submit_pr: [doc] Update CI wall-time table (estimate: 1)` — item the upcoming `submit-pr` step will produce (e.g., PR-body content). Belongs in the PR body, not in the issue tracker.
- `- handoff_to_merge_pr: [process] Verify cross-PR coordination at merge (estimate: 1)` — item the eventual `merge-pr` step will handle.
- `- current_workflow_action: [doc] Recompute coverage table for this review (estimate: 1)` — item the current `review-pr` cycle should handle itself.

Bullets without a marker prefix are treated as genuine new backlog work and routed through the TPM audit. Do not put the marker after `[Type]:` — the audit filter only matches the marker when it is the leading token.

### Handoff Notes
Context the next agent in this bundle needs to complete its current-scope work (e.g., struct changes, API contracts, file locations). Do NOT put aspirational suggestions or future work here — those belong in Discovered Work.
(Skip if none)
```

Then post it:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file tmp/completion-summary-[ISSUE_ID].md
```

### 9.2 Downstream Handoff (selective)

**Skip if** tracker is not Linear, this issue does not block other issues, or unblocking by completion alone is sufficient.

Check blocking relations:
```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
```
Read `.blocks` from the JSON output.

Post a handoff comment to each downstream issue **only if** this work changed an API, interface, file, or contract the downstream issue depends on. Create `tmp/downstream-handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md` with:

```markdown
Handoff from [ISSUE_ID]:
- [RELEVANT_CONTEXT: what changed, what downstream needs to know]
```

Then post it:

```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file tmp/downstream-handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md
```

Do NOT post handoff to the completed issue — that conflates audiences. Handoff Notes (§ 9.1) are for the next agent in this bundle. Downstream handoff is for agents working on issues this one unblocks.

---

## 10. Finalize Issue

**Verify complete:**

| Step | When | Ref |
|------|------|-----|
| Baseline captured | `baseline` label | § 2.6 |
| Research applied | Research in description | § 2.2.1 |
| Validation run | Always | § 5 |
| Docs/config updated | Repeated issues in § 4-5 | § 6 |
| Changes committed | Always | § 7 |
| QA labels applied | Triggers present | § 8 |
| Summary posted | Always | § 9.1 |
| Downstream handoff | Blocks + context needed | § 9.2 |

**Before returning — write your completion artifact.** With every row above checked (commit, QA labels, and summary now final), run `dev-return-write` to write the durable completion record (named `tmp/dev-return-[ISSUE_ID]-[DEV_ROUND_ID].json`). Do NOT hand-author the JSON — the writer builds it deterministically (schema + full field reference: [`../../orch/schemas/dev-return.md`](../../orch/schemas/dev-return.md)). The orchestrator treats this artifact as the durable completion record: if your return message is lost — e.g. a long validation exceeded the harness tool timeout and ended the turn (§ 5, vstack#770) — the orchestrator recovers your completion from this file instead of re-delegating the whole task. Run it AFTER commit/labels/summary so every field is final:

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|"FAILING: check1,check2"] [--qa-label [LABEL]]...
```

`--issue [ARTIFACT_KEY]` is the value of the delegation's `Artifact Key:` line — the **normalized workflow-state key** (`issue-N` for GitHub, `PROJ-123` for Linear), NOT the tracker-native `OWNER/REPO#N`. Orch resolves the artifact by that exact key, so keying it to anything else (or to the bare GitHub number) leaves the receipt un-found. `--round-id` is the `[DEV_ROUND_ID]` from the `Round ID:` line — it binds this receipt to your delegation (the writer names the file `tmp/dev-return-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`). `--validate` is `pass` or `FAILING: check1,check2` (matching your commit/return); pass one `--qa-label` per applied § 8 label, none if there were none. **GitHub/ad-hoc rounds** (summary not posted to a tracker): also append `--no-summary --summary-file tmp/completion-summary-[ISSUE_ID].md` so the summary content is recoverable from the artifact if your return is lost. It is a single sanctioned command (harness-safe — no shell redirection in your command) and prints the artifact path. **Bundled** (§ 11): add `--bundled` and one `--item` per sub-issue, key `--issue` to `[ARTIFACT_KEY]` (the Parent ID) — see § 11.

**If single**: Return now with:
```
Branch: [BRANCH_NAME]
Commit: [SHA]
QA Labels: [labels or "none"]
Validate: [pass or "FAILING: check1, check2"]
Summary: [ISSUE_ID] ✓
```

**If bundled**: Mark task completed. Next sub-issue is a separate task, or proceed to § 11 if none remain.

**Bundled Linear sub-issue** (a sub-issue processed under its parent in the § 4-10 loop) → mark issue Done (`.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "Done"`). The parent session aggregates these in § 11.
**Managed session-root issue** (this single delegation is the top-level managed issue of the worktree — whether or not it has a parent) → do NOT mark Done. It follows the managed lifecycle and stays In Progress/In Review until PR merge (handled by the PR merge workflow and issue tracker sync; see orch `start-worktree.md` § 5.3).
**GitHub/ad-hoc** → do not close the issue here; PR body/merge handles closure when appropriate.

Do NOT push or submit PR — orchestrator handles after review passes.

---

## 11. Return to Orchestrator (If Bundled)

**Skip if** single issue — you returned at § 10.

1. **Update parent issue with aggregated QA labels** (Linear only):
   ```bash
   # Collect QA labels from all sub-issues (including nested), apply to parent
   .agents/skills/linear/scripts/linear.sh issues update [PARENT_ID] --labels "[EXISTING_LABELS],[AGGREGATED_QA_LABELS]"
   ```

2. **Post parent summary** (Linear only, tree format for sub-issues, blocking info shown). Create `tmp/bundle-summary-[PARENT_ID].md` with:

   ```markdown
   ## Bundle Complete
   **Agent**: [NAME] | **Branch**: [BRANCH]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1] ✓ | blocks: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_2] ✓ | blocked by: [SUB_ISSUE_1]
      ↳ [SUB_ISSUE_3] ✓  ← nested
   Files: N | Commits: N | QA: [LABELS]
   [Discovered work: ...]
   ```

   Then post it:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [PARENT_ID] --body-file tmp/bundle-summary-[PARENT_ID].md
   ```

3. **Write the completion artifact** — run `dev-return-write` (schema: [`../../orch/schemas/dev-return.md`](../../orch/schemas/dev-return.md)), keyed to the Parent ID, before sending the return. The orchestrator treats it as the durable completion record for the bundle, so a lost return message is recoverable without redoing the work:

   ```bash
   .agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [LAST_SUBISSUE_HEAD_SHA] --validate [pass|"FAILING: check1,check2"] --bundled --item [N] [DECISION] [REASONING] [--item ...] [--qa-label [LABEL]]...
   ```

   `--issue [ARTIFACT_KEY]` is the delegation's `Artifact Key:` line — for a bundle that is the Parent's normalized workflow-state key (`issue-N`/`PROJ-123`), NOT the tracker-native form; orch resolves the bundle artifact by that key. `--round-id` is the `[DEV_ROUND_ID]` from the `Round ID:` line (per group, if the bundle was delegated in groups). `--bundled` requires at least one `--item` — one per sub-issue result (`--item 1 Applied "..."`), `DECISION` ∈ Applied|Skipped|Blocked, `REASONING` non-empty plain text (no backticks). `--commit` is the last sub-issue's HEAD; add one `--qa-label` per aggregated QA label. The writer rejects a bundled artifact with no items, so populate them from the sub-issue tree.

4. Send this result to the orchestrator as an agent-to-agent message. **Posting the parent summary comment is not a return** — the orchestrator does not poll the filesystem or issue tracker, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

   **Return exactly**:

   <output_format>
   Parent: [ISSUE_ID]
   Sub-Issues: [tree format with ✓]
   Branch: [BRANCH]
   Commits: [COUNT] ([SHAS])
   QA Labels: [AGGREGATED]
   Summaries: [all issue IDs ✓]
   </output_format>
