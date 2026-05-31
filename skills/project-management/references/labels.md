# Label Management Reference

Project-management workflows must treat issue labels as a validated contract, not free-form strings. Every issue create/update path uses two inputs:

1. **Live issue-label inventory** from the issue tracker.
2. **Project taxonomy/application rules** supplied by the project (for example in `vstack.toml` `[skill-instructions]`, project docs, or a project-specific reference file).

Upstream workflows define the mechanism and schema. Projects define the actual label names, domains, colors, and required categories.

## Issue Labels vs Project Labels

| Resource | Used for | CLI/source |
|----------|----------|------------|
| Issue labels | Issue routing, ownership, workflow, classification, domain/stack tags | `.agents/skills/linear/scripts/linear.sh cache labels list` or `labels list` |
| Project labels | Project/initiative categorization only | `.agents/skills/linear/scripts/linear.sh project-labels ...` |

Issue creation/update preflight must use **issue labels only**. Never validate issue labels against project labels.

## Mandatory Label Preflight

Run this before any workflow creates an issue or updates issue labels (`roadmap-create`, `audit-issues`, `research-issue`, `research-complete`, `cycle-plan`, and any wrapper calling those paths):

```bash
# Refresh if cache missing, stale, or labels are empty.
.agents/skills/linear/scripts/linear.sh sync --reconcile

# Load live issue-label inventory.
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Safe inventory rows must provide enough metadata to reject parent/group labels:

```json
{
  "id": "uuid",
  "name": "agent:example",
  "color": "#9C27B0",
  "description": "...",
  "team": "Team name or empty",
  "parent": "Agent",
  "is_group": false
}
```

If `is_group` is missing from older caches, refresh the cache. If it remains unavailable, conservatively treat any label that is used as another label's `parent` as a parent/group label and do not assign it to issues.

## Project Taxonomy Contract

Projects supply taxonomy/application rules outside upstream workflow logic. This conceptual shape is portable; exact storage may be TOML, JSON, or prose if it maps unambiguously to these fields.

```json
{
  "required_categories_for_new_issues": ["agent", "domain"],
  "categories": {
    "agent": {
      "required": true,
      "exclusive": true,
      "match": {"prefix": "agent:"},
      "forbid_group_labels": true
    },
    "platform": {
      "required": false,
      "exclusive": true,
      "match": {"parent": "Platform"},
      "forbid_group_labels": true
    },
    "domain": {
      "required": true,
      "exclusive": false,
      "labels": ["project-specific-domain-labels"]
    },
    "workflow": {
      "required": false,
      "exclusive": false,
      "labels": ["research", "blocked"]
    },
    "classification": {
      "required": false,
      "exclusive": false,
      "labels": []
    }
  }
}
```

Category matching order:

1. Explicit `labels[]` list.
2. `match.prefix`.
3. `match.parent` from live inventory.
4. Project-provided matcher/regex, if documented.

If a label matches multiple categories, the project taxonomy must disambiguate before mutation.

## Validation Rules

Validate the **final label set** before every create/update:

- Every label exists in live issue-label inventory.
- No label has `is_group: true`.
- No label name appears as a parent/group label for other labels.
- Required categories for new issues are present.
- Required exclusive categories have exactly one label.
- Optional exclusive categories have at most one label.
- Required non-exclusive categories have at least one label.
- Labels not mapped by taxonomy are rejected unless the project taxonomy explicitly allows uncategorized labels.
- Unknown labels stop the workflow and ask the user; workflows must not silently rely on CLI warn-and-skip behavior.
- If a required taxonomy label is missing from the live inventory, report it and request explicit user authorization before creating it.

Validation failure output should name:

- requested label set
- missing labels
- parent/group labels attempted
- category that failed required/exclusive rules
- whether a missing label exists in taxonomy but not in issue tracker

## Full Label Sets on Creates

New issues must carry a full validated `labels[]` set. `agent` and `agent_label` may remain as derived/backward-compatible fields, but they are not enough to create an issue.

Minimum create payload fields:

```json
{
  "title": "Implement: example scope",
  "labels": ["agent:example", "domain-example", "workflow-label"]
}
```

Before calling `issues create --labels`, validate `labels[]` against the live inventory and project taxonomy.

## Preserve Labels on Updates

The Linear CLI `--labels` option replaces the full label set. Therefore update workflows must compute a final label set from current labels plus the intended change before calling `issues update --labels`.

| Change intent | Algorithm |
|---------------|-----------|
| Replace `agent` | Fetch current labels, remove labels in taxonomy category `agent`, add new `agent:*`, preserve unrelated labels, preflight final set. |
| Replace `platform` | Fetch current labels, remove labels in taxonomy category `platform`, add new platform child, preserve unrelated labels, preflight final set. |
| Add workflow/classification/domain | Fetch current labels, union with new labels, preserve unrelated labels, preflight final set. |
| Full replacement | Allowed only when workflow output explicitly says `replace_all_labels: true`; preflight full replacement set. |

Never run snippets like:

```bash
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --labels "agent:new"
```

unless the explicit intent is to remove every other label and the full replacement set has been validated.

## Exclusivity Rules

See the project's issue-label taxonomy for full taxonomy and colors.

**Key rule**: Labels in an exclusive parent/category group (for example Agent or Platform when configured that way) allow only one label per issue. Labels without an exclusive category (for example Stack, Workflow, Classification, depending on project policy) allow multiples.

**"labelIds not exclusive child labels" error** = You tried to assign multiple labels from an exclusive group.

## When to Create Labels

**Authorization rule**: Never create any label unprompted. All label creation requires explicit user authorization.

**Create when**:
- Project taxonomy requires the label and the user authorizes issue-label creation.
- New agent added (requires agent definition first).
- New stack/domain component introduced and taxonomy owner approves.
- New workflow/classification state needed and taxonomy owner approves.

**Do NOT create when**:
- Existing label covers the use case.
- One-off categorization (use description instead).
- No clear owner or purpose defined.
- The label belongs to project labels rather than issue labels.

## Label Ownership

| Label Type | Owner | Approval | Notes |
|------------|-------|----------|-------|
| `agent:*` | tpm | Yes | Requires project agent definition |
| Domain/Stack | tpm | Yes | Architectural/taxonomy change |
| Workflow | tpm | Yes | Operational, but still requires user authorization |
| Classification | tpm | Yes | Operational, but still requires user authorization |
| Platform | tpm | Yes | Architectural/taxonomy change |

## Creating Agent Labels

Agent labels are special — MUST have agent definition AND parent group/category in the project taxonomy.

`agent:researcher` is reserved for research issues owned by the researcher agent. It requires the canonical `researcher` agent definition and should be used with the project-configured research workflow/classification label.

### Process

1. **Create the agent definition** in project agent definitions.
2. **Update** the project's issue-label taxonomy.
3. **Get explicit user authorization** to create the issue label.
4. **tpm** creates issue label:
   ```bash
   .agents/skills/linear/scripts/linear.sh labels create --name "agent:[NAME]" --color "#9C27B0" --parent "Agent"
   ```

**TPM should NOT create any labels unprompted** — even workflow or classification labels require explicit user authorization. `agent:*` labels additionally require the agent definition and taxonomy entry to exist first.

## Creating Other Issue Labels

```bash
# Workflow labels (usually no parent/group, project policy decides)
.agents/skills/linear/scripts/linear.sh labels create --name "[WORKFLOW_LABEL]" --color "#757575"

# Classification labels (usually no parent/group, project policy decides)
.agents/skills/linear/scripts/linear.sh labels create --name "[TYPE]" --color "#E53935"

# Domain/stack labels (requires taxonomy review)
.agents/skills/linear/scripts/linear.sh labels create --name "[DOMAIN_LABEL]" --color "#FF6B35"
```

After creating, update the project's issue-label taxonomy and rerun label preflight before mutation.

## Label Lifecycle

### Deprecating

1. Remove from active issues (reassign).
2. Archive in issue tracker (do not delete — preserves history).
3. Mark deprecated in taxonomy.

### Renaming

Avoid renaming — creates confusion. Instead:
1. Create new label with correct name.
2. Migrate issues from old to new.
3. Archive old label.

## Checklist: New Label

Before:
- [ ] No existing issue label covers this.
- [ ] Determined category and exclusivity.
- [ ] Confirmed this is an issue label, not a project label.
- [ ] Color consistent with category.
- [ ] Explicit user authorization obtained.

After:
- [ ] Issue label created in issue tracker.
- [ ] Taxonomy updated.
- [ ] Label inventory refreshed.
- [ ] Preflight passes.
- [ ] Announced in handoff/comment.
