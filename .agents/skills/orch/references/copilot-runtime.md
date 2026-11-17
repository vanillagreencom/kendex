# Copilot CLI runtime reference

Read when a lane or an overseer runs on GitHub Copilot CLI (`copilot`): its account, launch, context reading, allow-all block, relaunch, wake and close. A fact marked measured was read off the Copilot CLI version it names. A fact that cites `copilot help config` or `copilot help environment` is that help text.

## Account setup

A Copilot account is a directory the CLI runs under as `COPILOT_HOME`, such as `~/.1copilot`. The account judge chooses among the directories `AGENT_RUNTIME_ACCOUNT_DIRS` lists. An entry that holds `config.json` and no Claude `.credentials.json` is a Copilot account (agent-runtime `accounts/listing.rs` `kind_of`). A `COPILOT_HOME` the environment sets is measured but never chosen.

| File in the account | What reads it | Without it |
|---|---|---|
| `config.json` with a stored login | The CLI signs in with it. The account listing reads the login's token for GitHub's usage endpoint: from `config.json`, or from the Linux Secret Service through `secret-tool` where the CLI keeps the token in a keyring. It reads no other platform's store, such as the macOS Keychain. No token is copied or handed to a launch. | The launch has no identity. The listing reads the account `no_credentials`, or the pool `AGENT_RUNTIME_COPILOT_POOL` states for it. |
| `settings.json` with `statusLine` | `"statusLine": {"type": "command", "command": "<repo>/.agents/skills/orch/scripts/copilot-statusline", "refreshInterval": 30}`: the command an executable file, the interval a whole number of seconds under 120. The command writes the session record that the turn end reads where the context extension recorded no reading, and the one record that carries `allow_all_enabled` (§ Allow-all blocked by policy). The header of `scripts/copilot-statusline` states the record. | No fallback reading, and no reader can report an allow-all block. |
| `extensions/kendex-lane-context/extension.mjs` and `enabledFeatureFlags.EXTENSIONS` in `settings.json` | The context extension. The launch preparation installs it and sets the flag true where the flag is absent, for every local or hosted lane and controller. It hands each `session.usage_info` reading to the turn end. | A launch whose `settings.json` sets `EXTENSIONS` false is admitted only where the status line above writes the record. Otherwise it fails as `no-context-reader` with `detail=disabled` and the status line's cause as `detail_cause`. A hosted launch with the flag false fails `disabled`. |
| The three lane-mail hooks | `lane-mail-check`, `lane-mail-compact` and `lane-mail-start`, in the worktree's `.github/hooks` or the account's `hooks`. | The launch fails as `unsupported-for-oversee harness=copilot` ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)). |

Before a local fleet session starts, the preparation makes `~/.cache/lane-mail/copilot-usage` under the launcher's `HOME` and writes and removes one probe file there. Where that fails, the launch fails as `no-context-reader` with `file=` naming the directory and `detail=pending-unwritable`.

A Copilot lane can launch on a provider. Its Copilot home is the `copilot-home=` the provider's `create` answers, else `.copilot` under the host user's home. The launch installs the context reader there through the provider's files and fails `no-context-reader` where it cannot (agent-runtime `trust.rs` `hosted_copilot_reader`), then reads the three lane-mail hooks on the host. No settings layer is judged on the host.

The launch's hook refusals, each `unsupported-for-oversee harness=copilot reason=[REASON]` (agent-runtime `effects/prepare/gate.rs`), and the repair:

| Reason | Repair |
|---|---|
| `no-context-hooks` | Neither the worktree's `.github/hooks` nor the home's `hooks` holds all three hooks, each a `.sh` beside its `.json`. Install them: add `copilot` to `[install] harnesses` in `kendex.toml` and run `kendex apply`. |
| `hooks-unreadable` | A hook file named `file=` could not be read, `cause=` says why. Make that file readable; an unreadable file is never read as absent. |
| `hooks-disabled` | A settings layer or a registration `file=` names switches the hooks off (`kendex hooks-off`). Remove that switch. |
| `hooks-unjudged` | `kendex hooks-off` could not answer, with its `exit=` and `cause=`. Repair the `kendex` install. |

