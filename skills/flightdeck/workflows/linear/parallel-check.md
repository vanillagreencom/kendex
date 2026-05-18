# Linear Parallel Work Check

Verify issues have zero cross-dependencies before parallel execution.

Issue-mode workflow only. Generic/ad-hoc sessions do not run Linear/GitHub/worktree checks; their common supervision underlay is `workflows/shared/session-watch.md` plus `workflows/shared/session-handle-prompt.md`.

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| `issues` | `linear parallel-check` arguments (space-separated issue IDs or project name) | Yes (>=2 issues) |

## 1. Resolve Arguments

### 1a. Issue IDs

If arguments match issue ID pattern → use directly as `[ISSUES]`. Set `source: "manual"`.

### 1b. Project Name

If first argument does NOT match issue ID pattern, treat as project name:

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --project "[ARG]" --state "Todo" --format=ids
```

Use output directly as `[ISSUES]` (one identifier per line). Fail if < 2 issues. Set `source: "project"`.

## 2. Fetch & Resolve

### 2.1 Fetch with Bundle Context

```bash
for ISSUE in [ISSUES]; do
  .agents/skills/linear/scripts/linear.sh cache issues get $ISSUE --with-bundle
done
```

Collect: `id`, `title`, `agent`, `blocks`, `blockedBy`, `description`, `parent_id`, `children[]`.

### 2.2 Resolve to Top-Level

| Condition | Action |
|-----------|--------|
| No `parent_id`, no `children` | Standalone -- keep |
| No `parent_id`, has `children` | Bundle parent -- keep |
| Has `parent_id` | Child -- replace with parent (fetch parent if not already in set) |

Deduplicate. Fail if < 2 top-level issues after dedup. Use `[TOP_LEVEL_ISSUES]` for all subsequent sections.

### 2.3 Build Analysis Sets

For each top-level issue, build scope from:
- **Standalone**: own description
- **Bundle**: parent description + ALL children's descriptions, agent = union of children's agent labels

## 3. Dependency Check

### 3.1 Direct Dependencies

Check if any issue blocks/is-blocked-by another in the set:

| Check | Fail If |
|-------|---------|
| `blocks` | Contains any other issue in set |
| `blockedBy` | Contains any other issue in set |

**Bundles**: Check union of parent + all children's `blocks`/`blockedBy` against other top-level issues and their children.

**Bundle exception**: Dependencies between children of the SAME parent are intra-bundle -- do not flag. Only flag cross-bundle/cross-standalone dependencies.

### 3.2 Shared Blockers

Check if issues share common blockers (indicates related work):

```
Issue A blockedBy: [ID-100, ID-101]
Issue B blockedBy: [ID-101, ID-102]
→ Shared: ID-101 (potential coupling)
```

### 3.3 Pending Research Blockers

For each issue, check if any `blockedBy` issue has the `research` label and state != Done:

```bash
for BLOCKER in [BLOCKED_BY]; do
  .agents/skills/linear/scripts/linear.sh cache issues get $BLOCKER --format=compact
done
```

If a blocker is research + not Done → flag issue as **scope uncertain**. Scope-uncertain issues cannot appear in safe groups (research may expand scope into overlapping files). Report: `⚠️ [ISSUE_ID] scope uncertain — blocked by pending research [BLOCKER]`.

## 4. Agent Overlap Check

Same agent assignment = potential file conflicts.

| Agents | Risk |
|--------|------|
| All different | ✅ Low (different domains) |
| Some same | ⚠️ Medium (check file overlap) |
| All same | 🔴 High (likely conflicts) |

**Bundles**: Agent set = union of all children's agent labels.

### 4.1 Grouping Constraints

Apply these when forming safe groups from analyzed issues:

| Rule | Limit | Rationale |
|------|-------|-----------|
| Max group size | 5 issues | Practical limit: concurrent builds, merge cascades, review bandwidth |
| Max same-agent per group | 3 issues | Same-domain work shares implicit coupling (build config, shared types, test infra) |
| Source-modifying isolation | 1 per group per domain | Issues modifying `src/` (not just `tests/`/`benches/`) cannot share a group with other same-domain source-modifying issues |
| Manifest conflict | Hard conflict | Two issues both modifying the same project manifest file = separate groups |

**Source-modifying detection**: Issue adds/changes files in `src/` (not `tests/`, `benches/`). Parse from description paths and scope analysis. Test-only issues within the same agent are lower risk but still subject to the per-group cap.

## 5. Code Scope Analysis

Extract scope from descriptions (file paths, modules, types mentioned).

**Bundles**: Scope = union of parent + all children's mentioned paths/modules.

### 5.1 Scope Extraction

```bash
# For each issue, extract mentioned paths/modules from description
# Parse file paths, module names, type references
```

### 5.2 File Overlap Detection

If agents overlap, search for actual file conflicts:

```bash
# Get files each issue would likely touch
# Check intersection between issue scopes
```

## 6. Type/Value Flow Check

Search for cross-references between scopes:

```bash
# If Issue A touches TypeA and Issue B touches ModuleB
# Check if ModuleB imports/uses TypeA
```

Fail if: Type/value from one issue's scope is used in another's scope.

## 7. Build Config Check

Shared build configuration creates implicit coupling.

### 7.1 Manifest Files

```bash
# Check if descriptions mention dependency/config changes to project manifest file
```

### 7.2 Risk Matrix

| Scenario | Risk |
|----------|------|
| Both add dependencies | ⚠️ Medium (merge conflict likely, but mechanical) |
| Both modify same dependency version | Hard conflict (semantic conflict) |
| One adds dep, other unrelated | ✅ Safe |

### 7.3 Specific Checks

```bash
# Issues mentioning build changes
# If both touch project manifest file, check for overlapping sections
```

## 8. Active Work Check

Detect existing parallel work to inform merge order.

### 8.1 Existing Worktrees

```bash
.agents/skills/worktree/scripts/worktree list
```

Cross-reference with issue set:
- Issue already has worktree → work in progress
- Issue has open PR → near merge, order matters

### 8.2 Open PRs

```bash
for ISSUE in [ISSUES]; do
  gh pr list --search "$ISSUE in:title" --state open
