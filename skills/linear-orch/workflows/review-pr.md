# PR Review Workflow

Pre-submission code review with fix handling, QA checks, and issue audit.

## Inputs

| Command | Behavior |
|---------|----------|
| `review-pr` | Full review cycle: review, fix, QA, summary |
| `review-pr [PR#]` | Get/create worktree for PR, full review cycle |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `agents` (optional): list of review agent names. Default: every `reviewer-*` agent discovered in the active harness registry (typically all installed `reviewer-*` from `vstack.toml` `[agent-skills]`, e.g. `reviewer-arch`, `reviewer-correctness`, `reviewer-doc`, `reviewer-error`, `reviewer-perf`, `reviewer-quality`, `reviewer-safety`, `reviewer-security`, `reviewer-structure`, `reviewer-test`). Do not hardcode a count — enumerate from the registry.
- `lifecycle` (optional): `"managed"` (return to caller at § 11) | `"self"` (default, standalone).
- `dev_agent` (optional): name of alive dev agent for fix delegation. If absent, fixes use sub-agent tasks.
- `issue_id` (optional): issue tracker ID. If absent, extracted from branch.

**If PR# provided:**
```bash
ISSUE=$(.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text)
```

Apply [Worktree Scope](../SKILL.md#worktree-scope). If no worktree exists for `$ISSUE`, ask the user before running `worktree create $ISSUE --pr [PR_NUMBER]`.

**If no argument:** Set `WT_PATH` to current directory.

**Standalone init** (`lifecycle: "self"` only):
```bash
# Extract issue from branch if not provided
ISSUE_ID=$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN")
# Init workflow state if not exists
if ! .agents/skills/linear-orch/scripts/workflow-state exists $ISSUE_ID; then
  .agents/skills/linear-orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git -C $WT_PATH rev-parse --abbrev-ref HEAD)"
  QA_LABELS=$(.agents/skills/linear/scripts/linear.sh cache issues get $ISSUE_ID | jq '[.labels[] | select(startswith("needs-"))]')
  .agents/skills/linear-orch/scripts/workflow-state set $ISSUE_ID qa_labels "$QA_LABELS"
fi
```

---

## 1. Identify Changes

```bash
BASE_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git -C [WORKTREE_PATH] symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=main
git -C [WORKTREE_PATH] diff "origin/$BASE_BRANCH"...HEAD --stat
```

**If no changes**: Report "No changes to review" and **END**.

### 1.1 Gather Decision Context

Extract issue ID from branch name (e.g., `[BRANCH_NAME]` → `[ISSUE_ID]`). Use the decider skill's search workflow:

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

Collect decision IDs and summaries from the JSON output.

**If decisions found**: Include in delegation prompt below. Agents MUST read cited decisions/research before suggesting changes that could contradict them.

### 1.2 Check for Re-Review Context

```bash
CYCLES=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.cycles // 0')
FIXED=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.fixed_items // []')
ESCALATED=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.escalated_items // []')
```

If `CYCLES > 0`: This is a re-review. Include the "Previous review cycle context" section in the delegation prompt below, populated from `FIXED` and `ESCALATED`.

## 2. Launch Review Agents

**Detect team context**:
```bash
TEAM=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.team_name // empty')
```

**Determine agent list**: If `agents` context provided, use only those. Otherwise enumerate every `reviewer-*` agent from the active harness registries (do not hardcode a fixed set or count):

```bash
AGENTS=$(.agents/skills/linear-orch/scripts/list-review-agents)
if [ $? -ne 0 ] || [ -z "$AGENTS" ]; then
  # Report and skip review delegation.
  echo "No reviewer-* agents installed in any harness registry; skipping review delegation" >&2
  # → § 5 (verdict pass, no items to handle)
fi
```

The `list-review-agents` script scans `.pi/agents`, `.claude/agents`, `.agents`, `.codex/agents`, and `.opencode/agents` (whichever exist) for `reviewer-*` files, dedupes, and exits non-zero if none are found. The output is one agent name per line.

Before any spawn, read existing reviewer state:
```bash
EXISTING_REVIEW_AGENTS=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.review_agents // []')
EXISTING_REVIEW_AGENT_IDS=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.review_agent_ids // {}')
```

For each reviewer in `[AGENTS]`:
- Reuse by exact reviewer name when `review_agent_ids` points to a live/recoverable session
- If only `review_agents` exists, attempt one recovery/resume path, then treat as missing if still unavailable
- Spawn only the missing, closed, or confirmed-stuck reviewer

Do not respawn already-live reviewers during re-review. Idle reviewers remain the active reviewer for that role.

After reconciliation, store only the active reviewer set in state:
  ```bash
  .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_agents '[AGENT_LIST_JSON]'
  .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_agent_ids '[AGENT_ID_MAP_JSON]'
  ```

**Do NOT delegate yet.** Continue to § 2.1 to resolve external review availability *before* any reviewer is spawned.

## 2.1 External Review Availability

External review runs automatically alongside internal reviewers whenever the second-opinion skill is installed and a target is detected — no user prompt. Treated identically to internal reviewers in review and re-review cycles.

**Skip if** second-opinion skill is not installed (`.agents/skills/second-opinion/scripts/second-opinion` does not exist). Set `EXTERNAL_REVIEW_REQUESTED=false` → § 2.2.

**Detect external target**:
```bash
EXTERNAL_TARGET=$(.agents/skills/second-opinion/scripts/second-opinion detect 2>/dev/null) || true
```

**Skip if** `EXTERNAL_TARGET` is empty or `"none"`. Set `EXTERNAL_REVIEW_REQUESTED=false` → § 2.2.

Otherwise, set `EXTERNAL_REVIEW_REQUESTED=true` → § 2.2.

## 2.2 Delegate Review Agents

**Record delegation timestamp** before delegating — used by the § 3 watchdog to gate filesystem fallback so stale JSONs from earlier cycles cannot be misread as current returns:
```bash
.agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_delegated_at "$(date +%s)"
```

Delegate to each active review agent in `[AGENTS]` in parallel with the prompt below. **If `EXTERNAL_REVIEW_REQUESTED=true`**, launch the external review (block below) in the *same parallel batch* as the internal reviewers so the user does not wait for serialized completion.

**Harness-specific batching:** External review is a shell command (`second-opinion review`), not an in-harness sub-agent task, so different harnesses combine the two waves differently:

- **Claude Code / Codex / OpenCode** — spawn internal reviewers via the harness's sub-agent task API and run the external review shell command from the same delegation step; the parallel batch is a logical wave, not a single API call.
- **Pi** (`pi-agents-tmux`) — the `subagent` tool with `tasks: [...]` accepts only Pi agents, not arbitrary shell commands. Launch the external review via `bg_task` action `spawn` **immediately before** the `subagent` parallel-tasks call (or immediately after — ordering does not matter, but they must be in the same turn). Both run concurrently and both count toward the same `OUTSTANDING` set in § 3.

**Delegation prompt:** Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WORKTREE_PATH]
Branch: [BRANCH]

