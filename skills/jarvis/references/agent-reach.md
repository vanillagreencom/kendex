# Agent reach

Read when the user asks about, or wants to instruct, the agent working in one of their kendex projects.

## Route

- The repository mailbox is the one route to another repository's agent, with a fleet or without one. A repository is reachable when the [mailbox](../../mailbox/SKILL.md) package is installed there; [SKILL.md § Reachable repositories](../SKILL.md#reachable-repositories) judges which are.
- `[LANE_MAIL]` below is the repository's own `.agents/skills/mailbox/scripts/lane-mail`, run with the repository's main checkout as the working directory. Do not use the Jarvis home's `lane-mail` or its `peer send`: a peer send reaches the agent as another repository's note, not as the user's.
- Take repositories only from `kendex project list`. Each line is a folder, then optional notes in parentheses: `(folder not found)`, `(not a folder)`, `(folder could not be read)` or `(worktree of [MAIN])`. A worktree line stands for `[MAIN]`, where its mailbox sits.
- A fleet changes nothing here: Jarvis reads the repository's overseer mailbox, and a hosted lane's own mailbox stays the overseer's to read. A main reaches its declared remote machines through `.agents/skills/jarvis/scripts/owner-note REPO FILE`, which makes the send below on the selected host; `owner-note --help` lists its refusal keys. Each host reaches that repository only after [Control host setup](#control-host-setup). A satellite reaches no repository: it forwards to the main under [Main and satellites](#main-and-satellites).
- `lane-mail --help` defines every verb, envelope, receipt and refusal key used here.

## Read

