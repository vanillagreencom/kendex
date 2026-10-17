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

The reader refuses as `map-unreadable` a block of any other shape: a missing required field, an unknown `kind` or `role`, a standing project with `ends_when` or `initiative`, a deliverable with `role`, an initiative listing a project whose `initiative` does not name it, a deliverable whose `initiative` does not list it, and two names that compare equal (lowercase, every character but `a-z` and `0-9` dropped). Two renders that differ refuse the same way.

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
| A finding | An open item in a completed deliverable | A completed or canceled standing project, or one with a target date |

A standing project's `role` is one of:

- `area`: an owned subsystem with continuing work, such as Review Gate & CI. An item belongs to it when it changes the area's Location paths without advancing a deliverable. A defect in an area goes to that area; bug-ness is the `bug` label.
- `concern`: cross-cutting work with no single owning area, such as Tech Debt or Upkeep. An item belongs to it only when no single area owns it.

A project named for a label's value is a boundary finding, as "Tech Debt & Bugs" is against the `bug` label.

## Routing

Place every item by the first rule that admits it:

1. The deliverable whose `ends_when` the item advances.
2. The standing area that owns the item's Location paths.
3. The standing concern whose `admits` rule takes the item.
4. None: the item is `project_needed`.

No default project exists. Under a declared map, `linear.sh issues create` refuses a create with no `--project`, and `issues create`, `issues update --project` and `issues bulk-update --project` refuse a project the map does not list or Linear lacks, naming the map file and the legal projects. An issue already outside the map keeps its project until a write moves it; the audit lists it.

A `project_needed` item is held, not created. Its producer returns the project it needs: `name`, `kind`, `initiative`, `ends_when` for a deliverable or `role` for a standing project, and `reason`. Propose a deliverable only with a stated `ends_when`, and an area only when a subsystem has no owner; otherwise the item fits a concern or fails the creation bar. The overseer creates the project per [initiative-project-template](../templates/initiative-project-template.md) and adds it to the map; the held create then proceeds.

Routing outranks the rule that a parent and child share a project ([SKILL.md](../SKILL.md) § Hierarchy). When a child's route names another project than its parent's, move the parent first when the parent's route agrees, or hold the child as `project_needed`.

## Audit

```bash
.agents/skills/linear/scripts/linear.sh projects audit --team [TEAM]
```

It reads the team's open issues, the map projects, and the team and workspace labels, and prints `{team, map, projects, findings}`: `projects[]` lists each map project's `name`, `kind`, Linear `id` and `state`. A map project Linear lacks, or has twice live, refuses the audit. A non-zero exit is reported with its error output and never read as clean.

Each finding maps to one action. tpm-audit emits it; audit-issues § 7.1 applies a `wrong_project` whose `to` is a map project as its own-authority correction and reports the rest.

| `kind` | Fields | Action |
|---|---|---|
| `no-project` | `issue` | `wrong_project[]` with `from: null`, `to` from § Routing, or `project_needed[]` when nothing fits |
| `outside-map` | `issue`, `project` | `wrong_project[]` with `from: project`, routed the same way |
| `initiative-holds-issue` | `issue`, `initiative`, `project` | The same as `outside-map`: the item sits in a project named for an initiative |
| `completed-project-item` | `issue`, `project` | The same as `outside-map`: an open item in a completed deliverable |
| `name-collision` | `label`, `map: {level, name}`, `declared` | `map_findings[]`: a label whose name compares equal to a map project or initiative. `declared` is true when the taxonomy declares the label. The owner renames one side |
| `standing-closed` | `project`, `state` | `map_findings[]`: the owner reopens it or retires it from the map |
| `standing-target-date` | `project`, `target_date` | `map_findings[]`: the owner clears the date or makes the project a deliverable |
| `deliverable-no-ends-when` | `project` | `map_findings[]`: the owner states `ends_when` in the map |
| `map-absent` | `map` | `map_findings[]`: the repository declares no map |

The audit is team-wide. A `project` audit keeps the item findings whose `issue` is in its input set and the project findings naming its project; an `issues` audit keeps the item findings for its input issues and drops the rest. Every run keeps `map-absent`.
