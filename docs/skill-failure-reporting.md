# Skill-Failure Reporting: Routing and Attribution Rules

Every vstack-generated agent carries a short directive to report skill/asset
failures. This file is the single canonical copy of the full rules; vstack
installs and refreshes it at `.agents/skill-failure-reporting.md` (project
scope) or `~/.config/vstack/skill-failure-reporting.md` (global scope).

If there is a logic error, script failure, or provenly incorrect guidance,
report it to the orchestrating agent and user upon return.

## Ownership verification

Only ask the orchestrating agent to consider filing at
`github.com/vanillagreencom/vstack` when the failed asset is part of the VStack
distribution: a canonical VStack agent, skill, hook, or Pi extension, or a
skill whose `SKILL.md` frontmatter declares VStack ownership
(`metadata.source: vstack` or a `vanillagreencom/vstack` repository). Verify
that ownership in the asset's own file before filing — its location under
`.agents/skills/` is not proof, because projects install their own local skills
and `tools/` scripts there too.

## Non-VStack assets

For non-VStack assets (project-local skills without VStack frontmatter, project
`tools/` scripts, or harness/Codex `.system` skills), report the failure to the
orchestrator/user and use that asset's own upstream if known; do not route it
to the VStack repo.

## Invoked-tool attribution

When a VStack workflow step instructs running a repository-owned validator,
harness, or `tools/` command and THAT invocation fails, attribute the failure
to the failing implementation rather than to the workflow that invoked it: if
the failing implementation is proven repository-owned, route it to the owning
project's tracker, disclose to the orchestrator/user, and continue with scoped
evidence — file at VStack only when VStack's own guidance or template caused
the bad invocation (wrong command, wrong arguments, or a defective workflow
step) or ownership is genuinely uncertain.

## Before filing upstream

Before any upstream filing, search existing issues and comment on a match
instead of opening a duplicate; file only reproducible defects in
VStack-shipped assets (harness, runtime, or downstream-project limitations are
not VStack issues); and keep the report public-safe — no downstream project
names, internal issue IDs, or other project-private details.
