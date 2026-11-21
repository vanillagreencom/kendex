# Copilot CLI runtime reference

Read when a lane or an overseer runs on GitHub Copilot CLI (`copilot`): its account, launch, context reading, allow-all block, relaunch, wake and close. A fact marked measured was read off the Copilot CLI version it names. A fact that cites `copilot help config` or `copilot help environment` is that help text.

## Account setup

A Copilot account is a directory the CLI runs under as `COPILOT_HOME`, such as `~/.1copilot`. The account judge chooses among the directories `AGENT_RUNTIME_ACCOUNT_DIRS` lists. An entry that holds `config.json` and no Claude `.credentials.json` is a Copilot account (agent-runtime `accounts/listing.rs` `kind_of`). The judge measures a `COPILOT_HOME` the environment sets, but never chooses it.

| File in the account | What reads it | Without it |
|---|---|---|
| `config.json` with a stored login | The CLI signs in with it. The account listing reads the login's token for GitHub's usage endpoint: from `config.json`, or from the Linux Secret Service through `secret-tool` where the CLI keeps the token in a keyring. It reads no other platform's store, such as the macOS Keychain. | The launch has no identity. |
| `settings.json` with `statusLine` | `"statusLine": {"type": "command", "command": "<repo>/.agents/skills/orch/scripts/copilot-statusline", "refreshInterval": 30}`: the command an executable file, the interval a whole number of seconds under 120. The command writes the session record the turn end reads where the context extension recorded no reading. That record is also the one that carries `allow_all_enabled` (§ Allow-all blocked by policy). The header of `scripts/copilot-statusline` states the record. | No fallback reading, and no reader can report an allow-all block. |
| `extensions/kendex-lane-context/extension.mjs` and `enabledFeatureFlags.EXTENSIONS` in `settings.json` | The context extension, which hands each `session.usage_info` reading to the turn end. The launch preparation installs it and sets the flag true where the flag is absent, for every local or hosted lane and controller. | A launch whose `settings.json` sets `EXTENSIONS` false is admitted only where the status line above writes the record. |
| The three lane-mail hooks | `lane-mail-check`, `lane-mail-compact` and `lane-mail-start`, in the worktree's `.github/hooks` or the account's `hooks`. | The launch fails as `unsupported-for-oversee harness=copilot` ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)). |

A Copilot lane uses the `copilot-home` the provider's `create` supplies. The default `.copilot` is available on a provider that supports home-relative transfers, and a confined provider needs a usable named home. See [Launch on a provider](../schemas/lane-host.md#launch-on-a-provider). The launch installs the context reader there through the provider's files (agent-runtime `trust.rs` `hosted_copilot_reader`), then reads the three lane-mail hooks on the host. It judges no settings layer on the host.

Each hook refusal reads `unsupported-for-oversee harness=copilot reason=[REASON]` (agent-runtime `effects/prepare/gate.rs`):

| Reason | Repair |
|---|---|
| `no-context-hooks` | Neither the worktree's `.github/hooks` nor the home's `hooks` holds all three hooks, each a `.sh` beside its `.json`. Install them: add `copilot` to `[install] harnesses` in `kendex.toml` and run `kendex apply`. |
| `hooks-unreadable` | The hook file `file=` names could not be read, and `cause=` says why. Make that file readable. |
| `hooks-disabled` | A settings layer or a registration `file=` names switches the hooks off (`kendex hooks-off`). Remove that switch. |
| `hooks-unjudged` | `kendex hooks-off` could not answer, with its `exit=` and `cause=`. Repair the `kendex` install. |

A local launch whose Copilot home cannot be resolved fails `home-unresolved harness=copilot`. Name an `account` in the `launch-lane` request, or run the overseer with `COPILOT_HOME` or `HOME` set.

## Confinement