Decisions:
[For each matching decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[If none: "- No linked decisions found."]
<if re-review cycle>
Re-review cycle [N]. Already resolved — do NOT re-report:
- Fixed: [For each fixed_item: "[DESCRIPTION] — fixed in [COMMIT_SHA]"]
- Escalated: [For each escalated_item: "[DESCRIPTION] — [REASON]"]
</if>
</delegation_format>

**External review execution** (only if `EXTERNAL_REVIEW_REQUESTED=true`, default timeout from `SECOND_OPINION_TIMEOUT` env var or 300s):

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
EXTERNAL_OUTPUT="[WORKTREE_PATH]/tmp/review-external-${TIMESTAMP}.json"
.agents/skills/second-opinion/scripts/second-opinion review \
  --cwd [WORKTREE_PATH] \
  --output "$EXTERNAL_OUTPUT"
```

**On success** — validate and append to state:
```bash
# Basic schema check: verdict field must exist
if jq -e '.verdict' "$EXTERNAL_OUTPUT" >/dev/null 2>&1; then
  .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] json_paths "$EXTERNAL_OUTPUT"
else
  echo "Warning: external review JSON missing verdict field — skipping" >&2
fi
```

**On failure**: Report error to user but **continue** — external review is advisory, not blocking. Do not halt the review pipeline.

## 3. Collect Results (Watchdog)

Do NOT shutdown reviewers — they may be needed for re-review in § 4.

### 3.1 Completion

`OUTSTANDING = [AGENTS] ∪ ({external} if EXTERNAL_REVIEW_REQUESTED)`. An agent completes when *either*:

- A return message arrives with `Verdict:` and `File:` lines, *or*
- Latest `[WORKTREE_PATH]/tmp/review-[AGENT]-*.json` with `mtime >= review_delegated_at` validates with `jq -e '.verdict'`

On completion, append the path and drop the agent from `OUTSTANDING`:
```bash
.agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
```

### 3.2 Watchdog Rules

**Sweep filesystem on every event below** — catches silent finishers without delay.

Per-agent deadline from `review_delegated_at`:
- Perf reviewer (agent name contains `perf`): **25 min**
- All others, including external: **15 min**

| Event | Action |
|-------|--------|
| Return arrives | Append JSON, remove from `OUTSTANDING`. |
| 2 min after first return (or 10 min from delegation if zero returns yet) — once per cycle | Send each outstanding agent one ping: `Status check on [ISSUE_ID] review — return your verdict if complete, or report blocker.` |
| 2 min after ping | Mark each non-perf agent still in `OUTSTANDING` as `unresponsive`. |
| Per-agent deadline reached | Mark that agent `unresponsive`. |

Exit to § 3.3 when `OUTSTANDING` is empty (`unresponsive` counts as resolved).

### 3.3 Present Results

Extract `verdict` from each appended JSON. **Overall verdict**: `action_required` if any reviewer has blockers, `pass` otherwise. Unresponsive reviewers do not affect the overall verdict.

<output_format>

### ✅ PR REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [For each agent in AGENTS:] |
| [AGENT] | `[verdict]` | `[path]` |
| [If external review JSON exists in json_paths (agent field starts with "external-"):] |
| [AGENT] | `[verdict]` | `[path]` |
| [For each unresponsive agent:] |
| [AGENT] | `unresponsive` | — |
</output_format>

**Route by verdict + items:**

Read agent JSONs, check for items where `category == "fix"`.

| verdict | fix items? | Next |
|---------|-----------|------|
| any | yes (or `action_required`) | → § 4 |
| `pass` | none | → § 5 |

## 4. Handle PR Review Items

**Collect items** from agent JSONs:
- **Blockers**: items from agents with `action_required` verdict
- **Fix suggestions**: items where `category == "fix"` from any agent

**If no items** → § 5.

**Present to user:**

<output_format>

### PR Review Items — [ISSUE_ID]

**Blockers**

| # | Agent | Location | Description | Pri |
|---|-------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | 🔴 |

**Fix Suggestions**

| # | Agent | Location | Description | Pri | Est |
|---|-------|----------|-------------|-----|-----|
| 1 | [agent] | [location] | [description] | 🟤 | 1 |

</output_format>

**Omit empty categories.**

→ Ask user (omit categories with no items):

| Category | Question | Type |
|----------|----------|------|
| Blockers | `Fix blockers?` | `Fix now` \| `Ignore and proceed` |
| Fix suggestions | `Apply fix suggestions?` | Multi-select: `#N: [TITLE]`, `All`, `None` |

