---
name: jarvis
description: "Load when acting for the user on their computer, browser, accounts, messages or records, or when starting, handing off or ending a long session."
summary: "Guides a delegated desktop assistant through user decisions, checked results and communication. Includes a persona for the user's standing instructions."
license: MIT
user-invocable: true
dependencies:
  required: [commit-guards, communication, docs-writing, mailbox, orch, slack]
  optional: [github, linear]
  agents: [cpa, legal, operator, auditor, researcher, scout, reviewer-arch, publicist]
  commands:
    - command: agent-browser
      purpose: Browser automation and the installed core guide
      floor: "0.26.0"
      packages:
        npm: agent-browser
    - command: python3
      purpose: Run the packaged desktop and session tools
      floor: "3.8"
    - command: bash
      purpose: Run session launch and scratch cleanup commands
    - command: kendex
      purpose: Discover projects and manage assistant packages
    - command: jq
      purpose: Read and write session records
    - command: cat
      purpose: Keep the session lock's input open
    - command: tmux
      purpose: Keep the continuing session in a terminal
      optional: true
    - command: git
      purpose: Protect private credential files and read committed document reports
    - command: find
      purpose: Remove expired assistant scratch files
    - command: gh
      purpose: Optional GitHub account connection
      optional: true
    - command: ssh
      purpose: Optional fleet machine connection
      optional: true
    - command: claude
      purpose: Optional Claude continuing session
      optional: true
    - command: codex
      purpose: Optional Codex continuing session
      optional: true
    - command: copilot
      purpose: Optional Copilot continuing session
      optional: true
    - command: pi
      purpose: Optional Pi continuing session
      optional: true
    - command: op
      purpose: Optional 1Password session broker on Linux and macOS
      optional: true
      packages:
        brew: 1password-cli
    - command: chromium
      purpose: Optional browser alternative on Linux
      optional: true
    - command: chromium-browser
      purpose: Optional browser alternative on Linux
      optional: true
    - command: google-chrome
      purpose: Optional browser alternative on Linux
      optional: true
    - command: google-chrome-stable
      purpose: Optional browser alternative on Linux
      optional: true
    - command: chrome
      purpose: Optional browser alternative on Linux
      optional: true
    - command: brave-browser
      purpose: Optional browser alternative on Linux
      optional: true
    - command: brave
      purpose: Optional browser alternative on Linux
      optional: true
    - command: microsoft-edge
      purpose: Optional browser alternative on Linux
      optional: true
    - command: microsoft-edge-stable
      purpose: Optional browser alternative on Linux
      optional: true
    - command: ydotool
      purpose: Optional pointer input on Linux Wayland
      optional: true
    - command: hyprctl
      purpose: Optional pointer movement in logical coordinates on Hyprland
      optional: true
    - command: wtype
      purpose: Optional keyboard input on Linux Wayland
      optional: true
    - command: grim
      purpose: Optional screen capture on Linux Wayland
      optional: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [assistant, productivity]
---

# Jarvis

