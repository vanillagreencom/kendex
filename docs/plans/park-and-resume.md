# Hosted-lane park and resume, end to end

A hosted lane parks while its pull request waits in the merge queue: its sandbox stops, it holds no running harness, and it wakes when GitHub reports something it must act on. On 2026-09-28 parking failed in four ways: a parked close completed an item that still owed a second pull request, resumed lanes ran past the 12-lane cap, a sandbox start failed on a transient provider error, and a resumed lane re-read its whole transcript and handed off again. The design below fixes each with one change: every park ends in a resume and the lane runs its own post-merge steps (KEN-2023), a parked lane keeps its fleet slot (KEN-2035), one start path treats the provider's transient error as still starting (FLT-417, landed), and a relaunch renders a fresh brief from the handoff record (KEN-1527). The admin merge, which GitHub now enforces through two rulesets, removes the park for every ordinary pull request, so parking remains only for the queue-only class; KEN-2037, the tooling mode once planned for that merge, is canceled. KEN-2031 removes the queue failures the pull request run never saw.

Design note, 2026-09-28. Evidence: the 2026-09-28 fleet log (`workflow-state get oversee '.fleet_log[-160:]'`, 07:49Z to 18:05Z, plus the entry at 07:31:33Z just before that window), `.agents/skills/orch/references/oversee-lanes.md` § Parking a merge wait and § Talking to a lane, `.agents/skills/orch/references/lane-directive.md` § Caps and § Recovery relaunch, `.agents/skills/orch/references/oversee-events.md` § Event kinds (merged, handoff) and § Judgement rules (Hand off a lane), `.agents/skills/orch/workflows/merge-pr.md` § 5, `lane-close --help`, `open-terminal --help` (--relaunch, --over-cap, --host), `/opt/fleet/bin/lane-host-daytona` help (stop-sandbox, start), the kendex rulesets 20569265 and 20569268 (`gh api repos/vanillagreencom/kendex/rulesets/ID`), and Linear KEN-1993, KEN-2031, KEN-2023, KEN-2037, KEN-1994, KEN-2004. Owner decisions applied: 1790616596 (the admin-merge rule), 1790622737 item 2 and 1790623442 item 1 (the actor and the tooling mode, both superseded), 1790633650 (the GitHub-enforced route, which cancels KEN-2037) and 1790634126 items 1 and 2 (the failure-1 model, and the queue-only class).

## 1. The model

A parked lane is a paused lane. Its harness is ended by signal, its sandbox is stopped with its disk kept, and its pull request waits for GitHub on its own. Where each piece of state lives:

- Sandbox disk (stopped, billed for storage only): the worktree and branch, the harness transcript, the lane's own workflow state and lock, `tmp/lane-status-ITEM.md`, the mailbox, the detached `queue-wait` job (dead with the stop), and every round record under `tmp/`.
- Fleet record (control VM, `tmp/` state under the overseer): `status: parked` with `{pr, head, repo, at}`, `mail_root`, `host`, `account`, `over_cap`; the window is gone. The record holds no working-lane slot (`lane-directive.md` § Caps counts `running` and `preparing` alone).
- GitHub: the branch, the PR, its arm or queue entry, its threads and the review gate. This is the only state that moves while the lane is parked, and the watch reads it through `merged` and the `pr-watch` reducer.
- Control VM worktree: none. A hosted lane's tree is on the sandbox. The control checkout only syncs its base after a merge.

Two paths end a park on 2026-09-28, and they disagree about who owns the post-merge work:

- `merged`: the watch closes the sandbox without starting it, and the overseer performs `merge-pr.md` § 5 steps 2 to 6 by hand from the control VM (tracker completion, container close, base sync, late threads, state removal), reading the cycle as `rounds-unread` because the lane's state went with the disk.
- a `pr-watch` line: the overseer resumes the lane through Recovery relaunch (`lane-host start`, then `create --relaunch`, native `claude --continue`), judged as a new lane against the cap.

### Wake causes

The owner asked how often a parked lane must wake at all. Wake causes that exist on 2026-09-28, each a line the reducer or the watch prints:

1. A conflict GitHub reports: the PR turns DIRTY after another merge (07:59:34Z PR 3056, 14:41:28Z PR 3072, 14:58:33Z PR 3073, 15:10:30Z PR 3076, 15:35:47Z PR 3075).
2. A further PR the item owes: a split item whose lane must continue after the first merge (KEN-1935 at 15:13:17Z and 15:35:47Z; KEN-2003 was kept running for this reason at 11:13:13Z).
3. A review thread after arming: `threads-open`, `changes-requested`, `suppressed-findings` on a PR the lane armed and then parked on (12:23:59Z KEN-2007 park refused on a late Copilot thread).
4. A queue failure: an ejection by a merge-group run the PR run never ran (macOS shards, Bot instructions, the 30-minute job cap: 13:59:22Z PR 3062, 16:10:52Z PR 3077), a flaky test (09:18:50Z PR 3059), or a removal with no reason (14:39:01Z PR 3061).

