# Parallel Work Check

Check whether multiple issues are safe to hand off simultaneously. Stores cached analysis only; does not launch or monitor sessions.

## Inputs

| Input | Source |
|-------|--------|
| `issues` | Linear issue IDs, GitHub issue refs, or a Linear project name |

## 1. Resolve Items

1. If args are issue IDs/refs, use them directly.
2. If a Linear project name was provided:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT]" --state "Todo" --format=ids
   ```
3. Require at least two items.

## 2. Fetch Scope

If (and only if) the item list contains Linear issues, reconcile the cache
FIRST — the bundle reads below are collected once, so children or sibling
relations added since the last sync must be on disk before fetching, not
after. A GitHub-only check skips this step entirely (it must not require
Linear access):

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
```

For each Linear issue:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

For each GitHub issue:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels
```

Collect title, body/description, labels, dependencies, files/modules mentioned, and bundle children.

**Expand containers to children.** A parent that is a CONTAINER (no `(one PR)` title marker, and children present or `agent:multi` label — the `(one PR)` marker always wins, even over `agent:multi`) is not a dispatch unit — replace it in the item list with its unblocked DIRECT children (`depth == 0` entries only; the bundle's children array is flattened, and admitting deeper descendants here would duplicate their intermediate parent and bypass its blockers) and analyze those. A child is unblocked when its `state_type` is non-terminal and every blocker is resolved: blockers come from the child's own `blocked_by` PLUS the container's `blocked_by` (cross-bundle relations live on the parent and apply to every child), the arrays carry IDs only, so fetch each blocker's state (`cache issues get [BLOCKER_ID]`) — only a blocker with non-terminal `state_type` blocks. Independent children of one container may dispatch concurrently; blocking relations between siblings sequence the dependent ones. Only an explicit single-PR bundle (`(one PR)` marker) stays in the list as one item. Directly supplied children are normalized the same way — every final Linear item with a `parent_id` runs the Ancestor gate (SKILL.md → Coordination: full chain classified; blockers unioned across the item and every container ancestor; only non-terminal `state_type` blocks) before it can be marked safe, so a live cross-bundle blocker on a container parent is never invisible to the analysis. Apply the classification recursively to every replacement — a child that is itself a container (fetch its bundle and re-run this test) expands again — until the list holds only leaves and explicit `(one PR)` bundles; an intermediate container left in the list would be analyzed as a dispatch unit that handoff later refuses.

## 3. Analyze Coupling

Check for:
- Direct dependencies between items.
- Shared blockers or pending research.
- Same agent/domain assignment.
- File/module overlap.
- Shared public types, APIs, schema, migrations, or build manifests.
- Existing worktrees or open PRs.

Apply constraints:

| Constraint | Limit |
|------------|-------|
| Max group size | 5 |
| Max same-domain per group | 3 |
| Source-modifying same-domain items | split unless low overlap |
| Same manifest edits | conflict |

## 4. Present Verdict

<output_format>
### Parallel Check

| Item | Domain | Scope | Blockers |
|------|--------|-------|----------|
| [ID] | [DOMAIN] | [FILES/MODULES] | [none|IDs] |

| Check | Result |
|-------|--------|
| Dependencies | [result] |
| File overlap | [result] |
| API/type flow | [result] |
| Build config | [result] |
| Active work | [result] |

Verdict: [SAFE|CONFLICTS]
Safe groups: [GROUPS]
</output_format>

## 5. Persist

Clear and write current analysis:

```bash
.agents/skills/orch/scripts/parallel-groups clear
.agents/skills/orch/scripts/parallel-groups write '[GROUP_JSON]'
```

Group JSON:

```json
{
  "issues": ["ID-1", "ID-2"],
  "verdict": "safe",
  "source": "manual|project",
  "conflicts": [],
  "issue_fingerprints": {}
}
```

## 6. End

Suggest `orch handoff` only for safe groups the user explicitly wants to launch.
