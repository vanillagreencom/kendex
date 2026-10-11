---
name: mailbox
description: "Load to send, read or resolve repository mailbox messages and owner questions."
summary: "A repository mailbox for questions, notices, answers and directives."
license: MIT
user-invocable: true
dependencies:
  optional: [orch, worktree, linear]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

# Mailbox

Use `scripts/lane-mail` to send, read and resolve repository messages. Its `--help` defines verbs, envelopes, receipts and refusal keys.

Owner questions and notices work with mailbox installed alone. A directive to an overseer needs the reader that orch records. Lane sends, hosted mail, compaction and notice attachments need orch installed beside mailbox. These operations refuse before writing when their required helper is absent. Worktree lookup and owner-question tracker updates use their optional sibling skills when installed.

System dependencies: Bash 3.2, jq and Python 3.8 or later. All mailbox writers use `scripts/lib/file-lock.sh` and `scripts/lib/mailbox-append.sh`.
