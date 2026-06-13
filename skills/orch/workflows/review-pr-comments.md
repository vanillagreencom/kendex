# PR Comment Triage Workflow

Route PR review comments to domain agents, auto-fix valid items, loop until stable.

## Inputs

| Command | Behavior |
|---------|----------|
| `review-pr-comments` | Full triage: analyze, fix, create issues, reply |
| `review-pr-comments [PR-number]` | Specific PR by number |
| `review-pr-comments [BRANCH_NAME]` | Specific PR by branch |
| `review-pr-comments --dry-run [N]` | Parse + analyze, stop before § 6 |
| (from submit-pr/start-worktree) | Managed lifecycle with caller context |

**Dry-run**: Runs §§ 1-5, presents triage report, stops before fixes. No side effects.

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 8) | `"self"` (default, standalone).
- `issue_id` (optional): issue tracker ID. If absent, extracted from branch.
- `pr_number` (optional): PR number. If absent, resolved from branch.

**Standalone init** (`lifecycle: "self"` only):
```bash
ISSUE_ID=$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN")
PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null)
if ! .agents/skills/orch/scripts/workflow-state exists $ISSUE_ID; then
  WT_PATH=$(.agents/skills/worktree/scripts/worktree path $ISSUE_ID 2>/dev/null || echo ".")
  .agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git rev-parse --abbrev-ref HEAD)"
fi
```

## API Error Handling

On any `gh` or `.agents/skills/github/scripts/github.sh` failure: halt, report error, ask user: `Retry` | `Skip step` | `Abort`.

## 1. Fetch & Parse PR Data

### 1.1 Wait for All Bot Reviews

Multiple bots may review on different timelines. Wait for all configured reviewers before triaging.

```bash
WAIT_RESULT=$(.agents/skills/orch/scripts/bot-review-wait [PR_NUMBER] 15 600 --json --reviewers "$BOT_REVIEWERS")
BOT_STATUS=$(echo  "$WAIT_RESULT" | jq -r '.status')
BOT_VERDICT=$(echo "$WAIT_RESULT" | jq -r '.verdict')
PENDING_REVIEWERS=$(echo "$WAIT_RESULT" | jq -r '.pending_reviewers | join(", ")')
```

`$BOT_REVIEWERS`: comma-separated bot usernames. Default: auto-detected from formal reviews, known review-bot comment summaries, PR-body reactions, and own-comment reactions. Custom comment-only bots must be configured explicitly via `BOT_REVIEWERS` / `--reviewers`.

**Polling behavior**: per reviewer, status is `pending|approved|changes|skipped|unknown`. Claude-style comments parse `✅ Approved` / `Changes requested`; Codex-style signals use 👀 = pending, 👍 = approved, inline threads = changes. Returns `status=complete` only when no reviewer is pending. If `status=timeout`, ask the user `Wait` | `Skip pending bot` (configure via `BOT_SKIPPED_REVIEWERS`) | `Proceed without`. Late arrivals are caught in § 6.3.

### 1.2 Fetch Actionable Data

```bash
PR_DATA=$(.agents/skills/github/scripts/github.sh pr-data "[PR_NUMBER]" --actionable)
```

Output: `threads` (inline) + `comments` (PR-level).

### 1.3 Filter Comments

1. **Get baseline timestamp** for re-run filtering:
   ```bash
   mkdir -p tmp
   GH_USER=$(gh api user -q .login)
   .agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --pattern "Recommendations.*Processed" --author "$GH_USER" > tmp/summary_comment_[PR_NUMBER].json
   SUMMARY_TS=$(jq -r '.updated_at // empty' tmp/summary_comment_[PR_NUMBER].json)
   ```

2. **Filter comments**. When `$SUMMARY_TS` is set, filter PR-level comments with `select(.created_at > $SUMMARY_TS)`.

   **Exclude (both sources):**
   - Noise bots: `dependabot[bot]`, `github-actions[bot]`, `renovate[bot]`, issue-tracker sync bots
   - **If re-run** (`SUMMARY_TS` set): Comments posted before `SUMMARY_TS`

   **Exclude (review threads only):**
   - Resolved threads (`isResolved: true`)
   - Outdated threads (`isOutdated: true`)

   **Exclude (PR-level comments only):**
   - Status updates with no actionable content

   **Keep**: All reviewer comments (human + bot) with actionable content + unresolved, current threads.

