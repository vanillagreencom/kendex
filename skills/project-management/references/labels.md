# Label Management Reference

Issue labels are a validated contract, not free-form strings. Every create/update path uses two inputs: the **live issue-label inventory** from the tracker, and the **project taxonomy** the project supplies (`vstack.toml` `[skill-instructions]`, a project doc, or a project reference file). This file defines the mechanism; the project defines the names, colors, and required categories.

## Issue Labels vs Project Labels

| Resource | Used for | Source |
|----------|----------|--------|
| Issue labels | Issue routing, ownership, workflow, classification, domain/stack | `linear.sh cache labels list` / `gh label list` |
| Project labels | Project and initiative categorization only | `linear.sh project-labels ...` |

Preflight uses **issue labels only**. Never validate an issue label against the project-label list.

## Preflight

Run before any workflow creates an issue or updates issue labels:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

GitHub-tracked runs read live instead — `gh label list --repo [OWNER/REPO] --limit 200 --json name,description` — with no cache or sync step.

Safe inventory rows carry enough metadata to reject parent/group labels:

```json
{"id": "uuid", "name": "agent:example", "color": "#9C27B0", "description": "...", "team": "Team name or empty", "parent": "Agent", "is_group": false}
```

If `is_group` is absent, refresh the cache. If it stays absent, treat any label that appears as another label's `parent` as a group label and never assign it.

## Project Taxonomy Contract

Storage may be TOML, JSON, or prose, as long as it maps unambiguously to this shape:

```json
{
  "required_categories_for_new_issues": ["agent", "domain"],
  "categories": {
    "agent":     {"required": true,  "exclusive": true,  "match": {"prefix": "agent:"}, "forbid_group_labels": true},
    "platform":  {"required": false, "exclusive": true,  "match": {"parent": "Platform"}, "forbid_group_labels": true},
    "domain":    {"required": true,  "exclusive": false, "labels": ["project-specific-domain-labels"]},
    "workflow":  {"required": false, "exclusive": false, "labels": ["research", "blocked"]},
    "classification": {"required": false, "exclusive": false, "labels": []}
  }
}
```

Category matching order: explicit `labels[]`, then `match.prefix`, then `match.parent` from live inventory, then a project-documented matcher. A label matching two categories must be disambiguated by the taxonomy before mutation.

## Validation

Validate the **final label set** before every create and update:

- Every label exists in the live issue-label inventory.
- No label has `is_group: true` or appears as another label's parent.
- Required categories are present; required exclusive categories have exactly one label; optional exclusive categories have at most one.
- Labels the taxonomy does not map are rejected unless the taxonomy explicitly allows uncategorized labels.

Any failure halts before mutation and reports: the requested set, the missing labels, any group labels attempted, the category that failed, and whether a missing label exists in the taxonomy but not in the tracker. Never rely on the CLI's warn-and-skip behavior to catch an invalid label.

## Creates Carry the Full Set

A new issue needs a complete validated `labels[]`. `agent` / `agent_label` are derived, backward-compatible fields and are never sufficient on their own:

```json
{"title": "Implement: example scope", "labels": ["agent:example", "domain-example", "workflow-label"]}
```

## Updates Compute the Final Set

`issues update --labels` **replaces** the whole set. Compute the final set from the issue's current labels plus the intended change, then preflight it.

| Intent | Algorithm |
|--------|-----------|
| Replace an exclusive category (`agent`, `platform`) | Fetch current labels, drop that category's labels, add the new one, preserve everything else |
| Add domain / workflow / classification | Fetch current labels, union with the new ones |
| Full replacement | Only when the workflow output says `replace_all_labels: true` |

A bare `issues update [ID] --labels "agent:new"` strips every other label. It is correct only when the validated final set really is that one label.

## Creating Labels

**Never create a label unprompted** — all label creation requires explicit user authorization, workflow and classification labels included. An `agent:*` label additionally requires the agent definition and the taxonomy entry to exist first; `agent:researcher` is reserved for research issues owned by the researcher agent.

Create only when the taxonomy requires a label the tracker lacks and the user authorizes it. Do not create for a one-off categorization, when an existing label covers the case, or for a project label. After creating, update the taxonomy and rerun preflight before mutating.
