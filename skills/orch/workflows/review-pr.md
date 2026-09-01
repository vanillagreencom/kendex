# PR Review Workflow

Pre-submission review: reviewer fan-out, bounded fix rounds, QA checks, and the issue audit.

| Command | Behavior |
|---------|----------|
| `review-pr` | Full cycle: review, fix, QA, summary |
| `review-pr [PR#]` | Resolve the PR's worktree, then the full cycle |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `agents` — an explicit reviewer panel, default every `reviewer-*` agent the harness exposes; `lifecycle` — `"managed"` (return at § 9) or `"self"` (default); `dev_agent` — a live dev agent for fix delegation; `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

**With a PR number**: `github.sh pr-issue [PR_NUMBER] --format=text` gives `ISSUE`. Apply [Worktree Scope](../SKILL.md#workflow-execution); ask before `worktree create $ISSUE --pr [PR_NUMBER]`. With no argument, `WT_PATH` is `git-context repo-root .`.

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.
`[DIR]` is the checkout the paragraph above resolves `WT_PATH` from.

**Standalone init** (`lifecycle: "self"`): resolve `ISSUE_ID` with `git-context issue-from-branch .`, then `workflow-state exists --json [ISSUE_ID]`; when absent, initialize with `git-context branch [WT_PATH]` and `workflow-state init`, and resolve `TRACKER`. On this path § 5 derives its QA signals from the diff scan and judgment — there is no dev artifact.

---

## 1. Identify Changes

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] status --porcelain
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

A non-empty `status --porcelain` stops the review. Managed with a `dev_agent`: re-delegate to commit or revert the leftovers, then re-enter § 1. Standalone: report the dirty files and ask the user to commit, revert, or run `orch review all` for an ad-hoc uncommitted review. No committed diff after that check → report "No committed changes to review" and **END**.

**Trivial diffs skip review by rule, not by asking.** A diff that is docs- or comments-only, or under ten changed lines with no logic change, records the skip and goes to § 9 with verdict `pass`:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] review_skipped "tiny-docs"
```

### 1.1 Decision Context

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory. Verify each before injecting it, one command per path:

```bash
test -f [DECISION_FILE_PATH]
```

A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

### 1.2 Re-Review Context

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: (.cycles // 0), fixed_items: (.fixed_items // []), escalated_items: (.escalated_items // [])}'
```

`cycles > 0` fills the "previous review cycle" block of the delegation from `fixed_items` and `escalated_items`.

## 2. Prepare Reviewers

`[AGENTS]` is the caller's `agents` context when provided, otherwise every `reviewer-*` agent this harness exposes. Do not hardcode a count or a list. Where the harness exposes `reviewer-error`, a diff owning a subprocess, a transport (stream, socket, SSE), or a teardown path always carries it: relevance never drops it from the panel. With no reviewers available, skip to § 5 with verdict `pass`.

