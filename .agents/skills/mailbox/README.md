# Mailbox

A repository mailbox for AI coding sessions and the owner who answers their questions.

## Features

- Keeps questions, notices and answers in the repository.
- Reads pending questions and resolves them through one mailbox.
- With orch installed, also carries messages between orch's lanes, their overseer and peer sessions.

## Install

```sh
kendex add vanillagreencom/kendex --skill mailbox
```

## How it works

Each repository keeps its messages on disk. Sessions send and read them with the `lane-mail` command. Two sessions sending at once never lose a message.

## Licence

MIT.
