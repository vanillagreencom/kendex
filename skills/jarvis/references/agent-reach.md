# Agent reach

Read when the user asks about, or wants to instruct, the agent working in one of their kendex projects.

## Route

- The repository mailbox is the one route to another repository's agent, with a fleet or without one. A repository is reachable when the [mailbox](../../mailbox/SKILL.md) package is installed there; [SKILL.md § Reachable repositories](../SKILL.md#reachable-repositories) judges which are.
- `[LANE_MAIL]` below is the repository's own `.agents/skills/mailbox/scripts/lane-mail`, run with the repository's main checkout as the working directory. Do not use the Jarvis home's `lane-mail` or its `peer send`: a peer send reaches the agent as another repository's note, not as the user's.
- Take repositories only from `kendex project list`. Each line is a folder, then optional notes in parentheses: `(folder not found)`, `(not a folder)`, `(folder could not be read)` or `(worktree of [MAIN])`. A worktree line stands for `[MAIN]`, where its mailbox sits.
- A fleet changes nothing here: Jarvis reads the repository's overseer mailbox, and a hosted lane's own mailbox stays the overseer's to read. A repository on another machine is unreachable from this one. The one exception is a directive to a repository on the control host through `.agents/skills/jarvis/scripts/owner-note REPO FILE`, which makes the send below on that host.
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
3. The directive carries the user's authority, so [decisions.md § Authority](decisions.md#authority) applies: show the user the exact text and the repository, and send only after the user agrees.
4. Run `[LANE_MAIL] send --item overseer --directive --file [PATH]`.
5. The send is made only when stdout printed `lane-mail: sent item=overseer id=[DIRECTIVE_ID]`. Without that receipt nothing was sent. The receipt says the directive landed, not that the agent read it; the agent's notice with `ref` `[DIRECTIVE_ID]` is its answer.

## One voice

The agent's notice reaches Jarvis, and Jarvis decides what the user hears. Set no per-agent speech or reply setting.

## Refusals

Report each refusal in plain words. Do not retry it or work around it.

| Key | Meaning | Next step |
|---|---|---|
| `overseer-absent` | No session is registered to read that repository's mail; nothing was sent. A second line saying orch is not installed means the repository has mailbox alone. | Without orch, offer the [directive install](#install). With orch, say that the agent's session must run orch's `oversee register` in its own tmux pane. |
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
