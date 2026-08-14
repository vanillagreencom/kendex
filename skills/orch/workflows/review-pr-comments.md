# PR Comment Triage Workflow

Route PR review comments to domain agents, fix the valid ones, reply to and resolve every thread.

| Command | Behavior |
|---------|----------|
| `review-pr-comments` | Full triage: analyze, fix, create issues, reply |
| `review-pr-comments [PR-number]` \| `[BRANCH_NAME]` | A specific PR |
| `review-pr-comments --dry-run [N]` | §§ 1-5 only: triage report, no side effects |
| (from submit-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 8) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number; `pr_number`.

**Standalone init** (`lifecycle: "self"`): `git-context issue-from-branch .` and `gh pr view --json number -q .number` give `ISSUE_ID` and `PR_NUMBER`; when `workflow-state exists --json [ISSUE_ID]` reports false, resolve `WT_PATH`, read the branch with `git-context branch`, and run `workflow-state init`.

On any `gh` or `github.sh` failure: halt, report the error, and ask `Retry` | `Skip step` | `Abort`.

## 1. Fetch And Parse

Bot reviews are asynchronous. Triage what exists on the PR **right now** — never block on a bot reaching a terminal state. Bot prose is never a gate: emoji reactions, sticky comments, and checklist text carry no gating weight. Comments arriving later are caught by a later pass, by the caller's review gate, or by its merge gates.

```bash
.agents/skills/github/scripts/github.sh pr-data "[PR_NUMBER]" --actionable
```

The JSON carries `threads` (inline) and `comments` (PR-level).

**Baseline for re-runs.** Find this session's own prior summary comment and use its `updated_at` as `SUMMARY_TS`:

```bash
gh api user -q .login
.agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --pattern "Recommendations.*Processed" --author "[GH_USER_FROM_PREVIOUS_COMMAND]"
```

**Filter.** Exclude noise bots (`dependabot[bot]`, `github-actions[bot]`, `renovate[bot]`, tracker sync bots) from both sources, plus anything created before `SUMMARY_TS` on a re-run. Exclude resolved and outdated review threads, and PR-level status updates with no actionable content. Keep every reviewer comment — human or bot — with actionable content on an unresolved, current thread.

**Bot review summaries.** Derive bot logins from the authors present in the data (anything ending in `[bot]`, plus reaction-only bots) and fetch each one's summary comment, one command per bot with the literal login:

```bash
.agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --author "[BOT_LOGIN]" --review-summary
```

`--review-summary` picks, in order: the "View job" sticky, the review-section comment, then that bot's earliest comment. No bot having posted yet is normal in the async model — continue with the human and inline comments that exist.

**Extract** per item: `thread_id`/`comment_id`, `author`, `body`, `path`, `line`, `url`, and `source` (`inline` or `pr-level`). Bot review summaries additionally get a `section` and a keyword-derived source type — architectural, documentation, security, testing, performance, or plain suggestion — plus `blocking: true` for security items and `false` when the text says non-blocking or optional. Skip anything the bot labels an inline comment: those are already captured as review threads, with the bot username as `author`. Never filter bot inline threads out.

**Issue context.** `issue_id` from the caller, else `git-context issue-from-branch .`; ask the user if nothing matches. Resolve `WT_PATH` from `worktree exists`/`worktree path`, falling back to `.`. Then gather decisions:

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory, however plausible the slug looks. Verify each before injecting it, one command per path:

```bash
test -f [DECISION_FILE_PATH]
```

A failed check omits the path and carries `decision index lookup failed for [DECISION_ID]` instead.

## 2. Detect Domains

Map each comment to a domain from its source type and file path. Domain-to-agent routing is project-configurable: the source types above name their own reviewer domain, a path maps through the project's component conventions, `docs/**` goes to the documentation reviewer, and a comment with no file path goes to the architecture reviewer.

## 3. Analyze

Delegate to the mapped domain agents in parallel.

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

