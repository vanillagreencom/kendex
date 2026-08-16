# PR Review Workflow

Pre-submission review: reviewer fan-out, bounded fix rounds, QA checks, and the issue audit.

| Command | Behavior |
|---------|----------|
| `review-pr` | Full cycle: review, fix, QA, summary |
| `review-pr [PR#]` | Resolve the PR's worktree, then the full cycle |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `agents` — an explicit reviewer panel, default every `reviewer-*` agent the harness exposes; `lifecycle` — `"managed"` (return at § 9) or `"self"` (default); `dev_agent` — a live dev agent for fix delegation; `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

**With a PR number**: `github.sh pr-issue [PR_NUMBER] --format=text` gives `ISSUE`. Apply [Worktree Scope](../SKILL.md#workflow-execution); ask before `worktree create $ISSUE --pr [PR_NUMBER]`. With no argument, `WT_PATH` is the current directory.

**Standalone init** (`lifecycle: "self"`): resolve `ISSUE_ID` with `git-context issue-from-branch .`, then `workflow-state exists --json [ISSUE_ID]`; when absent, initialize with `git-context branch [WT_PATH]` and `workflow-state init`, and resolve `TRACKER`. The § 5 QA routing derives its signals from the diff scan and judgment on this path — there is no dev artifact.

---

## 1. Identify Changes

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] status --porcelain
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

A non-empty `status --porcelain` stops the review — never review a dirty pre-submission worktree. Managed with a `dev_agent`: re-delegate to commit or revert the leftovers, then re-enter § 1. Standalone: report the dirty files and ask the user to commit, revert, or run `orch review all` for an ad-hoc uncommitted review.

No committed diff after that check → report "No committed changes to review" and **END**.

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

`[AGENTS]` is the caller's `agents` context when provided, otherwise every `reviewer-*` agent this harness exposes. Do not hardcode a count or a list. With no reviewers available, skip to § 5 with verdict `pass`.

