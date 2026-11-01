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

# Communication

## Scope

Use this package for messages to a person. Agent-to-agent messages, literal return formats, tool prompts, documentation and text sent as the user follow their own owners. The caller owns authority, delivery and report schedules.

## Reading routes

Read this file and [messages](references/messages.md) once per revision, then apply them to every message. A revision is the file text the session last read. Read a file again only when it changed after that read, or when that read is no longer in the session's context, for example after a context summary. Add only the reference the task needs, read on the same terms:

| Task | Read |
|---|---|
| Request a decision or action | [questions](references/questions.md) |
| Write a report, briefing, work-item description, comment or completion summary | [reports](references/reports.md) |
| Answer a voice request | [voice](references/voice.md) |

## User instruction

For a global install, put this writing reference in the user-scope instruction file:

```text
Read `$HOME/.agents/skills/communication/SKILL.md` once per revision, and apply it before every message to a person.
```

For a project install, put this writing reference in the project-scope instruction file. The path is relative to the project root:

```text
Read `.agents/skills/communication/SKILL.md` once per revision, and apply it before every message to a person.
```