1. Read `.agents/skills/orch/references/finding-disposition.md` and apply its verification prerequisite and decision flow to every finding — read the actual source files before classifying any comment.
2. Classify into arrays per `../../reviewer/schemas/review-finding.md`:
   - `blockers[]`: verified and blocking, or P1/P2
   - `suggestions[]`: verified, non-blocking
   - `questions[]`: QUESTION type — include a draft response
   - Noise or failed checks: omit entirely
   - Already fixed: do NOT omit silently. Return it in `questions[]` with `outcome: "already_fixed"`, `commit: "[SHA]"`, and a `draft_response`.
3. Preserve `source_id` and `source_type` from the input on every item.
4. Write the JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` with your harness file-write tool — never shell redirection, a heredoc, `tee`, or `echo >`.
5. Return exactly:

   <output_format>
   Report: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
   Verdict: [pass|action_required]
   </output_format>
</delegation_format>

Collect each agent's report path for § 5.

## 4. Synthesize

**Skip if** the comments came from a single domain.

Delegate to the architecture reviewer with the domain report paths, asking for cross-cutting findings only: issues spanning domains, dependencies between suggestions (`dependency: #A blocks #B (reason)`), gaps at domain boundaries, and conflicts between domain recommendations (flag both, resolve neither). It must not modify or overrule domain findings — only add its own, in the same JSON schema at `[WORKTREE_PATH]/tmp/review-arch-synthesis-YYYYMMDD-HHMMSS.json`, returning the same `Report:`/`Verdict:` pair. Add the returned path to the set.

## 5. Triage Report

Read every report, aggregate across agents preserving attribution, and deduplicate by (location, description), keeping the first and noting all sources. `blockers[]` and `category: "fix"` suggestions are fix items; `category: "issue"` suggestions defer to § 6.2; `questions[]` are auto-answered in § 7.

Auto-fix every valid item — do not prompt for a selection. Skip an item only when it contradicts an active decision (cite the decision id), is too vague to act on, is out of the PR's scope (→ issue), or cannot affect real usage (decline with one line, per [SKILL.md § The Cycle](../SKILL.md#the-cycle)).

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

### 🔧 FIXING

| # | Agent | Author | Location | Description | Pri |
|---|-------|--------|----------|-------------|-----|
| 1 | [AGENT] | [BOT_1] | [file:line] | [description] | 🔴 |

### ⏭️ SKIPPING

| # | Agent | Author | Location | Description | Reason |
|---|-------|--------|----------|-------------|--------|
| 1 | [agent] | [bot] | [file:line] | [description] | Contradicts [DECISION_ID] |

### 💬 QUESTIONS (auto-responding)

| # | Agent | Location | Question | Draft Response |
|---|-------|----------|----------|----------------|
| 1 | [agent] | [file:line] | [question] | [response] |

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4

</output_format>

Omit empty sections and proceed straight to § 6 — no user prompt.

## 6. Apply Fixes And Loop

### 6.1 Delegate Fixes

**Skip if** nothing is marked Fixing → § 6.2.

Ensure the worktree exists (`worktree exists`/`worktree path`, creating with `--pr [PR_NUMBER]` when missing), group the items by `agent`, then stamp the round per group as separate tool calls immediately before delegating, arming the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

Persist this group's item set: write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file-write tool — a JSON array of `{"n": [N], "text": "[ITEM_TEXT]"}`, `[ITEM_TEXT]` being that item's formatted block from the delegation verbatim — then:

```bash
.agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json
```

The file route keeps backticks and quotes in review text off the command line. Each group's fresh round id scopes its own record, so a prior group's set can never be checked against this group's receipt.

⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` is the technical fix; the agent owns its own process.

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

**Accept the round** on **A** (the round-scoped artifact) and **B** (git completion), never the return message:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
```
```bash
.agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
```
```bash
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" log -1 --oneline
```

Apply the fix-round A×B table in [`dev-fix.md` § 2](dev-fix.md), which is canonical — including exact-commit binding on accept, the bounded git re-read on `ok==true` with B failing, and the report-only tail-reconciliation nudge on `ok==false` with B passing, which never re-runs the fix. On accept: applied items are marked for reply, items the agent skipped go to the skipped list with their reason, and blocked items become issue candidates in § 6.2.

Push, then reply to and resolve every inline thread handled in this pass — do not defer them to § 7:

```bash
git -C "[WORKTREE_PATH]" push origin HEAD
```

| Outcome | Reply body |
|---------|------------|
| Applied | `Applied in [COMMIT_SHA]: [SHORT_FIX_SUMMARY]` |
| Skipped | `Acknowledged — [RATIONALE]` |
| Blocked → issue | `Tracking in [CREATED_ISSUE_ID]` |
| Already fixed | The finding's `draft_response` |

```bash
.agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" "[REPLY_BODY]" --pr "[PR_NUMBER]"
.agents/skills/github/scripts/github.sh resolve-thread "[THREAD_ID]"
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.replied '{"source_id":"[THREAD_ID]","commit":"[COMMIT_SHA]","outcome":"[applied|skipped|blocked|already_fixed]"}'
```

Inline `--body` is safe only for plain strings; a rationale or draft response containing backticks or fences goes to a file and `--body-file` instead. PR-level comments and human-only threads stay deferred to § 7.

### 6.2 Create Issues

**Skip if** nothing clears the filing bar in [references/finding-disposition.md](../references/finding-disposition.md). Blocked items and `category: "issue"` suggestions that do clear it go into an audit-input file at `[WORKTREE_PATH]/tmp/audit-pr-comments-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md`, with `tracker.type` set to the resolved `TRACKER` (plus `tracker.repository` for GitHub items), then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.3`.

### 6.3 Re-Triage Or Exit

After pushing, do **not** wait for bots to re-review — late findings are caught by the merge gates. Check once for comments that arrived while fixes were being applied, then loop or exit.

```bash
.agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
```
```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{iterations: .pr_comment_review.iterations, known: (.pr_review_baseline.last_threads // [])}'
```

`iterations >= 5` → § 7.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

A thread is new when its `threads[].id` is not in `known`. No new threads → § 7. Otherwise update the baseline and loop to § 1:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline '{"last_threads":[UNRESOLVED_THREAD_IDS]}'
```

---

## 7. Replies And Final Summary

### 7.1 Post Remaining Replies

**Backstop only** — inline threads handled per-pass in § 6.1 are already replied to and resolved. This covers PR-level comments, human-only threads, and anything per-pass handling missed. Skip any `source_id` already in `pr_comment_review.replied`.

| Outcome | Response |
|---------|----------|
| Applied | `Applied in [SHA]` |
| Skipped (decision) | `Acknowledged — contradicts [DECISION_ID]` |
| Skipped (not actionable) | `Acknowledged — not actionable` |
| Blocked or issue created | `Tracking in [ISSUE_ID]` |
| Question | The finding's `draft_response` |

Use inline `--body` only for plain strings; Markdown with backticks or fences goes to a file and `--body-file` (`post-reply` for threads, `post-comment` for PR-level). Number lists `1.` `2.` `3.`, never `#N` — GitHub auto-links `#N` to issues.

**Contested bot reviews.** When a domain agent classifies a bot's blocking comment as noise: tag the bot with the rationale and a re-review request, dismiss its `CHANGES_REQUESTED` with `github.sh dismiss-review [PR_NUMBER] --bot --message "[RATIONALE]"`, and resolve the thread. Tag a human reviewer the same way, but never dismiss their review.

Auto-resolve every thread where a reply was posted; keep open only threads awaiting a human response.

### 7.2 Present And Await

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

(Empty if all items were addressed.)

Awaiting your response — ask questions, override skipped items, or confirm done.

</output_format>

**Stop and wait for the user.** A request to fix a skipped item delegates that single item via § 6.1, pushes, and returns here. Confirmation goes to § 8.

**Standalone only**: post the cumulative summary as a PR comment when there were fixes or created issues, written to a file first so the Markdown is shell-safe, and on the Linear issue too when `TRACKER` is `linear`.

```markdown
## Recommendations Processed

### Fixed in PR
- [SOURCE]: [ITEM] — [SHA]

### Issues Created
- [ISSUE_ID] - [TITLE] — [PROJECT]

### Not Addressed
- [SOURCE]: [ITEM] — [REASON]
```

## 8. Update State And Return

One tool call per block — each append runs per item:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
```
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"
```
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'
```

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