If >4 suggestion items: show first 3 + `All N fixes`. Refine via "Other".

| User Choice | Action |
|-------------|--------|
| No items selected | → § 5 |
| Items selected | → fix delegation below |

**Never fix as main agent.**

### Fix Delegation

1. **Capture pre-fix state**:
   ```bash
   .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] pre_delegate_sha "$(git -C [WORKTREE_PATH] rev-parse HEAD)"
   ```

2. **Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4 step 3` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `dev_agent`: [DEV_AGENT] (if provided)
   - `issue_id`: [ISSUE_ID]
   - `items`: [SELECTED_ITEMS — format each as `#[N] | [Agent] | [Location]` with Description + Recommendation]
   - `source`: `pr-review`

3. **Route based on fix scope**:
   ```bash
   PRE_SHA=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] .pre_delegate_sha)
   .agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] $PRE_SHA
   ```

   | `files_changed` | `risk_flags` | `scope` | Route |
   |-----------------|--------------|---------|-------|
   | `0` | — | — | § 5 |
   | `>0` | non-empty | any | → § 2 (full re-review, all agents) |
   | `>0` | empty | `production` | Selective shutdown (below) → § 2 |
   | `>0` | empty | `support` | § 5 |

   **Selective shutdown** (row 3):
   a. Read review JSONs. Reporting agents = agents whose JSON contained items.
   b. Shutdown non-reporting agents. Keep reporting agents alive for potential fix cycles.
   d. Update state: `.agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_agents '[REPORTERS_ONLY]'`

