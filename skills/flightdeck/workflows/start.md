# Start Session Workflow

Initialize development session, display status, select work, evaluate research, create worktree, and hand off to worktree session.

This is the legacy issue-mode start workflow. For ad-hoc or workflow sessions that are not tied to an issue/worktree, use `scripts/flightdeck-session start` or `flightdeck session start`, then supervise with `workflows/session-watch.md` and `workflows/session-handle-prompt.md`.

## 1. Initialize Session

### 1.1 Sync Cache

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
```

### 1.2 Present Dashboard

1. **Run**: `FLIGHTDECK_PREFLIGHT=1 .agents/skills/orchestration/scripts/session-init`

   The `FLIGHTDECK_PREFLIGHT=1` signal tells session-init to also check the runtime deps flightdeck itself needs (currently: `bun`, the runtime for every trampolined script on the default TS path plus the claude-channel and codex-bridge transports). If bun is missing the dashboard adds a hard warning — trampolines fail without it. Only setups that have explicitly opted out via `FLIGHTDECK_USE_TS=0` (legacy bash path) can proceed without bun, and channel transports there still fall back to tmux keystrokes.

2. **Output the result exactly as shown** — no reformatting, no additions, no commentary before/after the dashboard. The script output IS the dashboard. Script output uses backticks and markdown syntax.

3. **If build errors or auth failures** → fix locally before proceeding to § 1.3.

4. **If dashboard shows "Worktree session"** → STOP. Wrong workflow. Use the orchestration workflow from the worktree pane instead: [`../../orchestration/workflows/start.md`](../../orchestration/workflows/start.md).

### 1.3 Select Work

**Skip if** `start [ISSUE_ID]` provided → § 1.4

1. **Check recommendation**: The `Recommended` line shows the priority action.

2. **Present options**:

   | Recommendation | Action |
   |----------------|--------|
   | `research-complete [ISSUE_ID]` | `⤵ .agents/skills/project-management/workflows/research-complete.md [ISSUE_ID] § 1-7 → § 1` |
   | Complete [Project]: audit-issues project-order | `⤵ .agents/skills/project-management/workflows/audit-issues.md project-order § 1-9 → § 1` |
   | Activate project: audit-issues project-order | `⤵ .agents/skills/project-management/workflows/audit-issues.md project-order § 1-9 → § 1` |
   | Plan cycle: audit-issues → cycle-plan | `⤵ .agents/skills/project-management/workflows/audit-issues.md project § 1-9`, then `⤵ .agents/skills/project-management/workflows/cycle-plan.md § 1-6 → § 1` |
   | `parallel-check "Project"` | `⤵ workflows/parallel-check.md "Project" § 1-11 → § 1` |
   | Start in parallel: [ISSUE_ID], ... | Ask user: `Start [ISSUE_ID] only` (→ § 1.4) \| `Launch parallel group` (capture `[ISSUE_IDS]` → § 1.4) |
   | Start [ISSUE_ID] | Capture issue ID → § 1.4 |

   Note: per-issue actions (`ci-fix`, `review-pr-comments`, `merge-pr`) are not surfaced here. Master directs the per-issue agent in its tmux pane to handle those — see `patterns/prompt-handlers.md`. If a PR genuinely needs out-of-session attention, the user invokes the orchestration command directly from a worktree pane.

3. **Ask user** with recommended as first option. The `👉` line format is `👉 Label — reason`. Use text before `—` as the option label, text after `—` as the option description.

### 1.4 Handle Uncommitted Files

**Skip if** no uncommitted files warning in dashboard → § 2

1. **Present options**:
   - Stash first → `git stash -m "before [ISSUE_ID]"`
   - Commit first → `git add -A && git commit`
   - Commit and push first → `git add -A && git commit && git push`

2. **Ask user**

---

## 2. Prepare Issue

### 2.1 Parallel Group Iteration

**Skip if** single issue

**Pre-resolve**: For each issue in `[ISSUE_IDS]`, check `parent_id` (from `--with-bundle`). If set, replace with parent. Deduplicate. Update `[ISSUE_IDS]` with resolved top-level set.

For each issue in `[ISSUE_IDS]`, run § 2.2-2.5:
1. Per-issue exits (→ § 3) mean "done with this issue, continue loop"
2. Bundle completed (`pending_count == 0`) → remove from set, skip to next
3. § 2.4 auto-decompose (skip asking user)

After all issues processed → § 3.

### 2.2 Get Issue

1. **Fetch issue data** (from `start [ISSUE_ID]` argument or § 1.3 selection):
   ```bash
   PARENT_ID=$(.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle | jq -r '.parent_id // empty')
   ```

2. **If `PARENT_ID` set** (single-issue only; parallel groups pre-resolved in § 2.1): Use parent issue, restart § 2

### 2.3 Route by Bundle Status

1. **Check bundle status**:

   | Condition | Action |
   |-----------|--------|
   | `.children` empty | Single issue → § 3 |
   | `.pending_count == 0` | All done → mark parent complete, § 1 |
   | Otherwise | Bundle with pending work ↓ |

2. **If bundle**: If `.agent` empty, infer agent from component paths (project-configurable) or ask user

3. **Present bundle**:

   <output_format>

   📦 Bundle: [ISSUE_ID] | 📋 N remaining | 🐲 [AGENT]
   ↳ [SUB_ISSUE_1]: [TITLE]
   ↳ [SUB_ISSUE_2]: [TITLE] → blocks [SUB_ISSUE_4]
      ↳ [SUB_ISSUE_4]: [TITLE]  ← nested

   </output_format>

### 2.4 Validate Bundle Scope Coverage

1. **Parse parent description** for `## Requirements` section

