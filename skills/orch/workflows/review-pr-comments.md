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
- `issue_id` (optional): workflow-state key — the normalized issue ID (`issue-N` for GitHub, `PROJ-123` for Linear), never the bare GitHub issue number. If absent, extracted from branch.
- `pr_number` (optional): PR number. If absent, resolved from branch.

**Standalone init** (`lifecycle: "self"` only):
```bash
.agents/skills/orch/scripts/git-context issue-from-branch .
gh pr view --json number -q .number
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```
Use the outputs as `ISSUE_ID` and `PR_NUMBER`. If `.exists` is `false`, resolve `WT_PATH`, read the current branch with `git-context branch`, and run `workflow-state init`.

## API Error Handling

On any `gh` or `.agents/skills/github/scripts/github.sh` failure: halt, report error, ask user: `Retry` | `Skip step` | `Abort`.

## 1. Fetch & Parse PR Data

### 1.1 Async Bot Review Policy

Bot reviews are asynchronous. Triage what exists on the PR **right now** — never block triage on a bot reaching terminal status first. Bot prose is never parsed as a gate: emoji reactions, sticky comments, and checklist text carry no gating weight. Comments that arrive after this pass are caught by a later triage pass, by the caller's review gate (`submit-pr.md` § 4: the GitHub-native reviewer-gate verdict — approval or review-at-head per the resolved mode — polled via `approval-wait` together with new comments), or by its merge gates (`submit-pr.md` § 6.1: zero unresolved comments as a final live check).

### 1.2 Fetch Actionable Data

```bash
.agents/skills/github/scripts/github.sh pr-data "[PR_NUMBER]" --actionable
```
Use the JSON output as `PR_DATA`.

Output: `threads` (inline) + `comments` (PR-level).

### 1.3 Filter Comments

1. **Get baseline timestamp** for re-run filtering:
   ```bash
   mkdir -p tmp
   gh api user -q .login
   .agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --pattern "Recommendations.*Processed" --author "[GH_USER_FROM_PREVIOUS_COMMAND]"
   # Save output to tmp/summary_comment_[PR_NUMBER].json with the harness file-write tool.
   jq -r '.updated_at // empty' tmp/summary_comment_[PR_NUMBER].json
   ```
   Use the `jq` output as `SUMMARY_TS`.

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

3. **Collect bot review comments** — from ALL review bots that have posted so far (not just one):
   ```bash
   .agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --author "[BOT_LOGIN]" --review-summary
   ```
   Derive bot logins from the authors present in `PR_DATA`: thread/comment authors ending in `[bot]`, plus reaction-only bots via `.reactions`. Get the review-summary comment from each such bot by running the command once per bot with the literal bot login. `--review-summary` picks, in order: "View job" sticky, review-section comment, then the bot's earliest comment (Codex-style submission post). Do not use a shell `for` loop or `IFS` split for required comment collection in Codex.
   If no bot has posted anything yet, that is normal in the async model — continue with the human and inline comments that exist; do not wait for bots.

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

1. **Identify parent issue**: use caller `issue_id` when provided; otherwise run `.agents/skills/orch/scripts/git-context issue-from-branch .` and use the output as `[ISSUE_ID]` — the normalized workflow-state key (e.g. `issue-290`), never the bare GitHub issue number. If no issue id matches, ask user.

2. **Get worktree**:
   ```bash
   .agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
   .agents/skills/worktree/scripts/worktree path [ISSUE_ID]
   ```
   If the worktree does not exist, use `.` for `WT_PATH`; otherwise use the path output.

