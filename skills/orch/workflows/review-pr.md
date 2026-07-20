# PR Review Workflow

Pre-submission code review: fix handling, QA checks, and issue audit.

## Inputs

| Command | Behavior |
|---------|----------|
| `review-pr` | Full review cycle: review, fix, QA, summary |
| `review-pr [PR#]` | Get/create worktree for PR, full review cycle |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `agents` (optional): list of review agent names. Default: every `reviewer-*` agent from the active harness registry. Do not hardcode a count — enumerate from the registry.
- `lifecycle` (optional): `"managed"` (return to caller at § 11) | `"self"` (default, standalone).
- `dev_agent` (optional): alive dev agent for fix delegation. If absent, fixes use sub-agent tasks.
- `issue_id` (optional): workflow-state key — the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number. If absent, extracted from branch.

**If PR# provided:**
```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```
Use the output as `ISSUE`.

Apply [Worktree Scope](../SKILL.md#worktree-scope). If no worktree exists for `$ISSUE`, ask the user before running `worktree create $ISSUE --pr [PR_NUMBER]`. If no argument: set `WT_PATH` to current directory.

**Standalone init** (`lifecycle: "self"` only):
```bash
# Extract issue from branch if not provided
.agents/skills/orch/scripts/git-context issue-from-branch .
# Init workflow state if not exists
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```
Use the output as `ISSUE_ID`. If `.exists` is `false`, initialize with `git-context branch "$WT_PATH"` and `workflow-state init`, then resolve `TRACKER` and set `qa_labels` from the issue labels.

---

## 1. Identify Changes

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] status --porcelain
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

**If `git status --porcelain` is not empty**:
- Managed lifecycle with `dev_agent`: stop review and re-delegate to the dev agent to commit or revert the leftover files, then re-enter § 1. Do not run review against a dirty pre-submission worktree.
- Standalone lifecycle: report the dirty files and ask the user to commit, revert, or run `orch review all` for an ad-hoc uncommitted review. Do not continue through `review-pr`.

**If no committed diff after the dirty check**: Report "No committed changes to review" and **END**.

**Tiny/docs-only skip path**: Review is the default gate. If the full diff is docs/comments-only (`*.md`, comments, typo fixes) or tiny (≤10 changed lines, no logic change), present the diff stat and ask the user: `Run full review` | `Skip review (tiny/docs-only)`. On skip: `workflow-state set [ISSUE_ID] review_skipped "tiny-docs"` → § 11 with verdict `pass`. Never auto-skip without asking.

### 1.1 Gather Decision Context

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

Collect decision IDs and summaries from the JSON output. If decisions found: include in the delegation prompt below. Agents MUST read cited decisions before suggesting changes that could contradict them.