2. **If parent has `## Sub-Issues`** or no `## Requirements` → § 3 (scope already decomposed)

3. **Present warning**: "Parent [ISSUE_ID] has implementation requirements not decomposed into sub-issues."

4. **Ask user**: `Decompose now` | `Proceed anyway`
   - **Decompose now** → § 2.5
   - **Proceed anyway** → § 3

### 2.5 Decompose Parent Scope

1. **Extract requirements** from parent `## Requirements`, tag each bullet with domain (project-configurable domain categories)

2. **Check existing children** (from § 2.3): Map each child's scope to parent requirements it covers. Mark covered requirements as satisfied.

3. **Create sub-issues for uncovered requirements only** — group by domain → one sub-issue per domain. Sub-issues must be in parent's project.

4. **Title format**: `[Domain verb]: [scope]`

5. **Set labels**: `agent:[TYPE]` per domain, appropriate stack labels

6. **Set blocking relations**: infer dependency order from parent requirements, domain ownership, and existing child blockers. Include relations to/from existing children; ask the user if sequencing is ambiguous.

7. **Rewrite parent description**: Replace `## Requirements` with `## Sub-Issues` listing ALL children (existing + new), add `## Context`, remove implementation-level detail.

8. **Set parent label** to `agent:multi` if 2+ domains across all children

9. **Re-present bundle** (§ 2.3 step 3) → § 3

---

## 3. Evaluate Research Requirements

### 3.1 Parallel Group Evaluation

**Skip if** single issue

1. Run § 3.2 per issue
2. Spawn § 3.3 consultations in parallel (one task per issue)
3. Present § 3.4 as combined table (skip asking user)
4. Research-needed → collect per-issue context (§ 3.2/3.3 fields) as `batch_issues`, run § 3.5 once, remove from `[ISSUE_IDS]`

### 3.2 Extract Research References

1. **Parse issue description(s)** for:
   - Research document paths → list as `[RESEARCH_PATHS]`
   - Decision references → list as `[DECISION_IDS]` — read from individual decision files
   - `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` → find linked decisions not explicitly referenced

2. **If bundled (from § 2.3)**: Parse parent + all sub-issue descriptions. Dedupe paths/refs.

### 3.3 Consult Development Agent(s)

