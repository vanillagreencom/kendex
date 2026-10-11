# Mailbox

A repository mailbox for AI coding sessions and the owner who answers their questions.

## Features

- Keeps questions, notices and answers in the repository.
- Reads pending questions and resolves them through one mailbox.
- Delivers lane and peer messages when orch supplies a recorded reader.

## Install

```sh
kendex add vanillagreencom/kendex --skill mailbox
```

## How it works

Each repository keeps its messages on disk. Sessions read the mailbox through `lane-mail`. A lock protects messages when writers send at the same time. Orch supplies the session records for lane and peer delivery.

## Licence

MIT.