done
```

### 8.3 Implications

| State | Implication |
|-------|-------------|
| No existing work | ✅ Clean start |
| One has PR, one doesn't | ⚠️ PR likely merges first |
| Both have PRs | ⚠️ Review merge order |
| Worktree exists, no PR | ℹ️ Work in progress |

Note: Multiple worktrees from main is correct for parallel work. This check is informational for merge planning.

## 9. Present Results

<output_format>

### PARALLEL CHECK — [N] issues

| Issue | Agent | Scope | Blockers |
|-------|-------|-------|----------|
| [ISSUE_ID] | [AGENT_TYPE] | src/ui/ | none |
| [ISSUE_ID] | [AGENT_TYPE] | types/ | [ISSUE_ID], [ISSUE_ID] |

---

#### Dependencies
- Direct: [✅ None | [ISSUE_ID] blocks [ISSUE_ID]]
- Shared blockers: [✅ None | ⚠️ Both blocked by [ISSUE_ID]]
- Scope uncertainty: [✅ None | ⚠️ [ISSUE_ID] pending research [ISSUE_ID] — cannot guarantee safe]

#### Agent Overlap
[✅ Different domains | ⚠️ Same agent: [AGENT_TYPE] — checking files]

#### File Conflicts
[✅ No overlap | Both touch: path/to/file]

#### Type/Value Flow
[✅ No cross-references | Issue A's TypeX used in Issue B's scope]

#### Build Config
[✅ No manifest conflicts | ⚠️ Both touch project manifest file — review deps]

#### Active Work
[ℹ️ [ISSUE_ID] has worktree, [ISSUE_ID] no existing work]
[ℹ️ Open PRs: #42 ([ISSUE_ID])]

---

### VERDICT: [✅ SAFE TO PARALLELIZE | CONFLICTS DETECTED]

[If conflicts, list specific blockers to resolve first]
</output_format>

## 10. Persist Results

Persist regardless of verdict (prevents re-analysis on next `workflows/linear/start.md`). Stale fingerprints auto-invalidate when issues change. Persist **multiple groups** when analysis identifies safe subgroups within a conflicting set.

1. **Build fingerprints**: For each top-level issue, use its own `updated_at`. For bundle children, use `children_fingerprints`:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] | jq -r '.updated_at'
   ```

2. **Identify groups to persist** (apply § 4.1 grouping constraints when forming groups):
   - **All safe**: One group, verdict `safe`, all issues -- but respect § 4.1 caps (e.g., max 4 same-agent). If caps exceeded, split into multiple safe groups.
   - **All conflict**: One group, verdict `conflicts`, all issues
   - **Mixed**: Persist a `conflicts` group (all issues) AND **ALL valid safe subgroups** (2+ issues each). If A conflicts with B but both work with C and D, persist BOTH `{A,C,D}` safe AND `{B,C,D}` safe -- dashboard needs the group containing the highest-priority issue

3. **Build each group JSON** (conflict descriptions max 60 chars):
   ```json
   {
     "issues": ["[ISSUE_ID]", "[ISSUE_ID]"],
     "verdict": "safe|conflicts",
     "source": "[SOURCE]",
     "conflicts": ["file overlap: some_file (ID-1, ID-2)"],
     "issue_fingerprints": {
       "[ISSUE_ID]": "[UPDATED_AT]",
       "[ISSUE_ID]": "[UPDATED_AT]"
     },
     "children_fingerprints": {
       "[ISSUE_ID]": "[UPDATED_AT]",
       "[ISSUE_ID]": "[UPDATED_AT]"
     }
   }
   ```

   `children_fingerprints`: all children of any bundle in the group. Empty `{}` if no bundles.

4. **Clear existing groups**: `.agents/skills/flightdeck/scripts/parallel-groups clear`

5. **Write each group**: `.agents/skills/flightdeck/scripts/parallel-groups write '$GROUP_JSON'`

---

**END**: Parallel check complete.