1. **Determine consultation agent(s)**:
   - If parent has `agent:multi`: consult **all distinct `agent:[TYPE]` agents** from children (parallel agent launches, ephemeral)
   - Otherwise: consult the agent from `agent:[TYPE]` label

2. **Delegate consultation** to `[AGENT_TYPE]` agent(s). For multi-agent, delegate in parallel. Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

   <delegation_format>
   CONSULTATION ONLY.

   Read issue: .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID].

   [If bundle from § 2.3:]
   Sub-issues (tree):
   ↳ [SUB_ISSUE_1]: .agents/skills/linear/scripts/linear.sh cache issues get [SUB_ISSUE_1]
   ↳ [SUB_ISSUE_2]: .agents/skills/linear/scripts/linear.sh cache issues get [SUB_ISSUE_2]
      ↳ [SUB_ISSUE_3]: .agents/skills/linear/scripts/linear.sh cache issues get [SUB_ISSUE_3]  ← nested child
   [End if]

   - Read: [RESEARCH_PATHS]
   - Run: .agents/skills/decider/scripts/decisions search --issue [ISSUE_ID] (find linked decisions)
   - Read: [DECISION_FILES]
   - Read: Relevant architecture docs
   - Read: Relevant in-project code

   Analyze implementation requirements. Check for these triggers:

   1. **Architectural gaps**: Missing infrastructure/patterns needed for implementation
   2. **Multiple approaches**: >1 valid design with trade-offs (latency/memory/complexity)
   3. **Cross-component integration**: New patterns bridging multiple subsystems
   4. **Performance-critical decisions**: Hot path choices affecting latency budgets
   5. **Unclear requirements**: Ambiguous behavior, edge cases, or constraints

   **Bias toward research**: If ANY trigger present OR uncertain → recommend research.

   Reply format (choose ONE):
   - `No research needed` — only if: trivial implementation, clear single approach, no gaps
   - `Existing sufficient` — only if: all approaches/trade-offs documented in research_paths or decision_refs
   - `Research: [QUESTIONS]` — architectural gaps, multiple approaches, performance trade-offs, unclear requirements
   </delegation_format>

3. **Capture for resume**: If single agent, store agent reference as `[CONSULTATION_AGENT_NAME]` for resume in § 3.5. If multi-agent, skip (research-issue uses fresh delegation for multi-domain).

### 3.4 Present Result and Confirm

1. **Present summary**:

   <output_format>

   | Field | Value |
   |-------|-------|
   | 🎯 Issue | [ISSUE_ID] - Title |
   | 📦 Bundle | N sub-issues (M nested) — if bundle |
   | | ↳ [SUB_ISSUE_1]: [TITLE] &#124; blocks: [SUB_ISSUE_2] |
   | | ↳ [SUB_ISSUE_2]: [TITLE] &#124; blocked by: [SUB_ISSUE_1] |
   | |    ↳ [SUB_ISSUE_4]: [TITLE]  ← nested |
   | 🐲 Agent | [AGENT] |
   | 📚 Research | [ref\|none] |
   | 💬 Consultation | [RESPONSE] |

   </output_format>

2. **Ask user**: `Continue` | `Create research issue`

3. **Route**: `Continue` → § 3.6 → § 4 | `Create research` → § 3.5

### 3.5 Create Research Issue(s) (if requested)

Invoke workflow: `⤵ .agents/skills/project-management/workflows/research-issue.md § 1-5 → § 1` with context:

**If single issue**:
- `topic`: from § 3.3 agent "Research:" response
- `questions`: from § 3.3 agent response
- `domains`: from children's `agent:[TYPE]` labels if `agent:multi`, else from issue's stack labels
- `project`: from `.agents/skills/linear/scripts/linear.sh cache projects list --state started`
- `blocked_issue`: [ISSUE_ID] from § 2
- `type`: Targeted (1 domain) or Pervasive (2+ domains)
- `consultation_agent_name`: from § 3.3 step 4 if single agent (omit for multi-agent)
- `research_paths`: from § 3.2 [RESEARCH_PATHS]
- `decision_ids`: from § 3.2 [DECISION_IDS]

