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
- `issue_id` (optional): workflow-state key — the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number. If absent, extracted from branch.
- `tracker` (optional): `linear` or `github`.
- `github_repo` (optional): `OWNER/REPO` for GitHub work items.

---

## 1. Initialize

> If you are running in **Claude Code**: Create a team before any other steps — before auth checks, cache sync, or workflow-state init. All agents launch within the team. Other harnesses have no team concept; skip this.

1. **Standalone lifecycle with an explicit Linear `[ISSUE_ID]` (argument or caller context): run step 3's container guard FIRST, then return here** — `session-init` normalizes/creates the issue-named branch for explicit worktree issues, which would manufacture exactly the container branch artifact the guard forbids. (A branch-derived ID has no explicit argument and creates nothing new; it takes the steps in written order.) **Run**: `.agents/skills/orch/scripts/session-init --json [ISSUE_ID]`
   - Pass `[ISSUE_ID]` as a positional argument if provided; otherwise omit it.
   - For GitHub work items, pass the original form when available:
     ```bash
     .agents/skills/orch/scripts/session-init --json github [OWNER/REPO]#[N]
     ```
   - Script resolves `ISSUE_ID` from the argument or current branch and returns it as `issue_id` in JSON output. `github OWNER/REPO#N` returns `issue-N`.
   - In Codex-managed worktrees with an explicit issue, the script normalizes the app-created detached branch to the lower-case issue branch before workflow-state initialization.
   - Read `issue_id` from output; if empty, fall back to the sanitized branch name (replace `/` with `-`) for workflow-state and team naming.
   - Resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution).

2. **If `gh_auth` is false** → report error and fix before proceeding. **Linear only**: also require `linear_auth.ok` and `linear_auth.writes_enabled`; GitHub work items do not need Linear auth.

   `writes_enabled: false` means no `LINEAR_TEAM` is configured for this project, so every Linear write in this workflow will refuse — stop here and set it (`vstack.settings.toml` `[env]`, or `.env.local`) rather than syncing and failing at the first state change. Report `linear_auth.warnings` verbatim; they name the resolved target and its source.

3. **Container guard** — Linear work items (explicit `[ISSUE_ID]` or branch-derived), standalone lifecycle only (managed callers run their own preflight before delegating here). Ordering is defined in step 1: explicit IDs run this guard before `session-init`; branch-derived IDs run it here, after resolution. The guard itself: sync the cache (`.agents/skills/linear/scripts/linear.sh sync --reconcile`; step 6 below then just re-verifies) and fetch `.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle`. Apply the container classification (SKILL.md → Coordination): a `(one PR)` title marker always wins; without it, children present or `agent:multi` label → CONTAINER. Container → STOP HERE, before any state exists — no lease claim, no workflow state: containers are never initialized (they hold no implementation state; each child is the session/PR unit). Report the container verdict and its unblocked children instead. A LEAF whose `parent_id` is set gets the full Ancestor gate (SKILL.md → Coordination) the same way: walk the chain, classify each ancestor, and gate on the union of the leaf's own and every container ancestor's blockers (states fetched in ≤50-id chunks with every id verified returned, only non-terminal `state_type` blocks) — a blocked child STOPS here too, before the lease exists, with its live blockers named. An enclosing `(one PR)` bundle claims the work item TERMINALLY: stop without leasing or initializing the child (initializing the unchanged child id would split the single-PR session this guard exists to prevent) and route to the parent (`/orch start [PARENT_ID]`).

4. **Set `WORKTREE_PATH`** to current working directory.

5. **Claim the worktree for this session.** `create` never claims — a lease means "a live session is working here", and a session initializing state in the worktree is that session. This shared step covers every route into a worktree session, including worktree-launched ones that never pass through `start.md`. **Skip if** `WORKTREE_PATH` is the main checkout, not a linked worktree (the guard refuses the main checkout).

   ```bash
   .agents/skills/worktree/scripts/worktree-session-guard claim [WORKTREE_PATH] --owner [ISSUE_ID]
   ```

   While the lease is held, `worktree cleanup` will not collect this tree and another session's `create --reuse` is refused by name. `worktree remove` releases it at teardown, so nothing else has to.

   Do **not** pass `--repo`: `claim` and `refresh` reject it, and a swallowed failure leaves the guard looking installed while it silently never claims.

   Exit 75 means another session already holds the lease — coordinate with that owner instead of proceeding ([Worktree Scope](../SKILL.md#worktree-scope)). Exit 1 with a `flock` message means the host has no `flock`, so the session runs unguarded; continue, but do not assume the tree is protected.

6. **Sync cache** (skip if already synced by the container guard) — **Linear only**:
   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

7. **Init workflow state**:
   ```bash
   .agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --team "[ISSUE_ID_LOWERCASE]" \
     --agent "[AGENT]" --worktree "[WORKTREE_PATH]" --branch "[BRANCH]"
   ```
   QA fields (`--qa-labels`, `--sub-issues`) set later via `workflow-state set` when known.

---

## 2. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — session initialized.
