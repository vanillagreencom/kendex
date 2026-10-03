# Label Management Reference

Every create/update path uses two inputs: the **live issue-label inventory** from the tracker, and the **project taxonomy** § Project Taxonomy Contract defines. The project defines the names, colors, and required categories.

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

Under a declared taxonomy, also run `linear.sh labels audit`. It lists the undeclared labels on the team's open issues, with the issues carrying them, and each name both a team label and a workspace label use. Report each finding to the user; it does not halt the create. A non-zero audit exit is reported with its error output and never read as clean, and `taxonomy-unreadable` halts the create.

GitHub-tracked runs read live instead — `gh label list --repo [OWNER/REPO] --limit 200 --json name,description` — with no cache or sync step.

Safe inventory row shape:

```json
{"id": "uuid", "name": "agent:example", "color": "#9C27B0", "description": "...", "team": "Team name or empty", "parent": "Agent", "is_group": false}
```

If `is_group` is absent, refresh the cache. If it stays absent, treat any label that appears as another label's `parent` as a group label and never assign it.

For Linear, match each label by ID and scope as well as name. The inventory's `team` is empty for a workspace label. A team label must belong to the issue's team. A project taxonomy states which labels are shared and which belong to its team; prose using this existing `team` representation is sufficient. The CLI's `--labels` resolves names. If the mutation credential can see multiple labels with the same name, stop before mutation and report their IDs and scopes. Definition changes follow [Linear shared label maintenance](../../linear/SKILL.md#shared-label-maintenance).

## Project Taxonomy Contract

Declare it in the project's kendex manifest (`kendex.toml`, or `kendex-local.toml` in a source-catalog checkout) under `[skill-instructions].project-management`, as this JSON in a fenced `json` code block under a `### Project taxonomy` heading. kendex renders it into this skill's SKILL.md in each project skills directory it delivers the skill to. The linear CLI reads every render in one project's `.<tool>/skills` directories, never the source layout `skills/`. That project is the nearest directory from the working directory up to a bound that holds a render, else the bound. The bound is the project holding the linear install when the install sits in a `.<tool>/skills` directory in the repository, so a nested project's own taxonomy applies inside it; run from outside that project, the CLI reads the install's project. For any other install, global or source layout, the bound is the git top level:

```json
{
  "required_categories_for_new_issues": ["agent", "domain"],
  "categories": {
    "agent":     {"required": true,  "exclusive": true,  "match": {"prefix": "agent:"}, "forbid_group_labels": true},
    "platform":  {"required": false, "exclusive": true,  "match": {"parent": "Platform"}, "labels": ["macos", "linux"], "forbid_group_labels": true},
    "domain":    {"required": true,  "exclusive": false, "labels": ["project-specific-domain-labels"]},
    "workflow":  {"required": false, "exclusive": false, "labels": ["research", "blocked"]},
    "classification": {"required": false, "exclusive": false, "labels": []}
  }
}
```

Category matching order: explicit `labels[]`, then `match.prefix`, then `match.parent` from live inventory, then a project-documented matcher. A label matching two categories must be disambiguated by the taxonomy before mutation.

The declared names are every category's `labels[]` names and its `match.parent` group name, plus each name in `LINEAR_AGENT_LABELS`; a `match.prefix` declares none. The group name declares none of its children, so a `match.parent` category lists in `labels[]` the child labels issues carry. Under a declared taxonomy the linear CLI refuses, before any write, a label it does not declare, on the commands [linear SKILL.md § Issue Creation Routing](../../linear/SKILL.md#issue-creation-routing) names. A label the issue already carries is kept, and `labels audit` lists it. A `### Project taxonomy` heading with no readable JSON block, an empty one included, refuses every label write, and so do two renders whose taxonomy sections differ; with no heading the CLI enforces nothing.

A taxonomy still in an earlier form (TOML, JSON or prose in `[skill-instructions]`, or a linked project doc or reference file) under no `### Project taxonomy` heading still binds agents: they validate labels against it as before until it moves into that block. The linear CLI enforces nothing for it, as in earlier releases, and `linear.sh labels audit` reports `taxonomy-absent` until it moves.

## Validation

Validate the **final label set** before every create and update:

- Every label exists in the live issue-label inventory.
- No label has `is_group: true` or appears as another label's parent.
- Required categories are present; required exclusive categories have exactly one label; optional exclusive categories have at most one.
- Labels the taxonomy does not map are rejected unless the taxonomy explicitly allows uncategorized labels.

Any failure halts before mutation and reports: the requested set, the missing labels, any group labels attempted, the category that failed, and whether a missing label exists in the taxonomy but not in the tracker. Never rely on the CLI's warn-and-skip behavior to catch an invalid label.

## Creates Carry the Full Set

A new issue needs a complete validated `labels[]`; `agent` / `agent_label` alone are never sufficient:

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

A bare `issues update [ID] --labels "agent:new"` strips every other label; use it only when the validated final set is that one label.

## Creating Labels

A label is a taxonomy change, never a side effect of the work at hand. A lane never creates a label. Change the taxonomy in a reviewed commit whose message gives a one-line reason, and create the label only after that commit merges and the user authorizes the creation, workflow and classification labels included. An `agent:*` label additionally requires the agent definition to exist first; `agent:researcher` is reserved for research issues owned by the researcher agent.

Do not create for a one-off categorization, when an existing label covers the case, or for a project label. The label commands that refuse a name are listed in [linear SKILL.md § Issue Creation Routing](../../linear/SKILL.md#issue-creation-routing). After creating, rerun preflight before mutating.

## Label drift check

Read every open issue's `agent:` labels against the repository's effective manifest and installed harness files. Done and Canceled issue labels are historical. `agent:multi` and `agent:human` are coordination markers, not launch identities.

| Check | Rule | Result |
| --- | --- | --- |
| Routed agent | Each non-marker `agent:X` on an open issue names an enabled agent installed for the repository's execution harness. Check the catalog definition, effective subscription and rendered agent file separately. | Stop and return the issue ID, label, harness, evidence paths and cause: missing catalog definition, missing subscription or missing render. Do not replace a routing label merely because installation is missing. |

An unreadable manifest or incomplete issue inventory stops the check without a verdict.
