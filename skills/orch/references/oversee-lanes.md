# Oversee lanes

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) to park a hosted lane's merge wait, or to answer, direct, wake, paste into or resume a lane.

## Parking a merge wait

A hosted lane whose pull request is armed or queued and waiting for the merge queue does nothing but wait, and its sandbox bills for every minute of it. Park it: end the harness and stop the sandbox, keep its disk and record, and let the watch carry the pull request to its merge. `lane-close --park --pr [PR_NUMBER] [ITEM_KEY]` is the whole verb, run with `--state-dir [OVERSEE_STATE_DIR]` like every close, and it is the one judge of whether the lane may go: it reads the record's provider, the pull request from GitHub and the review-gate reducer before it signals anything, and refuses as `park-refused` naming the condition it stopped on. The provider is read first, through `lane-host stop-sandbox --check`, which changes nothing: a provider without the `stop-sandbox` and `start` pair answers the absent-verb status, `lane-host-ssh` among them, and the park refuses as `provider-unsupported` with no GitHub call and no signal, so on such a fleet the verb ends no lane. Then the pull request: it refuses when the pull request is not open, is not the item's branch, is neither in the merge queue nor auto-merge armed, or, armed and outside the queue, reads any `mergeStateStatus` but `CLEAN`, GitHub's word for every required check green on the current head and nothing else blocking; a queued pull request is admitted on the queue's own admission, since GitHub queues nothing before every required check is green on its head, and its arm has converted to the queue entry by then, so `autoMergeRequest` reads null for the whole wait. Last the reducer, `pr-watch.sh` as `OVERSEE_WATCH_PR_WATCH` names it: an attention line refuses, and its silence is no thread open, no objection and no `disarmed` or `awaiting-stale` line (`pr-watch.sh --help` holds the exact condition). Silence is no proof of approval, since an unapproved pull request inside its quiet period is silent too: `CLEAN` proves the approval the base requires for an armed pull request, and the queue's admission for a queued one. A lane inside a CI or review wait after a push meets one of those and is never parked; run the verb, never a reading of your own. The provider's `stop-sandbox` follows the harness stop and the window kill, and only its `sandbox-stopped` line records the lane `parked`, with `{pr, head, repo, at}`; a stop the provider refuses leaves the record `stopped`, `--keep-sandbox`'s truthful state, under `park-failed`, and a plain Recovery relaunch or a second `--park` recovers it (`lane-close --help`).

When to run it: at a `heartbeat` pass, for each hosted `running` lane whose open pull request the pass's open-PR list names and whose reducer lines name nothing, once the lane's status file ([oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads)) puts it in `merge-pr.md` § 5 step 1's queue wait. Those open-PR lines carry repo, number, branch and title and no arm or queue state: the verb's own read is the only judge of queued or armed and `CLEAN`, and its refusal is the answer where the lane is not ready. What a refusal costs: on a provider without the pair, the check alone and no GitHub call, so one run says the fleet parks nothing; at GitHub's own state, the check, one `gh pr view` and one queue read, plus a `gh repo view` for a record naming no repository; only a pull request that reads queued, or armed and `CLEAN`, reaches the reducer, which reads its threads and its review decision.

