---
name: communication
description: "Load before writing a message to a person: a reply, report, briefing, decision request, or issue or comment addressed to the user."
summary: "Plain-language messages, reader modes, decision questions, reports, threads and spoken replies."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [communication]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Communication

## Scope

Use this package for messages to a person. Agent-to-agent messages, literal return formats, tool prompts, documentation and text sent as the user follow their own owners. The caller owns authority, delivery and report schedules.

## Reading routes

Read [messages](references/messages.md) before every message. Add only the reference the task needs:

| Task | Read |
|---|---|
| Request a decision or action | [questions](references/questions.md) |
| Write a report, briefing, work-item description, comment or completion summary | [reports](references/reports.md) |
| Answer a voice request | [voice](references/voice.md) |

## User instruction

The supported installed path is `.agents/skills/communication/SKILL.md`, relative to the consumer project or assistant home. Its user instruction file carries this writing reference:

```text
Before writing a message to a person, read `.agents/skills/communication/SKILL.md`.
```
