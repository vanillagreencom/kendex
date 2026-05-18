# Flightdeck plan-file format

Plan lane turns one markdown file into multiple tracked implementation panes. Each `##` section becomes one work item, one worktree, and eventually one PR.

## Basic shape

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

## Rules

- First H1 (`#`) is the plan title.
- Each H2 (`##`) is one work item.
- Item id is the slugified H2 title: lowercase, dash-separated, alphanumeric plus dash only, truncated to 32 characters.
- Default worktree name is `flightdeck-plan-<item_id>`.
- Optional `### Worktree` overrides the worktree/branch name.
- Optional `### Depends on` lists H2 titles or item ids this item waits for.
- Item brief is the H2 section content, excluding only optional `Worktree` and `Depends on` subsections.
- Other H3 sections, such as `### Acceptance criteria`, stay in the item brief.
- Dependencies must resolve to known items, cannot point at self, and cannot form cycles.
- Flightdeck previews parsed items before creating worktrees or panes.

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

## Notes

- One plan file represents one plan session.
- Dependent items spawn only after required items merge.
- GitHub merge verification happens before item cleanup.
- Mid-session edits are not re-parsed; start a new session if the plan changes materially.
