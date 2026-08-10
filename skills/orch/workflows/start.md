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
| Tracker | [linear\|github] |
| Work item | [ID or OWNER/REPO#N] |
| Reason | [why this is next] |

</output_format>

## 3. Resolve Work Item

### Linear

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

**Container check** — mechanical, from the `--with-bundle` output. The issue is a CONTAINER when it carries the `agent:multi` label, or when it has children and its title carries no `(one PR)` marker. A container is never the work item: it gets no worktree, no session, and no PR — each child is the PR unit and the container closes last (via `merge-pr.md`, after its final child).

- **Container** → do not proceed with it. List its unblocked children (`.children[]` with a non-terminal `state_type` and no incomplete blocker in `blocked_by`), pick one as the work item — or present them if the choice is not obvious — and re-run this section for the chosen child. Independent children may also run in parallel sessions (`workflows/parallel-check.md`).
- **Explicit single-PR bundle** (`(one PR)` in the title, or a leaf issue whose description carries an internal checklist) → the parent IS the work item: one session, one PR covering all children. This is the exception, not the default, and must be opted into via the marker.
- **Child of a container** → keep the child; it is the PR unit. (Only for a child of a `(one PR)` bundle does the old rule apply: use the parent unless the user explicitly chose the child.)

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
3. Check whether the issue worktree already exists:
   ```bash
   .agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
   .agents/skills/worktree/scripts/worktree path [ISSUE_ID]
   ```
   If it exists, treat it as active ownership: inspect its branch/PR and monitor or coordinate with the existing owner. Do not spawn a second implementer. Only the confirmed owning session may run `create [ISSUE_ID] --reuse`.
4. When no issue worktree exists, create it with one command whose exit status is checked directly:
   ```bash
   # Linear
   .agents/skills/worktree/scripts/worktree create [ISSUE_ID]

   # GitHub
   .agents/skills/worktree/scripts/worktree create issue-[N]
   ```
   Exit 75 means a branch or open PR already owns the issue even though the configured path was absent; inspect/monitor it instead of delegating. Use the successful create output as `WT_PATH`.

5. **Session-guard lease** — claimed by the working session in `initialize.md` § 1 step 4, which every § 5 route (continue-here, handoff, manual) reaches through `start-worktree.md` § 1. This launcher step never claims: a lease means "a live session is working here", and for a handoff that session is the launched one.

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
| Next | [continue-here\|handoff\|codex-app\|manual] |

</output_format>

## 6. End

If launched as handoff, stop after launch.
