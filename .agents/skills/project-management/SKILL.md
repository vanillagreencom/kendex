---
name: project-management
description: "Load to plan a cycle, audit issues, build a roadmap, or decompose research into issues."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

### Intake

File a kendex issue only when its body names one of these two, in addition to the Creation bar in `references/filing.md`:

- **A failure that happened**: a `**Symptom**:` header that names where it broke, when, and what broke.
- **An owner request**: an `**Owner**:` header, placed right after `**Reached by**:`, that names the owner's note or ask. That `**Reached by**:` line names the same ask, as `references/filing.md` § Name what reaches it says of an owner-directed item.

For kendex, `templates/issue-description-template.md` keeps the `**Symptom**:` header at every priority and from every source where a failure happened. Its rule that drops the line outside a review-born priority-2 filing does not apply here.

Intake decides only whether new work is filed. A create that groups or splits work already filed or already approved is never skipped or declined under Intake: a coordination parent per `templates/parent-issue-template.md` Rule 7, a tpm-audit § 7.0 hierarchy-contract child, a decomposed child, a research issue or spike for an existing item, or a roadmap child of an approved plan. Such a create carries its source item's `**Symptom**:` or `**Owner**:` line when the source has one. A child of an approved plan names, on its `**Owner**:` line, the approval that admitted the plan: the roadmap-plan § 5 answer or the audit-issues § 6 approval. Otherwise it needs neither line.

audit-issues applies Intake to every kendex create it executes, whatever producer built its input and whatever `create_fields` that producer filled:

- § 6, in `ask` and `auto` mode alike, shows each new-work candidate with the Symptom or Owner text it rests on: a line in its proposal comment, its source item or its `create_fields`, or the owner's ask in this session. It declines a candidate with neither, naming this rule.
- § 7.2 writes each new-work create's `**Symptom**:` or `**Owner**:` header from the text § 6 showed for it, and writes no header that text lacks. A create that Intake exempts carries only the line the paragraph above gives it, or neither.

No producer marks a candidate `skip` under this rule. A create the primary session runs outside audit-issues applies the same check and headers at its own create.

An organization setup request, one that names a host, account, repository or person of this organization, is not filed as asked. Restate it as a need any catalog consumer has. Otherwise return it to its sender with its destination named: the overseer, or the repository or Linear team that owns this organization's setup.

`issues create` checks neither line, apart from its review-born priority-2 `Symptom:` refusal. The author applies this rule.

### Project taxonomy

Require one agent and one surface label. Surface means where a person meets the work. Agent names are declared by LINEAR_AGENT_LABELS in kendex.settings.toml. Labels outside these categories are not assigned.

Scope: `cli`, `harness` and `skills` belong to team `kendex`. All agent labels are excluded from team scope. All other labels in this taxonomy have workspace scope. `1.0` identifies kendex’s release set and requires team scope in a separately approved migration.

Brad Mahaffey owns shared label names and scope. Follow the Linear skill’s Shared label maintenance procedure for definition changes.

```json
{
  "required_categories_for_new_issues": ["agent", "surface"],
  "categories": {
    "agent": {"required": true, "exclusive": true, "match": {"prefix": "agent:"}, "forbid_group_labels": true},
    "surface": {"required": true, "exclusive": true, "labels": ["app", "cli", "skills", "harness", "ci-infra", "documentation", "releases"]},
    "stack": {"required": false, "exclusive": false, "labels": ["rust-core", "iced", "test", "security"]},
    "platform": {"required": false, "exclusive": true, "labels": ["macos", "windows", "linux"]},
    "classification": {"required": false, "exclusive": false, "labels": ["bug", "feature", "refactor", "design", "chore", "owner-gated", "1.0"]},
    "workflow": {"required": false, "exclusive": false, "labels": ["research", "needs-research", "baseline", "blocked", "jarvis-check"]}
  }
}
```

### Project map

Every kendex issue lives in one project below; the project-management skill's `references/project-map.md` states what each kind holds and the routing order. A create names one of these projects, or holds the item as `project_needed`.

