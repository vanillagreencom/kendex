# Project Management

Planning workflows for teams that track work in Linear or GitHub. They turn backlog reviews, research and feature plans into proposed issue changes.

## Install

```bash
kendex add vanillagreencom/kendex --skill project-management
```

Requires Git and jq. kendex installs orch, linear and github. Sync the Linear cache before planning Linear work.

## Features

- Plan cycles and roadmaps.
- Audit issues against the repository and related work.
- Break research and feature plans into proposed issues.
- Request approval for issue creation and cancellation.

## How it works

You provide a planning question or select issues to audit. The main session assigns analysis to a planning agent. That agent returns proposed changes without changing the tracker. The main session applies metadata corrections and asks you to approve creations and cancellations.

## Settings

- Define the project's required labels in `kendex.toml` under `[skill-instructions]`, or in a project document linked from those instructions. [references/labels.md](references/labels.md) defines the label workflow.
- Set `LINEAR_REQUIRE_REACH` and `LINEAR_AGENT_LABELS` in `kendex.settings.toml` under `[env]` to check issue descriptions and routing labels during creation.
