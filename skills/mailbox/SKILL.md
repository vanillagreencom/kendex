---
name: mailbox
description: "Load to send, read or resolve repository mailbox messages and owner questions."
summary: "A repository mailbox for questions, notices, answers and directives."
license: MIT
user-invocable: true
dependencies:
  optional: [orch, worktree, linear, agent-runtime]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

# Mailbox

Use `scripts/lane-mail` to send, read and resolve repository messages. Its `--help` defines the verbs, envelopes, receipts and refusal keys.
