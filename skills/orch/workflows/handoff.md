# Handoff Workflow

Launch one or more independent work-item sessions. This workflow only launches: nothing here monitors what it starts.

| Input | Meaning |
|-------|---------|
| `tracker` | `linear` or `github` |
| `items` | Linear IDs or GitHub issue numbers |
| `repo` | Required for GitHub when `gh repo view` cannot resolve it |
| `harness` | `claude`, `codex`, `copilot`, `pi`, or `codex-app` |

## 0. Resolve The Harness

An explicit user choice wins. Otherwise, with several items and `codex_app.create_thread` exposed, use `codex-app`. Else use this environment's terminal harness.

## 1. Gate The Launch List

1. Read a Linear item before creating any worktree:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues get [ITEM]
   ```

2. Apply the [Ancestor gate](../references/skill-rules.md#ancestor-gate) to each item.
   - Replace a container in the launch list with its unblocked direct children (`depth == 0`); each child takes step 1 again.
   - Drop a blocked item from the list, naming its live blockers.
3. Keep one entry per issue id, and apply the Ancestor gate to each final launch item.

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

1. Read `orch-env ORCH_LANE_PREFERENCE ""` for the program's default harness, model and effort. Select the model class and effort through [Model class](../references/skill-rules.md#model-class), and keep a model the brief names.
2. Choose each item's account through the preference walk or the account judge, under [oversee.md](oversee.md) § Lane directive step 3. The permission posture is `AGENT_RUNTIME_LAUNCH_PERMISSION` ([settings.md § Fleet lanes](../references/settings.md#fleet-lanes)), or a `permission` word in the request.
3. Where `orch-runtime state exists --fleet` answers false, run `orch-runtime state init --fleet`.
4. Launch each item with one `launch-lane` request, composed as [oversee.md](oversee.md) § Lane directive step 4 composes it. Its brief is a file ([lane-directive.md § Brief file](../references/lane-directive.md#brief-file)):

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

A refresh lane is an item whose brief authorizes a project-scope `kendex refresh` or `kendex apply` in its lane. Its request takes `refresh: true` at its launch and at every relaunch. The lane's session-start drift notice then says those commands run there with the CLI's own `--lane-refresh`.

Every lane launch clears the display variables from the lane's process. Where the brief needs the owner's live display, name `desktop: true` in the request, which keeps them. A relaunch keeps `desktop` ([lane-directive.md § Recovery relaunch](../references/lane-directive.md#recovery-relaunch)).

When an item must change harnesses, its new brief includes this sentence: `Continue [ITEM] from the prior [HARNESS] transcript at [TRANSCRIPT_PATH]; read it first, then resume the orch workflow.`

### Codex Desktop threads

**Skip if** `harness != codex-app`. Use this branch only inside a runtime that exposes the `codex_app` thread tools.

1. Resolve the base branch:

   ```bash
   .agents/skills/orch/scripts/resolve-base-branch .
   ```

2. For each item, create exactly one thread with `codex_app.create_thread`. Target the current saved project, with a separate worktree environment for that issue. Never run all issues in the controller thread, never launch several in one child thread, and never pass several issue IDs to one thread.
3. Set the worktree `startingState` to `{type: "branch", branchName: "[BASE_BRANCH]"}`. Use `working-tree` only when the user asks for a dirty local snapshot.
4. The prompt is `$orch start [ISSUE_ID]`, or `$orch start github [OWNER/REPO]#[N]`. Where the runtime creates the thread before it accepts a prompt, call `codex_app.send_message_to_thread` once with that prompt.
5. Title the thread with the item identifier where `codex_app.set_thread_title` is exposed, and record the returned thread ID.

The full contract: [codex-runtime.md § Codex Desktop app handoff](../references/codex-runtime.md#codex-desktop-app-handoff).

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