## 5. Verdict Pass

1. **Shutdown review agents** — terminate all agents in state `review_agents`.
   ```bash
   .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_agents '[]'
   .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] review_agent_ids '{}'
   ```

2. **Check skip_qa flag**:
   ```bash
   SKIP_QA=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.skip_qa // false')
   ```
   If `true`: `.agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] skip_qa false` → § 8

3. **Read state**: `.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] .qa_labels`

4. **Route**:
   - QA labels present → § 6
   - No QA labels → § 8

## 6. QA Checks

**Skip if** no QA labels. → § 8

1. **Check labels**. See issue tracker label configuration (project-level).

2. **Determine sequence**: QA agent types are configurable per project. Example label-to-agent mappings: `needs-safety-audit` → safety audit agent, `needs-perf-test` → performance QA agent, `needs-review` → architecture review agent, `design` → visual QA agent (use visual QA skills as necessary to validate UI changes).

**For each QA agent, execute steps 3–5:**

3. **Delegate to QA agent** (`[QA_AGENT]`) with the prompt below:

   <delegation_format>
   Follow workflow: .agents/skills/reviewer/workflows/qa-review.md

   Issue: [ISSUE_ID]
   Branch: [BRANCH]
   Worktree: [WORKTREE_PATH]
   Trigger: [needs-* label]

   Dev summary:
   [paste completion summary from dev return or describe branch changes]

   [If re-review (CYCLES > 0) — include:]
   Previous review cycle context (cycle [CYCLES]):
   - Fixed since last review: [For each fixed_item with source "qa-review": "[DESCRIPTION] — fixed in [COMMIT_SHA]"]
   - Escalated (accepted): [For each escalated_item with source "qa-review": "[DESCRIPTION] — [REASON]"]
   - Do NOT re-report fixed or escalated items. Only report NEW issues or regressions introduced by the fixes.
   </delegation_format>

4. **Wait for completion.**

5. **Process agent return.** Agent returns `verdict`, `json_path`, and (for performance QA agent) `benchmark_commit`.
   - **Update state**: `.agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] json_paths "[json_path]"`
   - If `benchmark_commit` is not "none", verify: `git -C [WORKTREE_PATH] log -1 --oneline [SHA]`.
   - **If performance QA agent**: post benchmark report to issue tracker as issue comment:
     ```bash
     .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body "[PERF_REPORT]"
     ```
     Build PERF_REPORT from performance QA agent's JSON `qa_metadata.perf_qa`:
     ```markdown
     ## Benchmark Results — [BRANCH] ([benchmark_commit])

     **Platform**: [platform] | **Baseline**: [baseline_sha]

     ### Regressions
     [If regressions[] non-empty:]
     | Operation | Baseline | Current | Change | Classification | Notes |
     |-----------|----------|---------|--------|----------------|-------|
     | [op] | [baseline_ns] | [current_ns] | +[change_pct]% | [classification] | [justification/decision_ref] |

     [If regressions[] empty:]
     None detected.

     ### Budget Compliance
     | Component | Operation | P50 | P99 | Budget | Status |
     |-----------|-----------|-----|-----|--------|--------|
     [Key operations from benchmarks vs project performance budgets]

     ### Summary
     [N] benchmarks recorded | [N] regressions ([N] hot-path, [N] cold-path, [N] intentional) | All budgets [met/exceeded]
     ```
   - **Handle verdict:**

     | verdict | Action |
     |---------|--------|
     | `pass` | Continue to next QA agent |
     | `action_required` | → § 7 |

