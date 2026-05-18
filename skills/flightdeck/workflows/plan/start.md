# Workflow: `plan start` — Plan-File Orchestration Lane

Start a Flightdeck plan-file session from one markdown plan. This lane is intentionally **not** a supervisor recursion path: each spawned child pane receives a self-contained item brief and implements that item directly.

**Inputs**: `<PLAN_PATH>` markdown file path, optional launch profile.

**Pre-conditions**:
- `$TMUX` set.
- Plan lane dependencies only: `github` and `worktree`. Do not load `linear` or `project-management`.
- `gh` authenticated against the target repo because each item produces a PR.

**Post-condition**: every parsed item has a tracked entry with metadata under `entry.domain.plan_item`; dependency-free items are spawned through `flightdeck-session start --kind workflow`; `workflows/plan/watch.md` owns supervision.

---

## § 1: Resolve and freeze plan

1. Resolve the plan path to an absolute path with the current repo as base.
2. Require the file to exist and be readable.
3. Read the file once at start. Treat this snapshot as frozen for this plan session; later plan edits are ignored until a new start command.
4. Extract the first H1 as `plan_title`. If absent, use the file basename without extension.
5. If another live entry already has `domain.plan_item.plan_path` equal to this resolved path, pause with `reason="plan-session-already-active"` instead of starting a second copy.

---

## § 2: Parse work items with dry-run preview

Parse with master judgment. No parser code is required.

Rules:

- Each `## <Work item title>` H2 section is one work item.
- `item_id` = slugified title: lowercase, dash-separated, alphanumeric plus dash only, collapsed repeats, trimmed, truncated to 32 chars.
- If two titles slugify to the same id, append a stable numeric suffix (`-2`, `-3`) and show the collision in the preview.
- Worktree name = optional `### Worktree` body, else `flightdeck-plan-<ITEM_ID>`.
- Branch name matches the worktree name.
- Optional `### Depends on` body names other H2 titles or item ids. Normalize each dependency to an `item_id`.
- Section content excluding only the optional `### Worktree` and `### Depends on` subsections becomes the child brief. Other H3 subsections remain part of the brief.

Validate the plan graph before dry-run preview and before any worktree, state, or pane mutation:

1. Require at least one H2 work item. If none, set `paused_for_user = {entry_id:"plan", reason:"plan-parse-invalid", prompt_text:"<ABSOLUTE_PLAN_PATH>: zero work items"}` and stop.
2. Resolve every `Depends on` token against known H2 titles and slug ids. If any token fails, set `paused_for_user = {entry_id:"plan", reason:"plan-dependency-unresolved", prompt_text:"<ITEM_ID> depends on '<BAD_NAME>' which doesn't match any H2"}` and stop.
3. Reject self-dependencies. If found, set `paused_for_user = {entry_id:"plan", reason:"plan-self-dependency", prompt_text:"<ITEM_ID> depends on itself"}` and stop.
4. Detect cycles. If found, set `paused_for_user = {entry_id:"plan", reason:"plan-dependency-cycle", prompt_text:"cycle: <ITEM_A> -> <ITEM_B> -> <ITEM_A>"}` and stop.

Only after graph validation passes, print a dry-run preview and ask the user to confirm.

<parse_preview_format>
Plan: [PLAN_TITLE]
Source: [ABSOLUTE_PLAN_PATH]

| Item | Depends on | Worktree | Brief preview |
|------|------------|----------|---------------|
| [ITEM_ID] — [ITEM_TITLE] | [ITEM_ID, ... or —] | [WORKTREE_NAME] | [first 200 chars, whitespace collapsed] |

Confirm plan parsing before Flightdeck creates worktrees or panes.
</parse_preview_format>

If the user rejects or corrects the preview, stop without mutation. This verify-don't-trust step is mandatory for every plan start.

---

## § 3: Register plan graph

After confirmation, create one tracked entry per item. Items blocked by dependencies may have no pane yet; they still get a state row so the graph survives compaction.

Minimum tracked-entry shape:

```jsonc
{
  "id": "<ITEM_ID>",
  "title": "<ITEM_TITLE>",
  "kind": "workflow",
  "state": "waiting",
  "domain": {
    "plan_item": {
      "plan_path": "<ABSOLUTE_PLAN_PATH>",
      "plan_title": "<PLAN_TITLE>",
      "item_id": "<ITEM_ID>",
      "item_title": "<ITEM_TITLE>",
      "depends_on": ["<ITEM_ID>"],
      "worktree": "<ABSOLUTE_WORKTREE_PATH>",
      "pr_number": null,
      "merge_commit": null
    }
  }
}
```

`domain.plan_item` is mutually exclusive with `domain.issue` and `domain.github_issue`. Do not write Linear or GitHub issue metadata for plan entries.

---

## § 4: Spawn dependency-free items

For each item with no unmet dependencies, in dependency-graph topological order, run an independent transaction. A single item failure does not halt the rest of `plan start`.

1. Before any worktree mutation, atomically claim the item under the Flightdeck state-lock:
   - Compare-and-swap `entry.state` from `waiting` to `spawning`.
   - Refuse to spawn if `entry.domain.plan_item.pr_number !== null`.
   - Refuse to spawn if `entry.domain.plan_item.merge_commit !== null`.
   - Refuse to spawn if a live pane is already registered for this entry.
   - On refusal, leave the entry unchanged, emit activity `plan-spawn-refused item=<ITEM_ID> reason=<reason>`, and continue to the next item.
2. Run the worktree preflight:
   ```bash
   .agents/skills/worktree/scripts/worktree check
   ```
3. Create or reuse the item worktree with the item worktree name as branch name:
   ```bash
   WT_PATH=$(.agents/skills/worktree/scripts/worktree create <WORKTREE_NAME>)
   ```
4. Create `<WT_PATH>/tmp/brief.md` atomically and check the write return code. The file body must be:

   ```markdown
   # Plan: <PLAN_TITLE>
   # Work item: <ITEM_TITLE>
   # Plan file: <ABSOLUTE_PLAN_PATH>

   You are a Pi engineering agent working on ONE work item of a larger plan. The plan and your specific item are in `tmp/brief.md`. Read the whole brief, execute end-to-end, push a PR with body referencing the plan path + item id. Print the PR URL as the LAST line.

   ---

   <SECTION_CONTENT_FROM_PLAN_FILE>
   ```

5. Spawn through Flightdeck's native session launcher and check the return code. Do not hand-roll tmux or harness commands:
   ```bash
   .agents/skills/flightdeck/scripts/flightdeck-session start \
     --session-id <ITEM_ID> \
     --title "<ITEM_TITLE>" \
     --cwd <WT_PATH> \
     --harness <HARNESS> \
     --kind workflow \
     --prompt "Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line."
   ```
6. Re-register / restore `entry.domain.plan_item` onto the spawned entry while preserving the launch/adapter metadata that `flightdeck-session` recorded. The entry remains claimed as `state="spawning"` until this write succeeds.
7. Transition item to in-progress: set `state="submitting"` and `domain.plan_item.phase="in-progress"`.
8. On any failure in steps 2-7:
   - Remove `<WT_PATH>/tmp/brief.md` if it was written.
   - Kill the spawned pane if `flightdeck-session start` succeeded but the entry could not be re-registered.
   - Mark the entry `state="failed"` with `domain.plan_item.error = {phase:"<PHASE>", reason:"<REASON>", stderr:"<STDERR>"}`.
   - Emit activity `plan-spawn-failed item=<ITEM_ID> phase=<PHASE> reason=<REASON>`.
   - Continue to the next dependency-free item.

This spawn shape is the recursion guard: child prompts contain implementation work only. They must not invoke master-side Flightdeck plan workflows.

---

## § 5: Leave dependency-blocked items waiting

For each item with unmet dependencies:

- Keep `state="waiting"`.
- Set `domain.plan_item.phase="waiting-on-dependency"`.
- Store the computed absolute `worktree` path but do not create the worktree yet.
- Record `depends_on` as item ids only.

`workflows/plan/watch.md` spawns these items after their dependencies have authoritative merged PRs.

---

## § 6: Enter watch

Invoke `workflows/plan/watch.md` with the parsed item ids. The watch loop reuses `workflows/shared/session-watch.md` for daemon/poll mechanics, then adds plan dependency resolution and GitHub PR handling.

## Returns

To the plan watch loop.
