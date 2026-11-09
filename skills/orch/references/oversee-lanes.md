# Oversee lanes

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) to park a hosted lane's merge wait, or to answer, direct, wake, paste into or resume a lane.

## Parking a merge wait

A hosted lane can wait for its own queued PR or for another PR in a watched repository. Park it to stop sandbox billing while keeping its disk and session. The overseer parks through the runtime's close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) with a park `mode`, written with the harness file tool and run as that section's command. For the lane's queue wait:

```json
{"op":"close-lane","item":"[ITEM_KEY]","mode":{"park":{"pr":[PR_NUMBER]}}}
```

For a dependency wait, `until_pr` names the blocking pull request, and `until_repo` its repository where it is not the lane's own:

```json
{"op":"close-lane","item":"[ITEM_KEY]","mode":{"park":{"until_pr":[BLOCKING_PR],"until_repo":"[OWNER/REPO]"}}}
```

The named repository must be the lane repository or listed in `ORCH_CONNECTED_REPOS`, else the park refuses `park-refused reason=repo-unwatched`. Add `"pr": [OWN_PR]` beside `until_pr` only when the dependency lane also has its own PR. A park naming neither refuses as `request-invalid field=park`.

Before requesting either park, the lane commits its work. In its worktree, it reads `git status --porcelain`, `git rev-parse HEAD`, `git branch --show-current`, and `date -u +%Y-%m-%dT%H:%M:%SZ`. A nonempty status prevents the request. With the harness file-write tool, it writes `tmp/park-status.json` as `{ "head": "[SHA]", "branch": "[BRANCH]", "porcelain": "", "at": "[UTC_TIME]" }` from those readings. It writes a notice to `tmp/park-request.md` naming the repository, its own PR if any, the blocking PR, and the next step held by that PR. It sends that notice with `.agents/skills/mailbox/scripts/lane-mail notice --item [ITEM_KEY] --file tmp/park-request.md`. The lane makes no further file changes while it waits for the overseer to park it.

The close is the park judge. It first asks `lane-host stop-sandbox --check` whether the disk can be stopped and started again. A local lane refuses as `park-refused reason=local`, and a provider without that pair as `park-refused reason=provider-unsupported`, before any signal or GitHub read. It reads the pull request in one GitHub read (`reason=pr-read-failed` where it fails). It reads the checked-out branch and head through the provider's file interface, then checks that the clean-status record, `tmp/park-status.json` under the lane's `mail_root`, names that branch and head, carries an empty status and a time. Missing, unreadable or mismatched evidence refuses as `reason=worktree-unread`, `clean-status-unread` or `clean-status-invalid`. File reads cannot prove current cleanliness; the lane owns the status reading and its quiet wait after the notice. When the remote Git read fails on a queue park, the item state's `branch` may name its PR branch instead, judged against the pull request's own head. Refusals name this fallback as `branch-source=workflow-state`.

A queue park requires an OPEN PR whose head branch and commit match the lane (`reason=pr-not-open`, `pr-branch-mismatch`, `pr-head-mismatch`). This includes a second branch of the same item. GitHub must queue the PR, or arm auto-merge with `mergeStateStatus=CLEAN` (`reason=not-armed`, `merge-state`). The github skill's reducer must print no attention line (`reason=attention` with the line's `kinds`, `reducer-missing`, `reducer-failed`). The queue and CLEAN prove the base's required approval; reducer silence alone does not. A dependency park requires the blocking PR to be OPEN. It does not apply the lane's queue, branch or review checks to that other PR. A park ends the lane's harness through its provider as any hosted close does, and refuses an unanswered ask as `ask-unanswered`; a record still `preparing` refuses as `record-invalid field=status`.

