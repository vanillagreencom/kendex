# Copilot CLI runtime reference

How orch launches, measures, resumes, wakes, closes and succeeds a GitHub Copilot CLI (`copilot`) session, and what a Copilot account needs for it. Everything here is Copilot-specific. A fact marked measured was read off Copilot CLI 1.0.88, by hand or by the `tools/harness-smoke` row it names. A fact that cites `copilot --help`, `copilot help config` or `copilot help environment` is that text for the same version. Everything else is what orch's own scripts do, and each rule is owned by the script named beside it.

## Account setup

A Copilot account is a directory the CLI runs under as `COPILOT_HOME`, such as `~/.1copilot`. `lanes` discovers `~/.copilot` and every `~/.*copilot*` directory holding `config.json` or `session-state`, which only Copilot CLI writes, and `ORCH_LANE_DIRS` names others (`lanes --help`).

| File in the account | What reads it | Without it |
|---|---|---|
| `config.json` with a stored login | The CLI's own login, from `copilot login` or the fleet's seat delivery; where the CLI keeps the token in the platform's credential store, config.json names only the login, and `lanes` reads the token from the Linux Secret Service through `secret-tool`, never from another platform's store such as the macOS Keychain. A launch signs in with it, `COPILOT_GITHUB_TOKEN` cleared (§ Launch environment), and `lanes` asks GitHub's usage endpoint for the account's monthly credit pool with it (`scripts/lib/copilot-credits.sh` states the layout it assumes). No token is copied or handed to a launch. | The launch has no identity, and `lanes` reads the account `no_credentials` under the reason, or its `ORCH_LANE_COPILOT_POOL` reading where one is stated. |
| `settings.json` with `statusLine` | `"statusLine": {"type": "command", "command": "<repo>/.agents/skills/orch/scripts/copilot-statusline", "refreshInterval": 30}`, the command an executable file and the interval under 120 seconds. The command writes the session record the lane's turn-end hook falls back to where the `kendex-lane-context` extension recorded no reading of the session, and the one record that carries `allow_all_enabled` (§ Allow-all blocked by policy); the header of `scripts/copilot-statusline` states the record. | No fallback reading, and no reader can report an allow-all block. A lane whose session the extension records loses no context reading. Where `EXTENSIONS` is false, a fleet launch refuses the lane as `unsupported-for-oversee reason=no-context-reader detail=disabled`, `cause=` naming what failed in the status line. A session with neither reading reports `reading-unrecorded` and `session-record=missing`. |

## Session record

A session keeps its state under `${COPILOT_HOME:-~/.copilot}/session-state/<session-id>/`:

- `workspace.yaml` holds plain `id:` and `cwd:` lines, written as the session starts and before any turn (measured).
- `events.jsonl` holds the session's events. A session that ended before its first event, for example one whose sign-in failed, has none (measured).

`lib/copilot-session.sh` reads these two files, for the relaunch in `lib/lane-relaunch.sh` and for the readers in § Allow-all blocked by policy, and nothing else does. No live context count is in either. A fleet session's context is read by the `kendex-lane-context` Copilot extension that the shared installer in `scripts/lib/adapters/copilot.sh` installs in its `COPILOT_HOME` for `open-terminal`, `oversee launch`, `oversee register` and succession, [`scripts/copilot-lane-context/extension.mjs`](../scripts/copilot-lane-context/extension.mjs): it hands `lane-mail-check` each `session.usage_info` reading, which the turn end judges. A reading handed on and not yet recorded, or one the extension could not read, leaves a pending marker under `~/.cache/lane-mail/copilot-usage`, and a turn end that finds it still standing after 5 seconds reports the context unmeasured under `reading-pending`. The shared installer makes that directory and writes and removes one probe file there before a fleet session starts, since a reading the extension cannot mark leaves the earlier record standing as room; where it cannot, it refuses the lane as `unsupported-for-oversee reason=no-context-reader detail=pending-unwritable`, `file=` naming the directory. Where no extension reading of the session stands and no pending marker does, the turn end falls back to the session record the account's status-line command writes, which `scripts/copilot-statusline` records (§ Measurement).

## Launch environment

