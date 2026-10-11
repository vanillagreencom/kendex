---
name: jarvis
description: "Load when acting for the user on their computer, browser, accounts, messages or records, or when starting, handing off or ending a long session."
summary: "Guides a delegated desktop assistant through user decisions, checked results and communication. Includes a persona for the user's standing instructions."
license: MIT
user-invocable: true
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

kendex does not insert package text into `AGENTS.md`. The fixed persona path is `persona.md`, beside `SKILL.md`.

### Plain folder

The persona loads on every turn only when its text is in the folder's `AGENTS.md`, which Claude Code, Codex, Copilot CLI and Pi read through their instruction-loading settings. Check that the harness loaded those instructions. When that file lacks the persona, offer once to add the text from [persona.md](persona.md), then add it only after the user agrees.

### App-managed home

The assistant app gives `persona.md` to its sessions itself. A line in `AGENTS.md` that routes to `persona.md` is the persona step here. Do not offer to paste the persona text into `AGENTS.md`. The text would load twice. `persona.md` must not exceed 3,072 bytes. An app that reads it directly can reject a larger file.

## Reading routes

Read the reference for the task before acting.

| Task | Read first |
|---|---|
| Choose an action, request approval or wait for a future condition | [references/decisions.md](references/decisions.md) |
| Check a result, report evidence or automate repeated work | [references/verification.md](references/verification.md) |
| Reply, request a decision, report progress or use the user's input devices | [references/communication.md](references/communication.md) |
| Start a continuing session, reconcile open work or transfer control | [references/long-session.md](references/long-session.md) |
| Save or revise a durable fact, preference, ruling or lesson | [references/memory.md](references/memory.md) |
| Control a desktop or terminal, recover work or manage scratch files | [references/computer-use.md](references/computer-use.md) |
| Use an automation browser, fill a form or handle a bot check | [references/browser.md](references/browser.md) |
| Handle credentials, account limits, sign-in or official records | [references/accounts-and-secrets.md](references/accounts-and-secrets.md) |
| Find sources, check a legal answer or audit work and documentation | [references/research.md](references/research.md) |
