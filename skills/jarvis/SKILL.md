---
name: jarvis
description: "Load when acting for the user on their computer, browser, accounts, messages or records, or when starting, handing off or ending a long session."
summary: "Guides a delegated desktop assistant through user decisions, checked results and communication. Includes a persona for the user's standing instructions."
license: MIT
user-invocable: true
dependencies:
  required: [mailbox]
  agents: [cpa, legal, operator, auditor, researcher, scout, reviewer-arch]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [assistant, productivity]
---

# Jarvis

## Setup

Use the [home layout](README.md#home-layout) for the assistant home.

kendex does not insert package text into `AGENTS.md`. The fixed persona path is `persona.md`, beside `SKILL.md`.

### Plain folder

On first load, check the folder's `AGENTS.md`. If it lacks the persona, offer once, in one line, to add the text from [persona.md](persona.md). Add it only after the user agrees. The persona then loads on every turn through the harness's instruction-loading settings. Check that the harness loaded those instructions.

### App-managed home

The assistant app gives `persona.md` to its sessions itself. A line in `AGENTS.md` that routes to `persona.md` is the persona step here. Do not offer to paste the persona text into `AGENTS.md`. The text would load twice. `persona.md` must not exceed 3,072 bytes. An app that reads it directly can reject a larger file.

## Reading routes

Read the linked workflow or reference for the task before acting.

| Task | Read first |
|---|---|
| Choose an action, request approval or wait for a future condition | [references/decisions.md](references/decisions.md) |
| Check a result, report evidence or automate repeated work | [references/verification.md](references/verification.md) |
| Reply, request a decision, report progress or use the user's input devices | [references/communication.md](references/communication.md) |
| Start a continuing session, reconcile open work or transfer control | [workflows/session.md](workflows/session.md) |
| Run the weekly efficiency audit | [workflows/efficiency-audit.md](workflows/efficiency-audit.md) |
| Save or revise a durable fact, preference, ruling or lesson | [references/memory.md](references/memory.md) |
| Control a desktop or terminal, recover work or manage scratch files | [references/computer-use.md](references/computer-use.md) |
| Use an automation browser, fill a form or handle a bot check | [references/browser.md](references/browser.md) |
| Handle credentials, account limits, sign-in or official records | [references/accounts-and-secrets.md](references/accounts-and-secrets.md) |
| Connect Slack, Linear, GitHub or a fleet machine | [Slack](workflows/setup-slack.md), [Linear](workflows/setup-linear.md), [GitHub](workflows/setup-github.md), [Fleet machine](workflows/setup-fleet-machine.md) |
| Find sources, check a legal answer or audit work and documentation | [references/research.md](references/research.md) |