What each of the three changes deletes:

| Change | Deletes | Leaves |
|---|---|---|
| KEN-1993 (Done): arm at creation, rebase only on a GitHub conflict | the arm-now directives (10:23:53Z, two in one pass) and every non-conflict restack; the lane parks earlier, at queue entry | causes 1, 3, 4 unchanged; cause 3 slightly wider, since the arm stands longer |
| Admin merge (owner decision 1790616596, 17:34:19Z; route settled by owner decision 1790633650, § 3 Admin merge route): a PR green at its current head merges with `gh pr merge N --squash --admin`, and GitHub refuses it otherwise; the queue keeps the queue-only class, derived from the paths the change touches | the park itself for every ordinary PR: the lane is up in its CI and gate waits, which are never parked, and the PR merges the moment they pass (17:34:11Z: PRs 3074 and 3072 merged from queue position 1). With no queue wait there is no conflict window and no group run, so causes 1 and 4 vanish for that class | parking, and causes 1, 3 and 4, for the queue-only class alone |
| KEN-2031 (Backlog): the PR run runs every merge-group job for touched paths | cause 4 as seen on 2026-09-28, since a green PR is green in the queue (51 of 150 merge-group Skill Tests runs failed, window 2026-09-27 17:00Z to 2026-09-28 18:00Z, [ci-targets.md § Merge-group runs](ci-targets.md#merge-group-runs)); it also removes the "run skipped a touched shard" entry from the queue-only class | flake ejections |

Answer: with all three in place a parked lane exists only for a queue-only PR, and it wakes for a conflict, a flake ejection or a late thread. The 2026-09-28 numbers (10:07:52Z ruling: 5 merges while parked, 5 ejections resumed in 5 to 11 minutes) describe the ordinary class, which stops parking. Cause 2 is not a wake cause at all. It is the reason the `merged` path must not close the lane, which is failure 1 below.

## 2. The four failures of 2026-09-28

### Failure 1: parked close of an item that owed a PR

Cause (15:13:17Z, corrected 15:35:47Z): the `merged` path closes the sandbox and the overseer completes the item, and nothing reads whether the lane had work left after its merge; KEN-1935's split lived only in its status file and brief. The `merged` and `pr-watch` paths disagree about who owns the post-merge, and the overseer's copy of steps 2 to 6 is where the error sits.

One fix, adopted by owner decision 1790634126 item 1: a merged park resumes the lane, which runs its own post-merge; the overseer completes nothing. `merged` ends a park the same way a `pr-watch` line does. The watch starts the sandbox and resumes the lane; the lane's own `queue-wait` reads the verdict `merged` and runs `merge-pr.md` § 5 steps 2 to 6 itself, then continues its split or closes itself out, and `lane-close` closes it as an exited, terminal lane. The one rule: every park ends in a resume, and the lane is the only owner of its post-merge, which `merge-pr.md` § 5 step 2 already states ("the overseer does not substitute for it"). The cost, one sandbox start per merged park, falls on the queue-only class alone now that the admin merge is on.

What it deletes: the watch's close-on-merged for parked records (`oversee-watch::check_merged` calling `close_hosted_lane`); the overseer's steps 2 to 6 block, the `rounds-unread` construction and the `item-files-kept cause=open` removal step in `oversee-events.md` § Event kinds (`merged`) and `oversee-lanes.md` § Parking a merge wait; the `owes_pr` flag, the refused park on a further PR and the `item-open cause=further-pr` event that KEN-2023's first branch added, which become unnecessary; the "a lane with work after its merge is not parked" rule the overseer had to apply by reading (11:13:13Z).

### Failure 2: resumes past the 12-lane cap

Cause: a parked record holds no slot, so the fleet filled to 12 running while lanes sat parked (08:00:15Z: 12 run plus 2 parked; 13:46:55Z: 8 run plus 10 parked). Every resume then met `cap-reached` and the overseer admitted it with `--over-cap` (08:04:24Z two resumes over cap; 14:39:01Z, 14:41:28Z, 14:58:33Z, 15:10:30Z; 15:39:59Z: "the excess is parked lanes resumed with --over-cap after merge-queue churn, six dequeues 14:32Z to 15:28Z"). The cap then bounded nothing: 14 lanes ran at 09:05:00Z, 09:56:49Z, 10:52:09Z, 11:31:51Z and 15:35:47Z.

One fix: a parked lane keeps its slot. `lane-cap.sh` counts `parked` beside `running` and `preparing` against `ORCH_OVERSEER_LANES`, so the cap bounds items in flight, which is what the overseer already treats it as, and a resume never adds a lane.

What it deletes: the sentence in `lane-directive.md` § Recovery relaunch and in `open-terminal --help` § `--relaunch` that a parked relaunch "is judged as adding a lane and meets cap-reached"; `--over-cap` on every resume, so `over_cap` is written only for a deliberate launch such as the release at 17:53:56Z; the overseer's counting of "N run plus M parked" in every ruling.

### Failure 3: the Daytona sandbox start error on a resume

Evidence in the window read: 07:31:33Z, KEN-1969, the watch's merged close failed once because the start of the stopped sandbox exceeded 180 s with Daytona in `state=error` and the provider advising `--force`; 8 minutes later the sandbox read started and a plain close finished. The 131 s reading named in the brief is not in the 160 entries read; the entry above is the same failure. The fleet peer directive at 10:30:18Z (FLT-417 park-path protocol: `stop-sandbox-refused`, `--force`, `close-parked`, `start-failed fix=`) is the provider side of it.

Cause: the provider's `start` waits to a fixed ceiling and reports Daytona's transient `error` state as a failed start, while the sandbox is still coming up. Two callers then act on it differently: the watch's close and the launcher's resume, each with its own retry.

One fix: one start path. With failure 1 fixed, only a resume ever starts a parked sandbox, and the contract is already right for it: the record stays `parked` on `host-start-failed`, and the next watch pass re-issues the same resume because the `merged` or `pr-watch` line still stands. The provider verb polls Daytona to `started` within a bound it states, prints `sandbox-started` once it reads it, refuses `start-failed` otherwise, and never advises `--force` on a resume. The fleet landed this as FLT-417 (fleet 064a955, PR 482, 2026-09-28 14:07Z, installed on the control VM); the kendex side is the retry contract above.

What it deletes: the "close starts a stopped sandbox first" step the watch depended on, the `--force` advice on a resume, and the second retry loop in the watch's close.

### Failure 4: native resume of a lane that handed off

Cause (14:51:11Z, then 14:56:27Z): the lane handed off at its context mark (407k tokens) and the overseer used Recovery relaunch, a native `claude --continue`, which reloads the whole transcript; the lane's first turn end read 403k and the turn-end hook refused it again. The overseer then launched a fresh session by hand with `--relaunch --cmd tmp/brief-2004-fresh.md`, and `lane-close --keep-sandbox` refused `pane-ambiguous` over the two idle sessions. `oversee-events.md` § handoff already says such a lane "is relaunched per that event, not resumed", but § Judgement rules, Hand off a lane, points that relaunch at Recovery relaunch, which is the native resume. Four hand-written fresh briefs on 2026-09-28 (KEN-1993 11:21:18Z, KEN-1982 11:31:51Z, KEN-2004 14:56:27Z, KEN-1987 16:52:39Z) are the overseer applying the rule by hand. A park resume near the mark meets the same edge.

One fix: `open-terminal --relaunch` reads the item's standing handoff record and, where one stands, renders the start brief from it (merged, remaining, branch, open PR, traps) instead of `--continue`; with no record it resumes natively. The launcher makes the choice, never the overseer.

What it deletes: the hand-written `tmp/brief-ITEM-fresh.md` files and the `--relaunch --cmd` form for handoffs; the 14:56:27Z rule "after a lane handoff, close its window before the relaunch" and the `lane-close --keep-sandbox` step before a fresh launch; the contradiction between the two `oversee-events.md` passages.

## 3. What the end-to-end design deletes

- The watch's close-on-merged for parked records and the overseer's hand copy of `merge-pr.md` § 5 steps 2 to 6, with `rounds-unread` and `item-files-kept cause=open`.
- KEN-2023's first-branch `owes_pr` flag, its refused park on a further PR and its `item-open cause=further-pr` event.
- `--over-cap` on resumes and the "parked relaunch adds a lane" rule; `over_cap` stays for a deliberate launch only.
- The second sandbox start path (start for a close) and the `--force` advice on a resume.
- The overseer's choice between native resume and fresh brief, the hand-written fresh briefs, and the close-window-before-relaunch rule.
- Under the admin merge: the park for every ordinary PR, the `still_progressing` queue-wait repeats for that class, and the arm-now directives (already gone under KEN-1993).
- Under KEN-2031: the "run skipped a touched shard" entry in the queue-only class.

What stays: `lane-close --park` as the one park judge; the watch's `merged` and `pr-watch` events as the only things that end a park; native resume on the kept disk; `lane-close` as the close of an exited, terminal lane; KEN-1994's silent drop of the park race lines (09:27:22Z, 09:56:49Z, 15:58:45Z, 16:07:59Z, 16:09:41Z, 16:52:39Z all name it).

### Admin merge route

Owner decision 1790633650 settles which token is the bypass actor and supersedes the overseer-only reading of 1790622737 item 2 and the `pr-merge.sh` admin mode of 1790623442 item 1. GitHub itself enforces the admin merge. The ruleset the lanes app bypasses, kendex 20569265, holds only `merge_queue`. The required status checks (the `Review gate` and the CI jobs), review-thread resolution, `deletion` and `non_fast_forward` sit in the zero-bypass ruleset 20569268. An admin merge therefore skips only the queue: any holder of the lanes identity, a lane or the overseer, merges a green PR with `gh pr merge N --squash --admin`, and GitHub refuses it unless the PR is green at its current head. A push after the check resets the checks, so GitHub also binds the merge to the head. The lane merges itself at green and never parks on an ordinary PR, and its own `merge-pr.md` § 5 runs the post-merge.

KEN-2037, which was to add an admin mode to `pr-merge.sh` bound to the verified head, is canceled on owner decision 1790633650: GitHub enforces those conditions, so no tooling mode is needed. The decision record for the route is D011, which KEN-2023's PR 3104 carries and rewords to name the GitHub-enforced route.

The queue-only class, the PRs that still enter the merge queue and may still park, is derived from the paths the change touches, not from judgement (owner decision 1790634126): a change to CI, a ruleset input or the shared test harness, and, until KEN-2031 lands, a PR whose PR run skipped a shard its touched paths select (owner decision 1790634126 item 2).

## 4. Item map

| Fix | Carried by | Note |
|---|---|---|
| Fewer wakes: arm at creation, rebase only on conflict | KEN-1993 (Done) | landed |
| Cause 4 gone; the skipped-shard entry of the queue-only class gone | KEN-2031 (Backlog, P1) | first among the CI items (owner decision 1790634126 item 2); scope adds splitting the guards-tools macOS shard so PR checks approach 10 minutes |
| Failure 1: `merged` resumes the lane, the lane owns its post-merge | KEN-2023 (In Review, PR 3104) | Done-when rewritten on owner decision 1790634126 item 1: on the merge of a parked PR the watch resumes the lane from its kept sandbox, the lane runs `merge-pr.md` § 5 steps 2 to 6 and § 6 itself, and the overseer completes nothing; `owes_pr` and `item-open cause=further-pr` leave the branch; D011 names the GitHub-enforced admin merge |
| Park race lines | KEN-1994 (Backlog) | as written; unchanged by this design |
| Failure 3: one start path, transient error is still starting | FLT-417 (fleet, Done 14:07Z) | landed; refusal named `start-failed` |
| Failure 4: relaunch renders the brief from the handoff record | KEN-1527 (Backlog, P1) | KEN-2036 filed then folded into KEN-1527, 2026-09-28 |
| Failure 2: a parked lane keeps its fleet slot | KEN-2035 (Backlog, P1) | filed 2026-09-28 |
| Admin merge by a tooling mode bound to the verified head | KEN-2037 (Canceled) | canceled on owner decision 1790633650: GitHub enforces the conditions (§ 3 Admin merge route) |
| Pi turn-end hold | KEN-2004 (In Review) | as written; failure 4 is not in its scope |

Items filed from the gaps on 2026-09-28, as specified below:

- KEN-1527 (KEN-2036 folded into it), open-terminal: a relaunch of an item whose handoff record stands renders the start brief from that record and never `--continue`. Done when: such a relaunch opens a fresh session carrying the record's remaining steps, a relaunch with no record resumes natively, and a must-fail control shows the native resume without the change.
- KEN-2035, open-terminal: a parked lane keeps its fleet slot. Done when: `lane-cap.sh` counts `parked` records against `ORCH_OVERSEER_LANES`, a parked resume never meets `cap-reached`, and `over_cap` is not written on a resume.
- KEN-2037, merge-pr: canceled on owner decision 1790633650. Its spec, a `pr-merge` mode that merges a green ordinary-class PR as the bypass actor, is replaced by the GitHub-enforced route in § 3 Admin merge route, and the decision record it asked for is D011 on KEN-2023.
