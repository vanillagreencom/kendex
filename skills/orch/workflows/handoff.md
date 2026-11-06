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

- **Deduplicate.** Keep one entry per issue id. Apply the Ancestor gate to each final launch item.

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

Read `orch-env ORCH_LANE_PREFERENCE ""` for the program's default harness, model and effort. Select the model class and effort through [Model class](../references/skill-rules.md#delegation), and keep a model the brief names. Choose each item's account under [oversee.md](oversee.md) § 3 Lane directive step 3, through the preference walk or the account judge, and its permission posture for this task: the settings' `ORCH_LAUNCH_PERMISSION`, `bypass` unless set, or a `permission` word in the request. Launch each item with one `launch-lane` request, composed as [oversee.md](oversee.md) § 3 Lane directive step 4 composes it, its brief a file ([lane-directive.md § Brief file](../references/lane-directive.md#brief-file)):

```bash
.agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
```

The runtime records every lane it launches in the fleet state, `orch-runtime state path --fleet`, and refuses `record-missing` until that state exists: where `orch-runtime state exists --fleet` answers false, run `orch-runtime state init --fleet` first. A handoff starts no watch, so nothing here monitors what it launches.

An item whose brief authorizes a project-scope `kendex refresh` or `kendex apply` in its lane, a refresh lane, takes `refresh: true` in its request at its launch and at every relaunch: the lane's session-start drift notice then says those commands run there with the CLI's own `--lane-refresh` instead of saying they never run there. Every launch clears `WAYLAND_DISPLAY`, `DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE` from the lane's process (`LAUNCH_SCRUB` in `skills/agent-runtime/runtime/src/launch.rs`), and a wake keeps a recorded `live_display` grant ([oversee-lanes.md § Talking to a lane](../references/oversee-lanes.md#talking-to-a-lane)). When an item must change harnesses, its new brief includes this sentence: `Continue [ITEM] from the prior [HARNESS] transcript at [TRANSCRIPT_PATH]; read it first, then resume the orch workflow.`

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
