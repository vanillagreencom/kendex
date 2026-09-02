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

Triage what exists on the PR **right now** — never block on a bot reaching a terminal state. Bot prose is never a gate: emoji reactions, sticky comments, and checklist text carry no gating weight.

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

**Bot review summaries.** Derive bot logins from the authors present in the data (anything ending in `[bot]`) and fetch each one's summary comment, one command per bot with the literal login:

```bash
.agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --author "[BOT_LOGIN]" --review-summary
```

`--review-summary` picks, in order: the "View job" sticky, the review-section comment, then that bot's earliest comment. No bot having posted yet → continue with the human and inline comments that exist.

**Extract** per item: `thread_id`/`comment_id`, `author`, `body`, `path`, `line`, `url`, and `source` (`inline` or `pr-level`). Bot review summaries additionally get a `section` and a keyword-derived source type — architectural, documentation, security, testing, performance, or plain suggestion — plus `blocking: true` for security items and `false` when the text says non-blocking or optional. Skip anything the bot labels an inline comment: those are already captured as review threads, with the bot username as `author`. Never filter bot inline threads out.

**Issue context.** `issue_id` from the caller, else `git-context issue-from-branch .`; ask the user if nothing matches. Resolve `WT_PATH` as `git-context repo-root "[DIR]"`, `[DIR]` being `worktree exists`/`worktree path` when they match and `.` otherwise.

Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.

Then gather decisions:

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory. Verify each before injecting it, one command per path:

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
Worktree Check: `pwd -P` before any repo-relative command; it must print [WORKTREE_PATH]. On any other path, stop and report where the shell started.

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