Resolve the reviewer mode per [SKILL.md § Agent Lifecycle](../SKILL.md#agent-lifecycle):

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

`0` means unlimited unless an earlier cycle already recorded a runtime demotion — check before choosing persistent mode:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{observed: (.reviewer_slots_observed // 0), live: (.child_sessions // {} | [to_entries[] | select((.value.status // "active") == "active")] | length)}'
```

`observed > 0` → wave mode at that size. Otherwise a budget of `0` is persistent mode, and a budget above `0` gives `REVIEWER_SLOTS = budget - 1 - live` (minimum 1; the `1` is this primary session), with wave mode when `[AGENTS]` exceeds it. A `child_sessions` record with no `status` counts as active. Recompute at every § 2 entry.

Read existing reviewer state before any spawn:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{review_agents: (.review_agents // []), review_agent_ids: (.review_agent_ids // {}), review_agent_runtime_types: (.review_agent_runtime_types // {})}'
```

Classify each reviewer in `[AGENTS]` as reusable, missing, closed, or confirmed-stuck: reuse by exact name when its recorded id points to a live session, attempt one resume when only a name is recorded, and add only the rest to `REVIEWERS_TO_LAUNCH`. Carry a reusable reviewer's existing runtime-type entry forward rather than rebuilding it from newly spawned reviewers.

On a RE-REVIEW whose panel shrank (§ 4 scopes it), retire the out-of-panel sessions first.

**Do not spawn yet** — resolve § 2.1 first.

### 2.1 External Review Availability

External review runs automatically alongside the internal panel when available, treated identically to an internal reviewer. No user prompt.

**Skip if** `.agents/skills/second-opinion/scripts/second-opinion` does not exist → `EXTERNAL_REVIEW_REQUESTED=false`.

```bash
.agents/skills/second-opinion/scripts/second-opinion detect
```

A failure, `none`, or empty output sets `EXTERNAL_REVIEW_REQUESTED=false`; anything else sets it `true` with that output as `EXTERNAL_TARGET`.

Output of `none` is a settings gap, not a missing skill: stderr carries a JSON object whose `candidates` name each reason. Tell the user once — `External review skipped — [REASON]. Fix: export SECOND_OPINION_CURRENT_MODEL in this session (it is session-scoped, never committed to project settings), or set SECOND_OPINION_MODELS / SECOND_OPINION_<NAME>_CMD in vstack.settings.toml [env]` — then continue.

### 2.2 Launch And Delegate

Spawn each reviewer in `REVIEWERS_TO_LAUNCH`, resolving Codex spawn parameters with `scripts/spawn-adapter spawn <reviewer-name>`. In **wave mode**, restrict this section to `[WAVE]` — the first up-to-`REVIEWER_SLOTS` reviewers in `[AGENTS]` not yet in `review_wave_done` — and reset the tracking on entry from § 2.1 (skip the reset when re-entering from § 3.2 for the next wave of the same cycle):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] review_wave_done '[]'
```

A retired reviewer has no session to reuse: recreate it fresh and write state with the live wave only. If a spawn fails with the runtime's thread-limit error, do not retry it and do not tear down the reviewers that did spawn — continue with those, fold the failed reviewer into a later wave, and use that smaller size for the rest of the cycle. Record the demotion in one write:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.reviewer_slots_observed = [OBSERVED_SPAWN_COUNT] | .review_wave_done = []'
```

Then tell the user once: `Runtime capped concurrent agent sessions — set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in vstack.settings.toml [env]`, where `[OBSERVED_BUDGET]` is successful spawns + this session + live dev/QA sessions. If nothing spawned at all, report the misconfiguration and stop.

Store the active set:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON] | .review_agent_ids = [AGENT_ID_MAP_JSON] | .review_agent_runtime_types = [AGENT_RUNTIME_TYPE_MAP_JSON]'
```

Stamp the freshness boundary immediately before the delegation batch — it gates § 3.1 acceptance against stale artifacts. In wave mode, re-stamp before each wave's batch:

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at
```

Delegate to every reviewer in the active set in parallel. When `EXTERNAL_REVIEW_REQUESTED=true`, launch the external review in the same batch — a shell command, not an agent session: it consumes no slot and joins only the cycle's first wave.

Mint each reviewer's artifact path immediately before its delegation — one command per reviewer, its output filling `[ARTIFACT_PATH]`:

```bash
.agents/skills/orch/scripts/review-artifact-check --path [WORKTREE_PATH] [AGENT]
```

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WORKTREE_PATH]
Branch: [BRANCH]
Artifact: [ARTIFACT_PATH]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
<if re-review cycle>
Re-review cycle [N]. Already resolved — do NOT re-report:
- Fixed: [For each fixed_item: "[DESCRIPTION] — fixed in [COMMIT_SHA]"]
- Escalated: [For each escalated_item: "[DESCRIPTION] — [REASON]"]
</if>
<if this reviewer session was recreated fresh>
Fresh session — you have no memory of earlier cycles. Read your prior report [PRIOR_REPORT_PATH] and re-read the current diff before reviewing.
</if>
</delegation_format>

`[PRIOR_REPORT_PATH]` is that reviewer's most recent `review-[AGENT]-*.json` from state `json_paths`.

**External review** (only when requested; default timeout `SECOND_OPINION_TIMEOUT` or 300s):

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-external-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json
```

Validate it like a reviewer JSON, with `review_delegated_at` as the freshness boundary:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```

`ok == true` → append the path to `json_paths`. `ok == false`, or any non-zero exit, → report the `reason` (and `detail` when present) and continue: external review is advisory, never blocking, and never substitutes a pass.

## 3. Collect Results

**Persistent mode**: keep reviewers alive for § 4. **Wave mode**: retire each reviewer as its artifact validates, freeing the slot for the next wave.

### 3.1 Completion