**If batch** (from § 3.1):
- `project`: from `.agents/skills/linear/scripts/linear.sh cache projects list --state started`
- `batch_issues`: list of per-issue objects, each containing: `topic`, `questions`, `domains`, `blocked_issue`, `type`, `consultation_agent_name`, `research_paths`, `decision_ids` — all sourced from § 3.2/3.3 per issue

Research issues block their `blocked_issue`. After `workflows/research-issue.md` completes, the issue is labeled `agent:researcher` and delegated to the researcher agent. Continue with `research-complete [ISSUE_ID]` after findings exist, or let the managed workflow invoke it directly.

After `workflows/research-issue.md` returns → § 3.6.

### 3.6 Clean Up Consultation

**Skip if** no consultation agent was created in § 3.3.

Terminate the consultation agent if it's still running.

---

## 4. Delegate to Specialist Agent(s)

### 4.0 Select Launch Profile

Use this whenever § 4.3 or § 4.4 launches a pane through `open-terminal`.

1. **Recommend a default profile** by issue complexity:

   | Work type | Recommended profile | Command flags |
   |-----------|---------------------|---------------|
   | Normal/complex implementation | Claude Code, strongest reasoning | `--harness claude --model 'opus[1m]' --effort max` |
   | OpenAI/Codex-preferred implementation | Codex, strongest reasoning | `--harness codex --model gpt-5.5 --effort xhigh` |
   | Pi-native orchestration / Pi extension work | Pi, strongest OpenAI reasoning | `--harness pi --model openai-codex/gpt-5.5 --effort xhigh` |
   | OpenCode-preferred implementation | OpenCode, strong model + variant | `--harness opencode --model openai/gpt-5.5 --effort xhigh` |
   | User wants their configured defaults | Harness default | `--harness [HARNESS]` only |

   Notes:
   - `open-terminal` maps effort per harness: Claude → `--effort`, Codex → `-c model_reasoning_effort=...`, Pi → `--thinking`, OpenCode → `--variant`. `max` maps to `xhigh` for Codex/Pi and OpenCode OpenAI/Codex models; OpenCode `off` maps to `none`.
   - If the user chooses a model/effort different from the recommendation, pass exactly their values.
   - If the user chooses harness defaults, omit `--model` and `--effort`.

2. **Ask user** for launch profile. Include the recommendation first, then: `Claude max` | `Codex xhigh` | `Pi xhigh` | `OpenCode xhigh` | `Harness defaults` | `I'll launch it myself` | custom model/effort.

3. **Capture** `[HARNESS]`, optional `[MODEL]`, optional `[EFFORT]`. Build `[LAUNCH_FLAGS]` as:
   ```bash
   --harness [HARNESS] [--model MODEL] [--effort EFFORT]
   ```

4. **For parallel launches**, ask whether to use one profile for all selected issues or choose per issue.
   - **One profile** → one `open-terminal [ISSUES...] [LAUNCH_FLAGS]` command.
   - **Per issue** → run one `open-terminal [ISSUE] [LAUNCH_FLAGS_FOR_ISSUE]` command per issue. This is intentional: each pane/session can use a different harness/model/effort.

### 4.1 Check Issue Type

**Route**:
- **Parallel group** → § 4.4
- **Research issues** (`research` label) → § 4.2
- **All other issues** → § 4.3

### 4.2 Research Issues (researcher execution)

1. **Check assets and findings**: research prompt file and `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md` status for [ISSUE_ID]

2. **If assets missing** → Invoke workflow: `⤵ .agents/skills/project-management/workflows/research-issue.md § 2 → § 4` (Prepare Assets then Delegate to Researcher)

3. **If assets exist and findings missing** → Invoke/delegate `project-management/workflows/research-issue.md § 4 Delegate to Researcher`. Do not create a normal implementation worktree.

4. **If findings exist** → `research-complete [ISSUE_ID]` → § 1

### 4.3 Create Worktree

Worktree creation is idempotent: existing worktrees are reused (rebased onto latest main), and PRs with matching branches are auto-detected. Fails on rebase conflicts.

