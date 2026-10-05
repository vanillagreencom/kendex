# Docs Writing

Writing rules and finished examples for repository markdown and documentation HTML. Authors and reviewers use the same requirements for each kind of document.

## Features

- Supply a plain writing standard with examples.
- State the repository layout every repository converges on.
- Define the purpose and contents of each document type, and ship one finished example per type with a contrast drawn from a real failure.
- Guide a focused edit to existing text, and a rewrite that extracts first and then writes from a blank page.
- Link decision-record work to the decider skill.

## Install

```bash
kendex add vanillagreencom/kendex --skill docs-writing
```

kendex also installs decider, which supplies the decision-record format.

## How it works

The author identifies the document type and reads its rules and its example in [SKILL.md](SKILL.md). The author checks existing claims against the code. A focused change edits only the affected text; a rewrite extracts what is unique, then writes from a blank page. Installed markdown guards check formatting and references after the change.

## Setup

Add repository writing instructions in `kendex.toml` under `[skill-instructions]`. kendex includes them in the installed skill.

## Licence

MIT, in the repository's LICENSE file.
