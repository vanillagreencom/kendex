# Workflow: `github start` — GitHub Issue Session Entry

Initialize a GitHub issue session, verify status, create/reuse the issue worktree, spawn the selected harness, and enter the GitHub issue watch loop.

This is the GitHub issue-mode start workflow. For ad-hoc or workflow sessions that are not tied to a GitHub issue/worktree, use `scripts/flightdeck-session start` or `flightdeck session start`, then supervise with `workflows/shared/session-watch.md` and `workflows/shared/session-handle-prompt.md`.

## Inputs

| Command | Flow |
|---------|------|
| `github start <N>` | § 1 → § 2 → § 3 → § 4 |

**Required**: `<N>` is a numeric GitHub issue number.

---

## 1. Initialize Session

### 1.1 Validate Issue Argument

1. Require a single numeric GitHub issue number.
2. If missing or non-numeric, ask the user for the issue number or stop with a concise error.
3. Set `ISSUE_ID=<N>`.

### 1.2 Present Preflight Status

1. **Run**: `FLIGHTDECK_PREFLIGHT=1 .agents/skills/flightdeck/scripts/flightdeck-dashboard launch`

   This verifies a live tracked `flightdeck-dashboard` entry/pane and ignores stale same-name windows. `FLIGHTDECK_DASHBOARD=0` is the only explicit opt-out.

2. **If dashboard launch fails**, surface stderr and stop. Do not spawn an issue pane when the dashboard invariant is not satisfied.

3. **Check GitHub CLI auth**:
   ```bash
   gh auth status
   ```
   If auth fails, stop and tell the user to authenticate `gh` before continuing.

### 1.3 Fetch Issue

Fetch authoritative issue data:

```bash
gh issue view "$ISSUE_ID" --json number,title,state,body,url,labels,assignees,milestone,closed,closedAt
```

1. If the issue does not exist, stop.
2. If `state == CLOSED`, present:

   <output_format>
   GitHub issue #[ISSUE_ID] is already closed: [TITLE]
   URL: [URL]
   </output_format>

   Ask: `Watch existing PR/session anyway` | `Stop`. Only continue on explicit watch/spawn confirmation.
3. Store the issue title, URL, labels, and body excerpt for the launch summary.

---

## 2. Prepare Worktree

### 2.1 Check Main Worktree Cleanliness

1. **Run check**:
   ```bash
   .agents/skills/worktree/scripts/worktree check
   ```

2. **If uncommitted** → Ask user: `Stash` | `Commit` | `Continue anyway`.

3. **If unpushed** → Ask user: `Push unpushed commits to the default branch?` (show commits), then:
   ```bash
   DEFAULT_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
   [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
   git push origin "$DEFAULT_BRANCH"
   ```

### 2.2 Active Work Conflict Scan

1. List active worktrees:
   ```bash
   .agents/skills/worktree/scripts/worktree list
   ```
2. If another live Flightdeck entry is working on the same issue number, stop and point to the existing entry.
3. If another live entry has an open PR touching the same files, do not block here; the `github watch` prompt handlers re-check PR state before merge/force-push decisions.

### 2.3 Create Worktree

Worktree creation is idempotent: existing worktrees are reused and rebased onto the default branch.

```bash
WT_PATH=$(.agents/skills/worktree/scripts/worktree create "$ISSUE_ID")
```

If the helper reports rebase conflicts, stop and tell the user to resolve or remove the worktree before retrying.

---

## 3. Select Launch Profile

Use this whenever § 4 launches a pane through `open-terminal`.

1. **Recommend a default profile** by issue complexity:

   | Work type | Recommended profile | Command flags |
   |-----------|---------------------|---------------|
   | Normal/complex implementation | Claude Code, strongest reasoning | `--harness claude --model 'opus[1m]' --effort max` |
   | OpenAI/Codex-preferred implementation | Codex, strongest reasoning | `--harness codex --model gpt-5.5 --effort xhigh` |
   | Pi-native work | Pi, strongest OpenAI reasoning | `--harness pi --model openai-codex/gpt-5.5 --effort xhigh` |
   | OpenCode-preferred implementation | OpenCode, strong model (effort recorded unsupported) | `--harness opencode --model openai/gpt-5.5 --effort xhigh` |

   Notes:
   - `open-terminal` maps effort per harness: Claude → `--effort`, Codex → `-c model_reasoning_effort=...`, Pi → `--thinking`. OpenCode validates the model via `opencode models`, passes `--model`, and records effort as unsupported because no validated top-level effort flag exists.
   - If the user chooses a model/effort different from the recommendation, pass exactly their values.
   - Do not choose bare harness defaults for a fresh LLM pane; subagents generated with model/effort definitions are exempt.

2. **Ask user** for launch profile. Include the recommendation first, then: `Claude max` | `Codex xhigh` | `Pi xhigh` | `OpenCode xhigh` | `I'll launch it myself` | custom model/effort.

3. **Capture** `[HARNESS]`, optional `[MODEL]`, optional `[EFFORT]`. Build `[LAUNCH_FLAGS]` as:
   ```bash
   --harness [HARNESS] [--model MODEL] [--effort EFFORT]
   ```

---

## 4. Launch and Watch

### 4.1 Present Launch Summary

<output_format>
GitHub issue #[ISSUE_ID] — [TITLE]
URL: [URL]
Worktree: [WT_PATH]
Harness: [HARNESS]
Model: [MODEL or default]
Effort: [EFFORT or default]
</output_format>

### 4.2 Spawn

- **Profile selected**:
  ```bash
  .agents/skills/flightdeck/scripts/open-terminal --tracker github "$ISSUE_ID" [LAUNCH_FLAGS]
  ```
  Then invoke `⤵ workflows/github/watch.md [ISSUE_ID] § 1-8 → § 1`.

- **Manual**: Show the recommended command and worktree path so the user can run it themselves:
  ```bash
  .agents/skills/flightdeck/scripts/open-terminal --tracker github "$ISSUE_ID" [LAUNCH_FLAGS]
  ```
  Then return to the user.

### 4.3 Watch Loop Entry

`workflows/github/watch.md § 1` registers or refreshes the numeric issue entry, then runs `workflows/shared/session-watch.md` for daemon spawn/ack/yield. Do not duplicate the generic loop here.

---

## Returns

To the GitHub issue watch loop. The watch loop handles prompts, terminal verification, teardown, and final summary.