`scripts/lib/lane-launch.sh` owns the Copilot rows below: `LAUNCH_CHOICE_FLAGS` for launch settings and `lane_copilot_env` for environment. `lane_launch_line` supplies the local `COPILOT_HOME`; a hosted provider supplies its own. Command templates follow [lane-directive.md § Lane preference](lane-directive.md#lane-preference).

| Words orch adds | Why |
|-----------------|-----|
| `--autopilot --max-autopilot-continues 3` | Continues a turn that stopped short, at most three times, with nobody at the pane. |
| `--context long_context` | The long context tier, named on the command and not left to `contextTier` in the account's settings. |
| `--no-auto-update` | The CLI runs the version the host installed and downloads none. |
| `--no-ask-user` | Takes the `ask_user` tool away, on every lane and on an overseer while `ORCH_QUESTION_TOOL` is `off`, its default. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)). |
| `-u COPILOT_GITHUB_TOKEN` | Copilot reads `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`, then the login stored in the account's `config.json` (`copilot help environment`). Copilot refuses a placeholder handed in `COPILOT_GITHUB_TOKEN`, so that one is cleared. `GH_TOKEN` and `GITHUB_TOKEN` stay, so a lane's own `gh` calls keep signing in: a fleet host holds the GitHub App token (`ghs_`) there, which Copilot 1.0.88 skips with `Unsupported token type, ignoring`, and the identity stays the account's stored login (§ Account setup). On a workstation, a user token in either one, a `gho_` token or a personal access token, signs Copilot in as that user instead. No token value enters a command. |
| `COPILOT_ALLOW_ALL=true` or `COPILOT_ALLOW_ALL=` (empty) | `true` only where the command carries `--allow-all` or `--yolo`. `copilot help environment`: any truthy value approves every tool, and exactly `true` also trusts the working directory without prompting and loads its hooks and skills. So it adds folder trust to the posture the caller chose. Every other command carries it empty, so a `COPILOT_ALLOW_ALL` the launching shell exports does not reach it: it keeps its permission prompts and its folder-trust dialog. An assignment an explicit-model `--cmd` writes itself comes after, and wins. |
| `COPILOT_SKILLS_DIRS=~/.agents/skills` | Any `COPILOT_HOME` hides the shared skills under `~/.agents/skills`, and this names them back: measured by `tools/harness-smoke`, row `skill-dirs:COPILOT_HOME`. |
| `COPILOT_HOME=<account>` | The account: the lane a local launch names, or with none the `COPILOT_HOME` `open-terminal` runs under, `~/.copilot` where that is unset, which is the store a relaunch reads (`lib/lane-relaunch.sh`). A hosted launch's provider sets it. |

| Words the caller passes in `--launch-flags` | Why |
|---------------------------------------------|-----|
| `--model`, `--reasoning-effort` | A launch under `--lane` that names neither refuses as `launch-model-missing` and `launch-effort-missing` (`open-terminal --help`). |
| `--allow-all` | The permission posture. A resumed session ignores `defaultPermissionMode` from settings (`copilot help config`), so a resume carries `--allow-all` only where the relaunch's `--launch-flags` carry it. A launch without it prints `permission-prompt`, carries an empty `COPILOT_ALLOW_ALL`, and still launches. |

`continueOnAutoMode` has no flag. Its default is `false`, which keeps the model on a rate limit instead of moving to Auto. It stays `false` only while the account's `settings.json` does not set it `true`.

## Measurement