A local launch whose Copilot home cannot be resolved fails `home-unresolved harness=copilot`: name an `account` in the `launch-lane` request, or run the overseer with `COPILOT_HOME` or `HOME` set.

## Confinement

A Copilot lane runs unconfined on every host, under the cause `token-on-session-bus`: Copilot CLI reads its token over the session bus the wrapper hides, and its launcher writes files the wrapper keeps read-only (agent-runtime `confine.rs` `answer`). No setting changes it. `orch-runtime ready --duty launch` prints `confinement=off harness=copilot cause=token-on-session-bus`, and the launch record's `confinement` names the same answer.

## Session store

A session keeps its state under `<account>/session-state/<session-id>/` (agent-runtime `session.rs`):

- `workspace.yaml` holds plain `id:` and `cwd:` lines, written as the session starts and before any turn (measured, 1.0.88).
- `events.jsonl` holds the session's events. A session that ended before its first event, for example one whose sign-in failed, has none (measured, 1.0.88). A session with no event is no session to the relaunch.

The relaunch reads a bound session by its id. The watch's policy note finds the session of a lane's worktree when the lane record names no session id.

## Launch environment

agent-runtime's launch builder spells these words and variables for every Copilot launch: `Harness::settings_words` and `Harness::question_off_words` in `skills/agent-runtime/runtime/src/harness.rs`, and `build` in `launch.rs` beside it. A lane's command line follows [lane-directive.md § Lane preference](lane-directive.md#lane-preference).

| Words orch adds | Why |
|---|---|
| `--autopilot --max-autopilot-continues 3` | Continues a turn that stopped short, at most three times, with nobody at the pane. |
| `--context long_context` | The long context tier, named on the command and not left to `contextTier` in the account's settings. |
| `--no-auto-update` | The CLI runs the version the host installed and downloads none. |
| `--no-ask-user` | Takes the `ask_user` tool away. Every lane launch carries it. A controller carries it while `AGENT_RUNTIME_QUESTION_TOOL` is `off`, its default. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)). |
| `-u COPILOT_GITHUB_TOKEN` | Copilot reads `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`, then the login stored in the account's `config.json` (`copilot help environment`). Copilot refuses a placeholder in `COPILOT_GITHUB_TOKEN`, so that one is cleared. `GH_TOKEN` and `GITHUB_TOKEN` stay, so a lane's own `gh` calls keep signing in. A GitHub App token (`ghs_`) there is skipped by Copilot with `Unsupported token type, ignoring` (measured, 1.0.88), and the identity stays the stored login. A user token there, a `gho_` token or a personal access token, signs Copilot in as that user instead. No token value enters a command. |
| `COPILOT_ALLOW_ALL=true` or `COPILOT_ALLOW_ALL=` (empty) | `true` only on a full bypass, where the command carries `--allow-all` or `--yolo`. Any truthy value approves every tool, and exactly `true` also trusts the working directory without prompting and loads its hooks and skills (`copilot help environment`). Every other command carries it empty, so a value the launching shell exports does not reach the lane, which keeps its permission prompts and its folder-trust dialog. |
| `COPILOT_SKILLS_DIRS=$HOME/.agents/skills` | Any `COPILOT_HOME` hides the shared skills under `~/.agents/skills`, and this names them back. The pane's shell expands `$HOME` when the line runs. A launch that already sets the variable keeps its value. |
| `COPILOT_HOME=<account>` | The account the `launch-lane` request names. A request naming none runs under the home the resumed session was found under, else the runtime's `COPILOT_HOME` setting, else `~/.copilot`. |

| Fields the `launch-lane` request names | Why |
|---|---|
| `model`, `effort` | The builder spells them `--model [MODEL] --reasoning-effort [EFFORT]` (`Harness::model_words`). A request naming an `account` names both, or the launch refuses ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)). |
| `permission` | The permission words of the lane's line. Where the request names none, the launch takes the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture, `bypass` by default, and the builder adds `--allow-all`. A resumed session ignores `defaultPermissionMode` from settings (`copilot help config`), so a resume carries the same words. `--allow-all-tools` or the `native` posture carries an empty `COPILOT_ALLOW_ALL` and keeps its prompts. |

