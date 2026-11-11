# Jarvis

Jarvis turns your coding assistant into a personal assistant that carries out the work you hand it. It runs in Claude Code, Codex, Copilot CLI or Pi from a folder of its own, with or without a desktop app.

## Features

- One assistant that keeps running and handles tasks for you on your computer.
- Specialist agents for finance and tax, legal questions, research, audits, outreach and more, with the kendex install below.
- Asks before deleting, spending, making a commitment or sending in your name, unless your instructions grant that action.
- Checks each result before it reports a task as done.
- Keeps memories, rules and workflows that last between sessions.
- Picks up open work after a restart or a handover.
- Uses your mouse, keyboard and screen on Linux Wayland, including Hyprland, once you agree.
- Fills in forms and works in your accounts from its own browser profile.
- Reads reports from the agents in your other kendex projects and sends them the instructions you approve.
- Guided setup for Slack, Linear, GitHub and fleet machines.
- Takes long work from Jarvis Voice on another computer after you confirm.
- Runs skills you write yourself.

## Install

You need kendex, Git, Python 3.8 or newer, Bash, jq, tmux, one supported coding assistant you have signed in to (Claude Code, Codex, Copilot CLI or Pi), and a Linear workspace. The continuing session keeps its open work in Linear.

Your Jarvis home is a new folder of its own, outside any existing project. Running `git init` in a folder inside a project does not separate it from that project. Run these four commands, with your assistant in place of `codex`:

```sh
mkdir ~/jarvis && cd ~/jarvis && git init
kendex add vanillagreencom/kendex --bundle jarvis --harness codex
.agents/skills/jarvis/scripts/jarvis-session start --home . --harness codex
.agents/skills/jarvis/scripts/jarvis-session attach --home .
```

