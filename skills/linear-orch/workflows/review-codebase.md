# Codebase Review Workflow

Ad-hoc full-codebase reviewer fanout. No PR, no issue, no diff, no fix delegation.

Use for early-stage projects when the user asks for a whole-codebase review.

## Inputs

| Command | Behavior |
|---------|----------|
| `review-codebase` | Review current repository root |
| `review-codebase [PATH]` | Review repository/worktree at path |

**Always standalone** — no managed lifecycle and no workflow-state file.

---

## 1. Resolve Worktree

If `[PATH]` is provided, use it. Otherwise use current directory.

```bash
WT_PATH=$(git -C [PATH_OR_PWD] rev-parse --show-toplevel 2>/dev/null)
```

**If not a git worktree**: report `review-codebase requires a git worktree` and **END**.

Create output dir:

```bash
mkdir -p "$WT_PATH/tmp"
```

---

## 2. Select Reviewers

Enumerate every installed `reviewer-*` agent from active harness registries:

```bash
AGENTS=$(.agents/skills/linear-orch/scripts/list-review-agents)
```

If no agents are found, report `No reviewer-* agents installed; cannot run codebase review` and **END**.

Use the full list. Do not path-filter; this workflow is intentionally a full fanout.

---

## 3. Delegate Reviewers

Delegate to each reviewer in `[AGENTS]` in parallel with the prompt below.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/codebase-review.md

Worktree: [WT_PATH]
Scope: Whole codebase. Inspect tracked, non-generated project code files, plus tests, configs, and docs relevant to your review domain. Do not sample or restrict to changed files. No PR, no issue, no diff.
Exclusions: generated artifacts, dependency/vendor dirs, build outputs, binary assets, harness mirrors, and lockfiles unless your review domain specifically requires them.
</delegation_format>

---

## 4. Collect Results

Wait for all review agents to complete. Extract `Verdict:` and `File:` from each agent return.

If an agent fails to return the expected format, include it in the final table as `unresponsive` and continue. Do not synthesize findings.

---

## 5. Present Findings

Read all returned JSON files. Overall verdict is `action_required` if any reviewer returned blockers, otherwise `pass`.

Present one concise report:

<output_format>

### CODEBASE REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass|action_required]` | |
| [AGENT] | `[pass|action_required|unresponsive]` | `[path or —]` |

## Blockers

| # | Agent | Location | Description | Pri |
|---|-------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | [priority] |

## Suggestions

| # | Agent | Location | Description | Pri | Est | Category |
|---|-------|----------|-------------|-----|-----|----------|
| 1 | [agent] | [location] | [description] | [priority] | [estimate] | [fix|issue] |

</output_format>

Omit empty `Blockers` or `Suggestions` sections. Do not offer to fix items automatically.
