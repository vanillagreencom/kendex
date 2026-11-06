# Copilot CLI runtime reference

How orch launches, measures, resumes, wakes, closes and succeeds a GitHub Copilot CLI (`copilot`) session, and what a Copilot account needs for it. Everything here is Copilot-specific. A fact marked measured was read off Copilot CLI 1.0.88, by hand or by the `tools/harness-smoke` row it names. A fact that cites `copilot --help`, `copilot help config` or `copilot help environment` is that text for the same version. The orch code named beside each remaining rule owns that behavior.

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

Agent-runtime's `session.rs` reads these two files: the runtime relaunch looks a bound session up by its id (`resume_owner`), and the watch's policy note finds the session of a lane's worktree (`lead_at`). `copilot_session_id` in `lib/copilot-session.sh` reads a `workspace.yaml`'s id for the session reader in `lib/lane-relaunch.sh`, which a Jarvis session uses for a recorded Copilot file. No live context count is in either. A fleet session's context is read by the `kendex-lane-context` Copilot extension installed in its `COPILOT_HOME` by runtime launch preparation for a lane or controller, and by the shared shell installer in `scripts/lib/adapters/copilot.sh` for `oversee register` and the plain succession call, [`scripts/copilot-lane-context/extension.mjs`](../scripts/copilot-lane-context/extension.mjs): it hands `lane-mail-check` each `session.usage_info` reading, which the turn end judges. A reading handed on and not yet recorded, or one the extension could not read, leaves a pending marker under `~/.cache/lane-mail/copilot-usage`, and a turn end that finds it still standing after 5 seconds reports the context unmeasured under `reading-pending`. The shared installer makes that directory and writes and removes one probe file there before a fleet session starts, since a reading the extension cannot mark leaves the earlier record standing as room; where it cannot, it refuses the lane as `unsupported-for-oversee reason=no-context-reader detail=pending-unwritable`, `file=` naming the directory. Where no extension reading of the session stands and no pending marker does, the turn end falls back to the session record the account's status-line command writes, which `scripts/copilot-statusline` records (§ Measurement).

## Launch environment

agent-runtime's launch builder spells the Copilot rows below for every runtime launch: `Harness::settings_words` and `question_off_words` in `skills/agent-runtime/runtime/src/harness.rs` add the launch words, and `build` in `launch.rs` beside it sets the environment. Command templates follow [lane-directive.md § Lane preference](lane-directive.md#lane-preference).

