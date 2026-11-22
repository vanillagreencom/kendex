# PR Comment Triage Workflow

Route a pull request's review comments to domain agents, fix the valid ones, and reply to and resolve every thread.

| Command | Behavior |
|---------|----------|
| `review-pr-comments` | Full triage: analyze, fix, file issues, reply |
| `review-pr-comments [PR-number]` \| `[BRANCH_NAME]` | A specific pull request |
| `review-pr-comments --dry-run [N]` | §§ 1-5 only: the triage report, no side effects |
| (from submit-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`):

- `worktree`.
- `lifecycle`: `"managed"` (return at § 8) or `"self"` (default).
- `issue_id`: the workflow-state key, the normalized issue ID, never the bare GitHub issue number.
- `pr_number`.

**Decision mode.** Resolve it once for this workflow:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

**Standalone init** (`lifecycle: "self"`):

1. `gh pr view --json number -q .number` gives `PR_NUMBER`.
2. `git-context issue-from-branch .` gives `ISSUE_ID` when the branch carries an issue id.
   - Otherwise `ISSUE_ID` is `pr-[PR_NUMBER]`, the repository-local key [ci-fix.md](ci-fix.md) § 1 and [merge-pr.md](merge-pr.md) § 3 use.
   - A branch with no issue id is ordinary, not a stop.
3. Except under `--dry-run`, when `orch-runtime state exists --item [ISSUE_ID]` reports false:
   1. Resolve `WT_PATH`.
   2. Read the branch with `git-context branch`.
   3. Run `orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]`.

**Dry run.** Under `--dry-run`, run `orch-runtime state exists --item [ISSUE_ID]` once the key resolves, and carry the answer into §§ 3-5. Write no state:

| State exists | Recurrence handling |
|---|---|
| `true` | Read the existing recurrence records as § 5 requires |
| `false` | Report `unavailable: workflow state absent` and skip the recurrence lookup. History stays unknown, never empty or zero |

**Continuing action.** Except under `--dry-run`, this triage pass is a continuing action and clears a standing stop. First the key must resolve and the state must exist:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [ISSUE_ID]
```

**GitHub read failures.** On a `gh` or `github.sh` failure:

1. Report the error.
2. Under `auto-recommended`, retry once and log `Retry`. A second failure records the named stop `github-read-failed` per [SKILL.md § The Cycle](../SKILL.md#the-cycle).
3. Under `ask`, present `Retry` | `Skip step` | `Abort`, with `Retry` recommended.

## 1. Fetch And Parse

Triage what stands on the pull request once Copilot's work on the current head has settled.

**Current-head Copilot wait.**

- Run it through [Waiter launch](../references/waiter-launch.md) before the `pr-data` read.
- Skip it while the pull request is a draft, which `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json isDraft --jq .isDraft` reads.
- `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers in `[WORKTREE_PATH]`.
- The wait requests and records nothing under either gate mode, so it runs under `--dry-run` too:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/orch-runtime copilot-wait --repo [OWNER/REPO] --pr [PR_NUMBER]
```

Its bound is `ORCH_COPILOT_HOLD_SECS`, counted from the wait's own start.

Route its reply's `result` by this table here, at § 6.3 and at § 7.2. An expiry is a `state` in a reply that exits 0, so route the `state`, never the exit.

| Reply | Route |
|---|---|
| `status` `complete`, `state` `none` | No Copilot work on the head: continue the calling read |
| `state` `settled` | Continue the calling read |
| `state` `expired` | Report `run`, `started_at` and `waited`, then continue the calling read under the existing gate |
| `status` `unreadable` | Report its `reason` and `detail`, and stop the calling read |
| A refusal: a nonzero exit with a keyed `orch-runtime:` line | Report it and stop the calling read |

- After `settled`, the calling read reads the review `review` names, where it names one, with the threads and bodies.
- The expiry grants no approval.
- A read stopped on `unreadable` takes the failure rule above. A failed read is never `none`.

No other bot holds this read.

- A Copilot thread posted after it holds the merge as [gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing) states for each gate mode.
- Bot prose is never a gate: emoji reactions, sticky comments and checklist text carry no gating weight.

**Read the pull request:**

```bash
.agents/skills/github/scripts/github.sh pr-data "[PR_NUMBER]"
```

Read it without `--actionable`, which drops the outdated threads the Filter below keeps.

**Baseline for re-runs.**

1. Find the prior summary comment this run's GitHub identity posted, whether a person or a GitHub App installation, by the `## Recommendations Processed` heading [post-summary.md § 1](post-summary.md#1-post-the-summary) keeps in every summary § 7 and submit-pr post:

   ```bash
   .agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --pattern "Recommendations.*Processed" --self
   ```

2. Use its `updated_at` as `SUMMARY_TS`. `{}` means no prior summary and no `SUMMARY_TS`.

**Filter.**

- From PR-level `comments`, leave out noise bots, anything created before `SUMMARY_TS` on a re-run, and status updates with no actionable content.
  - The noise bots are `dependabot`, `github-actions`, `renovate`, `codecov` and tracker sync bots.
  - A match ignores a trailing `[bot]`, which pr-data's logins lack.
- From `threads`, leave out resolved threads only.
  - Every unresolved inline thread, whatever its author, outdated ones included, gets a § 6.3 reply and resolve.
  - A noise-bot thread gets `Declined: [REASON]`.
  - Keep every reviewer comment on such a thread, human or bot.

**Bot review summaries.** Take the bot logins from the authors in the data (anything ending in `[bot]`). Fetch each one's summary comment, one command per bot with the literal login:

```bash
.agents/skills/github/scripts/github.sh find-comment [PR_NUMBER] --author "[BOT_LOGIN]" --review-summary
```

With no bot posted yet, continue with the human and inline comments that exist.

**Extract** per item: `thread_id` or `comment_id`, `author`, `body`, `path`, `line`, `url`, and `source` (`inline` or `pr-level`).

- A bot review summary also gets a `section`, and a source type from its keywords: architectural, documentation, security, testing, performance or plain suggestion.
- Security items get `blocking: true`; items the text calls non-blocking or optional get `false`.
- Skip what the bot labels an inline comment, since the review threads already carry it with the bot as `author`.

**Issue context.**

- Resolve `WT_PATH` as `git-context repo-root "[DIR]"`. `[DIR]` is `worktree exists` / `worktree path` when they match, and `.` otherwise.
- Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

**Decisions.** Run [review-pr.md § 1.1 Decision Context](review-pr.md#11-decision-context) with `[ISSUE_ID]`. § 3's delegation carries each verified decision and each failed lookup in its own line form.

## 2. Detect Domains

Map each comment to a domain from its source type and file path. The project configures the domain-to-agent routing:

- A source type names its own reviewer domain.
- A path maps through the project's component conventions.
- `docs/**` goes to the documentation reviewer.
- A comment with no file path goes to the architecture reviewer.

## 3. Analyze

This pass is a [Record verified findings](../schemas/workflow-state.md#record-verified-findings) batch. § 5 supplies acceptance, disposition and completion.

1. Admit it with § 1's inline, PR-level and review-body identities and this run's `--dry-run` status.
2. Bind its round token as `[TRIAGE_REVIEW_ROUND_ID]` for the domain and synthesis reports.
3. On every pass, apply [Delegation](../references/skill-rules.md#delegation) before you select domain, architecture or fix agents.
4. Delegate to the mapped domain agents in parallel.

<delegation_format>
Analyze these PR review comments for your domain.

PR: #[PR_NUMBER] - [TITLE]
Parent Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]
Review round: [TRIAGE_REVIEW_ROUND_ID, or unavailable under --dry-run]
Recurrence history: [available, or unavailable: workflow state absent under --dry-run]

Decision context (read before classifying — do NOT suggest changes that contradict these):
[For each verified decision: "[DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "decision index lookup failed for [DECISION_ID]"]
[If none: "No linked decisions found."]

Comments for your review:
[For each comment:]
---
Source ID: [THREAD_ID, COMMENT_ID or file:line]
Source Type: [inline, pr-level or review-body]
Author: @[AUTHOR]
File: [PATH]:[LINE] (or "general" if no file)
Comment: "[BODY]"
Blocking: [true/false]
URL: [URL]
---

1. Read `.agents/skills/reviewer/references/finding-disposition.md` and apply its verification prerequisite and decision flow to every finding — read the actual source files before classifying any comment. When the supplied dry-run recurrence history is unavailable, skip that reference's state-dependent recurrence lookup and retain history as unknown in the report. Otherwise read both recurrence records as it requires.
2. Classify into arrays per `../../reviewer/schemas/review-finding.md`:
   - `blockers[]`: verified and blocking, or P1/P2
   - `suggestions[]`: verified, non-blocking
   - `questions[]`: QUESTION type — include a draft response. For review-body inputs, use `Declined: [VERIFIED_DECISION_FLOW_REASON]`, answering the non-defect claim.
   - Noise or failed checks from other sources: omit.
   - Every review-body input must remain in one array, including false claims, Step 0 exclusions, vague or informational items, and other verified declines. Keep these in `questions[]`: copy the original claim into `question` and put `Declined: [VERIFIED_DECISION_FLOW_REASON]` in `draft_response`. Use the existing Question Fields; this is a reply carrier, not a fix item or a question to the user.
   - Already fixed: do NOT omit silently. Return it in `questions[]` with `outcome: "already_fixed"`, `commit: "[SHA]"`, and a `draft_response`.
3. Preserve `source_id` and `source_type` from the input on every item. Copy the supplied review-round token into `qa_metadata.review_round_id`, or use `null` under `--dry-run`. This report boundary owns disposition retention: no filter or omission rule removes a review-body input or its verified reply reason.
4. Write the JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` with your harness file-write tool — never shell redirection, a heredoc, `tee`, or `echo >`.
5. Return exactly:

   <output_format>
   Report: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
   Verdict: [pass|action_required]
   </output_format>
</delegation_format>

Collect each agent's report path with its bound round token for § 5.

## 4. Synthesize

**Skip if** the comments came from a single domain.

Delegate to the architecture reviewer with the domain report paths, `[TRIAGE_REVIEW_ROUND_ID]`, and § 3's recurrence-history line and lookup instruction. Ask for cross-cutting findings only:

- issues that span domains;
- dependencies between suggestions (`dependency: #A blocks #B (reason)`);
- gaps at domain boundaries;
- conflicts between domain recommendations: flag both, resolve neither.

The reviewer:

- must not modify or overrule a domain finding;
- writes its own findings in the same schema at `[WORKTREE_PATH]/tmp/review-arch-synthesis-YYYYMMDD-HHMMSS.json`;
- copies the token into `qa_metadata.review_round_id` (`null` under `--dry-run`);
- returns the same `Report:` / `Verdict:` pair.

Add the returned path and its token to the set.

## 5. Triage Report

1. Accept each domain and synthesis report under [Record verified findings](../schemas/workflow-state.md#record-verified-findings) with its assigned `[TRIAGE_REVIEW_ROUND_ID]`.
   - Complete that contract after the disposition below and before § 6, with this batch's identities and dry-run status.
2. Read every report and aggregate across agents, keeping attribution.
   - Keep every review-body item, with its source identity and verified reply draft, through § 6.3. Never deduplicate one away.
   - Deduplicate other items by location and description, keeping the first and noting every source.
3. Route each kind:
   - `blockers[]` and `category: "fix"` suggestions are fix items.
   - `category: "issue"` suggestions go to § 6.2.
   - § 7 answers `questions[]`, except review-body items, which § 6.3 answers.
   - Show verified body declines under SKIPPING with their draft reason. These reply-only items never enter the fix set.
4. **Recurrence before the cap.** [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) dispositions a finding that shares a root cause with one a prior pass patched. Check it here, before § 6.1's cap.
   - When the dry-run history is unavailable, report that status in the triage output and leave recurrence unverified.
   - Otherwise read both records, with the command that section states, before you disposition any item.
5. Auto-fix every valid item, and never prompt for a selection. Skip an item only when it:
   - contradicts an active decision (cite the decision id);
   - is too vague to act on;
   - is out of the pull request's scope (an issue);
   - carries a root cause § Recurrence dispositions (`RECURRENCE`, never an auto-fix);
   - cannot affect real usage (a one-line decline, per [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar)).

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

Omit empty sections and go straight to § 6, with no user prompt.

## 6. Apply Fixes And Loop

The **fix set** is every § 5 row marked Fixing plus every `structural-close` row.

- A structural close is a fix round whose item names the generating surface in place of the site.
- `freeze` and `declined` rows are reply-only: they never join the delegation, the commit or the push.

Before it answers a thread, every pass owes two things, whether it fixes, replies or both. The subsections run in order and the `reply step` comes last, so a pass that reads straight through has done both:

1. Every class issue a reply names exists.
   - § 6.2 files each `freeze` row's class issue.
   - A `declined` row names the issue its frozen cause carries.
2. Every cause a reply closes is recorded: a `freeze` row's in `frozen_causes`, an applied item's in `patched_causes`. The next pass re-triages a cause the record lacks instead of declining it.

   Write the cause file in its shape with the harness file tool, then record it:

   ```json
   {"cause": "[ONE_LINE]", "issue": "[CLASS_ISSUE_ID]"}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"frozen-cause","file":"[WORKTREE_PATH]/tmp/frozen-cause-[ISSUE_ID].json"}'
   ```

   ```json
   {"cause": "[ONE_LINE]", "commit": "[COMMIT_SHA]", "location": "[LOCATION]", "owner": "[OWNER]"}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"patched-cause","file":"[WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json"}'
   ```

   - Copy `[LOCATION]` from the fixed item's header as written.
   - Copy `[OWNER]` from its `Owner:` line as written. Omit the `owner` key when the item has no such line.

### 6.1 Delegate Fixes

**Skip the delegation and the push if** the fix set is empty. The pass still answers every thread at the `reply step`.

**Round budget.** The cap decides before the fix round, never after:

```bash
.agents/skills/orch/scripts/orch-runtime state cap REVIEW_MAX_EXTERNAL_ROUNDS --item [ISSUE_ID]
```

- `below`: the fix set below is the items marked Fixing.
- `at-cap`: ordinary fix rounds end on this pull request.
  - The cap is a ruling point. No ordinary fix round starts past it until the overseer has ruled, judging with the reply's `count` and `limit`, and recorded one `ruling` row for the item in the fleet log ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)).
  - At the cap the disposition still runs in full; only the fix stops. Every thread is analyzed and gets its reply and resolve, on this pass and every later one.
  - The fix set holds only the cap-exempt items: a defect this diff itself introduces or arms that Step 0 does not exclude.
  - Run three steps in order:
    1. **File first.** Run § 6.2 for every item that clears its bar, with its return recorded as `→ § 6.1` in place of § 6.2's `→ § 6.3`.
    2. **Then the exception.** The cap-exempt fix set is this pass's only fix delegation and only push. A fix the verification pass below triggers belongs to it.
    3. **Then reply** by § 6.3's table: `Tracked: [ISSUE_ID]` for a filed item, `Fixed in [SHA]` for one the exception fixed, and `Declined: [REASON]` for the rest, which needs no issue. Resolve each thread as you reply, then go to § 6.3 with § 6.2 already done.

**Delegate the fix set.**

1. Ensure the worktree exists (`worktree exists` / `worktree path`), and create it with `--pr [PR_NUMBER]` when missing. Then record the head the verification pass diffs against, once per fix set:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"base","worktree":"[WORKTREE_PATH]"}'
   ```

2. Group the fix set by `agent`. Run the groups one after another, and take steps 3 to 12 for each group.
3. Read the pull request and bind `[PR_OPEN]` as [dev-fix.md § 2](dev-fix.md#2-delegate) step 4 does:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] [PR_NUMBER] --json state
   ```

4. Run [dev-fix.md § 2](dev-fix.md#2-delegate)'s base-freshness gate before stamping this round.
5. Apply [Finding occurrences § Query and admission](../schemas/workflow-state.md#query-and-admission) to this group's proposed fix classes. Write the requests to `[WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json` from the original review items, or from exact receipt-origin check names:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state findings query --item [ISSUE_ID] [WORKTREE_PATH]/tmp/finding-requests-[ISSUE_ID].json
   ```

   - A nonzero exit or `ok: false` is a failed query.
   - Otherwise save the reply's `result`, the `{prior, classes}` object, unchanged with the harness file tool as `[WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json`.
   - Take the [finding-specific design read](../references/design-review.md#inputs-and-actions), with that JSON in the ask or status, before the round's `begin-round`, prune or delegation time. This path owns the read even when dev-fix has not run.
   - Carry the same JSON in the group's delegation.

6. Stamp the round as separate tool calls immediately before delegating.
   - Apply the cleanup condition and arm the watchdog per [skill-rules.md § Round Closure](../references/skill-rules.md#round-closure).
   - First reconcile the standing dev round, as [dev-start.md § 2](dev-start.md#2-delegate) does, with `{"op": "reconcile-round", "round_id": "[PRIOR_DEV_ROUND_ID]"}` through the command below. Its admitted runs then close before the new round supersedes it.
7. Mint the round: write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "dev"}`, run it, and take `[DEV_ROUND_ID]` from the reply's `.result.report.round_id`.
   - With several groups, the request adds `"group": {"n": [N], "of": [GROUPS]}`.
   - It may also carry an `exception`: the known failures the round may end with. This side grants the exception, and the receipt only cites it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
   ```

8. Apply [Round Closure](../references/skill-rules.md#round-closure)'s cleanup condition to the round's prune. Write `[WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json` with the harness file tool as `{"op": "prune-round", "field": "dev"}`, run it, then stamp the delegation time:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"dev"}'
   ```

9. Write the round's admission request, `[WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json`, with the harness file tool as `{"op": "record-validation-admission", "round_id": "[DEV_ROUND_ID]"}`. The delegation's `Validation admission:` line names the command that runs it, as [dev-start.md § 2](dev-start.md#2-delegate) states.
10. Persist the group's items: write `[WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json` with the harness file tool as a JSON array of `{"n": [N], "text": "[ITEM_TEXT]", "reach": "[REACH]"}`.
    - Copy `[ITEM_TEXT]` from the delegation under [dev-round.md § Item text](../schemas/dev-round.md#item-text).
    - `[REACH]` names the shipped producer, user action or fixture that reaches the finding: a command a person runs, a file a shipped writer emits, or a test in the tree.
    - An item with no reach is a `Declined:` reply, not a fix; disposition it per [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar).
11. Decide whether this round may add protected files. [dev-round.md § Protected additions](../schemas/dev-round.md#protected-additions) is the one scope definition, and the default is none.
    - When the list is non-empty, pass the exact repository-relative paths to the writer as one blank-separated `--adds` value.
    - Render the same list after `Adds:` in the delegation: `Adds: tools/one-helper.sh`, or `Adds: tools/one-helper.sh skills/x/scripts/check`.
    - A blank or tab separates paths, so no path holding whitespace can be authorized. Check for one first.

    ```bash
    .agents/skills/orch/scripts/orch-runtime round --text stamp --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --items-file [WORKTREE_PATH]/tmp/dev-round-items-[DEV_ROUND_ID].json --source pr-comments --pr-open [PR_OPEN] --finding-occurrences-file [WORKTREE_PATH]/tmp/finding-context-[ISSUE_ID].json [--adds "[REPO_RELATIVE_PATHS]"]
    ```

    - A nonzero exit names a usage or environment failure: report it and stop.
    - A chosen cut follows [dev-fix.md § 2](dev-fix.md#2-delegate) step 4 with `[SOURCE]` `pr-comments`.

12. Read the near-ceiling lines the last recorded round left, and render one `Near-ceiling:` line per entry. An absent field renders none. The stamp already moved `dev_round_id`, so the state key is the one carrier:

    ```bash
    .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /near_ceiling
    ```

    - Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
    - Fill `Labels:` as [dev-fix.md § 2](dev-fix.md#2-delegate) fills it.
    - Fill placeholders only ([Format Tags Are Literal](../references/skill-rules.md#format-tags-are-literal)).
    - `Recommendation:` is the technical fix. The agent owns its own process.

<delegation_format>
Follow workflow: .agents/skills/dev/workflows/dev-fix.md

Source: pr-comments
Finding occurrences: [UNCHANGED_QUERY_JSON]
Issue: [ISSUE_ID]
PR: #[PR_NUMBER]
Worktree: [WORKTREE_PATH]
Round ID: [DEV_ROUND_ID]
Artifact Key: [ISSUE_ID]
Labels: [LABELS]
Validation admission: .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/validation-admission-[ISSUE_ID]-[DEV_ROUND_ID].json
[If the round may add files: "Adds: [REPO_RELATIVE_PATHS]"]
[For each near_ceiling line read from workflow state: "Near-ceiling: [LINE]"]

Review items:
[For each item in the fix set:]
#[N] | [AGENT] | [LOCATION]
Title: "[TITLE]"
Description: "[DESCRIPTION]"
Recommendation: "[RECOMMENDATION]"
[If the finding has an owner: "Owner: [OWNER]"]
</delegation_format>

**Accept the round** on **A**, the round-scoped artifact, and **B**, git completion, never on the return message:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /dev_round_id
```

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND] --expect-items-from-round
```

```bash
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" log -1 --oneline
```

1. Route the verdict by [dev-fix.md § 2](dev-fix.md#2-delegate) step 5, which owns the acceptance table. That covers:
   - its stalled-round route, with `reconcile-round` before `orch-runtime round --text recover` and the prune on a `redelegate` line;
   - exact-commit binding on accept;
   - the stage close through [dev-start.md § Close The Round's Stages](dev-start.md#close-the-rounds-stages);
   - the bounded git re-read on `accept` with B failing;
   - the report-only tail nudge on `wait` with B passing;
   - the `retry` row, which never re-runs the fix.
2. A group that is not the last ends `hand-over`.
   - Its Check B is a commit past the round's base and a clean worktree, with no tracker validation.
   - Its handoff notes go to the next group.
   - The last group's acceptance validates the combined work.
3. On accept:
   - mark the applied items for reply;
   - put the items the agent skipped on the skipped list with their reason;
   - make the blocked items issue candidates for § 6.2.

**Verify before the push.** Every accepted fix round gets one focused pass over its diff, `[PRE_SHA]...HEAD`, whatever `REVIEW_MAX_EXTERNAL_ROUNDS` reads. The pass follows [review-pr.md § Bounded Re-Review](review-pr.md#bounded-re-review)'s rule for a fix diff no reviewer has seen.

1. The panel is that section's scoped panel over this diff: the reviewers whose domains it touches, and the domain reviewers § 2 routed the applied items to.
   - This pass runs no external review.
   - Record the panel. One holding every `first_panel` reviewer carries `domain_reasons`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-panel","panel":"verification","agents":[PANEL_AGENTS_JSON],"reason":"pr-comments fix round: [DOMAINS]","external":false}'
   ```

2. Delegate and collect it as [review-pr.md](review-pr.md) § 2.2 and § 3 do, with `Diff-range: [PRE_SHA]...HEAD`.
   - Close its review stage with the `outcome` word [review-pr.md § 3.3](review-pr.md#33-present) computes from this pass's panel and accepted artifacts.
   - Then shut its reviewers down and clear their state with review-pr.md § 5's first write.
3. Its blockers and `category == "fix"` suggestions re-enter § 5's disposition as findings of this pass. What survives joins this pass's fix set as a defect this diff introduces.
   - Its `category == "issue"` suggestions go to § 6.2.
   - At the cap, where § 6.2 already ran, run it once more for them.
4. One verification pass runs per push. The fix it triggers joins the same push without a second pass, and the next external round reviews it.

**Push.** Push a fix round only once every configured reviewer has reported on the current head. A pass with nothing to push skips this step.

1. Read the pull request and record whether `autoMergeRequest` is armed:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] [PR_NUMBER] --json number,state,autoMergeRequest
   ```

2. With workflow state `pr_order` reading `open-first-returned` or `push-first-returned`, publish through the branch-publication owner.
   - Write `[WORKTREE_PATH]/tmp/triage-push-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "branch", "worktree": "[WORKTREE_PATH]"}`, run it, and route its exit and reply as [merge-pr-restack.md](merge-pr-restack.md) step 3 does.
   - [submit-pr.md](submit-pr.md) § 2 step 1 pushes next, so GitHub receives one combined head:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/triage-push-[ISSUE_ID].json
   ```

   That push may rebase this round's fix commits, whose SHAs come from the dev return.

   - Before § 6.3's `Fixed in` reply or § 8's `fix` entry uses one, resolve it through workflow state's `rebase_map`. Follow the chain until no key matches.
   - A chain ending in `dropped` puts no SHA in the reply and `dropped:[COMMIT_SHA]` in the entry.

3. With any other `pr_order`, push directly:

   ```bash
   git -C "[WORKTREE_PATH]" push origin HEAD
   ```

4. After § 6.3 finds no new thread and §§ 7-8 finish:
   - an armed standalone triage enters [merge-pr.md](merge-pr.md) at its entry point;
   - an armed managed triage returns the recorded `autoMergeRequest` with its § 8 result, so the caller's merge stage owns the lifecycle.

**The description matches the head.** At the end of a round, the pull request body describes the commits on the head and names every issue § 6.2 filed this round. Nothing else regenerates it after the first round.

1. Rebuild it per [submit-pr.md](submit-pr.md) § 2 step 3.
2. Post it with `pr-edit-body` until both hold.

### 6.2 Create Issues

**Skip if** nothing clears the filing bar in [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar).

1. Put what clears the bar in an audit-input file at `[WORKTREE_PATH]/tmp/audit-pr-comments-YYYYMMDD-HHMMSS.json`, per `.agents/skills/project-management/schemas/audit-issues-input.md`: the blocked items, skipped items, `category: "issue"` suggestions and each `freeze` row's class issue.
   - Set `source: "pr-comments"`, `tracker.type` to `TRACKER`, and `tracker.repository` for GitHub items.
2. Apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination), then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.3`.

### 6.3 Re-Triage Or Exit

**Reply step.** Reply to and resolve every inline thread this pass handled, and defer none to § 7. This holds for every outcome, mixed passes included.

| Outcome | Reply body |
|---------|------------|
| Applied | `Fixed in [COMMIT_SHA]: [SHORT_FIX_SUMMARY]` |
| Skipped, blocked, or declined, nothing filed | `Declined: [REASON]` |
| Blocked or skipped → issue | `Tracked: [CREATED_ISSUE_ID]` |
| Already fixed | Review-body: `Fixed in [COMMIT_SHA]: [SHORT_FIX_SUMMARY]`, using its verified fix SHA; otherwise the finding's `draft_response` |
| Question or verified decline | Review-body: its retained `draft_response`, in `Declined: [VERIFIED_DECISION_FLOW_REASON]` form; otherwise the finding's `draft_response` |

- Resolving a thread is not a reply.
- `[REASON]` takes one of the forms [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow) sets out.

**Inline threads.** Write `[REPLY_BODY]` with the harness file tool to `tmp/pr-reply-[THREAD_ID].md`, bind it as `[BODY_FILE]`, and run each of these per thread:

```bash
.agents/skills/github/scripts/github.sh post-reply "[THREAD_ID]" --body-file [BODY_FILE] --pr "[PR_NUMBER]"
```

```bash
.agents/skills/github/scripts/github.sh resolve-thread "[THREAD_ID]"
```

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"reply","source_id":"[THREAD_ID]","commit":"[COMMIT_SHA]","outcome":"[applied|skipped|blocked|already_fixed]"}'
```

**Review-body items** (`source_type: "review-body"`). These items take neither `post-reply` nor `resolve-thread`.

1. Collect the replies for every retained item into one PR comment.
   - Its first line is `Dispositions at [BODY_REVIEW_HEAD]`, the full source-reviewed SHA § 7.2 saved in this pass's context.
   - Keep that marker unchanged across any fix push, a rebase included. A reconciled fix SHA belongs in the reply text and never replaces it.
   - Open each line with the item's original `source_id` (`file:line` or `review:<ID>`), per `check-review-replies --help`.
2. Write the comment to a file with the harness file tool, and post it with `github.sh post-comment [PR_NUMBER] --body-file [BODY_FILE]`.
3. Record each item with the `reply` entry above, with the item's token as its `source_id`.

PR-level comments and human-only threads stay for § 7.

**Re-triage.** This section counts the pass and decides whether to loop. The cap is § 6.1's alone.

1. Run § 1's current-head Copilot wait, except while the pull request is a draft, and route its reply by § 1's table. This is the one wait on bots in this section.
2. Count the pass. This is the only writer of `pr_comment_review.iterations` in any workflow.
   - One triage pass adds exactly one.
   - A caller of this workflow writes neither it nor § 8's arrays:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"counted","counter":"external"}'
   ```

3. Check once, without waiting for bots to re-review, for comments that arrived while the fixes ran:

   ```bash
   STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {known: (.pr_review_baseline.last_threads // [])}' <<<"$STATE_READ"
   ```

   ```bash
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   ```

4. A thread is new when its `threads[].id` is not in `known`.
   - No new thread: § 7.
   - Otherwise update the baseline and loop to § 1, at the cap as below it. The next pass analyzes and answers the new threads, and § 6.1 is where the fix and the push stop:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"baseline","last_threads":[UNRESOLVED_THREAD_IDS]}'
   ```

A Copilot thread posted after this read routes as § 1 states.

---

## 7. Replies And Final Summary

### 7.1 Post Remaining Replies

**Backstop only.** § 6.3 already answered and resolved the inline threads each pass handled. This step covers PR-level comments, human-only threads and anything a pass missed. Skip any `source_id` already in `pr_comment_review.replied`.

1. Review-body items, their `questions[]` and `already_fixed` included, stay in § 6.3's head-bound disposition comment and never take this route.
2. Other reply bodies follow § 6.3's table.
   - A `questions[]` item § 5 routed here takes the Question row: its own `draft_response`.
   - A question is not a finding, takes no disposition, and is never answered `Declined:`.
3. A skip that contradicts a recorded decision spells its `[REASON]` `contradicts [DECISION_ID]`. File the issue a `Tracked:` reply names before you post the reply.
4. Write each reply body with the harness file tool to `tmp/pr-reply-[SOURCE_ID].md`, and bind it as `[BODY_FILE]`.
   - Use `github.sh post-reply [ID] --body-file [BODY_FILE]` for a thread.
   - Use `github.sh post-comment [PR_NUMBER] --body-file [BODY_FILE]` for a PR-level comment.
   - Number lists `1.` `2.` `3.`, never `#N`.
5. **Contested bot reviews.** When a domain agent classifies a bot's blocking comment as noise:
   - tag the bot with the reason and a re-review request;
   - dismiss its `CHANGES_REQUESTED` with `github.sh dismiss-review [PR_NUMBER] --bot --message "[REASON]"`, and resolve the thread.

   Tag a human reviewer the same way, and never dismiss a human's review.

6. Resolve every thread a reply was posted to. Keep open only the threads awaiting a human answer.

### 7.2 Copilot Head Route

**Skip if** workflow state `pr_order` reads `open-first-returned`, `push-first` or `push-first-returned`: send no notice and no request.

- For `push-first-returned`, first complete [submit-pr.md § 2](submit-pr.md#2-push-and-submit) step 4's **Push-first ready head** block, a head already ready included. That block changes the order to `push-first-pushed` before this step's call.
- The other skipped orders still hold the lane's `Review:` line pending and take submit-pr's publication route.

1. Run § 1's current-head Copilot wait and route it by § 1's table. Keep its reply as `[COPILOT_WAIT]`.
2. Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing).
   - Run [the review call](../references/gates.md#the-review-call) once, from `[WORKTREE_PATH]`, with `[MARK_READY]` `false`, and keep its reply as `[REVIEW_READ]`.
   - A call whose `head` differs from `[COPILOT_WAIT]`'s runs the wait again, then the call.
3. Route the reply:
   - A refusal ends this step: report its keyed line.
   - A reply whose `status` is `unreadable` ends it too, with or without a `mode`. Report its `reason` and `detail`.
   - A `pending` reply whose `reason` opens `head-moved` restarts this § 7.2 from its Copilot wait.
4. Under either gate mode, bind the reply's `head` as `[HEAD_SHA]` before any approval-only exit. Then read every review of the pull request, oldest first, one id, login, `commit_id`, `state` and body per line:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api --paginate 'repos/{owner}/{repo}/pulls/[PR_NUMBER]/reviews' --jq '.[] | [.id, .user.login, .commit_id, .state, .body] | @tsv'
   ```

**Body findings.** Copilot writes a finding on code the diff left unchanged only in its review body, under `Previously missed` or `Suppressed comments`. No thread carries it, and an `APPROVED` review can carry one too. Run the one reader of those bodies at two points:

- after binding the head and the reviews, before any approval-only exit or route selection;
- again before a `copilot-approved-on-rerequest` or `copilot-declined-unchanged` notice, or the `timeout` row's `copilot-fallback` notice.

A body finding is then answered before the lane waits on CI, not at the merge gate:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" check-review-replies [PR_NUMBER]
```

- A `head=` other than `[HEAD_SHA]` restarts this § 7.2 from its Copilot wait, review call and reviews read.
- Exit `1` with `suppressed-entry` lines: save `[HEAD_SHA]` as `[BODY_REVIEW_HEAD]` in the new pass's context, then loop to § 2.
  - Each entry is an item: `source_type: "review-body"`, `source_id` the entry's token, and the finding's text from the review at `[BODY_REVIEW_HEAD]` in the reviews read.
  - Carry that head with each entry's source identity through analysis, reporting and publication. A later head read or fix push never replaces it.
  - The pass runs §§ 5-6, Recurrence before the cap, the fix set, verification and cause records included. § 6.3 posts its body replies and counts the pass once.
  - After § 6.3, restart this § 7.2 from its Copilot wait, review call, reviews read and route selection, the body check included. A pushed head's body findings take their own pass, with that head as their source.
  - Keep the handled body items with their source-reviewed heads for the skip decision and the notices.
  - Complete § 8 before returning to the caller with the current head and whether the pass pushed. Discard every route selected before the pass.
- Exit `1` with any other rule's line: rewrite the replies by [submit-pr.md § 6.1 Merge Gates](submit-pr.md#61-merge-gates).
- Exit `2` reached no verdict: report its first stderr line and send nothing.
- Before an exit `0`, no notice this step sends goes out, and no step ends on an approved head.
- Under the thread lines of a `copilot-declined-unchanged` or `copilot-fallback` notice:
  - add one line per body finding with its `path:line` and the URL of the comment that answered it;
  - add one line naming the id of each Copilot review at `[HEAD_SHA]` from the reviews read.

**Routes.**

1. `off` ends this step once the body check exits `0`, per [Gate-mode routing](../references/gates.md#gate-mode-routing).
2. Under `approval`, end the step once the body check exits `0` when neither a thread nor a review-body item this triage handled is Copilot's.
3. A reviews line whose `commit_id` is `[HEAD_SHA]` and whose `state` is `APPROVED` ends this step after the body check's exit `0`: the head is approved.
4. Otherwise every Copilot thread is answered and resolved by now. The route is whether the head moved since the last head Copilot read, the `commit_id` of the last `copilot-pull-request-reviewer[bot]` line:
   - **Head unmoved.** Send the notice below with the first line `copilot-declined-unchanged PR #[PR_NUMBER] head [HEAD_SHA]`.
     - Under it, add one line per thread that `github.sh pr-threads [PR_NUMBER]` lists with `author` `copilot-pull-request-reviewer`. Each line gives the thread's `id`, its location and the reply that answered it, a decline's reason included.
     - Request no Copilot re-review. The overseer approves the head under [copilot-head-notices.md](../references/copilot-head-notices.md).
   - **Head moved**, by a push for any reviewer's thread or body finding. Route `[REVIEW_READ]`'s `request` by [Copilot requests](../references/gates.md#copilot-requests).
     - `requested` or `existing` takes the wait below.
     - `fallback` starts no wait and takes that section's fallback route.
     - This step sends none of the notices the reply's `notices` names.

**The wait on a moved head.** Wait on the head through [the review wait](../references/gates.md#the-review-call), run so that a silent head ends `timeout`, never `proceeded`:

```bash
env PR_REVIEW_ON_TIMEOUT=block .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-review-request-[ISSUE_ID].json"
```

On a `complete` reply, compare its `head` with `[HEAD_SHA]`.

- A different head restarts this § 7.2 from its Copilot wait.
- Otherwise read the reviews again. A `copilot-pull-request-reviewer[bot]` line whose `commit_id` is `[HEAD_SHA]` is the re-review:

| Verdict | Copilot's review at `[HEAD_SHA]` | Then |
|---------|----------------------------------|------|
| `comments` | any | Update the baseline and loop to § 1 for each open thread this triage has not answered, as § 6.3 does; this section then routes the head again, except as below the table |
| `approved` | `APPROVED` | Run the body check; on its exit `0`, send the notice `copilot-approved-on-rerequest PR #[PR_NUMBER] head [HEAD_SHA]` |
| `approved` | none, or not `APPROVED` | No notice from this step: another reviewer approved the head, and no hold of [Copilot requests](../references/gates.md#copilot-requests) stands |
| `copilot-error` | error answer | Route as [Copilot requests](../references/gates.md#copilot-requests) says. The caller keeps the approval gate unmet and waits for the overseer's approval |
| `timeout` | present, not `APPROVED` | Copilot read the head again and left no open thread. Send the notice `copilot-fallback PR #[PR_NUMBER] head [HEAD_SHA]`, which asks for the overseer's fallback approval |
| `timeout` | none | No notice: the overseer's `awaiting-stale` rule decides the head |
| any other | any | No notice: the caller's own review wait routes it |

The call answers `comments` while any thread stands open. On `comments` where every open thread is one § 7.1 keeps open for a human, every repeat answers `comments` until the human answers: end this step and leave the head to the caller's own review wait.

**Notice.** In a lane, write the notice with the harness file tool to `[WORKTREE_PATH]/tmp/copilot-head-[ISSUE_ID].md` and send it:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file [WORKTREE_PATH]/tmp/copilot-head-[ISSUE_ID].md
```

Outside a lane no overseer reads a notice, and the caller's own review wait decides the head.

### 7.3 Present And Await

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

Under `ask` only: awaiting your response to ask questions, override skipped items, or confirm done.

</output_format>

- `auto-recommended` logs `Continue`, clears any stop, and goes to § 8 with no question.
- `ask` stops here. A managed run returns the pending choice to its caller instead of continuing.
- A request to fix a skipped item delegates that one item through § 6.1, pushes, and returns here.
- A confirmation clears any stop and goes to § 8.

**Standalone only.** When the triage fixed anything or created issues:

1. Write the cumulative summary to a file in the session-summary form of [post-summary.md § 1](post-summary.md#1-post-the-summary), and post it as a PR comment. Items not addressed go under its Skipped subsection with their reason.
2. When `TRACKER` is `linear`, post it on the Linear issue too.

## 8. Update State And Return

- Run one tool call per block, one append per item.
- A fix entry and a skip entry carry the finding's own text, so write each to a file with the harness file tool and bind it by path.

A fix:

```json
{"description": "[DESC]", "location": "[LOC]", "commit": "[SHA]", "source": "[SOURCE]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"fix","file":"[WORKTREE_PATH]/tmp/state-fix-[ISSUE_ID].json"}'
```

A skip:

```json
{"description": "[DESC]", "reason": "[REASON]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"skip","file":"[WORKTREE_PATH]/tmp/state-skipped-[ISSUE_ID].json"}'
```

An issue id is not finding text and stays inline:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"issue","id":"[CREATED_ISSUE_ID]","origin":"triage"}'
```

- **Managed**: return to the parent workflow's next section, with the recorded `autoMergeRequest` where § 6.1 pushed.
- **Standalone**: return `.post_pr_stop` when present; otherwise the triage session is complete.
