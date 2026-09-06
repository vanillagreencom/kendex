# Docs Writing

Writing rules and templates for repository markdown. Authors and reviewers use the same requirements for each kind of document.

## Install

```bash
kendex add vanillagreencom/kendex --skill docs-writing
```

kendex also installs decider, which supplies the decision-record format.

## Features

- Supply a plain writing standard with examples.
- Define the purpose and contents of each document type.
- Provide templates for package, developer, agent and reference documents.
- Guide a rewrite from a blank page.
- Link decision-record work to the decider skill.

## How it works

The author identifies the document type and reads its rules in [SKILL.md](SKILL.md). The author checks existing claims against the code. The matching template provides the structure for the rewrite. Installed markdown guards check formatting and references after the rewrite.

## Settings

- Add repository writing instructions in `kendex.toml` under `[skill-instructions]`. kendex includes them in the installed skill.
- Set `DOC_LIMITS_CLASSES` in `kendex.settings.toml` under `[env]` when the project needs different file limits. [../doc-limits/README.md](../doc-limits/README.md) § Path classes defines the format.