- Run `[LANE_MAIL] events --item overseer --box to-overseer --after [N] --mark-read`. The command records the snapshot's logical count for the Slack relay's hold resume.
- Handle the returned notices through [One voice](#one-voice). Show every returned owner ask through [Answer an ask](#answer-an-ask).
- Keep the snapshot header's `count` for each repository in the handoff's State section after handling the returned envelopes, and pass it as `[N]`; `0` reads every envelope.
- An agent writes a notice only when its workflow or a directive from the user tells it to. With no envelope, say that the agent has reported nothing. Silence does not mean the agent is idle.

## Answer an ask

- An envelope with `kind` `ask` and `to` `owner` is the agent's question to the user. Show it to the user with its options.
- Write the user's answer to a file, then run `[LANE_MAIL] resolve --item overseer --id [ASK_ID] --text [PATH]`. It needs no registered session.

## Instruct

1. Write the text to a file. Text crosses a file, never a command argument.
2. End the text with the reply form: `lane-mail notice --item overseer --to owner --ref [DIRECTIVE_ID] --file [PATH]`, `[DIRECTIVE_ID]` being the id of the directive the agent receives.
3. The directive carries the user's authority, so [decisions.md § Authority](decisions.md#authority) applies: show the user the exact text and the repository, and send only after the user agrees. Through `owner-note`, the sent text is FILE, a blank line, then the verify footer: show the user that full text, and end FILE, not the sent text, with step 2's reply form.
4. Run `[LANE_MAIL] send --item overseer --directive --file [PATH]`.
5. The send is made only when stdout printed `lane-mail: sent item=overseer id=[DIRECTIVE_ID]`. Without that receipt nothing was sent. The receipt says the directive landed, not that the agent read it; the agent's notice with `ref` `[DIRECTIVE_ID]` is its answer.

## Findings

- A practice or design finding Jarvis meets in a repository, whose cause lies in a kendex-owned package, goes to the kendex repository through [Instruct](#instruct), as an item or a note.
- Judge it under the code-quality skill's SKILL.md § Finding Evaluation, and send that section's evaluation line with the finding. That section decides which findings qualify; the line by itself does not justify a new item.
- The note is a send in the user's name: [Instruct](#instruct) step 3's approval of the exact text applies unless the user's responsibility map holds a standing grant for these finding notes, under [decisions.md § Authority](decisions.md#authority). This package records no such grant.

## One voice

The agent's notice reaches Jarvis, and Jarvis decides what the user hears. Set no per-agent speech or reply setting.

## Refusals

Report each refusal in plain words. Do not retry it or work around it.

| Key | Meaning | Next step |
|---|---|---|
| `overseer-absent`, `no-overseer` | No session is registered to read that repository's mail; nothing was sent. `owner-note` refuses `no-overseer` when no machine it tried lists that repository with one. A second line saying orch is not installed means the repository has mailbox alone. | Without orch, offer the [directive install](#install). With orch, say that the agent's session must run orch's `oversee register` in its own tmux pane. When that session runs on the control host, offer [Control host setup](#control-host-setup) first. |
| `overseer-unreadable` | The repository's fleet record could not be read; nothing was sent. | Report the cause `lane-mail` printed. |
| `command-missing`, `file-unreadable` | A command `lane-mail` needs is absent, or the message file is unreadable. | Name the command or file. |

## Install

Offer one of these commands, run with the repository's main checkout as the working directory. `[HARNESS]` is the harness whose transcript holds that agent's session, else the one the user names.

| Purpose | Command |
|---|---|
| Reports and asks reach Jarvis | `kendex add vanillagreencom/kendex --skill mailbox --harness [HARNESS] --yes` |
| The agent takes directives, after a send refused `overseer-absent` | `kendex add vanillagreencom/kendex --skill orch --hook lane-mail-check --harness [HARNESS] --yes` |

- The directive install brings orch, mailbox and the hooks `lane-mail-check` requires. On Copilot CLI, add `--hook lane-mail-start,lane-mail-prompt`.
- Before the user's yes, say what it installs, that it writes files into that repository's working tree and commits nothing, and, for the directive install, that the agent's running session may need a restart before the hooks reach it.
- On a yes, run the command, then judge the folder again by [§ Reachable repositories](../SKILL.md#reachable-repositories).
- After the directive install, the agent's session still runs orch's `oversee register` before mail reaches it. Say so. Call the repository instructable only after a directive send prints its receipt.

## Control host setup

The main's `JARVIS_REMOTE_HOSTS` adds whitespace-separated SSH aliases alongside `JARVIS_CONTROL_HOST` and local roots. An alias uses the DEST grammar in [Main and satellites](#main-and-satellites). Repeat the registration steps below on each remote, using that alias as HOST. Exact repeated aliases are one destination. Use one stable alias per physical machine; two different aliases reaching one mailbox are unsupported.

With no additional distinct alias, bare `owner-note REPO FILE` keeps control-host-first routing and tries local only when the host lists no root or its send refuses `overseer-absent`. With an additional alias, bare selection reads every declared destination before sending, refuses unread discovery as `project-list-failed` and duplicate basenames as `repo-ambiguous`, including a local/control duplicate. No partial listing proves uniqueness.

`owner-note --host ALIAS REPO FILE` selects a declared remote only; `--local` selects this machine only. Either discovers only that machine and never falls back. An undeclared alias refuses `destination-unknown`. A selected root's own mailbox judges whether its overseer exists. Report the send's actual cause. The setting declares reach, never approval of a particular directive.

- `owner-note` finds a repository on the control host only in `ssh [HOST] kendex project list`, `[HOST]` being `JARVIS_CONTROL_HOST`. That list belongs to the user `ssh [HOST]` logs in as.
- The host reaches `REPO` only when that list prints the repository's main checkout as a row with no note, and the row's last path segment is `REPO`. A worktree row carries a note and does not count. Starting or registering an overseer on the host adds no row.
- Without that row, the legacy bare route tries this machine, and a local checkout with a stale overseer record takes the note. The receipt then reads `sent side=local`. With additional aliases, a bare route instead requires uniqueness across its complete candidate set. If `REPO`'s overseer runs on the host, tell the user where the receipt says the note landed and offer the row.
- To add the row, show the user the command and the repository, and run it only after the user agrees: `ssh [HOST] kendex project add [MAIN_CHECKOUT]`, once per hosted repository. It writes nothing into the checkout. It refuses a path the list already holds.
- Do not run `kendex project discover --register` over a parent folder. It adds every project it finds, and two rows whose last segment is `REPO` make `owner-note` refuse `repo-ambiguous`. With the user's yes, remove the extra row with `kendex project remove [PATH]` on that side.
- Check the result: `ssh [HOST] kendex project list` prints the row, and the next `owner-note` receipt reads `sent side=host`.
- Record the host and the repositories it lists in the consumer's own repository or tracker. This package names neither.

## Main and satellites

One machine runs the main Jarvis. Every other machine that runs Jarvis for the same owner is a satellite.

- `JARVIS_MAIN_HOST` selects the role. Empty makes this machine the main. A satellite sets it to `DEST:HOME`: `DEST` is what `ssh DEST` takes, with no whitespace, `:` or `/`, and `HOME` is the main home's absolute path on that host. A value that does not parse still makes a satellite, which reports `setting-invalid`.
- Set a satellite's value in its home's private env file, never in the committed `kendex.settings.toml`. A cloned home carries committed settings, and the main would read that value on its next pull and become a satellite.
- Only one machine leaves the setting empty. The package cannot detect a second main: two machines with an empty setting are two mains, each the fleet contact. Keep this rule in the consumer's own setup records.

### Satellite

- A satellite handles local voice, windows, apps, files, screen and sign-ins.
- It is no fleet contact. Its `watch-loop` reads its own home alone, renews no Slack hold, runs no control-host pass and schedules no progress checkpoint. `owner-note` refuses `role-satellite`.
- Do not run [Read](#read), [Answer an ask](#answer-an-ask) or [Instruct](#instruct) on a satellite. Tell the owner that the main handles that request. The package does not enforce this: a repository's own `lane-mail` reads no Jarvis role.
- Do not commit to or push the home repository from a satellite. The package cannot see a clone's commits, so this rule is held here.

### Forward

A request needs the main when it acts on an account, the fleet, the home repository or anything outside this machine.

1. Ask the owner in the conversation the request came from, with no mailbox ask. Quote the text that will be sent, name the main, say that the request and its answer will appear in the owner's Slack channel, and ask for `forward` or `yes`; otherwise the request stays on this machine. The forward sends the request as the owner's directive, so [decisions.md § Authority](decisions.md#authority) applies. Ask this question last and alone: `forward` cannot tell which question a yes answered. A console request is asked with `lane-mail notice --item overseer --to owner --ref R --file PATH`, `R` being its envelope id.
2. Write one record file under the home's `tmp/`, then run `.agents/skills/jarvis/scripts/jarvis-session forward --home HOME --record PATH`. Remove the file after exit 0 or 75.
3. The command prints one JSON line with the request reference, its delivery key, `state`, the main's directive id as `forwarded` and `cause`. Exit 0 means `delivered`. Exit 75 means the request is `queued` in the local outbox with its cause, and the watch loop retries it. Tell the owner which, and that the answer will be in the Slack thread. Answer a console confirmation with `notice --ref` on its envelope id.
4. A refusal prints `jarvis-session: forward=refused cause=KEY` on stderr, with ` field=PATH` after it for `record-invalid`, and exits 2. It enqueued and sent nothing.

The record is one JSON object of at most 65 536 bytes:

```json
{"v":1,
 "request":{"ref":"lane-mail:<id>","at":"2026-11-02T14:03:07Z","text":"<the request, verbatim>"},
 "confirmation":{"ref":"lane-mail:<id>","at":"2026-11-02T14:03:21Z","words":"Yes."}}
```

- Each `ref` cites where the turn is recorded: `lane-mail:<envelope id>` for a console message, `transcript:<session id>#<turn id>` for words typed into the session's own pane, or `vgs-audit:<id>` for a VGS conversation turn. The id is 1 to 200 characters of `A-Z a-z 0-9 . _ : @ # + / = -`. `forward` reads no row: the record is the caller's word.
- Each `at` is a UTC time in the form `YYYY-MM-DDTHH:MM:SSZ`, with an optional fraction of up to nine digits before `Z`. A console turn's `at` is its envelope's own `at`.
- `confirmation` holds `words`, the owner's words, or `method`, `voice` or `physical`, for a caller that records how the owner confirmed. One row may hold both turns, so the two references may be equal.
- The words confirm when a line is `forward`, or the whole text is `yes`, each compared after trimming, case folding and dropping one trailing `.` or `!`. Words over 300 characters do not confirm. A `method` confirms on its own.
- The delivery key comes from the home, the request reference and the request time. The same request run again, after a crash too, gets the same key, and the main lands it once while it keeps the first copy. Once the main's compaction drops that copy, a send whose receipt was lost can land a second time.

| Key | Meaning | Next step |
|---|---|---|
| `role-main` | This machine is the main. | Act on the request here. |
| `setting-invalid` | `JARVIS_MAIN_HOST` does not parse. | Fix the setting. |
| `record-unreadable` | The file is missing, too large, not UTF-8 or not one JSON object. | Fix the record; do not ask the owner again. |
| `record-invalid` | The field `field=` names breaks the shape above. | Fix the record; do not ask the owner again. |
| `confirmation-early` | The confirmation's time is before the request's. | Ask the owner again and cite the next answer. |
| `confirmation-unclear` | The words are not `forward` or a plain `yes`. | Ask the owner again and cite the next answer. |
| `answered-already` | The main answered this request within the last 30 days. | Tell the owner the main already answered it in Slack. `status --main` shows only the most recent answer, under `last_answer.request`. |
| `answer-unseen` | The main received this request within the last 30 days, and no answer was read within 7 days of its delivery. | Tell the owner to look for the answer in the request's Slack thread. Do not forward it again. |
| `request-conflict` | An open forward cites this request reference with another text or time. | Wait for it, or cite the request's own reference. |
| `outbox-unreadable` | The outbox file cannot be read; it is never reset. | Report the cause. |

### On the main

The main receives the request text, a blank line, then one line:

`forwarded-request: satellite=NAME request-ref=REF request-at=TIME confirmation-ref=REF confirmed-at=TIME key=KEY confirmation-method=words|voice|physical confirmation-text=WORDS`

`WORDS` is the owner's words as one JSON string, or `null` for a `voice` or `physical` method.

- Handle it as an owner directive and answer it with the reply form in [Instruct](#instruct) step 2. The answer reaches the owner on the main; no answer goes back to the satellite's call.
- Apply the word rule above to a `words` confirmation. A forwarded directive whose line does not parse, or whose words do not confirm, confirms nothing: ask the owner with an ordinary owner ask that quotes the request.
- A `confirmation-method=voice` forward follows orch's [communication-modes.md § Voice requests](../../orch/references/communication-modes.md#voice-requests), whose caller is the `caller=` value of a `voice-request:` first line. The record carries no caller of its own. A voice forward whose text does not open with `voice-request: caller=owner` approves no step only the owner may approve: ask the owner with an ordinary owner ask that quotes the request.
- The line cites the satellite's records; the main cannot check them. The owner or a reviewer looks a reference up on the satellite.

### Status

`jarvis-session status --home HOME --main` reports the role, whether the main was reachable at the last call, the last answer, and every open forward with its state and cause. The [session workflow](../workflows/session.md#session-command) lists them. An answered forward closes; its answer shows as `last_answer`, the answer the main wrote last. A forward with no answer read within 7 days of its delivery closes as `answer-unseen`: the main's compaction dropped the answer by age before the satellite read it, or the main answered without `--ref`. The drain prints it as `EVENT forward-failed` for 30 days after the close, and the satellite reads the main for it no more.

## Transcript fallback

Until the mailbox install, answer from the agent's own session transcript under [Weekly efficiency audit: Transcript access](../workflows/efficiency-audit.md#transcript-access). Use available documented read-only readers first. Before reading internal files, record why the installed reader is unavailable or which required evidence it cannot supply.

Resolve transcript roots under [Weekly efficiency audit: Inputs](../workflows/efficiency-audit.md#inputs). The user's own location takes precedence. Use the file selectors below only when original file access is required under the transcript access contract.

| Harness | Session file for repository folder `[ROOT]` |
|---|---|
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/[FOLDER]/[SESSION_ID].jsonl`. `[FOLDER]` is `[ROOT]` with each character other than an ASCII letter or digit changed to `-`. A name over 200 characters is cut at 200 and followed by `-` and a hash; match it by that prefix. |
| Codex | `${CODEX_HOME:-~/.codex}/sessions/[YYYY]/[MM]/[DD]/rollout-*.jsonl` whose first line, a `session_meta` record, carries `payload.cwd` equal to `[ROOT]`. |
| Copilot CLI | `${COPILOT_HOME:-~/.copilot}/session-state/[SESSION_ID]/events.jsonl` whose sibling `workspace.yaml` has the `cwd:` line `[ROOT]`. |
| Pi | Discover the installed version's configured session directory under [Weekly efficiency audit: Inputs](../workflows/efficiency-audit.md#inputs). Confirm the session's recorded working directory belongs to `[ROOT]`. Report no transcript only when no matching session is available. |

- Select the newest session whose recorded repository identity matches `[ROOT]` and name it, so the user can correct the choice.
- The transcript is read only. Read it as a stream, only its last entries, and write nothing.
- Never read a tmux pane or a screen: `capture-pane` and screen capture are not a route.
- Quote no credential from the file; [accounts-and-secrets.md § Secret transfer](accounts-and-secrets.md#secret-transfer) applies.
- Open the answer with "From the session transcript, not a report from the agent". Name the original file and the time of its last entry when accessible. Otherwise name the reader and the unavailable evidence. Say when no transcript was found. Then offer the mailbox install.
