# PR Review Workflow

Review a branch before submission. Run the reviewer panel, delegate bounded fix rounds, run QA, and file what the review leaves. `review-pr [PR_NUMBER]` reviews that pull request's worktree. [start-worktree.md](start-worktree.md) § 3 runs it managed.

When [start-worktree.md](start-worktree.md) § 2.1 opened the pull request early, this review runs on the pushed head. Its fix rounds stay local until submit-pr pushes them. Under `push-first`, start-worktree.md § 2.1's first-head review call, run with `[MARK_READY]` `true`, marks the pull request ready.

**Caller context** (via `⤵`):

- `worktree`.
- `agents`: an explicit reviewer panel. The default is the first-cycle panel § 2 selects.
- `lifecycle`: `"managed"` (return at § 9) or `"self"` (default).
- `dev_agent`: a live dev agent for fix rounds.
- `issue_id`: the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

Worktree resolution:

- **With a PR number.** `.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text` prints `ISSUE`. Apply [Worktree Scope](../SKILL.md#workflow-execution), and ask before `worktree create [ISSUE] --pr [PR_NUMBER]`.
- With no argument, `WT_PATH` is `git-context repo-root .`.
- Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`, where `[DIR]` is the checkout `WT_PATH` resolves from.

**Standalone init** (`lifecycle: "self"`):

1. Resolve `ISSUE_ID` with `git-context issue-from-branch .`, and resolve `TRACKER` ([Tracker Resolution](../SKILL.md#tracker-resolution)).
2. Run `.agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]`.
3. When the state is absent, read `[BRANCH]` with `git-context branch [WT_PATH]`, then run `.agents/skills/orch/scripts/orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]`.
4. This path has no dev return, so § 5 derives the QA signals from the diff scan and your judgment alone.

---

## 1. Identify Changes

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] status --porcelain
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

1. A non-empty `status --porcelain` stops the review.
   - Managed with a `dev_agent`: re-delegate the commit or revert of the leftovers, then re-enter § 1.
   - Standalone: report the dirty files. Ask the user to commit, revert, or run `orch review all` for an ad-hoc review of uncommitted work.
2. No committed diff: report "No committed changes to review" and **END**.
3. **Review line.** In a lane whose brief names a status file, while workflow state `pr_order` reads `open-first` or `push-first`, write `Review: pending PR #[PR_NUMBER]` to that file before any reviewer starts. Read the number here. A read that prints no number writes no line:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] --json number,state
   ```

   [submit-pr.md](submit-pr.md) § 2 step 1 replaces the line once the push carrying this review's fix rounds lands.

4. **Review depth.** Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing). Read the floor a route promised this run, which [micro.md § Escape](micro.md#escape) records:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /review_floor
   ```

   A read that exits 0 with the field unset binds `[REVIEW_FLOOR]` to `micro`. A nonzero exit runs the full review. Otherwise run the base checkout's command against the worktree:

   ```bash
   "[REVIEW_BASE_CHECKOUT]/.agents/skills/reviewer/scripts/review-depth" --base origin/[BASE_BRANCH] --head HEAD --repo [WORKTREE_PATH] --floor "[REVIEW_FLOOR]"
   ```

   The command's `--help` owns the class-to-depth mapping and the floor.

   - `review_depth=none` goes to § 9 with verdict `pass`.
   - `bot` or `full` runs this review, under [small.md § 3](small.md#3-review) when small.md is the caller.
   - A nonzero exit runs the full review.
   - The depth selects package review only. Every depth keeps the native approval and thread requirements that publication checks.

### 1.1 Decision Context

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
.agents/skills/decider/scripts/decisions search "[KEYWORDS_OF_THE_CHANGED_AREA]"
```

1. The `path` fields in that JSON are the only source of decision file paths. Never compose or recall one.
2. Read each full record, and apply [decider's status meanings](../../decider/SKILL.md#decider) before you use it as policy.
3. Verify each path, one command per path:

   ```bash
   test -f [DECISION_FILE_PATH]
   ```

4. A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

### 1.2 Re-Review Context

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {cycles: (.cycles // 0), fixed_items: (.fixed_items // []), escalated_items: (.escalated_items // []), declined_items: (.declined_items // [])}' <<<"$STATE_READ"
```

With `cycles > 0`, fill the delegation's re-review block from `fixed_items`, `escalated_items` and `declined_items`.

## 2. Prepare Reviewers

**Pre-panel admission.** Before you size or start attached reviewers, ask the runtime whether this session has room for their returns. Run it from `[WORKTREE_PATH]`:

```bash
.agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --attached-launch
```

- In a lane, the command reads the session and transcript bound to its pane.
- Outside a lane, pass the harness name and this session's native ID and transcript path as one JSON object on stdin. Copilot requires the session ID and can read its session record without a transcript path.

```bash
jq -cn --arg harness "[HARNESS]" --arg session_id "[SESSION_ID]" --arg transcript_path "[TRANSCRIPT_PATH]" '{harness: $harness, session_id: $session_id, transcript_path: $transcript_path}' |
  .agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --attached-launch
```

Route on the reply's `verdict`:

- `room`: size and start the attached panel below.
- `alternate-review`: Codex only: the attached-agent reserve refuses, while the plain mark has room.
  1. Keep the full required panel and run its required domains as process-owned Codex reviewers through [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers).
  2. Skip attached slot sizing, thread selection and spawn; keep panel selection, the existing-assignment reads and § 2.1.
  3. This verdict permits no attached launch and no advisory replacement.
- `due`: take the parent handoff below.
- A refusal at exit 2:
  1. Start no attached panel. Report the stderr line.
  2. If the harness cannot supply the named session input or is unsupported, ask the user to resume the review in a supported session that supplies it.
  3. Otherwise repair the cause before re-entering § 2.

**Handoff on `due`.** The session is past its plain mark, compacted, or cannot prove room for the returns.

1. Keep the returned `decision` and `source` as the handoff's `context`. An unavailable decision stays unknown. Set `REVIEWER_SLOTS=0`.
2. Bind `git -C [WORKTREE_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`.
3. Checkpoint the committed head through the branch-publication owner. Write `[WORKTREE_PATH]/tmp/checkpoint-push-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "checkpoint", "worktree": "[WORKTREE_PATH]", "args": ["--set-upstream"]}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/checkpoint-push-[ISSUE_ID].json
   ```

   Route its exit and reply as [merge-pr-restack.md](merge-pr-restack.md) step 3 routes the branch push.

4. Compare HEAD with `[BOUND_HEAD]`. If it moved, apply [Rules reload after a rebase](../SKILL.md#the-cycle) at once, after a failed transport too.
5. A failed checkpoint starts no panel and records no publication.
6. Record the published head in the handoff under [oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out).
7. Before retirement, collect the attached and external returns already available through § 3's checks.
   - Record every other return as unread, with only its known assignment, job, output path, wake, deadline and survival facts.
   - An unknown external outcome or liveness stays unread. Invent no wait target or result, and launch no duplicate job.
   - Preserve each process-owned assignment with its exact job directory, runner record, exit, log and artifact paths, deadline and known survival facts. Its existing job and artifact owners collect it on recovery.
8. Base delivery waits for the successor's completed review.
9. The successor re-enters § 2's admission, then applies the continuation rule below.

**Original-batch continuation.**

1. Before handoff, copy the owning workflow's known assignment facts into the handoff's existing `remaining` and `traps` prose: item, worktree, branch and pull request; published and reviewed head; concrete range endpoints; full required panel and reason; external request; the original `review_round_id` and `review_delegated_at`; each assigned canonical domain's exact artifact path and accepted or attempted disposition; the domains never launched; actual first-delegation times, deadlines, ping and re-delegation history, and existing return and wake owners. Keep the handoff's fixed shape with the admission's `context`, and add no state key.
2. On resume, prove that the copied facts describe the same original batch, an unchanged published and current head, and the same concrete scope.
   - `json_paths` and `review_wave_done` alone prove no assignment or acceptance.
   - Missing provenance, a different current batch, or a changed head or scope means no reuse. Then keep the historical evidence and run an ordinary fresh review under admission.
   - Never rebuild a range from today's symbolic base, and never attach today's round token to an old report.
3. A proved continuation keeps its original `review_round_id`, stage and `review_delegated_at` throughout, § 3.1's exact-file rechecks included.
4. Revalidate through § 3.1 only the exact previously accepted files assigned to this batch.
   - Keep the full required `[AGENTS]` panel apart from the launch subset.
   - Subtract revalidated accepted domains from delegation only, and carry their findings, repeats and measurement declarations into normal handling.
5. An attempted domain keeps its job owner, deadlines, rejection and re-delegation history and execution outcome.
   - It gets no duplicate launch and no restarted allowance.
   - A resolved `unresponsive` domain stays unresponsive, never accepted.
   - Only unread domains proved never launched enter the launch subset.
6. If the preserved facts or admission cannot support this route, stop and report the exact limitation.
7. A handoff resets no counter, validation receipt, finding, disposition or failure history, and starts no validation replay of an unchanged tree.

**Panel.** `[AGENTS]` is the caller's `agents` when given. Otherwise it is the first-cycle panel: the reviewers this harness exposes whose domains the whole diff, `origin/[BASE_BRANCH]...HEAD`, or the issue's Done-when touches, by [§ Bounded Re-Review](#bounded-re-review)'s scoped-panel rule.

1. Read the Done-when first: `linear.sh issues get [ISSUE_ID]` `.description` for Linear, `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body` for GitHub. A failed read, or a `pr-N` key, selects from the diff alone, and `[PANEL_REASON]` says so.
2. Never hardcode a count or a list.
3. Where the harness exposes `reviewer-error`, a diff that owns a subprocess, a transport (stream, socket, SSE) or a teardown path always carries it.
4. With no reviewer available, go to § 5 with verdict `pass`.
5. `[PANEL_REASON]` names the domains touched, or reads `caller panel` for a caller's `agents`. § 2.1 records the panel.
6. A proved continuation keeps its original panel.

**Reviewer slots** (attached review only). Resolve the reviewer mode per [skill-rules.md § Agent Lifecycle](../references/skill-rules.md#agent-lifecycle):

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

Read the slots the open child sessions hold:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"slots"}'
```

The reply's `live` counts the open child sessions that still hold a slot. `observed` is the wave size an earlier thread-limit error proved.

- **Codex MultiAgentV2.**
  1. Apply [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse), whose **Budget** reads `effective_cap` and the held threads.
  2. `REVIEWER_SLOTS` is the eligible finished reviewer threads plus `max(0, effective_cap - held threads)`.
  3. Bound the wave by a positive `observed` and by a nonzero budget after the primary and other active work.
  4. A zero-sized wave takes Codex thread reuse's held-thread wait.
- **Every other surface.**
  1. A positive `observed` is wave mode at that size.
  2. Otherwise a budget of `0` is persistent mode, and a positive budget gives `REVIEWER_SLOTS` by [skill-rules.md § Reviewer persistence is budget-conditional](../references/skill-rules.md#reviewer-persistence-is-budget-conditional) step 3.
- Use wave mode when `[AGENTS]` exceeds `REVIEWER_SLOTS`; otherwise persistent mode.
- Recompute at every § 2 entry.

**Existing reviewers.** Read the stored reviewer state before any spawn:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {review_agents: (.review_agents // []), review_agent_ids: (.review_agent_ids // {}), review_agent_runtime_types: (.review_agent_runtime_types // {})}' <<<"$STATE_READ"
```

1. For attached review, classify each reviewer in `[AGENTS]` as reusable, context-exhausted, missing, closed or confirmed-stuck. On a proved continuation, classify only its launch subset and keep the attempted assignments for § 3.
2. Reuse a live ID only under [Delegation](../references/skill-rules.md#delegation) for the target worktree, after a name-only resume too.
3. On Codex, retire and reuse under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
4. Add the context-exhausted, missing, closed and confirmed-stuck reviewers to `REVIEWERS_TO_LAUNCH`.
5. Carry a reusable reviewer's runtime-type entry forward.
6. On a re-review whose panel shrank (§ Bounded Re-Review scopes it), retire the reviewers outside the panel first.
7. For `alternate-review`, read the process ownership facts in the lane status and the handoff's `remaining` and `traps` prose. Keep accepted and attempted assignments, attached work included, and select only never-launched required domains for process launch.
8. Spawn nothing yet: resolve § 2.1 first.

### 2.1 External Review Availability

- External review runs beside the internal panel when the consumer's policy chooses it. It runs like an internal reviewer, with no user prompt.
- A proved continuation keeps the original external request and its return owner: skip this section and collect it through § 3.
- An unknown outcome or liveness stays unread, and nothing replaces it.

1. Read the policy from the consumer's base checkout:

   ```bash
   .agents/skills/orch/scripts/orch-runtime validate policy --base-checkout [REVIEW_BASE_CHECKOUT] --stage external-review
   ```

   - `result.answer` `skip` sets `EXTERNAL_REVIEW_REQUESTED=false`.
   - A nonzero exit reports its keyed line and sets it false.
   - On `run`, continue.

2. When `.agents/skills/second-opinion/scripts/second-opinion` is absent, report in one line that the chosen external review has no installed tool. Set `EXTERNAL_REVIEW_REQUESTED=false` and continue.
3. Detect the available targets:

   ```bash
   .agents/skills/second-opinion/scripts/second-opinion detect
   ```

   - A failure, `none` or empty output sets `EXTERNAL_REVIEW_REQUESTED=false`.
   - Anything else sets it `true`. The output signals availability only; the review runs without `--target`.
   - On `none`, the error JSON's `candidates` carry a reason per target. Tell the user once, `External review skipped — [CANDIDATE_REASONS]. Fix: [FIX]`, where `[FIX]` is each reason's remedy in the second-opinion skill's SKILL.md § Error Handling.

4. **Record the panel** on a fresh § 1 entry, before any spawn, with `external` set to `EXTERNAL_REVIEW_REQUESTED`. A `small` item's panel holds three reviewers at most, the external lane counted:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-panel","panel":"first","agents":[PANEL_AGENTS_JSON],"reason":"[PANEL_REASON]","external":[EXTERNAL_REVIEW_REQUESTED]}'
   ```

### 2.2 Launch And Delegate

**Round token.**

- A fresh batch mints its review round before its first spawn or process launch.
- A proved continuation keeps its original `review_round_id` and `review_delegated_at` and mints nothing.
- Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "review"}`, run it, then stamp the delegation time:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"review"}'
```

`[REVIEW_ROUND_ID]` is the first reply's `.result.report.round_id`. The write opens a new review stage ([workflow-state.md](../schemas/workflow-state.md) `stages`), which § 3.3 closes. These two writes are this batch's admission under [Record verified findings](../schemas/workflow-state.md#record-verified-findings), with state writes enabled. § 3.1 is its acceptance; § 4 is its disposition and completion.

**Scope.**

1. On a fresh § 1 entry, resolve `origin/[BASE_BRANCH]` and `HEAD` to commit SHAs.
2. On a § 4 or § 7 re-entry, resolve the stored `pre_delegate_sha` and the current `HEAD`.
3. Bind `[DIFF_RANGE]` to the concrete `[BASE_SHA]...[HEAD_SHA]` and pass it to internal and external review alike.
4. A missing fix boundary sends `unavailable` internally and the external default.
5. A proved continuation keeps its resolved endpoints.

**Attached launch.**

1. In wave mode, `[WAVE]` is the first `REVIEWER_SLOTS` reviewers in `[AGENTS]` not yet in `review_wave_done`. Launch only those. A continuation selects its wave only from its never-launched launch subset and keeps the full required panel.
2. On a fresh entry from § 2.1, reset the wave record. Skip the reset on a proved continuation, and when § 3.2 returns here for the next wave of the same cycle:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"wave-start"}'
   ```

3. Select an eligible finished thread or spawn each reviewer in `REVIEWERS_TO_LAUNCH` under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
   - On Codex, spawn each canonical reviewer name by [codex-runtime.md § Spawning Codex collaboration agents](../references/codex-runtime.md#spawning-codex-collaboration-agents), and reuse an eligible finished reviewer thread with the complete delegation below.
4. When a spawn fails with the runtime's thread-limit error:
   - Do not retry it, and do not tear down the reviewers that spawned.
   - Continue with those, fold the failed reviewer into a later wave, and use that smaller size for the rest of the cycle.
   - Record it in one write. On Codex, `[OBSERVED_SPAWN_COUNT]` counts assigned reusable threads as well as fresh spawns. The write keeps `review_wave_done` on every wave:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"wave-start","slots_observed":[OBSERVED_SPAWN_COUNT]}'
   ```

   Then tell the user once: `Runtime capped concurrent agent sessions — set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in kendex.settings.toml [env]`. On Codex, `[OBSERVED_BUDGET]` is the `effective_cap` that `subagent room` reported. Elsewhere it is the successful spawns, plus this session, plus the `slots` reply's `live`.

5. When nothing spawned:
   - On Codex, an empty fresh-spawn set first takes Codex thread reuse's eligible-thread and held-thread wave routes. Report the cap blocker that rule names only when neither can run the work.
   - On every other surface, nothing spawned is a misconfiguration: report it and stop.
6. Store the active set under canonical reviewer names. A continuation includes its kept attempted and live assignments with their IDs and runtime types:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"active","agents":[AGENT_LIST_JSON],"ids":[AGENT_ID_MAP_JSON],"runtime_types":[AGENT_RUNTIME_TYPE_MAP_JSON]}'
   ```

**Both execution paths.**

1. On `alternate-review`, every never-launched required domain starts in the same wave, each through its own [Process launch admission](#process-launch-admission). No domain waits for another to start.
2. Keep the complete required panel and every earlier assignment.
3. Record in the lane status and ownership prose each process's exact job directory, runner, exit, log and artifact paths, actual first-delegation time, deadline, and rejection and re-delegation history.
4. Store the canonical active domains in `review_agents`. A process has no entry in `review_agent_ids` or `review_agent_runtime_types`, and no process number goes in either map.
5. Keep `review_wave_done`, the original `review_round_id`, `review_delegated_at` and the concrete scope across process waves and continuations. Reset them only for a fresh batch.
6. A live assignment never gets a second job.
7. A missing runner, CLI, native source or launch selection stops this route: report the exact cause to the caller.

**Delegate.**

1. Mint each reviewer's artifact path immediately before its delegation, one command per reviewer, its output filling `[ARTIFACT_PATH]`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime review-artifact --text path --worktree [WORKTREE_PATH] --agent [AGENT]
   ```

2. On Codex, prepare each complete `DELEGATION:` message under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
3. For attached review, delegate to every reviewer selected for launch in parallel, once admission gave room.
4. For process-owned review, put the same complete role, workflow and delegation in the prompt file [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers) names. Pass each launch through [Process launch admission](#process-launch-admission). Call no collaboration spawn or follow-up for a process assignment.
5. When `EXTERNAL_REVIEW_REQUESTED=true` on a fresh batch, start the external review in the same batch (below). It is a shell command, not an agent session. It takes no slot and joins only the cycle's first wave.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WORKTREE_PATH]
Branch: [BRANCH]
Artifact: [ARTIFACT_PATH]
Diff-range: [DIFF_RANGE, or unavailable for a missing fix boundary]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
<if re-review cycle>
Re-review cycle [N]. Already resolved — do NOT re-report the entries listed below, unless you check a Fixed entry against the current diff and the defect is still there: report that one again, copying that entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha, so the stale entry can be superseded. A Fixed entry you did not check, and every Escalated and Declined entry, stays suppressed.
- Fixed: [For each fixed_item: "[LOCATION] | [DESCRIPTION] — fixed in [COMMIT_SHA]"; an entry whose commit is a `dropped:<sha>` marker prints "recorded, then dropped in a rebase" in place of the sha]
- Escalated: [For each escalated_item: "[LOCATION] | [DESCRIPTION] — [REASON]"]
- Declined: [For each declined_item: "[LOCATION] | [DESCRIPTION] — [REASON]"]
</if>
<if this reviewer session was recreated fresh>
Fresh session — you have no memory of earlier cycles. Read your prior report [PRIOR_REPORT_PATH] and re-read the current diff before reviewing.
</if>
</delegation_format>

`[PRIOR_REPORT_PATH]` is that reviewer's most recent `review-[AGENT]-*.json` in state `json_paths`.

**External review** (only when requested). `[RANGE_FLAG]` is `--range [DIFF_RANGE]`, with the endpoints sent internally. Only a missing fix boundary leaves it empty, which takes the script's `origin/BASE...HEAD` default. The command backgrounds itself and prints when to check:

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-external-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json --foreground [RANGE_FLAG]
```

1. Run the exact command printed after `wait:`, and repeat it by its exit code (`second-opinion --help`) until it ends.
2. Handle other reviewer events in between.
3. Then validate its artifact like a reviewer's, with `review_delegated_at` as the boundary. § 3.1's sweep also covers a silent finisher:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /review_delegated_at
   .agents/skills/orch/scripts/orch-runtime review-artifact --text check --file "$EXTERNAL_OUTPUT" --worktree [WORKTREE_PATH] --delegated-at [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND] --issue [ISSUE_ID]
   ```

- `ok == true`: append the path to `json_paths` (§ 3.1's write) and carry its `repeats` to § 4.
- `reason == "valid_undermeasured"`: report its `measurement_failed` string, and `measurement_suppressed` when present, beside the path. Never present the external pass as clean.
- `ok == false`, `moving_tree` included, or any nonzero exit: report the `reason`, and `detail` when present, and continue. External review is advisory. It never blocks and never stands in for a pass.
- A detached run that already exited nonzero, or an artifact that does not validate, resolves at once as `external: failed — [REASON]` and leaves `OUTSTANDING`.

### Process launch admission

Every process-owned launch enters here immediately before its runtime launch command. That covers an initial, later or continuation wave, and the one replacement § 3.1 allows. Run it from the worktree:

```bash
.agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --checkpoint
```

1. Only `room` launches the selected process through codex-runtime.md.
2. `due` takes § 2's handoff with this latest `decision` and `source`, and starts no process.
3. A refusal starts nothing and reports its cause. A denied launch keeps a never-launched domain unlaunched and starts no clock.
4. Re-entering admission starts no fresh batch and repeats no external detection. Keep the full panel, the exact assignment, the concrete head and range, the original token and evidence boundary, the accepted-file rechecks and the spent allowances.
5. Record an actual first delegation only once the runner confirms the job started. A replacement keeps its original clock and rejection boundary.

## 3. Collect Results

- **Persistent mode** keeps reviewers alive for § 4.
- **Wave mode** retires each reviewer once its artifact validates, which frees the slot for the next wave.
- A process-owned reviewer follows the job lifetime in [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers). Its accepted artifact does not retire a running process, and its domain's next launch waits for the recorded terminal outcome.

### 3.1 Completion

- `OUTSTANDING` is the active set, plus `{external}` when requested, less the returns already accepted and the execution outcomes already resolved here.
- On a continuation, every required domain stays accounted for: accepted, attempted and unread, never launched and unread, or unresponsive.
- An unread domain holds collection until its acceptance or deadline route resolves it.

A reviewer completes only when its on-disk artifact validates:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /review_delegated_at
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --worktree [WORKTREE_PATH] --agent [AGENT] --delegated-at [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND] --issue [ISSUE_ID]
```

Run it on every return message and every watchdog sweep.

- `ok == true`: drop the agent from `OUTSTANDING`, carry the result's `repeats` to § 4, and append the path:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","artifact":"[PATH]"}'
  ```

  Wave mode records the wave return in the same write, then shuts that reviewer's session down:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","artifact":"[PATH]","agent":"[AGENT]"}'
  ```

- `reason == "valid_undermeasured"`: carry the `measurement_failed` string into the review summary beside that verdict, with `measurement_suppressed` when present. Never present the domain as clean.

**Process-owned completion.**

1. Collect every process return, the first included, with codex-runtime.md's process collection command. It reads the recorded job exit before the exact assigned-file check.
2. Read the job log beside the result.
3. An empty exit file is unfinished, never a return.
4. A nonzero exit or confirmed interruption supplies no accepted review, even when a JSON file exists. Keep its evidence unread, take the incomplete-return and deadline rules below, and never substitute an external opinion.
5. A zero exit still needs the exact assigned artifact to validate. The last-message file alone supplies no acceptance.

**Continuation.** A proved continuation checks the preserved assigned path, under the original token, stage and evidence boundary:

```bash
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --file [ASSIGNED_ARTIFACT_PATH] --worktree [WORKTREE_PATH] --delegated-at [ORIGINAL_REVIEW_DELEGATED_AT] --issue [ISSUE_ID]
```

1. Match `artifact.agent` to the preserved canonical assignment and the required panel.
2. Reuse only an `ok == true` result. Missing, invalid, stale, `no_review` or `moving_tree` evidence supplies no completion.
3. A failed recheck of an accepted file ends reuse. Run an ordinary fresh review, and keep the rejection and its history.
4. Never select a sibling file, touch an old file, lower or omit the boundary, or mint a receipt. An unfinished assigned return keeps any stricter rejection boundary § 3.2 requires, and the batch boundary does not move.
5. A path already recorded as accepted appends no second entry. Carry its findings, repeats and `valid_undermeasured` declarations through the handling above.

**Incomplete returns.**

- **Attached.**
  1. `ok == false` after a return, `moving_tree` included, makes the return incomplete, whatever its `File:` path or message says.
  2. Send that agent exactly one re-delegation. A continuation keeps an already spent re-delegation, and names its exact assigned path in place of a new timestamped path. A `moving_tree` refusal needs a new review from a new starting snapshot once development finishes:

     > Your review return is incomplete: `orch-runtime review-artifact check` reports `[reason]`[ — `[detail]`] for `[WORKTREE_PATH]/tmp/review-[AGENT]-*.json`. Write your full review JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` using your harness file-write tool (not shell redirection), following every required field of `review-finding.md`, then return `Verdict:` and `File:` again.

  3. Still `ok == false` after that, or the § 3.2 deadline reached: mark the agent `unresponsive`. Never re-delegate a second time.

- **Process-owned.**
  1. A terminal failure or a rejected artifact is incomplete.
  2. Its one re-delegation passes through [Process launch admission](#process-launch-admission).
  3. It starts a fresh job only once the previous process is terminal, with the same canonical role and complete delegation, the exact assigned artifact and § 3.2's rejection boundary.
  4. It returns here as the same attempted assignment, never a never-launched domain. It keeps the original first-delegation time, deadline and spent allowance.
  5. A process has no message channel: record that limit in place of a ping.
  6. A failed replacement or an exhausted deadline marks the domain `unresponsive`.

### 3.2 Watchdog

**Keep a wake source armed for every incomplete agent.** Arm one check per agent:

```bash
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --worktree [WORKTREE_PATH] --agent [AGENT] --delegated-at [REVIEW_DELEGATED_AT] --wait [SECS] --issue [ISSUE_ID]
```

1. Run it where its exit wakes this session: [artifact-checks.md § Round-closure mechanics](../references/artifact-checks.md#round-closure-mechanics) names the route per harness. On Codex, use [codex-runtime.md § Reviewer round wait](../references/codex-runtime.md#reviewer-round-wait) and hold every completion in the current turn.
2. `[SECS]` ends at the earliest pending row of the table below, or at the agent's deadline when no earlier row remains. The external lane uses § 2.2's `wait:` command.
3. Arm with the delegation batch and re-arm after every action, a ping included. A promised completion extends nothing until re-armed.
4. After an artifact rejection (§ 3.1), set `[REVIEW_DELEGATED_AT]` strictly above the rejected artifact's modification time. On a continuation this is a stricter boundary for that assignment's check alone, never a write to the batch boundary. The glob watchdog only wakes the session. § 3.1's exact assigned-file check decides continuation acceptance.

**Replace a wake source that ends without a verdict, once, at once.**

- A verdict prints on stdout at exit 0 (accepted) or 1 (rejected).
- A keyed refusal exits 2 with its `review-artifact:` line on stderr. That, or any other status, leaves the agent's deadlines unarmed.
- If the replacement also ends without a verdict, stop and report an environment failure with its status and any keyed line.
- Never arm a third source, and never mark the reviewer `unresponsive` for this failure.

**Process liveness.**

1. A process-owned domain keeps the same artifact watchdog and exact-file acceptance.
2. Read its recorded job completion and log on each sweep through the runner's owners.
3. A process has no chat or child-wait target. The ping rows below apply only to messageable attached agents, and the process keeps its per-domain deadline.
4. A never-launched domain's clock starts at its actual first delegation.
5. An attempted domain, a retry or a continuation keeps its original clock and spent allowance, and a fresh process never resets them.
6. Job evidence of an active required measurement earns the measurement allowance below; a promise does not.
7. At its terminal deadline, stop the process through [job-units.md § Stopping](../references/job-units.md#stopping) before any allowed replacement.
8. Carry every attempt and failure forward.

**Continuation clocks.**

1. Keep the batch's evidence boundary for accepted-file rechecks.
2. A never-launched domain's clock starts at its actual first delegation, which this workflow records in `remaining` and `traps` on any later handoff. Use it for the ping, post-ping, per-agent and measurement deadlines, never the older batch time.
3. An attempted domain keeps its original clocks, spent ping and re-delegation history and wake owner.
4. A resumed session restarts none of them.

**Deadlines.** Sweep the filesystem on every wake. Each agent's deadline runs from `review_delegated_at`, or from the continuation clock above:

- 25 minutes for an agent whose name contains `perf`.
- 36 minutes for `reviewer-test`: one [`mutation-stability`](../../reviewer/scripts/mutation-stability) run at the defaults its `--help` prints, plus 5 minutes.
- 15 minutes for every other agent.
- The external lane's printed deadline, absolute Unix epoch seconds compared with `date +%s`. With no deadline printed, use 2 × `SECOND_OPINION_TIMEOUT` plus 3 minutes; `second-opinion --help` prints the timeout's default. The external lane is no messageable agent, so the ping rows never apply to it.

**Active required measurement.**

1. A responsive reviewer running the [reviewer skill's Mutation-Stability Pairing](../../reviewer/SKILL.md#mutation-stability-pairing) gets the `reviewer-test` deadline, whatever its name, when its status reply identifies the active required measurement job.
2. Apply it before the post-ping and per-agent rows, anchored to the original delegation clock. A reply restarts no clock.
3. Re-arm the wake source for it.
4. A promise with no active required job keeps the agent's usual deadline.
5. Completion still needs § 3.1's validated artifact.

| Event | Action |
|-------|--------|
| A return arrives | Run § 3.1's artifact check |
| 2 min after the first return, or 10 min from delegation with no return; once per cycle (wave mode: per wave) | Ping each outstanding agent once, the external lane exempt: `Status check on [ISSUE_ID] review: return your verdict if complete. If incomplete, report the blocker and identify any active required Mutation-Stability Pairing job.` |
| 2 min after that ping | Mark each agent still outstanding `unresponsive`, except a perf agent, `reviewer-test`, a responsive reviewer with an active required measurement, and the external lane |
| The agent's deadline above | Mark that agent or lane `unresponsive` |

Wave mode also shuts an `unresponsive` reviewer down and records it, so its slot frees and it does not relaunch this cycle:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","agent":"[AGENT]"}'
```

**When `OUTSTANDING` is empty** (`unresponsive` counts as resolved, never accepted):

1. A never-launched required domain still unread returns to § 2 for its admission.
2. Wave mode returns to § 2.2 for the next wave while any reviewer in `[AGENTS]` is missing from `review_wave_done`. Every process-owned launch passes its own admission first, and a continuation keeps its original batch.
3. Otherwise go to § 3.3.

### 3.3 Present

**Close the review stage.** The runtime alone writes a stage's end ([workflow-state.md](../schemas/workflow-state.md) `stages`); the artifact check writes none. Compute the outcome `[WORD]` from the required panel `[AGENTS]` and the artifacts § 3.1 accepted. The external lane is advisory and takes no part. `[WORD]` is the first row that holds:

| Condition | `[WORD]` |
|---|---|
| An accepted artifact of a required reviewer reports a blocker | `fail` |
| A required reviewer's process was stopped at its terminal deadline (§ 3.2) | `stopped` |
| A required reviewer's process ended with no accepted artifact and no stop: a nonzero exit, a confirmed interruption | `lost` |
| A required reviewer is `unresponsive`, never launched, or its artifact was refused and not replaced | `no-verdict` |
| Every required reviewer's artifact was accepted with no blocker | `pass` |

- Evidence from one member never stands for an unread required member.
- `[END_PATH]` is the `path` of the batch's last `ok == true` result. The runtime reads its modification time as the stage's end.
- Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "accept-result", "round_id": "[REVIEW_ROUND_ID]", "outcome": "[WORD]", "end": {"from_artifact": "[END_PATH]"}}` and run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
```

A batch that accepted no artifact closes with its `[WORD]` and no `end`.

The overall verdict is `action_required` when any reviewer reported a blocker, else `pass`. An unresponsive reviewer does not change it.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ PR REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[verdict\|unresponsive]` | `[path or —]` |

</output_format>

- Blockers or suggestions present: § 4.
- Otherwise complete [Record verified findings](../schemas/workflow-state.md#record-verified-findings) with the empty finding set, then § 5.

## 4. Handle Review Items

1. Collect the blockers and suggestions from the accepted artifacts.
2. With none, complete [Record verified findings](../schemas/workflow-state.md#record-verified-findings) with the empty set and go to § 5.
3. Otherwise complete it after this section's disposition and before any route below. It also covers the `category == "issue"` findings that § 8 files.

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

Omit empty categories.

**Disposition.** Disposition is by rule, never by prompt. Present no selection menu over the findings, in any `ORCH_DECISION_MODE`.

1. Read `patched_causes` and `frozen_causes` first, with the command [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) states.
2. Disposition every finding by [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow), Step 0 first. Only what survives enters the fix set.
3. Decline, with a one-line reason, an item that cannot affect real usage ([finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar)). A declined item is neither fixed nor filed; § 8 reports it.
4. A check result's `repeats` entry is a candidate: a finding at a location where § 4 or § 7 recorded a decline, with each recorded description and reason. The same defect stays declined and takes the write below with its recorded reason. Disposition a different defect like any other.
5. Every surviving blocker goes to the fix round. The fix round is blockers only.
   - A `category == "fix"` suggestion enters it only as a blocker, where Step 1 finds a defect this diff introduces or arms.
   - Decline every other `category == "fix"` suggestion by the write below, or track it for § 8 by the escalation write of § At The Cap, with `reason` `fix suggestion outside the blockers-only fix round` and `outcome` `skipped`.

Record every decline, from this section or any disposition step, in one write per item. The write replaces an entry with the same location and description. `[SOURCE]` is `pr-review` here, and `qa-review` where § 7 follows this pattern:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"declined","drop":["declined"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"[ONE_LINE_REASON]","source":"[SOURCE]"}}'
```

**Recurrence before the cap.** [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) dispositions a finding that shares a root cause with one a prior round patched. No further patch round answers it. Check it here, before the cap. Each disposition owes one thing:

- A cause this diff introduces or arms takes `structural-close`: one item that names the generating surface in place of the site. It reaches the fix round whatever `rereview_cycles` reads.
- A cause this diff neither introduces nor arms takes the escalation write of § At The Cap, its `reason` `recurrence outside this diff's authorship`, and § 8 files it.
- A cause `frozen_causes` names takes its one-line reason and reaches § 8's declined report.

Separate the work the item's goal needs from separable work of another concern:

- Finish the first here.
- Give the second its own item with its actual owner in the same pass, through § 8's filing.

The **fix set** is what this section delegates: every item still standing after declines and tracking, plus every `structural-close`. At the cap it holds only those closes and the correction or cut § At The Cap permits.

1. Apply § At The Cap before routing.
2. An empty fix set goes to § 5; otherwise go to § Fix Delegation.

### At The Cap

`REVIEW_MAX_CYCLES` bounds the fix rounds of ordinary items. [settings.md § Review and CI](../references/settings.md#review-and-ci) states what `0` and `1` allow, and the default. A project setting raises it for a standard item. [small.md](small.md) holds a small item to 1, and micro runs none. The cap decides before any delegation:

```bash
.agents/skills/orch/scripts/orch-runtime state cap REVIEW_MAX_CYCLES --item [ISSUE_ID]
```

Apply the own-regression rule below before routing on the reply's `verdict`.

- `below`: go to § Fix Delegation.
- `at-cap`: the fix loop ends here, apart from the fix set's `structural-close` items and the correction or cut below. A cap is a ruling point, never the end of work the goal needs.
  1. Escalate the outstanding items by the write below, and name them in the lane status.
  2. Another fix round starts only once the overseer has ruled, judging with the reply's `count` and `limit`, and recorded one `ruling` row for the item in the fleet log ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)). The ruling names the separated items.

**A fix round's own regression.** A blocker in lines the last fix round wrote (`pre_delegate_sha` to HEAD), which no earlier review reported, gets one correction past the cap per pull request.

1. Read the round files `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` named by the `round_id` of each `dev` stage, rounds from other review paths included.
   - A `Correction: own-regression [BOUNDARY_SHA]` line in an `items[].text` means this pull request has spent its correction.
   - An unmarked round, a cap-zero or `structural-close` round included, spends none.
2. With no correction recorded, add these blockers to the fix set.
   - Keep the new batch's boundary, the worktree's HEAD, before § Fix Delegation overwrites `pre_delegate_sha`.
   - Append the correction line to each correction item's text.
   - Every domain group delegated carries the same boundary and counts as one correction.
   - Complete the whole batch before re-review.
3. § Bounded Re-Review finds that batch by the correction boundary matching `pre_delegate_sha`, and takes `verification_panel` before its cap-zero exit.
4. A later such blocker in the same pull request ends the fix rounds, even below the cap.
   - Where the Done-when does not need its code, add a cut item to the fix set.
   - Otherwise escalate it below and name it in the lane status for the overseer's [design review](../references/design-review.md).
   - On this terminal pass, route as at the cap. Keep only structural-close and cut items in the fix set, and escalate every other outstanding blocker.

**Escalation.** A capped item is escalated, never dropped.

1. Record every blocker this pass found still outstanding, and every suggestion § 4 made one, a `fixed_items` entry whose fix did not hold included.
2. Leave out only what `escalated_items` holds, what § 4 declined, and the fix set's `structural-close`, correction and cut items. A decline is terminal.
3. Make one write per item, before § Fix Delegation or § 5. In one command the write drops a superseded `fixed_items` entry with the same location and description and records the item, so the item never stands in both buckets or in neither:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"escalated","drop":["fixed"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"outstanding at the review cycle cap","outcome":"blocked","source":"[SOURCE]","kind":"[KIND]"}}'
```

- `[ARTIFACT_PATH]` is the `json_paths` entry the item came from. `[ARRAY]` is `blockers` or `suggestions`, and `[INDEX]` is its position there. Type only a path, an array name, an integer and the one `[KIND]` word.
- `[KIND]` is `regression-against-main` for a blocker that breaks behaviour the base branch has, and empty for every other item.
- `[SOURCE]` is `pr-review`, or `qa-review` for a QA item that reached this rule through § 7. § 8 reports these items as escalated and takes each one's agent and priority from its artifact.

1. Report the outstanding items.
2. A non-empty fix set goes to § Fix Delegation; otherwise § 5.

### Fix Delegation

**Skip if** the fix set is empty.

A finding that leaves the fix set is never dropped. Decline it per [finding-disposition](../../reviewer/references/finding-disposition.md) when a cut removed its surface, or record it in `escalated_items` when § 8 is to file it.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"base","worktree":"[WORKTREE_PATH]","review_fix":true}'
```

**Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § Bounded Re-Review` with context `worktree`, `lifecycle: "managed"`, `dev_agent`, `issue_id`, `items` (the fix set, each formatted per [dev-round.md § Item text](../schemas/dev-round.md#item-text)), and `source: pr-review`.

### Bounded Re-Review

1. Apply § At The Cap's correction route first.
2. For every other § 4 fix round, or a submit-pr cut, a cap of 0 (`orch-runtime state cap REVIEW_MAX_CYCLES` with no `--item` answers its `limit`) goes to § 5, accepted on validation.
3. Every other entry, a § 7 QA round included, scopes the re-review to what the round changed. Read the round's diff:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pre_delegate_sha
   .agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH] [PRE_SHA]
   ```

| Round | Next |
|-------|------|
| No files changed | § 5 |
| Anything else | § 2 with caller context `agents` = the scoped panel below |

The scoped panel is the reviewers whose domains the fix diff touches, the reviewers whose defect classes the round fixed (the blocker finders), and external review when available. A domain counts when the fix diff changes code or text that reviewer reads, not when the item's first diff did. Record it, with `external` set to the cycle's `EXTERNAL_REVIEW_REQUESTED`:

- the correction route of § At The Cap writes `"panel":"verification"`;
- otherwise write `"panel":"rereview"` while budget remains, or `"panel":"verification"` for the past-budget verification pass this section permits.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-panel","panel":"rereview","agents":[PANEL_AGENTS_JSON],"reason":"[DOMAINS_TOUCHED] + blocker finders + external","external":[EXTERNAL_REVIEW_REQUESTED]}'
```

A panel holding every `first_panel` reviewer adds `"domain_reasons": {"[AGENT]": "[WHY THE FIX DIFF CONCERNS THIS DOMAIN]", ...}`, one entry per `first_panel` reviewer.

**The loop ends** when two consecutive cycles surface no new blocker, at the cap-0 exit, or when § At The Cap ends it.

- The cap bounds new cycles, never verification.
- A fix diff no reviewer has seen gets one focused verification pass, scoped to that diff. The loop's last fix round has budget for it. Past the budget it takes `verification_panel`, which the cap does not gate.
- That pass's items re-enter § 4, where the fix set decides what still delegates.
- In wave mode the panel replaces `[AGENTS]` for the cycle and the wave rules apply unchanged.

## 5. Verdict Pass

Shut the review agents down and clear their state. In wave mode the sessions are already retired, so this clears state only:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"cleared"}'
```

**QA routing.** One request reads the dev round's `qa_labels`. It scans the round's full diff for unsafe code, atomics, and paths matching `QA_PERF_PATHS` and `QA_UI_PATHS`. It applies the judgments in order and writes `qa_decision` with the agent for each signal. Write `[WORKTREE_PATH]/tmp/qa-decision-[ISSUE_ID].json` with the harness file tool as `{"op": "record-qa-decision", "step": "scan", "worktree": "[WORKTREE_PATH]", "base": "origin/[BASE_BRANCH]", "judgments": []}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/qa-decision-[ISSUE_ID].json
```

- `[BASE_BRANCH]` is § 1's `resolve-base-branch` output.
- A refusal records nothing: report its keyed line and stop the review.

**Judgment.**

1. Add or drop a signal with a one-line reason.
2. List each in the request's `judgments` as `{"judge": "add", "signal": "[SIGNAL]", "reason": "[ONE_LINE]"}`, or `"judge": "drop"`, and run the request again.
3. Put every judgment in that one request, because a rescan writes `qa_decision` whole from its own request.
4. Drop a signal when the triggering code is trivial or test-only. Never drop one for schedule pressure.

**User skip.** When workflow state `skip_qa` reads `true`, reset it with `orch-runtime state set --item [ISSUE_ID] /skip_qa false`, record the skip, and go to § 7:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-qa-decision","step":"skip"}'
```

Signals empty: § 7. Otherwise § 6.

## 6. QA Checks

**Skip if** the recorded `qa_decision.signals` is empty: go to § 7, which finds no QA artifact, converges and routes on. § 7 decides the exit even when QA never ran.

Delegate each recorded signal to the agent `qa_decision.agents` names for it, and wait. A project may override the mapping in its instructions.

- The `needs-ui-review` agent judges the screenshots the dev summary lists against the design-system doc `QA_UI_DESIGN_DOC` names. Its delegation's Dev summary carries a Screenshots list: each changed view's set, as `.agents/skills/reviewer/references/ui-screenshots.md` § Screenshots defines it. On a QA re-check, each view's entries come from the latest dev round whose summary lists that view: a fix round that recaptured it, else the implement round.
- Fill `Worktree:` by the rule at the top of this workflow. Omit `[OWNER/REPO]` when `TRACKER=linear`.

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
- Fixed since last review: [For each fixed_item with source "qa-review": "[LOCATION] | [DESCRIPTION] — fixed in [COMMIT_SHA]"; an entry whose commit is a `dropped:<sha>` marker prints "recorded, then dropped in a rebase" in place of the sha]
- Escalated (accepted): [For each escalated_item with source "qa-review": "[LOCATION] | [DESCRIPTION] — [REASON]"]
- Declined: [For each declined_item, whatever its source: "[LOCATION] | [DESCRIPTION] — [REASON]"]
- Do NOT re-report the fixed, escalated or declined items listed above, unless you check a listed fixed item against the current diff and the defect is still there — then report it again, copying that entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha. A listed fixed item you did not check, and every listed escalated or declined item, stays suppressed. Otherwise report only new issues or regressions the fixes introduced.
</delegation_format>

1. Each QA agent's batch is a [Record verified findings](../schemas/workflow-state.md#record-verified-findings) batch. Admit it with § 2.2's round token writes, state writes enabled.
2. Accept each return through § 3.1's check. On `ok == true`, append the artifact path to `json_paths` and carry its `repeats` to § 7.
3. When the agent reports a `benchmark_commit` other than `none`, confirm it resolves with `git -C [WORKTREE_PATH] log -1 --oneline [SHA]`.
4. Post a performance QA agent's `qa_metadata.perf_qa` block as an issue comment, written to a file first: Linear through `linear.sh comments create [ISSUE_ID] --body-file`, GitHub through `gh issue comment ${ISSUE_ID#issue-} --body-file`.
5. Once every QA reviewer resolves, go to § 7 on every verdict.
   - Carry the blockers and the `category == "fix"` suggestions not already in `escalated_items`.
   - Keep an item this round's QA artifact reports again, even when `fixed_items` lists it, as § 7 states.

## 7. Handle QA Items

Complete [Record verified findings](../schemas/workflow-state.md#record-verified-findings) for this QA batch after its disposition and before either route below. It includes the `category == "issue"` findings § 8 files.

When **Converged** below is false, follow § 4: collect, present, run its recurrence check on the same two records, then delegate through `workflows/dev-fix.md`, by rule and with no selection prompt. These overrides apply:

- The fix set is § 4's, dispositions and all, with its candidate rule applied to the `repeats` § 6 carried.
- Items come from the QA artifacts.
  1. Leave out what `escalated_items` holds.
  2. Leave out a `fixed_items` entry only when this round's QA artifact does not report it again.
  3. Keep a re-found item: its `fixed_items` entry is stale, and the Converged exit drops that entry and records the item.
- The table header is `QA Agent` and the title `QA Review Items — [ISSUE_ID]`. `source` is `qa-review`, and `qa_agent` carries the agent name.
- **No cap check runs here.** This section neither reads nor raises the § 4 budget `REVIEW_MAX_CYCLES` bounds.
- After the fix round, apply § Bounded Re-Review with § 6 as the target in place of § 2: a focused QA re-check of the recorded signals, which records no panel.
  1. A round whose diff reaches beyond QA's own surface returns to § 2 instead, with its panel recorded as `"panel":"verification"`.
  2. Either target re-runs the QA agents or the reviewers and comes back here. Neither decides an exit.

### Converged

This is QA's one exit predicate and the only route to § 8. § 6, a QA re-check and a § 2 verification pass all come back here.

**Converged** is true when this round's QA artifacts report nothing this section can act on.

- A blocker first raised on this pass, or a suggestion § 4's rule makes one, is a new finding, and the predicate is false.
- Any other `category == "fix"` suggestion takes § 4's one-pass disposition with `[SOURCE]` `qa-review`.
- A `category == "issue"` suggestion rides through to § 8, which files it.

Route on the predicate:

- True: the disposition below, then § 8.
- False: the fix round above. The loop runs while each round finds a distinct defect this diff introduced. It stops the moment one root cause reappears at a new site, which takes [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence)'s structural close, never another patch round.

On the way out, before § 8, disposition every item still outstanding:

1. That is every blocker and every `category == "fix"` suggestion this round's QA artifacts report, whether or not `fixed_items` lists it, except what `escalated_items` holds and what this section declined.
2. An item dev returns as Blocked reaches `escalated_items` through `dev-fix.md`.
3. Make one write per item. In one command it drops a superseded `fixed_items` entry and records the item. `[ARTIFACT_PATH]`, `[ARRAY]`, `[INDEX]` and `[KIND]` are as § At The Cap sets them, and the reason is this exit's own:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"escalated","drop":["fixed"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"QA loop converged with the item unresolved","outcome":"blocked","source":"qa-review","kind":"[KIND]"}}'
```

## 8. Summary And Issue Audit

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {json_paths: (.json_paths // []), fixed: (.fixed_items // []), escalated: (.escalated_items // []), declined: (.declined_items // [])}' <<<"$STATE_READ"
```

1. Empty `json_paths`: report "No review items" and go to § 9.
2. Read every artifact.
   - Collect the `category == "issue"` suggestions and deduplicate them by location and description, keeping the first and noting every source.
   - § 4 and § 7 already completed the findings contract, so do not admit old artifacts as a new batch.
3. **Re-derive the declined items, then match them to their record.** A blocker or `category == "fix"` suggestion that stands in a `json_paths` artifact but in neither `fixed_items` nor `escalated_items` was declined in § 4 or § 7.
   - Carry the reason its `declined_items` entry records, matched on location and description.
   - Where no entry records it, report `reason: not recorded`.

Output: [Lane Output](../references/skill-rules.md#lane-output).

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
Est: a size class within the team, 1 for its smallest work through 5 for its largest, never a unit of time

</output_format>

Omit empty sections.

**File only what clears the bar.**

1. Apply [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar) to every candidate: `category == "issue"` suggestions, escalated items, and the Discovered Work bullets of the dev return. Absorb or drop everything below the bar with a one-line note.
2. Silently drop the Discovered Work bullets matching `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s`, which this workflow already carries. The filter applies to Discovered Work only.
3. Nothing clears the bar: go to § 9.
4. Build the audit-input file per `.agents/skills/project-management/schemas/audit-issues-input.md` at `[WORKTREE_PATH]/tmp/audit-review-YYYYMMDD-HHMMSS.json`, with `source: "review"` and `parent_issue: [ISSUE_ID]`.
   - Set `tracker.type` to `TRACKER`, plus `tracker.repository` for GitHub items.
   - Each escalated item's `outcome` sets its `origin`: `"skipped"` gives `origin: "skipped"`; `"blocked"` or no `outcome` gives `origin: "escalated"`.
   - With `TRACKER=linear`, also set `in_pr_bundle: true`. Only this section marks `[ISSUE_ID]` an in-PR bundle root and works the children the audit files under it.
5. Apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination), then **Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 8 step 6`.
6. Record each created issue:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-comment-ledger","entry":"issue","id":"[CREATED_ISSUE_ID]","origin":"audit"}'
   ```

**Children worked here** (Linear only). When the audit created `make_child` issues under `[ISSUE_ID]`:

1. Record `[ISSUE_ID]` as their in-PR bundle root, the marker that dev-start's Ancestor gate and every container reader read ([skill-rules.md § Coordination](../references/skill-rules.md#coordination)).
   - Read its description with `issues get [ISSUE_ID]`, and add the line `**In-PR bundle**: yes` under its `## Filing record` heading.
   - Write the full description to `[WORKTREE_PATH]/tmp/in-pr-bundle-[ISSUE_ID].md`, and save it with `issues update [ISSUE_ID] --description-file [WORKTREE_PATH]/tmp/in-pr-bundle-[ISSUE_ID].md`.
2. Delegate them at once: `⤵ workflows/dev-start.md § 1-4` with context `worktree`, `lifecycle` inherited, and `issue_id`. The managed call must pass dev-start's § 2 live Ancestor gate first.
3. A `no-change` return from dev-start ends that child's round with no commit. Merge-pr still owns the child's tracker end.
4. After delegating the children, apply § Bounded Re-Review to their diff.
5. When delegation does not happen, a gate refusal included:
   - First remove the bundle line the same way.
   - Then detach from `[ISSUE_ID]` each `audit_issues_created` entry whose live `issues get [CHILD_ID]` reports `parent_id` `[ISSUE_ID]`. Otherwise `merge-pr.md` closes them as Done with the parent. Each detach:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --remove-parent && .agents/skills/linear/scripts/linear.sh issues add-relation [CHILD_ID] --related [ISSUE_ID]
   ```

## 9. Return

`[VERDICT]` is the verdict this review hands its caller, which [submit-pr.md](submit-pr.md) § 6.1 gate 1 reads. Read workflow state `pr_order` and take one branch:

- **`open-first`**: keep § 1's pending line and write no verdict line. This review's fix rounds are still local, and the overseer must not approve or request Copilot on the head they replace. Record that this review returned. The record lets [submit-pr.md](submit-pr.md) § 2 run its triage, write this verdict once its push lands, and arm the pull request:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"open-first-returned"}'
  ```

- **`push-first`**: keep the pending review line until `[VERDICT]` is `pass`. The line holds the overseer's approval while submit-pr § 2 step 5 arms nothing. Only a `pass` records the return:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"push-first-returned"}'
  ```

  Submit-pr publishes the combined fixes and settles each new head's Copilot request ([gates.md § Copilot requests](../references/gates.md#copilot-requests)) before it arms auto-merge.

- **Any other value, or absent**: in a lane whose brief names a status file, write the review line `Review: [VERDICT]`. Record no workflow state. A review-first lane, a re-submit review and a trivial-diff skip leave `pr_order` as they found it.

**Managed**: return to the parent workflow's next section. **Standalone**: the session is complete, and § 8 holds the summary.
