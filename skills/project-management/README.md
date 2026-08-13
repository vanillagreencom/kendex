# Project Management Skill

Turns planning conversations into tracked work: cycle plans, backlog audits, roadmaps, and research-driven decomposition. It exists to keep the backlog small and true — every audit is expected to close more issues than it opens, and an observation only becomes an issue when it changes what someone experiences and someone could finish it as-is.

## How it works

Each command is a **wrapper** that runs in your main session. The wrapper asks you the product questions (what to build, what to cancel, what to activate) and performs every tracker mutation itself. It delegates the analysis — reading the backlog, comparing scope against the codebase, computing dependency order — to a one-shot **TPM workflow** that returns JSON and touches nothing.

Metadata corrections (labels, priorities, relations, hierarchy, sort order, project moves) are applied without asking. Creations and cancellations always go through an in-session approval gate.

Issues live in Linear or in GitHub. Issue-level audits work with either — GitHub-tracked audits never need Linear installed. Project-level work (cycle planning, roadmaps, project audits) is Linear-only, since GitHub has no project, bundle, or typed-relation model.

## Setup

1. Install and authenticate the `linear` skill (and `github` for GitHub-tracked audits). `git` and `jq` must be on `PATH`.
2. Sync the Linear cache so issues, projects, relations, and labels are readable.
3. Give the project a **label taxonomy**: which label categories new issues require, which are exclusive, and the label names themselves. Put it in `vstack.toml` `[skill-instructions]` or a project doc. The upstream contract is [`references/labels.md`](references/labels.md); this file defines the mechanism, your project defines the names.

Labels are never created automatically — a missing label stops the workflow and asks you first.
