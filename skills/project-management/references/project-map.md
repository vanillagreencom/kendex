# Project Map Reference

Each Linear project states what it admits in its own content, and filing reads the team's projects from Linear at the moment it places an item, so a project created in Linear takes issues at once. `linear.sh projects audit` lists those projects and reports every item and project whose placement the lines do not hold. Labels stay the taxonomy's, [labels.md](labels.md).

A team's project map is its live projects as Linear holds them. A map project is one of them whose content opens with an `Admits:` line (§ Admission lines).

## Admission lines

A project's admission lines open its content, the long Markdown body `linear.sh projects create` and `projects update` take as `--content`, never its 255-character `description` summary. One line each, before any other text:

Windows Support, a deliverable:

```text
Admits: Work whose completion makes kendex install and run on Windows.
Kind: deliverable
Ends when: A release installs and runs kendex on Windows with copy-mode delivery, skill roots and hooks working.
```

Review Gate & CI, a standing area:

```text
Admits: Changes to CI workflows, the review gate and the merge rail.
Kind: standing
```

| Line | Required | Meaning |
|---|---|---|
| `Admits:` | yes | One sentence: which items belong in the project |
| `Kind:` | yes | `deliverable` or `standing` (§ Project kinds) |
| `Ends when:` | deliverable | One sentence: the observable condition, date or release that completes the project |

- Blank lines between the lines are allowed. The first other line ends them, and a line after it is not read.
- A repeated line keeps its first value. A `Kind:` other than `deliverable` or `standing` reads as absent.
- The project's initiative is its Linear initiative. No line names it.
- A new project takes them in the `--content` it is created with. An existing project takes them through `projects update [ID] --content`, with its existing content kept after them.

A project whose content holds no `Admits:` line admits nothing:

- Filing places no item in it, and names it in its report.
- The audit reports it as `no-admits`.
- It never stops a create into another project.

## Levels

- An **initiative** holds why: one strategic outcome that gives several projects a reason to exist.
  - It holds projects, never issues.
  - It is never a label.
- A **project** holds where the work lives: one deliverable with an end state, or one standing area with no end.
  - An issue is in exactly one project.
  - Anything that completes, or that an issue's completion contributes to, is a project, never a label.
- A **label** holds an attribute true of an issue in any project: who runs it (agent), where a person meets it (surface), stack, platform, classification, workflow flag.
  - A label never names a project or an initiative.
  - A label never stands in for one: a `ci-infra` item still belongs in the CI project.

## Boundary tests

- **Project or label:**
  1. Does it end? Then a deliverable project.
  2. Does it appear unchanged across projects? Then a label.
  3. Otherwise a standing project.
- **Label or initiative:** Does it explain why several projects exist? Then an initiative. A label never does.
- **Initiative or project:** Does an issue's completion advance it directly? Then a project. An initiative is reached only through its projects.

## Project kinds

Most projects are deliverables. Only work with no end is standing.

A `deliverable` project:

- Has an end state and an `Ends when:` line, and optionally a target date.
- Is named for the outcome it delivers ("Windows Support", "Package Settings").
- Is planned, then started when its first item starts.
- Is completed once its `Ends when:` holds and it has no open item left: each item is closed or moved to the standing project that owns it.
- Is canceled if abandoned. It may be paused.
- Admits an item when finishing the item advances its `Ends when:`.
- Makes each open item in it a finding when it is completed or canceled.

A `standing` project:

- Has no end, no `Ends when:` line and no target date.
- Is named for the area or concern it owns ("Skills & Agents Library", "Tech Debt"), with no date, version, phase or label value in the name.
- Stays started for as long as the area exists. Retirement is an owner decision that moves its open items first.
- Admits an item when its `Admits:` sentence names the item's work.
- Is a finding when it has a target date.

A standing project owns one of:

- An area: an owned subsystem with continuing work, such as Review Gate & CI.
  - An item belongs to it when it changes the area's Location paths without advancing a deliverable.
  - A defect in an area goes to that area. Bug-ness is the `bug` label.
- A concern: cross-cutting work with no single owning area, such as Tech Debt or Upkeep.
  - An item belongs to it only when no single area owns it.

No line names which one: a standing project's `Admits:` sentence states it. An area's sentence names the Location paths it owns, and a concern's says that no single area owns the work. Read a standing project's role from that sentence.

