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

Parse with master judgment. No parser code is required. First choose exactly one parse mode, then derive items.

Parse modes:

- `h2-items`: simple format. Each `## <Work item title>` H2 section is one work item. Use this mode only when the file contains no phase-style indicators anywhere.
- `phase-style`: long-plan format. One or more recognized implementation workstream H2 sections contain item H3s. Recognized workstream headings are `## Implementation phases`, `## Implementation plan`, `## Work items`, `## Workstreams`, `## Additional workstream ...`, and `## Execution plan`; any H2 containing `workstream` is a workstream. Inside those sections, `### Phase <N> ...` and `### Work item ...` H3 headings become work items. Non-item H3s inside a workstream, such as `### Context`, `### Summary`, `### Goals`, and `### Non-goals`, are workstream-local shared context, not items.

Phase-style indicators are any H3 heading matching `### Phase <N> ...` or `### Work item ...`, anywhere in the file. A malformed phase-style file must not fall back to H2 item mode.

Safe global shared-context H2 allowlist for phase-style mode:

- `Pre-execution context`, `Context`, `Background`, `Summary`, `Problem`, `Goals`, `Non-goals`, `Scope`, `Constraints`, `Current state`, `Proposed model`, `Design`, `Architecture`, `Lifecycle changes`, `Dashboard UX`, `Pi extension scope after the Rust app`, `CLI/script changes`, `Data model additions`, `Storage layout`, `Acceptance criteria`, `Validation plan`, `Test plan`, `Tests`, `Execution workflow`, `Risks`, `Notes`, `Open questions`.
- The title may have a parenthetical or update suffix after an allowlisted base title, such as `Pre-execution context (updated ...)`.
- Any other H2 outside a recognized implementation workstream is ambiguous; do not silently treat it as shared context.

Safety guard:

- If phase-style indicators exist but do not sit under a recognized implementation workstream, set `paused_for_user = {entry_id:"plan", reason:"plan-format-ambiguous", prompt_text:"<ABSOLUTE_PLAN_PATH>: ambiguous plan format; use either H2 item mode or put Phase/Work item H3s under an implementation workstream"}` and stop before dry-run preview.
- If a phase-style document has any non-allowlisted H2 outside recognized implementation workstreams, set `paused_for_user = {entry_id:"plan", reason:"plan-format-ambiguous", prompt_text:"<ABSOLUTE_PLAN_PATH>: H2 '<H2_TITLE>' is neither an implementation workstream nor allowlisted shared context"}` and stop before dry-run preview.
- Before adding shared context to any child brief, scan shared-context sections for orchestration-only markers: `BACKUP-WAKE`, reviewer fan-out instructions, `Do NOT act as Flightdeck master`, `/skill:flightdeck plan`, `$flightdeck plan`, `/flightdeck plan`, `flightdeck plan start`, `flightdeck plan watch`, `flightdeck plan close-item`, `flightdeck plan terminate`, `flightdeck linear start`, `flightdeck github start`, and `flightdeck session` master commands. Omit matching shared-context sections from child briefs and show their titles in the preview as omitted orchestration context.
- If an implementation item section contains any orchestration-only marker, set `paused_for_user = {entry_id:"plan", reason:"plan-format-ambiguous", prompt_text:"<ITEM_ID> contains Flightdeck master-only orchestration instructions"}` and stop before dry-run preview. Do not silently strip item content.
- Immediately before writing `<WT_PATH>/tmp/brief.md`, re-scan the final item brief and abort with `plan-format-ambiguous` if any orchestration-only marker remains.
- Context-only H2 sections outside the safe allowlist must never appear as preview Item rows in phase-style mode; they must fail closed as `plan-format-ambiguous`.

Rules:

- `item_id` = slugified item title: lowercase, dash-separated, alphanumeric plus dash only, collapsed repeats, trimmed, truncated to 32 chars.
- If two titles slugify to the same id, append a stable numeric suffix (`-2`, `-3`) and show the collision in the preview.
- Worktree name = optional `Worktree` control body, else `flightdeck-plan-<ITEM_ID>`. Use `### Worktree` in `h2-items` mode and `#### Worktree` in `phase-style` mode.
- Branch name matches the worktree name.
- Optional `Depends on` control body names other item titles or item ids. Normalize each dependency to an `item_id`. Use `### Depends on` in `h2-items` mode and `#### Depends on` in `phase-style` mode.
- In `h2-items` mode, the H2 section content excluding only optional `### Worktree` and `### Depends on` subsections becomes the child brief. Other H3 subsections remain part of the brief.
- In `phase-style` mode, shared context is the plan intro plus allowlisted H2 sections outside recognized implementation workstreams that do not contain orchestration-only markers. Workstream-local shared context is the recognized workstream H2 intro plus non-item H3 sections inside that workstream that do not contain orchestration-only markers. The child brief is safe global shared context plus safe workstream-local shared context plus the item H3 content, excluding only optional `#### Worktree` and `#### Depends on` subsections. Other H4 subsections remain part of the item brief.

Validate the parse mode and plan graph before dry-run preview and before any worktree, state, or pane mutation:

1. Require at least one parsed work item. If none, set `paused_for_user = {entry_id:"plan", reason:"plan-parse-invalid", prompt_text:"<ABSOLUTE_PLAN_PATH>: zero work items"}` and stop.
2. Resolve every `Depends on` token against known item titles and slug ids. If any token fails, set `paused_for_user = {entry_id:"plan", reason:"plan-dependency-unresolved", prompt_text:"<ITEM_ID> depends on '<BAD_NAME>' which doesn't match any item title or id"}` and stop.
3. Reject self-dependencies. If found, set `paused_for_user = {entry_id:"plan", reason:"plan-self-dependency", prompt_text:"<ITEM_ID> depends on itself"}` and stop.
4. Detect cycles. If found, set `paused_for_user = {entry_id:"plan", reason:"plan-dependency-cycle", prompt_text:"cycle: <ITEM_A> -> <ITEM_B> -> <ITEM_A>"}` and stop.

Only after parse-mode and graph validation pass, print a dry-run preview and ask the user to confirm.

<parse_preview_format>
Plan: [PLAN_TITLE]
Source: [ABSOLUTE_PLAN_PATH]
Mode: [PARSE_MODE]
Shared context: [global H2/workstream-local titles or —]
Omitted orchestration context: [titles or —]

| Item | Depends on | Worktree | Brief preview |
|------|------------|----------|---------------|
| [ITEM_ID] — [ITEM_TITLE] | [ITEM_ID, ... or —] | [WORKTREE_NAME] | [first 200 chars, whitespace collapsed] |

Confirm plan parsing before Flightdeck creates worktrees or panes.
</parse_preview_format>

If the user rejects or corrects the preview, stop without mutation. This verify-don't-trust step is mandatory for every plan start.

---

## § 3: Register plan graph

After confirmation, create/reuse the active durable run before writing any tracked entries. This keeps plan graph rows attached to a run even when dependency-blocked items are recorded before their panes exist:

```bash
flightdeck-state run ensure --tmux-session "$SESSION"
```

Then create one tracked entry per item. Items blocked by dependencies may have no pane yet; they still get a state row so the graph survives compaction.

Before writing entries or spawning panes, materialize immutable sanitized item brief artifacts from the already-confirmed parse result:

1. Compute `plan_snapshot_sha256 = sha256:<hex>` over the frozen plan text read in § 1.
2. Create a plan-brief artifact directory under the canonical Flightdeck state-owned root, for example `<project-root>/<FLIGHTDECK_STATE_DIR or tmp>/plan-briefs/<PLAN_ID_OR_HASH>/`. Do not use attacker-controlled absolute paths that merely contain a `plan-briefs` segment, and do not route through symlinked state or `plan-briefs` roots.
3. For every item, write the final sanitized item brief content (safe shared context + item content, with `Worktree` / `Depends on` controls removed and omitted orchestration context excluded) to `<ARTIFACT_DIR>/<ITEM_ID>.md` atomically.
4. Compute `brief_sha256 = sha256:<hex>` for each artifact and store `brief_artifact_path`, `brief_sha256`, and `plan_snapshot_sha256` in `domain.plan_item`.
5. If any artifact write/hash fails, set `paused_for_user = {entry_id:"plan", reason:"plan-brief-artifact-failed", prompt_text:"<ITEM_ID>: <ERROR>"}` and stop before any tracked-entry, worktree, or pane mutation.

Plan watch and dependency-edge resolution must consume only these immutable brief artifacts. They must not reread mutable `plan_path` to rebuild child briefs after compaction/re-entry.

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
      "plan_snapshot_sha256": "sha256:<FROZEN_PLAN_TEXT_HASH>",
      "plan_title": "<PLAN_TITLE>",
      "item_id": "<ITEM_ID>",
      "item_title": "<ITEM_TITLE>",
      "depends_on": ["<ITEM_ID>"],
      "worktree": "<ABSOLUTE_WORKTREE_PATH>",
      "parse_mode": "h2-items|phase-style",
      "brief_artifact_path": "<ABSOLUTE_BRIEF_ARTIFACT_PATH>",
      "brief_sha256": "sha256:<SANITIZED_BRIEF_HASH>",
      "omitted_context": ["<H2_OR_H3_TITLE>"],
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
4. Read the immutable sanitized item brief from `entry.domain.plan_item.brief_artifact_path`, verify its `sha256:<hex>` matches `entry.domain.plan_item.brief_sha256`, re-scan it for orchestration-only markers, then create `<WT_PATH>/tmp/brief.md` atomically and check the write return code. The item brief content must already include only safe shared context when parse mode is `phase-style`; omitted orchestration context must not be written. The file body must be:

   ```markdown
   # Plan: <PLAN_TITLE>
   # Work item: <ITEM_TITLE>
   # Plan file: <ABSOLUTE_PLAN_PATH>

   You are a Pi engineering agent working on ONE work item of a larger plan. The plan and your specific item are in `tmp/brief.md`. Read the whole brief, execute end-to-end, push a PR with body referencing the plan path + item id. Print the PR URL as the LAST line.

   ---

   <ITEM_BRIEF_CONTENT_FROM_PARSE_MODE>
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
