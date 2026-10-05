# Project Management

Planning workflows for teams that track work in Linear or GitHub. They turn backlog reviews, research and feature plans into proposed issue changes.

## Install

```bash
kendex add vanillagreencom/kendex --skill project-management
```

Requires Git and jq. kendex installs orch, linear and github. Linear reads go to the live API.

## Features

- Plan cycles and roadmaps.
- Audit issues against the repository and related work.
- Break research and feature plans into proposed issues.
- Request approval for issue creation and cancellation.

## How it works

You provide a planning question or select issues to audit. The main session assigns analysis to a planning agent. That agent returns proposed changes without changing the tracker. The main session applies metadata corrections and follows your creation policy for creations and cancellations.

## Settings

- Set `PM_CREATE_AUTONOMY` in `kendex.settings.toml` under `[env]`: `ask`, the caller default, requests approval; `auto` executes the audit's accepted creations and cancellations and reports reasons for declined entries and cancellations. Under `ORCH_USER_MODE=ceo` an unset key composes to `auto`.
- Declare the project's label taxonomy as the `json` block under `### Project taxonomy` in the manifest's `[skill-instructions].project-management`. [references/labels.md § Project Taxonomy Contract](references/labels.md#project-taxonomy-contract) defines the block, and the rest of that file the label workflow.
- Set `LINEAR_REQUIRE_REACH` and `LINEAR_AGENT_LABELS` in `kendex.settings.toml` under `[env]` to check issue descriptions and routing labels during creation.
