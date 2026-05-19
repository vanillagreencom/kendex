# Flightdeck plan-file format

Plan lane turns one markdown file into multiple tracked implementation panes. A plan file uses one parse mode:

- **H2 item mode**: each `##` section is one work item. This mode is valid only when the file has no `### Phase ...` or `### Work item ...` headings anywhere.
- **Phase-style mode**: `### Phase ...` sections under a recognized implementation workstream become work items. Surrounding `##` sections are shared context only when their titles are on the safe shared-context allowlist.

Flightdeck previews parsed items before creating worktrees or panes. If the mode is ambiguous, Flightdeck stops with a validation error instead of guessing.

## Basic H2 item shape

```markdown
# <Plan title>

Optional overview: goals, context, non-goals, shared acceptance criteria.

## <Work item title>

Brief for the implementation pane assigned to this item.

### Worktree
optional-custom-worktree-name

### Depends on
Other work item title, another-item-id
```

## Phase-style shape

Use phase-style mode for long planning documents that keep problem/goals/design as top-level sections and list implementation work under a dedicated workstream.

```markdown
# <Plan title>

## Problem

Shared context every implementation pane should read.

## Goals

More shared context.

## Implementation phases

Introductory workstream context.

### Phase 1 — Extract storage helper

Implementation brief for this item.

#### Worktree
flightdeck-plan-storage-helper

#### Depends on

### Phase 2 — Wire UI

Implementation brief for this item.

#### Depends on
Phase 1 — Extract storage helper
```

Recognized implementation workstream headings include `## Implementation phases`, `## Implementation plan`, `## Work items`, `## Workstreams`, `## Additional workstream ...`, and `## Execution plan`; any H2 containing `workstream` is a workstream. Inside those sections, `### Phase <N> ...` and `### Work item ...` headings become plan items. Non-item H3s inside a workstream, such as `### Context`, `### Summary`, `### Goals`, and `### Non-goals`, are workstream-local shared context.

Top-level shared context is fail-closed. In phase-style mode, H2 sections outside recognized workstreams are shared context only when their normalized titles are allowlisted:

- `Pre-execution context`, `Context`, `Background`, `Summary`, `Problem`, `Goals`, `Non-goals`, `Scope`, `Constraints`, `Current state`, `Proposed model`, `Design`, `Architecture`, `Lifecycle changes`, `Dashboard UX`, `Pi extension scope after the Rust app`, `CLI/script changes`, `Data model additions`, `Storage layout`, `Acceptance criteria`, `Validation plan`, `Test plan`, `Tests`, `Execution workflow`, `Risks`, `Notes`, `Open questions`.

An allowlisted title may have a parenthetical or update suffix, such as `Pre-execution context (updated ...)`. Any other H2 outside a recognized workstream stops parsing with `plan-format-ambiguous` before preview, worktree creation, state writes, or pane launch.

Shared context is also filtered for child-brief safety. Sections containing master-only orchestration markers are omitted from child briefs and shown in the preview as omitted orchestration context. Markers include `BACKUP-WAKE`, reviewer fan-out instructions, `Do NOT act as Flightdeck master`, and Flightdeck master lane commands such as `/skill:flightdeck plan`, `$flightdeck plan`, `/flightdeck plan`, `flightdeck plan start`, `flightdeck plan watch`, `flightdeck plan close-item`, `flightdeck plan terminate`, `flightdeck linear start`, `flightdeck github start`, or `flightdeck session`. If those markers appear inside an implementation item, Flightdeck stops with `plan-format-ambiguous` instead of stripping item content.

## Rules

- First H1 (`#`) is the plan title.
- Flightdeck chooses exactly one parse mode before preview:
  - H2 item mode when no phase-style indicators (`### Phase ...` or `### Work item ...`) exist anywhere.
  - Phase-style mode when one or more recognized implementation workstreams contain `### Phase ...` or `### Work item ...` headings.
  - Malformed or ambiguous mixed files stop with `plan-format-ambiguous` before any dry-run preview, worktree, state, or pane mutation.
- In H2 item mode, each H2 (`##`) is one work item.
- In phase-style mode, each matching H3 inside a recognized implementation workstream is one work item; allowlisted surrounding H2 sections become global shared context, and safe non-item H3s inside that workstream become workstream-local shared context prepended to item briefs.
- Item id is the slugified item title: lowercase, dash-separated, alphanumeric plus dash only, truncated to 32 characters.
- Default worktree name is `flightdeck-plan-<item_id>`.
- Optional `Worktree` overrides the worktree/branch name. Use `### Worktree` in H2 item mode and `#### Worktree` in phase-style mode.
- Optional `Depends on` lists item titles or item ids this item waits for. Use `### Depends on` in H2 item mode and `#### Depends on` in phase-style mode.
- Item brief is the parsed item content, excluding only optional `Worktree` and `Depends on` subsections.
- Other subsections, such as `Acceptance criteria`, stay in the item brief.
- Dependencies must resolve to known items, cannot point at self, and cannot form cycles.
- The dry-run preview is mandatory before Flightdeck creates worktrees or panes.
- After preview confirmation, Flightdeck writes immutable sanitized item brief artifacts under its canonical state-owned `<project-root>/<FLIGHTDECK_STATE_DIR or tmp>/plan-briefs/` root and stores `brief_artifact_path`, `brief_sha256`, and `plan_snapshot_sha256` on each `domain.plan_item`. Artifact paths must be absolute normalized paths below that exact root, ending in `<item_id>.md`, with no traversal, control characters, wrong filename, out-of-root containment, symlinked state/`plan-briefs` roots, or symlink escape. Dependency-spawned items read those artifacts instead of reparsing a mutable plan file.

