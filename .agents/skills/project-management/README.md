# Project Management

Turns planning conversations into tracked work: cycle plans, backlog audits, roadmaps, and research-driven decomposition. For a project that wants its backlog small and true, with every creation and cancellation approved by a person.

## Install

```bash
kendex add vanillagreencom/kendex --skill project-management
```

Needs `git` and `jq`, the `linear` skill installed and synced, and `github` for GitHub-tracked audits. Give the project a label taxonomy: which label categories new issues require, which are exclusive, and the names, in `kendex.toml` `[skill-instructions]` or a project doc. [references/labels.md](references/labels.md) is the mechanism; your project supplies the names. A missing label stops the workflow and asks first.

## What it does

- `cycle-plan`: plan a cycle from the backlog.
- `audit-issues`: sweep a project, team or issue set for what the codebase already satisfied, duplicated or superseded, and for issues that fail the creation bar.
- `roadmap plan` and `roadmap create`: decompose a feature, research findings or a finished plan into issues.
- `research-spike` and `research-complete`: delegate standalone research and fold its findings back.

## How it works

Each command is a wrapper that runs in your main session. The wrapper asks you the product questions (what to build, what to cancel, what to activate) and performs every tracker mutation itself. It delegates the analysis to a one-shot TPM workflow that returns JSON and touches nothing. Metadata corrections (labels, priorities, relations, hierarchy, sort order, project moves) are applied without asking; creations and cancellations always go through an in-session approval gate.

Issue-level audits work with Linear or GitHub; project-level work (cycle planning, roadmaps, project audits) is Linear-only, since GitHub has no project, bundle or typed-relation model. What qualifies as an issue is the creation bar in [SKILL.md](SKILL.md) § Disposition.

## Customise

- The label taxonomy, above.
- `LINEAR_REQUIRE_REACH` and `LINEAR_AGENT_LABELS` in the `linear` skill make `issues create` enforce the creation bar's `Reached by:` line and the routing labels.