3. **Decision context**: `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]`. Collect matching IDs and summaries for § 3 delegation prompt.

   The `path` fields in this JSON output are the ONLY authorized source for decision file paths in delegation guidance — the CLI resolves them from the decision index; never compose or recall a decision path from memory, however plausible the `DXXX-slug` looks (vstack#696). Verify every collected path before injecting it (belt-and-suspenders against index drift) — one simple command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

   **If the check fails**: omit that path and carry the one-line note `decision index lookup failed for [DECISION_ID]` in the decision-context lines instead — a broken path must never reach a domain agent.

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
[For each verified decision: "[DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "decision index lookup failed for [DECISION_ID]"]
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
4. Create `[WORKTREE_PATH]/tmp` if needed, then save JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` with the harness file-write/edit tool. In Codex, use `apply_patch`; do not use shell redirection, heredocs, `tee`, `echo >`, command substitution, or redirected `cat` writes.
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
   3. Create `[WORKTREE_PATH]/tmp` if needed, then save to `[WORKTREE_PATH]/tmp/review-arch-synthesis-YYYYMMDD-HHMMSS.json` with the harness file-write/edit tool. In Codex, use `apply_patch`; do not use shell redirection, heredocs, `tee`, `echo >`, command substitution, or redirected `cat` writes. Return:

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

1. **Ensure worktree**:
   ```bash
   .agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
   .agents/skills/worktree/scripts/worktree path [ISSUE_ID]
   ```
   If the worktree is missing, run:
   ```bash
   .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --pr [PR_NUMBER]
   ```
   Use the existing path output or create output as `WT_PATH`.

2. **Group items** by `agent` field.

3. **Stamp the round, then delegate fixes** per agent group (reuse existing dev agent if available). `dev_round_id` binds step 5 `dev-artifact-check` acceptance to THIS cycle's receipt (deterministic identity — vstack#776); `dev_delegated_at` is the watchdog deadline. Run each as its own tool call, immediately before the delegation:

   ```bash
   .agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
   ```
   Use the printed token as `[DEV_ROUND_ID]`; note this group's delegated item numbers (`#[N]`) as `[ITEM_NUMBERS]` (comma-separated) for step 5's exact item-set check.

   ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` = technical fix only; the agent owns process per `dev/workflows/dev-fix.md`.

   <delegation_format>
   Follow workflow: .agents/skills/dev/workflows/dev-fix.md

   Source: pr-comments
   Issue: [ISSUE_ID]
   PR: #[PR_NUMBER]
   Worktree: [WORKTREE_PATH]
   Round ID: [DEV_ROUND_ID]
   Artifact Key: [ISSUE_ID]

   Review items:
   [For each item marked "Fixing":]
   ---
   #[N] | [AGENT] | [LOCATION]
   Title: "[TITLE]"
   Description: "[DESCRIPTION]"
   Recommendation: "[RECOMMENDATION]"
   ---
   </delegation_format>

5. **Wait for completion, then accept deterministically.** Acceptance is a function of two checks — **A** (the round-scoped on-disk artifact) and **B** (git completion for this fix round) — never the return message, which is informational for display (a return can be lost to a harness tool timeout mid-tail, vstack#770).

   **Check A** — read `dev_round_id`, then run `dev-artifact-check` in round mode with this group's item numbers (run each as its own tool call):

   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
   ```
   ```bash
   .agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items [ITEM_NUMBERS]
   ```
   `--expect-items [ITEM_NUMBERS]` requires the artifact's `items[]` to cover EXACTLY the delegated set (each once, no unknown/duplicate, valid decision, non-empty reasoning). The round id guarantees only THIS cycle's receipt is read (vstack#776).

   **Check B** — the fix commit landed and nothing was left behind:

   ```bash
   git -C "[WORKTREE_PATH]" status --porcelain
   # Must be empty (clean worktree).
   git -C "[WORKTREE_PATH]" log -1 --oneline
   # Shows the fix commit reported by the artifact/return.
   ```
   `B = pass` when the worktree is clean and the reported fix commit resolves in the log — or the round applied nothing and correctly made no new commit (an all-items-skipped fix leaves HEAD unchanged; B passes on a clean worktree).

   **Decision table.** Apply the fix-round A×B acceptance table in [`dev-fix.md` § 6](dev-fix.md) (the canonical fix-round table — including exact-commit binding on `ok==true`, the bounded git re-read on `ok==true`+`B fail`, and the report-only tail-reconciliation nudge on `ok==false`+`B pass`, never re-running the fix), with these step-pointer deltas for this workflow:

   - **Accept** (`ok==true`, B pass) → handle results (step 6), then push (step 7).
   - **`ok==false`, B pass** → the tail-reconciliation nudge's recovered per-item decisions drive the replies (step 8) and § 8 state (dev-fix's "step 7" maps here to steps 6-8/§ 8).
   - Dev-vs-reviewer asymmetry is the same — see [SKILL § Wait for Agent Return Before Acting](../SKILL.md#wait-for-agent-return-before-acting).

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
   # [ISSUE_ID] is the workflow-state key (e.g. issue-290), matching the
   # state file created at init — never the bare tracker number (290).
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.replied '{"source_id":"[THREAD_ID]","commit":"[COMMIT_SHA]","outcome":"[applied|skipped|blocked|already_fixed]"}'
   ```

   PR-level comments and human-only threads remain deferred to § 7.1.

### 6.2 Create Issues

**Skip if** no issue suggestions AND no blocked items.

1. **Build audit-input file** from issue suggestions + blocked items
2. **Write file**: `[WORKTREE_PATH]/tmp/audit-pr-comments-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md` — set `tracker.type` to the resolved `TRACKER` (plus `tracker.repository` `[OWNER/REPO]` for GitHub items) so the audit routes through the correct tracker
3. **Invoke workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.3`

### 6.3 Check for New Comments & Re-Triage

After fixes are pushed, do **not** wait for bots to re-review — re-review rounds are asynchronous, and late findings are caught by the merge gates (zero unresolved comments plus the approval verdict poll). Check once for comments that arrived while fixes were being applied, then loop or exit.

1. **Update iteration count**:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
   ```

2. **Check iteration limit**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pr_comment_review.iterations
   ```
   Use the output as `ITERATIONS`.
   **If** `ITERATIONS >= 5` → § 7.

3. **Check for new comments**:
   ```bash
   # Count unresolved threads + new PR-level comments since last triage
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review_baseline.last_ts // empty'
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved --since "[LAST_TS_FROM_PREVIOUS_COMMAND]"
   ```
   Use the workflow-state output as `LAST_TS_FROM_PREVIOUS_COMMAND`. Read `.count` from the threads JSON output as `NEW_THREADS_FROM_PREVIOUS_COMMAND`.

4. **Route**:

   | `NEW_THREADS_FROM_PREVIOUS_COMMAND` | Action |
   |---------------|--------|
   | `0` | → § 7 |
   | `> 0` | Update baseline, loop to § 1 |

5. **Update baseline** (before looping):
   ```bash
   date -u +%Y-%m-%dT%H:%M:%SZ
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline '{"last_ts":"[NOW_FROM_PREVIOUS_COMMAND]","last_threads":[NEW_THREADS_FROM_PREVIOUS_COMMAND]}'
   ```
   Use the date output as `NOW_FROM_PREVIOUS_COMMAND`.

6. **Loop**: Return to § 1.2 (§ 1.1 is policy only — the comments to triage already arrived).

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
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   # Write SUMMARY_CONTENT to [WORKTREE_PATH]/tmp/pr-comments-summary-[ISSUE_ID]-[TIMESTAMP_FROM_PREVIOUS_COMMAND].md
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
   ```
   Use the summary file path as `SUMMARY_FILE`.

   Determine tracker:

   ```bash
   .agents/skills/orch/scripts/tracker-for-issue "[ISSUE_ID]"
   ```
   Use the output as `TRACKER`.

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

1. **Update state** with cumulative results — run each block as its own tool call; each append runs once per item, so they can't be folded into a single expression:
   ```bash
   # For each fixed item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
   ```
   ```bash
   # For each issue created:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"
   ```
   ```bash
   # For each skipped item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'
   ```

2. **Return**:

   **If managed**: Return to the parent workflow's next section.

   **If standalone**: Session complete.
