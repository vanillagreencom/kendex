# Start New Workflow

Create one issue, then start it through [start.md](start.md).

| Command | Flow |
|---------|------|
| `start new linear [title]` | Create a Linear issue |
| `start new github OWNER/REPO [title]` | Create a GitHub issue |

## 1. Confirm Scope

Ask only for the details that are missing: title, expected outcome, tracker, project or repository, and labels.

## 2. Create

Apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination) before creation; its § Tracked issue creation lets this workflow create the issue directly with its own label set.

1. Build the complete label set and validate it against the live inventory and the project taxonomy: the project-management skill's `references/labels.md` § Preflight.
2. Search existing issues, in every state, for the same problem or component change. Flag a likely duplicate to the user, with a related relation and a comment, instead of creating blind.
3. Write the issue body with the harness file tool to `tmp/issue-body-[SLUG].md`, from the project-management skill's `templates/issue-description-template.md`, its `**Reached by**` line naming what arrives at the defect. `[BODY_FILE]` is that path.
4. Create the issue. **Linear only**:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[TITLE]" --description-file [BODY_FILE] --project "[PROJECT]" --labels "[LABELS]" --format=ids
   ```

   **GitHub only**:

   ```bash
   gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body-file [BODY_FILE] --label "[LABELS]"
   ```

## 3. Route

Run `workflows/start.md` with the created issue.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Milestone: Issue Created

| Field | Value |
|-------|-------|
| Tracker | [linear\|github] |
| Issue | [ID or URL] |
| Next | `orch start [ID]` |

</output_format>