6. **After all QA agents complete** — check for accumulated fix suggestions:
   - Read all QA agent JSONs from state `json_paths`, filter items where `category == "fix"`
   - Exclude items already in `fixed_items` or `escalated_items`
   - Fix suggestions remain → § 7
   - No remaining items → § 8

## 7. Handle QA Review Items

**Skip if** all QA verdicts are `pass` AND no fix suggestions from QA agents. → § 8

**Never fix as main agent.**

Follow § 4 pattern (collect → present → ask user → delegate via `workflows/dev-fix.md` → update state) with these overrides:

- **Items**: from QA agent JSONs. Exclude items already in `fixed_items` or `escalated_items`.
- **Table header**: `QA Agent` instead of `Agent`. Title: `QA Review Items — [ISSUE_ID]`.
- **Source**: `qa-review` in `workflows/dev-fix.md` context.
- **`qa_agent`**: pass QA agent name (project-configurable, e.g. safety audit, performance QA, architecture review) to `workflows/dev-fix.md` context.
- **Route after fix**:

   | `files_changed` | `risk_flags` | `scope` | Route |
   |-----------------|--------------|---------|-------|
   | `0` | — | — | § 8 |
   | `>0` | non-empty | any | § 2 (full PR review) |
   | `>0` | empty | `production` | § 6 (focused QA re-check) |
   | `>0` | empty | `support` | § 8 |

## 8. Review Summary

**Read state**: `.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] .json_paths`

**Skip if** json_paths empty (no reviews ran). Output: "No review items." → § 9

1. **Read all JSON files** from state `json_paths`

2. **Collect issue suggestions** — items where `category == "issue"` from review JSONs (defer to § 9 audit). Fix suggestions already handled in § 4 / § 7.

3. **Deduplicate** by (location, description) — keep first, note all sources

4. **Present summary**:

   <output_format>

### REVIEW SUMMARY — [ISSUE_ID]

| Agent | Verdict | Blockers | Fix | Issue |
|-------|---------|----------|-----|-------|
| [AGENT_NAME] | ✅ pass | 0 | 0 | 1 |
| [AGENT_NAME] | ⚠️ action_required → fixed | 2 | 1 | 0 |

### ✅ FIXED BLOCKERS

| # | Source | Location | Description | Commit |
|---|--------|----------|-------------|--------|
| 1 | [agent] | [location] | [description] | [sha] |

### ⚠️ ESCALATED BLOCKERS

| # | Source | Location | Description | Pri |
|---|--------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | 🟠 |

### 📊 QA METRICS

[QA_METRICS] — project-configurable per QA agent type. Include agent-specific results as returned by each QA agent's JSON `qa_metadata` field. Example sections:

**[QA_AGENT_TYPE]**: [metric_1] [status] | [metric_2] [status] | ...

**Perf** (from `qa_metadata.perf_qa`, if performance QA agent ran):

| Metric | Value |
|--------|-------|
| Percentiles | P50 [val] · P99 [val] · P99.9 [val] |
| Budget | [budget target] · Margin: [N]x |
| Platform | [platform] |
| Baseline | [baseline_sha] → [benchmark_commit] |
| Regressions | [N] hot-path ❌ · [N] cold-path ⚠️ · [N] intentional ℹ️ |

**If regressions[] non-empty**, expand each:

| Operation | Baseline | Current | Change | Class | Notes |
|-----------|----------|---------|--------|-------|-------|
| [op] | [val] | [val] | +X% | hot-path | ❌ BLOCKER |
| [op] | [val] | [val] | +X% | intentional | [decision_ref]: [reason] |

**Budget compliance** (key operations vs project performance budgets):

| Component | Operation | P50 | P99 | Budget | Status |
|-----------|-----------|-----|-----|--------|--------|
| [component] | [operation] | [val] | [val] | [budget] | ✅ |

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4
Est: 1 (hours) | 2 (half-day) | 3 (day) | 4 (2-3d) | 5 (week+)
Issue suggestions: [N] items → § 9 audit

   </output_format>

   **Omit empty sections.** Omit QA METRICS if no QA agents ran. Show issue suggestion count in legend if any exist.