`OUTSTANDING` is the active set plus `{external}` when requested. A reviewer completes **only** when its on-disk artifact validates — a return message carrying `Verdict:`/`File:` is never sufficient:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .review_delegated_at
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]
```

Run it on every return message and every watchdog sweep. `ok == true` → drop the agent from `OUTSTANDING` and append its path:

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

Sweep the filesystem on every event — it catches silent finishers. Per-agent deadline from `review_delegated_at`: 25 minutes for an agent whose name contains `perf`, 15 minutes for everyone else including external.

| Event | Action |
|-------|--------|
| Return arrives | Run `review-artifact-check` (§ 3.1) |
| 2 min after the first return, or 10 min from delegation with no returns — once per cycle (wave mode: per wave) | Ping each outstanding agent once: `Status check on [ISSUE_ID] review — return your verdict if complete, or report the blocker.` |
| 2 min after that ping | Mark each non-perf agent still outstanding `unresponsive` |
| Per-agent deadline | Mark that agent `unresponsive` |

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

Omit empty categories. Decline any item that cannot affect real usage with one line of rationale here, per [SKILL.md § The Cycle](../SKILL.md#the-cycle) — it is neither fixed nor filed, and it is reported in § 8.

**Disposition is by rule, not by prompt** — never present a selection menu over the findings. Every blocker and `category == "fix"` suggestion that survives declining goes to the fix round below, in EVERY decision mode: which findings to fix is a mechanics question the rule settles, so `ORCH_DECISION_MODE` does not gate it. The always-ask set in [SKILL.md § The Cycle](../SKILL.md#the-cycle) is unaffected and still applies. Nothing left after declines → § 5.

### Fix Delegation

Never fix as the main agent.

```bash
.agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
```

**Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4 re-review` with context `worktree`, `lifecycle: "managed"`, `dev_agent`, `issue_id`, `items` (every blocker plus every `category == "fix"` suggestion that survived declining, each formatted `#[N] | [Agent] | [Location]` with Description and Recommendation), `source: pr-review`.

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

**The loop ends** when two consecutive cycles surface no new blocker, or when `cycles` reaches 4. The cap bounds NEW cycles, never verification: a fix diff no reviewer has seen gets one focused verification pass — the `rereview_panel` rule above (blocker finders + the domains the fix touched + external), scoped to exactly that diff — before § 5, cap or no cap. At the cap, report the outstanding items after that pass and proceed to § 5 rather than looping. In wave mode the panel replaces `[AGENTS]` for the cycle and wave mechanics apply unchanged.

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

   `[BASE_BRANCH]` is the § 1 `resolve-base-branch` output. `-G` matches added and removed lines only, and `--quiet` turns the answer into the exit code: **1** means a matching change exists and adds `needs-safety-audit`, **0** means no signal. Any other exit is an error. When the repo sets `QA_PERF_PATHS` (space-separated path globs), any changed file matching one adds `needs-perf-test`:

```bash
.agents/skills/orch/scripts/orch-env QA_PERF_PATHS ""
```