`continueOnAutoMode` has no flag. Its default is `false`, which keeps the model on a rate limit instead of moving to Auto. It stays `false` only while the account's `settings.json` does not set it `true`.

## Measurement

The turn end reads a Copilot session's context in this order (orch `turnend/marks.rs` `copilot_reading`):

1. A flag the session's automatic compaction left in its mailbox: the session is past its mark whatever a reading says, and the turn end holds until the handoff record stands.
2. The extension's reading of this session, judged against 80 percent of `tokenLimit`, the point Copilot compacts at (agent-runtime `context.rs` `COPILOT_COMPACTION_PCT`). A reading handed on and not yet recorded leaves a pending marker under `~/.cache/lane-mail/copilot-usage`. A turn end that finds the marker still standing after 5 seconds reports `reading-pending` and judges the context unmeasured.
3. The status-line record of the session, read where the extension has no reading, against 80 percent of its `context_window_size`. The record is read beside an extension reading too, for its stop cause.
4. The session's own `events.jsonl`, read where neither answers: the last `tool.execution_complete` row's `context_current_tokens` against `context_token_limit`, or the last `session.compaction_complete` row whose `success` is `true`, its `postCompactionTokens` against `tokenLimit` (measured, 1.0.112). With no such row the turn end reports `context-unmeasurable=<session>` beside the status line's `session-record=<reason>`. Where that file cannot be read, it reports `reading-unrecorded` and `session-record=<reason>`.

A gap is reported and never read as room. The shared judge hands a lane off by [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules). The record is no credit source.

Credits: the account listing reads the account's monthly pool from GitHub's `copilot_internal/user` endpoint with the stored login. [schemas/copilot-credits.md](../schemas/copilot-credits.md) states the record. A Pi root on a `github-copilot/` model is judged as [lane-directive.md § No lane has room](lane-directive.md#no-lane-has-room) says.

## Allow-all blocked by policy

Enterprise managed settings can block the allow-all mode. GitHub delivers them per account from the server, or per machine through device management or a `managed-settings.json` file. A machine delivery stays active when the CLI signs in to another account. The CLI checks for new settings about once an hour ([Choosing how to deploy enterprise-managed settings](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-managed-settings/deploy-managed-settings)). A lane launched with `--allow-all` can lose the mode mid-run, and each tool call then waits on a permission prompt nobody at the pane answers.

The status-line record keeps the CLI's `allow_all_enabled`; the extension's reading does not. A lane launched without `--allow-all` or `--yolo` reads `false` too, and its prompts are expected. So the stop cause `allow-all-blocked-by-policy` applies only to a lane whose launch granted the full allow-all mode (agent-runtime `context.rs` `CopilotRecord::stop_cause`).

| Reader | When it reads | What it prints |
|---|---|---|
| `orch-runtime lane status --item [ITEM]` | For the item's in-flight fleet record | The lane's state. It supplies no policy note. |
| The runtime watch | At each pass, for a local in-flight Copilot lane whose record carries `allow_all: true`, at its `lane-asking` line and at an `idle-after-return` line that carries no `cause=` | `stop-cause=allow-all-blocked-by-policy` where the record reports `allow_all_enabled` false, or `session-record=<reason>` where no record answers. The note is part of the line's key, so a changed note prints the line again. The record is read under the lane record's `account`, else its `home`, else the watch's `COPILOT_HOME`, else `.copilot` under its `HOME`. The session is the record's `session_id`, else the lead session of the lane's worktree in that account's store since the record's `session_since`. A hosted lane gets no note: its store is on its host. |
| The `lane-mail-check` turn-end hook | At a turn end whose status-line record answers, in a session whose launch line set `COPILOT_ALLOW_ALL=true` | `lane-mail-check: stop-cause=allow-all-blocked-by-policy`. The turn end is judged as usual. |

A lane waiting at a permission prompt reaches no turn end, so the hook reports nothing there; the watch's `lane-asking` line carries the cause. To confirm a cause by hand, read the session's record under `<account>/lane-status/<session-id>.json`.

The remedy for the block is the owner's. Tell the owner the account and the cause: an enterprise administrator lifts an account block, and the machine's administrator lifts a machine block. To move the item meanwhile:

1. Where a lane of another Copilot account, launched with allow-all, runs on this machine, read that session's fresh record under its `<account>/lane-status/`. A record for that session and account with `allow_all_enabled: false` shows a block on both accounts: from this machine, or from an enterprise that licenses both. Another account does not help then. A missing, stale or mismatched record settles nothing about the machine. Tell the owner both accounts and both possible administrators, and stop. A relaunched lane that reports the same cause shows the same: stop it and wait for the owner.
2. Stop the blocked lane first, by [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver) step 1, so two sessions never run in one worktree.
3. Relaunch the item with a `launch-lane` request whose `account` names the other account ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). A relaunch on another account starts fresh on the item's branch as `account-switched` and does not resume the blocked session.