What a parked lane keeps: its record, its `mail_root` and PR-watch rows, and its disk, with the harness transcript, the mailbox and its `tmp`. What it gives up: its window, its pane reads and its mail pass, since the disk is stopped. It keeps its fleet slot: `open-terminal` counts `running`, `preparing` and `parked` records against `ORCH_OVERSEER_LANES`, so the cap bounds items in flight and a resume never adds a lane ([lane-directive.md § Caps](lane-directive.md#caps)). The [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) watch carries a parked record for its merged check, terminal close and `lane-long` age and names the count as `parked=` in its `fleet-read` note; `oversee-report` lists it under Running with the pull request its record names and reads nothing from its disk.

What ends a park, each per [oversee-events.md § Event kinds](oversee-events.md#event-kinds):

- `merged` of the pull request the parked record names, in that repository: [oversee-events.md](oversee-events.md#event-kinds) defines terminal close and open-item resume. The watch records the cycle before closing a Done or Canceled item. It prints `parked-merged` only for an open item that needs its lane to finish post-merge work. Another pull request merged on the branch name gets a merge event without a resume.
- A `pr-watch` line on the parked pull request, `threads-open`, `changes-requested`, `disarmed`, `awaiting-stale`, `head-moved` or `error`: the lane is needed again. `disarmed` is also how a dequeue nothing else reported reads, since the reducer prints it for an approved pull request neither queued nor armed, so the queue needs no other reading, and a parked pull request the heartbeat still lists open with no reducer line stays parked. Resume it through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch): the launcher starts the sandbox first, rewrites the record `stopped` once the provider confirms the start, and resumes the harness on its kept disk; a start the provider does not confirm is `host-start-failed` with the record still parked, never a resumed lane, and a create that fails after the start leaves the stopped record, which a plain relaunch recovers. A resumed lane that opens on no transcript to continue is a blocker to report, not a resume.

## Talking to a lane

Answering and directing are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host, and `--root [MAIL_ROOT]` alone, run from a checkout of that repository, for a local lane whose `mail_root` is another repository's worktree.

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). The `--state-dir` send reads the lane's record and matches the `channel` its host kind declares, and refuses as `lane-unrecorded` where that state holds no record for the lane; a lane with no record, one the watch carries from `--item` alone, takes the same send with no `--state-dir`. A `session` lane, a Claude cloud session, takes a directive alone, queued into its session; the receipt is `{ok: true}` and no `directive-read` follows, so the lane's next push or `## Lane status` shows it acted, and a session that does not act shows as `lane-stalled`. `--re` and `--halt` refuse there, `session-archived` is a session the operator archived, and `session-send-failed` carries the CLI's own words. A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](skill-rules.md) says when each reaches it. Wake the lane after the send where [watch-delivery.md](watch-delivery.md#lane-mailbox-monitor) says. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host, run from the checkout the send used, because the wake resolves the lane's tree from the caller's own project; it wakes a lane only when the shared judge calls it `idle`, and refuses any other state as `wake-refused reason=[STATE]`. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] --state-dir [OVERSEE_STATE_DIR] [ISSUE_ID]
```

After a directive, wait for the watch's `directive-read` for its id: the lane's own mailbox cursor passing it, whichever read path moved it, on every harness and on a hosted lane. Never read a pane to confirm a delivery. `directive-unread` is the directive still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: wake the lane, reach it by Pane paste, or relaunch it, by the lane's state and [lane-reach.md](lane-reach.md).

**A refusal is a state, not a remedy.** A halt or an answer to a lane with no monitor that the wake refuses lands only where the Lane mail rule above says. Send where the reason allows it; mail that cannot wait takes [lane-reach.md](lane-reach.md#mail-the-wake-cannot-deliver).

[lane-reach.md](lane-reach.md) holds what each wake refusal reason licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

**Pane paste.** Write harness input to a file with the harness file tool, then type it with the one pane writer. `[WINDOW]` is the lane record's `window`, and `[PROCESS]` is the record's `harness`, or `ssh` for a record carrying `host`:

```bash
.agents/skills/orch/scripts/pane-write --window [WINDOW] --expect [PROCESS] --file [PATH]
```

It cancels copy mode, pastes the file and presses `Enter`. A dialog key takes `--key [KEY]` in place of `--file`. A refusal, exit 1, types nothing, and its `fix=` line names the remedy (`pane-write --help`). Exit 2, `write-failed`, may have typed part of the input: read the pane before a retry. Never paste a shell command into a lane pane. Stop a process inside a hosted sandbox through `lane-host stop --item [ITEM] --harness [HARNESS]`. Never type a process-name kill at a prompt that can belong to the control host.

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; the launch brief and a harness dialog's answer reach a pane the same way, and nothing else does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) without `--cmd` for automatic session selection or the fresh start brief. Only a hosted Codex relaunch that reports `resume-lineless` needs its continuation through Pane paste afterwards. A fresh start needs no paste.