3. **Judgment** — you may add or drop a signal with one line of rationale; record it:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] qa_decision '{"signals":[SIGNALS],"rationale":"[ONE_LINE]"}'
```

QA passes are expensive: drop a signal when the triggering code is trivial or test-only; never drop one for schedule pressure. `skip_qa` true → set it false, record `qa_decision` with rationale "user skip", → § 8. Signals empty → § 8. Otherwise → § 6.

## 6. QA Checks

**Skip if** the recorded `qa_decision.signals` is empty → § 8.

Map each signal to its agent — `needs-safety-audit` → `reviewer-safety`, `needs-perf-test` → `reviewer-perf`, `needs-review` → `reviewer-correctness`; a project may override the mapping in its instructions. For each, delegate and wait:

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/qa-review.md

Issue: [ISSUE_ID]
Tracker: [TRACKER] [OWNER/REPO]
Branch: [BRANCH]
Worktree: [WORKTREE_PATH]
Trigger: [QA signal]

Dev summary:
[completion summary from the dev return, or a description of the branch changes]

Previous review cycle context (cycle [CYCLES]):
- Fixed since last review: [For each fixed_item with source "qa-review": "[DESCRIPTION] — fixed in [COMMIT_SHA]"]
- Escalated (accepted): [For each escalated_item with source "qa-review": "[DESCRIPTION] — [REASON]"]
- Do NOT re-report fixed or escalated items. Report only new issues or regressions the fixes introduced.
</delegation_format>

Omit `[OWNER/REPO]` when `TRACKER=linear`. On return, append the artifact path to `json_paths`; when the agent reports a `benchmark_commit` other than `none`, confirm it resolves with `git -C [WORKTREE_PATH] log -1 --oneline [SHA]`. A performance QA agent's `qa_metadata.perf_qa` block is posted as an issue comment — Linear via `linear.sh comments create [ISSUE_ID] --body-file`, GitHub via `gh issue comment ${ISSUE_ID#issue-} --body-file` — written to a file first, since benchmark tables carry backticks.

A `pass` verdict continues to the next QA agent; `action_required` goes to § 7. After all QA agents complete, remaining `category == "fix"` items not already in `fixed_items` or `escalated_items` also go to § 7; otherwise → § 8.

## 7. Handle QA Items

**Skip if** every QA verdict is `pass` and no fix suggestions remain → § 8.

Follow the § 4 pattern — collect, present, delegate through `workflows/dev-fix.md`, by rule and with no selection prompt — with these overrides: items come from the QA JSONs excluding anything already fixed or escalated; the table header is `QA Agent` and the title `QA Review Items — [ISSUE_ID]`; `source` is `qa-review` and `qa_agent` carries the agent name. After the fix round, apply the § 4 bounded re-review rule with § 6 as the target instead of § 2 — a focused QA re-check, not a full PR review — unless the round's diff reaches beyond QA's own surface, which returns to § 2.

## 8. Summary And Issue Audit

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), fixed: (.fixed_items // []), escalated: (.escalated_items // [])}'
```

Empty `json_paths` → report "No review items" and → § 9.

Read every JSON, collect the `category == "issue"` suggestions, and deduplicate by (location, description), keeping the first and noting all sources.

**Declined items are re-derived, not remembered.** A blocker or `category == "fix"` suggestion that appears in a `json_paths` artifact but in neither `fixed_items` nor `escalated_items` was declined in § 4 or § 7. Carry each one's recorded rationale; where a compaction lost it, report the item with `rationale: not recorded` rather than inventing one.

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

| # | Source | Location | Description | Rationale |
|---|--------|----------|-------------|-----------|
| 1 | [agent] | [location] | [description] | [one line] |

### 📊 QA METRICS

[Per QA agent, the results its JSON `qa_metadata` returned — project-configurable.]

---
Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4
Est: 1 (hours) | 2 (half-day) | 3 (day) | 4 (2-3d) | 5 (week+)

</output_format>

Omit empty sections.

**File only what clears the bar.** Apply [references/finding-disposition.md](../references/finding-disposition.md) § Filing bar to every candidate: `category: "issue"` suggestions, escalated items, and Discovered Work bullets from the dev return. Everything below the bar is absorbed or dropped with a one-line note — filing is not the default.

Discovered Work bullets whose first token after `- ` is `handoff_to_submit_pr:`, `handoff_to_merge_pr:`, or `current_workflow_action:` are already in flight in this workflow — match `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` and drop them silently. The filter applies to Discovered Work only; escalated items and `category: "issue"` suggestions are unaffected.

Nothing clears the bar → § 9. Otherwise build the audit-input file per `.agents/skills/project-management/schemas/audit-issues-input.md` at `[WORKTREE_PATH]/tmp/audit-start-YYYYMMDD-HHMMSS.json`. Each escalated item's `origin` comes from its `outcome`: `"skipped"` → `origin: "skipped"`; `"blocked"` or no `outcome` field → `origin: "escalated"`. Set `tracker.type` to the resolved `TRACKER`, plus `tracker.repository` for GitHub items.

**Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 8 tail`. audit-issues is a primary-session wrapper holding the interactive approval gate: run it in this session, never delegated to a subagent; the only delegable part is the `tpm-audit.md` analysis, which audit-issues spawns itself.

Record each created issue:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] audit_issues_created "[CREATED_ISSUE_ID]"
```

**Children created to be worked here** (Linear only). When the audit created `make_child` issues under `[ISSUE_ID]`, delegate them immediately via `⤵ workflows/dev-start.md § 1-4` with context `worktree`, `lifecycle`: inherit, `issue_id`, and `audit_bundle: true` (the single-PR opt-in for dev-start's container guard). If delegation is skipped, FIRST detach every `audit_issues_created` entry from `[ISSUE_ID]` — otherwise `merge-pr.md` cascade-Dones them:

```bash
.agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --remove-parent
.agents/skills/linear/scripts/linear.sh issues add-relation [CHILD_ID] --related [ISSUE_ID]
```

After delegating children, apply the § 4 bounded re-review rule to their diff.

## 9. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete — the summary is in § 8.
