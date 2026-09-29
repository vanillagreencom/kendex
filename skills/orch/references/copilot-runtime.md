# Copilot CLI runtime reference

How orch launches, measures, resumes, wakes, closes and succeeds a GitHub Copilot CLI (`copilot`) session, and what a Copilot account needs for it. Everything here is Copilot-specific. A fact marked measured was read off Copilot CLI 1.0.88, by hand or by the `tools/harness-smoke` row it names. A fact that cites `copilot --help`, `copilot help config` or `copilot help environment` is that text for the same version. Everything else is what orch's own scripts do, and each rule is owned by the script named beside it.

## Account setup

A Copilot account is a directory the CLI runs under as `COPILOT_HOME`, such as `~/.1copilot`. `lanes` discovers `~/.copilot` and every `~/.*copilot*` directory holding `config.json` or `session-state`, which only Copilot CLI writes, and `ORCH_LANE_DIRS` names others (`lanes --help`).

| File in the account | What reads it | Without it |
|---|---|---|
| `config.json` with a stored login | The CLI's own login, from `copilot login` or the fleet's seat delivery. A launch signs in with it, `COPILOT_GITHUB_TOKEN` cleared (§ Launch environment), and `lanes` asks GitHub's usage endpoint for the account's monthly credit pool with it (`scripts/lib/copilot-credits.sh` states the layout it assumes). No token is copied or handed to a launch. | The launch has no identity, and `lanes` reads the account `no_credentials` under the reason, or its `ORCH_LANE_COPILOT_POOL` reading where one is stated. |
| `settings.json` with `statusLine` | `"statusLine": {"type": "command", "command": "<repo>/.agents/skills/orch/scripts/copilot-statusline", "refreshInterval": 30}`, the command an executable file and the interval under 120 seconds. The command writes the session record the lane's turn-end hook reads its context from; the header of `scripts/copilot-statusline` states the record. | No context reading: the hook reports `session-record=missing`, and a fleet launch refuses the lane as `unsupported-for-oversee reason=status-line`, and an overseer succession skips the account. |

## Session record

A session keeps its state under `${COPILOT_HOME:-~/.copilot}/session-state/<session-id>/`:

- `workspace.yaml` holds plain `id:` and `cwd:` lines, written as the session starts and before any turn (measured).
- `events.jsonl` holds the session's events. A session that ended before its first event, for example one whose sign-in failed, has none (measured).

`lib/lane-relaunch.sh` reads these two files and nothing else. No live context count is in either: the CLI's status-line command is the only producer of one, and `scripts/copilot-statusline` records it (§ Measurement).

## Launch environment

Every Copilot command `open-terminal`, `oversee` and `oversee-succeed` build carries every row below, on a fresh start, a relaunch, a wake and a successor alike. A `--cmd` template `open-terminal` wraps carries the environment rows alone. `scripts/lib/lane-launch.sh` holds them: the `LAUNCH_CHOICE_FLAGS` copilot row, and `lane_copilot_env` for the environment, in front of a local launch with `COPILOT_HOME` (`lane_launch_line`) and of a hosted one, whose provider sets `COPILOT_HOME`.

| Words orch adds | Why |
|-----------------|-----|
| `--autopilot --max-autopilot-continues 3` | Continues a turn that stopped short, at most three times, with nobody at the pane. |
| `--context long_context` | The long context tier, named on the command and not left to `contextTier` in the account's settings. |
| `--no-auto-update` | The CLI runs the version the host installed and downloads none. |
| `--no-ask-user` | Takes the `ask_user` tool away, on every lane and on an overseer while `ORCH_QUESTION_TOOL` is `off`, its default. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)). |
| `-u COPILOT_GITHUB_TOKEN` | Copilot reads `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`, then the login stored in the account's `config.json` (`copilot help environment`). Copilot refuses a placeholder handed in `COPILOT_GITHUB_TOKEN`, so that one is cleared. `GH_TOKEN` and `GITHUB_TOKEN` stay, so a lane's own `gh` calls keep signing in: a fleet host holds the GitHub App token (`ghs_`) there, which Copilot 1.0.88 skips with `Unsupported token type, ignoring`, and the identity stays the account's stored login (§ Account setup). On a workstation, a user token in either one, a `gho_` token or a personal access token, signs Copilot in as that user instead. No token value enters a command. |
| `COPILOT_ALLOW_ALL=true` or `COPILOT_ALLOW_ALL=` (empty) | `true` only where the command carries `--allow-all` or `--yolo`. `copilot help environment`: any truthy value approves every tool, and exactly `true` also trusts the working directory without prompting and loads its hooks and skills. So it adds folder trust to the posture the caller chose. Every other command carries it empty, so a `COPILOT_ALLOW_ALL` the launching shell exports does not reach it: it keeps its permission prompts and its folder-trust dialog. An assignment a `--cmd` template writes itself comes after, and wins. |
| `COPILOT_SKILLS_DIRS=~/.agents/skills` | Any `COPILOT_HOME` hides the shared skills under `~/.agents/skills`, and this names them back: measured by `tools/harness-smoke`, row `skill-dirs:COPILOT_HOME`. |
| `COPILOT_HOME=<account>` | The account: the lane a local launch names, or with none the `COPILOT_HOME` `open-terminal` runs under, `~/.copilot` where that is unset, which is the store a relaunch reads (`lib/lane-relaunch.sh`). A hosted launch's provider sets it. |

The first three rows are launch settings. A caller's copy of any one of them, typed whole, is dropped, so none appears twice. A `--cmd` template gets the environment words and no flag words: its command is the caller's own ([lane-directive.md](lane-directive.md)).

