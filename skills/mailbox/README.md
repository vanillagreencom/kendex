# Mailbox

A repository mailbox for AI coding sessions and the owner who answers their questions.

## Features

- Keeps questions, notices and answers in the repository.
- Reads pending questions and resolves them through one mailbox.
- Carries a notice a program writes, such as a mail watch's summary of an email, as data from a named source and never as an instruction.
- With orch installed, also carries messages between orch's lanes, their overseer and peer sessions.

## Install

```sh
kendex add vanillagreencom/kendex --skill mailbox
```

## How it works

Each repository keeps its messages on disk. Sessions send and read them with the `lane-mail` command. Two sessions sending at once never lose a message.

## Setup

Requires Bash, jq and Python 3.8 or newer. Bash 3.2 is supported.

## Licence

MIT.