## Session record reasons

The reason a `session-record=` note names (agent-runtime `context.rs` `copilot_record`, orch `watch/lanes.rs` `copilot_note`):

| Reason | Meaning | Remedy |
|---|---|---|
| `missing`, `stale` | The account's status line writes no record, or stopped refreshing it: a record older than 120 seconds, or stamped later than the reader's clock, is stale. | Set the account's `statusLine` (§ Account setup). |
| `unbound` | The session id is empty or outside the alphabet `A-Za-z0-9._-`: the hook's from its payload, the watch's from the lane record or the worktree's store. | Check the session id the hook was handed, or the lane record's `session_id`. |
| `worktree-unmatched` | The watch only: a lane record naming no session id names no `mail_root`, or the account's store holds no session for that worktree. | Check the lane record's `mail_root`, and that the lane's session started under that account. |
| `store-unreadable` | The watch only: the worktree path does not resolve, or the account's session store cannot be read. | Check the worktree and the account's `session-state/` directory. |
| `account-unnamed` | The watch only: a lane record naming neither `account` nor `home`, on a watch whose settings name neither `COPILOT_HOME` nor `HOME`. | Run the watch with `HOME` set. |
| `unreadable`, `wrong-session`, `wrong-account` | The file is no record `copilot-statusline` wrote for this session and account. | Remove the file under `<account>/lane-status/` and let the status line write it again. |
| `wrong-transcript` | The hook only: the record's `transcript_path` is not the folder that holds the transcript the hook's payload names. | Remove the file under `<account>/lane-status/` and let the status line write it again. |

## Recovery

A relaunch is the item's `launch-lane` request sent again ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). It resumes the session the lane record binds by explicit id, `copilot --resume=<id> -i <brief>`, and never uses bare `--resume`, which opens a picker. The route reads the lane record, the item's standing handoff and the bound session's own files under its id, never a session found by its age (orch `effects/launch.rs` `relaunch_route`, `route_of`). The rows apply in order; the first that matches decides.

| Case | What the relaunch does |
|---|---|
| No bound session | Starts a fresh session on the request's brief. |
| Harness or account switch | A lane record that names another harness starts fresh as `harness-switched`. A request on another account than the record's starts fresh as `account-switched`. |
| Bound session absent from the destination home | Starts fresh as `session-absent`. The destination is the lane record's `home`, else its account, else the home a fresh launch picks. A session that ended before its first event is absent too. `--resume=<id>` on such a session exits 1 with `No session, task, or name matched`, under `-p` and at a pane, and opens no picker (measured, 1.0.88). |
| Store unreadable, or bound session another worktree owns | Fails before any window: `session-owned-elsewhere`, or the store's cause. |
| Retired session | A standing handoff starts fresh as `session-retired` unless its `relaunch` says `resume`. The handoff record carries the context. |
| Bound session | Resumes it under the home its files were found in. |

A hosted relaunch reads the same route first, so the two refusals apply. The hosted launch then starts the harness fresh on its host, and the context continues through the handoff record.