The provider's `stop-sandbox` follows the harness stop and window close, which records the lane `stopped`. Its `sandbox-stopped` line records `parked` with `{head, repo, at}`, an own `pr` when supplied, and `until_pr` for a dependency wait, and the reply's `result.word` reads `parked`. A qualified dependency also records `until_repo`. The own `repo` stays the lane repository. A failed sandbox stop refuses as `park-failed` and leaves `stopped`: Recovery relaunch recovers it, and a second park retries that stop from the record. A park of a record already `parked` changes nothing.

Run the park when the lane's notice names a dependency hold or its queue wait. A `heartbeat` also identifies queue waits from the lane's status file ([oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads)). The lane must supply its clean-status record before that park. The verb's own reads decide admission.

What a parked lane keeps: its record, its `mail_root` and PR-watch rows, and its disk, with the harness transcript, the mailbox and its `tmp`. What it gives up: its window, its pane reads and its mail pass, since the disk is stopped. The launch cap charges a parked record only while a live identity or a `reservation` stands, which `reserve-lane`, or a `park-lane` request that names one, writes and the close's park does not, so a lane that park left holds no fleet slot and its resume meets the cap as an added lane ([lane-directive.md § Caps](lane-directive.md#caps)). The [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) watch carries a parked record for its merged check, terminal close and `lane-long` age; it asks a parked record's provider nothing. The status report, `orch-runtime report render`, lists it under In progress with the pull request its record names, its `pending_pr` else its `parked` one, or `no pull request`, and reads nothing from its disk.

What ends a park, each per [oversee-events.md § Event kinds](oversee-events.md#event-kinds):

- Merge of the wait PR in that repository: `until_pr` selects it for a dependency park; `pr` selects it for a queue park. The watch prints `parked-merged` for an item with work left. The lane's own PR merge does not clear a dependency wait. The watch repeats the resume hand at a heartbeat while the record still reads parked. Recovery relaunch changes that record before creating the harness, so a replay cannot launch another copy. A dependency merge earns no cycle for the waiting item. The resumed lane rebases and continues its held step.
- `parked-closed`: the dependency PR closed without merging. The watch reports it once. The overseer resolves the hold or resumes the lane through Recovery relaunch.
- A `pr-watch` line on the parked pull request, `threads-open`, `changes-requested`, `ci-failed`, `disarmed`, `awaiting-stale`, `head-moved` or `error`: the lane is needed again. `disarmed` is also how a dequeue nothing else reported reads, since the reducer prints it for an approved pull request neither queued nor armed, so the queue needs no other reading, and a parked pull request the heartbeat still lists open with no reducer line stays parked. Resume it through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), whose parked rule starts the sandbox before the relaunch, since the runtime's launch starts no stopped sandbox. The unpark owner retains the PR identity as `pending_pr`, per [workflow-state.md](../schemas/workflow-state.md#oversee-state), so an OPEN PR still prevents terminal close after a failed relaunch. The relaunch starts the harness fresh on the kept disk, and the item's handoff record carries its context.

## Talking to a lane

A mailbox lane whose host declares `files=verb` needs `--root [MAIL_ROOT] --host` on the sends below. Use the lane record's `mail_root` as `[MAIL_ROOT]`. The send uses the record's `host` instead of the configured provider. A different root refuses as `host-root-mismatch`. A send that reads such a record without `--host` refuses as `host-root-required` before it writes mail or prints a sent receipt.

Answering and directing a mailbox lane are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host, and `--root [MAIL_ROOT]` alone, run from a checkout of that repository, for a local lane whose `mail_root` is another repository's worktree.

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). The `--state-dir` send reads the lane's record and matches the `channel` its host kind declares, and refuses as `lane-unrecorded` where that state holds no record for the lane; a lane with no record, one the watch carries from `--item` alone, takes the same send with no `--state-dir`. A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](skill-rules.md) says when each reaches it.

A `session` lane, a Claude cloud session, takes a directive alone, through the runtime, which queues it into the session and records the send on the lane record as `directive_send`:

```bash
.agents/skills/orch/scripts/orch-runtime send --item [ISSUE_ID] --file [PATH]
```

