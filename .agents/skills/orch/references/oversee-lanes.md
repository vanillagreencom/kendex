# Oversee lanes

Read from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) to park a hosted lane's wait, or to answer, direct, type into or resume a lane.

## Parking a merge wait

A hosted lane can wait for its own queued pull request, for another pull request in a watched repository, for the owner's answer to its own ask, or stay on hold with no wait. Park it to stop sandbox billing while keeping its disk and session. Park when the lane's notice names its queue wait, a dependency hold, its ask or a hold with no wait; a `heartbeat` also shows queue waits from the lane's status file ([oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads)). The park is a `close-lane` request with a park `mode`, written with the harness file tool and run as [lane-reach.md § Lane close](lane-reach.md#lane-close) states. The close's own reads decide admission.

| Wait | `mode` |
|---|---|
| The lane's own pull request in the queue | `{"park":{"pr":[PR_NUMBER]}}` |
| A blocking pull request | `{"park":{"until_pr":[BLOCKING_PR],"until_repo":"[OWNER/REPO]"}}`, `until_repo` only where it is not the lane's repository; add `"pr":[OWN_PR]` where the lane also has its own pull request |
| The lane's open ask | `{"park":{"ask":"[ASK_ID]"}}` |
| A hold with no pull request or ask wait | `{"park":{"hold":true}}` |

```json
{"op":"close-lane","item":"[ITEM_KEY]","mode":{"park":{"pr":[PR_NUMBER]}}}
```

The named `until_repo` must be the lane's repository or listed in `ORCH_CONNECTED_REPOS`, else the park refuses `park-refused reason=repo-unwatched`. A park naming no pull request, ask or hold refuses `request-invalid field=park requires=pr|ask|hold`. A hold combined with any wait field refuses `request-invalid field=park conflict=hold|wait`.

### The lane's steps before a park

1. Commit the work and push the branch to `origin`.
2. In the worktree, read `git status --porcelain`, `git rev-parse HEAD`, `git branch --show-current` and `date -u +%Y-%m-%dT%H:%M:%SZ`. A nonempty status stops here.
3. With the harness file tool, write `tmp/park-status.json` as `{ "head": "[SHA]", "branch": "[BRANCH]", "porcelain": "", "at": "[UTC_TIME]" }` from those readings.
4. Write a notice to `tmp/park-request.md` naming the repository, its own pull request if any, and what it waits on: the blocking pull request and the step it holds, its ask, or a hold with no wait.
5. Send it with `.agents/skills/mailbox/scripts/lane-mail notice --item [ITEM_KEY] --file tmp/park-request.md`, then change no file while it waits.

### The judge

The close reads before it signals anything; each failed reading is `park-refused reason=[REASON]`:

- The provider's `stop-sandbox --check` answers whether the disk can be stopped and started again: `reason=local` for a local lane, `reason=provider-unsupported` for a provider without that pair.
- An ask park's ask must be the lane's oldest open one: `ask-not-open ask= open=`. An ask park reads no pull request.
- The lane's repository must resolve: `reason=repo-unresolved` with its `cause`.
- A named pull request is read once (`reason=pr-read-failed`) and must be OPEN (`reason=pr-not-open`). A dependency park checks only that the blocking pull request is open. A hold park reads no pull request and uses the same pushed-head and clean-status proof below.
- The checked-out branch and head are read through the provider's file interface (`reason=worktree-unread`), and the head must stand on the sandbox's `origin` (`reason=unpushed head= remote=`): tell the lane to push, then park again.
- The clean-status record, `tmp/park-status.json` under the lane's `mail_root`, must name that branch and head with an empty status and a time (`reason=clean-status-unread`, `clean-status-invalid`). File reads cannot prove current cleanliness: the lane owns the status reading and its quiet wait after the notice. Where the remote Git read fails on a queue park, the item state's `branch` can name its pull request branch instead, judged against the pull request's own head; refusals then name `branch-source=workflow-state`.
- A queue park needs its pull request's head branch and commit to match the lane (`reason=pr-branch-mismatch`, `pr-head-mismatch`), a second branch of the same item included. GitHub must hold it in the merge queue, or have auto-merge armed with `mergeStateStatus=CLEAN` (`reason=not-armed`, `merge-state`). The github skill's reducer must print no attention line (`reason=attention` with the line's `kinds`, `reducer-missing`, `reducer-failed`). The queue or CLEAN proves the base's required approval; reducer silence alone does not.
- A pull-request or hold park refuses an unanswered ask as `ask-unanswered`. A record still `preparing` refuses `record-invalid field=status`.

### What a park records

The park ends the lane's harness through its provider, as any hosted close does, then calls the provider's `stop-sandbox`. Its `sandbox-stopped` line records the lane `parked` with `{head, repo, at}`, its own `pr` where supplied, `until_pr` and `until_repo` for a dependency wait, its ask for an ask park, or `hold: true` for a hold; the reply's `result.word` reads `parked`. A park of a record already `parked` changes nothing. A hold keeps the item's state and work.

A failed sandbox stop refuses `park-failed` and leaves the record `stopped` with `sandbox: standing` and the owed park, which holds a fleet slot. The watch completes an owed park each pass and reports `park-owed [ITEM] result=` once per distinct result; a confirmed park, relaunch or close clears it. The `result` reads:

| `result` | Meaning |
|---|---|
| `parked` | The park completed: the record reads `parked`. |
| A refusal key with its fields, such as `park-refused reason=attention pr= kinds=` | The close refused the park, or its effect failed or stood open, naming its key or cause; the watch asks again next pass. Answer the cause as § The judge says. |
| `deferred` | The tracker's quota hold refused the verdict the close needs; nothing closed, and the watch asks again once the hold ends. |
| `refused path=[PATH]` | The provider refused its close, naming the checkout it kept (`unknown` without one). |
| `unanswered [CAUSE]` | The close gave no answer and may have acted; the watch leaves the lane to the operator. Read the lane's record and intents before acting. |

A parked lane keeps its record, its `mail_root`, its pull-request watch rows and its disk with the harness transcript, the mailbox and its `tmp`. It gives up its window, its pane reads and its mail pass. The launch cap charges a parked record only while a live identity or a `reservation` stands, which `reserve-lane`, or a `park-lane` request that names one, writes and the close's park does not; so a parked lane holds no fleet slot, and its resume meets the cap as an added lane ([lane-directive.md § Caps](lane-directive.md#caps)). The watch carries a parked record for its merged check, terminal close and `lane-long` age, and asks its provider nothing. The status report, `orch-runtime report render`, lists it under In progress with the pull request its record names, its `pending_pr` else its `parked` one, or `no pull request`, and reads nothing from its disk.

### What ends a park

A hold park returns only through a hand relaunch of the parked lane. The watch wakes nothing for it, including when the tracker leaves hold.

Each per [oversee-events.md § Event kinds](oversee-events.md#event-kinds):

- The wait pull request merges in its repository: `until_pr` selects it for a dependency park, `pr` for a queue park. The watch prints `parked-merged` for an item with work left, and repeats the resume at a heartbeat while the record still reads parked. The lane's own merge does not clear a dependency wait, and a dependency merge earns the waiting item no cycle. Recovery relaunch changes the record before it creates the harness, so a replay cannot launch a second copy. The resumed lane rebases and continues its held step.
- `parked-closed`: the dependency pull request closed without merging. The watch reports it once. Resolve the hold, or resume the lane through Recovery relaunch.
- A `pr-watch` line on the parked pull request, `threads-open`, `changes-requested`, `ci-failed`, `disarmed`, `awaiting-stale`, `head-moved` or `error`: the lane is needed again. `disarmed` is also how an otherwise unreported dequeue reads, since the reducer prints it for an approved pull request neither queued nor armed; a parked pull request the heartbeat still lists open with no reducer line stays parked.
- An ask park's answer: resume the lane through Recovery relaunch, then send the answer.

Resume through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), whose parked rule starts the sandbox before the relaunch; the launch starts no stopped sandbox. The unpark keeps the pull request's identity as `pending_pr` ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), so an open pull request still prevents a terminal close after a failed relaunch. The relaunch starts the harness fresh on the kept disk, and the item's handoff record carries its context.

## Talking to a lane

Answering and directing a mailbox lane are the same two commands on every harness and every surface, inside tmux or not. Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell).

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH]
```

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH]
```