## Wake and lane mail

A Copilot lane's own wake is its mailbox monitor: `.agents/skills/mailbox/scripts/lane-mail watch --once --item [ITEM]` as a background command, re-armed after each exit once the inbox command it printed has run. The launch brief carries the arm line ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Copilot CLI starts a turn when a background command exits.

Beside the monitor, the lane's hooks hand it mail: at its session start and at each prompt (`lane-mail-start`, `lane-mail-prompt`), after each tool call (`lane-mail-deliver`), at its turn end (`lane-mail-check`), and at its next tool call while a halt stands (`lane-mail-halt`). A Copilot payload names no agent, so the hooks record each lead session at its session start, or at a turn end whose own transcript proves it, and hand mail only to a call from a recorded lead session (orch `turnend/payload.rs`). A custom subagent's calls carry its own session id, which nothing recorded: they are handed no mail and mark none read.

Where the lane reads idle with mail unread, the watch's wake duty types the inbox line into it ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)): `wake-delivered`, else `wake-unconfirmed`. Mail that neither the monitor, the hooks nor the wake duty delivers waits for the lane's next turn, or takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

## Lane close

The runtime's close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) types `C-c` and `/exit` into a local Copilot lane's pane, so the session writes its totals, then stops its recorded process, named `copilot` or `MainThread` on Linux (agent-runtime `harness.rs` `owns_process`). A hosted lane whose provider holds the pane gets the same two inputs through the provider before the provider's stop. A working lane refuses as `lane-live`. A Copilot limit banner, `You've hit your … limit` or `You've reached your … limit`, reads as the usage wall. The close reads no account for a Copilot lane, so a walled Copilot lane refuses as `lane-live state=walled account=none`.

## Overseer registration

`orch-runtime register --fleet --account [DIR]` records the account a hand-opened Copilot overseer spends where its pane cannot reveal it. Registration installs the context reader in that home and reports `context-reader=next-start` where the reader was absent, since the running session loads it only at its next start, or `context-reader=missing` with the cause where the home refuses it. It also reports `turn-end-hook=missing` where the three hooks are not found. Start, adoption and succession are [oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption). Its standing watch is [watch-delivery.md § Repeat watch](watch-delivery.md#repeat-watch).

## Unproved behaviour

No live session has proved these:

| Behaviour | Proof |
|---|---|
| A killed lane pane resumes its session and runs the continuation line | Kill the lane's window, then send the item's `launch-lane` request again on the same account, with the continuation line as its brief. The pane shows the resumed transcript and the lane runs `lane-mail inbox`. |
| A resume keeps model, effort, context tier and allow-all | In the resumed pane, `/model` and the footer name the model, effort and tier the command named, and a tool call runs with no prompt. |
| `COPILOT_ALLOW_ALL=true` opens a new worktree with no trust dialog | A first launch into a fresh worktree reaches its first turn with no `Confirm folder trust` screen. |
| A Copilot overseer succession | Follow [Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) with a Copilot successor; confirm its publication and a fresh context reading. |
| Allow-all takes effect on the first fleet lane | Launch the first fleet lane with `--allow-all`; a tool call runs with no prompt, and the record under `<account>/lane-status/` reads `allow_all_enabled: true`. |
| A policy block reaches the record, and the record stays fresh at a waiting prompt | On an account whose policy blocks allow-all, launch with `--allow-all`; the record reads `allow_all_enabled: false` and its `written_at` keeps moving while the prompt waits. |
| A built-in task-tool subagent's calls carry their own session id, not the lead's. The hooks tell the lead by the call's session id alone (orch `turnend/mod.rs` `caller`): a call from a session no lead record names is handed no mail and marks none read, but a call carrying the lead's session id is read as the lead's, is handed the lead's mail after its tool call, which marks it read, and under a halt is shown the read that clears it. Until this is proved, do not rely on mail its hooks marked read while a built-in subagent ran having reached the lead. | In a lane whose lead starts a built-in task-tool subagent, the subagent's tool-call payloads carry a session id that no record under `~/.cache/lane-mail/copilot-leads` names. |
