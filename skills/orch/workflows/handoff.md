# Handoff Workflow

Launch one or more independent work item sessions. This is launch-only.

## Inputs

| Input | Meaning |
|-------|---------|
| `tracker` | `linear` or `github` |
| `items` | Linear IDs or GitHub issue numbers |
| `repo` | Required for GitHub if `gh repo view` cannot resolve |
| `harness` | `claude`, `codex`, `codex-app`, `opencode`, or `pi`; optional when Codex app thread tools are exposed |

## 0. Resolve Harness

1. If the user explicitly selected a harness, use it.
2. Else if multiple items were provided and `codex_app.create_thread` is exposed, set `harness=codex-app`.
3. Else resolve the normal terminal harness for the current environment before launch.

## 1. Confirm Launch

**Container preflight** — before any worktree is created. Fetch the data
first (Linear items only):

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ITEM] --with-bundle
```

Per item, check the title FIRST — a `(one PR)` marker always makes it
launchable, even with `agent:multi`. Otherwise, an item with the
`agent:multi` label, or with children in the bundle read, is a CONTAINER:
drop it from the launch list and surface its unblocked DIRECT children
(`depth == 0` in the bundle's flattened `.children`) as the launchable
items instead — then rerun this preflight on each replacement, since a
direct child can itself be a container. Containers are never orchestrated
and never own a worktree; open-terminal would create one before the
launched session could refuse. The guard covers directly supplied
children too, via the Ancestor gate (SKILL.md → Coordination): EVERY
final launch item with a `parent_id` walks its full ancestor chain
(`.agents/skills/linear/scripts/linear.sh cache issues get
[ANCESTOR_ID]` per hop), classifying each — an enclosing `(one PR)`
ancestor makes that bundle the launch item ONLY for container-expanded
entries: an item the USER supplied explicitly stays the launch item (the
Ancestor gate's explicit-choice exception, as in `start.md`), still
gated on the unioned blockers below; all-container ancestry →
the item stays launchable only if it passes the unblocked test below
with the UNION of its own and every container ancestor's blockers;
blocked → drop it from the launch list and name its live blockers.

Resolve "unblocked" mechanically: collect each child's `blocked_by` ids
plus the container's own `blocked_by` (parent-carried cross-bundle
relations apply to every child), fetch those blockers' live states in one
call —

```bash
.agents/skills/linear/scripts/linear.sh issues bulk-get [BLOCKER_IDS]
```

— and a child is dispatchable only when its own `state_type` is
non-terminal and every collected blocker's `state_type` IS terminal
(`completed` or `canceled`) — terminality by type, never by
workspace-configurable state names.

Present:

<output_format>
### Launch Handoff

| Field | Value |
|-------|-------|
| Tracker | [linear|github] |
| Items | [ITEMS] |
| Harness | [HARNESS] |
| Follow-up | No monitoring; each launched session owns its work item |
</output_format>

## 2. Launch

### Codex Desktop Threads

**Skip if** `harness != codex-app`.

Use this branch only inside Codex Desktop or another runtime that exposes the `codex_app` thread tools. The Codex CLI does not expose these tools.

1. Resolve the base branch for the new app worktree:
   ```bash
   .agents/skills/orch/scripts/resolve-base-branch .
   ```
   Use the output as `BASE_BRANCH`.
2. Check whether app-created worktrees will expose generated Codex agents before launch:
   ```bash
   .agents/skills/orch/scripts/codex-app-agent-preflight .
   ```
   Read `.status`, `.severity`, `.ok`, `.requires_confirmation`, `.message`, `.tracked_agents`, and `.visible_agents` from the JSON output.
   - If `.severity` is `error`, stop the `codex-app` handoff and report the message.
   - If `.requires_confirmation` is `true`, present the warning message, explain that child threads may fall back to `worker`, and ask whether to continue anyway. Continue only after the user explicitly accepts. If the user declines, stop before creating child threads.
   - If `.ok` is `true`, continue without extra confirmation.
   Do not silently create child threads that will start without generated agent types and then fall back to `worker`.

For each item:

3. Resolve the exact start prompt:
   ```text
   # Linear
   $orch start [ISSUE_ID]

   # GitHub
   $orch start github [OWNER/REPO]#[N]
   ```
4. Create exactly one Codex app thread for that item with `codex_app.create_thread`.
   - The prompt must be exactly the start prompt from step 3.
   - Target the current saved project with a separate worktree environment for that issue. Do not run all issues in the controller thread, do not launch all issues in one child thread, and do not pass multiple issue IDs to a child thread.
   - Set the worktree `startingState` to `{type: "branch", branchName: "[BASE_BRANCH]"}`. Do not use `{type: "working-tree"}` for orch handoff unless the user explicitly asks for a dirty local snapshot; ignored generated harness files such as `.codex/agents` are not visible to the child at subagent-discovery time, causing generated reviewers/dev agents to fall back to `worker`.
   - The child thread may start in a detached Codex app worktree. Its first `start`/`initialize` step must parse `github OWNER/REPO#N` into `ISSUE_ID=issue-N` and run `session-init --json github OWNER/REPO#N`, which normalizes the branch before dev/review/submit.
   - Use the current model and thinking settings unless the user explicitly requested overrides.
5. If the runtime creates the thread before accepting the prompt, immediately call `codex_app.send_message_to_thread` for the returned `threadId` with the exact start prompt from step 3.
6. If `codex_app.set_thread_title` is exposed, title the thread with the item identifier, such as `orch [ISSUE_ID]` or `orch github #[N]`.
7. Record the returned thread ID.

If the `codex_app` thread tools are not exposed, stop the `codex-app` handoff and report that Codex Desktop thread tools are unavailable in this runtime. Do not substitute terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.

### Terminal Harnesses

**Skip if** `harness == codex-app`.

```bash
# Linear
.agents/skills/orch/scripts/open-terminal --tracker linear --harness [HARNESS] [ISSUE_IDS]

# GitHub
.agents/skills/orch/scripts/open-terminal --tracker github --repo [OWNER/REPO] --harness [HARNESS] [NUMBERS]
```

## 3. Return

<output_format>
### Milestone: Handoff Launched

| Field | Value |
|-------|-------|
| Launched | [N] |
| Items | [ITEMS] |
| Mode | [codex-app|terminal|unavailable] |
| Threads | [THREAD_IDS or none] |
| Worktrees | [WORKTREE_PATHS or none] |
| Monitoring | none |
</output_format>
