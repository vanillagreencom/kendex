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

Because `chore` and `docs` are also ordinary type labels, an issue routinely matches two
rules, so **rule order matters**. Linear runs triage rules top-down *cumulatively* — it
does not stop at the first match, and a later rule overwrites an earlier one on the same
property. So the **last** matching rule wins the project, and the rules must be ordered
generic first, specific last:

```
chore → docs → ci-infra → harness → skills → cli
```

A `cli` + `chore` issue then hits the chore rule (Tech Debt & Bugs) and is overwritten by
the cli rule, landing in CLI & Distribution. Reversing this order silently drains every
labelled issue into Tech Debt or Docs.

## How the label gets applied

**`vstack report`** stamps exactly one on vstack-targeted issues. The surface is derived
from the asset selector — a `review-gate`-named asset
wins over its kind, hooks and pi-extensions are harness, skills and agents are skills —
and `--area <name>` overrides the derivation. `--area` accepts either vocabulary
(`review-gate` or `ci-infra`).

Only reports filed to the canonical `vanillagreencom/vstack` carry one. Project-local
reports never do — these labels live on `vanillagreencom/vstack` and team VST, so
attaching one to a consuming repo's issue would fail the `gh` call outright — and the
same applies when `--upstream` redirects a vstack-owned report to a fork, which does
not inherit the canonical repo's labels.

**Hand-filed issues** should carry one too. Anything unlabeled stays parked in Linear
Triage until a human or the TPM audit workflow routes it — which is the intended
fallback, not a failure.

## Full label register

Every label live in the workspace or on team VST is either registered below with its
role for this repo, or listed under [Never-use for this repo](#never-use-for-this-repo).
There is no third state: a new live label that appears in neither place means this file
is stale and must be updated. Last verified against the live inventory
(`.agents/skills/linear/scripts/linear.sh cache labels list`, 42 labels): 2026-08-06.

The six routing labels above are part of this register. The rest:

### Type labels (workspace)

Classify what the work *is*; pair one with the routing label.

| Label | Role here |
|-------|-----------|
| `bug` | Defect in shipped behavior |
| `feature` | New capability or product behavior |
| `refactor` | Restructure/migration/cleanup, behavior mostly unchanged |
| `test` | Testing: coverage, harnesses, fixtures, flakes |
| `security` | Security-relevant surface or hardening work |
| `research` | Spike whose primary output is findings/decision support |

### Workflow and state labels (workspace)

| Label | Role here |
|-------|-----------|
| `blocked` | External blocker (vendor/access/manual dependency); internal deps use issue relations |
| `needs-research` | Blocked on unresolved research; prefer a blocking relation to a research issue |
| `needs-review` | Explicit review gate required before execution, merge, or close |
| `critical-path` | Blocks or enables major project progress; align priority |
| `owner-gated` | Needs an owner decision or owner-only action to proceed |

### Steward labels (team VST)

| Label | Role here |
|-------|-----------|
| `needs-ownership-check` | Possibly a project-local asset misfiled here; see `vstack report` |
| `ci-nightly` | Automated nightly CI failure requiring triage |
| `enhancement` | GitHub-sync twin of workspace `feature`: GitHub's stock `enhancement` label had no same-named workspace label, so the GH→Linear sync minted a team-scoped copy. It arrives on synced issues; never hand-apply it in Linear — use `feature` |

`enhancement` is the one sanctioned exception to the "never create a team-scoped twin
of a workspace label" rule, because the sync created it, not us.

### Agent ownership group (workspace, exclusive)

`Agent` is the workspace's only exclusive prefixed group: exactly one `agent:*` label
per issue, naming which agent role owns it.

| Label | Role here |
|-------|-----------|
| `agent:generalist` | Maintenance, docs, tooling/workflow, mixed low-risk work |
| `agent:rust` | Rust systems work — for vstack, the CLI codebase |
| `agent:researcher` | Research issues owned by the deep-research workflow |
| `agent:multi` | Bundle/coordination issue spanning two or more agent domains |
| `agent:human` | Manual/owner work, or work intentionally not delegated to an agent |

(`agent:iced` completes the group but has no vstack surface — see below.)

## Never-use for this repo

These workspace labels exist for other projects' surfaces and structurally cannot
apply to vstack. Never apply one to a vstack issue; if a synced issue arrives wearing
one, it is a routing smell — check whether the issue belongs to another repo.

| Label | Why it cannot apply |
|-------|---------------------|
| `Platform` group: `ios`, `macos`, `windows`, `linux`, `cross-platform` | Target-platform labels for shipped end-user products; vstack is agent tooling with no per-platform product surface |
| `frontend` | UI-surface work; vstack has no UI |
| `iced` | Iced app/storybook implementation; no Iced code here |
| `component` | Design-system component/widget work; no component library here |
| `design` | Design-system/UX/visual-language specification; no design surface here |
| `rust-core` | Trading-engine core architecture (IPC, market data, execution, risk); vstack's Rust surface is the CLI, which `cli` covers |
| `hardware-blocked` | Blocked on physical hardware or device access; vstack has no hardware dependencies |
| `baseline` | Benchmark fixture / golden-data / pre-optimization reference; no benchmark workflow here |
| `needs-perf-test` | Benchmark/profiling gate before acceptance; no performance-validation gate here |
| `needs-safety-audit` | Unsafe code, lock-free, memory/thread-safety validation; the CLI ships no unsafe or concurrency-critical code. If that ever changes, move this to the register |
| `agent:iced` | Agent-ownership label for Iced work, which vstack has none of |

## Adding a surface

Adding one means four coordinated changes; a partial rollout silently drops issues into
Triage:

1. Create the Linear project.
2. Create the Linear label — workspace-scoped if it would apply to any project, team VST
   otherwise — or confirm an existing workspace label already covers it.
3. Create the matching GitHub label on `vanillagreencom/vstack`, same name.
4. Add the Linear triage rule mapping label → project, positioned by specificity — a
   subsystem rule goes below the generic type-label rules so it wins the overwrite.

Then extend `Area` in `cli/src/commands/report.rs` (variant, `label()`, `parse()`, and the
`derive()` arm) so `vstack report` can emit it, and update this table.

Triage rules are configured in the Linear UI — Team Settings → Triage. They are not
scriptable through the API or the MCP surface, so step 4 is always manual.
