# Project Map Reference

A repository declares which projects its issues live in, what each project admits, and the initiatives above them. The linear CLI refuses an issue write that places an issue outside the map, and `linear.sh projects audit` reports every item and project the map does not hold. Labels stay the taxonomy's, [labels.md](labels.md).

## Declaration

Declare the map in the project's kendex manifest (`kendex.toml`, or `kendex-local.toml` in a source-catalog checkout) under `[skill-instructions].project-management`, as a fenced `json` block under a `### Project map` heading, after the `### Project taxonomy` block. kendex renders it into this skill's SKILL.md. The linear CLI reads it from the same renders, with the same reader, as the taxonomy ([labels.md § Project Taxonomy Contract](labels.md#project-taxonomy-contract)).

```json
{"initiatives": [
   {"name": "Cross-Platform Desktop", "outcome": "The app installs, runs and updates on every desktop OS its users have.", "projects": ["Windows Support"]}],
 "projects": [
   {"name": "Windows Support", "kind": "deliverable", "initiative": "Cross-Platform Desktop",
    "ends_when": "A release ships a signed Windows installer that passes the install smoke test.",
    "admits": "Work whose completion moves the Windows installer toward that release."},
   {"name": "Review Gate & CI", "kind": "standing", "role": "area", "admits": "Changes to CI workflows, the review gate and the merge rail."},
   {"name": "Tech Debt", "kind": "standing", "role": "concern", "admits": "Cross-cutting cleanup no single area owns."}]}
```

| Field | Required | Meaning |
|---|---|---|
| `projects[]` | yes, one or more | The projects an issue may be placed in |
| `projects[].name` | yes | The exact Linear project name. The map lists a project only once it exists in Linear |
| `projects[].kind` | yes | `deliverable` or `standing` (§ Project kinds) |
| `projects[].admits` | yes | One sentence: which items belong in the project |
| `projects[].ends_when` | deliverable | One observable condition, a date or a release that completes the project. The reader accepts its absence; the audit reports it |
| `projects[].initiative` | deliverable, optional | The initiative the deliverable serves |
| `projects[].role` | standing | `area` or `concern` |
| `initiatives[]` | no | `name`, `outcome` (one sentence) and `projects[]`, the deliverables it holds |

The reader refuses as `map-unreadable` a block with any of these shapes: a missing required field, an unknown `kind` or `role`, a standing project with `ends_when` or `initiative`, a deliverable with `role`, an initiative listing a project whose `initiative` does not name it, a deliverable whose `initiative` does not list it, and two names that compare equal (lowercase, every character but `a-z` and `0-9` dropped). Two renders that differ refuse the same way. The reader ignores a key the field table does not name, so a misspelt `ends_when` reads as absent and the audit reports `deliverable-no-ends-when`.

With no `### Project map` heading the repository declares no map: the CLI enforces nothing, and `projects audit` reports one `map-absent` finding.

## Levels

- An **initiative** holds why: one strategic outcome that gives several projects a reason to exist. It holds projects, never issues, and is never a label.
- A **project** holds where the work lives: one deliverable with an end state, or one standing area with no end. An issue is in exactly one project. Anything that completes, or that an issue's completion contributes to, is a project, never a label.
- A **label** holds an attribute true of an issue in any project: who runs it (agent), where a person meets it (surface), stack, platform, classification, workflow flag. A label never names a project or an initiative and never stands in for one: a `ci-infra` item still belongs in the CI project.

## Boundary tests

| Pair | Test |
|---|---|
| Project or label | Does it end? Then a deliverable project. Does it appear unchanged across projects? Then a label. Otherwise a standing project |
| Label or initiative | Does it explain why several projects exist? Then an initiative; a label never does |
| Initiative or project | Does an issue's completion advance it directly? Then a project; an initiative is reached only through its projects |

## Project kinds

Most projects are deliverables. Only work with no end is standing.

| | `deliverable` | `standing` |
|---|---|---|
| Has | An end state, `ends_when`, and optionally a target date | No end, no `ends_when`, no target date |
| Named for | The outcome it delivers ("Windows Support", "Package Settings") | The area or concern it owns, with no date, version, phase or label value in the name ("Skills & Agents Library", "Tech Debt") |
| States | planned, then started when its first item starts, then completed once `ends_when` holds and every remaining item is done, canceled or moved to the standing project that owns it. Canceled if abandoned. Paused allowed | started for as long as the area exists. Retirement is an owner decision that moves its open items first |
| An item belongs when | Finishing it advances `ends_when` | It fits the `role` below |
| A finding | A canceled deliverable the map still lists, and an open item in a completed or canceled deliverable | A completed or canceled standing project, or one with a target date |

A step that decides whether a project with no open item left completes (tpm-audit § 11 step 5, tpm-cycle-plan § 1) reads the map first, as tpm-audit § 1.6 does. It never completes a standing map project. It completes a map deliverable only on stated evidence that its `ends_when` holds; without that evidence the deliverable stays started and the step reports it. A project off the map, and every project under `map-absent`, completes once it has no open item left. The steps that run the completion, audit-issues § 2.3 and cycle-plan § 2, follow that decision and read no map.

The active project is the started project whose work is current: the one a step plans or audits when none is named, and the one that holds every other project from activation. A standing map project never counts as active; it stays started beside the active project. A started map deliverable counts, a held-open one included, and so does a started project off the map; under `map-absent` every started project counts. tpm-audit § 11 step 5 makes the activation decision, and audit-issues § 2.3 follows it and reads no map. A step that picks the active project from a list of started projects (tpm-cycle-plan § 1, audit-issues § 3) reads the map first, as tpm-audit § 1.6 does, and skips each standing map project.

A standing project's `role` is one of:

- `area`: an owned subsystem with continuing work, such as Review Gate & CI. An item belongs to it when it changes the area's Location paths without advancing a deliverable. A defect in an area goes to that area; bug-ness is the `bug` label.
- `concern`: cross-cutting work with no single owning area, such as Tech Debt or Upkeep. An item belongs to it only when no single area owns it.

`projects audit` reports a label value in a project name only as a `name-collision`: the label and the whole project name compare equal under the § Declaration name key, as `tech-debt` does against "Tech Debt". The owner judges a partial match, such as "Tech Debt & Bugs" against the `bug` label, when editing the map.

## Routing

Place an item with no parent by the first rule that admits it; a child follows its parent, below:

1. The deliverable whose `ends_when` the item advances.
2. The standing area that owns the item's Location paths.
3. The standing concern whose `admits` rule takes the item.
4. None: the item is `project_needed`.

No default project exists. Under a declared map, `linear.sh issues create` refuses a create with no `--project`, naming the map file and the legal projects. `issues create`, `issues update --project` and `issues bulk-update --project` refuse a project the map does not list, naming the map file and the legal projects, and a map project with no single live Linear project in the issue's team, naming the map file and that project. A project Linear holds only as canceled counts as none. An issue already outside the map keeps its project until a write moves it; the audit lists it.

A `project_needed` item is held, not created. Its producer returns the project it needs: `name`, `kind`, `initiative`, `ends_when` for a deliverable or `role` for a standing project, and `reason`. Propose a deliverable only with a stated `ends_when`, and an area only when a subsystem has no owner; otherwise the item fits a concern or fails the creation bar. The overseer creates the project per [initiative-project-template](../templates/initiative-project-template.md) and adds it to the map; the held create then proceeds.

A child takes its parent's project ([SKILL.md](../SKILL.md) § Hierarchy): the parent is routed, and its children follow it. A parent outside the map moves to its own route before its child is created there. research-complete § 6.4 makes that move for the `hierarchy_contract` parent before it builds the audit input, and holds the whole contract when the parent's route is `project_needed`. A parent no step moves keeps its project, and its child takes audit-issues § 7.2's standalone fallback: created in its own route, with `related` to the parent.

## Audit

```bash
.agents/skills/linear/scripts/linear.sh projects audit --team [TEAM]
```

It reads the team's open issues, the map projects, and the team and workspace labels, and prints `{team, map, projects, findings}`: `projects[]` lists each map project's `name`, `kind`, Linear `id` and `state`. A map project with no Linear project in the team, or with two live ones, refuses the audit, as it refuses a write. A map project Linear holds only as canceled, which a write also refuses, is a finding instead: `deliverable-canceled` or `standing-closed`, with each open item in it a `closed-project-item`. A non-zero exit is reported with its error output and never read as clean.

Each finding maps to one action. tpm-audit § 3 maps every finding its mode keeps, map or no map; audit-issues § 7.1 applies a `wrong_project` whose `to` is a map project as its own-authority correction and reports the rest.

| `kind` | Fields | Action |
|---|---|---|
| `no-project` | `issue` | `wrong_project[]` with `from: null`, `to` from § Routing, or `project_needed[]` when nothing fits |
| `outside-map` | `issue`, `project` | `wrong_project[]` with `from: project`, routed the same way |
| `initiative-holds-issue` | `issue`, `initiative`, `project` | The same as `outside-map`: the item sits in a project named for an initiative |
| `closed-project-item` | `issue`, `project`, `state` | The same as `outside-map`: an open item in a completed or canceled map project |
| `name-collision` | `label`, `map: {level, name}`, `declared` | `map_findings[]`: a label whose name compares equal to a map project or initiative. `declared` is true when the taxonomy declares the label. The owner renames one side |
| `standing-closed` | `project`, `state` | `map_findings[]`: the owner reopens it or retires it from the map |
| `standing-target-date` | `project`, `target_date` | `map_findings[]`: the owner clears the date or makes the project a deliverable |
| `deliverable-canceled` | `project` | `map_findings[]`: the owner reopens it or removes it from the map |
| `deliverable-no-ends-when` | `project` | `map_findings[]`: the owner states `ends_when` in the map |
| `map-absent` | `map` | `map_findings[]`: the repository declares no map |

The audit is team-wide, and it reads every issue whose state is not completed or canceled, Triage and Duplicate included. A finding that carries `issue` is kept only when that issue is in the run's input set (tpm-audit § Inputs). Of the findings without `issue`, a `team` audit keeps every one, and a `project` audit keeps `map-absent` and those whose `project` or `map.name` is its project. An `issues` or `single` audit runs no tpm-audit § 3 and keeps no finding, as its output has no `map_findings[]`: in a map repository, tpm-audit § 6.3 or § 14 places each input item by § Routing.
