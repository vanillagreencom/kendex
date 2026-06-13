# Initialize Session

Set up team, auth, cache, and workflow state for a worktree session.

## Inputs

| Command | Flow |
|---------|------|
| `initialize` | § 1 → § 2 |
| `initialize [ISSUE_ID]` | § 1 → § 2 |
| `initialize github OWNER/REPO#N` | normalize to `issue-N`, then § 1 → § 2 |
| (from start-worktree.md) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `lifecycle` (optional): `"managed"` (return to caller at § 2) | `"self"` (default, standalone).
- `issue_id` (optional): Issue ID. If absent, extracted from branch.
- `tracker` (optional): `linear` or `github`.
- `github_repo` (optional): `OWNER/REPO` for GitHub work items.

---

## 1. Initialize

> If you are running in **Claude Code**: Create a team before any other steps — before auth checks, cache sync, or workflow-state init. All agents launch within the team. Other harnesses have no team concept; skip this.

1. **Run**: `.agents/skills/orch/scripts/session-init --json [ISSUE_ID]`
   - Pass `[ISSUE_ID]` as a positional argument if provided; otherwise omit it.
   - For GitHub work items, pass the original form when available:
     ```bash
     .agents/skills/orch/scripts/session-init --json github [OWNER/REPO]#[N]
     ```
   - Script resolves `ISSUE_ID` from the argument or current branch and returns it as `issue_id` in JSON output. `github OWNER/REPO#N` returns `issue-N`.
   - In Codex-managed worktrees with an explicit issue, the script normalizes the app-created detached branch to the lower-case issue branch before workflow-state initialization.
   - Read `issue_id` from output; if empty, fall back to the sanitized branch name (replace `/` with `-`) for workflow-state and team naming.
   - Resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution).

2. **If `gh_auth` is false** → report error and fix before proceeding. **Linear only**: also require `linear_auth.ok`; GitHub work items do not need Linear auth.

3. **Set `WORKTREE_PATH`** to current working directory.

4. **Sync cache** — **Linear only**:
   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

5. **Init workflow state**:
   ```bash
   .agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --team "[ISSUE_ID_LOWERCASE]" \
     --agent "[AGENT]" --worktree "[WORKTREE_PATH]" --branch "[BRANCH]"
   ```
   QA fields (`--qa-labels`, `--sub-issues`) set later via `workflow-state set` when known.

---

## 2. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — session initialized.