- Context: the `kendex-lane-context` extension's reading of Copilot's `session.usage_info` is read first, against 80 percent of `tokenLimit`, the limit Copilot compacts at (`scripts/lib/lane-context.sh`, `LANE_CONTEXT_COPILOT_COMPACTION_PCT`). Where no such reading of the session stands, `scripts/lib/adapters/copilot.sh` reads the session record, held to the session id, transcript, account and a freshness bound by `scripts/lib/copilot-session.sh`, and hands the shared judge the same share of the window as capacity ([oversee-events.md](oversee-events.md#judgement-rules), Hand off a lane). The record is no credit source.
- Credits: `lanes` reads the monthly pool through `scripts/lib/copilot-credits.sh`; the record it produces is [schemas/copilot-credits.md](../schemas/copilot-credits.md). Nothing here reads a Pi root's Copilot login, so a Pi root on a `github-copilot/` model is judged on the lane host's `harness=pi` accounts row for it ([lane-host.md](../schemas/lane-host.md)), or on its stated `ORCH_LANE_COPILOT_POOL` override where no row reads it.

## Allow-all blocked by policy

Enterprise managed settings can block the allow-all mode. GitHub delivers them per account from the server, or per machine through device management or a `managed-settings.json` file, and a machine delivery stays active when the CLI signs in to another account. The CLI checks for new settings about once an hour ([Choosing how to deploy enterprise-managed settings](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-managed-settings/deploy-managed-settings)). So a lane launched with `--allow-all` can lose it mid-run, and each tool call then waits on a permission prompt that nobody at the pane answers. The session record keeps the CLI's `allow_all_enabled`, and the `kendex-lane-context` extension's reading does not, so every reader below reads the session record. A lane launched without `--allow-all` or `--yolo` reads `false` too, and its prompts are expected. So the stop cause `allow-all-blocked-by-policy`, which `scripts/lib/copilot-session.sh` names, applies only to a lane whose launch granted the full allow-all mode. `open-terminal` records that grant twice where the launch or relaunch command carries it: `allow_all: true` in the fleet record, and `COPILOT_ALLOW_ALL=true` on the launch line. Three readers report it:

| Reader | When it reads | What it prints |
|---|---|---|
| `oversee-watch` | At each pass where a lane that a running fleet record names as a Copilot lane with `allow_all: true` shows a prompt or sits idle. A changed note under an unchanged screen prints `lane-asking` or `idle-after-return` again | `stop-cause=allow-all-blocked-by-policy` on the event line, or `session-record=<reason>` where the record does not answer |
| `lanes state [WINDOW]` | When a pane on this tmux server carries the window and a running fleet record names it as a Copilot lane with `allow_all: true` | `lanes: stop-cause=allow-all-blocked-by-policy` on stderr, beside the state the pane shows, or `lanes: session-record=<reason>` |
| The `lane-mail-check` turn-end hook | At a turn end whose record answers, in a session whose `COPILOT_ALLOW_ALL` is `true`, whether or not the extension recorded a context reading of the session | `lane-mail-check: stop-cause=allow-all-blocked-by-policy`. The turn end is judged as usual. This hook reads no fleet record, so it takes the grant from the launch line's `COPILOT_ALLOW_ALL`, which is empty on a launch without allow-all. |

The first two find the session by the record's `session_id` where a relaunch or a wake wrote one. Otherwise they take the earliest session in the lane's worktree that was started at or after the record's `session_since`: the time `open-terminal` read before the launch or relaunch that started the lane's running session opened its terminal. A session that a fresh relaunch retired started before that time, and a later Copilot session in the same worktree, such as a second-opinion run, started after the lane's own, so neither is read in its place. The record's `launched_at` is not read: a relaunch keeps it. A record with no `session_since` that parses takes the newest session in the worktree. They read it under the record's `account`, or under the account a launch with no `--lane` runs on. A lane that waits at a permission prompt reaches no turn end, so the first two are the readers that see it. A fleet has no hosted Copilot lane (§ Recovery), so every read is on this machine.

| `session-record=` reason | Meaning | Remedy |
|---|---|---|
| `missing`, `stale` | The account's status line writes no record, or stopped refreshing it | Set the account's `statusLine` (§ Account setup) |
| `worktree-unmatched` | The fleet record names no session, and no session with events ran in the lane's worktree under that account since the launch that started the lane's running session | Check the record's `account` and `mail_root` |
| `store-unreadable` | The worktree or the account's `session-state` could not be read | Fix the path or its permissions |
| `unbound` | The session id the fleet record or `workspace.yaml` names is empty or is not an id | Check the record's `session_id` and the session's `workspace.yaml` |
| `unreadable`, `wrong-session`, `wrong-account` | The record file is not one `lib/copilot-session.sh` wrote for this session and account | Remove the file under `<account>/lane-status/` and let the status line write it again |
| `wrong-transcript` | The record names another transcript than the one the turn-end hook's payload names. Only the hook passes a transcript, so only the hook prints this reason | Remove the file under `<account>/lane-status/` and let the status line write it again |

The remedy for the block is the owner's. Tell the owner the account and the cause: an enterprise administrator lifts an account block, and the machine's administrator lifts a machine block. To move the item meanwhile:

1. Where a lane of another Copilot account, launched with allow-all, runs on this machine, run `lanes state` on it. Where it prints neither a `stop-cause=` nor a `session-record=` line, the block is not the machine's; a `session-record=` line settles nothing about the machine. Where it also prints `stop-cause=allow-all-blocked-by-policy`, the block comes from this machine or from an enterprise that licenses both accounts, and another account does not help. Tell the owner both accounts and both possible administrators: the machine's, and that enterprise's. A relaunched lane that reports the same cause shows the same: stop it and wait for the owner.
2. Stop the blocked lane first, by [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver) steps 1 to 3, so two sessions never run in one worktree.
3. Relaunch the item with `--lane` naming the other account ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)). The relaunch finds no session of the item under that account, so it starts afresh on the item's branch and does not resume the blocked session.

## Recovery

A lane relaunched with `open-terminal --relaunch` ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)) resumes by explicit session id, `copilot --resume=<id> -i <continuation line>`. It never uses bare `--resume`, which opens a picker.