| Words orch adds | Why |
|-----------------|-----|
| `--autopilot --max-autopilot-continues 3` | Continues a turn that stopped short, at most three times, with nobody at the pane. |
| `--context long_context` | The long context tier, named on the command and not left to `contextTier` in the account's settings. |
| `--no-auto-update` | The CLI runs the version the host installed and downloads none. |
| `--no-ask-user` | Takes the `ask_user` tool away, on every lane and on an overseer while `ORCH_QUESTION_TOOL` is `off`, its default. A lane asks through `lane-mail` ([skill-rules.md § Coordination](skill-rules.md#coordination)). |
| `-u COPILOT_GITHUB_TOKEN` | Copilot reads `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`, then the login stored in the account's `config.json` (`copilot help environment`). Copilot refuses a placeholder handed in `COPILOT_GITHUB_TOKEN`, so that one is cleared. `GH_TOKEN` and `GITHUB_TOKEN` stay, so a lane's own `gh` calls keep signing in: a fleet host holds the GitHub App token (`ghs_`) there, which Copilot 1.0.88 skips with `Unsupported token type, ignoring`, and the identity stays the account's stored login (§ Account setup). On a workstation, a user token in either one, a `gho_` token or a personal access token, signs Copilot in as that user instead. No token value enters a command. |
| `COPILOT_ALLOW_ALL=true` or `COPILOT_ALLOW_ALL=` (empty) | `true` only where the command carries `--allow-all` or `--yolo`. `copilot help environment`: any truthy value approves every tool, and exactly `true` also trusts the working directory without prompting and loads its hooks and skills. So it adds folder trust to the posture the caller chose. Every other command carries it empty, so a `COPILOT_ALLOW_ALL` the launching shell exports does not reach it: it keeps its permission prompts and its folder-trust dialog. |
| `COPILOT_SKILLS_DIRS=~/.agents/skills` | Any `COPILOT_HOME` hides the shared skills under `~/.agents/skills`, and this names them back: measured by `tools/harness-smoke`, row `skill-dirs:COPILOT_HOME`. |
| `COPILOT_HOME=<account>` | The account the `launch-lane` request names; with none, the home the resumed session was found under, else the runtime's `COPILOT_HOME` setting, else `~/.copilot` (`named_home`, `accountless_kept` and `inherited_home` in `runtime/src/effects/launch.rs`). A relaunch reads its bound session under the lane record's `home`, else its account, else that same home (`relaunch_route`). A fleet refuses a hosted Copilot launch, so no provider names one (§ Recovery). |

| Fields the `launch-lane` request names | Why |
|---|---|
| `model`, `effort` | The builder spells them `--model [MODEL] --reasoning-effort [EFFORT]` (`Harness::model_words` in agent-runtime's `harness.rs`). A request naming an `account` names both, or the launch refuses `launch-model-missing` or `launch-effort-missing` ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)); one naming no account and neither adds neither word. |
| `permission` | The permission words of the lane's line. Where the request names none, the launch takes the `ORCH_LAUNCH_PERMISSION` posture, `bypass` by default, and the builder adds `--allow-all` (`build` in agent-runtime's `launch.rs`). A resumed session ignores `defaultPermissionMode` from settings (`copilot help config`), so a resume takes the same words. A narrower grant or the `native` posture carries an empty `COPILOT_ALLOW_ALL` and keeps its prompts. |

`continueOnAutoMode` has no flag. Its default is `false`, which keeps the model on a rate limit instead of moving to Auto. It stays `false` only while the account's `settings.json` does not set it `true`.

## Measurement

- Context: the `kendex-lane-context` extension's reading of Copilot's `session.usage_info` is read first, against 80 percent of `tokenLimit`, the limit Copilot compacts at (`scripts/lib/lane-context.sh`, `LANE_CONTEXT_COPILOT_COMPACTION_PCT`). Where no such reading of the session stands, `scripts/lib/adapters/copilot.sh` reads the session record, held to the session id, transcript, account and a freshness bound by `scripts/lib/copilot-session.sh`, and hands the shared judge the same share of the window as capacity ([oversee-events.md](oversee-events.md#judgement-rules), Hand off a lane). The record is no credit source.
- Credits: `lanes` reads the monthly pool through `scripts/lib/copilot-credits.sh`; the record it produces is [schemas/copilot-credits.md](../schemas/copilot-credits.md). Nothing here reads a Pi root's Copilot login, so a Pi root on a `github-copilot/` model is judged on the lane host's `harness=pi` accounts row for it ([lane-host.md](../schemas/lane-host.md)), or on its stated `ORCH_LANE_COPILOT_POOL` override where no row reads it.

## Allow-all blocked by policy

Enterprise managed settings can block the allow-all mode. GitHub delivers them per account from the server, or per machine through device management or a `managed-settings.json` file, and a machine delivery stays active when the CLI signs in to another account. The CLI checks for new settings about once an hour ([Choosing how to deploy enterprise-managed settings](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-managed-settings/deploy-managed-settings)). So a lane launched with `--allow-all` can lose it mid-run, and each tool call then waits on a permission prompt that nobody at the pane answers. The session record keeps the CLI's `allow_all_enabled`, and the `kendex-lane-context` extension's reading does not, so a policy read needs the session record. A lane launched without `--allow-all` or `--yolo` reads `false` too, and its prompts are expected. So the stop cause `allow-all-blocked-by-policy`, which `scripts/lib/copilot-session.sh` names, applies only to a lane whose launch granted the full allow-all mode. The hook takes that grant from `COPILOT_ALLOW_ALL` on the session's launch line, and the runtime watch from the lane record's `allow_all`. These readers distinguish lane state from the policy note:

| Reader | When it reads | What it prints |
|---|---|---|
| `orch-runtime lane status --item [ITEM]` | For the item's one in-flight fleet record. Where the host kind declares `status=verb`, it asks the provider's status first: `exited` reads `exited`, and a failed read reads `unjudged`. For `pane=verb` it judges the provider's capture. On the local-pane path it reads the recorded pane and screen, and reads the pane's foreground process unless the provider answered `running`, which proves the harness up | The classifier's word in `result.state`, with `result.cause` for `unjudged` or `unreadable`. This read supplies no session-record policy note. |
| The runtime watch | At each long pass, for an in-flight Copilot lane whose record carries `allow_all: true`, at its `lane-asking` line and at an `idle-after-return` line that carries no `cause=` | `stop-cause=allow-all-blocked-by-policy` on that line where the session's status-line record reports `allow_all_enabled` false, or `session-record=<reason>` where no record answers for the session. The note is part of the line's key, so a changed note prints the line again under an unchanged screen. The record is read under the lane record's `account`, else its `home`, else the watch's `COPILOT_HOME`, else `.copilot` under the watch's `HOME`. The session is the record's `session_id`, else the session the account's store holds for the lane's worktree, the earliest since `session_since`, else the newest. |
| The `lane-mail-check` turn-end hook | At a turn end whose record answers, in a session whose `COPILOT_ALLOW_ALL` is `true`, whether or not the extension recorded a context reading of the session | `lane-mail-check: stop-cause=allow-all-blocked-by-policy`. The turn end is judged as usual. This hook reads no fleet record, so it takes the grant from the launch line's `COPILOT_ALLOW_ALL`, which is empty on a launch without allow-all. |

A lane waiting at a permission prompt reaches no turn end, so the hook reports nothing there; the watch's `lane-asking` line carries the cause. To confirm a cause by hand, read the session's status-line record as step 1 below does.

| `session-record=` reason | Meaning | Remedy |
|---|---|---|
| `missing`, `stale` | The account's status line writes no record, or stopped refreshing it: a record older than 120 seconds, or stamped later than the reader's clock, is stale | Set the account's `statusLine` (§ Account setup) |
| `unbound` | The session id is not an id: the hook's from its payload, an empty one included, and the watch's from the lane record's nonempty `session_id` or the session its worktree's store answered | Check the native session id passed to the hook, or the `session_id` in the lane record |
| `worktree-unmatched` | The watch only: a lane record naming no session id names no `mail_root`, or the account's session store holds no session for that worktree | Check the lane record's `mail_root`, and that the lane's session started under that account |
| `store-unreadable` | The watch only: the lane's worktree path does not resolve, or the account's session store or a session in it cannot be read | Check the worktree and the account's `session-state/` directory |
| `account-unnamed` | The watch only: a lane record naming neither `account` nor `home`, on a watch whose settings name neither `COPILOT_HOME` nor `HOME`. A watch with `HOME` set, as every ordinary run has, never prints it | Run the watch with `HOME` set |
| `unreadable`, `wrong-session`, `wrong-account` | The record file is not one `lib/copilot-session.sh` wrote for this session and account | Remove the file under `<account>/lane-status/` and let the status line write it again |
| `wrong-transcript` | The record names another transcript than the one the turn-end hook's payload names. Only the hook passes a transcript, so only the hook prints this reason | Remove the file under `<account>/lane-status/` and let the status line write it again |

The remedy for the block is the owner's. Tell the owner the account and the cause: an enterprise administrator lifts an account block, and the machine's administrator lifts a machine block. To move the item meanwhile:

1. Where a lane of another Copilot account, launched with allow-all, runs on this machine, inspect that session's fresh status-line record under `<account>/lane-status/`. A record for that session and account with `allow_all_enabled: false` shows a block on both accounts. The block can come from this machine or from an enterprise that licenses both accounts, and another account does not help. A missing, stale or mismatched record settles nothing about the machine. Tell the owner both accounts and both possible administrators: the machine's, and that enterprise's. A relaunched lane that reports the same cause shows the same: stop it and wait for the owner.
2. Stop the blocked lane first, by [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver) steps 1 to 3, so two sessions never run in one worktree.
3. Relaunch the item with a `launch-lane` request whose `account` names the other account ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). A relaunch on another account than the lane record's starts fresh on the item's branch, reported as `account-switched`, and does not resume the blocked session.

## Recovery

A relaunch is the item's `launch-lane` request sent again ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). It resumes the session the lane record binds by explicit id, `copilot --resume=<id> -i <brief>` (`build` in agent-runtime's `launch.rs`), and never uses bare `--resume`, which opens a picker. The route reads the lane record, the item's standing handoff and the bound session's own files under its id, never a session found by its age (`relaunch_route` and `route_of` in `runtime/src/effects/launch.rs`). The rows apply in order; the first that matches decides.

| Case | What the relaunch does |
|------|------------------------|
| Hosted lane | A hosted Copilot launch refuses as `unsupported-for-oversee harness=copilot reason=hosted` before the provider creates anything. |
| No bound session | Starts a fresh session on the request's brief. |
| Harness or account switch | A lane record that names another harness starts fresh as `harness-switched`. A request on another account than the record's starts fresh as `account-switched`. |
| Bound session absent from the destination home | Starts fresh as `session-absent`. The destination is the lane record's `home`, else its account, else the home a fresh launch picks. |
| Session ended before its first event | Starts fresh as `session-absent`, as for a session absent from the destination home: the route reads a session with no event as no session (`identify` in agent-runtime's `session.rs`). `--resume=<id>` on such a session exits 1 with `No session, task, or name matched`, under `-p` and at a pane, and opens no picker (measured). |
| Bound session another worktree owns | Refuses as `session-owned-elsewhere` before any window. A store that cannot be read refuses with its cause. |
| Retired session | A standing handoff starts fresh as `session-retired` unless its `relaunch` says `resume`. The handoff record carries the context. |
| Bound session | Resumes it: the destination home holds `session-state/<id>/` with a `workspace.yaml` naming the lane's worktree and a nonempty `events.jsonl`. |

## Wake and lane mail

A Copilot lane's own wake is its `lane-mail watch --once` monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Where the lane reads positively idle with mail unread, the watch's wake duty types it one line that runs `lane-mail inbox`, and confirms it by a new user turn in the lane's own session: `wake-delivered`, else `wake-unconfirmed`. `open-terminal --wake --harness copilot` refuses as `wake-invalid` before any read, since a Copilot session is never resumed beside itself. Mail that the monitor, the hooks and the wake duty do not deliver waits for the lane's next turn, or takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver): stop, close with `--keep-sandbox`, relaunch.

## Lane close

`lane-close` ends an idle Copilot lane by SIGTERM to its native process, named `MainThread` on Linux ([lane-reach.md § Lane close](lane-reach.md#lane-close)). A working lane refuses as `lane-live`. A Copilot limit banner that says `You've hit your … limit` or `You've reached your … limit` matches the shared banner pattern in `lib/lane-state.sh`. `lane-close` weighs a banner against the account's reading for a claude or codex lane alone, so a Copilot lane under one stays `walled` and refuses as `lane-live state=walled`.

## Overseer succession

The runtime's `successor --fleet` chooses a live controller's successor; `start-controller` and `request-transfer` prepare its Copilot home, install its context reader and apply the hook gate before opening a pane. [Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) gives the commands and request fields. The runtime's `marks --fleet` judges the recorded account's monthly pool and the current context reading. A context-mark walk can keep the caller's unmeasured account when no measured account of that harness has room; headroom and rate walks exclude the caller's account. Dead recovery opens a fresh session from the record's typed launch fields and handoff. It does not resume the dead session.

`oversee register --account [DIR]` records an account the pane cannot reveal. Registration reports missing hook coverage or a context reader that loads only at the next start. The runtime writes the published controller's display line from the successor it launches. A controller with a recorded `succession` command follows that owner's lifecycle.

## Pending live proofs

Each live-session proof below remains unverified.

| Proof | Command |
|-------|---------|
| A killed lane pane resumes its session and runs the continuation line | Kill the lane's window, then send the item's `launch-lane` request again on the same account, with the continuation line as its brief ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)); the pane shows the resumed transcript and the lane runs `lane-mail inbox` |
| A resume keeps model, effort, context tier and allow-all | In the resumed pane, `/model` and the footer name the model, effort and tier the command named, and a tool call runs with no prompt |
| `COPILOT_ALLOW_ALL=true` opens a new worktree with no trust dialog | A first launch into a fresh worktree reaches its first turn with no `Confirm folder trust` screen |
| A Copilot overseer succession | Follow [controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) with a Copilot successor; confirm its publication and a fresh context reading |
| Allow-all takes effect on the first fleet lane | Launch the first fleet lane with `--allow-all`; a tool call runs with no prompt, and the record under `<account>/lane-status/` reads `allow_all_enabled: true` |
| A policy block reaches the record, and the record stays fresh at a waiting prompt | On an account whose policy blocks allow-all, launch with `--allow-all`; the record reads `allow_all_enabled: false` and its `written_at` keeps moving while the prompt waits |