- `kendex add` asks whether to install into this folder and whether to set up the commit-guards hooks. Answer yes to both. List each assistant you use in `--harness`, comma-separated.
- The first `start` writes the starting files, an `AGENTS.md` that loads the [persona](persona.md), the memory index and `state/`, and then starts the session. It uses the account folder your assistant uses, such as `~/.codex` or the folder `CODEX_HOME` names; add `--account DIR` for another one. In a folder that is not a new home of its own, it refuses and names what to do. [Initialize](references/home-layout.md#initialize) has the details.
- `attach` puts your terminal on the running session. Before the first start with Copilot CLI, follow [Copilot folder trust](references/home-layout.md#copilot-folder-trust).

## How it works

Jarvis runs as a session of your coding assistant in your Jarvis home. You give it requests in its terminal, through Slack or by voice. For each request it reads the guidance it needs, does the work or hands part of it to a specialist agent, checks the result and tells you what the evidence shows. It asks you before any step you keep for yourself. Open work stays in your tracker, and notes in the home let the next session carry on. These pages explain the current package and name the parts still being built.

- **Jarvis** is the main long-running session.
- **Jarvis Voice** is the VGS voice session on any computer.
- **Jarvis main** is the computer that runs Jarvis.
- **Jarvis satellite** is a computer that runs Jarvis Voice, not Jarvis, and forwards long work to Jarvis main. Its [local console session](references/agent-reach.md#satellite) and [forwarding](references/agent-reach.md#forward) are described separately.
- **Jarvis home** is `~/dev/jarvis`, the folder with Jarvis's instructions, skills and memory. Keep it in a private Git repository of its own, not in a work project. Its committed files travel with the repository; scratch files and secrets stay on each computer.

| Your question | Read |
|---|---|
| How does a request get finished? | [Tasks](documentation/HIW-tasks.md) |
| How does Jarvis work with other agents? | [Delegation](documentation/HIW-delegation.md) |
| How does work continue after a restart or handover? | [Sessions](documentation/HIW-sessions.md) |
| What does Jarvis remember? | [Memory](documentation/HIW-memory.md) |
| How do requests and decisions reach Jarvis? | [Messages](documentation/HIW-messages.md) |
| What happens when a result needs another check? | [Checks](documentation/HIW-checks.md) |
| How does Jarvis use my computer and accounts? | [Tools](documentation/HIW-tools.md) |
| What belongs in my Jarvis home? | [Home](documentation/HIW-home.md) |

## Customize

Your own files sit in the Jarvis home beside the package, and package updates leave them as they are. The [home layout](references/home-layout.md) lists every file and whether Git keeps it.

- `AGENTS.md` holds your standing instructions: who decides what, and which work Jarvis may do without asking.
- `skills/own/` holds skills you write. Create `skills/own/my-task/SKILL.md` with a frontmatter `name: my-task` and a `description` that says when to read it, then the instructions below it. Install it from your Jarvis home with `kendex add ./skills/own/my-task --skill my-task --harness codex --yes`, naming your harnesses in `--harness`.
- `memory/` holds facts and preferences under [Memory](references/memory.md). Keep secrets in a password manager, never in memory.
- `kendex.settings.toml` holds shared settings under `[env]`, such as the report cadence, quiet hours, time zone and report folder. The [settings example](kendex.settings.toml.example) lists them.
- `.env.local` holds secrets and settings for one computer only. Its values override `kendex.settings.toml`.

## Use from another computer

To use Jarvis Voice on a second computer, make that computer a Jarvis satellite with a clone of your Jarvis home:

1. Clone the Jarvis home's private repository onto the computer, and run the next steps in the clone.
2. Run `kendex guard install` to turn on the commit checks. Git does not copy them with a clone.
3. Run `.agents/skills/jarvis/scripts/jarvis-session main-host --home . --set DEST:/path/to/main/home`, where `DEST` is the SSH destination of Jarvis main and the path is the Jarvis home on it. The command saves `JARVIS_MAIN_HOST` in this computer's `.env.local`. Never put it in `kendex.settings.toml`: Jarvis main would pull it and become a satellite too.
4. Move the secrets this computer needs under [Secret transfer](references/accounts-and-secrets.md#secret-transfer). A clone carries none of them.

The satellite handles voice, windows, apps, files, the screen and sign-ins on that computer. It asks before it forwards other work to Jarvis main, and the request and answer appear in your Slack channel. Leave `JARVIS_MAIN_HOST` empty on Jarvis main only. Do not commit or push the Jarvis home from a satellite.

## Update

Run `kendex refresh` in your Jarvis home. It updates the package and leaves your `AGENTS.md`, own skills, memory and handoffs as they are, so a later change to the starting `AGENTS.md` text does not reach an existing home. In a home where VGS installed Jarvis without kendex, VGS updates the package when it opens the home.

## Uninstall

1. If VGS starts Jarvis when you log in, turn off its Session at boot setting. Remove any login entry of your own that runs `jarvis-session start --origin boot`.
2. On Pi or Copilot CLI, ask Jarvis to stop its event loop. There it runs as a separate background job.
3. Stop the session with `.agents/skills/jarvis/scripts/jarvis-session stop --home .` from your Jarvis home. Run `.agents/skills/jarvis/scripts/jarvis-session status --home .` until it reads `stopped` or `off` before removing anything; stop and report if it reads `blocked` or `failed`.
4. Stop and disable each service you set up that runs a script from this home's `.agents/skills/`, such as the 1Password broker.
5. If the Slack relay on this computer also serves other checkouts, run `.agents/skills/slack/scripts/slack install` again from one of them, with one `--root` for each remaining checkout. If this home is its only checkout, run `systemctl --user disable --now slack-listen.service` and delete `~/.config/systemd/user/slack-listen.service`.
6. Run `kendex remove jarvis --sweep` to remove the package and the packages only it needed. kendex turns off the commit checks before it removes commit-guards.
7. Delete this home's local state on each computer. Its session record and queued forwards are in `~/.local/state/kendex/jarvis/KEY/`, where `KEY` is what `python3 -c 'import hashlib, os; print(hashlib.sha256(os.fsencode(os.path.realpath("."))).hexdigest())'` prints in the Jarvis home. Its event log is in `JARVIS_LOG_DIR`, by default `~/.local/state/jarvis/`. Delete only that `KEY` folder, and the log folder only when no other Jarvis home uses it.
8. Keep the Jarvis home to start again later, or delete it. Deleting it deletes your instructions, memory and handoffs, apart from any copy in its remote.

## Licence

MIT.
