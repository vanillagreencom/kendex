# Reviewer

Review workflows and finding formats for AI review agents. Projects using orch can collect specialist reviews in a shared format.

## Install

```bash
kendex add vanillagreencom/kendex --skill reviewer
```

kendex also installs orch, code-quality and docs-writing. Add linear for Linear review work.

## Features

- Review a change or audit existing code.
- Run additional review work selected by QA labels.
- Record verified findings with their causes and effects.
- Return a structured report to the primary agent.

## How it works

The primary agent assigns a review to a specialist. The specialist reads the change and verifies possible defects against the code. It writes findings using [schemas/review-finding.md](schemas/review-finding.md). The primary agent reads that report and routes required fixes.

## Settings

Set project review instructions in `kendex.toml` under `[skill-instructions]`. Add instructions for a review agent under `[agent-additional-instructions]` in the same file.