Resolve the reviewer mode per [SKILL.md § Agent Lifecycle](../SKILL.md#agent-lifecycle):

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

Check for a recorded runtime demotion before choosing persistent mode:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{observed: (.reviewer_slots_observed // 0), live: (.child_sessions // {} | [to_entries[] | select((.value.status // "active") == "active")] | length)}'
```

`observed > 0` → wave mode at that size. Otherwise a budget of `0` is persistent mode, and a budget above `0` gives `REVIEWER_SLOTS = budget - 1 - live` (minimum 1; the `1` is this primary session), with wave mode when `[AGENTS]` exceeds it. A `child_sessions` record with no `status` counts as active. Recompute at every § 2 entry.

Read existing reviewer state before any spawn:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{review_agents: (.review_agents // []), review_agent_ids: (.review_agent_ids // {}), review_agent_runtime_types: (.review_agent_runtime_types // {})}'
```

Classify each reviewer in `[AGENTS]` as reusable, missing, closed, or confirmed-stuck: reuse by exact name when its recorded id points to a live session, attempt one resume when only a name is recorded, and add only the rest to `REVIEWERS_TO_LAUNCH`. Carry a reusable reviewer's existing runtime-type entry forward. On a RE-REVIEW whose panel shrank (§ 4 scopes it), retire the out-of-panel sessions first. **Do not spawn yet** — resolve § 2.1 first.

### 2.1 External Review Availability

External review runs automatically alongside the internal panel when available, treated identically to an internal reviewer. No user prompt.

**Skip if** `.agents/skills/second-opinion/scripts/second-opinion` does not exist → `EXTERNAL_REVIEW_REQUESTED=false`.

```bash
.agents/skills/second-opinion/scripts/second-opinion detect
```

A failure, `none`, or empty output sets `EXTERNAL_REVIEW_REQUESTED=false`; anything else sets it `true`. The output is an availability signal only — the external review is launched without `--target`. On `none`, the error JSON's `candidates` carry a reason per target. Tell the user once — `External review skipped — [CANDIDATE_REASONS]. Fix: [FIX]` — then continue. `[FIX]` follows the reasons: **CLI not found** → install that target's CLI or set its `SECOND_OPINION_<NAME>_CMD` in `kendex.settings.toml [env]`; **same model as this session** or a session-identity reason → export `SECOND_OPINION_CURRENT_MODEL` in this session (session-scoped, never committed to project settings) or widen `SECOND_OPINION_MODELS`.

### 2.2 Launch And Delegate

Spawn each reviewer in `REVIEWERS_TO_LAUNCH`, resolving Codex spawn parameters with `scripts/spawn-adapter spawn <reviewer-name>`. In **wave mode**, restrict this section to `[WAVE]` — the first up-to-`REVIEWER_SLOTS` reviewers in `[AGENTS]` not yet in `review_wave_done` — and reset the tracking on entry from § 2.1 (skip the reset when re-entering from § 3.2 for the next wave of the same cycle):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] review_wave_done '[]'
```

A retired reviewer has no session to reuse: recreate it fresh and write state with the live wave only. If a spawn fails with the runtime's thread-limit error, do not retry it and do not tear down the reviewers that did spawn — continue with those, fold the failed reviewer into a later wave, and use that smaller size for the rest of the cycle. Record the demotion in one write:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.reviewer_slots_observed = [OBSERVED_SPAWN_COUNT] | .review_wave_done = []'
```

Then tell the user once: `Runtime capped concurrent agent sessions — set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in kendex.settings.toml [env]`, where `[OBSERVED_BUDGET]` is successful spawns + this session + live dev/QA sessions. If nothing spawned at all, report the misconfiguration and stop.

Store the active set:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON] | .review_agent_ids = [AGENT_ID_MAP_JSON] | .review_agent_runtime_types = [AGENT_RUNTIME_TYPE_MAP_JSON]'
```

Stamp the freshness boundary immediately before the delegation batch. In wave mode, re-stamp before each wave's batch:

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at
```

Delegate to every reviewer in the active set in parallel. When `EXTERNAL_REVIEW_REQUESTED=true`, launch the external review in the same batch — a shell command, not an agent session: it consumes no slot and joins only the cycle's first wave. Mint each reviewer's artifact path immediately before its delegation — one command per reviewer, its output filling `[ARTIFACT_PATH]`:

```bash
.agents/skills/orch/scripts/review-artifact-check --path [WORKTREE_PATH] [AGENT]
```

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.
Branch: [BRANCH]
Artifact: [ARTIFACT_PATH]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
<if re-review cycle>
Diff-range: [a § 4 or § 7 re-entry only — `[PRE_SHA]...HEAD` when that section's `pre_delegate_sha` read returned a sha, the bare word `unavailable` when it returned `null` or nothing; omit the line on a § 1 entry]
Re-review cycle [N]. Already resolved — do NOT re-report the entries listed below, unless you check a Fixed entry against the current diff and the defect is still there: report that one again, copying that entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha, so the stale entry can be superseded. A Fixed entry you did not check, and every Escalated entry, stays suppressed.
- Fixed: [For each fixed_item: "[LOCATION] | [DESCRIPTION] — fixed in [COMMIT_SHA]"; an entry whose commit is a `dropped:<sha>` marker prints "recorded, then dropped in a rebase" in place of the sha]
- Escalated: [For each escalated_item: "[LOCATION] | [DESCRIPTION] — [REASON]"]
</if>
<if this reviewer session was recreated fresh>
Fresh session — you have no memory of earlier cycles. Read your prior report [PRIOR_REPORT_PATH] and re-read the current diff before reviewing.
</if>
</delegation_format>

`[PRIOR_REPORT_PATH]` is that reviewer's most recent `review-[AGENT]-*.json` from state `json_paths`.

**External review** (only when requested). Run `second-opinion …`; it backgrounds itself and prints when to check. `[RANGE_FLAG]` is `--range [PRE_SHA]...HEAD` on a re-entry whose `pre_delegate_sha` read returned a sha, and empty otherwise, leaving the script's own `origin/BASE...HEAD` default: the external lane sits in the scoped panel and takes the panel's boundary.

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-external-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json --foreground [RANGE_FLAG]
```

Execute the exact command printed after `wait:`. Exit 75 means completion is still recoverable; process other reviewer events, then rerun the same command. Exit 124 is terminal: the run reached its deadline, and its processes are stopped when they can still be identified as belonging to it. When terminal, validate its artifact like a reviewer JSON, with `review_delegated_at` as the freshness boundary (the § 3.1 sweep covers a silent finisher):

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```

`ok == true` → append the path to `json_paths`; `reason == "valid_undermeasured"` → report its `measurement_failed` string — and `measurement_suppressed` when present — beside the path; never present the external pass as clean. `ok == false`, or any non-zero exit, → report the `reason` (and `detail` when present) and continue: external review is advisory, never blocking, and never substitutes a pass. A detached run that has already exited non-zero, or an artifact that does not validate, is **resolved** right then as `external: failed — [REASON]` (the script's exit class, or the check's `reason`) and leaves `OUTSTANDING` in § 3.1.

## 3. Collect Results

**Persistent mode**: keep reviewers alive for § 4. **Wave mode**: retire each reviewer as its artifact validates, freeing the slot for the next wave.

### 3.1 Completion

`OUTSTANDING` is the active set plus `{external}` when requested. A reviewer completes **only** when its on-disk artifact validates — a return message carrying `Verdict:`/`File:` is never sufficient:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```

Run it on every return message and every watchdog sweep. `ok == true` → drop the agent from `OUTSTANDING` and append its path; `reason == "valid_undermeasured"` → carry the result's `measurement_failed` string into the review summary beside that verdict, with `measurement_suppressed` when present, and never present the domain as clean.

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
```

Wave mode uses this combined write instead, then shuts that reviewer's session down:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.json_paths += ["[PATH]"] | .review_wave_done += ["[AGENT]"]'
```

`ok == false` after a return means the return is **incomplete**, whatever its `File:` path or message body claims. Send that agent **exactly one** re-delegation:

> Your review return is incomplete: `review-artifact-check` reports `[reason]`[ — `[detail]`] for `[WORKTREE_PATH]/tmp/review-[AGENT]-*.json`. Write your full review JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` using your harness file-write tool (not shell redirection), following every required field of `review-finding.md`, then return `Verdict:` and `File:` again.

Still `ok == false` after that, or the § 3.2 deadline reached → mark the agent `unresponsive`. Never re-delegate a second time.

### 3.2 Watchdog

**No wait here is unclocked: while any agent this workflow delegated has not completed (§ 3.1), a wake source for it is armed.** A reviewer that finishes and whose return message is never delivered produces no event, so no row below fires and the wait is silent and unbounded. An agent's wake source is one backgrounded `review-artifact-check [WORKTREE_PATH] [AGENT] [REVIEW_DELEGATED_AT] --wait [SECS]` whose `[SECS]` expires at the earliest row of the table below still pending for it, which is that agent's deadline once no row above it remains; the external lane's is the `wait:` command § 2.2 prints. Arm them with the delegation batch, and re-arm after every action below, a status ping included — a reply promising completion extends nothing without a re-armed clock. A re-arm that follows a rejected artifact (§ 3.1) waits for one newer than that rejection: its `[REVIEW_DELEGATED_AT]` is strictly greater than the rejected artifact's mtime.

Sweep the filesystem on every wake. Per-agent deadline from `review_delegated_at`: 25 minutes for an agent whose name contains `perf`, 15 minutes for every other agent. The external lane's printed deadline is absolute Unix epoch seconds; compare it with `date +%s`. If no deadline metadata prints, use 2 × `SECOND_OPINION_TIMEOUT` plus 3 minutes, with 1080 seconds as the timeout default. It is not a messageable agent, so the ping row and its early end never apply to it.

| Event | Action |
|-------|--------|
| Return arrives | Run `review-artifact-check` (§ 3.1) |
| 2 min after the first return, or 10 min from delegation with no returns — once per cycle (wave mode: per wave) | Ping each outstanding agent once (external exempt): `Status check on [ISSUE_ID] review — return your verdict if complete, or report the blocker.` |
| 2 min after that ping | Mark each non-perf **agent** still outstanding `unresponsive` — never the external lane |
| Per-agent deadline (external: printed deadline, else 2 × timeout + 3 min) | Mark that agent or lane `unresponsive` |

Wave mode also shuts an `unresponsive` reviewer down and records it, so the slot frees and the reviewer does not relaunch this cycle:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] review_wave_done "[AGENT]"
```

`OUTSTANDING` empty (`unresponsive` counts as resolved) → § 3.3 in persistent mode; in wave mode, return to § 2.2 for the next wave while any reviewer in `[AGENTS]` is missing from `review_wave_done`, else § 3.3.

### 3.3 Present

Overall verdict is `action_required` when any reviewer reported blockers, else `pass`. Unresponsive reviewers do not affect it.

<output_format>

### ✅ PR REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[verdict\|unresponsive]` | `[path or —]` |

</output_format>

Blockers or `category == "fix"` suggestions present → § 4. Otherwise → § 5.

## 4. Handle Review Items

Collect blockers and `category == "fix"` suggestions from the appended JSONs. None → § 5.

<output_format>

### PR Review Items — [ISSUE_ID]

**Blockers**

| # | Agent | Location | Description | Pri |
|---|-------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | 🔴 |

**Fix Suggestions**

| # | Agent | Location | Description | Pri | Est |
|---|-------|----------|-------------|-----|-----|
| 1 | [agent] | [location] | [description] | 🟤 | 1 |

</output_format>

Omit empty categories. Decline any item that cannot affect real usage with a one-line reason here, per [SKILL.md § The Cycle](../SKILL.md#the-cycle) — it is neither fixed nor filed, and it is reported in § 8.

**Disposition is by rule, not by prompt** — never present a selection menu over the findings. Disposition every finding per [references/finding-disposition.md](../references/finding-disposition.md) § Decision flow, Step 0 first, and only what survives it enters the fix set. Every blocker and `category == "fix"` suggestion that survives goes to the fix round below, in EVERY decision mode; `ORCH_DECISION_MODE` does not gate it. The always-ask set in [SKILL.md § The Cycle](../SKILL.md#the-cycle) still applies.

**Recurrence before the cap.** A finding sharing a root cause with one a prior round patched is dispositioned by [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence), and no further patch round answers it. Check it here, ahead of the cap below. Each disposition owes one thing and reaches one place, and no later step re-derives it: `structural-close`, which a cause this diff introduces or arms takes, owes an item naming the generating surface in place of the site and reaches the fix round whatever `rereview_cycles` reads; a cause this diff neither introduces nor arms owes the At The Cap write below, its `reason` reading `recurrence outside this diff's authorship` in place of the cap's, and reaches § 8, which files it; a cause `frozen_causes` names owes its one-line reason and reaches § 8's declined report. The `fix set` is what this section delegates — every item still standing after declines, plus every `structural-close`, and at the cap those alone. Empty → § 5, otherwise → Fix Delegation. Read both records first:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{patched: (.pr_comment_review.patched_causes // []), frozen: (.pr_comment_review.frozen_causes // [])}'
```

### At The Cap

The cap decides before any delegation. One call reads the re-review cycles already entered, the cap they are measured against, and the verdict:

```bash
.agents/skills/orch/scripts/workflow-state cap REVIEW_MAX_CYCLES --issue [ISSUE_ID]
```

It prints `below [COUNT]/[CAP]` or `at-cap [COUNT]/[CAP]`. `rereview_cycles` counts the re-review cycles this loop has entered — the Bounded Re-Review write below raises it, and nothing else does. Below the cap → Fix Delegation. At it the fix loop ends here — the count is entries already taken, so it never goes past the cap — with no fix round beyond the `structural-close` items the `fix set` carries past it, so the items this pass reported are the latest word on the diff. Read `rereview_cycles`, never `cycles`: `cycles` is the general fix-round tally `dev-fix.md` keeps, and QA and pre-loop fix rounds bump it without spending this budget.

**Capped items are escalated, never dropped.** Record every blocker and `category == "fix"` suggestion this pass found still outstanding, including one already listed in `fixed_items` whose fix did not hold. Exclude only what is already in `escalated_items`, what § 4 declined, and the `fix set`'s `structural-close` items; a decline is terminal. Match on the RECORDED entry's (location, description), the § 8 key — a re-reporting reviewer copies both fields verbatim off the Fixed line, so the pair matches. An item `fixed_items` already lists has a superseded entry there: its fix did not hold, so the same write drops it. One write per item, before routing to § 5 — the drop and the record land in one command, so the item is never in both buckets and never in neither:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile art '[ARTIFACT_PATH]' --arg src [SOURCE] '$art[0].[ARRAY][[INDEX]] as $item | .fixed_items = ((.fixed_items // []) | map(select(.location != $item.location or .description != $item.description))) | .escalated_items = ((.escalated_items // []) + [{description: $item.description, location: $item.location, reason: "outstanding at the review cycle cap", outcome: "blocked", source: $src}])'
```

`[ARTIFACT_PATH]` is the `json_paths` entry the item came from, `[ARRAY]` is `blockers` or `suggestions`, and `[INDEX]` is its position there. Only a path, an array name, and an integer are ever typed: the finding's own text stays inside the artifact and reaches jq through the binding. It must never be pasted into the command, in a quoted shell word or anywhere else — a location like ``fs.rs::write_all's guard`` ends the shell word early and the item goes unrecorded, and `$(…)` and multi-command blocks are rejected shapes ([references/codex-runtime.md](../references/codex-runtime.md)), so the file is the only channel.

`[SOURCE]` is `pr-review` here and `qa-review` for a QA-sourced item that reached this rule through § 7's return path. § 8 then reports them as escalated instead of re-deriving them as declined, and they reach its filing candidates, taking each item's agent and priority from the `json_paths` artifact it came from. Report the outstanding items and proceed to § 5.

### Fix Delegation

**Skip if** the `fix set` is empty. Findings that leave `items` are never dropped: declined per [finding-disposition](../references/finding-disposition.md) when a cut removed their surface, recorded in `escalated_items` when § 8's audit is to file them. Never fix as the main agent.

```bash
.agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
```

**Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4 re-review` with context `worktree`, `lifecycle: "managed"`, `dev_agent`, `issue_id`, `items` (the `fix set` above, each formatted `#[N] | [Agent] | [Location]` with Description and Recommendation), and `source: pr-review`.

### Bounded Re-Review

Re-review is scoped to what the fix round actually changed. Read the round's diff to decide:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pre_delegate_sha
.agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] [PRE_SHA]
```

| Round | Next |
|-------|------|
| No files changed | → § 5 |
| Only minor suggestions applied, no blocker cleared, and the diff stays inside already-reviewed domains | Record the skip below → § 5 |
| Anything else | → § 2 with caller context `agents` = the scoped panel below |

The scoped panel is the union of the reviewers whose domains the round's diff touched, the reviewers who found the blockers it cleared, and external review when available. Record the scoping:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] rereview_panel '{"agents": [PANEL_AGENTS_JSON], "reason": "[DOMAINS_TOUCHED] + blocker finders + external"}'
```

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] rereview_skipped '[REASON]'
```

**The loop ends** when two consecutive cycles surface no new blocker, or when the At The Cap check above ends it (the `rereview_panel` write raises `rereview_cycles` and refuses once that count reaches the cap). The cap bounds NEW cycles, never verification: a fix diff no reviewer has seen gets one focused verification pass — the `rereview_panel` rule above, scoped to exactly that diff — and this loop's last fix round has budget for it. A pass over a diff no reviewer has seen once the budget is spent takes `verification_panel` instead, which the cap does not gate. That pass's items re-enter § 4, where the `fix set` decides what still delegates. In wave mode the panel replaces `[AGENTS]` for the cycle and wave mechanics apply unchanged.

## 5. Verdict Pass

Shut the review agents down and clear their state (wave mode: sessions are already retired, so this only clears state):

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [] | .review_agent_ids = {} | .review_wave_done = []'
```

Then decide the QA routing. The inputs, in precedence order:

1. **Dev signals** — the dev round's artifact `qa_labels` (its § 8 self-assessment of the final code).
2. **Diff scan** — deterministic checks on the round's full diff:

```bash
git -C [WORKTREE_PATH] diff --quiet -G'unsafe |Ordering::|Atomic(U|I|Bool|Ptr)' "origin/[BASE_BRANCH]"...HEAD
```

   `[BASE_BRANCH]` is the § 1 `resolve-base-branch` output. Exit **1** means a matching change exists and adds `needs-safety-audit`; **0** means no signal; any other exit is an error. When the repo sets `QA_PERF_PATHS` (space-separated path globs), any changed file matching one adds `needs-perf-test`:

```bash
.agents/skills/orch/scripts/orch-env QA_PERF_PATHS ""
```

3. **Judgment** — you may add or drop a signal with a one-line reason; record it:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] qa_decision '{"signals":[SIGNALS],"rationale":"[ONE_LINE]"}'
```

Drop a signal when the triggering code is trivial or test-only; never drop one for schedule pressure. `skip_qa` true → set it false, record `qa_decision` with `"rationale":"user skip"`, → § 7. Signals empty → § 7. Otherwise → § 6. Both of those reach § 7 rather than § 8: with no QA findings **Converged** is true and its disposition writes nothing, so the routing is unchanged and the exit stays in one place.

## 6. QA Checks

**Skip if** the recorded `qa_decision.signals` is empty → § 7, which finds no QA artifacts, converges, and routes on: the exit is decided in one place even when QA never ran.

Map each signal to its agent — `needs-safety-audit` → `reviewer-safety`, `needs-perf-test` → `reviewer-perf`, `needs-review` → `reviewer-correctness`; a project may override the mapping in its instructions. For each, delegate and wait.

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.
`[DIR]` is the checkout the top of this workflow resolves `WT_PATH` from.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/qa-review.md

Issue: [ISSUE_ID]
Tracker: [TRACKER] [OWNER/REPO]
Branch: [BRANCH]
Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.
Trigger: [QA signal]

Dev summary:
[completion summary from the dev return, or a description of the branch changes]

Previous review cycle context (cycle [CYCLES]):
- Fixed since last review: [For each fixed_item with source "qa-review": "[LOCATION] | [DESCRIPTION] — fixed in [COMMIT_SHA]"; an entry whose commit is a `dropped:<sha>` marker prints "recorded, then dropped in a rebase" in place of the sha]
- Escalated (accepted): [For each escalated_item with source "qa-review": "[LOCATION] | [DESCRIPTION] — [REASON]"]
- Do NOT re-report the fixed or escalated items listed above, unless you check a listed fixed item against the current diff and the defect is still there — then report it again, copying that entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha. A listed fixed item you did not check, and every listed escalated item, stays suppressed. Otherwise report only new issues or regressions the fixes introduced.
</delegation_format>

Omit `[OWNER/REPO]` when `TRACKER=linear`. On return, append the artifact path to `json_paths`; when the agent reports a `benchmark_commit` other than `none`, confirm it resolves with `git -C [WORKTREE_PATH] log -1 --oneline [SHA]`. A performance QA agent's `qa_metadata.perf_qa` block is posted as an issue comment — Linear via `linear.sh comments create [ISSUE_ID] --body-file`, GitHub via `gh issue comment ${ISSUE_ID#issue-} --body-file` — written to a file first. A `pass` verdict continues to the next QA agent. After all QA agents complete, → § 7 — every verdict, every time: § 7 owns the exit and no branch here decides one around it, carrying the blockers and the `category == "fix"` suggestions not already in `escalated_items`. An item this round's QA artifact reports again is retained even when `fixed_items` lists it — that entry is stale, and dropping the item here would hide a live blocker behind the earlier fix.

## 7. Handle QA Items

When **Converged** below is false, follow the § 4 pattern — collect, present, run its recurrence check on the same two records, then delegate through `workflows/dev-fix.md`, by rule and with no selection prompt — with these overrides: the `fix set` is § 4's, dispositions and all; items come from the QA JSONs excluding anything already in `escalated_items`, and excluding a `fixed_items` entry only when this round's QA artifact does not report it again; the table header is `QA Agent` and the title `QA Review Items — [ISSUE_ID]`; `source` is `qa-review` and `qa_agent` carries the agent name. A re-found item is retained on purpose: its `fixed_items` entry is stale, and the Converged exit below is what drops that entry and records the item. **No cap check runs here**, and the § 4 budget `REVIEW_MAX_CYCLES` bounds is neither read nor raised in this section: a QA re-check is not a re-review cycle, and a § 4 loop that spent its whole budget still owes this round its QA re-check. After the fix round, apply the § 4 bounded re-review rule with § 6 as the target instead of § 2 — a focused QA re-check whose panel is set on `qa_recheck_panel` — unless the round's diff reaches beyond QA's own surface, which returns to § 2 with its panel on `verification_panel`. Both are sibling keys the `rereview_panel` guard neither counts nor refuses: a verification pass is not a fix cycle, so `REVIEW_MAX_CYCLES` does not gate it, which is what § 4's own rule says in words. Either target re-runs the QA agents or the reviewers and comes back here; neither decides an exit.

### Converged

This is the one exit predicate for QA, and the only route to § 8: § 6, a QA re-check, and a § 2 verification pass all come back here and none of them returns on its own. **Converged** is true when this round's QA artifacts report nothing this section can act on: a blocker or a `category == "fix"` suggestion first raised on this pass is a new finding, and the predicate is false. A `category == "issue"` suggestion is not one of them. § 7 delegates blockers and `category == "fix"` suggestions, so an issue suggestion would turn the loop with nothing to hand a fix round; it rides through to § 8, where the audit pipeline files it as the finding contract says. True → the disposition below, then § 8. False → the fix round above. The predicate stops repeated patching of a finding already answered; it never discards one. The loop otherwise runs on while each round finds a DISTINCT defect this diff introduced, each of those earning its fix, and stops the moment one root cause reappears at a new site: that round's answer is [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence)'s structural close, cutting the surface that generates the class, never another patch round.

On the way out, and before § 8, disposition every item still outstanding — every blocker and every `category == "fix"` suggestion this round's QA artifacts report, whether or not `fixed_items` already lists it, excluding only what `escalated_items` carries and what this section declined; an item dev returns as Blocked reaches `escalated_items` through `dev-fix.md` unchanged. One write per item, which drops any superseded `fixed_items` entry and records the item in the same command, its `[ARTIFACT_PATH]` the `json_paths` entry the item came from, `[ARRAY]` either `blockers` or `suggestions` and `[INDEX]` its position there, so the finding's own text reaches jq through the file, never a quoted shell word, and the reason is this exit's own, never the cap's:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile art '[ARTIFACT_PATH]' '$art[0].[ARRAY][[INDEX]] as $item | .fixed_items = ((.fixed_items // []) | map(select(.location != $item.location or .description != $item.description))) | .escalated_items = ((.escalated_items // []) + [{description: $item.description, location: $item.location, reason: "QA loop converged with the item unresolved", outcome: "blocked", source: "qa-review"}])'
```

## 8. Summary And Issue Audit

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), fixed: (.fixed_items // []), escalated: (.escalated_items // [])}'
```

Empty `json_paths` → report "No review items" and → § 9. Otherwise read every JSON, collect the `category == "issue"` suggestions, and deduplicate by (location, description), keeping the first and noting all sources.

**Declined items are re-derived, not remembered.** A blocker or `category == "fix"` suggestion that appears in a `json_paths` artifact but in neither `fixed_items` nor `escalated_items` was declined in § 4 or § 7. Carry each one's recorded reason; where a compaction lost it, report `reason: not recorded` rather than inventing one.

<output_format>

### REVIEW SUMMARY — [ISSUE_ID]

| Agent | Verdict | Blockers | Fix | Issue |
|-------|---------|----------|-----|-------|
| [AGENT_NAME] | ✅ pass | 0 | 0 | 1 |
| [AGENT_NAME] | ⚠️ action_required → fixed | 2 | 1 | 0 |

### ✅ FIXED BLOCKERS

| # | Source | Location | Description | Commit |
|---|--------|----------|-------------|--------|
| 1 | [agent] | [location] | [description] | [sha] |

### ⚠️ ESCALATED BLOCKERS

| # | Source | Location | Description | Pri |
|---|--------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | 🟠 |

### 🚫 DECLINED

| # | Source | Location | Description | Reason |
|---|--------|----------|-------------|--------|
| 1 | [agent] | [location] | [description] | [one line] |

### 📊 QA METRICS

[Per QA agent, the results its JSON `qa_metadata` returned — project-configurable.]

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4
Est: 1 (hours) | 2 (half-day) | 3 (day) | 4 (2-3d) | 5 (week+)

</output_format>

Omit empty sections.

**File only what clears the bar.** Apply [references/finding-disposition.md](../references/finding-disposition.md) § Filing bar to every candidate: `category: "issue"` suggestions, escalated items, and Discovered Work bullets from the dev return. Everything below the bar is absorbed or dropped with a one-line note.

Discovered Work bullets matching `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` are already in flight in this workflow — drop them silently. The filter applies to Discovered Work only.

Nothing clears the bar → § 9. Otherwise build the audit-input file per `.agents/skills/project-management/schemas/audit-issues-input.md` at `[WORKTREE_PATH]/tmp/audit-start-YYYYMMDD-HHMMSS.json`. Each escalated item's `origin` comes from its `outcome`: `"skipped"` → `origin: "skipped"`; `"blocked"` or no `outcome` field → `origin: "escalated"`. Set `tracker.type` to the resolved `TRACKER`, plus `tracker.repository` for GitHub items.

**Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 8 tail`. audit-issues is a primary-session wrapper holding the interactive approval gate: run it in this session, never delegated to a subagent; the only delegable part is the `tpm-audit.md` analysis, which audit-issues spawns itself.

Record each created issue:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] audit_issues_created "[CREATED_ISSUE_ID]"
```

**Children created to be worked here** (Linear only). When the audit created `make_child` issues under `[ISSUE_ID]`, delegate them immediately via `⤵ workflows/dev-start.md § 1-4` with context `worktree`, `lifecycle`: inherit, `issue_id`, and `audit_bundle: true`. If delegation is skipped, FIRST detach every `audit_issues_created` entry from `[ISSUE_ID]`, or `merge-pr.md` cascade-Dones them:

```bash
.agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --remove-parent
.agents/skills/linear/scripts/linear.sh issues add-relation [CHILD_ID] --related [ISSUE_ID]
```

After delegating children, apply the § 4 bounded re-review rule to their diff.

## 9. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete — the summary is in § 8.
