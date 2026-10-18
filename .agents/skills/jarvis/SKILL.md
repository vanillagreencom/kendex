---
name: jarvis
description: "Load when acting for the user on their computer, browser, accounts, messages or records, or when starting, handing off or ending a long session."
summary: "Guides a delegated desktop assistant through user decisions, checked results and communication. Includes a persona for the user's standing instructions."
license: MIT
user-invocable: true
dependencies:
  required: [communication, mailbox, orch, slack]
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

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Jarvis

## Setup

Use the [home layout](references/home-layout.md) for the assistant home.

Read the [home contract](references/home-contract.md) when starting a session or finding a memory note.

kendex does not insert package text into `AGENTS.md`. The fixed persona path is `persona.md`, beside `SKILL.md`.

### Plain folder

On first load, check the folder's `AGENTS.md`. If it lacks the persona, offer once, in one line, to add the text from [persona.md](persona.md). Add it only after the user agrees. The persona then loads on every turn through the harness's instruction-loading settings. Check that the harness loaded those instructions.

### App-managed home

The assistant app gives `persona.md` to its sessions itself. A line in `AGENTS.md` that routes to `persona.md` is the persona step here. Do not offer to paste the persona text into `AGENTS.md`. The text would load twice.

### Reachable repositories

At first load, and when the user asks which repositories Jarvis can reach, judge each folder `kendex project list` prints, a `(worktree of [MAIN])` line by `[MAIN]`:

- Run the folder's own `.agents/skills/mailbox/scripts/lane-mail events --item overseer --box to-overseer` with the folder as the working directory. Exit 0 is reachable; a mailbox nobody has written yet prints no envelope at exit 0. This probe records no read position. Read session messages through [Agent reach: Read](references/agent-reach.md#read).
- Anything else is unreachable. Its cause is the folder's note, a missing mailbox script, or the key `lane-mail` printed, such as `command-missing python3` or `file-unreadable`.
- A folder with no mailbox script but with `.agents/skills/orch/` has an orch older than the mailbox package. Its cause is "refresh needed", and the offer is `kendex refresh` in that folder.

Report both lists in one message, each unreachable folder with its cause.

## Cleanup and backups

Remove all unused code, files, keys, secret-store entries, databases, records and settings from every holder in the same change.

Back up only if a step can lose the only copy; delete the backup after checking the result.

## Reading routes

Read the linked workflow or reference for the task before acting.

| Task | Read first |
|---|---|
| Draft product videos, posts or outreach | Launch `publicist` for drafting with a task file or attached prompt. Before a publisher setup launch, obtain the consumer's approval under [Authority](references/decisions.md#authority) and [Message types](references/communication.md#message-types). Carry the approval record and named publisher selections in the setup task file. |
| Choose an action, request approval or wait for a future condition | [references/decisions.md](references/decisions.md) |
| Check a result, report evidence or automate repeated work | [references/verification.md](references/verification.md) |
| Reply, request a decision, report progress or use the user's input devices | [communication](../communication/SKILL.md) and the [local delivery routes](references/communication.md) |
| Start a continuing session, reconcile open work or transfer control | [workflows/session.md](workflows/session.md) |
| Report committed Markdown growth for explicit repositories and dates | [workflows/docs-audit.md](workflows/docs-audit.md) |
| Run the weekly efficiency audit | [workflows/efficiency-audit.md](workflows/efficiency-audit.md) |
| Save or revise a durable fact, preference, ruling or lesson | [references/memory.md](references/memory.md) |
| Control a desktop or terminal, recover work or manage scratch files | [references/computer-use.md](references/computer-use.md) |
| Use an automation browser, fill a form or handle a bot check | [references/browser.md](references/browser.md) |
| Handle credentials, account limits, sign-in or official records | [references/accounts-and-secrets.md](references/accounts-and-secrets.md) |
| Connect Slack, Linear, GitHub or a fleet machine | [Slack](workflows/setup-slack.md), [Linear](workflows/setup-linear.md), [GitHub](workflows/setup-github.md), [Fleet machine](workflows/setup-fleet-machine.md) |
| Find sources, check a legal answer or audit work and documentation | [references/research.md](references/research.md) |
| Report from, answer or instruct the agent in another of the user's repositories | [references/agent-reach.md](references/agent-reach.md) |