A Copilot lane runs unconfined on every host under the cause `token-on-session-bus` ([agent-runtime SKILL.md § Confinement](../../agent-runtime/SKILL.md#confinement)).

## Session store

A session keeps its state under `<account>/session-state/<session-id>/` (agent-runtime `session.rs`): `workspace.yaml` holds its `id:` and `cwd:` lines, and `events.jsonl` holds its events.

## Launch environment

agent-runtime's launch builder spells the words and variables of every Copilot launch (`Harness::settings_words` and `Harness::question_off_words` in `skills/agent-runtime/runtime/src/harness.rs`, and `build` in `launch.rs` beside it). A lane's command line follows [lane-directive.md § Lane preference](lane-directive.md#lane-preference). What a launch carries:

- Every lane launch carries `--no-ask-user`, which takes the `ask_user` tool away. A controller carries it while [`AGENT_RUNTIME_QUESTION_TOOL`](settings.md#talking-to-you) is `off`. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)).
- The launch clears `COPILOT_GITHUB_TOKEN`. `GH_TOKEN` and `GITHUB_TOKEN` stay, so a lane's own `gh` calls keep signing in. Copilot skips a GitHub App token (`ghs_`) there, and the identity stays the stored login (measured, 1.0.88). A user token there, a `gho_` token or a personal access token, signs Copilot in as that user instead.
- `COPILOT_ALLOW_ALL=true` rides only a full bypass, where the command carries `--allow-all` or `--yolo`. It approves every tool, trusts the working directory without prompting, and loads its hooks and skills (`copilot help environment`). Every other command carries it empty, so the lane keeps its permission prompts and its folder-trust dialog.
- A request naming an `account` names `model` and `effort` too, or the launch refuses ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)).
- A request naming no `permission` takes the [`AGENT_RUNTIME_LAUNCH_PERMISSION`](settings.md#fleet-lanes) posture, and under `bypass` the builder adds `--allow-all`. `--allow-all-tools` or the `native` posture carries an empty `COPILOT_ALLOW_ALL` and keeps its prompts. A resume carries the same words, since a resumed session ignores `defaultPermissionMode` from settings (`copilot help config`).
- `continueOnAutoMode` has no flag. It stays `false`, which keeps the model on a rate limit instead of moving to Auto, only while the account's `settings.json` does not set it `true`.

## Measurement

The turn end reads a Copilot session's context in this order (orch `turnend/marks.rs` `copilot_reading`). A flag the session's automatic compaction left in its mailbox comes first: the session is then past its mark whatever a reading says, and the turn end holds until the handoff record stands. Then come the extension's reading of this session, the session's status-line record, and the session's own `events.jsonl`.

The turn end reports a gap and never reads it as room. The shared judge hands a lane off by [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules).

Credits: [schemas/copilot-credits.md](../schemas/copilot-credits.md) states the monthly pool record the account listing reads. A Pi root on a `github-copilot/` model is judged as [lane-directive.md § No lane has room](lane-directive.md#no-lane-has-room) says.

## Allow-all blocked by policy

Enterprise managed settings can block the allow-all mode. GitHub delivers them per account from the server, or per machine through device management or a `managed-settings.json` file ([Choosing how to deploy enterprise-managed settings](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-managed-settings/deploy-managed-settings)). A machine delivery stays active when the CLI signs in to another account. A lane launched with `--allow-all` can lose the mode mid-run. Each tool call then waits on a permission prompt nobody at the pane answers.

The status-line record keeps the CLI's `allow_all_enabled`. A lane launched without `--allow-all` or `--yolo` also reads `false`, and its prompts are expected. So the stop cause `allow-all-blocked-by-policy` applies only to a lane whose launch granted the full allow-all mode (agent-runtime `context.rs` `CopilotRecord::stop_cause`).

The runtime watch prints `stop-cause=allow-all-blocked-by-policy` on a local lane's `lane-asking` line or an `idle-after-return` line that carries no `cause=`, or `session-record=<reason>` (§ Session record reasons) where no record answers. The `lane-mail-check` turn-end hook prints `lane-mail-check: stop-cause=allow-all-blocked-by-policy` in a session whose launch line set `COPILOT_ALLOW_ALL=true`. `orch-runtime lane status` supplies no policy note, and a hosted lane gets none: its store is on its host.

A lane waiting at a permission prompt reaches no turn end, so the hook reports nothing there; the watch's `lane-asking` line carries the cause. To confirm a cause by hand, read the session's record under `<account>/lane-status/<session-id>.json`.

The owner remedies the block. Tell the owner the account and the cause: an enterprise administrator lifts an account block, and the machine's administrator lifts a machine block. To move the item meanwhile:

1. Where a lane of another Copilot account, launched with allow-all, runs on this machine, read that session's fresh record under its `<account>/lane-status/`. A record for that session and account with `allow_all_enabled: false` shows a block on both accounts, from this machine or from an enterprise that licenses both. Another account does not help then. A missing, stale or mismatched record settles nothing about the machine. Tell the owner both accounts and both possible administrators, and stop. A relaunched lane that reports the same cause shows the same: stop it and wait for the owner.
2. Stop the blocked lane first, by [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver) step 1, so two sessions never run in one worktree.
3. Relaunch the item with a `launch-lane` request whose `account` names the other account ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). A relaunch on another account starts fresh on the item's branch as `account-switched`, and does not resume the blocked session.

## Session record reasons

The reason a `session-record=` note names (agent-runtime `context.rs` `copilot_record`, orch `watch/lanes.rs` `copilot_note`):

| Reason | Meaning | Remedy |
|---|---|---|
| `missing`, `stale` | The account's status line writes no record, or stopped refreshing it. A record older than 120 seconds, or stamped later than the reader's clock, is stale. | Set the account's `statusLine` (§ Account setup). |
| `unbound` | The session id is empty or outside the alphabet `A-Za-z0-9._-`. The hook takes the id from its payload; the watch takes it from the lane record or the worktree's store. | Check the session id the hook was handed, or the lane record's `session_id`. |
| `worktree-unmatched` | The watch only: a lane record naming no session id names no `mail_root`, or the account's store holds no session for that worktree. | Check the lane record's `mail_root`, and that the lane's session started under that account. |
| `store-unreadable` | The watch only: the worktree path does not resolve, or the account's session store cannot be read. | Check the worktree and the account's `session-state/` directory. |
| `account-unnamed` | The watch only: a lane record naming neither `account` nor `home`, on a watch whose settings name neither `COPILOT_HOME` nor `HOME`. | Run the watch with `HOME` set. |
| `unreadable`, `wrong-session`, `wrong-account` | The file is no record `copilot-statusline` wrote for this session and account. | Remove the file under `<account>/lane-status/` and let the status line write it again. |
| `wrong-transcript` | The hook only: the record's `transcript_path` is not the folder that holds the transcript the hook's payload names. | Remove the file under `<account>/lane-status/` and let the status line write it again. |

## Recovery

A relaunch is the item's `launch-lane` request sent again ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). It resumes the session the lane record binds by explicit id, `copilot --resume=<id> -i <brief>`. It never uses bare `--resume`, which opens a picker. The route reads the lane record, the item's standing handoff and the bound session's own files under its id, never a session found by its age (orch `effects/launch.rs` `relaunch_route`, `route_of`). The rows apply in order, and the first that matches decides.

| Case | What the relaunch does |
|---|---|
| No bound session | Starts a fresh session on the request's brief. |
| Harness or account switch | A lane record that names another harness starts fresh as `harness-switched`. A request on another account than the record's starts fresh as `account-switched`. |
| Bound session absent from the destination home | Starts fresh as `session-absent`. The destination is the lane record's `home`, else its account, else the home a fresh launch picks. A session that ended before its first event is absent too. |
| Store unreadable, or bound session another worktree owns | Fails before any window. |
| Retired session | A standing handoff starts fresh as `session-retired` unless its `relaunch` says `resume`. The handoff record carries the context. |
| Bound session | Resumes it under the home its files were found in. |

A hosted relaunch reads the same route first, so the two refusals apply. The hosted launch then starts the harness fresh on its host, and the handoff record carries the context.

## Wake and lane mail

A Copilot lane's own wake is its `--once` mailbox monitor, run as a background command. The launch brief's arm line arms it; [watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor) says when to re-arm it. Copilot CLI starts a turn when an attached background command exits while Autopilot runs; after Autopilot stops, it holds the result for the next typed message ([watch-delivery.md § Repeat watch](watch-delivery.md#repeat-watch), Copilot CLI row).

Beside the monitor, the lane's hooks hand it mail: at its session start and at each prompt (`lane-mail-start`, `lane-mail-prompt`), after each tool call (`lane-mail-deliver`), at its turn end (`lane-mail-check`), and at its next tool call while a halt stands (`lane-mail-halt`). A Copilot payload names no agent. So the hooks record each lead session at its session start, or at a turn end whose own transcript proves it, and hand mail only to a call from a recorded lead session (orch `turnend/payload.rs`). A custom subagent's calls carry its own session id, which nothing recorded: the hooks hand them no mail, and they mark none read.

Where the lane reads idle with mail unread, the watch's wake duty types the inbox line into it ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)). Mail that neither the monitor, the hooks nor the wake duty delivers waits for the lane's next turn, or takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

## Lane close

The runtime's close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) types `C-c` and `/exit` into a local Copilot lane's pane, so the session writes its totals. It then stops the recorded process (agent-runtime `harness.rs` `owns_process`). A hosted lane gets the same two inputs before the provider's stop: through the provider where it holds the pane, or in a `pane=local` window from the close. The close reads no account for a Copilot lane, so it refuses a walled Copilot lane as `lane-live`.

## Overseer registration

`orch-runtime register --fleet --account [DIR]` records the account a hand-opened Copilot overseer spends, where its pane cannot reveal it. Registration installs the context reader in that home; a running session loads it only at its next start. [oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) covers start, adoption and succession. The overseer's standing watch is [watch-delivery.md § Repeat watch](watch-delivery.md#repeat-watch).

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
| A built-in task-tool subagent's calls carry their own session id, not the lead's. The hooks tell the lead by the call's session id alone (orch `turnend/mod.rs` `caller`). A call from a session no lead record names is handed no mail and marks none read. A call carrying the lead's session id is read as the lead's: it is handed the lead's mail after its tool call, which marks it read, and under a halt it is shown the read that clears it. Until this is proved, do not assume that mail the hooks marked read while a built-in subagent ran reached the lead. | In a lane whose lead starts a built-in task-tool subagent, the subagent's tool-call payloads carry a session id that no record under `~/.cache/lane-mail/copilot-leads` names. |