The send goes where the caller's route names; it reads no lane record. For a lane whose record carries `host`, set `ORCH_LANE_HOST` to that value and add `--root [MAIL_ROOT] --host`, `[MAIL_ROOT]` being the record's `mail_root`; with no `ORCH_LANE_HOST` it refuses `host-route-missing`. For a local lane whose `mail_root` is another repository's worktree, add `--root [MAIL_ROOT]` alone and run it from a checkout of that repository. A directive answers no ask, and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md § Lane mail](skill-rules.md#lane-mail) says when each reaches it.

After a directive, wait for the watch's `directive-read` for its id: the lane's own mailbox cursor passing it, whichever read moved it, on every harness and on a hosted lane. Never read a pane to confirm a delivery. `directive-unread` is the directive still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: reach the lane by its state under [lane-reach.md § Lane states](lane-reach.md#lane-states). A lane state is not a remedy: mail that cannot wait takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver). [lane-reach.md](lane-reach.md) holds what each lane state licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

### Cloud session lanes

A `session` lane, a Claude cloud session, takes a directive alone, through the runtime, which records the send on the lane record as `directive_send` before it sends:

```bash
.agents/skills/orch/scripts/orch-runtime send --item [ISSUE_ID] --file [PATH]
```

The record reads `sent`, `archived` (a session the operator archived) or `failed` with the CLI's words and the account's credit at the send; the watch's stall close reads it (`cloud-stall-closed` in [oversee-events.md § Event kinds](oversee-events.md#event-kinds)). No `directive-read` follows a session send: the lane's next push or its pull request body shows it acted, and a session that does not act shows as `lane-stalled`. A send whose outcome the runtime could not read stands owed: every later send to that lane refuses `directive-send-owed` until the operator settles it as the watch's `directive-send-unsettled` line directs. `--re` and `--halt` have no session form.

### The wake duty

The watch's wake duty wakes a lane; the overseer sends the mail and wakes nothing. For a running lane whose mailbox holds mail it has not read, the duty reads the lane positively idle and types one line that runs `lane-mail inbox`, confirmed by a new user turn in the session file the lane record binds. Every harness takes that line. A hosted lane's line goes through its window or its provider's `send`, and is reported `wake-unconfirmed cause=session-hosted`: the lane's own mailbox read is the confirmation. `wake-limit` names what kept the duty from a confirmable delivery, such as a session no record binds. For a walled lane whose reset has passed, the duty types the resume sentence before the inbox line; no hosted lane is resumed this way. The duty's lines are the `wake-` entries of [oversee-events.md § Event kinds](oversee-events.md#event-kinds).

### Typing into a lane

Never type mail into a lane's pane, and never paste a shell command into it. A harness dialog's answer reaches the pane as [lane-reach.md § Per harness](lane-reach.md#per-harness) states. A hosted lane whose host declares `pane=verb` takes input through its provider: `orch-runtime host --host [HOST] send --item [ITEM] --file [PATH]`, or `--key [KEY]` for one key. Stop a process inside a hosted sandbox with `orch-runtime host --host [HOST] stop --item [ITEM] --harness [HARNESS]`; never type a process-name kill at a prompt that can belong to the control host.

A lane never arms the shared git hooks from its worktree. A guard-script pull request whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

### Resuming a lane

Resume a dead or walled lane through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). Its brief file carries the continuation, so nothing is typed after the relaunch.