An open item of a project is every issue in it whose state type is not one of the closed types `completed`, `canceled` and `duplicate`: Triage, Verifying, In Review, blocked, research and `agent:human` issues included.

- One read finds them: `issues list --project-id [PROJECT_ID] --max --format=compact`, by the project's recorded Linear id, keeping each row whose `state_type` is not a closed type.
- A started project with no issue at all is not complete: it has no open item left only when the read returns at least one row and every row has a closed type.
- A read by `--project` matches by name, so a canceled project or another team's project with the same name adds its rows.
- A read by a list of state names misses each state it leaves out, Verifying among them.
- A planning list that leaves out blocked, research or In Review issues is no such read either.

A step that decides whether a project with no open item left completes (tpm-audit § 11 step 5, tpm-cycle-plan § 1):

- Reads the team's projects first, as tpm-audit § 1.6 does, and decides from that read.
- Never completes a standing project.
- Completes a deliverable only on stated evidence that its `ends_when` holds. Without that evidence the deliverable stays started and the step reports it.
- Completes a project whose `kind` is null once it has no open item left.

The steps that run the completion, audit-issues § 2.3 and cycle-plan § 2, follow that decision and read no project list.

The active project is the started project whose work is current: the one a step plans or audits when none is named, and the one that holds every other project from activation.

- A standing project never counts as active. It stays started beside the active project.
- A started deliverable counts, a held-open one included, and so does a started project whose `kind` is null.
- tpm-audit § 11 step 5 and tpm-cycle-plan § 1 make the activation decision, each returning the project that holds activation as `blocked_by_active`.
- audit-issues § 2.3 and cycle-plan § 2 follow it, read no project list, and activate nothing while it is set.
- audit-issues § 3 activates only when no started project counts as active.
- A step that picks the active project from a list of started projects (tpm-cycle-plan § 1, audit-issues § 3) reads the team's projects first, as tpm-audit § 1.6 does, and skips each standing project.

`projects audit` reports a label value in a project name only as a `name-collision`: the label and the whole project name compare equal once each is lowercased with every character but `a-z` and `0-9` dropped, as `tech-debt` does against "Tech Debt".

The owner judges a partial match, such as "Tech Debt & Bugs" against the `bug` label, when naming the project.

## Routing

Filing places an item from the team's live projects as Linear holds them at that moment: the `projects[]` of the § Audit command, each with the `kind`, `admits` and `ends_when` its admission lines give. A team that serves several repositories gives each of them this one list.

Place an item with no parent by the first rule that admits it; a child follows its parent, below:

1. The deliverable whose `ends_when` the item advances.
2. The standing project whose `admits` sentence names the work at the item's Location: an area before a concern.
3. No fit: § No fit.

- Judge the item's Location against each project's `admits` sentence in that order, using the project list the route already read.
- The sentence must name the work at that Location. A project name, label or current assignment alone does not establish a fit.
- A project whose `admits` is null admits nothing: place no item in it, and name it in the report.

### No fit

When no `admits` sentence names the item's work:

- One design that produces several issues is proposed as its own project. The item is `project_needed`: held, not created.
- A single small issue goes to the nearest standing project, the one whose `admits` sentence names the work closest to the item's Location. Its `reason` says that no sentence names the Location and which project is nearest.
- With no standing project that admits anything, the item is `project_needed`.

Examples, against the two projects § Admission lines shows:

- A single filing ([tpm-audit § 14](../workflows/tpm-audit.md#14-single-item-mode) step 3) with Location `.github/workflows/ci.yml` returns `project.recommended: "Review Gate & CI"` and a `reason` that quotes the sentence: `Review Gate & CI admits "Changes to CI workflows, the review gate and the merge rail."; .github/workflows/ci.yml is a CI workflow.`
- A filing with Location `docs/legal/terms.md` matches no `admits` sentence. As a single small issue it goes to the nearest standing project, with a `reason` that says so.
- A research decomposition that files a design of several issues for a new installer channel, which no sentence names, has `project.recommended: null` and a `project_needed[]` row for the project it needs. The creates are held.

The linear CLI checks no project's admission lines. `--project` takes a project UUID as given, or a name, which resolves to the one project of that name in the issue's team that takes issues (every state but `completed` and `canceled`); a name matching none or several refuses. This section is the placement rule, and filing holds it: a write passes the chosen project's `id` from `projects[]`.

A `project_needed` item is held, not created.

- Its producer returns the project it needs: `name`, `kind`, `initiative`, `ends_when` for a deliverable, `admits` and `reason`.
- Propose a deliverable only with a stated `ends_when`.
- Propose a standing project only when an area has no owner.
- The overseer creates the project in Linear per [initiative-project-template](../templates/initiative-project-template.md), its content opening with the proposed admission lines. The held create then proceeds.

A child takes its parent's project ([dependencies.md](dependencies.md) § Parent-Child Placement): the parent is routed, and its children follow it.

- Related items that are not the parts of one deliverable are grouped by this route, or by one label where no project says what they share, never under a parent ([filing.md](filing.md) § Group by project or label, never by parent).
- A parent in no project, or in one that does not admit it, moves to its own route before its child is created there.
- research-complete § 6.4 makes that move for the `hierarchy_contract` parent before it builds the audit input, and holds the whole contract when the parent's route is `project_needed`.
- A parent no step moves keeps its project, and its child takes audit-issues § 7.2's standalone fallback: created in its own route, with `related` to the parent.

## Audit

```bash
.agents/skills/linear/scripts/linear.sh projects audit --team "[TEAM]"
```

It reads the team's open issues, the team's projects with their content, the workspace's initiatives, and the team and workspace labels, and prints `{team, projects, findings}`.

- `projects[]` lists each live project of the team, every state but `completed` and `canceled`, with its `name`, Linear `id`, `state`, and the `kind`, `admits` and `ends_when` of its admission lines, each null where its line is absent.
- A team or issue audit reads those open issues from its run's inventory ([tpm-audit § 1.6](../workflows/tpm-audit.md#16-extract-project-definitions)). The project, initiative and label reads stay live.
- Report a non-zero exit with its error output. Never read it as clean.
- A step that has no team of its own (tpm-cycle-plan § 1, audit-issues § 3, research-spike § 3) runs it without `--team`, so the team is `LINEAR_TEAM`. With that unset the command refuses `no-team`, and the refusal stops the step.

Each finding maps to one action.

- tpm-audit § 3 maps every finding its mode keeps.
- audit-issues § 7.1 applies a `wrong_project` whose `to` is a map project as its own-authority correction, and reports the rest.

| `kind` | Fields | Output |
|---|---|---|
| `no-project` | `issue` | `wrong_project[]` with `from: null` |
| `unadmitted` | `issue`, `project` | `wrong_project[]` with `from: project` |
| `initiative-holds-issue` | `issue`, `initiative`, `project` | The same as `unadmitted` |
| `closed-project-item` | `issue`, `project`, `state` | The same as `unadmitted` |
| `name-collision` | `label`, `entry: {level, name}`, `declared` | `project_findings[]` |
| `no-admits` | `project` | `project_findings[]` |
| `no-kind` | `project` | `project_findings[]` |
| `standing-target-date` | `project`, `target_date` | `project_findings[]` |
| `deliverable-no-ends-when` | `project` | `project_findings[]` |

What each kind means, and its action:

- `no-project`: its `to` comes from § Routing. When the route is `project_needed`, it is a `project_needed[]` entry instead.
- `unadmitted`: an open item in a live project whose content holds no `Admits:` line, or in a project the team's list does not hold. Routed the same way as `no-project`.
- `initiative-holds-issue`: the item sits in a project named for a Linear initiative.
- `closed-project-item`: an open item in a completed or canceled project.
- `name-collision`: a label whose name compares equal to a live project or an initiative.
  - `declared` is true when the taxonomy declares the label.
  - The owner renames one side.
- `no-admits`: the project's content holds no `Admits:` line, so it admits nothing. The owner writes the line.
- `no-kind`: the project's content holds no readable `Kind:` line. The owner writes it.
- `standing-target-date`: the owner clears the date or makes the project a deliverable.
- `deliverable-no-ends-when`: the owner writes the project's `Ends when:` line.

The audit is team-wide, and it reads every open item of the team, Triage included, by the closed types of § Project kinds. Which findings a run keeps:

- A finding that carries `issue` is kept only when that issue is in the run's input set (tpm-audit § Inputs).
- Of the findings without `issue`, a `team` audit keeps every one.
- A `project` audit keeps those whose `project` or `entry.name` is its project.
- An `issues` or `single` audit runs no tpm-audit § 3 and keeps no finding, as its output has no `project_findings[]`. tpm-audit § 6.3 or § 14 places each input item by § Routing.
