# PR Review Workflow

Review a branch before submission: run the reviewer panel, delegate bounded fix rounds, run QA, and file what the review leaves. `review-pr [PR_NUMBER]` reviews that pull request's worktree. [start-worktree.md](start-worktree.md) § 3 runs this workflow managed. [review-cycle.md](../references/review-cycle.md) holds the contracts the steps below name: the review cap, the reviewer wait, process-owned review, and the handoff with its continuation.

When start-worktree.md § 2.1 opened the pull request early, this review runs on the pushed head. Its fix rounds stay local until submit-pr pushes them. Under `push-first`, start-worktree.md § 2.1's first-head review call, run with `[MARK_READY]` `true`, marks the pull request ready.

**Caller context** (via `⤵`):

- `worktree`.
- `agents`: an explicit reviewer panel. Without it, § 2 selects the first-cycle panel.
- `lifecycle`: `"managed"` (return at § 9) or `"self"` (default).
- `dev_agent`: a live dev agent for fix rounds.
- `issue_id`: the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

**Worktree resolution.**

- With a PR number, `.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text` prints `ISSUE`. Apply [Worktree Scope](../SKILL.md#workflow-execution), and ask before `worktree create [ISSUE] --pr [PR_NUMBER]`.
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
2. With no committed diff, report "No committed changes to review" and **END**.
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

**Fresh first cycle.** Take this step only on a fresh entry from § 1, outside any saved review handoff or its fallback. Apply **Panel** and § 2.1 once before admission. Resolve `origin/[BASE_BRANCH]` and `HEAD` to `[BASE_SHA]` and `[HEAD_SHA]`, then run [review-cycle.md § Tier escape](../references/review-cycle.md#tier-escape) with the final panel. Keep `[AGENTS]` as the full panel for collection. Use the returned `launch` list for admission, slot sizing, reviewer classification and delegation, and carry `kept` into § 3.1. An empty launch list skips internal admission, slots and launches. Take § 2.2's token writes, any requested external review still owed, then collection. With work to launch, take the admission below, then skip the panel and policy reads already made.

**Pre-panel admission.** Before you size or start attached reviewers, ask the runtime whether this session has room for their returns. Run it from `[WORKTREE_PATH]`:

```bash
.agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --attached-launch
```

- In a lane, the command reads the session and transcript bound to its pane.
- Outside a lane, pass the harness name and this session's native ID and transcript path as one JSON object on stdin. Copilot requires the session ID, and can read its session record without a transcript path.

```bash
jq -cn --arg harness "[HARNESS]" --arg session_id "[SESSION_ID]" --arg transcript_path "[TRANSCRIPT_PATH]" '{harness: $harness, session_id: $session_id, transcript_path: $transcript_path}' |
  .agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --attached-launch
```

Route on the reply's `verdict`:

- `room`: size and start the attached panel below.
- `alternate-review`: Codex only. The attached-agent reserve refuses, while the plain mark has room.
  1. Keep the full required panel. Run its required domains as process-owned Codex reviewers through [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers) and [review-cycle.md § Process-owned review](../references/review-cycle.md#process-owned-review).
  2. Skip attached slot sizing, thread selection and spawn. Keep panel selection, the existing-assignment reads and § 2.1.
  3. This verdict permits no attached launch and no advisory replacement.
- `due`: hand off by [review-cycle.md § Handoff on `due`](../references/review-cycle.md#handoff-on-due).
- A refusal at exit 2:
  1. Start no attached panel. Report the stderr line.
  2. If the harness cannot supply the named session input or is unsupported, ask the user to resume the review in a supported session that supplies it.
  3. Otherwise repair the cause before re-entering § 2.

**Continuation.** A successor that resumes a handed-off review applies [review-cycle.md § Original-batch continuation](../references/review-cycle.md#original-batch-continuation) after this admission. A proved continuation, in the steps below, is one that section proves.

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
  3. Bound the wave by a positive `observed`, and by a nonzero budget after the primary and other active work.
  4. A zero-sized wave takes Codex thread reuse's held-thread wait.
- **Every other surface.**
  1. A positive `observed` is wave mode at that size.
  2. Otherwise a budget of `0` is persistent mode, and a positive budget gives `REVIEWER_SLOTS` by [skill-rules.md § Reviewer persistence is budget-conditional](../references/skill-rules.md#reviewer-persistence-is-budget-conditional) step 3.
- Use wave mode when `[AGENTS]` exceeds `REVIEWER_SLOTS`; otherwise use persistent mode.
- Recompute at every § 2 entry.

**Existing reviewers.** Read the stored reviewer state before any spawn:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {review_agents: (.review_agents // []), review_agent_ids: (.review_agent_ids // {}), review_agent_runtime_types: (.review_agent_runtime_types // {})}' <<<"$STATE_READ"
```

1. For attached review, classify each reviewer in `[AGENTS]` as reusable, context-exhausted, missing, closed or confirmed-stuck. On a proved continuation, classify only its launch subset, and keep the attempted assignments for § 3.
2. Reuse a live ID only under [Delegation](../references/skill-rules.md#delegation) for the target worktree, after a name-only resume too.
3. On Codex, retire and reuse under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
4. Add the context-exhausted, missing, closed and confirmed-stuck reviewers to `REVIEWERS_TO_LAUNCH`.
5. Carry a reusable reviewer's runtime-type entry forward.
6. On a re-review whose panel shrank (§ Bounded Re-Review scopes it), retire the reviewers outside the panel first.
7. For `alternate-review`, read the process ownership facts in the lane status and in the handoff's `remaining` and `traps` prose. Keep accepted and attempted assignments, attached work included, and select only never-launched required domains for process launch.
8. Spawn nothing yet: resolve § 2.1 first.

### 2.1 External Review Availability

- External review runs beside the internal panel when the consumer's policy chooses it. It runs like an internal reviewer, with no user prompt.
- A proved continuation keeps the original external request and its return owner: skip this section and collect it through § 3.
- An unknown outcome or liveness stays unread, and nothing replaces it.

1. Read the policy from the consumer's base checkout:

   ```bash
   .agents/skills/orch/scripts/orch-runtime validate policy --base-checkout [REVIEW_BASE_CHECKOUT] --stage external-review
   ```

   - `result.answer` `skip` sets `EXTERNAL_REVIEW_REQUESTED=false`, with `EXTERNAL_SKIP_REASON` `policy: skip`.
   - A nonzero exit reports its keyed line and sets it false, with that line as `EXTERNAL_SKIP_REASON`.
   - On `run`, continue.

2. When `.agents/skills/second-opinion/scripts/second-opinion` is absent, report in one line that the chosen external review has no installed tool. Set `EXTERNAL_REVIEW_REQUESTED=false`, with `EXTERNAL_SKIP_REASON` `second-opinion not installed`, and continue.
3. Detect the available targets:

   ```bash
   .agents/skills/second-opinion/scripts/second-opinion detect
   ```

   - A failure, `none` or empty output sets `EXTERNAL_REVIEW_REQUESTED=false`.
   - Anything else sets it `true`. The output signals availability only; the review runs without `--target`.
   - On `none`, the error JSON's `candidates` carry a reason per target. Tell the user once, `External review skipped — [CANDIDATE_REASONS]. Fix: [FIX]`, where `[FIX]` is each reason's remedy in the second-opinion skill's references/error-handling.md.
   - `EXTERNAL_SKIP_REASON` is `[CANDIDATE_REASONS]` on `none`, the error JSON's `error` or first stderr line on another failure, and `detect: no output` on empty output.

4. **Record the panel** on a fresh § 1 entry, before any spawn. Set `external` to `EXTERNAL_REVIEW_REQUESTED` and, when it is false, `external_skip` to `EXTERNAL_SKIP_REASON`. A `small` item's panel holds three reviewers at most, the external lane counted.
   1. The reason is tool output, so write the request to `[WORKTREE_PATH]/tmp/record-panel-[ISSUE_ID].json` with the harness file tool. Leave out `external_skip` when `external` is true:

      ```json
      {"op":"record-panel","panel":"first","agents":[PANEL_AGENTS_JSON],"reason":"[PANEL_REASON]","external":[EXTERNAL_REVIEW_REQUESTED],"external_skip":"[EXTERNAL_SKIP_REASON]"}
      ```

   2. Run it:

      ```bash
      .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/record-panel-[ISSUE_ID].json
      ```

### 2.2 Launch And Delegate

For a fresh first cycle planned in § 2, delegate from that cycle's launch list, carrying it across its waves. Skip attached and process launch blocks when it is empty. Other entries use the launch candidates from their existing routes.

**Round token.**

- A fresh batch mints its review round before its first spawn or process launch.
- A proved continuation keeps its original `review_round_id` and `review_delegated_at`, and mints nothing.
- Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "review"}`, run it, then stamp the delegation time:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"review"}'
```

On the fresh first cycle from § 2 only, use this form instead of the delegation-time-only stamp:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"review","review_range":{"base":"[BASE_SHA]","head":"[HEAD_SHA]"}}'
```

- `[REVIEW_ROUND_ID]` is the first reply's `.result.report.round_id`.
- The write opens a new review stage ([workflow-state.md](../schemas/workflow-state.md) `stages`), which § 3.3 closes.
- These two writes are this batch's admission under [Record verified findings](../schemas/workflow-state.md#record-verified-findings), with state writes enabled. § 3.1 is its acceptance; § 4 is its disposition and completion.

**Scope.**

1. On the fresh first cycle from § 2, use its resolved endpoints. An ordinary fresh review after a failed handoff proof resolves `origin/[BASE_BRANCH]` and `HEAD` to commit SHAs.
2. On a § 4 or § 7 re-entry, resolve the stored `pre_delegate_sha` and the current `HEAD`.
3. Bind `[DIFF_RANGE]` to the concrete `[BASE_SHA]...[HEAD_SHA]`, and pass it to internal and external review alike.
4. A missing fix boundary sends `unavailable` internally and the external default.
5. A proved continuation keeps its resolved endpoints.

**Attached launch.**

1. In wave mode, `[WAVE]` is the first `REVIEWER_SLOTS` reviewers in `[AGENTS]` not yet in `review_wave_done`. Launch only those. A continuation selects its wave only from its never-launched launch subset, and keeps the full required panel.
2. On a fresh entry from § 2.1, reset the wave record. Skip the reset on a proved continuation, and when § 3.2 returns here for the next wave of the same cycle:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"wave-start"}'
   ```

3. Select an eligible finished thread, or spawn each reviewer in `REVIEWERS_TO_LAUNCH`, under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
   - On Codex, spawn each canonical reviewer name by [codex-runtime.md § Spawning Codex collaboration agents](../references/codex-runtime.md#spawning-codex-collaboration-agents), and reuse an eligible finished reviewer thread with the complete delegation below.
4. When a spawn fails with the runtime's thread-limit error:
   - Do not retry it, and do not tear down the reviewers that spawned.
   - Continue with those, fold the failed reviewer into a later wave, and use that smaller size for the rest of the cycle.
   - Record it in one write. On Codex, `[OBSERVED_SPAWN_COUNT]` counts assigned reusable threads as well as fresh spawns. The write keeps `review_wave_done` on every wave:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"wave-start","slots_observed":[OBSERVED_SPAWN_COUNT]}'
   ```

   Then tell the user once: `Runtime capped concurrent agent sessions — set REVIEWER_SLOT_BUDGET = "[OBSERVED_BUDGET]" in kendex.settings.toml [env]`. On Codex, `[OBSERVED_BUDGET]` is the `effective_cap` that `subagent room` reported. Elsewhere it is the successful spawns, plus this session, plus the `slots` reply's `live`.

5. When candidates were selected for launch and none could start:
   - On Codex, an empty fresh-spawn set first takes Codex thread reuse's eligible-thread and held-thread wave routes. Report the cap blocker that rule names only when neither can run the work.
   - On every other surface, nothing spawned is a misconfiguration: report it and stop.
6. Store the active set under canonical reviewer names. A continuation includes its kept attempted and live assignments, with their IDs and runtime types:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"active","agents":[AGENT_LIST_JSON],"ids":[AGENT_ID_MAP_JSON],"runtime_types":[AGENT_RUNTIME_TYPE_MAP_JSON]}'
   ```

**Both execution paths.**

1. On `alternate-review`, every never-launched required domain starts in the same wave, each through its own [review-cycle.md § Process launch admission](../references/review-cycle.md#process-launch-admission). No domain waits for another to start.
2. Keep the complete required panel and every earlier assignment.
3. Record in the lane status and ownership prose each process's exact job directory, runner, exit, log and artifact paths, actual first-delegation time, deadline, and rejection and re-delegation history.
4. Store the canonical active domains in `review_agents`. A process has no entry in `review_agent_ids` or `review_agent_runtime_types`, and no process number goes in either map.
5. Keep `review_wave_done`, the original `review_round_id`, `review_delegated_at` and the concrete scope across process waves and continuations. Reset them only for a fresh batch.
6. A live assignment never gets a second job.
7. A missing runner, CLI, native source or launch selection stops this route: report the exact cause to the caller.

**Delegate.**

1. Mint each reviewer's artifact path immediately before its delegation, one command per reviewer. Its output fills `[ARTIFACT_PATH]`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime review-artifact --text path --worktree [WORKTREE_PATH] --agent [AGENT]
   ```

   For the fresh first cycle only, add `--round-id [REVIEW_ROUND_ID]` to the mint command.

2. On Codex, prepare each complete `DELEGATION:` message under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).
3. For attached review, delegate to every reviewer selected for launch in parallel, once admission gave room.
4. For process-owned review, put the same complete role, workflow and delegation in the prompt file [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers) names. Pass each launch through [review-cycle.md § Process launch admission](../references/review-cycle.md#process-launch-admission). Call no collaboration spawn or follow-up for a process assignment.
5. When `EXTERNAL_REVIEW_REQUESTED=true` on a fresh batch and no external result was kept on this cycle, start the external review in the same batch (below). It is a shell command, not an agent session. It takes no slot, and joins only the cycle's first wave.

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

**External review** (only when requested). `[RANGE_FLAG]` is `--range [DIFF_RANGE]`, with the endpoints sent internally. Only a missing fix boundary leaves it empty, which takes the script's `origin/BASE...HEAD` default. For a fresh first cycle, mint `[EXTERNAL_OUTPUT]` by **Delegate** step 1 with `--agent external` and the round id, then run only the review command below. Otherwise take the timestamped output path. The command backgrounds itself and prints when to check:

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [EXTERNAL_OUTPUT] --foreground [RANGE_FLAG]
```

The timestamped `[EXTERNAL_OUTPUT]` is `[WORKTREE_PATH]/tmp/review-external-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json`.

1. Run the exact command printed after `wait:`, and repeat it by its exit code (`second-opinion --help`) until it ends.
2. Handle other reviewer events in between.
3. Then validate its artifact like a reviewer's, with `review_delegated_at` as the boundary. § 3.1's sweep also covers a silent finisher:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /review_delegated_at
   .agents/skills/orch/scripts/orch-runtime review-artifact --text check --file "$EXTERNAL_OUTPUT" --worktree [WORKTREE_PATH] --delegated-at [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND] --issue [ISSUE_ID]
   ```

- `ok == true`: append the path to `json_paths` (§ 3.1's write), and carry its `repeats` to § 4.
- `reason == "valid_undermeasured"`: report its `measurement_failed` string, and `measurement_suppressed` when present, beside the path. Never present the external pass as clean.
- `ok == false`, `moving_tree` included, or any nonzero exit: report the `reason`, and `detail` when present, and continue. External review is advisory. It never blocks and never stands in for a pass.
- A detached run that already exited nonzero, or an artifact that does not validate, resolves at once as `external: failed — [REASON]` and leaves `OUTSTANDING`.

## 3. Collect Results

- **Persistent mode** keeps reviewers alive for § 4.
- **Wave mode** retires each reviewer once its artifact validates, which frees the slot for the next wave.
- A process-owned reviewer follows the job lifetime in [codex-runtime.md § Process-owned reviewers](../references/codex-runtime.md#process-owned-reviewers). Its accepted artifact does not retire a running process, and its domain's next launch waits for the recorded terminal outcome.

### 3.1 Completion

- `OUTSTANDING` is the active set, plus `{external}` when requested, less the returns already accepted and the execution outcomes already resolved here.
- In the fresh first cycle only, start collection with the returned kept results already accepted. Mark them `kept` in § 3.3 and carry their findings, repeats and measurement declarations through ordinary handling.
- On a continuation, every required domain stays accounted for: accepted, attempted and unread, never launched and unread, or unresponsive.
- An unread domain holds collection until its acceptance or deadline route resolves it.

A reviewer completes only when its on-disk artifact validates:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /review_delegated_at
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --worktree [WORKTREE_PATH] --agent [AGENT] --delegated-at [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND] --issue [ISSUE_ID]
```

In the fresh first cycle only, accept the exact assigned path with `--file [ASSIGNED_ARTIFACT_PATH]` in place of `--agent [AGENT]`. Match the JSON `agent` to the canonical assignment. The agent glob remains the wake check. Run the applicable acceptance on every return and watchdog sweep.

- `ok == true`: drop the agent from `OUTSTANDING`, carry the result's `repeats` to § 4, and append the path:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","artifact":"[PATH]"}'
  ```

  Wave mode records the wave return in the same write, then shuts that reviewer's session down:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","artifact":"[PATH]","agent":"[AGENT]"}'
  ```

- `reason == "valid_undermeasured"`: carry the `measurement_failed` string into the review summary beside that verdict, with `measurement_suppressed` when present. Never present the domain as clean.

A process-owned reviewer completes by [review-cycle.md § Process-owned completion](../references/review-cycle.md#process-owned-completion). A proved continuation rechecks its assigned files by [review-cycle.md § Continuation recheck](../references/review-cycle.md#continuation-recheck).

**Incomplete returns.** An attached agent's return:

1. `ok == false` after a return, `moving_tree` included, makes the return incomplete, whatever its `File:` path or message says.
2. Send that agent exactly one re-delegation. A continuation keeps an already spent re-delegation. In the fresh first cycle or a continuation, give the exact assigned path in place of a new timestamped path. A `moving_tree` refusal needs a new review from a new starting snapshot once development finishes:

   > Your review return is incomplete: `orch-runtime review-artifact check` reports `[reason]`[ — `[detail]`] for `[WORKTREE_PATH]/tmp/review-[AGENT]-*.json`. Write your full review JSON to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json` using your harness file-write tool (not shell redirection), following every required field of `review-finding.md`, then return `Verdict:` and `File:` again.

3. If it is still `ok == false` after that, or the deadline of [review-cycle.md § Deadlines](../references/review-cycle.md#deadlines) is reached, mark the agent `unresponsive`. Never re-delegate a second time.

A process-owned reviewer's incomplete return takes [review-cycle.md § Process-owned replacement](../references/review-cycle.md#process-owned-replacement).

### 3.2 Watchdog

1. Keep a wake source armed for every incomplete agent, by [review-cycle.md § Reviewer wait](../references/review-cycle.md#reviewer-wait).
2. On every wake, act by [review-cycle.md § Deadlines](../references/review-cycle.md#deadlines) and [§ Deadline actions](../references/review-cycle.md#deadline-actions). A process-owned domain also takes [review-cycle.md § Process liveness](../references/review-cycle.md#process-liveness).
3. When `OUTSTANDING` is empty (`unresponsive` counts as resolved, never accepted):
   - A fresh first cycle considers only its launch list for the steps below. Its later waves keep the existing plan and round.
   1. A never-launched required domain still unread returns to § 2 for its admission.
   2. Wave mode returns to § 2.2 for the next wave while any reviewer in `[AGENTS]` is missing from `review_wave_done`. Every process-owned launch passes its own admission first, and a continuation keeps its original batch.
   3. Otherwise go to § 3.3.

### 3.3 Present

**Close the review stage.** The runtime alone writes a stage's end ([workflow-state.md](../schemas/workflow-state.md) `stages`); the artifact check writes none. Compute the outcome `[WORD]` from the required panel `[AGENTS]` and the artifacts § 3.1 accepted. The external lane is advisory and takes no part. `[WORD]` is the first row that holds:

| Condition | `[WORD]` |
|---|---|
| An accepted artifact of a required reviewer reports a blocker | `fail` |
| A required reviewer's process was stopped at its terminal deadline ([review-cycle.md § Process liveness](../references/review-cycle.md#process-liveness)) | `stopped` |
| A required reviewer's process ended with no accepted artifact and no stop: a nonzero exit, a confirmed interruption | `lost` |
| A required reviewer is `unresponsive`, never launched, or its artifact was refused and not replaced | `no-verdict` |
| Every required reviewer's artifact was accepted with no blocker | `pass` |

- Evidence from one member never stands for an unread required member.
- `[END_PATH]` is the `path` of the batch's last `ok == true` result. The runtime reads its modification time as the stage's end.
- For the fresh first cycle, choose the accepted path from this batch with greatest modification time. Bind the first candidate, then replace it when `test [CANDIDATE_PATH] -nt [END_PATH]` succeeds.
- Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "accept-result", "round_id": "[REVIEW_ROUND_ID]", "outcome": "[WORD]", "end": {"from_artifact": "[END_PATH]"}}` and run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
```

A batch that accepted no artifact closes with its `[WORD]` and no `end`. The fresh first cycle excludes earlier kept paths when choosing its end.

The overall verdict is `action_required` when any reviewer reported a blocker, else `pass`. An unresponsive reviewer does not change it.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ PR REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[verdict\|kept (verdict)\|unresponsive]` | `[path or —]` |

</output_format>

- With blockers or suggestions present, go to § 4.
- Otherwise complete [Record verified findings](../schemas/workflow-state.md#record-verified-findings) with the empty finding set, then go to § 5.

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
4. A check result's `repeats` entry is a candidate: a finding at a location where § 4 or § 7 recorded a decline, with each recorded description and reason. The same defect stays declined, and takes the write below with its recorded reason. Disposition a different defect like any other.
5. Every surviving blocker goes to the fix round. The fix round is blockers only.
   - A `category == "fix"` suggestion enters it only as a blocker, where Step 1 finds a defect this diff introduces or arms.
   - Decline every other `category == "fix"` suggestion by the write below, or track it for § 8 by the write of [review-cycle.md § Escalation](../references/review-cycle.md#escalation), with `reason` `fix suggestion outside the blockers-only fix round` and `outcome` `skipped`.

Record every decline, from this section or any disposition step, in one write per item. The write replaces an entry with the same location and description. `[SOURCE]` is `pr-review` here, and `qa-review` where § 7 follows this pattern:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"declined","drop":["declined"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"[ONE_LINE_REASON]","source":"[SOURCE]"}}'
```

### At The Cap

Before routing recurrence, read the verdict from [review-cycle.md § Review cap](../references/review-cycle.md#review-cap).
On `at-cap`, if review stops again on the part the last permitted round addressed, record the open defect once by [§ Escalation](../references/review-cycle.md#escalation), with `outcome` `skipped` and `reason` `same part at the review cap`. Leave it out of the fix set, including structural closes.
File the defect as one related issue through the project-management skill's `audit-issues --single` route, including for a recurring defect the diff introduces. Apply Step 0, the creation bar and duplicate checks. Run § 6's `orch-env PM_CREATE_AUTONOMY ask` read with `PM_CREATE_AUTONOMY=auto` for this single filing and execute its Auto branch.
In a lane, send the authorized single filing to the overseer by `lane-mail notice`. Carry back the created issue ID, the duplicate's `target` from TPM audit § 14, or the verified reason if the candidate fails the filing bar. Exclude this defect from § 8's audit and take the current head through the normal merge gates without another round or ruling for it.
A stop on a new part takes the existing recurrence and cap routes below.

**Recurrence before the cap.** [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) dispositions the remaining findings that share a root cause with one a prior round patched. No further patch round answers them. Each disposition owes one thing:

- A cause this diff introduces or arms takes `structural-close`: one item that names the generating surface in place of the site. It reaches the fix round whatever `rereview_cycles` reads.
- A cause this diff neither introduces nor arms takes the write of [review-cycle.md § Escalation](../references/review-cycle.md#escalation), its `reason` `recurrence outside this diff's authorship`, and § 8 files it.
- A cause `frozen_causes` names takes its one-line reason, and reaches § 8's declined report.

Separate the work the item's goal needs from separable work of another concern:

- Finish the first here.
- Give the second its own item, with its actual owner, in the same pass, through § 8's filing.

The **fix set** is what this section delegates: every item still standing after declines and tracking, plus every `structural-close`. At the cap it holds only those closes and the correction or cut the cap permits.

1. Apply [review-cycle.md § Review cap](../references/review-cycle.md#review-cap), including its correction and cut rules, to the remaining findings before routing.
2. Report the outstanding items it escalated.
3. A non-empty fix set goes to § Fix Delegation; an empty one goes to § 5.

### Fix Delegation

**Skip if** the fix set is empty.

A finding that leaves the fix set is never dropped. Decline it per [finding-disposition](../../reviewer/references/finding-disposition.md) when a cut removed its surface, or record it in `escalated_items` when § 8 is to file it.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"base","worktree":"[WORKTREE_PATH]","review_fix":true}'
```

**Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § Bounded Re-Review` with context `worktree`, `lifecycle: "managed"`, `dev_agent`, `issue_id`, `items` (the fix set, each formatted per [dev-round.md § Item text](../schemas/dev-round.md#item-text)), and `source: pr-review`.

### Bounded Re-Review

1. Take the correction route of [review-cycle.md § A fix round's own regression](../references/review-cycle.md#a-fix-rounds-own-regression) first.
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

The scoped panel is the reviewers whose domains the fix diff touches, the reviewers whose defect classes the round fixed (the blocker finders), and external review when available. A domain counts when the fix diff changes code or text that reviewer reads, not when the item's first diff did.

Record the panel through § 2.1 step 4's request file, with `external` set to the cycle's `EXTERNAL_REVIEW_REQUESTED` and, when false, `external_skip` set to its `EXTERNAL_SKIP_REASON`:

- The correction route writes `"panel":"verification"`.
- Every other entry writes `"panel":"rereview"`. Below the cap the write raises `rereview_cycles`, the count the cap reads. At the cap it records `verification_panel` and raises nothing, and the reply's `pointer` names the panel it wrote.

```json
{"op":"record-panel","panel":"rereview","agents":[PANEL_AGENTS_JSON],"reason":"[DOMAINS_TOUCHED] + blocker finders + external","external":[EXTERNAL_REVIEW_REQUESTED],"external_skip":"[EXTERNAL_SKIP_REASON]"}
```

A panel holding every `first_panel` reviewer adds `"domain_reasons": {"[AGENT]": "[WHY THE FIX DIFF CONCERNS THIS DOMAIN]", ...}`, one entry per `first_panel` reviewer.

**The loop ends** when two consecutive cycles surface no new blocker, at the cap-0 exit, or when the cap ends it.

- The cap bounds new cycles, never verification.
- A fix diff no reviewer has seen gets one focused verification pass, scoped to that diff. Past the cap the rereview write records it as `verification_panel`, which the cap does not gate.
- That pass's items re-enter § 4, where the fix set decides what still delegates.
- In wave mode the panel replaces `[AGENTS]` for the cycle, and the wave rules apply unchanged.

## 5. Verdict Pass

Shut the review agents down and clear their state. In wave mode the sessions are already retired, so this clears state only:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"cleared"}'
```

**QA routing.** One request reads the dev round's `qa_labels`. It scans the round's full diff for unsafe code, atomics, and paths matching `QA_PERF_PATHS` and `QA_UI_PATHS`. It applies the judgments in order, and writes `qa_decision` with the agent for each signal. Write `[WORKTREE_PATH]/tmp/qa-decision-[ISSUE_ID].json` with the harness file tool as `{"op": "record-qa-decision", "step": "scan", "worktree": "[WORKTREE_PATH]", "base": "origin/[BASE_BRANCH]", "judgments": []}`, then run it:

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

With the signals empty, go to § 7. Otherwise go to § 6.

## 6. QA Checks

**Skip if** the recorded `qa_decision.signals` is empty: go to § 7, which finds no QA artifact, converges and routes on. § 7 decides the exit even when QA never ran.

Delegate each recorded signal to the agent `qa_decision.agents` names for it, and wait. A project may override the mapping in its instructions.

- The `needs-ui-review` agent judges the screenshots the dev summary lists against the design-system doc `QA_UI_DESIGN_DOC` names.
  - Its delegation's Dev summary carries a Screenshots list: each changed view's set, as `.agents/skills/reviewer/references/ui-screenshots.md` § Screenshots defines it.
  - On a QA re-check, each view's entries come from the latest dev round whose summary lists that view: a fix round that recaptured it, else the implement round.
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
2. Accept each return through § 3.1's check. On `ok == true`, append the artifact path to `json_paths`, and carry its `repeats` to § 7.
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
3. Make one write per item. In one command it drops a superseded `fixed_items` entry and records the item. `[ARTIFACT_PATH]`, `[ARRAY]`, `[INDEX]` and `[KIND]` are as [review-cycle.md § Escalation](../references/review-cycle.md#escalation) sets them, and the reason is this exit's own:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"escalated","drop":["fixed"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"QA loop converged with the item unresolved","outcome":"blocked","source":"qa-review","kind":"[KIND]"}}'
```

## 8. Summary And Issue Audit

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {json_paths: (.json_paths // []), fixed: (.fixed_items // []), escalated: (.escalated_items // []), declined: (.declined_items // [])}' <<<"$STATE_READ"
```

1. With empty `json_paths`, report "No review items" and go to § 9.
2. Read every artifact.
   - Collect the `category == "issue"` suggestions, and deduplicate them by location and description, keeping the first and noting every source.
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
3. When nothing clears the bar, go to § 9.
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

- **`open-first`**: keep § 1's pending line, and write no verdict line. This review's fix rounds are still local, and the overseer must not approve or request Copilot on the head they replace. Record that this review returned. The record lets [submit-pr.md](submit-pr.md) § 2 run its triage, write this verdict once its push lands, and arm the pull request:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"open-first-returned"}'
  ```

- **`push-first`**: keep the pending review line until `[VERDICT]` is `pass`. The line holds the overseer's approval while submit-pr § 2 step 5 arms nothing. Only a `pass` records the return:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"push-first-returned"}'
  ```

  Submit-pr publishes the combined fixes, and settles each new head's Copilot request ([gates.md § Copilot requests](../references/gates.md#copilot-requests)) before it arms auto-merge.

- **Any other value, or absent**: in a lane whose brief names a status file, write the review line `Review: [VERDICT]`. Record no workflow state. A review-first lane, a re-submit review and a trivial-diff skip leave `pr_order` as they found it.

**Managed**: return to the parent workflow's next section. **Standalone**: the session is complete, and § 8 holds the summary.
