# Home layout

Read when setting up a Jarvis home, adding an agent, skill or workstream, choosing a home path, starting a continuing session or reaching the managed session from a terminal.

## Paths

| Path | Git status | Holds |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions, which travel with you |
| `skills/NAME/` | Committed | Your own skills |
| `agents/NAME.md` | Committed | Your own agent source |
| `memory/` | Committed | Durable facts and rulings under [Memory](memory.md), which travel with you |
| `memory/workstreams.md` | Committed | Workstream intent, scope, owner and tracker references |
| `state/handoff.md` | Committed | The default current handoff |
| `state/archive/` | Committed | Archived handoffs and progress logs |
| `state/archive/INDEX.md` | Committed | One dated line for each file the handoff replacement step archives |
| Other files under `state/` | Committed | The work a consumer's file and shell tools write |
| `${XDG_STATE_HOME:-$HOME/.local/state}/kendex/jarvis/<canonical-home-key>/jarvis-session.json` | Outside the home | The local controller record |
| `owner-asks.json`, beside the controller record on the main | Outside the home | Owner-ask action deltas and retry receipts |
| `.agents/skills/` and each harness's skill and agent directories, such as `.claude/skills/`, `.claude/agents/` and `.codex/agents/` | Committed | Installed skills and agents, so a clone has them |
| `tmp/` | Local | Scratch files, which stay on this machine |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets, which stay on this machine |

