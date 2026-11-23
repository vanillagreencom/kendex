# Start Workflow

Prepare one work item from the main checkout and hand it to its worktree session. This workflow never watches or manages other sessions.

| Command | Flow |
|---------|------|
| `start` | pick one item → prepare |
| `start [LINEAR_ID]` | prepare a Linear issue |
| `start github OWNER/REPO#N` | prepare a GitHub issue |
| `start new ...` | `workflows/start-new.md` |

**Main checkout only.** Read the lane host before anything else. A worktree cwd skips this read, and § 1 step 3 routes it on:

```bash
.agents/skills/orch/scripts/orch-runtime host resolve
```

Any answer but `local` refuses the run here:

1. Resume no handoff, and read, activate or create nothing ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes).
2. Report `start-control-host host=[HOST]` as the first line.
3. As the next line, report the fix: launch the item as a hosted lane through [lane-launch.md](../references/lane-launch.md) § Lane directive, Placement, with its `/orch start [ISSUE_ID]` brief. For `start new`, create the issue first, then launch it that way.

## 0. Resume From A Handoff

**Skip if** no work item was named (`start` alone, or `start new`). For `start github OWNER/REPO#N`, `[ISSUE_ID]` is `issue-[N]` (§ 1).

```bash
.agents/skills/orch/scripts/orch-runtime state handoff-standing --item [ISSUE_ID]
```

This verb answers whether a lane's handoff record ([oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out)) stands. The reply's `result.standing` word is the answer, not the exit status.

- `none` → § 1.
- `unreadable`, or a non-zero exit → stop and report, naming the item and what the reader wrote.
- `stands` → `result.record` holds the record.
  1. Print it.
  2. Stamp it resumed in every place it stands. A refusal stops and reports the same way.

     ```bash
     .agents/skills/orch/scripts/orch-runtime state handoff-resume --item [ISSUE_ID]
     ```

  3. Continue from the first entry of its `remaining` list instead of § 1-5, or, on the start-worktree.md § 1 step 3 route, from the continuation that step names.

## 1. Route

1. Arguments starting with `new` → run `workflows/start-new.md`.
2. Parse explicit arguments before reading the cwd. `github` → `TRACKER=github`, `[OWNER/REPO]` and `ISSUE_ID=issue-[N]`. Otherwise `TRACKER=linear` with the parsed `[ISSUE_ID]`; an `[ISSUE_ID]` starting with `issue-` makes it `github`.
3. A worktree cwd → run `workflows/start-worktree.md` with that context, and stop here.

## 2. Select Work Item

**Skip if** an explicit item was named.

Present the unblocked candidates from the tracker and pick one. This workflow prepares exactly one: where several are wanted, make each an issue first and hand each off separately.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Milestone: Work Selected

| Field | Value |
|-------|-------|
| Tracker | [linear\|github] |
| Work item | [ID or OWNER/REPO#N] |
| Reason | [why this is next] |

</output_format>

## 3. Resolve Work Item

**Linear only.** Read the item live:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
```

A Verifying item stops development preparation. Its post-merge readings belong to the verification pass in [verify.md](verify.md).

Apply the [Ancestor gate](../references/skill-rules.md#ancestor-gate) to this live read, with any further reads the gate requires.

- **A container**, whose read reports `in_pr_bundle` false, is not the work item. List its unblocked direct children, `depth` 0 in the read's flattened children, never a deeper descendant. Pick one and run this section again for it.
- **A single-PR work item** is the work item: a leaf whose description carries an internal checklist, or an in-PR bundle root, whose read reports `in_pr_bundle`.
- **A child of a container** is the PR unit. Apply the Ancestor gate to it. A blocked or terminal child stops, naming the live blockers.

**GitHub only**:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,url,labels,state
```

An issue that is not open stops: ask for another item.

## 4. Prepare Worktree

```bash
.agents/skills/worktree/scripts/worktree check
```

Resolve a dirty main checkout with the user before creating anything. Then look for an existing worktree:

```bash
.agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
.agents/skills/worktree/scripts/worktree path [ISSUE_ID]
```

An existing worktree means another session owns the item. Inspect its branch and pull request, and coordinate with that owner. Start no second implementer. Only the confirmed owning session runs `create [ISSUE_ID] --reuse`.

Otherwise create the worktree, `issue-[N]` for a GitHub item, and check its exit status:

```bash
.agents/skills/worktree/scripts/worktree create [ISSUE_ID]
```

Exit 75 means a branch or an open pull request already owns the item: inspect it instead of delegating. `[WT_PATH]` is the path `create` prints.

## 5. Continue In Worktree

Run `workflows/start-worktree.md` with `[WT_PATH]` as the worktree context. Ask no question.

An `orch start` run is complete when its merge work is complete and the tracker issue is Done, or is handed to the overseer in Verifying under [merge-pr.md § 5](merge-pr.md#5-execute-the-merge). The issue reaches Done only after every post-merge box has proof. An opened or armed pull request is not complete.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Milestone: Worktree Ready

| Field | Value |
|-------|-------|
| Work item | [ID or OWNER/REPO#N] |
| Worktree | [WT_PATH] |
| Branch | [BRANCH] |
| Next | [continue-here\|handoff\|manual] |

</output_format>

A run launched as a handoff stops after the launch.
