# Home layout

Read when setting up an assistant home, choosing a home path or starting a continuing session.

## Paths

| Path | Git status | Reason |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions travel with you. |
| `skills/own/` | Committed | You are the source. kendex installs your skills from here. |
| `memory/` | Committed | Durable facts and rulings travel with you under [Memory](memory.md). |
| `state/handoff.md` | Committed | The session model writes the current handoff under [Handoff](long-session.md#handoff). |
| `state/archive/` | Committed | The session model writes archived handoffs and progress logs under [Handoff](long-session.md#handoff). |
| Other files under `state/` | Committed | A consumer's file and shell tools write its work here. An app-managed home limits model file and shell writes to this folder. |
| `${XDG_STATE_HOME:-$HOME/.local/state}/kendex/jarvis/<canonical-home-key>/jarvis-session.json` | Outside the home | The session runtime and the native SessionStart hook write the local controller record. The runtime writes no start-critical record under `state/`. |
| `.agents/skills/` and each harness's skill and agent directories, such as `.claude/skills/`, `.claude/agents/` and `.codex/agents/` | Committed | kendex renders or links installed skills and agents here so a clone has them. In a home where kendex did not install Jarvis, an assistant app such as VGS can copy a kendex-rendered package to these same paths. |
| `tmp/` | Local | Scratch files stay on this machine under [Scratch files](computer-use.md#scratch-files). |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets stay on this machine; kendex creates the file with mode 600. |

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

## Copilot folder trust

Before the first Jarvis Start with Copilot CLI, open this home in native Copilot with the selected account. Approve its folder-trust request once. Jarvis does not approve native security requests. Without this setup, Start ends the native session and reports Blocked with reason `trust-required`, naming the dialog's question in its detail.

## Session record

The [session command](../workflows/session.md#session-command) keeps one tmux controller per canonical home. Its record stays across logins and restarts. Each home uses a separate tmux socket. Status names that socket and the owned session, window and pane.
