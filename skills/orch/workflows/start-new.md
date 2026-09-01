# Start New Workflow

Create one issue, then route it through `orch start`.

| Command | Flow |
|---------|------|
| `start new linear [title]` | Create a Linear issue |
| `start new github OWNER/REPO [title]` | Create a GitHub issue |

## 1. Confirm Scope

Ask only for the details that are missing: title, expected outcome, tracker, project or repo, labels.

## 2. Create

Build and validate the complete label set against the live inventory and the project taxonomy first (the project-management skill's label preflight). Then search existing issues (all states) for the same problem or component change and flag a likely duplicate to the user (related relation + comment) instead of creating blind.

`[BODY]` follows project-management's [issue-description-template.md](../../project-management/templates/issue-description-template.md), including the `Reached by:` line naming what arrives at the defect.

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[TITLE]" --description "[BODY]" --project "[PROJECT]" --labels "[LABELS]" --format=ids
```

```bash
gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body "[BODY]" --label "[LABELS]"
```

## 3. Route

Invoke `workflows/start.md` with the created issue.

<output_format>

### Milestone: Issue Created

| Field | Value |
|-------|-------|
| Tracker | [linear\|github] |
| Issue | [ID or URL] |
| Next | `orch start [ID]` |

</output_format>
