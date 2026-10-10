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

**Container preflight** — Linear items only, before any worktree is created.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ITEM] --with-bundle
```

Apply the Ancestor gate ([references/skill-rules.md § Coordination](../references/skill-rules.md#coordination)) per item. A container drops off the launch list and is replaced by its unblocked DIRECT children (`depth == 0`), each of which reruns this preflight. A blocked item drops off with its live blockers named.

- **The explicit-choice exception survives.** An enclosing `(one PR)` ancestor makes that bundle the launch item only for container-expanded entries; an item the USER supplied explicitly stays the launch item, still subject to the Ancestor gate.
- **Deduplicate, then collapse ancestry.** Keep one entry per issue id, marking it EXPLICIT whenever any duplicate was user-supplied. Then, when one final item is an ancestor bundle of another, keep only the bundle. Apply the Ancestor gate to each final launch item.

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

### Terminal harnesses

**Skip if** `harness == codex-app`.

Read `orch-env ORCH_LANE_PREFERENCE ""` for the program's default harness, model and effort. Size up when the item needs a stronger model, never down, and keep a model the brief names. Without a model in the launch, `open-terminal` uses [lane-directive.md § Lane preference](../references/lane-directive.md#lane-preference). Unset, choose the model and effort as before. Choose the permission posture for this task. Explicit model and effort choices are sized to the item's difficulty and, for a claude, codex or copilot item or a pi item on a `pi-claude/` or `github-copilot/` model, to its account lane under [oversee.md](oversee.md) § 3 Lane directive. An `open-terminal` launch under a `--lane` names a model, and an effort where its harness has an effort flag; `open-terminal --help` holds the flag each harness takes, marks the harness with no effort flag, and refuses a lane launch that names either none. The commands below pass no `--cmd`, so those words go in `--launch-flags`; a launch that does pass `--cmd` names them inside that command instead, and `--launch-flags` beside it are refused as reaching nothing. Such a launch carries its brief as a file, `--brief-file [BRIEF_PATH]`, placed as `{brief}` in the command, never typed into the command's quotes ([lane-directive.md § Brief file](../references/lane-directive.md#brief-file)). A claude lane must include a permission-bypass flag (`open-terminal` warns when the flags omit one, and leaves a `--cmd` launch alone, its own argv carrying the posture).

Omit `--tmux` and `--ghostty` unless the user explicitly requests a terminal-mode override. With neither flag `open-terminal` auto-detects the mode: tmux windows when `$TMUX` or `ORCH_TMUX_SESSION` is set, GUI terminals otherwise. What the screen looks like is not a request; `--ghostty` inside tmux moves the lane out of the workspace.

```bash
.agents/skills/orch/scripts/open-terminal --tracker linear --harness [HARNESS] --launch-flags "[FLAGS]" [ISSUE_IDS]
```

```bash
.agents/skills/orch/scripts/open-terminal --tracker github --repo [OWNER/REPO] --harness [HARNESS] --launch-flags "[FLAGS]" [NUMBERS]
```

Neither command passes `--state-dir`, so the launcher records no lane and creates no oversee state: a handoff is launch-only, and nothing here monitors what it starts. A fleet launch names its state per [oversee.md](oversee.md) § 3 Lane record.

`--lane <config-dir>` launches under that account, `--lane <alias>` under a lane named in `ORCH_LANE_ALIASES`, and `--lane auto` (or `auto:<harness>`) under `lanes pick`'s choice, re-picked before each further tmux item. A named lane that `ORCH_LANE_EXCLUDE` or `ORCH_LANE_RETIRE` covers is refused. Which lane and which flags: [oversee.md](oversee.md) § 3 Lane directive. An item whose brief authorizes a project-scope `kendex refresh` or `kendex apply` in its lane, a refresh lane, takes `--lane-refresh` at its launch and at every relaunch: the lane's session-start drift notice then says those commands run there with the CLI's own `--lane-refresh` instead of saying they never run there. When an item must change harnesses, its new brief includes this sentence: `Continue [ITEM] from the prior [HARNESS] transcript at [TRANSCRIPT_PATH]; read it first, then resume the orch workflow.`

### Codex Desktop threads

**Skip if** `harness != codex-app`. Use this branch only inside a runtime that exposes the `codex_app` thread tools; never emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual instructions.

```bash
.agents/skills/orch/scripts/resolve-base-branch .
```

For each item, create exactly one thread with `codex_app.create_thread`, targeting the current saved project with a separate worktree environment for that issue: never run all issues in the controller thread, never launch several in one child thread, and never pass several issue IDs to one thread. Set the worktree `startingState` to `{type: "branch", branchName: "[BASE_BRANCH]"}`; use `working-tree` only when the user explicitly asks for a dirty local snapshot. The prompt is `$orch start [ISSUE_ID]` (or `$orch start github [OWNER/REPO]#[N]`). If the runtime creates the thread before accepting a prompt, call `codex_app.send_message_to_thread` once with that same prompt. Title the thread with the item identifier when `codex_app.set_thread_title` is exposed, and record the returned thread ID.

Full contract: [references/codex-runtime.md](../references/codex-runtime.md).

## 3. Return

Output: [Lane Output](../references/skill-rules.md#lane-output).

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
