# vstack issue-label taxonomy

Linear team `vstack` (VST). GitHub `vanillagreencom/vstack` is the code and PR surface;
issues sync GitHub → Linear one-way, so a label applied at file time arrives in Linear
with the synced issue.

This is the project-side taxonomy the upstream
[label-management contract](../skills/project-management/references/labels.md) expects
projects to supply. Upstream defines the mechanism; this file defines the names.

## Convention

Labels are **flat bare words** — no prefix, no exclusive parent group. This matches the
rest of the workspace: memsira's `vault` / `claude-bridge` / `transcription` and
hyprtrade's `rust-core` / `iced` are all plain subsystem names. The only prefixed,
grouped labels in the workspace are `agent:*` under the exclusive `Agent` group, and
that exception exists because exactly one agent owns an issue.

Two scopes:

- **Workspace labels** — anything broadly applicable to any project (`bug`, `docs`,
  `ci-infra`, `chore`, `test`, `security`, `refactor`, `research`, …). Reuse these; never
  create a team-scoped twin of one.
- **Team labels on VST** — vstack's own subsystems, which mean nothing to another repo.

## Routing labels

Each maps 1:1 to a Linear project, and a Linear triage rule routes the synced issue
into that project.

| Label | Scope | Project | Surface |
|-------|-------|---------|---------|
| `cli` | team VST | CLI & Distribution | Rust CLI, `vstack.toml`/settings resolution, lockfile, propagation |
| `skills` | team VST | Skills & Agents Library | `skills/`, `agents/`, `skill-templates/`, base agent instructions |
| `harness` | team VST | Agent Harness Integrations | `pi-extensions/`, pi-claude-bridge, MCP allowlists, `hooks/`, harness adapters |
| `ci-infra` | workspace | Review Gate & CI | review-gate engine, merge queue, reviewer CI, PR quality automation |
| `docs` | workspace | Docs & Onboarding | README, AGENTS.md, `docs/`, adoption guides |
| `chore` | workspace | Tech Debt & Bugs | cross-cutting hygiene, flaky tests, defects with no single owning surface |

The three workspace labels are reused as-is. `ci-infra`'s existing description — "CI,
review gates, runners, and repo tooling" — already describes the Review Gate surface
exactly, so a vstack-specific `review-gate` label would have been a pointless twin.

A routing label is a **routing signal, not a classification**. Pair it with the type
labels (`bug`, `feature`, `refactor`, `test`, `security`) as usual.

Because `chore` and `docs` are also ordinary type labels, **rule order matters**: put the
three team subsystem rules first so a `cli` + `chore` issue lands in CLI & Distribution
rather than Tech Debt & Bugs. Triage rules run top to bottom.

## How the label gets applied

**`vstack report`** stamps exactly one on vstack-targeted issues. The surface is derived
from the asset selector — no selector means a CLI report, a `review-gate`-named asset
wins over its kind, hooks and pi-extensions are harness, skills and agents are skills —
and `--area <name>` overrides the derivation. `--area` accepts either vocabulary
(`review-gate` or `ci-infra`).

Project-local reports never carry one: these labels live on `vanillagreencom/vstack` and
team VST, so attaching one to a consuming repo's issue would fail the `gh` call outright.

**Hand-filed issues** should carry one too. Anything unlabeled stays parked in Linear
Triage until a human or the TPM audit workflow routes it — which is the intended
fallback, not a failure.

## Adding a surface

Adding one means four coordinated changes; a partial rollout silently drops issues into
Triage:

1. Create the Linear project.
2. Create the Linear label — workspace-scoped if it would apply to any project, team VST
   otherwise — or confirm an existing workspace label already covers it.
3. Create the matching GitHub label on `vanillagreencom/vstack`, same name.
4. Add the Linear triage rule mapping label → project, positioned correctly relative to
   the existing rules.

Then extend `Area` in `cli/src/commands/report.rs` (variant, `label()`, `parse()`, and the
`derive()` arm) so `vstack report` can emit it, and update this table.

Triage rules are configured in the Linear UI — Team Settings → Triage. They are not
scriptable through the API or the MCP surface, so step 4 is always manual.
