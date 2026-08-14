# Start Workflow

Prepare one work item from the main repo. Never watches or manages other sessions.

| Command | Flow |
|---------|------|
| `start` | pick one item → prepare |
| `start [LINEAR_ID]` | prepare Linear issue |
| `start github OWNER/REPO#N` | prepare GitHub issue |
| `start new ...` | `workflows/start-new.md` |

## 1. Route

1. Args starting with `new` → invoke `workflows/start-new.md`.
2. Parse explicit args before checking cwd: `github` → `tracker=github`, `[OWNER/REPO]`, `ISSUE_ID=issue-[N]`; otherwise `tracker=linear` with the parsed `[ISSUE_ID]`, promoted to `github` when it starts with `issue-`.
3. cwd is a worktree → invoke `workflows/start-worktree.md` with that context and stop.

## 2. Select Work Item

**Skip if** an explicit issue was provided.

Present the unblocked candidates from the tracker and pick one. If several are wanted, convert them to issues first and hand them off separately — this workflow prepares exactly one.

<output_format>

### Milestone: Work Selected

| Field | Value |
|-------|-------|
| Tracker | [linear\|github] |
| Work item | [ID or OWNER/REPO#N] |
| Reason | [why this is next] |

</output_format>

## 3. Resolve Work Item

**Linear** — two commands; the sync precedes the read so children added since the last reconcile cannot slip a container through a stale cache:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

Apply the Ancestor gate ([SKILL.md § Coordination](../SKILL.md#coordination)) to the `--with-bundle` output.

- **Container** → it is not the work item. List its unblocked DIRECT children (`depth == 0` in the flattened children array; deeper descendants are reached by re-running this section, never selected past their own parent's blockers), pick one, and re-run this section for it.
- **Explicit single-PR bundle** (`(one PR)` in the title, or a leaf whose description carries an internal checklist) → the parent IS the work item.
- **Child of a container** → the child is the PR unit, gated on its own non-terminal `state_type` and the union of its own and every container ancestor's blockers. Blocked or terminal → stop and name the live blockers.

**GitHub**:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,url,labels,state
```

Not open → stop and ask for a different item.

## 4. Prepare Worktree

```bash
.agents/skills/worktree/scripts/worktree check
```

Resolve a dirty main repo with the user before creating anything. Then check for an existing worktree:

```bash
.agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
.agents/skills/worktree/scripts/worktree path [ISSUE_ID]
```

An existing worktree means active ownership: inspect its branch and PR and coordinate with that owner. Do not spawn a second implementer; only the confirmed owning session may run `create [ISSUE_ID] --reuse`.

Otherwise create it, checking the exit status directly (`issue-[N]` for GitHub items):

```bash
.agents/skills/worktree/scripts/worktree create [ISSUE_ID]
```

Exit 75 means a branch or open PR already owns the issue even though the configured path was absent — inspect it instead of delegating. Use the create output as `WT_PATH`.

## 5. Continue In Worktree

The invocation already answered where the work runs: `start` runs it in this session; a separate session is launched with the `handoff` command instead. Execute `workflows/start-worktree.md` with `[WT_PATH]` as the worktree context — no question.

<output_format>

### Milestone: Worktree Ready

| Field | Value |
|-------|-------|
| Work item | [ID or OWNER/REPO#N] |
| Worktree | [WT_PATH] |
| Branch | [BRANCH] |
| Next | [continue-here\|handoff\|manual] |

</output_format>

Launched as a handoff → stop after launch.