```json
{
  "initiatives": [
    {"name": "Self-Service App", "outcome": "A user keeps kendex current, signed in and configured from the desktop app alone, with no file edits and no terminal.", "projects": ["Package Settings", "Update Notice & Account"]}
  ],
  "projects": [
    {"name": "Package Settings", "kind": "deliverable", "initiative": "Self-Service App", "ends_when": "A release ships the one documented package settings contract and package settings editing in the Customize UI.", "admits": "Work on the package settings contract: its resolvers, authoring template, template check and Customize UI editing."},
    {"name": "Update Notice & Account", "kind": "deliverable", "initiative": "Self-Service App", "ends_when": "A signed release ships the update notice on every install channel and the account surfaces this project keeps.", "admits": "Work on the app's update notice, self-update and account surfaces."},
    {"name": "Windows Support", "kind": "deliverable", "ends_when": "A release installs and runs kendex on Windows with copy-mode delivery, skill roots and hooks working.", "admits": "Work whose completion makes kendex install and run on Windows."},
    {"name": "t3code", "kind": "deliverable", "ends_when": "The orch overseer runs on the T3 Code host with its delivery position, state reader and release contract test.", "admits": "T3 Code overseer runtime work."},
    {"name": "Review Gate & CI", "kind": "standing", "role": "area", "admits": "CI workflows under .github/, CI setup in .fleet-setup and tools/lane-setup, and the skills and tools that run the review gate, the merge rail, the merge queue and CI validation."},
    {"name": "Agent Harness Integrations", "kind": "standing", "role": "area", "admits": "pi-extensions/, hooks/ and the per-harness adapters under crates/core/src/harness."},
    {"name": "CLI & Distribution", "kind": "standing", "role": "area", "admits": "The kendex CLI and engine under crates/ outside crates/app and crates/core/src/harness: manifest, lock, settings, apply, refresh, verify and install."},
    {"name": "Desktop App", "kind": "standing", "role": "area", "admits": "Work on the app's code and screens under crates/app and ui/ that advances no deliverable."},
    {"name": "Docs", "kind": "standing", "role": "area", "admits": "The root README.md and AGENTS.md, and docs/; a README or AGENTS.md under another area's path goes to that area."},
    {"name": "Website", "kind": "standing", "role": "area", "admits": "The kendex website's pages and code in the kendex-web repository."},
    {"name": "Skills & Agents Library", "kind": "standing", "role": "area", "admits": "Catalog skills and agents under skills/ and agents/ that no other area's rule names."},
    {"name": "Tech Debt", "kind": "standing", "role": "concern", "admits": "Cleanup of past shortcuts and pre-existing defects no single area owns; an item that also fits Upkeep goes here."},
    {"name": "Upkeep", "kind": "standing", "role": "concern", "admits": "Recurring maintenance no single area owns: dependency and toolchain updates that span areas, renewals, rotations, refresh adoption and scheduled housekeeping. A change confined to one area's paths goes to that area."}
  ]
}
```
<!-- kendex:project-instructions:end -->

# Project Management

This skill plans tracker work: cycles, issue audits, roadmaps and research decomposition. An agent that loads it has one of two roles:

- **Primary session.** It runs a wrapper command from § Commands. A wrapper owns the user dialog and every tracker write.
- **Analysis agent.** The `tpm` agent running a TPM workflow, or the [proposal sweep](workflows/proposal-sweep.md) subagent the overseer launches. It returns JSON inline: a TPM workflow to its wrapper, the sweep to the overseer.

## Goals

These goals decide a case that no workflow step covers:

1. The tracker holds only items that pass the creation bar, and containers that group the parts of one deliverable.
2. A lane can pick up, land and prove each item alone.
3. The user decides what work exists, once per decision. The workflow decides the mechanics.

## Disposition

The rules for an item are in [references/filing.md](references/filing.md). Read that file before you judge, write, split or file a tracked item, and at a launch read.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | none | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `team` \| `issue [IDs]` \| `--issues [file]` \| `--single [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | none | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | none | [research-issue](workflows/research-issue.md) |
| `proposal-sweep` | fleet brief | [proposal-sweep](workflows/proposal-sweep.md) |

- `research-issue` is internal: `research-spike` invokes it.
- `proposal-sweep` is internal: `oversee` invokes it.

## Execution Rules

- Run the sections of a workflow in order.
- Skip a section only on its explicit **Skip if** condition, never on your own judgement of scope.
- `<delegation_format>` and `<output_format>` are literal templates:
  - Fill each `[PLACEHOLDER]`.
  - Remove the lines whose placeholders are empty.
  - Add nothing.
- For a user-visible `<output_format>` report:
  1. Send the report as a normal assistant message first.
  2. Then invoke the question tool separately, with only the question and short option labels.
  3. Never paste the report into the question or its options.
- A failed Linear read halts the workflow with its diagnostic, never a partial result.

## Read when

- When a run writes, cites, hands over or cannot find a plan, research, roadmap or audit file: [references/planning-artifacts.md](references/planning-artifacts.md).
- Before you add or change a mode, a tracker read or a tracker route in a workflow of this package, and when a step resolves or checks the team scope: [references/tracker-reads.md](references/tracker-reads.md).
- When you decide what an initiative, a project or a label holds, which project kind applies, or which project an item goes in: [references/project-map.md](references/project-map.md).