The record reads `sent`, `archived` (a session the operator archived) or `failed` with the CLI's words and the account's credit at the send; the watch's stall close reads it ([oversee-events.md § Event kinds](oversee-events.md#event-kinds), `cloud-stall-closed`). No `directive-read` follows a session send: the lane's next push or its pull request body shows it acted, and a session that does not act shows as `lane-stalled`. A send whose outcome the runtime could not read stands owed, and every later send to that lane is refused `directive-send-owed` until the operator settles it as the watch's `directive-send-unsettled` line directs. `--re` and `--halt` have no session form.

Wake a Claude or Pi mailbox lane after the send where [watch-delivery.md](watch-delivery.md#lane-mailbox-monitor) says. Pass its harness and `[WAKE_ITEM]`: `[ISSUE_ID]` for a Linear item, and for a GitHub item the bare issue number, never its `issue-N` key, with `--tracker github --repo [OWNER/REPO]`; the woken turn spends the account the lane record names, or the one `--lane [DIR]` names, and keeps the record's `live_display`. The wake hands the lane's own session one line that runs `lane-mail inbox`, and reaches only lanes on this host, run from the checkout the send used, because the wake resolves the lane's tree from the caller's own project. A Claude lane takes it as a second process in print mode, only where no turn an earlier wake started still runs and the runtime's lane status reads the lane `idle`; any other state refuses as `wake-refused reason=[STATE]`. A Pi lane takes it through pi-bridge into its live session. A Codex or Copilot lane takes no wake: its mail waits for its next turn or its relaunch. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] --state-dir [OVERSEE_STATE_DIR] [WAKE_ITEM]
```

After a directive, wait for the watch's `directive-read` for its id: the lane's own mailbox cursor passing it, whichever read path moved it, on every harness and on a hosted lane. Never read a pane to confirm a delivery. `directive-unread` is the directive still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: wake the lane, reach it by Pane paste, or relaunch it, by the lane's state and [lane-reach.md](lane-reach.md).

**A refusal is a state, not a remedy.** A halt or an answer to a lane with no monitor that the wake refuses lands only where the Lane mail rule above says. Send where the reason allows it; mail that cannot wait takes [lane-reach.md](lane-reach.md#mail-the-wake-cannot-deliver).

[lane-reach.md](lane-reach.md) holds what each wake refusal reason licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

**Pane paste.** Write harness input to a file with the harness file tool, then type it with the one pane writer, the `pane_write` function of `scripts/lib/pane-write.sh`, run from the lane's repository checkout. `[WINDOW]` is the lane record's `window`, and `[PROCESS]` is the record's `harness`, or `ssh` for a record carrying `host`:

```bash
SCRIPT_DIR=.agents/skills/orch/scripts bash -c '. "$SCRIPT_DIR/lib/lane-state.sh" && . "$SCRIPT_DIR/lib/pane-write.sh" && pane_write "$@"' _ window [WINDOW] [PROCESS] file [PATH]
```

It checks that the pane runs `[PROCESS]`, cancels local copy mode, pastes the file and presses `Enter`. A dialog key takes `key [KEY]` in place of `file [PATH]`, one of `Enter`, `Up`, `Down`, `C-c` or a digit. A record whose host declares `pane=verb` takes `host [ITEM] [HARNESS]` in place of `window [WINDOW] [PROCESS]`, with `ORCH_LANE_HOST=[HOST]` set, and its input goes through the provider's `send` under [lane-host.md](../schemas/lane-host.md#provider-protocol). A refusal, status 1, types nothing, and its `fix=` line names the remedy. Status 2, `write-failed`, may have typed part of the input: read the pane before a retry. Never paste a shell command into a lane pane. Stop a process inside a hosted sandbox through `lane-host stop --item [ITEM] --harness [HARNESS]`. Never type a process-name kill at a prompt that can belong to the control host.

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; a harness dialog's answer reaches a pane the same way, and nothing else the overseer sends does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). Its brief file carries the continuation, so nothing is pasted after the relaunch.