Jarvis is the owner's main long-running session. Jarvis main is the one computer that runs Jarvis. Jarvis Voice is the VGS voice session on any computer. A Jarvis satellite is another of the owner's computers with a clone of the Jarvis home. It runs Jarvis Voice, not Jarvis, and forwards long work to Jarvis main. Agent reach covers its [local console session](references/agent-reach.md#satellite) and [forwarding](references/agent-reach.md#forward).

## Setup

The Jarvis home is the folder that holds Jarvis's instructions, skills and memory. [README: Install](README.md#install) creates it at `~/jarvis`. The [home layout](references/home-layout.md) places its files. `jarvis-session init` or a person's first manual Start writes its starting files, under [Initialize](references/home-layout.md#initialize).

The declared agents need a kendex installation of Jarvis: `cpa`, `legal`, `operator`, `auditor`, `researcher`, `scout`, `reviewer-arch` and `publicist`. A copy of the skill folder alone, an app-supplied copy included, supplies none of their harness agent files. From the Jarvis home, run the bundle command in [README: Install](README.md#install). It installs Jarvis, its required skills, its declared agents, their assigned skills and the session hooks. Installing `orch` alone installs neither Jarvis nor its declared agents.

Read the [home contract](references/home-contract.md) when starting a session or finding a memory note.

kendex inserts no package text into `AGENTS.md`. The persona lives at `persona.md`, beside `SKILL.md`.

### Plain folder

1. On first load, look in the folder's `AGENTS.md` for a line that routes to [persona.md](persona.md).
2. If none does, offer once, in one line, to add the route line [Initialize](references/home-layout.md#initialize) writes.
3. Add it only after the user agrees. Never paste the persona text into `AGENTS.md`.
4. The harness's instruction-loading settings then load the route on every turn. Check that the harness loaded those instructions.

### App-managed home

The assistant app gives `persona.md` to its sessions. Here, a line in `AGENTS.md` that routes to `persona.md` is the persona step. Do not offer to paste the persona text into `AGENTS.md`.

### Reachable repositories

At first load, and when the user asks which repositories Jarvis can reach, judge each folder `kendex project list` prints. Judge a `(worktree of [MAIN])` row by `[MAIN]`.

- Run the folder's own `.agents/skills/mailbox/scripts/lane-mail events --item overseer --box to-overseer`, with the folder as the working directory. Exit 0 means reachable. An unwritten mailbox prints no envelope and exits 0. The probe records no read position. Read session messages through [Agent reach: Read](references/agent-reach.md#read).
- Any other result means unreachable. The cause is the folder's note, a missing mailbox script, or the key `lane-mail` printed.
- A folder with `.agents/skills/orch/` but no mailbox script has an orch older than the mailbox package. Its cause is "refresh needed". Offer `kendex refresh` in that folder.

Report both lists in one message, with each unreachable folder's cause.

## Cleanup and backups

- In the same change, remove every unused code, file, key, secret-store entry, database, record and setting from every holder.
- Back up only when a step can lose the only copy.
- Delete the backup after checking the result.

## Reading routes

Read the linked workflow or reference for the task before acting.

| Task | Read first |
|---|---|
| Draft product videos, posts or outreach | The `publicist` agent, by the steps below the table |
| Read mail, pages or files, choose an action, request approval or wait for a future condition | [references/decisions.md](references/decisions.md) |
| Check a result, report evidence or automate repeated work | [references/verification.md](references/verification.md) |
| Reply, request a decision, report progress or use the user's input devices | [communication](../communication/SKILL.md) and the [local delivery routes](references/communication.md) |
| Start a continuing session, reconcile open work or transfer control | [workflows/session.md](workflows/session.md) |
| Start, stop or attach to the managed session, launch a Jarvis task, or read a `jarvis-session` or `task` answer | [references/session-command.md](references/session-command.md) |
| Report committed Markdown growth and shape for explicit repositories and dates | [workflows/docs-audit.md](workflows/docs-audit.md) |
| Run the weekly efficiency audit | [workflows/efficiency-audit.md](workflows/efficiency-audit.md) |
| Add an agent or skill, or change an installed agent | [Home contract: Personal additions](references/home-contract.md#personal-additions) and [home layout](references/home-layout.md) |
| Remember a fact or establish a workstream | [Home contract: Personal additions](references/home-contract.md#personal-additions) and [memory](references/memory.md) |
| Add a hook or schedule | [Home contract: Personal additions](references/home-contract.md#personal-additions) and [verification](references/verification.md) |
| Save or revise a durable fact, preference, ruling or lesson | [references/memory.md](references/memory.md) |
| Control a desktop or terminal, recover work or manage scratch files | [references/computer-use.md](references/computer-use.md) |
| Use an automation browser, fill a form or handle a bot check | [references/browser.md](references/browser.md) |
| Handle credentials, account limits, sign-in or official records | [references/accounts-and-secrets.md](references/accounts-and-secrets.md) |
| Prepare a filing obligation, close a month against the bank, triage mail with a deadline or request a finance decision | [references/finance.md](references/finance.md) |
| Connect Slack, Linear, GitHub or a fleet machine | [Slack](workflows/setup-slack.md), [Linear](workflows/setup-linear.md), [GitHub](workflows/setup-github.md), [Fleet machine](workflows/setup-fleet-machine.md) |
| Find sources, check a legal answer or audit work and documentation | [references/research.md](references/research.md) |
| Report from, answer or instruct the agent in another of the user's repositories | [references/agent-reach.md](references/agent-reach.md) |
| Use Jarvis Voice on a Jarvis satellite, or forward a request to Jarvis main | [Agent reach: Main and satellites](references/agent-reach.md#main-and-satellites) |
| List shared owner asks or send Later from a console | [Owner asks](references/owner-asks.md) |

To draft product videos, posts or outreach:

1. Launch `publicist` with a task file or an attached prompt.
2. Before a publisher setup launch, get the consumer's approval under [Authority](references/decisions.md#authority) and [Message types](references/communication.md#message-types).
3. Carry the approval record and named publisher selections in the setup task file.