3. **Collect bot review comments** — from ALL review bots (not just one):
   ```bash
   # Get the review-summary comment from each bot reviewer.
   # --review-summary picks (in order): "View job" sticky → review-section
   # comment → the bot's earliest comment (Codex-style submission post).
   IFS=',' read -ra REVIEW_BOTS <<< "$BOT_REVIEWERS"
   for BOT in "${REVIEW_BOTS[@]}"; do
     .agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --author "$BOT" --review-summary
   done
   ```
   If no bot reviews found AND no bot reactions on the PR body: ask user `Wait` | `Skip triage`.
   (Reaction-only bots like Codex may have no summary comment yet — check `.reactions` from `pr-data` to confirm presence.)

### 1.4 Extract Comment Data

1. **Extract from review threads** — fields per comment:
   - `thread_id`, `author`, `body`, `path`, `line`, `url`
   - `source`: `inline`

2. **Extract from PR-level comments** (human reviewers only):
   - `comment_id`, `author`, `body`, `path` (null), `line` (null), `url`
   - `source`: `pr-level`

3. **Parse bot review comments** — extract from ALL bot reviewers. For each bot's review comment or sticky, extract section headers and bullets. Categorize by keywords:

   | Keywords (case-insensitive) | Source Type |
   |-----------------------------|-------------|
   | "inline comment" | Skip (redundant with review threads) |
   | "architect", "design", "pattern" | `pr-level:architectural` |
   | "doc", "readme", "comment" | `pr-level:documentation` |
   | "security", "auth", "vulnerab", "inject" | `pr-level:security` |
   | "test", "coverage", "assert" | `pr-level:testing` |
   | "perf", "latency", "throughput" | `pr-level:performance` |
   | No match / "follow-up", "future", "todo" | `pr-level:suggestion` |

   Fields per extracted item:
   - `comment_id`, `author` (bot name), `body`, `section`, `path` (null), `line` (null), `url`
   - `source`: from keyword matching
   - `blocking`: `true` for security items, `false` if "non-blocking"/"optional", `false` otherwise

   **Bot inline threads**: Bot review threads are already captured in step 1 as regular review threads (bot username as `author`) — do NOT filter them out.

### 1.5 Resolve Issue Context

1. **Identify parent issue**: Extract `[ISSUE_ID]` from branch name. If not found, ask user.

2. **Get worktree**:
   ```bash
   WT_PATH=$(.agents/skills/worktree/scripts/worktree path [ISSUE_ID] 2>/dev/null || echo ".")
   ```

3. **Decision context**: `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]`. Collect matching IDs and summaries for § 3 delegation prompt.

## 2. Detect Domains

Map each comment to a domain based on source and file path. Domain-to-agent routing is project-configurable — example defaults:

| Source / Path Pattern | Domain Agent (example) |
|-----------------------|------------------------|
| `pr-level:architectural` | architecture review agent |
| `pr-level:documentation` | documentation review agent |
| `pr-level:security` | security review agent |
| `pr-level:testing` | test review agent |
| `pr-level:performance` | performance QA agent |
| `pr-level:suggestion` | infer from keywords, default architecture review agent |
| Path inference | infer from component paths (project-configurable) |
| `docs/**` | documentation review agent |
| No file path (general comment) | architecture review agent |

## 3. Analyze via Domain Agents

### 3.1 Route to Domain Agents (Parallel if Multiple)

**Delegate to domain agents** from § 2 mapping (parallel if multiple).

<delegation_format>
Analyze these PR review comments for your domain.

PR: #[PR_NUMBER] - [TITLE]
Parent Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]