## 9. Create Issues

1. **Read state**: `.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] .escalated_items`

2. **Extract discovered work** from completion summaries:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID] | jq -r '.[] | select(.body | contains("Discovered Work")) | .body'
   ```
   If bundled: also extract from each sub-issue via `.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle | jq -r '.children[].id'`.
   Parse "Discovered Work" section bullets into audit items with `origin: "discovered"`, `found_by: [agent]`. Skip if section absent or "(Skip if none)".

   **Filter out workflow-internal handoffs.** Skip any Discovered Work bullet whose leading token after `- ` is one of the markers below. The marker MUST be the first token — anything before it (such as `[Type]`) prevents the match. The canonical bullet form is documented in `linear-dev/workflows/dev-implement.md` § 9:

   - `- handoff_to_submit_pr: [doc] PR-body content for X (estimate: N)` — produced by the upcoming `submit-pr` step.
   - `- handoff_to_merge_pr: [process] ... (estimate: N)` — produced by the eventual `merge-pr` step.
   - `- current_workflow_action: [doc] ... (estimate: N)` — item the current `review-pr` cycle will handle itself.

   Match by exact regex `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s`. These items must not be routed through the TPM audit — they are already in-flight in the current workflow. Drop them silently from the audit-input file in step 4 below.

   This filter applies only to Discovered Work bullets parsed from completion summaries. Escalated items and review JSON `category: "issue"` suggestions remain in the audit input unchanged — the orchestrator has already decided those are tracked work.

3. **Skip if** no issue suggestions AND escalated_items empty AND no discovered work items. → § 10

4. **Build audit-input file** from:
   - Escalated items from state file
   - Issue suggestions (`category: "issue"` from review JSONs in state `json_paths`)
   - Discovered work items (from step 2, `origin: "discovered"`)

5. **Write file**: `[WORKTREE_PATH]/tmp/audit-start-YYYYMMDD-HHMMSS.json`
   - Schema: `.agents/skills/project-management/schemas/audit-issues-input.md`

6. **Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 9 step 7`

7. **Update state** — for each created issue from audit output:
   ```bash
   .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] audit_issues_created "[CREATED_ISSUE_ID]"
   ```

## 10. Delegate Pending Children

1. **Query pending children**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [ISSUE_ID] --recursive --pending --format=safe
   ```

2. **Skip if** no pending children → § 11.

3. **Capture pre-delegate state**:
   ```bash
   .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] pre_delegate_sha "$(git -C [WORKTREE_PATH] rev-parse HEAD)"
   ```

4. **Delegate immediately.** Do **not** surface a Defer/Skip prompt — § 10 is mandatory once § 9 created `make_child` issues under `[ISSUE_ID]`. Delegate regardless of how sub-issues were created or their perceived scope.

   If delegation is skipped (user override, escalation), § 10 must FIRST detach every `audit_issues_created` entry from `[ISSUE_ID]` before returning to § 11 — otherwise `merge-pr.md` will cascade-Done them.

   ```bash
   .agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] '.audit_issues_created // []' | jq -r '.[]'
   ```
   Capture each line as `[CHILD_ID]`, then for each:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --remove-parent
   .agents/skills/linear/scripts/linear.sh issues add-relation [CHILD_ID] --related [ISSUE_ID]
   ```

   The `merge-pr.md § 4.3` guard is a backstop, not a license to defer.

   **Run Workflow**: `⤵ workflows/dev-start.md § 1-4 → § 10 step 5` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: inherit current
   - `issue_id`: [ISSUE_ID]

5. **Assess re-review scope**:
   ```bash
   PRE_SHA=$(.agents/skills/linear-orch/scripts/workflow-state get [ISSUE_ID] .pre_delegate_sha)
   .agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] $PRE_SHA
   ```

   | `risk_flags` | `scope` | Action | Route |
   |--------------|---------|--------|-------|
   | non-empty | any | — | → § 1 (full re-review) |
   | empty | `production` | `.agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] skip_qa true` | → § 1 |
   | empty | `support` | — | → § 11 |

## 11. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — review cycle complete. Summary presented in § 8.