**Recurrence before the cap.** A finding sharing a root cause with one a prior pass patched is dispositioned by [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence), which allows `structural-close` or `freeze` and no further patch round. Check it here, ahead of § 6.1's round cap. A finding sharing a cause in `patched_causes` is the recurrence this rule ends, and one sharing a cause in `frozen_causes` is `declined` without re-triaging.

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{patched: (.pr_comment_review.patched_causes // []), frozen: (.pr_comment_review.frozen_causes // [])}'
```

Auto-fix every valid item — do not prompt for a selection. Skip an item only when it contradicts an active decision (cite the decision id), is too vague to act on, is out of the PR's scope (→ issue), carries a root cause § Recurrence dispositions (→ `RECURRENCE`, never an auto-fix), or cannot affect real usage (decline with one line, per [SKILL.md § The Cycle](../SKILL.md#the-cycle)).

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

### ♻️ RECURRENCE

| # | Agent | Author | Location | Root cause | Disposition |
|---|-------|--------|----------|------------|-------------|
| 1 | [AGENT] | [BOT_1] | [file:line] | [one line] | `structural-close` |

### 💬 QUESTIONS (auto-responding)

| # | Agent | Location | Question | Draft Response |
|---|-------|----------|----------|----------------|
| 1 | [agent] | [file:line] | [question] | [response] |

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4

</output_format>

Omit empty sections and proceed straight to § 6 — no user prompt.

## 6. Apply Fixes And Loop

The `fix set` is every § 5 row marked Fixing plus every `structural-close` row: a structural close IS a fix round, one whose item names the generating surface rather than the site, and cutting surface the Done-when does not require is a close. `freeze` and `declined` rows are `reply-only` — they never join the delegation, the commit, or the push.

**Every pass owes both of these before it answers a thread** — fix-only, reply-only, mixed, `freeze`, `declined` alike. The subsections below run in the order they appear and the single `reply step` is the last of them, so a pass reading straight through owes nothing it has not already done:

1. Every class issue a reply names exists. § 6.2 files each `freeze` row's class issue; a `declined` row names the issue its frozen cause carries.
2. Every cause a reply closes is recorded — a `freeze` row's in `frozen_causes`, an applied item's in `patched_causes`. A cause the store does not carry is one the next pass re-triages in place of declining it. Write the file its shape below names, then bind the path.

```json
{"cause": "[ONE_LINE]", "issue": "[CLASS_ISSUE_ID]"}
{"cause": "[ONE_LINE]", "commit": "[COMMIT_SHA]"}
```
```bash
.agents/skills/orch/scripts/workflow-state append-file [ISSUE_ID] pr_comment_review.frozen_causes [WORKTREE_PATH]/tmp/frozen-cause-[ISSUE_ID].json
```
```bash
.agents/skills/orch/scripts/workflow-state append-file [ISSUE_ID] pr_comment_review.patched_causes [WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json
```

### 6.1 Delegate Fixes

**Skip the delegation and the push if** the `fix set` is empty; the pass still owes every thread its answer at the `reply step` below.

Read the round budget first. The cap governs what may be pushed, so it decides before the fix round, never after one:

```bash
.agents/skills/orch/scripts/workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS --issue [ISSUE_ID]
```

It prints `below [COUNT]/[CAP]` or `at-cap [COUNT]/[CAP]`, counting `pr_comment_review.iterations`. An `at-cap` verdict on `REVIEW_MAX_EXTERNAL_ROUNDS` ends the ordinary fix rounds on this PR. Two rules decide the pass. **At the cap the disposition is unconditional and the fix is what stops**: every thread is analyzed and gets its reply posted and resolved, on this pass and every later one, and what the cap forbids is the fix and the push that follows it. The **fix set** is what the rest of this section groups, records and delegates: the items marked Fixing, and **at the cap only the cap-exempt ones — a defect this diff itself introduces or arms and Step 0 does not exclude**. The pass then runs three steps, in order. **File first** — run § 6.2 for every item clearing its bar, invoked with its return recorded as `→ § 6.1` rather than § 6.2's usual `→ § 6.3`. **Then the exception**, the only delegation and the only push this pass makes. **Then reply**, through the reply table below: `Tracked: [ISSUE_ID]` for a filed item, `Fixed in [SHA]` for one the exception fixed, `Declined: [REASON]` for the rest, which needs no issue. Resolve each thread as you reply, then → § 6.3 with § 6.2 already done.

**Delegate the fix set.** Ensure the worktree exists (`worktree exists`/`worktree path`, creating with `--pr [PR_NUMBER]` when missing), group the `fix set` by `agent`, then stamp the round per group as separate tool calls immediately before delegating, arming the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

```bash
.agents/skills/orch/scripts/worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]
```
```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

`worktree-claim` exit 75 aborts the delegation — another session holds this worktree, and its stderr names the holder; exit 1 is an unverifiable guard, which stops the workflow and is reported. Its printed token is the delegation's `Worktree Lease:` line.

Persist this group's slice of the `fix set`: write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file-write tool as a JSON array of `{"n": [N], "text": "[ITEM_TEXT]"}`. `[ITEM_TEXT]` is that item's formatted block from the delegation verbatim.

Decide whether this fix round may add protected files. [`../schemas/dev-round.md` § Protected additions](../schemas/dev-round.md#protected-additions) is the sole scope definition. The default is none.

When the list is non-empty, write `[WORKTREE_PATH]/tmp/dev-round-adds-[DEV_ROUND_ID].json` with the harness file-write tool as a JSON array of exact repository-relative paths. Render the same array after `Adds:` in the delegation, preserving JSON string boundaries, including `Adds: ["tools/one path.sh"]` and `Adds: ["tools/one path.sh","skills/x/scripts/check;safe"]`. Pass only the data-file path to the writer:

```bash
.agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json [--adds-file [WORKTREE_PATH]/tmp/dev-round-adds-[DEV_ROUND_ID].json]
```

Exit 3 is the branch-size refusal. Stop before delegation, discard this fix set, and report the current and baseline counts with `Cut required`. After the branch is cut back to the Done-when, mint a fresh round. Every other nonzero exit is an environment or authorization failure and also stops the workflow.

⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` is the technical fix; the agent owns its own process.

Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-fix.md

Source: pr-comments
Issue: [ISSUE_ID]
PR: #[PR_NUMBER]
Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command; it must print [WORKTREE_PATH]. On any other path, stop and report where the shell started.
Worktree Lease: [WORKTREE_LEASE]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
[If the round may add files: "Adds: [REPO_RELATIVE_PATHS_JSON_ARRAY]"]

Review items:
[For each item in the fix set:]
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

Apply the fix-round A×B table in [`dev-fix.md` § 2](dev-fix.md), which is canonical — including exact-commit binding on accept, the bounded git re-read on `accept` with B failing, the report-only tail-reconciliation nudge on `wait` with B passing, and the never-accept `retry` row, which never re-runs the fix. On accept: applied items are marked for reply, items the agent skipped go to the skipped list with their reason, and blocked items become issue candidates in § 6.2.

**Batch per fully-reviewed head.** Push a fix round only after every configured reviewer has reported on the current head. A pass with nothing to push skips this command:

```bash
git -C "[WORKTREE_PATH]" push origin HEAD
```

**A round ends with the description matching its head.** The PR body describes the commits actually on the PR head and names every issue § 6.2 filed this round; nothing else regenerates it after round one, so rebuild it per [`submit-pr.md` § 2](submit-pr.md) step 3 and post it with `pr-edit-body` until both hold.

### 6.2 Create Issues

**Skip if** nothing clears the filing bar in [references/finding-disposition.md](../references/finding-disposition.md). Blocked items, skipped items, `category: "issue"` suggestions, and each `freeze` row's class issue that clear it go into an audit-input file at `[WORKTREE_PATH]/tmp/audit-pr-comments-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md`, with `source: "pr-comments"` and `tracker.type` set to the resolved `TRACKER` (plus `tracker.repository` for GitHub items), then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.3`.

### 6.3 Re-Triage Or Exit

**Reply step.** Reply to and resolve every inline thread this pass handled, never deferring one to § 7.

| Outcome | Reply body |
|---------|------------|
| Applied | `Fixed in [COMMIT_SHA]: [SHORT_FIX_SUMMARY]` |
| Skipped, blocked, or declined, nothing filed | `Declined: [REASON]` |
| Blocked or skipped → issue | `Tracked: [CREATED_ISSUE_ID]` |
| Already fixed | The finding's `draft_response` |
| Question | The finding's `draft_response` |

The word "tracked" (any form) without a `KEN-` or `#` issue id turns the gate red (`untracked-claim`) unless the reply opens with `Fixed in <sha>` or `Declined:`; only a later reply of one of the three forms clears it, and resolving the thread does not. A decline is a decline — say so.

`[REASON]` takes one of the forms [../references/finding-disposition.md](../references/finding-disposition.md) § Decision flow sets out. A label instead of a reason — `frozen`, `at the cap`, `out of scope`, `pre-existing`, `flagged separately`, a test count — is never one. An empty reason, or one that is nothing but labels the gate knows, turns it red (`unreasoned-decline`), and dropping the colon exempts nothing: `Declined, out of scope` is read as the decline it is. A label beside a real reason is fine.

```bash
.agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" "[REPLY_BODY]" --pr "[PR_NUMBER]"
.agents/skills/github/scripts/github.sh resolve-thread "[THREAD_ID]"
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.replied '{"source_id":"[THREAD_ID]","commit":"[COMMIT_SHA]","outcome":"[applied|skipped|blocked|already_fixed]"}'
```

Inline `--body` only for plain strings; a reply containing backticks or fences goes to a file and `--body-file` instead. PR-level comments and human-only threads stay deferred to § 7.

This section counts the round and decides whether to loop; the cap is § 6.1's and is not re-applied here. Do **not** wait for bots to re-review — check once for comments that arrived while fixes were being applied, then loop or exit.

```bash
.agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
```

This is the only writer of `pr_comment_review.iterations` in any workflow: one triage pass advances the counter by exactly one, and a caller that runs this workflow writes neither it nor § 8's result arrays.

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{known: (.pr_review_baseline.last_threads // [])}'
```
```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

A thread is new when its `threads[].id` is not in `known`. No new threads → § 7. Otherwise update the baseline and loop to § 1, at the cap as below it: the next pass analyzes the new threads and posts their dispositions, and § 6.1 is where the fix and the push stop:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline '{"last_threads":[UNRESOLVED_THREAD_IDS]}'
```

---

## 7. Replies And Final Summary

### 7.1 Post Remaining Replies

**Backstop only** — inline threads handled per-pass in § 6.3 are already replied to and resolved. This covers PR-level comments, human-only threads, and anything per-pass handling missed. Skip any `source_id` already in `pr_comment_review.replied`.

Reply bodies are § 6.3's table, which is where the `questions[]` § 5 routes here are answered — the Question row, the finding's own `draft_response`. A question is never a `Declined:`, which the gate reads as a decline naming no mechanism. Two clauses this step adds: a skip that contradicts a recorded decision spells its `[REASON]` as `contradicts [DECISION_ID]`, and an issue named by `Tracked:` exists before the reply is posted.

Use inline `--body` only for plain strings; Markdown with backticks or fences goes to a file and `--body-file` (`post-reply` for threads, `post-comment` for PR-level). Number lists `1.` `2.` `3.`, never `#N`.

**Contested bot reviews.** When a domain agent classifies a bot's blocking comment as noise: tag the bot with the reason and a re-review request, dismiss its `CHANGES_REQUESTED` with `github.sh dismiss-review [PR_NUMBER] --bot --message "[REASON]"`, and resolve the thread. Tag a human reviewer the same way, but never dismiss their review.

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

**Standalone only**: post the cumulative summary as a PR comment when there were fixes or created issues, written to a file first, and on the Linear issue too when `TRACKER` is `linear`.

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

One tool call per block — each append runs per item. A fix and a skip entry carry the finding's own text, so each is written to a file with the harness file-write tool and bound by path:

```json
{"description": "[DESC]", "location": "[LOC]", "commit": "[SHA]", "source": "[SOURCE]"}
```
```bash
.agents/skills/orch/scripts/workflow-state append-file [ISSUE_ID] pr_comment_review.fixes [WORKTREE_PATH]/tmp/state-fix-[ISSUE_ID].json
```
```json
{"description": "[DESC]", "reason": "[REASON]"}
```
```bash
.agents/skills/orch/scripts/workflow-state append-file [ISSUE_ID] pr_comment_review.skipped [WORKTREE_PATH]/tmp/state-skipped-[ISSUE_ID].json
```

An issue id is not finding text and stays inline:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"
```

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
