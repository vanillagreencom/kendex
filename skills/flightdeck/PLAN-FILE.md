# Flightdeck plan-file format

Plan lane turns one markdown file into multiple tracked implementation panes. Each `##` section becomes one work item, one worktree, and eventually one PR.

Use plan files when work can be split into independent or dependency-ordered chunks and you want Flightdeck to supervise the PR lifecycle for each chunk.

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

## <Another work item title>

Another item brief.
```

## Parsing rules

Flightdeck uses master-agent judgment, not a strict schema. These rules are the happy path:

- First H1 (`#`) is the plan title.
- Each H2 (`##`) is one work item.
- Work item id is the slugified H2 title: lowercase, dash-separated, alphanumeric plus dash only, truncated to 32 characters.
- Default worktree name is `flightdeck-plan-<item_id>`.
- Optional `### Worktree` overrides the worktree/branch name.
- Optional `### Depends on` lists H2 titles or item ids this item waits for.
- Item brief is the H2 section content, excluding only the optional `Worktree` and `Depends on` subsections.
- Other H3 sections, such as `### Acceptance criteria`, stay in the item brief.
- Dependencies must form a directed acyclic graph.

Before creating worktrees, Flightdeck prints a dry-run preview showing item ids, dependencies, worktree names, and the first 200 characters of each brief. Confirm that preview before launch.

## Writing good items

A good item brief tells the child agent:

- what to build or fix;
- files or modules likely involved;
- acceptance criteria;
- tests to add or run;
- what to avoid;
- how to keep the PR small.

Keep shared context in the H1 overview when all items need it. Repeat critical constraints inside each H2 when missing them would be dangerous.

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

## Operational notes

- One plan file represents one plan session.
- Plan items may create PRs in parallel when dependencies allow it.
- Dependent items spawn only after required items merge.
- Flightdeck verifies PR merge state with GitHub before cleaning up an item worktree.
- Mid-session edits to the plan file are not re-parsed; start a new session if the plan changes materially.