Decision context (read before classifying — do NOT suggest changes that contradict these):
[For each matching decision: "[DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[If none: "No linked decisions found."]

Comments for your review:
[For each comment:]
---
Source ID: [THREAD_ID or COMMENT_ID]
Source Type: [inline or pr-level]
Author: @[AUTHOR]
File: [PATH]:[LINE] (or "general" if no file)
Comment: "[BODY]"
Blocking: [true/false]
URL: [URL]
---

1. Read `workflows/recommendation-bias.md`. Apply its verification prerequisite and decision flow to ALL findings — read the actual source files before classifying any comment.
2. Classify into arrays per `../../reviewer/schemas/review-finding.md` schema:
   - `blockers[]`: Passed checks + blocking=true or P1/P2 priority
   - `suggestions[]`: Passed checks + blocking=false
   - `questions[]`: QUESTION type — include draft response
   - NOISE or failed checks: Omit entirely
   - **Already fixed**: If a comment is verified resolved by a prior fix commit, do NOT omit silently. Return it in `questions[]` with `outcome: "already_fixed"`, `commit: "[SHA]"`, and a `draft_response` — orchestrator replies & resolves in § 6.1 step 8.
3. Preserve `source_id` and `source_type` from input on each item.
4. Save JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`.
5. Return exactly:

   <output_format>
   Report: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
   Verdict: [pass|action_required]
   </output_format>
</delegation_format>

### 3.2 Collect Results

1. **Wait for all agents**. Extract `Report` path and `Verdict` from each.
2. **Store paths** in `JSON paths[]` for § 5.

## 4. Synthesize (if multi-domain)

**Skip if** comments from single domain only.

1. **Delegate to architecture review agent** for cross-cutting analysis:

   <delegation_format>
   Synthesize domain agent analyses of PR comments.

   PR: #[PR_NUMBER] - [TITLE]
   Parent Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]

   Domain Report JSONs:
   [List paths from § 3.2]

   Read each JSON. Identify cross-cutting concerns:
   1. Issues spanning multiple domains
   2. Dependencies between suggestions (output: `dependency: #A blocks #B (reason)`)
   3. Gaps at domain boundaries
   4. Conflicts between domain recommendations (flag both, don't resolve)

   **Do NOT** modify or overrule domain agent findings. Add your own only.

   1. Read `workflows/recommendation-bias.md`. Apply its decision flow.
   2. Build JSON per `../../reviewer/schemas/review-finding.md` with YOUR cross-cutting findings only.
   3. Save to `[WORKTREE_PATH]/tmp/review-arch-synthesis-YYYYMMDD-HHMMSS.json` and return:

   <output_format>
   Report: [WORKTREE_PATH]/tmp/review-arch-synthesis-YYYYMMDD-HHMMSS.json
   Verdict: [pass|action_required]
   </output_format>
   </delegation_format>

2. **Add returned path** to `JSON paths[]`.

## 5. Present Triage Report

1. **Read all JSON files** from `JSON paths[]`.

2. **Aggregate items** across all agents, preserving `agent` attribution:
   - `blockers[]` → Blockers
   - `suggestions[]` with `category: "fix"` → Fix Items
   - `suggestions[]` with `category: "issue"` → Issue Items (defer to § 6.2)
   - `questions[]` → Questions (auto-response in § 7.1)

3. **Deduplicate** by (location, description) — keep first, note all sources.

4. **Decide action** for each fix item. Auto-fix all valid items — do NOT prompt for selection.

   | Item | Action | Reason |
   |------|--------|--------|
   | Blocker or fix with clear recommendation | **Fixing** | Valid, actionable |
   | Contradicts active decision | **Skipping** | Cite decision ID |
   | Vague, no clear deliverable | **Skipping** | Not actionable |
   | Unrelated to PR scope | **Skipping** | Out of scope → issue |

5. **Present table** showing what will be fixed and what won't:

<output_format>

### PR TRIAGE — #[PR_NUMBER] [TITLE] (pass [N])

| Field | Value |
|-------|-------|
| Branch | [headRefName] → Parent: [ISSUE_ID] |
| Reviewers | [BOT_1], [BOT_2], [HUMAN_1] |
| Summary | N blocker, N fix, N issue, N questions |

| Agent | Verdict | Blk | Fix | Issue | Q |
|-------|---------|-----|-----|-------|---|
| [AGENT] | ✅ pass | 0 | 1 | 0 | 0 |
| [AGENT] | ⚠️ action | 1 | 1 | 1 | 1 |

### 🔧 FIXING

| # | Agent | Author | Location | Description | Pri |
|---|-------|--------|----------|-------------|-----|
| 1 | [AGENT] | [BOT_1] | [file:line] | [description] | 🔴 |
| 2 | [AGENT] | [BOT_2] | [file:line] | [description] | 🟠 |

### ⏭️ SKIPPING

| # | Agent | Author | Location | Description | Reason |
|---|-------|--------|----------|-------------|--------|
| 1 | [agent] | codex[bot] | [file:line] | [description] | Contradicts D015 |

### 💬 QUESTIONS (auto-responding)

| # | Agent | Location | Question | Draft Response |
|---|-------|----------|----------|----------------|
| 1 | [agent] | [file:line] | [question] | [response] |

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4
Issue suggestions: [N] items → § 6.2 audit
</output_format>

**Omit empty sections.** Proceed immediately to § 6 — no user prompt.

## 6. Apply Fixes & Loop

### 6.1 Delegate Fixes

**Skip if** no items marked "Fixing" in § 5. → § 6.2

1. **Ensure worktree**: `WT_PATH=$(.agents/skills/worktree/scripts/worktree path [ISSUE_ID] 2>/dev/null || .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --pr [PR_NUMBER])`

2. **Group items** by `agent` field.

3. **Delegate fixes** per agent group (reuse existing dev agent if available). ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` = technical fix only; the agent owns process per `dev/workflows/dev-fix.md`.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: pr-comments
   Issue: [ISSUE_ID]
   PR: #[PR_NUMBER]
   Worktree: [WORKTREE_PATH]

   Review items:
   [For each item marked "Fixing":]
   ---
   #[N] | [AGENT] | [LOCATION]
   Title: "[TITLE]"
   Description: "[DESCRIPTION]"
   Recommendation: "[RECOMMENDATION]"
   ---
   </delegation_format>

5. **Wait for completion.**

6. **Handle results**:
   - Applied → mark for reply (§ 7.1)
   - Skipped by agent → add to skipped list with reason
   - Blocked → convert to issue (§ 6.2)

7. **Push**: `git -C "[WORKTREE_PATH]" push origin HEAD`

8. **Reply & resolve addressed threads immediately** — for each item with `source_type: inline` handled in this pass, do not wait for § 7.1:

   | Outcome | Reply body |
   |---------|------------|
   | Applied | `Applied in [COMMIT_SHA]: [SHORT_FIX_SUMMARY]` |
   | Skipped | `Acknowledged — [RATIONALE]` |
   | Blocked → issue | `Tracking in [CREATED_ISSUE_ID]` |
   | Already fixed (from § 3) | Use `draft_response` from finding |

   ```bash
   # The reply bodies above are plain strings without backticks or fenced
   # code, so inline --body (positional) is safe. If a draft_response or
   # rationale contains backticks/fences (e.g. quoted code suggestions),
   # write the body to a file and use --body-file instead.
   .agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" "[REPLY_BODY]" --pr "[PR_NUMBER]"
   # Markdown-heavy alternative:
   #   .agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" --body-file "$REPLY_FILE" --pr "[PR_NUMBER]"
   .agents/skills/github/scripts/github.sh resolve-thread "[THREAD_ID]"
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.replied '{"source_id":"[THREAD_ID]","commit":"[COMMIT_SHA]","outcome":"[applied|skipped|blocked|already_fixed]"}'
   ```

   PR-level comments and human-only threads remain deferred to § 7.1.

### 6.2 Create Issues

**Skip if** no issue suggestions AND no blocked items.

1. **Build audit-input file** from issue suggestions + blocked items
2. **Write file**: `[WORKTREE_PATH]/tmp/audit-pr-comments-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md`
3. **Invoke workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.3`

### 6.3 Wait for New Comments & Re-Triage

After fixes are pushed, bots re-review. Wait for new comments, then loop.

1. **Update iteration count**:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
   ```

2. **Check iteration limit**:
   ```bash
   ITERATIONS=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pr_comment_review.iterations)
   ```
   **If** `ITERATIONS >= 5` → § 7.

3. **Wait 5 minutes** for bot re-reviews:
   ```bash
   sleep 300
   ```

4. **Check for new comments**:
   ```bash
   # Count unresolved threads + new PR-level comments since last triage
   LAST_TS=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review_baseline.last_ts // empty')
   NEW_THREADS=$(.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved --since "$LAST_TS" | jq '.count')
   ```

5. **Route**:

   | `NEW_THREADS` | Action |
   |---------------|--------|
   | `0` | → § 7 |
   | `> 0` | Update baseline, loop to § 1 |

6. **Update baseline** (before looping):
   ```bash
   NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline "{\"last_ts\":\"$NOW\",\"last_threads\":$NEW_THREADS}"
   ```

7. **Loop**: Return to § 1.2 (skip § 1.1 bot-wait on re-triage — comments already arrived).

---

## 7. Present Skipped Summary & Await User

**Always runs** after the comment loop stabilizes (§ 6.3 exits with 0 new comments or max iterations).

### 7.1 Post Replies & Resolve Threads

**Backstop only.** Inline threads handled per-pass in § 6.1 step 8 are already replied & resolved. This step covers PR-level comments, human-only threads, and inline items missed by per-pass handling.

Skip any `source_id` already in `pr_comment_review.replied` to avoid duplicate replies.

1. **Post reply** to each comment from the final pass:

   | Outcome | Response |
   |---------|----------|
   | Applied | `Applied in [SHA]` |
   | Skipped (decision) | `Acknowledged — contradicts [DECISION_ID]` |
   | Skipped (not actionable) | `Acknowledged — not actionable` |
   | Blocked → issue | `Tracking in [ISSUE_ID]` |
   | Issue created | `Tracking in [ISSUE_ID]` |

   **For questions** (automatic): Post `draft_response` from JSON.

   **Posting**: use inline `--body "..."` only for plain strings. If `[RESPONSE]` contains backticks or code fences, write to a file and use `--body-file`:
   - Inline threads (plain): `.agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" "[RESPONSE]" --pr "[PR_NUMBER]"`
   - Inline threads (Markdown): write to `[WORKTREE_PATH]/tmp/reply-[THREAD_ID].md` then `... post-reply "[THREAD_ID]" --body-file "$REPLY_FILE" --pr "[PR_NUMBER]"`
   - PR-level comments (Markdown with quoted blocks): write to `[WORKTREE_PATH]/tmp/comment-[PR_NUMBER].md` then `... post-comment "[PR_NUMBER]" --body-file "$COMMENT_FILE"`
   - Use `1.` `2.` `3.` numbering, never `#N` (GitHub auto-links `#N` to PRs/issues)

   **Contested bot reviews** — when domain agent classifies a bot's blocking comment as noise:
   - Tag bot: `@[BOT_NAME] [RATIONALE]. Please re-review.`
   - Dismiss `CHANGES_REQUESTED`: `.agents/skills/github/scripts/github.sh dismiss-review [PR_NUMBER] --bot --message "[RATIONALE]"`
   - Resolve the thread
   - **Human reviewers**: Tag `@[AUTHOR]` but do NOT dismiss

2. **Resolve threads**: Auto-resolve all threads where a reply was posted. Keep open only threads awaiting human response.

### 7.2 Present Final Summary

Aggregate all passes. Show cumulative totals and all unaddressed items.

<output_format>

### ✅ PR COMMENT TRIAGE COMPLETE

| Metric | Count |
|--------|-------|
| Triage passes | [N] |
| Fixed | [N] |
| Issues created | [N] |
| Replies posted | [N] |
| Threads resolved | [N] |

### ⏭️ ITEMS NOT ADDRESSED

| # | Author | Location | Description | Reason |
|---|--------|----------|-------------|--------|
| 1 | [BOT_1] | [file:fn] | [description] | Contradicts [DECISION_ID] — [reason] |
| 2 | [BOT_2] | [file:fn] | [description] | Not actionable — no specific deliverable |

(Empty if all items were addressed.)

Awaiting your response — ask questions, override skipped items, or confirm done.

</output_format>

**STOP and wait for user.** The user may ask about skipped items, override a skip ("fix #1"), ask follow-up questions, or confirm done: → § 8.

If user requests fixes for skipped items → delegate via § 6.1 (single item), push, return here.

### 7.3 Reconcile & Post Summaries

**If managed**: Skip → § 8

**If standalone**:

1. **Reconcile fixes** — skip if no fixes applied:
   Invoke: `⤵ workflows/fix-reconcile.md § 1-9 → § 7.3 step 2`

2. **Post summary** — skip if no fixes AND no issues created. Write the summary to a file first so Markdown is shell-safe:
   ```bash
   SUMMARY_FILE="[WORKTREE_PATH]/tmp/pr-comments-summary-[ISSUE_ID]-$(date +%Y%m%d-%H%M%S).md"
   mkdir -p "$(dirname "$SUMMARY_FILE")"
   cat > "$SUMMARY_FILE" <<'SUMMARY_EOF'
   [filled SUMMARY_CONTENT — see template below]
   SUMMARY_EOF
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
   ```

   Determine tracker:

   ```bash
   TRACKER=$(.agents/skills/orch/scripts/tracker-for-issue "[ISSUE_ID]")
   ```

   If `TRACKER` is `linear`, post to Linear. GitHub items get linkage via `Closes #N` in the PR body:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
   ```

   ```markdown
   ## Recommendations Processed

   ### Fixed in PR
   - [SOURCE]: [ITEM] — [SHA]

   ### Issues Created
   - [ISSUE_ID] - [TITLE] — [PROJECT]

   ### Not Addressed
   - [SOURCE]: [ITEM] — [REASON]
   ```

## 8. Update State & Return

1. **Update state** with cumulative results:
   ```bash
   # For each fixed item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'

   # For each issue created:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"

   # For each skipped item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'
   ```

2. **Return**:

   **If managed**: Return to the parent workflow's next section.

   **If standalone**: Session complete.
