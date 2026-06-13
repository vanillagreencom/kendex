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

For each item:

1. Resolve the exact start prompt:
   ```text
   # Linear
   $orch start [ISSUE_ID]

   # GitHub
   $orch start github [OWNER/REPO]#[N]
   ```
2. Create exactly one Codex app thread for that item with `codex_app.create_thread`.
   - The prompt must be exactly the start prompt from step 1.
   - Target the current saved project with a separate worktree environment for that issue. Do not run all issues in the controller thread, do not launch all issues in one child thread, and do not pass multiple issue IDs to a child thread.
   - The child thread may start in a detached Codex app worktree. Its first `start`/`initialize` step must parse `github OWNER/REPO#N` into `ISSUE_ID=issue-N` and run `session-init --json github OWNER/REPO#N`, which normalizes the branch before dev/review/submit.
   - Use the current model and thinking settings unless the user explicitly requested overrides.
3. If the runtime creates the thread before accepting the prompt, immediately call `codex_app.send_message_to_thread` for the returned `threadId` with the exact start prompt from step 1.
4. If `codex_app.set_thread_title` is exposed, title the thread with the item identifier, such as `orch [ISSUE_ID]` or `orch github #[N]`.
5. Record the returned thread ID.

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