| Words the caller passes in `--launch-flags` | Why |
|---------------------------------------------|-----|
| `--model`, `--reasoning-effort` | A launch under `--lane` that names neither refuses as `launch-model-missing` and `launch-effort-missing` (`open-terminal --help`). |
| `--allow-all` | The permission posture. A resumed session ignores `defaultPermissionMode` from settings (`copilot help config`), so a resume carries `--allow-all` only where the relaunch's `--launch-flags` carry it. A launch without it prints `permission-prompt`, carries an empty `COPILOT_ALLOW_ALL`, and still launches. |

`continueOnAutoMode` has no flag. Its default is `false`, which keeps the model on a rate limit instead of moving to Auto. It stays `false` only while the account's `settings.json` does not set it `true`.

## Measurement

- Context: `scripts/lib/adapters/copilot.sh` reads the session record, held to the session id, transcript, account and a freshness bound by `scripts/lib/copilot-session.sh`, and hands the shared judge the window's documented compaction point as capacity ([oversee-events.md](oversee-events.md#judgement-rules), Hand off a lane). The record is no credit source.
- Credits: `lanes` reads the monthly pool through `scripts/lib/copilot-credits.sh`; the record it produces is [schemas/copilot-credits.md](../schemas/copilot-credits.md). A Pi root on a `github-copilot/` model is judged on its stated `ORCH_LANE_COPILOT_POOL` reading, since nothing here reads a Pi root's Copilot login.

## Recovery

A lane relaunched with `open-terminal --relaunch` ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)) resumes by explicit session id, `copilot --resume=<id> -i <continuation line>`. It never uses bare `--resume`, which opens a picker.

| Case | What the relaunch does |
|------|------------------------|
| Killed pane | Resumes the newest session record whose `cwd:` is the lane's worktree and that holds events. |
| Session ended before its first event | Passes that record over. `--resume=<id>` on it exits 1 with `No session, task, or name matched`, under `-p` and at a pane, and opens no picker (measured). An older record in the same worktree resumes in its place; with none, the start brief runs. |
| No record | Renders the start brief. |
| Harness switch | Reads only the relaunch harness's own store, so a lane that ran on another harness starts afresh. |
| Retired session | A standing handoff record means the lane ended that session. `workflow-state handoff-standing` answers `stands`, asked from the lane's worktree, where the lane wrote the record. A local relaunch of any harness then looks for no session, reports `session-retired`, and renders the start brief, whose [start.md](../workflows/start.md) § 0 continues from the record. A verdict that cannot be read refuses as `handoff-unreadable`. |
| Hosted lane | Not read here: a hosted lane's session records are on its host, and its relaunch is the provider's `create --relaunch` ([schemas/lane-host.md](../schemas/lane-host.md)). A fleet refuses a hosted Copilot lane as `unsupported-for-oversee reason=hosted`. |

## Wake and lane mail

`open-terminal --wake --harness copilot` resumes the lane's session in print mode, `copilot --resume=<id> -p <inbox line>`, as a second process. Copilot publishes no idle signal. So while a Copilot process runs in the lane's worktree the wake refuses the lane, as `working` where the process has a shell under it and `unjudged` otherwise ([lane-reach.md § Wake refusals](lane-reach.md#wake-refusals)). A lane with no resumable session refuses as `session-missing`.

The overseer sends a Copilot lane no wake ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): the wake is for an operator reaching a lane whose Copilot process is gone. The lane's own wake is its `lane-mail watch --once` monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Mail the monitor and the hooks do not deliver takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver): stop, close with `--keep-sandbox`, relaunch.

## Lane close

`lane-close` ends an idle Copilot lane by SIGTERM to its native process, named `MainThread` on Linux ([lane-reach.md § Lane close](lane-reach.md#lane-close)). A working lane refuses as `lane-live`. A Copilot limit banner that says `You've hit your … limit` or `You've reached your … limit` matches the shared banner pattern in `lib/lane-state.sh`. `lane-close` weighs a banner against the account's reading for a claude or codex lane alone, so a Copilot lane under one stays `walled` and refuses as `lane-live state=walled`.

## Overseer succession

`oversee-succeed` builds a Copilot overseer's line in print mode, on the account its launch record names, through the same launch environment, and judges its marks on that account's session record and monthly pool (§ Measurement). A record that names no account refuses as `copilot-account-unknown`; `oversee register --account DIR` records one. A dead overseer pane relaunches from the recorded line: a fresh session that reads the overseer handoff, never a resume.

## Pending live proofs

No Copilot model turn ran on the machine where this reference was written, so each row below is unproved on a live session.

| Proof | Command |
|-------|---------|
| A killed lane pane resumes its session and runs the continuation line | Kill the lane's window, then `open-terminal --relaunch --harness copilot --lane <account> --launch-flags '<flags>' <ITEM>`; the pane shows the resumed transcript and the lane runs `lane-mail inbox` |
| A resume keeps model, effort, context tier and allow-all | In the resumed pane, `/model` and the footer name the model, effort and tier the command named, and a tool call runs with no prompt |
| `COPILOT_ALLOW_ALL=true` opens a new worktree with no trust dialog | A first launch into a fresh worktree reaches its first turn with no `Confirm folder trust` screen |
| A second process on a session: the wake's `-p` run beside a live interactive one | Not made by orch: the wake refuses a live Copilot process |
| A Copilot overseer succession on its recorded account | `oversee-succeed --print-launch-line --harness copilot -- <flags>`, then run the line in a fresh pane |
