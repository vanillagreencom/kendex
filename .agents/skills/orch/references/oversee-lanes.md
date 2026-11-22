# Oversee lanes

Read from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) to park a hosted lane's wait, or to answer, direct, type into or resume a lane.

## Parking a merge wait

A hosted lane can wait for its own queued pull request, for another pull request in a watched repository, or for the owner's answer to its own ask. It can also stay on hold with no wait.

- Park it to stop sandbox billing; the park keeps its disk and session.
- Park when the lane's notice names its queue wait, a dependency hold, its ask or a hold with no wait.
- A `heartbeat` also shows queue waits from the lane's status file ([oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads)).
- The park is a `close-lane` request with a park `mode`. Write it with the harness file tool and run it as [lane-reach.md § Lane close](lane-reach.md#lane-close) states.
- The close's own reads decide admission.

| Wait | `mode` |
|---|---|
| The lane's own pull request in the queue | `{"park":{"pr":[PR_NUMBER]}}` |
| A blocking pull request | `{"park":{"until_pr":[BLOCKING_PR],"until_repo":"[OWNER/REPO]"}}` |
| The lane's open ask | `{"park":{"ask":"[ASK_ID]"}}` |
| A hold with no pull request or ask wait | `{"park":{"hold":true}}` |

- A blocking pull request's park names `until_repo` only where it is not the lane's repository.
- It adds `"pr":[OWN_PR]` where the lane also has its own pull request.

```json
{"op":"close-lane","item":"[ITEM_KEY]","mode":{"park":{"pr":[PR_NUMBER]}}}
```

- The named `until_repo` must be the lane's repository or listed in `ORCH_CONNECTED_REPOS`.
- A park names a pull request, an ask or a hold; a hold names no wait field.

### The lane's steps before a park

1. Commit the work and push the branch to `origin`.
2. In the worktree, read `git status --porcelain`, `git rev-parse HEAD`, `git branch --show-current` and `date -u +%Y-%m-%dT%H:%M:%SZ`. A nonempty status stops here.
3. With the harness file tool, write `tmp/park-status.json` as `{ "head": "[SHA]", "branch": "[BRANCH]", "porcelain": "", "at": "[UTC_TIME]" }` from those readings.
4. Write a notice to `tmp/park-request.md`. Name the repository, the lane's own pull request if any, and what the lane waits on: the blocking pull request and the step it holds, its ask, or a hold with no wait.
5. Send it with `.agents/skills/mailbox/scripts/lane-mail notice --item [ITEM_KEY] --file tmp/park-request.md`. Then change no file while it waits.

### The judge

The close judges a park before it signals anything, and refuses one that fails a reading as `park-refused reason=[REASON]`. Park only where:

- the provider can stop and start the disk again (`stop-sandbox --check`); a local lane never parks;
- an ask park's ask is the lane's oldest open one;
- a named pull request is OPEN; a dependency park needs only the blocking pull request open;
- the lane's head stands on the sandbox's `origin`. On `reason=unpushed`, tell the lane to push, then park again;
- `tmp/park-status.json` under the lane's `mail_root` names that branch and head with an empty status and a time.
  - File reads cannot prove current cleanliness: the lane owns the status reading and its quiet wait after the notice.
  - A hold park needs this pushed-head and clean-status proof too;
- for a queue park:
  - the pull request's head branch and commit match the lane;
  - GitHub holds the pull request in the merge queue, or has auto-merge armed with `mergeStateStatus=CLEAN`;
  - and the github skill's reducer prints no attention line;
- a pull-request or hold park has no unanswered ask, and the record no longer reads `preparing`.

### What a park records

The park ends the lane's harness through its provider, then stops its sandbox; the reply's `result.word` reads `parked`. A hold keeps the item's state and work.

A failed sandbox stop leaves the record `stopped` with the park owed, which holds a fleet slot.

- The watch asks for an owed park each pass and reports `park-owed [ITEM] result=` once per distinct result ([oversee-events.md § `park-owed`](oversee-events.md#park-owed)).
- A confirmed park, relaunch or close clears it.

The `result` reads:

| `result` | Meaning |
|---|---|
| `parked` | The park completed: the record reads `parked`. |
| A refusal key with its fields, such as `park-refused reason=attention pr= kinds=` | The close refused the park, or its effect failed or stood open, naming its key or cause. |
| `deferred` | The tracker's quota hold refused the verdict the close needs. |
| `refused path=[PATH]` | The provider refused its close, naming the checkout it kept (`unknown` without one). |
| `unanswered [CAUSE]` | The close gave no answer and may have acted. |

- After a refusal key, the watch asks again next pass. Answer the cause as § The judge says.
- After `deferred`, nothing closed; the watch asks again once the hold ends.
- After `unanswered`, the watch leaves the lane to the operator. Read the lane's record and intents before acting.

A parked lane keeps its record, its `mail_root`, its pull-request watch rows, and its disk with the harness transcript, the mailbox and its `tmp`. It gives up its window, its pane reads and its mail pass, and holds no fleet slot ([lane-directive.md § Parked record](lane-directive.md#parked-record)).

### What ends a park

Only a hand relaunch of the parked lane ends a hold park. The watch wakes nothing for it, even when the tracker leaves hold.

The other ends, each per [oversee-events.md § Event kinds](oversee-events.md#event-kinds):

- The wait pull request merges in its repository, [`parked-merged`](oversee-events.md#parked-merged).
  - `until_pr` selects it for a dependency park, `pr` for a queue park.
  - The lane's own merge does not clear a dependency wait.
  - Recovery relaunch changes the record before it creates the harness, so a replay cannot launch a second copy.
- The dependency pull request closed without merging: [`parked-closed`](oversee-events.md#parked-closed).
- A `pr-watch` line on the parked pull request, `threads-open`, `changes-requested`, `ci-failed`, `disarmed`, `awaiting-stale`, `head-moved` or `error`: the lane is needed again. A parked pull request the heartbeat still lists open with no reducer line stays parked.
- An ask park's answer: resume the lane through Recovery relaunch, then send the answer.

Resume through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), with no separate provider `start` call. Its [§ Parked record](lane-directive.md#parked-record) states what the relaunch does for a parked lane.

## Talking to a lane

Answering and directing a mailbox lane take the same two commands on every harness and every surface, inside tmux or not.

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH]
```

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH]
```

- For a hosted mailbox, set `ORCH_LANE_HOST` to the lane record's `host`, and add `--root [MAIL_ROOT] --host`, where `[MAIL_ROOT]` is the record's `mail_root`.
- For a local lane whose `mail_root` is another repository's worktree, add `--root [MAIL_ROOT]` alone, and run the send from a checkout of that repository.
- A directive answers no ask.
- `--halt` in place of `--directive` halts the lane.
- [skill-rules.md § Lane mail](skill-rules.md#lane-mail) says when each reaches the lane.

After a directive, wait for the watch's `directive-read` for its id, on every harness and on a hosted lane.

- Never read a pane to confirm a delivery.
- `directive-unread` means the directive is still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: reach the lane by its state under [lane-reach.md § Lane states](lane-reach.md#lane-states).
- A lane state is no remedy: mail that cannot wait takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

### Cloud session lanes

A `session` lane, a Claude cloud session, takes only a directive, through the runtime. The runtime records the send on the lane record as `directive_send` before it sends:

```bash
.agents/skills/orch/scripts/orch-runtime send --item [ISSUE_ID] --file [PATH]
```

- The watch's stall close reads that record (`cloud-stall-closed` in [oversee-events.md § Event kinds](oversee-events.md#event-kinds)).
- No `directive-read` follows a session send: the lane's next push or its pull request body shows it acted.
- A session that does not act shows as `lane-stalled`.
- A send whose outcome the runtime could not read stands owed: settle it as [oversee-events.md § `directive-send-unsettled`](oversee-events.md#directive-send-unsettled) directs.
- `--re` and `--halt` have no session form.

### The wake duty

The watch's wake duty wakes a lane. The overseer sends the mail and wakes nothing.

- For a running lane whose mailbox holds mail it has not read, the duty reads the lane idle and types one line that runs `lane-mail inbox`, on every harness; a hosted lane's line goes through its window or its provider's `send`.
- For a walled lane whose reset has passed, the duty types the resume sentence before the inbox line.
- The duty resumes no hosted lane this way.
- The duty's lines are the `wake-` entries of [oversee-events.md § Event kinds](oversee-events.md#event-kinds).

### Typing into a lane

- Never type mail into a lane's pane, and never paste a shell command into it.
- A harness dialog's answer reaches the pane as [lane-reach.md § Per harness](lane-reach.md#per-harness) states.
- A hosted lane whose host declares `pane=verb` takes input through its provider: `orch-runtime host --host [HOST] send --item [ITEM] --file [PATH]`, or `--key [KEY]` for one key.
- Stop a process inside a hosted sandbox with `orch-runtime host --host [HOST] stop --item [ITEM] --harness [HARNESS]`.
- Never type a process-name kill at a prompt that can belong to the control host.

A lane never arms the shared git hooks from its worktree. The overseer sequences a guard-script pull request whose new chain refuses the branch under main's installed scripts, as a one-time transition.

### Resuming a lane

Resume a dead or walled lane through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). Its brief file carries the continuation, so nothing is typed after the relaunch.