| Case | What the relaunch does |
|------|------------------------|
| Killed pane | Resumes the newest session record whose `cwd:` is the lane's worktree and that holds events. |
| Session ended before its first event | Passes that record over. `--resume=<id>` on it exits 1 with `No session, task, or name matched`, under `-p` and at a pane, and opens no picker (measured). An older record in the same worktree resumes in its place; with none, the start brief runs. |
| No record | Renders the start brief. |
| Harness switch | Under `--state-dir`, a fleet record that names another harness as the last one to run the lane starts fresh, reported as `harness-switched`, and no session store is read. Where no record names a harness, the relaunch reads only the relaunch harness's own store, so a lane that ran on another harness starts afresh. |
| Retired session | A standing handoff record means the lane ended that session. `workflow-state handoff-standing` answers `stands`, asked from the lane's worktree, where the lane wrote the record. A local relaunch of any harness then looks for no session, reports `session-retired`, and renders the start brief, whose [start.md](../workflows/start.md) § 0 continues from the record. A verdict that cannot be read refuses as `handoff-unreadable`. |
| Hosted lane | Not read here: a hosted lane's session records are on its host, and its relaunch is the provider's `create --relaunch` ([schemas/lane-host.md](../schemas/lane-host.md)). A fleet refuses a hosted Copilot lane as `unsupported-for-oversee reason=hosted`. |

## Wake and lane mail

`open-terminal --wake --harness copilot` resumes the lane's session in print mode, `copilot --resume=<id> -p <inbox line>`, as a second process. Copilot publishes no idle signal. So while a Copilot process runs in the lane's worktree the wake refuses the lane, as `working` where the process has a shell under it and `unjudged` otherwise ([lane-reach.md § Wake refusals](lane-reach.md#wake-refusals)). A lane with no resumable session refuses as `session-missing`.

The overseer sends a Copilot lane no wake ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): the wake is for an operator reaching a lane whose Copilot process is gone. The lane's own wake is its `lane-mail watch --once` monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Mail the monitor and the hooks do not deliver takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver): stop, close with `--keep-sandbox`, relaunch.

## Lane close

`lane-close` ends an idle Copilot lane by SIGTERM to its native process, named `MainThread` on Linux ([lane-reach.md § Lane close](lane-reach.md#lane-close)). A working lane refuses as `lane-live`. A Copilot limit banner that says `You've hit your … limit` or `You've reached your … limit` matches the shared banner pattern in `lib/lane-state.sh`. `lane-close` weighs a banner against the account's reading for a claude or codex lane alone, so a Copilot lane under one stays `walled` and refuses as `lane-live state=walled`.

## Overseer succession

`oversee-succeed` builds a Copilot overseer's line in print mode, on the account its launch record names, through the same launch environment, and judges its marks on the context reading its turn end hands it, the extension's where one stands and else that account's session record, and on its monthly pool (§ Measurement). The account walk runs the shared installer before a new Copilot session starts, including a retained caller account. It keeps an explicit `EXTENSIONS=false` and skips the account as `successor-status-line` only where setup fails or no statusLine fallback serves. Register warns about missing hook coverage and newly installed readers loading at the next start. Its Copilot gate is the shared adapter gate; other harnesses use `kendex list --harness H`. SessionStart reports a fleet-recorded Copilot overseer with no reader as context, even without a mailbox file. A record that names no account takes the account the Copilot process under the pane was started on, its `COPILOT_HOME` else its home's `.copilot`, read in place of the session's own sessionStart row, which a session started before the hook install or with no overseer mailbox never writes and which `ol_caller_known` keeps only for claude or codex; where that environment cannot be read, as on a host without `/proc`, it refuses as `copilot-account-unknown`, and `oversee register --account DIR` records one. A dead overseer pane relaunches from the recorded line: a fresh session that reads the overseer handoff, never a resume.

## Pending live proofs

No Copilot model turn ran on the machine where this reference was written, so each row below is unproved on a live session.

| Proof | Command |
|-------|---------|
| A killed lane pane resumes its session and runs the continuation line | Kill the lane's window, then `open-terminal --relaunch --harness copilot --lane <account> --launch-flags '<flags>' <ITEM>`; the pane shows the resumed transcript and the lane runs `lane-mail inbox` |
| A resume keeps model, effort, context tier and allow-all | In the resumed pane, `/model` and the footer name the model, effort and tier the command named, and a tool call runs with no prompt |
| `COPILOT_ALLOW_ALL=true` opens a new worktree with no trust dialog | A first launch into a fresh worktree reaches its first turn with no `Confirm folder trust` screen |
| A second process on a session: the wake's `-p` run beside a live interactive one | Not made by orch: the wake refuses a live Copilot process |
| A Copilot overseer succession on its recorded account | `oversee-succeed --print-launch-line --harness copilot -- <flags>`, then run the line in a fresh pane |
| Allow-all takes effect on the first fleet lane | Launch the first fleet lane with `--allow-all`; a tool call runs with no prompt, and the record under `<account>/lane-status/` reads `allow_all_enabled: true` |
| A policy block reaches the record, and the record stays fresh at a waiting prompt | On an account whose policy blocks allow-all, launch with `--allow-all`; the record reads `allow_all_enabled: false`, its `written_at` keeps moving while the prompt waits, and `lanes state [WINDOW]` prints `lanes: stop-cause=allow-all-blocked-by-policy` |