- `skills/NAME/`: follow [Customize](../README.md#customize) to declare the home source and install your skills.
- `agents/NAME.md`: declare it through [Personal additions](home-contract.md#personal-additions).
- `memory/workstreams.md`: [Personal additions](home-contract.md#personal-additions) sets its content. Active work stays in the tracker.
- `state/handoff.md`: `jarvis-session succeed` saves and hands over this file only. `progress-log` and `owner-unanswered` select another through `--handoff PATH` under [Handoff](long-session.md#handoff).
- `state/archive/`: [Handoff](long-session.md#handoff) owns what the session model writes here. `jarvis-session succeed` saves its own copy of the handoff as `handoff-<generation>-<id>.md`.
- `state/archive/INDEX.md`: `progress-log --archived` writes these lines, under [Handoff](long-session.md#handoff). `owner-unanswered` reads any file it does not list, such as the copy `jarvis-session succeed` saves.
- Other files under `state/`: an app-managed home limits model file and shell writes to this folder.
- The controller record: the session runtime and the native SessionStart hook write it. The runtime writes no start-critical record under `state/`.
- `owner-asks.json`: the [owner-ask operations](owner-asks.md) retain it. Satellites call this main-owned authority and hold no local copy.
- `.agents/skills/` and the harness directories: kendex renders or links installed skills and agents here. In a home where kendex did not install Jarvis, an assistant app such as VGS can copy a kendex-rendered package to these same paths.
- `tmp/`: scratch files follow [Scratch files](computer-use.md#scratch-files).
- The private env file: kendex creates it with mode 600.

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

## Initialize

`jarvis-session init --home HOME` writes the missing starting files of a Jarvis home.

- A person's first manual Start runs the same step when this machine holds no session record for HOME and a starting file is missing.
- A boot or `app-on` Start never runs it; an app calls `init` itself.
- A Start that leaves out `--account`, `--mode` and `--origin` uses `new`, `manual` and the account directory the harness itself uses: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME` or `PI_CODING_AGENT_DIR` when set, otherwise `~/.claude`, `~/.codex`, `~/.copilot` or `~/.pi/agent`. The orch package's account resolver gives this answer.
- An app passes each value itself.

A folder qualifies when it is its own Git root, lies inside no other Git work tree, and has no top-level entry beyond these names:

- the paths above: `AGENTS.md`, `skills`, `memory`, `state`, `tmp` and `.env.local`; only `.env.local` counts as the private env file, so a home whose `KENDEX_ENV_FILE` names another top-level file does not qualify;
- Git's `.git` and `.gitignore`;
- kendex's `kendex.toml`, `kendex.settings.toml`, `.kendex-lock.json`, `.kendex-generated.json`, `.cache`, `.kendex` and `.kendex-local`;
- the harness folders and files kendex writes: `.agents`, `.claude`, `.codex`, `.github`, `.pi`, `.opencode`, `.cursor`, `.gemini`, `.mcp.json`, `opencode.json` and `opencode.jsonc`.

1. Make the home a new folder outside any project.
2. Run `git init` before `kendex add`, so `kendex add` can offer to commit the files it writes and to set up the commit-guards hooks.

- When `COMMIT_GUARDS_PRE_COMMIT_LOCAL` in the home's `kendex.settings.toml` is unset or empty, this step sets it to `.agents/skills/jarvis/scripts/progress-log`, the home-contract commit check. That check refuses a commit whose staged memory notes or State break the home contract's structure.
- A home that already names a lane there keeps it, and the step prints `init-local-lane=kept` with the check's path for that lane to call.
- [Install](../README.md#install) lists the questions `kendex add` asks and the answer each one needs.
- `git init` alone does not separate a folder inside a project from that project. When the enclosing project has kendex or harness files, `kendex add` there installs into the enclosing project. Otherwise it installs into the folder, and this step refuses the folder as `inside-work-tree`.

In a qualifying folder the step creates each missing starting file and keeps each existing one unchanged:

- `AGENTS.md`, holding one line that routes to the installed `persona.md` and reuses persona text already loaded, so an app that supplies the persona does not load it twice;
- `memory/MEMORY.md`, the memory index;
- the `state/` folder.

It creates no Git repository, handoff or other folder; their own writers create them when needed.

- A folder that already holds `AGENTS.md` and `memory/MEMORY.md` is an initialized home. Git does not carry an empty `state/` to a clone, so the step creates only that folder there and does not judge the folder again.
- A change to the starting text reaches only new homes, since `AGENTS.md` is yours.

The step also adds each harness's vendor-memory switch when it is missing, so the home keeps one memory:

- `"autoMemoryEnabled": false` in `.claude/settings.json` when `.claude/` exists;
- `memories = false` under `[features]` in `.codex/config.toml` when `.codex/` exists. The Codex edit needs Python 3.11 or newer.

A value already set stays. The step inserts its key and changes no other byte. A linked file, an unreadable file, or a table it cannot extend stays unchanged.

`init` prints one JSON object: `v`, the format version `1`; `home`; `created` and `kept` for the starting files; and `settings` rows with `path`, `key`, `outcome` (`merged`, `kept` or `refused`) and, when refused, `cause` (`linked`, `unreadable`, `shape`, `unwritable` or `toml-reader-missing`).

- Each refused row also prints `jarvis-session: init-settings=refused path=PATH cause=CAUSE` on stderr.
- A folder that does not qualify exits 1 with `jarvis-session: init=refused cause=CAUSE`, followed by the separate-folder action, and writes nothing. CAUSE is one of:
  - `no-git`;
  - `inside-work-tree`, with `work-tree=` naming the top-level folder of the enclosing work tree as a JSON string;
  - `other-entry`, with `entry=` naming the first other entry as a JSON string.
- A write that fails exits 1 with `jarvis-session: init=failed path=PATH cause=CAUSE created=LIST`.
- A Git read that fails, such as a repository Git cannot read, exits 1 with `jarvis-session: init=failed path=DIR cause=CAUSE created=` and writes nothing.
  - DIR is `.` for the home's own repository or `..` for the search for an enclosing one.
  - CAUSE is `git-exit-N`, or `git-` and the error name when Git could not run.
  - `detail=` follows with Git's first error line as a JSON string when Git printed one.
- A HOME that does not resolve exits 2.
- A first Start in a folder that does not qualify answers `blocked` with reason `home-not-dedicated` and prints the same refusal line.
- A first Start whose write or Git read fails answers `failed` with reason `launch-failed` and prints the same failure line.
- On a successful first Start, the step adds only the refused settings lines to stderr.

## Copilot folder trust

A home whose `JARVIS_UNATTENDED_HARNESSES` names `copilot` skips this step: Copilot then launches with `--allow-all`, which also trusts the folder without the dialog. Otherwise:

1. Before the first Jarvis Start with Copilot CLI, open this home in native Copilot with the selected account.
2. Approve its folder-trust request once. Jarvis does not approve native security requests.

Without this setup, Start ends the native session and reports Blocked with reason `trust-required`, naming the dialog's question in its detail.

## Claude Code bypass consent

A home whose `JARVIS_UNATTENDED_HARNESSES` names `claude` launches Claude Code with `--dangerously-skip-permissions`. Claude Code asks once per account to accept Bypass Permissions mode, and Jarvis does not approve native security requests.

1. Before the first Jarvis Start with Claude Code, launch the selected account once natively with `--dangerously-skip-permissions`.
2. Accept Bypass Permissions mode.

Without this setup, Start waits at that dialog until its launch bound ends and reports Failed with reason `launch-failed`.

## Session record

The [session command](session-command.md#session-command) keeps one tmux controller per canonical home.

- Its record stays across logins and restarts.
- Each home uses a separate tmux socket. The sessions Start and succession open live on that socket, so a restart of your own tmux server does not end Jarvis.
- Status names that socket and the owned session, window and pane. While a controller is live, it prints the attach command on stderr.

The record also keeps the private brief that the [session command](session-command.md#session-command) describes. The stored brief is continuing instruction: put a one-time fact, such as a session number, in the handoff.

- To replace the stored brief while the controller runs, use `jarvis-session update-brief --home HOME --brief-file PATH` with a file in Start's brief format.
- The command changes only the stored brief, and the next `succeed` delivers the new text.
- A Start that changes the app, account or model keeps only its own `--brief-file`.
- With an unreadable or invalid file, no running controller, Off, or a launch, stop or handover in progress, it answers `blocked` with reason `record-unreadable` and leaves the record unchanged.

## Attach

A tmux picker such as sesh lists only your default server, so it does not show the managed session. Your route to it is `jarvis-session attach --home HOME`, from the Jarvis package installed in HOME.

- Outside tmux, the command attaches your terminal to the recorded socket and session.
- Inside tmux, it opens the attach in a new window of your terminal and leaves your tmux client where it is.
  - It opens that window through `xdg-terminal-exec`, which picks your terminal from your terminal list and the terminals' desktop entries; `$TERMINAL` is not read.
  - The command succeeds once the new window's client is on the managed session.
  - With no `xdg-terminal-exec` on PATH, it refuses inside tmux.
- The [session command](session-command.md#session-command) explains `terminal-unresolved`; the refusal line names every other cause.

kendex does not write your picker's configuration. One sesh session entry serves both sesh and television's sesh channel, which lists sesh's configured sessions and connects through `sesh connect`. To reach Jarvis from a picker:

1. Add an entry that runs the attach command, with HOME's absolute path in place of HOME:

   ```toml
   [[session]]
   name = "jarvis"
   path = "HOME"
   startup_command = "HOME/.agents/skills/jarvis/scripts/jarvis-session attach --home HOME && exit"
   ```

2. For television, bind its sesh channel to a key such as Ctrl+Shift+S.

The picker creates a session on your server and runs the command in it. The `&& exit` closes that session once the window opens. tmux's `detach-on-destroy` option then decides where your client goes. A refusal leaves its line on screen.
