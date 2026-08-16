# Handoff Workflow

Launch one or more independent work-item sessions. Launch-only: nothing here monitors what it starts.

| Input | Meaning |
|-------|---------|
| `tracker` | `linear` or `github` |
| `items` | Linear IDs or GitHub issue numbers |
| `repo` | Required for GitHub when `gh repo view` cannot resolve it |
| `harness` | `claude`, `codex`, `codex-app`, `opencode`, or `pi` |

## 0. Resolve The Harness

An explicit user choice wins. Otherwise, with several items and `codex_app.create_thread` exposed, use `codex-app`; else resolve the normal terminal harness for this environment.

## 1. Gate The Launch List

**Container preflight** — Linear items only, before any worktree is created, because `open-terminal` creates one before the launched session could refuse.

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ITEM] --with-bundle
```

Apply the Ancestor gate ([SKILL.md § Coordination](../SKILL.md#coordination)) per item. A container drops off the launch list and is replaced by its unblocked DIRECT children (`depth == 0`), each of which reruns this preflight, since a direct child can itself be a container. A blocked item drops off with its live blockers named.

Two handoff-specific rules follow from expanding items:

- **The explicit-choice exception survives.** An enclosing `(one PR)` ancestor makes that bundle the launch item only for container-expanded entries; an item the USER supplied explicitly stays the launch item, still gated on the unioned blockers.
- **Deduplicate, then collapse ancestry.** Expanding a parent beside an explicitly supplied child re-adds that child, and launching both races one worktree. Keep one entry per issue id, marking it EXPLICIT whenever any duplicate was user-supplied. Then, when one final item is an ancestor bundle of another, keep only the bundle: two worktrees must never launch for work sharing one session and PR.

<output_format>

### Launch Handoff

| Field | Value |
|-------|-------|
| Tracker | [linear\|github] |
| Items | [ITEMS] |
| Harness | [HARNESS] |
| Follow-up | No monitoring; each launched session owns its work item |

</output_format>

## 2. Launch

**Every launched brief states the terminal condition**: the item is complete only when its PR is MERGED and its worktree cleaned up — an opened PR is not done. `open-terminal` renders it into every brief; briefs minted by hand (codex-app threads, oversee's non-terminal surfaces) carry it explicitly.

### Terminal harnesses

**Skip if** `harness == codex-app`.

Choose the launch flags for THIS task before launching — model, effort, and permission posture are a per-task judgment, not a stored default; size them to the item's difficulty. Handoff is unattended autonomy: a claude lane launched without a permission-bypass flag stalls at its first tool call with nobody there to answer, and `open-terminal` warns when the flags omit one.

```bash
.agents/skills/orch/scripts/open-terminal --tracker linear --harness [HARNESS] --launch-flags "[FLAGS]" [ISSUE_IDS]
```

```bash
.agents/skills/orch/scripts/open-terminal --tracker github --repo [OWNER/REPO] --harness [HARNESS] --launch-flags "[FLAGS]" [NUMBERS]
```

Add `--lane auto` (or `auto:<harness>`) to launch under the qualifying account with the fewest launches already in flight, headroom breaking the tie; it refuses to launch anything when no lane is under the usage threshold, rather than launching into a wall. On tmux it re-picks before each further item, so one command spreads a batch across accounts. `--lane <alias>` picks a named lane from `ORCH_LANE_ALIASES`, and `--lane <config-dir>` a literal one.

### Codex Desktop threads

**Skip if** `harness != codex-app`. Use this branch only inside a runtime that exposes the `codex_app` thread tools — the Codex CLI does not, and app handoff must not be emulated with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual instructions.

```bash
.agents/skills/orch/scripts/resolve-base-branch .
```

For each item, create exactly one thread with `codex_app.create_thread`, targeting the current saved project with a separate worktree environment for that issue: never run all issues in the controller thread, never launch several in one child thread, and never pass several issue IDs to one thread. Set the worktree `startingState` to `{type: "branch", branchName: "[BASE_BRANCH]"}` — a `working-tree` state can start the child before generated Codex agents are visible and force a `worker` fallback, so use it only when the user explicitly asks for a dirty local snapshot. The prompt is `$orch start [ISSUE_ID]` (or `$orch start github [OWNER/REPO]#[N]`) followed by the terminal condition above. If the runtime creates the thread before accepting a prompt, call `codex_app.send_message_to_thread` once with that same prompt. Title the thread with the item identifier when `codex_app.set_thread_title` is exposed, and record the returned thread ID.

Full contract: [references/codex-runtime.md](../references/codex-runtime.md).

## 3. Return

<output_format>

### Milestone: Handoff Launched

| Field | Value |
|-------|-------|
| Launched | [N] |
| Items | [ITEMS] |
| Mode | [codex-app\|terminal\|unavailable] |
| Threads | [THREAD_IDS or none] |
| Worktrees | [WORKTREE_PATHS or none] |
| Monitoring | none |

</output_format>
