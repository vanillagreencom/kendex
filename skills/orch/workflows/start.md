# Start Workflow

Start one work item. Never watches or manages other sessions.

## Inputs

| Command | Flow |
|---------|------|
| `start` | dashboard → select one item |
| `start [LINEAR_ID]` | prepare Linear issue → handoff or worktree run |
| `start github OWNER/REPO#N` | prepare GitHub issue → handoff or worktree run |
| `start new ...` | `workflows/start-new.md` |

## 1. Route

1. If args start with `new`, invoke `workflows/start-new.md`.
2. Parse explicit work item args before checking cwd:
   - If args start with `github`, set `tracker=github`, parse `[OWNER/REPO]` and `[N]`, and set `ISSUE_ID=issue-[N]`.
   - Else set `tracker=linear`, parse `[ISSUE_ID]` if present.
   - If parsed `ISSUE_ID` starts with `issue-`, set `tracker=github`.
3. If cwd is a worktree, invoke `workflows/start-worktree.md` with the parsed context and stop.

## 2. Main Repo Dashboard

**Skip if** an explicit issue was provided.

1. Run:
   ```bash
   .agents/skills/orch/scripts/session-init
   ```
2. Output exactly as printed.
3. Pick one recommended work item. If multiple items exist, convert them into Linear/GitHub issues first; do not spawn a controller session.

<output_format>
### Milestone: Work Selected

| Field | Value |
|-------|-------|
| Tracker | [linear|github] |
| Work item | [ID or OWNER/REPO#N] |
| Reason | [why this is next] |
</output_format>

## 3. Resolve Work Item

### Linear

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

If the issue has a parent bundle, use the parent unless the user explicitly chose the child.

### GitHub

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,url,labels,state
```

If the issue is not open, stop and ask for a different item.

## 4. Prepare Worktree

1. Run:
   ```bash
   .agents/skills/worktree/scripts/worktree check
   ```
2. Resolve dirty main repo state with the user before creating worktrees.
3. Create/reuse worktree:
   ```bash
   # Linear
   WT_PATH=$(.agents/skills/worktree/scripts/worktree create [ISSUE_ID])

   # GitHub
   WT_PATH=$(.agents/skills/worktree/scripts/worktree create issue-[N])
   ```

## 5. Handoff Or Continue

Ask one action:

| Choice | Action |
|--------|--------|
| Continue here | Execute `workflows/start-worktree.md` using `[WT_PATH]` as the worktree context |
| Launch handoff | Invoke `workflows/handoff.md` |
| Launch Codex app | Invoke `workflows/handoff.md` with `harness=codex-app`; Codex Desktop creates one app thread per issue via `codex_app` thread tools |
| Manual | Print worktree path and exact `/orch start ...` command. For GitHub, use `/orch start github [OWNER/REPO]#[N]`; the worktree workflow normalizes it to `issue-[N]`. |

<output_format>
### Milestone: Worktree Ready

| Field | Value |
|-------|-------|
| Work item | [ID or OWNER/REPO#N] |
| Worktree | [WT_PATH] |
| Branch | [BRANCH] |
| Next | [continue-here|handoff|codex-app|manual] |
</output_format>

## 6. End

If launched as handoff, stop after launch.
