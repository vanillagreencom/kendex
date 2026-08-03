# vstack issue-label taxonomy

Linear team `vstack` (VST). GitHub `vanillagreencom/vstack` is the code and PR surface;
issues sync GitHub → Linear one-way, so a label applied at file time arrives in Linear
with the synced issue.

This is the project-side taxonomy the upstream
[label-management contract](../skills/project-management/references/labels.md) expects
projects to supply. Upstream defines the mechanism; this file defines the names.

## Area labels (exclusive — exactly one per issue)

Parent group `Area` on team VST; the same names exist as GitHub labels on the repo.
Each maps 1:1 to a Linear project, and a Linear triage rule routes the synced issue
into that project.

| Label | Project | Surface |
|-------|---------|---------|
| `area:cli` | CLI & Distribution | Rust CLI, `vstack.toml`/settings resolution, lockfile, propagation |
| `area:skills` | Skills & Agents Library | `skills/`, `agents/`, `skill-templates/`, base agent instructions |
| `area:harness` | Agent Harness Integrations | `pi-extensions/`, pi-claude-bridge, MCP allowlists, `hooks/`, harness adapters |
| `area:review-gate` | Review Gate & CI | review-gate engine, merge queue, reviewer CI, PR quality automation |
| `area:docs` | Docs & Onboarding | README, AGENTS.md, `docs/`, adoption guides |
| `area:tech-debt` | Tech Debt & Bugs | cross-cutting hygiene, flaky tests, defects with no single owning surface |

An area label is a **routing signal, not a classification**. Pair it with the existing
type labels (`bug`, `feature`, `chore`, `refactor`, `docs`, `test`, `security`) as usual.

## How the label gets applied

**`vstack report`** stamps exactly one on vstack-targeted issues. The surface is derived
from the asset selector — no selector means a CLI report, a `review-gate`-named asset
wins over its kind, hooks and pi-extensions are harness, skills and agents are skills —
and `--area <name>` overrides the derivation. Project-local reports never carry one:
these labels are defined on `vanillagreencom/vstack` only, so attaching one to a
consuming repo's issue would fail the `gh` call outright.

**Hand-filed issues** should carry one too. Anything unlabeled stays parked in Linear
Triage until a human or the TPM audit workflow routes it — which is the intended
fallback, not a failure.

## Adding a surface

Adding an area means four coordinated changes; a partial rollout silently drops issues
into Triage:

1. Create the Linear project.
2. Create the Linear label under the `Area` group on team VST.
3. Create the matching GitHub label on `vanillagreencom/vstack`.
4. Add the Linear triage rule mapping label → project.

Then extend `Area` in `cli/src/commands/report.rs` (variant, `label()`, `parse()`, and
the `derive()` arm) so `vstack report` can emit it, and update this table.

Triage rules are configured in the Linear UI — Team Settings → Triage. They are not
scriptable through the API or MCP surface, so step 4 is always a manual step.
