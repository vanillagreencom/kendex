# Home layout

Read when setting up a Jarvis home, choosing a home path, starting a continuing session or reaching the managed session from a terminal.

## Paths

| Path | Git status | Reason |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions travel with you. |
| `skills/own/` | Committed | You are the source. kendex installs your skills from here. |
| `memory/` | Committed | Durable facts and rulings travel with you under [Memory](memory.md). |
| `state/handoff.md` | Committed | Default current handoff. `jarvis-session succeed` saves and hands over this file only; `progress-log` and `owner-unanswered` select another through `--handoff PATH` under [Handoff](long-session.md#handoff). |
| `state/archive/` | Committed | The session model writes archived handoffs and progress logs under [Handoff](long-session.md#handoff). `jarvis-session succeed` saves its own copy of the handoff as `handoff-<generation>-<id>.md`. |
| `state/archive/INDEX.md` | Committed | `progress-log --archived` adds one dated line for each file the session's handoff replacement step archives, under [Handoff](long-session.md#handoff). `owner-unanswered` reads any file it does not list, such as the copy `jarvis-session succeed` saves. |
| Other files under `state/` | Committed | A consumer's file and shell tools write its work here. An app-managed home limits model file and shell writes to this folder. |
| `${XDG_STATE_HOME:-$HOME/.local/state}/kendex/jarvis/<canonical-home-key>/jarvis-session.json` | Outside the home | The session runtime and the native SessionStart hook write the local controller record. The runtime writes no start-critical record under `state/`. |
| `.agents/skills/` and each harness's skill and agent directories, such as `.claude/skills/`, `.claude/agents/` and `.codex/agents/` | Committed | kendex renders or links installed skills and agents here so a clone has them. In a home where kendex did not install Jarvis, an assistant app such as VGS can copy a kendex-rendered package to these same paths. |
| `tmp/` | Local | Scratch files stay on this machine under [Scratch files](computer-use.md#scratch-files). |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets stay on this machine; kendex creates the file with mode 600. |

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

## Initialize

`jarvis-session init --home HOME` writes the missing starting files of a Jarvis home. A person's first manual Start runs the same step when this machine holds no session record for HOME and a starting file is missing. A boot or `app-on` Start never runs it; an app calls `init` itself. A Start that leaves out `--account`, `--mode` and `--origin` uses `new`, `manual` and the account directory the harness itself uses: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME` or `PI_CODING_AGENT_DIR` when set, otherwise `~/.claude`, `~/.codex`, `~/.copilot` or `~/.pi/agent`. The orch package's account resolver gives this answer. An app passes each value itself.

A folder qualifies when it is its own Git root, lies inside no other Git work tree, and has no top-level entry beyond these names:

- the paths above: `AGENTS.md`, `skills`, `memory`, `state`, `tmp` and `.env.local`; only `.env.local` counts as the private env file, so a home whose `KENDEX_ENV_FILE` names another top-level file does not qualify;
- Git's `.git` and `.gitignore`;
- kendex's `kendex.toml`, `kendex.settings.toml`, `.kendex-lock.json`, `.kendex-generated.json`, `.cache`, `.kendex` and `.kendex-local`;
- the harness folders and files kendex writes: `.agents`, `.claude`, `.codex`, `.github`, `.pi`, `.opencode`, `.cursor`, `.gemini`, `.mcp.json`, `opencode.json` and `opencode.jsonc`.

Make the home a new folder outside any project and run `git init` before `kendex add`, so `kendex add` can offer to commit the files it writes and to set up the commit-guards hooks. [Install](../README.md#install) lists the questions `kendex add` asks and the answer each one needs. `git init` alone does not separate a folder inside a project from that project. When the enclosing project has kendex or harness files, `kendex add` there installs into the enclosing project; otherwise it installs into the folder, and this step refuses the folder as `inside-work-tree`.

In a qualifying folder the step creates each missing starting file and keeps each existing one unchanged:

- `AGENTS.md`, holding one line that routes to the installed `persona.md` and reuses persona text already loaded, so an app that supplies the persona does not load it twice;
- `memory/MEMORY.md`, the memory index;
- the `state/` folder.

It creates no Git repository, handoff or other folder; their own writers create them when needed. A folder that already holds `AGENTS.md` and `memory/MEMORY.md` is an initialized home: Git does not carry an empty `state/` to a clone, so the step creates only that folder there and does not judge the folder again. A change to the starting text reaches only new homes, since `AGENTS.md` is yours.

The step also adds each harness's vendor-memory switch when it is missing, so the home keeps one memory: `"autoMemoryEnabled": false` in `.claude/settings.json` when `.claude/` exists, and `memories = false` under `[features]` in `.codex/config.toml` when `.codex/` exists. A value already set stays. The step inserts its key and changes no other byte. A linked file, an unreadable file, or a table it cannot extend stays unchanged. The Codex edit needs Python 3.11 or newer.

`init` prints one JSON object: `v`, the format version `1`; `home`; `created` and `kept` for the starting files; and `settings` rows with `path`, `key`, `outcome` (`merged`, `kept` or `refused`) and, when refused, `cause` (`linked`, `unreadable`, `shape`, `unwritable` or `toml-reader-missing`). Each refused row also prints `jarvis-session: init-settings=refused path=PATH cause=CAUSE` on stderr. A folder that does not qualify exits 1 with `jarvis-session: init=refused cause=CAUSE`, where CAUSE is `no-git`, `inside-work-tree` with `work-tree=` naming the top-level folder of the enclosing work tree as a JSON string, or `other-entry` with `entry=` naming the first other entry as a JSON string, followed by the separate-folder action; it writes nothing. A write that fails exits 1 with `jarvis-session: init=failed path=PATH cause=CAUSE created=LIST`. A Git read that fails, such as a repository Git cannot read, exits 1 with `jarvis-session: init=failed path=DIR cause=CAUSE created=`, where DIR is `.` for the home's own repository or `..` for the search for an enclosing one and CAUSE is `git-exit-N`, or `git-` and the error name when Git could not run, followed by `detail=` with Git's first error line as a JSON string when Git printed one; it writes nothing. A HOME that does not resolve exits 2. A first Start in a folder that does not qualify answers `blocked` with reason `home-not-dedicated` and prints the same refusal line; a failed write or Git read answers `failed` with reason `launch-failed` and prints the same failure line. On a successful first Start, the step adds only the refused settings lines to stderr.

## Copilot folder trust

A home whose `JARVIS_UNATTENDED_HARNESSES` names `copilot` skips this step: Copilot then launches with `--allow-all`, which also trusts the folder without the dialog. Otherwise, before the first Jarvis Start with Copilot CLI, open this home in native Copilot with the selected account. Approve its folder-trust request once. Jarvis does not approve native security requests. Without this setup, Start ends the native session and reports Blocked with reason `trust-required`, naming the dialog's question in its detail.

## Claude Code bypass consent

A home whose `JARVIS_UNATTENDED_HARNESSES` names `claude` launches Claude Code with `--dangerously-skip-permissions`. Claude Code asks once per account to accept Bypass Permissions mode, and Jarvis does not approve native security requests. Before the first Jarvis Start with Claude Code, launch the selected account once natively with `--dangerously-skip-permissions` and accept. Without this setup, Start waits at that dialog until its launch bound ends and reports Failed with reason `launch-failed`.

## Session record

The [session command](../workflows/session.md#session-command) keeps one tmux controller per canonical home. Its record stays across logins and restarts. Each home uses a separate tmux socket. The sessions Start and succession open live on that socket, so a restart of your own tmux server does not end Jarvis. Status names that socket and the owned session, window and pane, and while a controller is live it prints the attach command on stderr.

The record also keeps the private brief that the [session command](../workflows/session.md#session-command) describes. The stored brief is continuing instruction: put a one-time fact, such as a session number, in the handoff. To replace the stored brief while the controller runs, use `jarvis-session update-brief --home HOME --brief-file PATH` with a file in Start's brief format. The command changes only the stored brief, and the next `succeed` delivers the new text. A Start that changes the app, account or model keeps only its own `--brief-file`. With an unreadable or invalid file, no running controller, Off, or a launch, stop or handover in progress, it answers `blocked` with reason `record-unreadable` and leaves the record unchanged.

## Attach

A tmux picker such as sesh lists only your default server, so it does not show the managed session. Your route to it is `jarvis-session attach --home HOME`, from the Jarvis package installed in HOME. Outside tmux, the command attaches your terminal to the recorded socket and session. Inside tmux, it opens the attach in a new window of your terminal and leaves your tmux client where it is. The terminal is `$TERMINAL` when it names a command on PATH, otherwise `xdg-terminal-exec`. The command succeeds once the new window's client is on the managed session. With `$TERMINAL` unset and no `xdg-terminal-exec`, it prints one line and attaches inside the current pane. Its refusals are listed under the [session command](../workflows/session.md#session-command).

To reach Jarvis from a picker, add an entry that runs the attach command. kendex does not write your picker's configuration. One sesh session entry serves both sesh and television's sesh channel, which lists sesh's configured sessions and connects through `sesh connect`; bind that channel to a key such as Ctrl+Shift+S. Put HOME's absolute path in place of HOME:

```toml
[[session]]
name = "jarvis"
path = "HOME"
startup_command = "HOME/.agents/skills/jarvis/scripts/jarvis-session attach --home HOME && exit"
```

The picker creates a session on your server and runs the command in it. The `&& exit` closes that session once the window opens, or once you detach from a nested attach. tmux's `detach-on-destroy` option then decides where your client goes. A refusal leaves its line on screen.
