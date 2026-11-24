# Review cycle

The contracts of the review cycle that [review-pr.md](../workflows/review-pr.md) runs and other workflows cite. Each section says when to read it. A bare § names a section of this file. A section of review-pr.md is named with its path. Every contract keeps review-pr.md's bindings, among them `[ISSUE_ID]`, `[WORKTREE_PATH]`, `[AGENTS]`, `OUTSTANDING`, the fix set and the review round token.

## Review cap

Read when review-pr.md § 4 or its § Bounded Re-Review applies the cap, or when another workflow states its own fix-round bound.

`REVIEW_MAX_CYCLES` bounds the fix rounds of ordinary items.

- [settings.md § Review and CI](settings.md#review-and-ci) states what `0` and `1` allow. For the default, see `load` in [the orch runtime settings](../runtime/src/settings.rs).
- A project setting raises it for a standard item.
- [small.md](../workflows/small.md) holds a small item to 1, and micro runs none.

The cap decides before any delegation:

```bash
.agents/skills/orch/scripts/orch-runtime state cap REVIEW_MAX_CYCLES --item [ISSUE_ID]
```

Apply § A fix round's own regression before you act on the reply's `verdict`.

- `below`: escalate nothing for the cap. The fix set stands as review-pr.md § 4 built it.
- `at-cap`: the fix loop ends here, apart from the fix set's `structural-close` items and the correction or cut that § A fix round's own regression permits. A cap is a ruling point, never the end of work the goal needs.
  1. Escalate the outstanding items by § Escalation, and name them in the lane status.
  2. Another fix round starts only once the overseer has ruled and recorded one `ruling` row for the item in the fleet log ([oversee-events.md § Judgement rules](oversee-events.md#judgement-rules)). The overseer judges with the reply's `count` and `limit`. The ruling names the separated items.

### A fix round's own regression

A blocker in lines the last fix round wrote (`pre_delegate_sha` to HEAD), which no earlier review reported, gets one correction past the cap per pull request.

1. Read the round files `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` named by the `round_id` of each `dev` stage, rounds from other review paths included.
   - A `Correction: own-regression [BOUNDARY_SHA]` line in an `items[].text` means this pull request has spent its correction.
   - An unmarked round, a cap-zero or `structural-close` round included, spends none.
2. With no correction recorded, add these blockers to the fix set.
   - Keep the new batch's boundary, the worktree's HEAD, before review-pr.md § Fix Delegation overwrites `pre_delegate_sha`.
   - Append the correction line to each correction item's text.
   - Every domain group delegated carries the same boundary and counts as one correction.
   - Complete the whole batch before re-review.
3. review-pr.md § Bounded Re-Review finds that batch by the correction boundary matching `pre_delegate_sha`. It takes `verification_panel` before its cap-zero exit.
4. A later such blocker in the same pull request ends the fix rounds, even below the cap.
   - Where the Done-when does not need its code, add a cut item to the fix set.
   - Otherwise escalate it by § Escalation, and name it in the lane status for the overseer's [design review](design-review.md).
   - On this terminal pass, act as at the cap. Keep only structural-close and cut items in the fix set, and escalate every other outstanding blocker.

### Escalation

A capped item is escalated, never dropped. review-pr.md § 4 and § 7 also use this write for the items they track.

1. Record every blocker this pass found still outstanding, and every suggestion review-pr.md § 4 made one. A `fixed_items` entry whose fix did not hold is included.
2. Leave out only what `escalated_items` holds, what review-pr.md § 4 declined, and the fix set's `structural-close`, correction and cut items. A decline is terminal.
3. Make one write per item, before review-pr.md § Fix Delegation or § 5. In one command the write drops a superseded `fixed_items` entry with the same location and description and records the item, so the item never stands in both buckets or in neither:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-disposition","into":"escalated","drop":["fixed"],"file":"[ARTIFACT_PATH]","element":"/[ARRAY]/[INDEX]","fields":{"reason":"outstanding at the review cycle cap","outcome":"blocked","source":"[SOURCE]","kind":"[KIND]"}}'
```

- `[ARTIFACT_PATH]` is the `json_paths` entry the item came from.
- `[ARRAY]` is `blockers` or `suggestions`, and `[INDEX]` is the item's position there.
- Type only a path, an array name, an integer and the one `[KIND]` word.
- `[KIND]` is `regression-against-main` for a blocker that breaks behaviour the base branch has, and empty for every other item.
- `[SOURCE]` is `pr-review`, or `qa-review` for a QA item that reached this rule through review-pr.md § 7.
- review-pr.md § 8 reports these items as escalated, and takes each one's agent and priority from its artifact.

## Reviewer wait

Read when review-pr.md § 3.2 arms a wake source for an incomplete agent, or acts on a wake.

### Wake source

Arm one check per agent:

```bash
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --worktree [WORKTREE_PATH] --agent [AGENT] --delegated-at [REVIEW_DELEGATED_AT] --wait [SECS] --issue [ISSUE_ID]
```

1. Run it where its exit wakes this session. [artifact-checks.md § Round-closure mechanics](artifact-checks.md#round-closure-mechanics) names the route per harness. On Codex, use [codex-runtime.md § Reviewer round wait](codex-runtime.md#reviewer-round-wait).
2. `[SECS]` ends at the earliest pending row of § Deadline actions, or at the agent's deadline when no earlier row remains. The external lane uses review-pr.md § 2.2's `wait:` command.
3. Arm with the delegation batch, and re-arm after every action, a ping included. A promised completion extends nothing until re-armed.
4. After an artifact rejection (review-pr.md § 3.1), set `[REVIEW_DELEGATED_AT]` strictly above the rejected artifact's modification time.
   - On a continuation this is a stricter boundary for that assignment's check alone, never a write to the batch boundary.
   - The glob watchdog only wakes the session. § Continuation recheck decides continuation acceptance.

### Wake source replacement

Replace a wake source that ends without a verdict, once, at once.

- A verdict prints on stdout at exit 0 (accepted) or 1 (rejected).
- A keyed refusal exits 2 with its `review-artifact:` line on stderr. That, or any other status, leaves the agent's deadlines unarmed.
- If the replacement also ends without a verdict, stop and report an environment failure with its status and any keyed line.
- Never arm a third source, and never mark the reviewer `unresponsive` for this failure.

### Deadlines

Sweep the filesystem on every wake. Each agent's deadline runs from `review_delegated_at`, or from § Continuation clocks:

- 25 minutes for an agent whose name contains `perf`.
- 36 minutes for `reviewer-test`: one [`mutation-stability`](../../reviewer/scripts/mutation-stability) run at the defaults its `--help` prints, plus 5 minutes.
- 15 minutes for every other agent.
- The external lane's printed deadline, in absolute Unix epoch seconds, compared with `date +%s`.
  - With no deadline printed, use 2 × `SECOND_OPINION_TIMEOUT` plus 3 minutes. `second-opinion --help` prints the timeout's default.
  - The external lane is no messageable agent, so the ping rows never apply to it.

### Active required measurement

1. A responsive reviewer running the [reviewer skill's Mutation-Stability Pairing](../../reviewer/SKILL.md#mutation-stability-pairing) gets the `reviewer-test` deadline, whatever its name, when its status reply identifies the active required measurement job.
2. Apply it before the post-ping and per-agent rows, anchored to the original delegation clock. A reply restarts no clock.
3. Re-arm the wake source for it.
4. A promise with no active required job keeps the agent's usual deadline.
5. Completion still needs review-pr.md § 3.1's validated artifact.

### Deadline actions

| Event | Action |
|-------|--------|
| A return arrives | Run review-pr.md § 3.1's artifact check |
| 2 min after the first return, or 10 min from delegation with no return; once per cycle (wave mode: per wave) | Ping each outstanding agent once, the external lane exempt: `Status check on [ISSUE_ID] review: return your verdict if complete. If incomplete, report the blocker and identify any active required Mutation-Stability Pairing job.` |
| 2 min after that ping | Mark each agent still outstanding `unresponsive`, except a perf agent, `reviewer-test`, a responsive reviewer with an active required measurement, and the external lane |
| The agent's deadline in § Deadlines | Mark that agent or lane `unresponsive` |

Wave mode also shuts an `unresponsive` reviewer down and records it, so its slot frees and it does not relaunch this cycle:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","agent":"[AGENT]"}'
```

## Process-owned review

Read when review-pr.md runs a required domain as a process-owned Codex reviewer, on the `alternate-review` verdict. [codex-runtime.md § Process-owned reviewers](codex-runtime.md#process-owned-reviewers) owns the launch command and the job lifetime. This section holds the admission, completion, replacement and liveness rules for each process.

### Process launch admission

Every process-owned launch enters here immediately before its runtime launch command. That covers an initial, later or continuation wave, and the one replacement § Process-owned replacement allows. Run it from the worktree:

```bash
.agents/skills/orch/scripts/orch-runtime admission --item [ISSUE_ID] --checkpoint
```

1. Only `room` launches the selected process through codex-runtime.md.
2. `due` takes § Handoff on `due` with this latest `decision` and `source`, and starts no process.
3. A refusal starts nothing and reports its cause. A denied launch keeps a never-launched domain unlaunched and starts no clock.
4. Re-entering admission starts no fresh batch and repeats no external detection. Keep the full panel, the exact assignment, the concrete head and range, the original token and evidence boundary, the accepted-file rechecks and the spent allowances.
5. Record an actual first delegation only once the runner confirms the job started. A replacement keeps its original clock and rejection boundary.

### Process-owned completion

1. Collect every process return, the first included, with codex-runtime.md's process collection command. It reads the recorded job exit before the exact assigned-file check.
2. Read the job log beside the result.
3. An empty exit file is unfinished, never a return.
4. A nonzero exit or a confirmed interruption supplies no accepted review, even when a JSON file exists.
   - Keep its evidence unread.
   - Take § Process-owned replacement and the deadline rules.
   - Never substitute an external opinion.
5. A zero exit still needs the exact assigned artifact to validate. The last-message file alone supplies no acceptance.

### Process-owned replacement

1. A terminal failure or a rejected artifact is an incomplete return.
2. Its one re-delegation passes through § Process launch admission.
3. It starts a fresh job only once the previous process is terminal, with the same canonical role and complete delegation, the exact assigned artifact and § Wake source step 4's rejection boundary.
4. It returns to review-pr.md § 3.1 as the same attempted assignment, never a never-launched domain. It keeps the original first-delegation time, deadline and spent allowance.
5. A process has no message channel: record that limit in place of a ping.
6. A failed replacement or an exhausted deadline marks the domain `unresponsive`.

### Process liveness

1. A process-owned domain keeps the same artifact watchdog and exact-file acceptance.
2. Read its recorded job completion and log on each sweep through the runner's owners.
3. A process has no chat or child-wait target. The ping rows of § Deadline actions apply only to messageable attached agents, and the process keeps its per-domain deadline.
4. A never-launched domain's clock starts at its actual first delegation.
5. An attempted domain, a retry or a continuation keeps its original clock and spent allowance, and a fresh process never resets them.
6. Job evidence of an active required measurement earns § Active required measurement; a promise does not.
7. At its terminal deadline, stop the process through [job-units.md § Stopping](job-units.md#stopping) before any allowed replacement.
8. Carry every attempt and failure forward.

## Handoff on `due`

Read when an admission answers `due`. It does so when the session is past its plain mark, compacted, or cannot prove room for the returns. review-pr.md § 2's pre-panel admission and § Process launch admission both send that verdict here.

1. Keep the returned `decision` and `source` as the handoff's `context`. An unavailable decision stays unknown. Set `REVIEWER_SLOTS=0`.
2. Bind `git -C [WORKTREE_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`.
3. Checkpoint the committed head through the branch-publication owner. Write `[WORKTREE_PATH]/tmp/checkpoint-push-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "checkpoint", "worktree": "[WORKTREE_PATH]", "args": ["--set-upstream"]}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/checkpoint-push-[ISSUE_ID].json
   ```

   Route its exit and reply as [merge-pr-restack.md](../workflows/merge-pr-restack.md) step 3 routes the branch push.

4. Compare HEAD with `[BOUND_HEAD]`. If it moved, apply [Rules reload after a rebase](../SKILL.md#the-cycle) at once, after a failed transport too.
5. A failed checkpoint starts no panel and records no publication.
6. Copy the batch's assignment facts into the handoff by § Original-batch continuation step 1.
7. Record the published head in the handoff under [oversee-events.md § Hand off a lane before it runs out](oversee-events.md#hand-off-a-lane-before-it-runs-out).
8. Before retirement, collect the attached and external returns already available through review-pr.md § 3's checks.
   - Record every other return as unread, with only its known assignment, job, output path, wake, deadline and survival facts.
   - An unknown external outcome or liveness stays unread. Invent no wait target or result, and launch no duplicate job.
   - Preserve each process-owned assignment with its exact job directory, runner record, exit, log and artifact paths, deadline and known survival facts. Its existing job and artifact owners collect it on recovery.
9. Base delivery waits for the successor's completed review.
10. The successor re-enters review-pr.md § 2's admission, then applies § Original-batch continuation.

## Original-batch continuation

Read step 1 when a lane hands off by § Handoff on `due`. Read the other steps when a successor resumes a handed-off review at review-pr.md § 2. A proved continuation is a successor's resumed review whose copied facts pass step 2. review-pr.md's steps name what a proved continuation keeps.

1. Before handoff, copy the owning workflow's known assignment facts into the handoff's existing `remaining` and `traps` prose:
   - item, worktree, branch and pull request;
   - published and reviewed head, and the concrete range endpoints;
   - the full required panel and its reason, and the external request;
   - the original `review_round_id` and `review_delegated_at`;
   - each assigned canonical domain's exact artifact path, and its accepted or attempted disposition;
   - the domains never launched;
   - actual first-delegation times, deadlines, ping and re-delegation history, and the existing return and wake owners.

   Keep the handoff's fixed shape with the admission's `context`, and add no state key.

2. On resume, prove that the copied facts describe the same original batch, an unchanged published and current head, and the same concrete scope.
   - `json_paths` and `review_wave_done` alone prove no assignment or acceptance.
   - Missing provenance, a different current batch, or a changed head or scope means no reuse. Then keep the historical evidence and run an ordinary fresh review under admission.
   - Never rebuild a range from today's symbolic base, and never attach today's round token to an old report.
3. A proved continuation keeps its original `review_round_id`, stage and `review_delegated_at` throughout, § Continuation recheck included.
4. Revalidate through § Continuation recheck only the exact previously accepted files assigned to this batch.
   - Keep the full required `[AGENTS]` panel apart from the launch subset.
   - Subtract revalidated accepted domains from delegation only, and carry their findings, repeats and measurement declarations into normal handling.
5. An attempted domain keeps its job owner, deadlines, rejection and re-delegation history and execution outcome.
   - It gets no duplicate launch and no restarted allowance.
   - A resolved `unresponsive` domain stays unresponsive, never accepted.
   - Only unread domains proved never launched enter the launch subset.
6. If the preserved facts or admission cannot support this route, stop and report the exact limitation.
7. A handoff resets no counter, validation receipt, finding, disposition or failure history, and starts no validation replay of an unchanged tree.

### Continuation recheck

A proved continuation checks the preserved assigned path, under the original token, stage and evidence boundary:

```bash
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --file [ASSIGNED_ARTIFACT_PATH] --worktree [WORKTREE_PATH] --delegated-at [ORIGINAL_REVIEW_DELEGATED_AT] --issue [ISSUE_ID]
```

1. Match `artifact.agent` to the preserved canonical assignment and the required panel.
2. Reuse only an `ok == true` result. Missing, invalid, stale, `no_review` or `moving_tree` evidence supplies no completion.
3. A failed recheck of an accepted file ends reuse. Run an ordinary fresh review, and keep the rejection and its history.
4. Never select a sibling file, touch an old file, lower or omit the boundary, or mint a receipt.
   - An unfinished assigned return keeps any stricter rejection boundary § Wake source step 4 requires.
   - The batch boundary does not move.
5. A path already recorded as accepted appends no second entry. Carry its findings, repeats and `valid_undermeasured` declarations through review-pr.md § 3.1's handling.

### Continuation clocks

1. Keep the batch's evidence boundary for accepted-file rechecks.
2. A never-launched domain's clock starts at its actual first delegation. § Original-batch continuation step 1 copies it into `remaining` and `traps` on any later handoff. Use it for the ping, post-ping, per-agent and measurement deadlines, never the older batch time.
3. An attempted domain keeps its original clocks, spent ping and re-delegation history and wake owner.
4. A resumed session restarts none of them.