1. **Run check**: `.agents/skills/worktree/scripts/worktree check` — returns `{uncommitted, unpushed, unpushed_commits}`

2. **If uncommitted** → present uncommitted options (stash/commit/push)

3. **If unpushed** → Ask user: `Push unpushed commits to the default branch?` (show commits), then:
   ```bash
   DEFAULT_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
   [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
   git push origin "$DEFAULT_BRANCH"
   ```

4. **Active work conflict scan**: Check for agent overlap with in-progress worktrees.
   ```bash
   .agents/skills/worktree/scripts/worktree list
   ```
   For each active worktree issue: `.agents/skills/linear/scripts/linear.sh cache issues get [WT_ISSUE] --format=compact` → compare `agent` with current issue.
   - **No overlap** → continue
   - **Same agent** → `.agents/skills/flightdeck/scripts/parallel-groups needs-refresh [ISSUE_ID] [WT_ISSUE]`. If exit 1 (fresh, cached safe) → continue. Otherwise ask user: `flightdeck parallel-check [ISSUE_ID] [WT_ISSUE]` | `Continue anyway`. If check → `⤵ workflows/parallel-check.md [ISSUE_ID] [WT_ISSUE] § 1-11 → § 4.3`. If conflicts verdict → warn with details, do not block.

5. **Create worktree**: `WT_PATH=$(.agents/skills/worktree/scripts/worktree create [ISSUE_ID])`

6. **Launch**: Run § 4.0 to select `[LAUNCH_FLAGS]`.
   - **Profile selected**: `.agents/skills/flightdeck/scripts/open-terminal [ISSUE_ID] [LAUNCH_FLAGS]`, then `⤵ workflows/watch.md [ISSUE_ID] § 1-9 → § 1` — `watch.md § 1` spawns `flightdeck-daemon` (idempotent, flock-protected) which drives wake delivery for the rest of the session. Enter master oversight loop until the spawned pane reaches a terminal state, then return to dashboard.
   - **Manual**: Show the recommended command and worktree path so the user can run it themselves. → § 1.
   - **I'll launch it myself** → § 1.

### 4.4 Launch Issue(s)

`[ISSUE_IDS]` contains only issues that passed § 2-3 (research-needed removed in § 3).

1. **If 0 issues in `[ISSUE_IDS]`** → § 1

2. **Inform user**:

   <output_format>
   If you are using a desktop app (no terminal), switch to the worktree(s) yourself and run `/orchestration start [ISSUE_ID]` (or `$orchestration start [ISSUE_ID]` on Codex, `/skill:orchestration start [ISSUE_ID]` on Pi).
   </output_format>

3. **Ask user**: `Launch [N] issues` | `Select subset` | `I'll launch them myself` | `Cancel`
   - **Launch**: Run § 4.0 for all `[ISSUE_IDS]`. If one profile: `.agents/skills/flightdeck/scripts/open-terminal [ISSUE_IDS] [LAUNCH_FLAGS]`. If per issue: run one `open-terminal [ISSUE] [LAUNCH_FLAGS_FOR_ISSUE]` per issue. Then `⤵ workflows/watch.md [ISSUE_IDS] § 1-9 → § 1` — `watch.md § 1` spawns the daemon for the session and drives wake delivery for the spawned set.
   - **Select subset**: Ask user with individual issues as options (multiSelect), then run § 4.0 for `[SELECTED_ISSUES]`. If one profile: `.agents/skills/flightdeck/scripts/open-terminal [SELECTED_ISSUES] [LAUNCH_FLAGS]`. If per issue: run one `open-terminal [ISSUE] [LAUNCH_FLAGS_FOR_ISSUE]` per issue. Then `⤵ workflows/watch.md [SELECTED_ISSUES] § 1-9 → § 1`.
   - **Manual**: Show the recommended command(s) so the user can run them themselves. → § 1.
   - **Cancel** → § 1

4. **→ § 1** (restart dashboard in current session, only reached on Manual / Cancel paths).
