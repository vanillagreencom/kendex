# Linear Start New Issue Workflow

Create a new issue from scratch, set up worktree, and launch session.

## Inputs

| Command | Flow |
|---------|------|
| `linear start new` | § 1 → § 2 → § 3 |
| `linear start new [TITLE]` | Skip title prompt → § 1 step 2 → § 2 → § 3 |

---

## 1. Gather Intent

1. **Sync cache**:
   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

2. **If title provided** as argument → set `TITLE`, skip to step 3.

   **Otherwise** → Ask user: "What do you want to work on?" (free text)

   Parse response: first line = `TITLE`, rest = `DESCRIPTION_NOTES`.

3. **Ask user**: "Brief description? (or press enter to skip)"

   If response provided → set `DESCRIPTION_NOTES`.

---

## 2. Create Issue

### 2.1 Select Project

1. **List active projects**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache projects list --state started --format=compact
   ```

2. **Suggest project** — infer from title/description keywords (project-configurable keyword-to-project mapping):

   | Keywords | Suggested Project |
   |----------|-------------------|
   | (domain-specific terms) | Matching project |
   | No match | Most recently active project |

3. **Ask user**: "Which project?" with options:
   - `[SUGGESTED_PROJECT]` (suggested, shown first)
   - Other active projects as additional options
   - `Other` (free text)

### 2.2 Determine Agent

Infer `agent:[TYPE]` label from title/description using project-configurable keyword-to-agent mapping:

| Keywords | Agent | Label |
|----------|-------|-------|
| (domain-specific terms) | [AGENT_TYPE] | `agent:[TYPE]` |
| No match | — | (no agent label) |

### 2.3 Create Bundle

Always create as a parent + sub-issue pair. Parent coordinates, child implements.

1. **Derive titles**:
   - `PARENT_TITLE`: High-level name (e.g., user says "add zoom" → "Feature: Zoom")
   - `CHILD_TITLE`: Implementation task (e.g., "Implement zoom feature") — keep bare unless user gave specific scope.

2. **Create parent issue**:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues create \
     --title "[PARENT_TITLE]" \
     --project "[PROJECT_ID]" \
     --description "## Sub-Issues\n\n- (pending creation)" \
     --state "Todo" \
     --labels "[AGENT_LABEL]"
   ```
   Capture `PARENT_ID`.

3. **Create sub-issue**:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues create \
     --title "[CHILD_TITLE]" \
     --project "[PROJECT_ID]" \
     --parent "[PARENT_ID]" \
     --description "[DESCRIPTION_NOTES if provided, otherwise: 'Scope TBD.']" \
     --state "Todo" \
     --labels "[AGENT_LABEL]"
   ```
   Capture `CHILD_ID`.

4. **Update parent description** with actual child ID:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [PARENT_ID] \
     --description "## Sub-Issues\n\n- [CHILD_ID]: [CHILD_TITLE]"
   ```

5. **Set `ISSUE_ID`** = `PARENT_ID` (worktree session orchestrates from parent, delegates sub-issues to agents).

6. **Output**:

   <output_format>

   Bundle: [PARENT_ID] — [PARENT_TITLE]
   └─ [CHILD_ID] — [CHILD_TITLE]
   Project: [PROJECT_NAME]
   Agent: [AGENT or "unassigned"]

   </output_format>

---

## 3. Create Worktree & Launch

1. **Run check**: `.agents/skills/worktree/scripts/worktree check` — returns `{uncommitted, unpushed, unpushed_commits}`

2. **If uncommitted** → Ask user: `Stash` | `Commit` | `Continue anyway`

3. **If unpushed** → Ask user: `Push unpushed commits to the default branch?` (show commits), then:
   ```bash
   DEFAULT_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
   [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
   git push origin "$DEFAULT_BRANCH"
   ```

4. **Create worktree**: `WT_PATH=$(.agents/skills/worktree/scripts/worktree create [ISSUE_ID])`

5. **Launch**: Ask user for harness/model/effort profile. Explicit model/effort selection is required for new LLM panes; subagents generated with their own model/effort definitions are exempt. Recommend one of:
   - Claude max: `--harness claude --model 'opus[1m]' --effort max`
   - Codex xhigh: `--harness codex --model gpt-5.5 --effort xhigh`
   - Pi xhigh: `--harness pi --model openai-codex/gpt-5.5 --effort xhigh`
   - OpenCode model: `--harness opencode --model openai/gpt-5.5 --effort xhigh` (`open-terminal` validates the model and records effort as unsupported)
   - `I'll launch it myself`

   If the user chooses custom values, pass exactly those flags. Do not choose harness defaults for a fresh LLM pane.
   - **Profile selected**: `.agents/skills/flightdeck/scripts/open-terminal [ISSUE_ID] [LAUNCH_FLAGS]`
   - **Manual**: Show the recommended command and worktree path so the user can run it themselves.

→ end