Good item briefs include: scope, likely files, acceptance criteria, tests, non-goals, and PR-size boundaries.

## Example: simple parallel plan

```markdown
# Reduce settings UI friction

Goal: make the settings page easier to scan without changing stored settings.

## Group related toggles

Reorganize settings into visual groups. Preserve existing setting keys and persistence behavior.

Acceptance criteria:
- Existing settings load unchanged.
- Groups have accessible headings.
- Snapshot tests update only for layout.

Tests:
- Run the settings UI test suite.

## Add search filter

Add a local search box that filters visible settings by label and description.

Acceptance criteria:
- Empty search shows all settings.
- Search is case-insensitive.
- No settings persistence behavior changes.

Tests:
- Add unit tests for filtering.
- Run the settings UI test suite.
```

## Example: plan with dependencies

```markdown
# Split report export pipeline

Goal: separate report serialization from delivery so future exporters can share the same core data shape.

## Extract report model

Create a pure report model module used by current export code. Keep existing exported output byte-for-byte compatible.

### Worktree
flightdeck-plan-report-model

Acceptance criteria:
- Existing export tests still pass.
- New model has unit tests for required fields.
- No delivery behavior changes.

## Add markdown exporter

Build a markdown exporter on top of the extracted report model.

### Depends on
Extract report model

Acceptance criteria:
- Markdown output includes title, summary, and item table.
- Exporter has snapshot coverage.
- Existing export behavior remains unchanged.

## Wire CLI flag

Expose a CLI flag that selects the markdown exporter.

### Depends on
Add markdown exporter

Acceptance criteria:
- Default CLI behavior unchanged.
- New flag writes markdown output.
- Invalid format names return a clear error.
```

## Example: phase-style plan

```markdown
# Improve release diagnostics

## Problem

Users need clearer failure causes across release tooling.

## Goals

Keep changes small and independently reviewable.

## Implementation phases

### Phase 1 — Normalize error payloads

Scope: add a shared error shape.

Tests: unit tests for parser failures.

### Phase 2 — Render diagnostics

#### Depends on
Phase 1 — Normalize error payloads

Scope: show the normalized payload in the CLI.

Tests: snapshot CLI output.

## Additional workstream — Documentation follow-ups

### Context

Keep docs aligned with the new diagnostic output.

### Phase 3 — Update troubleshooting guide

Scope: document common diagnostic causes.

Tests: link check docs.
```

Preview must show only `phase-1-normalize-error-payloads`, `phase-2-render-diagnostics`, and `phase-3-update-troubleshooting-guide` as items. `Problem`, `Goals`, `Additional workstream — Documentation follow-ups`, and `Context` are shared context, not work items.

## Invalid phase-style examples

Malformed phase-style sections do not fall back to H2 item mode:

```markdown
# Bad plan

## Phases

### Phase 1 — Missing recognized workstream

This looks like phase-style, but `## Phases` is not a recognized implementation workstream.
```

Result: `plan-format-ambiguous` before dry-run preview or mutation. Rename `## Phases` to `## Implementation phases` or convert the file to pure H2 item mode.

Unallowlisted H2 sections in a phase-style file also fail closed:

```markdown
# Bad plan

## Problem

Shared context.

## Implementation phases

### Phase 1 — Add parser guard

Implementation work.

## Refactor dashboard

This H2 could be a missed work item, so Flightdeck must not silently treat it as context.
```

Result: `plan-format-ambiguous` with a message that `Refactor dashboard` is neither an implementation workstream nor allowlisted shared context.

Master-only instructions cannot ride into child briefs:

```markdown
# Bad plan

## Implementation phases

### Phase 1 — Add parser guard

Run `/flightdeck plan watch` after editing.
```

Result: `plan-format-ambiguous` because implementation item content contains Flightdeck master-only orchestration instructions.

## Notes

- One plan file represents one plan session.
- Dependent items spawn only after required items merge.
- Dependent items use the immutable brief artifact created at plan start; mid-session edits to the source plan do not change queued child briefs.
- GitHub merge verification happens before item cleanup.
- Mid-session edits are not re-parsed; start a new session if the plan changes materially.
