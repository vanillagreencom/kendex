# Copilot CLI runtime reference

How orch launches, resumes, wakes, closes and succeeds a GitHub Copilot CLI (`copilot`) session. Everything here is Copilot-specific. A fact marked measured was read off Copilot CLI 1.0.88; every other fact is the CLI's own `--help`, `copilot help config` or `copilot help environment` text for that version.

## Session record

A session keeps its state under `${COPILOT_HOME:-~/.copilot}/session-state/<session-id>/`:

- `workspace.yaml` holds plain `id:` and `cwd:` lines, written as the session starts and before any turn (measured).
- `events.jsonl` holds the session's events. A session that ended before its first event, for example one whose sign-in failed, has none (measured).

`lib/lane-relaunch.sh` reads these two files and nothing else. No live context count is in either: the CLI's status-line command is the only producer of one, and orch keeps no Copilot status-line record yet. So a Copilot lane's context and account marks are unmeasured, as the `lane-mail-check` hook reports.

## Launch environment

Every command `open-terminal` and the overseer launchers build for Copilot carries these, on a fresh start, a relaunch, a wake and a successor alike. `lib/lane-launch.sh` holds each: the `LAUNCH_CHOICE_FLAGS` copilot row and `lane_copilot_env`.

| Words | Why |
|-------|-----|
| `--model`, `--reasoning-effort` | The caller's `--launch-flags`. A launch under `--lane` that names neither refuses as `launch-model-missing` and `launch-effort-missing` (`open-terminal --help`). |
| `--allow-all` | The permission posture. A resumed session ignores `defaultPermissionMode` from settings, so the flag rides on every resume. |
| `--no-ask-user` | Takes the `ask_user` tool away, on every lane and on an overseer while `ORCH_QUESTION_TOOL` is `off`, its default. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)). |
| `--autopilot --max-autopilot-continues 3` | Continues a turn that stopped short, at most three times, with nobody at the pane. |
| `--context long_context` | The long context tier, named on the command and not left to `contextTier` in the account's settings. |
| `--no-auto-update` | The CLI runs the version the host installed and downloads none. |
| `env -u GH_TOKEN -u GITHUB_TOKEN` | Copilot takes either variable as its sign-in ahead of a stored login. On a fleet host they hold the GitHub App's token. `COPILOT_GITHUB_TOKEN`, the account token a host exports, outranks both and passes through. No token value enters a command. |
| `COPILOT_ALLOW_ALL=true` | Exactly `true` also trusts the working directory, so no folder-trust dialog opens and the worktree's hooks and skills load. `--allow-all` alone does not trust the folder. |
| `COPILOT_SKILLS_DIRS=~/.agents/skills` | Any `COPILOT_HOME` hides the shared skills under `~/.agents/skills`; this names them back (`tools/harness-smoke`, row `skill-dirs:COPILOT_HOME`). |
| `COPILOT_HOME=<account>` | The account, where a lane is named. A launch naming none opens on the `COPILOT_HOME` the pane inherits. |

`continueOnAutoMode` has no flag. Its default is `false`, which keeps the model on a rate limit instead of moving to Auto. It stays `false` only while the account's `settings.json` does not set it `true`.

A `--cmd` launch carries none of these by itself: its command is the caller's own ([lane-directive.md](lane-directive.md)).

## Recovery

A lane relaunched with `open-terminal --relaunch` ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)) resumes by explicit session id, `copilot --resume=<id> -i <continuation line>`. It never uses bare `--resume`, which opens a picker.

| Case | What the relaunch does |
|------|------------------------|
| Killed pane | Resumes the newest session record whose `cwd:` is the lane's worktree and that holds events. |
| Session ended before its first event | Passes that record over. `--resume=<id>` on it exits 1 with `No session, task, or name matched`, under `-p` and at a pane, and opens no picker (measured). An older record in the same worktree resumes in its place; with none, the start brief runs. |
| No record | Renders the start brief. |
| Harness switch | Reads only the relaunch harness's own store, so a lane that ran on another harness starts afresh. |
| Retired session | A standing handoff record (`workflow-state handoff-standing` answers `stands`) means the lane ended that session. The relaunch looks for no session, reports `session-retired`, and renders the start brief, whose [start.md](../workflows/start.md) § 0 continues from the record. This holds for every harness. A verdict that cannot be read refuses as `handoff-unreadable`. |
| Hosted lane | None. `lane-host` has no Copilot provider, so no Copilot lane runs on another machine. |

## Wake and lane mail

`open-terminal --wake --harness copilot` resumes the lane's session in print mode, `copilot --resume=<id> -p <inbox line>`, as a second process. Copilot publishes no idle signal. So while a Copilot process runs in the lane's worktree the wake refuses the lane, as `working` where the process has a shell under it and `unjudged` otherwise ([lane-reach.md § Wake refusals](lane-reach.md#wake-refusals)). A lane with no resumable session refuses as `session-missing`.

The lane's own wake is its `lane-mail watch --once` monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Mail the monitor and the hooks do not deliver takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver): stop, close with `--keep-sandbox`, relaunch.

## Lane close

`lane-close` ends an idle Copilot lane by SIGTERM to its native process, named `MainThread` on Linux ([lane-reach.md § Lane close](lane-reach.md#lane-close)). A working lane refuses as `lane-live`. A Copilot limit banner that says `You've hit your … limit` or `You've reached your … limit` matches the shared banner pattern in `lib/lane-state.sh`, and `lanes` measures no Copilot account, so such a lane stays `walled` and refuses as `lane-live state=walled`.

## Overseer succession

`oversee-succeed` builds a Copilot overseer's line in print mode alone, on the account its launch record names, through the same launch environment. Every mode that judges a mark or picks an account refuses as `copilot-unmeasured`, because `lanes` makes no reading of a Copilot account. A record that names no account refuses as `copilot-account-unknown`; `oversee register --account DIR` records one. A dead overseer pane relaunches from the recorded line: a fresh session that reads the overseer handoff, never a resume.

## Pending live proofs

No Copilot model turn ran on the machine where this reference was written, so each row below is unproved on a live session.

| Proof | Command |
|-------|---------|
| A killed lane pane resumes its session and runs the continuation line | Kill the lane's window, then `open-terminal --relaunch --harness copilot --lane <account> --launch-flags '<flags>' <ITEM>`; the pane shows the resumed transcript and the lane runs `lane-mail inbox` |
| A resume keeps model, effort, context tier and allow-all | In the resumed pane, `/model` and the footer name the model, effort and tier the command named, and a tool call runs with no prompt |
| `COPILOT_ALLOW_ALL=true` opens a new worktree with no trust dialog | A first launch into a fresh worktree reaches its first turn with no `Confirm folder trust` screen |
| A second process on a session: the wake's `-p` run beside a live interactive one | Not made by orch: the wake refuses a live Copilot process |
| A Copilot overseer succession on its recorded account | `oversee-succeed --print-launch-line --harness copilot -- <flags>`, then run the line in a fresh pane |