The `path` fields in this JSON output are the ONLY authorized source for decision file paths in delegation guidance — the CLI resolves them from the decision index; never compose or recall a decision path from memory, however plausible the `DXXX-slug` looks (vstack#696). Verify every collected path before injecting it (belt-and-suspenders against index drift) — one simple command per path:

```bash
test -f [DECISION_FILE_PATH]
```

**If the check fails**: omit that path and carry the one-line note `- decision index lookup failed for [DECISION_ID]` in the `Decisions:` block instead — a broken path must never reach a reviewer.

### 1.2 Check for Re-Review Context

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: (.cycles // 0), fixed_items: (.fixed_items // []), escalated_items: (.escalated_items // [])}'
```
Read `cycles` as `CYCLES`, `fixed_items` as `FIXED`, and `escalated_items` as `ESCALATED` from the JSON object.

If `CYCLES > 0`: include the "Previous review cycle context" section in the delegation prompt, populated from `FIXED` and `ESCALATED`.

## 2. Prepare Review Agents

**Detect team context**:
```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.team_name // empty'
```
Use the output as `TEAM`.

**Determine agent list**: If `agents` context provided, use only those. Otherwise enumerate every `reviewer-*` agent from active harness registries (do not hardcode a count):

```bash
.agents/skills/orch/scripts/list-review-agents
```
Use the output as `AGENTS`. If the command fails or prints no agents, skip review delegation and go to § 5 with verdict pass.

`list-review-agents` scans `.pi/agents`, `.claude/agents`, `.agents`, `.codex/agents`, and `.opencode/agents` for `reviewer-*` files, dedupes, and exits non-zero if none found. Output: one agent name per line.

**Resolve the reviewer slot budget** — some runtimes cap concurrent agent threads, so the full reviewer set may not fit alongside the primary and persistent dev/QA sessions:

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

The printed value is `SLOT_BUDGET` — the runtime's total concurrent agent-session budget, counting this primary session (`0` = unlimited; Codex collaboration runtime: MultiAgentV2's configurable default is `4` total including the primary — set the budget to the cap the machine config declares). If `SLOT_BUDGET` is `0`, first check whether an earlier cycle already recorded a runtime demotion (§ 2.2 persistent-mode thread-limit recovery):

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.reviewer_slots_observed // 0'
```

If the output is greater than `0`, use **wave mode** with `REVIEWER_SLOTS` set to that observed value — the runtime already proved the unlimited configuration wrong; do not relaunch the full set only to fail again. If the output is `0`, use **persistent mode** — today's semantics: every reviewer launches before the coordinated delegation batch and stays alive through fix/re-review cycles. The configured budget is advisory; the runtime cap is authoritative — § 2.2 recovers automatically if a persistent launch hits the thread limit. If `SLOT_BUDGET` is greater than `0`, count the live persistent agent sessions:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.child_sessions // {} | [to_entries[] | select((.value.status // "active") == "active")] | length'
```

A record with no `status` field counts as active — legacy child-session records written before the `status` stamp (vstack#698) persist in workflow-state files, and an unretired record means a live dev/QA session holding a slot.

Use the output as `LIVE_AGENTS`, then compute `REVIEWER_SLOTS = SLOT_BUDGET - 1 - LIVE_AGENTS` (minimum `1`; the `1` is this primary session). If the `[AGENTS]` count fits within `REVIEWER_SLOTS`, use persistent mode. If it exceeds `REVIEWER_SLOTS`, use **wave mode**: run reviewers in sequential waves of up to `REVIEWER_SLOTS` (§ 2.2), retiring each completed session to release its slot. One policy, two modes: persistent when the budget allows, waves when it does not. Recompute the mode at every § 2 entry — live sessions change between cycles.

**Invariant (both modes)**: review state lives in on-disk report artifacts and workflow state, never in reviewer session memory. Retiring a completed reviewer loses nothing; a recreated reviewer re-reads the current diff and its prior report artifact, and `review_delegated_at` freshness gating is unchanged.

**Codex runtime agent type rule**: When § 2.2 launches a reviewer, first call the harness spawn API with `agent_type` equal to that reviewer name. The Codex `task_name` schema accepts only `[a-z0-9_]` and rejects hyphenated names before launch (vstack#751): pass the reviewer name with hyphens translated to underscores as the runtime `task_name` only (`reviewer-arch` → `task_name=reviewer_arch`, `agent_type` unchanged), and attempt that translation before any `worker` fallback — a `task_name` schema rejection is not a missing agent type. When the name was translated, record the runtime `task_name` under `review_agent_runtime_types[reviewer-name].task_name`; workflow-state keys and reports always use the canonical hyphenated name. Do not launch `worker` and simulate reviewer identity in the prompt unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated `agent_type`. In that fallback, spawn `agent_type=worker` but keep the logical reviewer name in bootstrap/delegation text, reports, and workflow-state keys: persist the returned id under `review_agent_ids[reviewer-name]`, and record runtime metadata under `review_agent_runtime_types[reviewer-name]` with `agent_type="worker"` and a fallback reason.

Before any spawn, read existing reviewer state:
```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{review_agents: (.review_agents // []), review_agent_ids: (.review_agent_ids // {}), review_agent_runtime_types: (.review_agent_runtime_types // {})}'
```
Read `review_agents` as `EXISTING_REVIEW_AGENTS`, `review_agent_ids` as `EXISTING_REVIEW_AGENT_IDS`, and `review_agent_runtime_types` as `EXISTING_REVIEW_AGENT_RUNTIME_TYPES` from the JSON object.

For each reviewer in `[AGENTS]`: classify it as reusable, missing, closed, or confirmed-stuck. Reuse by exact name when `review_agent_ids` points to a live/recoverable session. If only `review_agents` exists, attempt one recovery/resume, then treat as missing. Add only missing, closed, or confirmed-stuck reviewers to `REVIEWERS_TO_LAUNCH`. Do not respawn already-live reviewers. When a reviewer is reusable, carry forward any `EXISTING_REVIEW_AGENT_RUNTIME_TYPES[reviewer-name]` entry into `AGENT_RUNTIME_TYPE_MAP_JSON` instead of rebuilding runtime metadata only from newly spawned reviewers.

**Do NOT spawn or delegate yet.** Continue to § 2.1 to resolve external review availability before launching reviewers.

## 2.1 External Review Availability

External review runs automatically alongside internal reviewers when the second-opinion skill is installed and a target is detected — no user prompt. Treated identically to internal reviewers.

**Skip if** `.agents/skills/second-opinion/scripts/second-opinion` does not exist. Set `EXTERNAL_REVIEW_REQUESTED=false` → § 2.2.

```bash
.agents/skills/second-opinion/scripts/second-opinion detect
```
If the command fails or prints `none`, set `EXTERNAL_REVIEW_REQUESTED=false`. Otherwise use the output as `EXTERNAL_TARGET`.

**Skip if** `EXTERNAL_TARGET` is empty or `"none"`. Set `EXTERNAL_REVIEW_REQUESTED=false` → § 2.2. Otherwise `EXTERNAL_REVIEW_REQUESTED=true` → § 2.2.

## 2.2 Launch Review Agents

Prepare internal reviewer sessions before the coordinated delegation step:
- For each reusable reviewer, keep the existing session id and preserve its carried-forward `EXISTING_REVIEW_AGENT_RUNTIME_TYPES[reviewer-name]` entry in `AGENT_RUNTIME_TYPE_MAP_JSON`.
- For each reviewer in `REVIEWERS_TO_LAUNCH`, spawn it now. Follow the Codex runtime agent type rule above when running in Codex.
- When writing `review_agent_runtime_types`, include preserved entries for reused reviewers and new/updated entries for reviewers launched in this step.

**Wave mode** (§ 2 selected it) — do not launch the full set. On entry from § 2.1 (a new review cycle), reset the per-cycle wave tracking:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] review_wave_done '[]'
```

On re-entry from § 3.2 (next wave of the same cycle), skip the reset. Then:
- `WAVE` = the first up-to-`REVIEWER_SLOTS` reviewers in `[AGENTS]` not listed in `review_wave_done`. Restrict this section's launch, state-write, and delegation steps to `[WAVE]`.
- A retired reviewer has no session to reuse — recreate it fresh (`REVIEWERS_TO_LAUNCH = [WAVE]`), and write `review_agents`/`review_agent_ids`/`review_agent_runtime_types` with the live wave only.
- If a spawn still fails with the runtime thread-limit error (Codex: `collab spawn failed: agent thread limit reached`), the budget is set too high for the live session count: continue with the reviewers that did spawn, fold the failed reviewer into a later wave, and use that smaller wave size for the rest of the cycle. If nothing spawned, report the misconfigured `REVIEWER_SLOT_BUDGET` to the user and stop.
- A re-review delegation to a recreated reviewer MUST include the fresh-session block in the delegation prompt below — the recreated session has no memory of earlier cycles; state lives in artifacts, not session memory.

**Persistent-mode thread-limit recovery** — a `SLOT_BUDGET` of `0` (unlimited) does not lift the runtime's real cap; the configuration is advisory, the runtime is authoritative. If a spawn in the persistent launch batch fails with the runtime thread-limit error (Codex: `collab spawn failed: agent thread limit reached`), do not retry the failed spawn and do not tear down the reviewers that did spawn — demote this review to wave mode and continue automatically:

- `[WAVE]` = the reviewers that spawned successfully; `REVIEWER_SLOTS` = the observed successful spawn count. If nothing spawned, report the misconfigured `REVIEWER_SLOT_BUDGET` to the user and stop.
- Record the demotion and reset the per-cycle wave tracking in one write, so every later § 2 entry — re-review cycles included — reuses wave mode at the observed size:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.reviewer_slots_observed = [OBSERVED_SPAWN_COUNT] | .review_wave_done = []'
```

- From here the existing wave mechanics apply unchanged for the rest of the review: restrict this section's state-write and delegation steps to `[WAVE]`, re-stamp `review_delegated_at` immediately before each wave's delegation batch, retire each reviewer as its artifact validates (§ 3.1), and loop § 3.2 → § 2.2 until every reviewer in `[AGENTS]` is listed in `review_wave_done` — the reviewers whose spawns failed land in later waves.
- Surface a one-line configuration recommendation to the user. `[OBSERVED_BUDGET]` = successful spawns + 1 (this primary session) + live persistent agent sessions (the § 2 `child_sessions` active count): `Runtime capped concurrent agent sessions — set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in vstack.settings.toml [env] (observed: [N] reviewer spawns + this session + [M] live dev/QA sessions).`

This recovery is the documented automatic behavior for what was previously a manual workaround (running the wave invariant by hand with persisted artifacts): review state lives in on-disk artifacts and workflow state — never in session memory — so demoting mid-launch loses nothing.

After launch/reuse, store the active reviewer set:
```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON] | .review_agent_ids = [AGENT_ID_MAP_JSON] | .review_agent_runtime_types = [AGENT_RUNTIME_TYPE_MAP_JSON]'
```

**Record delegation timestamp immediately before the actual delegation batch** — gates § 3.1 `review-artifact-check` acceptance against stale JSONs from earlier cycles and output produced during reviewer spawn/bootstrap. In wave mode, re-stamp immediately before each wave's delegation batch — every prior-wave artifact is already validated and appended, so the fresh boundary gates only the in-flight wave:
```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at
```

Start the coordinated delegation batch:
- Delegate to each active reviewer in `[AGENTS]` in parallel. **Wave mode**: the active set is `[WAVE]` — delegate to each reviewer in the wave in parallel.
- **If `EXTERNAL_REVIEW_REQUESTED=true`**, launch the external review in the same parallel batch. It is a shell command, not an agent session — it consumes no slot; in wave mode it joins only the first wave of the cycle.

**Harness-specific batching:**
- **Claude Code / Codex / OpenCode**: spawn reviewers via the harness sub-agent task API; run the external review shell command in the same delegation step.
- **Pi** (`pi-agents-tmux`): launch external review via `bg_task` action `spawn` immediately before (or after) the `subagent` parallel-tasks call in the same turn. Both count toward the same `OUTSTANDING` set in § 3.

**Delegation prompt:** Fill placeholders, omit empty lines/sections.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WORKTREE_PATH]
Branch: [BRANCH]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
<if re-review cycle>
Re-review cycle [N]. Already resolved — do NOT re-report:
- Fixed: [For each fixed_item: "[DESCRIPTION] — fixed in [COMMIT_SHA]"]
- Escalated: [For each escalated_item: "[DESCRIPTION] — [REASON]"]
</if>
<if re-review cycle and this reviewer session was recreated fresh (wave mode or respawn)>
Fresh session — you have no memory of earlier cycles. Read your prior report [PRIOR_REPORT_PATH] and re-read the current diff before reviewing.
</if>
</delegation_format>

`[PRIOR_REPORT_PATH]` is the reviewer's most recent `review-[AGENT]-*.json` path from state `json_paths`.

**External review execution** (only if `EXTERNAL_REVIEW_REQUESTED=true`; default timeout: `SECOND_OPINION_TIMEOUT` env var or 300s):

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
# Use [WORKTREE_PATH]/tmp/review-external-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json as EXTERNAL_OUTPUT.
.agents/skills/second-opinion/scripts/second-opinion review \
  --cwd [WORKTREE_PATH] \
  --output "$EXTERNAL_OUTPUT"
```

**On success** — validate deterministically, then append. Pass `review_delegated_at` (recorded in § 2.2) as the freshness boundary so a stale or misdated external artifact is rejected the same way glob mode rejects stale reviewer JSONs. `review-artifact-check --file` then checks existence, `mtime >= review_delegated_at`, `jq -e '.verdict'`, that the artifact does not self-report a no-review (`qa_metadata.review_performed: false` → reason `no_review`), and that an artifact declaring `qa_metadata` still carries its `blockers[]`/`suggestions[]` arrays (reason `incomplete` when they were lost in the write), printing `{ok, path, reason}` — no inline conditional or redirection:
```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```
**If `ok == true`** — append the external JSON:
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "$EXTERNAL_OUTPUT"
```
**If `ok == false`** — the external JSON is missing, has no `verdict` field, self-reports that no review was performed (reason `no_review`), or declares `qa_metadata` but lost its finding arrays (reason `incomplete`). Report the `reason` to the user and skip the append (external review is advisory).

**On failure**: report to user but **continue** — external review is advisory, not blocking. Exit 3 means the wrapper found no diff scope to review; exit 4 means the external model reported it performed no review or omitted required schema fields even after the one-shot retry (response preserved as `<output>.noreview.json` / `<output>.incomplete.json`) — in all cases there is no external verdict; never substitute a pass.

## 3. Collect Results (Watchdog)

**Persistent mode**: do NOT shutdown reviewers — needed for re-review in § 4. **Wave mode**: retire each reviewer as soon as its artifact validates (§ 3.1) so the slot frees for the next wave — § 2.2 recreates reviewers fresh for re-review; state lives in artifacts, not sessions.

### 3.1 Completion

`OUTSTANDING = [AGENTS] ∪ ({external} if EXTERNAL_REVIEW_REQUESTED)`. **Wave mode**: `OUTSTANDING = [WAVE]` (∪ `{external}` in the cycle's first wave). An agent completes **only** when its on-disk artifact validates — a return message with `Verdict:`/`File:` lines is never sufficient by itself. Check deterministically:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```

Run `review-artifact-check` on every return message and every watchdog sweep. It prints `{ok, path, reason}` after validating existence, `mtime >= review_delegated_at`, `jq -e '.verdict'`, the absence of a self-reported no-review (`qa_metadata.review_performed: false` → reason `no_review`), and that an artifact declaring `qa_metadata` still carries its `blockers[]`/`suggestions[]` arrays (reason `incomplete`).

**If `ok == true`** — the agent is complete. Append `path` and drop from `OUTSTANDING`:
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
```

**Wave mode** — use this combined write instead, then shut the reviewer's session down (retiring each completed reviewer releases its slot for the next wave):
```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.json_paths += ["[PATH]"] | .review_wave_done += ["[AGENT]"]'
```

**If `ok == false` after a return message** — the return is **incomplete** (even if its `File:` path looks valid or the message body contains JSON). Send that agent **exactly one** re-delegation:

> Your review return is incomplete: `review-artifact-check` reports `[reason]` for `[WORKTREE_PATH]/tmp/review-[AGENT]-*.json`. Write your full review JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` using your harness file-write tool (not shell redirection), then return `Verdict:` and `File:` again.

If `review-artifact-check` still reports `ok == false` after the re-delegation return (or the agent hits its § 3.2 deadline), mark the agent `unresponsive` — do not re-delegate a second time.

### 3.2 Watchdog Rules

**Sweep filesystem on every event** — catches silent finishers without delay.

Per-agent deadline from `review_delegated_at`:
- Agent name contains `perf`: **25 min**
- All others (including external): **15 min**

| Event | Action |
|-------|--------|
| Return arrives | Run `review-artifact-check` (§ 3.1). `ok == true` → append `path`, remove from `OUTSTANDING`. `ok == false` → one re-delegation per § 3.1. |
| 2 min after first return (or 10 min from delegation if zero returns yet) — once per cycle (wave mode: once per wave) | Send each outstanding agent one ping: `Status check on [ISSUE_ID] review — return your verdict if complete, or report blocker.` |
| 2 min after ping | Mark each non-perf agent still in `OUTSTANDING` as `unresponsive`. |
| Per-agent deadline reached | Mark that agent `unresponsive`. |

**Wave mode**: shut down an `unresponsive` reviewer's session as well, and record it — the slot must be released and the reviewer must not relaunch this cycle:
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] review_wave_done "[AGENT]"
```

When `OUTSTANDING` is empty (`unresponsive` counts as resolved): persistent mode → § 3.3. Wave mode → if any reviewer in `[AGENTS]` is missing from `review_wave_done`, return to § 2.2 for the next wave; otherwise → § 3.3.

### 3.3 Present Results

Extract `verdict` from each appended JSON. **Overall verdict**: `action_required` if any reviewer has blockers; `pass` otherwise. Unresponsive reviewers do not affect the verdict.

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

**Collect items** from agent JSONs — blockers (from `action_required` agents) and fix suggestions (`category == "fix"`).

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

Ask user (omit categories with no items):

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
   .agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
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
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pre_delegate_sha
   .agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] $PRE_SHA
   ```
   Use the workflow-state output as `PRE_SHA`.

   | `files_changed` | `risk_flags` | `scope` | Route |
   |-----------------|--------------|---------|-------|
   | `0` | — | — | § 5 |
   | `>0` | non-empty | any | → § 2 (full re-review, all agents) |
   | `>0` | empty | `production` | Selective shutdown (below) → § 2 |
   | `>0` | empty | `support` | § 5 |

   **Selective shutdown** (row 3):
   a. Read review JSONs. Reporting agents = agents whose JSON contained items.
   b. Shutdown non-reporting agents. Keep reporting agents alive for potential fix cycles.
   c. Update state: `.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] review_agents '[REPORTERS_ONLY]'`

   **Wave mode**: every reviewer session is already retired (§ 3.1) — skip step b; run steps a and c unchanged, and § 2.2 recreates reviewers fresh in waves on re-entry.

## 5. Verdict Pass

1. **Shutdown review agents** — terminate all agents in state `review_agents`. (Wave mode: sessions are already retired — just clear the state.)
   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [] | .review_agent_ids = {} | .review_wave_done = []'
   ```

2. **Check skip_qa flag**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.skip_qa // false'
   ```
   Use the output as `SKIP_QA`.
   If `true`: `.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] skip_qa false` → § 8

3. **Read state**: `.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .qa_labels`

4. **Route**:
   - QA labels present → § 6
   - No QA labels → § 8

## 6. QA Checks

**Skip if** no QA labels. → § 8

1. **Check labels**. See issue tracker label configuration (project-level).

2. **Determine sequence**: QA agent types are configurable per project. Example mappings: `needs-safety-audit` → safety audit agent, `needs-perf-test` → performance QA agent, `needs-review` → architecture review agent, `design` → visual QA agent.

**For each QA agent, execute steps 3–5:**

3. **Delegate to QA agent** (`[QA_AGENT]`) with the prompt below:

   <delegation_format>
   Follow workflow: .agents/skills/reviewer/workflows/qa-review.md

   Issue: [ISSUE_ID]
   Tracker: [TRACKER] [OWNER/REPO]
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

   Omit `[OWNER/REPO]` when `TRACKER=linear`.

4. **Wait for completion.**

5. **Process agent return.** Agent returns `verdict`, `json_path`, and (for performance QA) `benchmark_commit`.
   - **Update state**: `.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "[json_path]"`
   - If `benchmark_commit` is not "none", verify: `git -C [WORKTREE_PATH] log -1 --oneline [SHA]`.
   - **If performance QA agent**: post benchmark report as issue comment — **Linear only**; GitHub: `gh issue comment ${ISSUE_ID#issue-} --body "[PERF_REPORT]"`:
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
- **`qa_agent`**: pass QA agent name to `workflows/dev-fix.md` context.
- **Route after fix**:

   | `files_changed` | `risk_flags` | `scope` | Route |
   |-----------------|--------------|---------|-------|
   | `0` | — | — | § 8 |
   | `>0` | non-empty | any | § 2 (full PR review) |
   | `>0` | empty | `production` | § 6 (focused QA re-check) |
   | `>0` | empty | `support` | § 8 |

## 8. Review Summary

**Read state**: `.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .json_paths`

**Skip if** json_paths empty. Output: "No review items." → § 9

1. **Read all JSON files** from state `json_paths`.

2. **Collect issue suggestions** — items where `category == "issue"` from review JSONs (defer to § 9 audit). Fix suggestions already handled in § 4 / § 7.

3. **Deduplicate** by (location, description) — keep first, note all sources.

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

1. **Read state**: `.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .escalated_items`

2. **Extract discovered work** from completion summaries — **Linear only**; GitHub/ad-hoc: parse the dev agent's return message for a "Discovered Work" section instead:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
   ```
   Read matching comments from the JSON output with the filter `.[] | select(.body | contains("Discovered Work")) | .body`.
   If bundled: also run `.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle` and read `.children[].id` from the JSON output.
   Parse "Discovered Work" bullets into audit items with `origin: "discovered"`, `found_by: [agent]`. Skip if section absent or "(Skip if none)".

   **Filter out workflow-internal handoffs.** Skip any Discovered Work bullet whose leading token after `- ` is one of the markers below. The marker MUST be the first token — anything before it (such as `[Type]`) prevents the match. The canonical bullet form is documented in `dev/workflows/dev-implement.md` § 9:

   - `- handoff_to_submit_pr: [doc] PR-body content for X (estimate: N)` — produced by the upcoming `submit-pr` step.
   - `- handoff_to_merge_pr: [process] ... (estimate: N)` — produced by the eventual `merge-pr` step.
   - `- current_workflow_action: [doc] ... (estimate: N)` — item the current `review-pr` cycle will handle itself.

   Match by exact regex `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s`. Drop silently from the audit-input file in step 4 — these are already in-flight in the current workflow.

   This filter applies only to Discovered Work bullets. Escalated items and `category: "issue"` suggestions remain in the audit input unchanged.

3. **Skip if** no issue suggestions AND escalated_items empty AND no discovered work items. → § 10

4. **Build audit-input file** from:
   - Escalated items from state file
   - Issue suggestions (`category: "issue"` from review JSONs in state `json_paths`)
   - Discovered work items (from step 2, `origin: "discovered"`)

5. **Write file**: `[WORKTREE_PATH]/tmp/audit-start-YYYYMMDD-HHMMSS.json`
   - Schema: `.agents/skills/project-management/schemas/audit-issues-input.md`
   - Set `tracker.type` to the resolved `TRACKER`; for GitHub items also set `tracker.repository` to `[OWNER/REPO]`. audit-issues executes every preflight and approved action through this tracker — GitHub items complete the audit via `gh`/github-skill commands without Linear.

6. **Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 9 step 7`

7. **Update state** — for each created issue from audit output:
   ```bash
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] audit_issues_created "[CREATED_ISSUE_ID]"
   ```

## 10. Delegate Pending Children

**Skip if** `TRACKER=github` (no Linear parent/child bundle model). → § 11

1. **Query pending children**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [ISSUE_ID] --recursive --pending --format=safe
   ```

2. **Skip if** no pending children → § 11.

3. **Capture pre-delegate state**:
   ```bash
   .agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
   ```

4. **Delegate immediately.** Do **not** surface a Defer/Skip prompt — § 10 is mandatory once § 9 created `make_child` issues under `[ISSUE_ID]`.

   If delegation is skipped (user override, escalation), § 10 must FIRST detach every `audit_issues_created` entry from `[ISSUE_ID]` before returning to § 11 — otherwise `merge-pr.md` will cascade-Done them.

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.audit_issues_created // []'
   ```
   Read each array item as `[CHILD_ID]`, then for each:
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
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pre_delegate_sha
   .agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] $PRE_SHA
   ```
   Use the workflow-state output as `PRE_SHA`.

   | `risk_flags` | `scope` | Action | Route |
   |--------------|---------|--------|-------|
   | non-empty | any | — | → § 1 (full re-review) |
   | empty | `production` | `.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] skip_qa true` | → § 1 |
   | empty | `support` | — | → § 11 |

## 11. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — summary in § 8.
