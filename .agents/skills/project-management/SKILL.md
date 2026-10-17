---
name: project-management
description: "Load to plan a cycle, audit issues, build a roadmap, or decompose research into issues."
summary: "TPM planning, audit, roadmap, and research-driven decomposition: the cycle-plan, audit-issues, roadmap and research wrappers and the TPM workflows under them."
license: MIT
user-invocable: true
dependencies:
  required: [orch, linear, github]
  optional: [decider, second-opinion]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [planning]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

### Intake

File a kendex issue only when its body names one of these two, in addition to the Creation bar in § Disposition:

- **A failure that happened**: a `**Symptom**:` header that names where it broke, when, and what broke.
- **An owner request**: an `**Owner**:` header, placed right after `**Reached by**:`, that names the owner's note or ask. That `**Reached by**:` line names the same ask, as § Disposition says of an owner-directed item.

For kendex, `templates/issue-description-template.md` keeps the `**Symptom**:` header at every priority and from every source where a failure happened. Its rule that drops the line outside a review-born priority-2 filing does not apply here.

Intake decides only whether new work is filed. A create that groups or splits work already filed or already approved is never skipped or declined under Intake: a coordination parent per `templates/parent-issue-template.md` Rule 7, a tpm-audit § 7.0 hierarchy-contract child, a decomposed child, a research issue or spike for an existing item, or a roadmap child of an approved plan. Such a create carries its source item's `**Symptom**:` or `**Owner**:` line when the source has one. A child of an approved plan names, on its `**Owner**:` line, the approval that admitted the plan: the roadmap-plan § 5 answer or the audit-issues § 6 approval. Otherwise it needs neither line.

audit-issues applies Intake to every kendex create it executes, whatever producer built its input and whatever `create_fields` that producer filled:

- § 6, in `ask` and `auto` mode alike, shows each new-work candidate with the Symptom or Owner text it rests on: a line in its proposal comment, its source item or its `create_fields`, or the owner's ask in this session. It declines a candidate with neither, naming this rule.
- § 7.2 writes each new-work create's `**Symptom**:` or `**Owner**:` header from the text § 6 showed for it, and writes no header that text lacks. A create that Intake exempts carries only the line the paragraph above gives it, or neither.

No producer marks a candidate `skip` under this rule. A create the primary session runs outside audit-issues applies the same check and headers at its own create.

The 2026-10-08 backlog read canceled these four kinds, each filed with neither line:

- A post-merge reading's remainder filed as a new item (KEN-3369, KEN-3371, KEN-3375). The reading stays on its originating item, per § Disposition.
- A plan follow-up that proposes a migration with no failing action (KEN-2360, KEN-2361, KEN-2362).
- An audit item that reclassifies a correct refusal (KEN-2378, KEN-2397).
- A scanner or grammar extension with no live failure (KEN-2207, KEN-3285).

An organization setup request, one that names a host, account, repository or person of this organization, is not filed as asked. Restate it as a need any catalog consumer has. Otherwise return it to its sender with its destination named: the overseer, or the repository or Linear team that owns this organization's setup.

`issues create` checks neither line, apart from its review-born priority-2 `Symptom:` refusal. The author applies this rule.

### Project taxonomy

Require one agent and one surface label. Surface means where a person meets the work. Agent names are declared by LINEAR_AGENT_LABELS in kendex.settings.toml. Labels outside these categories are legacy and are not assigned.

Scope: `cli`, `harness` and `skills` belong to team `kendex`. All agent labels are excluded from team scope. All other labels in this taxonomy have workspace scope. `1.0` identifies kendex’s release set and requires team scope in a separately approved migration.

Brad Mahaffey owns shared label names and scope. Follow the Linear skill’s Shared label maintenance procedure for definition changes.

```json
{
  "required_categories_for_new_issues": ["agent", "surface"],
  "categories": {
    "agent": {"required": true, "exclusive": true, "match": {"prefix": "agent:"}, "forbid_group_labels": true},
    "surface": {"required": true, "exclusive": true, "labels": ["app", "cli", "skills", "harness", "ci-infra", "docs", "releases"]},
    "stack": {"required": false, "exclusive": false, "labels": ["rust-core", "iced", "test", "security"]},
    "platform": {"required": false, "exclusive": true, "labels": ["macos", "windows", "linux"]},
    "classification": {"required": false, "exclusive": false, "labels": ["bug", "feature", "refactor", "design", "chore", "owner-gated", "1.0"]},
    "workflow": {"required": false, "exclusive": false, "labels": ["research", "needs-research", "baseline", "blocked"]}
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
    {"name": "Review Gate & CI", "kind": "standing", "role": "area", "admits": "CI workflows under .github/, and the skills and tools that run the review gate, the merge rail, the merge queue and CI validation."},
    {"name": "Agent Harness Integrations", "kind": "standing", "role": "area", "admits": "pi-extensions/, hooks/ and the per-harness adapters under crates/core/src/harness."},
    {"name": "CLI & Distribution", "kind": "standing", "role": "area", "admits": "The kendex CLI and engine under crates/ outside crates/app and crates/core/src/harness: manifest, lock, settings, apply, refresh, verify and install."},
    {"name": "Desktop App", "kind": "standing", "role": "area", "admits": "Work on the app's code and screens under crates/app and ui/ that advances no deliverable."},
    {"name": "Docs & Onboarding", "kind": "standing", "role": "area", "admits": "The root README.md and AGENTS.md, and docs/; a README or AGENTS.md under another area's path goes to that area."},
    {"name": "Skills & Agents Library", "kind": "standing", "role": "area", "admits": "Catalog skills and agents under skills/ and agents/ that no other area's rule names."},
    {"name": "Tech Debt", "kind": "standing", "role": "concern", "admits": "Cleanup of past shortcuts and pre-existing defects no single area owns; an item that also fits Upkeep goes here."},
    {"name": "Upkeep", "kind": "standing", "role": "concern", "admits": "Recurring maintenance no single area owns: dependency and toolchain updates that span areas, renewals, rotations, refresh adoption and scheduled housekeeping. A change confined to one area's paths goes to that area."}
  ]
}
```
<!-- kendex:project-instructions:end -->

# Project Management

Wrappers run in the primary session: they own the user dialog and every tracker mutation. TPM workflows analyze and return JSON inline; they never mutate the tracker. The fleet [proposal sweep](workflows/proposal-sweep.md) runs in a subagent the overseer launches and returns its analyzed JSON to the overseer.

## Disposition

- **Judge the approach.** At every filing and launch read, judge the approach against the item's own outcome sentence:
  1. Why does this approach produce the stated outcome, and what source evidence will show it? An outcome sentence plus a measurement does not show the work helps.
  2. Can we remove or simplify something instead of adding this? Name the existing owner or the simpler alternative and why it meets or fails the same need. Naming an owner alone is no answer. A new requirement is not forced into a removal.
  3. Is this a workaround of a limit, a rule or a tool? If yes, does the limit or rule still have a reason? Correct or remove a stale rule in its owning place. Fix the cause. Escalate only a boundary the owner reserves. Apply [orch SKILL.md § Skill Rules](../orch/SKILL.md#skill-rules) and code-quality SKILL.md § Correctness and § Over-Engineering.
  - Decide go, change or drop. Put the short cause-and-effect answer in the item's existing outcome, evidence or ruling text.
  - Repair an item with a valid need and weak text on the same item from its source request. Keep its date. Drop it only when the need is absent, duplicated, satisfied or superseded.

- **Creation bar.** File an issue only when all three hold:
  - it changes what a user or operator experiences, or blocks work that does;
  - no open issue, active branch, or one-line fix already covers it;
  - someone could pick it up and finish it without a new investigation.

  A reproducible anomaly with evidence in hand passes all three as an investigation issue. A container has no work of its own, so the three tests do not apply to it. A container is a parent with no `(one PR)` title marker that has children in the tracker, or that names its children by identifier in its body ([parent-issue-template](<templates/parent-issue-template.md>)). It is filed, and kept by every later sweep or verifier, when it states one outcome for its children and holds no requirements and no pull request of its own. Its children sharing that outcome is the design, not a duplicate, and each child faces the bar itself. A parent with no child and none named, and a `(one PR)` parent, are judged as work items. Everything else is declined with one line in the report: no issue, no placeholder, no tracking artifact. Failing the bar: a severe-sounding edge case no real input reaches, a hypothetical of low severity, a coverage ask for a path that has not regressed, a refactor that neither changes behavior nor unblocks user-visible work, and the classes in [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow Step 0, whatever source the candidate arrived from. Two exceptions file at any likelihood: a security or data-loss defect a shipped path reaches, and an edge case whose failure is critical harm or financial loss.

- **Name what reaches it.** Every issue carries a `Reached by:` line giving the user action, run, check, or shipped producer that arrives at the defect; an owner-directed item names the ask.
  - The thread a finding came from, a shape ("a name containing a quote"), or something true in theory is not a reach, and an item with nothing to name is a decline, not an issue. The judgement is the author's: `issues create` under `LINEAR_REQUIRE_REACH` refuses only a body with no `Reached by:` line, an unsubstituted placeholder and a null token (`TBD`, `n/a`, `none`, `-`) counting as absent.
  - A filing whose source is a review round carries, at priority 2, a `Symptom:` line naming the run, the user, or the red check that already showed the defect (`--review-born`). Priority 2 from any other source is structural, reports no symptom, and is not checked for one. Where a review-born finding files at all is [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Filing bar.
- **A requirement asks for what code-quality admits.** A requirement, Done-when or test plan is written against the code-quality skill's SKILL.md § Tests, § Over-Engineering and the repository's compatibility policy under § Cleanup. A wording test, a fixed count of growing data, a compatibility or migration clause the policy does not require, or a gate with no named failure is cut from the item before filing; the cited section states each rule.
- **Done-when separates branch proof from live proof.** Prove every box the branch can prove before merge. Admit a post-merge box on the same item only when all three conditions hold. It needs something the branch cannot give: a deployment or installation (a release, consumer refresh or host), live use over time, or a person's screen or hands. Name that class in `Why after merge:`. Its `Where:` names evidence the verification pass can read, or the person for a person-only check. The repository's normal traffic produces its sample inside the window. A release trigger names a release the repository publishes within 72 hours of merge. A count names its sample size. Otherwise make it a pre-merge test or drop it. Write each such box on one line as `- [ ] Post-merge: <check>; Where: <location or command>; Why after merge: <why the branch cannot prove it>; Trigger: <trigger>; Deadline: <deadline>`. The `Post-merge:` check states its pass condition. Trigger is `merge`, a UTC time at or after merge, or `release OWNER/REPO TAG-GLOB`, the first matching GitHub release published after merge. When OWNER/REPO is a repository where the item merged, the release must contain the item's latest merge commit in that repository. A missing Trigger means `merge`. Deadline is `+Nh`, with N from 1 through 72, counted from the trigger: the merge, the stated time, or the release publication. Write a merge trigger's deadline as `+Nh`, because the merge time is unknown when the box is written. A merge or time trigger also takes a real UTC deadline after its trigger and at most 72 hours later; a release trigger takes only `+Nh`. The Linear completion command validates this form. Admit a count or rare-event check only when an existing query or counter answers it inside this window. Otherwise make it a pre-merge test or drop it. Absence of an event passes only when the check states absence as its pass condition. An open post-merge box keeps the merged item in Verifying. The overseer records evidence and ticks a passing box, then completes the same item after its last box. A failed check keeps the item Verifying and gets a peer fix item that blocks it. Evidence that remains unreadable at its deadline gets the same route, with the fix item correcting access, measurement, or the check. The same check runs again after the fix merges. A merged item never returns to In Progress. No deadline moves. Do not create a separate item to carry the verification check.
- **One item per batch.** A body that lists batches each able to land alone is filed as one item per batch, with a blocking relation only where a batch needs another's change.
- **One landing per subsystem.** An item whose work changes more than one subsystem, as the orch skill's [small.md](../orch/workflows/small.md) opening defines one, is filed as one item per subsystem, each able to land and be reviewed alone, with a blocking relation only where one needs another's change. An item that cannot land in parts says why in its body. The orch launch read, [oversee.md](../orch/workflows/oversee.md) § 3 Lane directive step 2, sends back an item that still spans several.
- **Burn down more than you create.** Every audit that reads an issue backlog sweeps its comparison set for issues the codebase has already satisfied, duplicated, or superseded, and proposes those for cancellation in the same pass, along with every active issue that fails the creation bar as it stands today. Report `created N / closed M`. `project-order` reorders projects, reads no backlog, and does not sweep; `single` files one item against the open titles and does not sweep either.
- **Ask about work, never about mechanics.** Creation and cancellation follow [audit-issues § 6](workflows/audit-issues.md#6-approve-creations-and-cancellations); the user decides activation. Labels, priorities, relations, hierarchy, sort order, and project moves are corrections the workflow applies on its own authority.
- **Research is part of planning, not a work item.** Gather prior art, vendor docs, and approach comparisons inline during planning. Store the artifacts in the tracker under § Planning artifacts; research that is the evidence behind a constraint still in force stays attached to that constraint's issue, and the rest is not kept. A tracker research issue exists only when the research is delegated as standalone work: run by the researcher agent, or prepared for later pickup (`research-spike`).
- **One approval per decision.** Ask the user to approve a body of work once, at the roadmap plan gate. Creation re-asks only what changed after that answer.

## Planning artifacts

Planning, research, roadmap and audit files are not repository content. A plan or report with no caller-supplied path lives at `tmp/plans/<slug>.md` (a research report at `tmp/plans/<slug>-research.md`, a roadmap at `tmp/roadmaps/roadmap-<feature>.md`), never under a tracked `docs/` path; the full rule is `agents/planner.md` § Plan Artifacts. `[RESEARCH_DOCS_PATH]`, the directory the research workflows name, is `tmp/plans/research`: a research issue's assets and findings live under `tmp/plans/research/<ISSUE_ID>/`. Temporary review output belongs under `tmp/reviews/`.

**Where a plan lives and how a reader finds it.** An artifact's durable home is its source issue: the issue it already sits on, else the issue it serves, else, when it serves several, the first issue the run creates, or the first open issue it updates in a run that creates none. The local file is a working copy. A reader given a cited path reads that file when it exists in its checkout; otherwise it finds the artifact by the tracker:

- **Linear**: the link in the read issue's `**Artifacts**` list, which names the current copy, else an attachment on the source issue, both read through [linear SKILL.md § Resolve a cited artifact](../linear/SKILL.md#resolve-a-cited-artifact).
- **GitHub Issues**: the text in the source issue's body or a comment, read with `gh issue view [N] --repo [OWNER/REPO] --json body,comments`.
- **No tracker**: the caller's named path, else `tmp/`. Nothing makes the file durable, and a missing one is reported missing.

An artifact this route does not find is missing, and the calling workflow's missing-file behavior applies. A brief cites an artifact by its repository path, which on Linear is the attachment name and the `**Artifacts**` link label; a brief whose own issue neither holds nor links the artifact also names its source issue.

Carry each planning artifact's repository reference, readable path, and source issue separately. A same-checkout delegation receives the readable path for analysis and the reference for its output. A handoff to another checkout carries the reference and the source issue; the receiver resolves its own readable path through the route above. Saved plans and tracker text contain references and source issues, never a machine's local paths. A source issue identifies storage, not the roadmap's hierarchy origin. With no published source issue, keep the existing local-until-creation flow.

**Publishing on Linear.** Attach each produced artifact and each cited planning input once, to its source issue; one that already sits on its source issue is not uploaded again. After the planned mutations for that issue, run `issues update [ISSUE_ID] --attach [PATH]`, repeated per file, as an attach-only call. Include companion files needed to read the artifact, such as roadmap JSON and research metadata. Keep its returned `attachments[]` entries and add an `**Artifacts**` list to the issue description: one `[repository-relative path](url)` link per entry. Every other issue the run creates or updates that cites the artifact carries the same links in its own `**Artifacts**` list and uploads nothing. Replace the prior link for the same path and preserve links to other inputs. Those links identify the published version even when older attachments share the path. Verify every attachment and description write before reporting completion. A run with no issue writes keeps its files locally until creation; it creates no issue only to hold files. A run whose writes leave no open issue to hold them, such as one that only cancels, keeps its files locally and reports them as unpublished.

**Publishing on GitHub.** For a GitHub audit, put the produced text artifact in the created or updated issue body, and include the text of any cited planning input needed for pickup. Report binary inputs that have no tracker upload route as incomplete; never claim a local-only file is available to another lane. A run without artifacts retains its existing tracker behavior.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | none | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `team` \| `issue [IDs]` \| `--issues [file]` \| `--single [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | none | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | none | [research-issue](workflows/research-issue.md), internal, invoked by `research-spike` |
| `proposal-sweep` | fleet brief | [proposal-sweep](workflows/proposal-sweep.md), internal, invoked by `oversee` |

`audit-issues` is **primary-session only** ([audit-issues](workflows/audit-issues.md) preamble): the roadmap-plan § 5 answer that roadmap-create carries in is validated and admitted at § 6, never around it.

The `@[path]` given to `roadmap plan` may be research findings or a **finished plan** (a design the user has reviewed). A finished plan is the spec: derive issues from it instead of re-planning, and every issue cites it.

TPM analysis workflows, each returning JSON per its schema: [tpm-cycle-plan](workflows/tpm-cycle-plan.md), [tpm-audit](workflows/tpm-audit.md) (project / team / issue / single / project-order modes), [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md).

## Execution Rules

- Run workflow sections in order. Skip only on an explicit **Skip if** condition, never on your own scope assessment.
- `<delegation_format>` and `<output_format>` are literal templates: fill `[PLACEHOLDERS]`, drop lines whose placeholders are empty, add nothing.
- Send a user-visible `<output_format>` report as a normal assistant message first, then invoke the question tool separately with only the question and short option labels. Never paste the report into question text or options.
- A Linear list read with no `--team` returns the whole workspace, except `cycles list` and `statuses`, which default to `LINEAR_TEAM`, and `issues list` returns no team through its `safe`, `compact`, `ids` or `table` formatter, so a row read through those cannot be checked against `--team X` (only `--format=raw` carries `.team.name`). Team scope per path: § Scope by Path.
- Every Linear read is live, so it answers with the tracker as it is. A failed read halts the workflow with its diagnostic, never a partial result: a `--max` read reads every page or fails, and a bounded list read prints a `linear-list: truncated` notice on stderr when it left rows unread.
- Resolve tracker context once per run (audit-issues § 1.2) and route every preflight, fetch, and mutation through it. A GitHub-tracked run must not require Linear installation or authentication; where GitHub lacks a Linear concept, degrade in a documented note, never silently.
- Before any issue create or label update, run the label preflight in [references/labels.md](references/labels.md) against the live inventory and project taxonomy; any § Validation failure there halts before mutation.
- A project declares its taxonomy where [references/labels.md § Project Taxonomy Contract](references/labels.md#project-taxonomy-contract) states. A project that declares none has no required categories to enforce.
- In multi-issue analysis, keep verification context per issue. One issue's PR, branch, or resolved path set never scopes another's checks.

## Scope by Path

A Linear list read is workspace-wide unless it passes `--team`, so each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters. TPM comparison `issues list` reads pass `--team` on the server. Closed comparison rows come only from per-input `--state "Done,Canceled" --search` reads without `--max`; tpm-audit § 1.5 owns the comparison and truncation rules. Silence is not inheritance: a new mode adds its row.

| Path | Resolves | Filters |
|------|----------|---------|
| tpm-audit `project`, `team` | yes | § 1.3 projects; § 1.4 input and § 1.5 active/closed issue lists pass `--team`; § 1.4.1 comments cover inputs and candidates |
| tpm-audit `issues`, Linear | yes | § 1.5 active/closed issue lists pass `--team`; § 1.4.1 comments cover inputs and candidates; a § 1.4 input issue outside scope halts |
| tpm-audit `issues`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `single`, Linear | yes | § 1.3 projects; § 14 title list passes `--team` |
| tpm-audit `single`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `project-order` | yes | § 11 initiatives and projects; per-project issue lists pass `--team` |
| tpm-roadmap-plan | yes, § 1.1 | § 1.4 projects; § 1.5 active/closed issue lists pass `--team` and comments cover inputs and candidates |
| tpm-cycle-plan | **no** | **no**. § 1 picks the active project from `session-status`'s workspace-wide started projects, and every issue read is scoped to that pick. The § 1 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](references/project-map.md#audit)) |
| audit-issues §§ 7.2-7.5 | n/a, executes an artifact tpm-audit produced under its scope | reads rooted at an in-scope project or an issue this run mutated |
| audit-issues § 1.2.1, § 3 | **no** | **no**. `session-status` selects projects workspace-wide. The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](references/project-map.md#audit)) |
| cycle-plan, roadmap-plan, roadmap-create | **no** | **no**. Project, initiative, and label reads span the workspace. roadmap-create's map read is scoped to the team it creates in |
| research-spike | **no** | **no**. Project and label reads span the workspace. The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](references/project-map.md#audit)) |
| research-complete | n/a | reads are rooted at the caller's issue identifier |
| research-issue | n/a | reads rooted at the caller's identifiers; the project it creates into is the caller's pick |

## Hierarchy

`Initiative → Project → Milestone → Issue → Sub-Issue`. Parent and child must share a project; under a project map, the parent's route sets it ([references/project-map.md § Routing](references/project-map.md#routing)). Blocking relations may cross projects freely. See [references/dependencies.md](references/dependencies.md). What an initiative, a project and a label each hold, the two project kinds, and which project an item goes in: [references/project-map.md](references/project-map.md).

## Contracts

| Kind | Files |
|------|-------|
| Schemas | [audit-issues-input](schemas/audit-issues-input.md), [audit-output](schemas/audit-output.md), [roadmap-plan-input](schemas/roadmap-plan-input.md), [roadmap-plan-output](schemas/roadmap-plan-output.md), [cycle-plan-output](schemas/cycle-plan-output.md) |
| Templates | [issue-description-template](templates/issue-description-template.md), [parent-issue-template](templates/parent-issue-template.md), [initiative-project-template](templates/initiative-project-template.md) |
| References | [labels](references/labels.md), [dependencies](references/dependencies.md), [project-map](references/project-map.md) |
| Tracker CLI | Linear: `.agents/skills/linear/scripts/linear.sh`; GitHub: `gh` + `.agents/skills/github/scripts/github.sh` |

## Where each rule lives

| Rule | Home | Reason and callers |
|---|---|---|
| Issue body and field mapping | Package: [issue-description-template](templates/issue-description-template.md) and [parent-issue-template](templates/parent-issue-template.md) | The audit maps structured fields into its own body. Linear's [IssueCreateInput.templateId](https://github.com/linear/linear/blob/master/packages/sdk/src/_generated_documents.ts) lets supplied values override template values. A Linear copy would be a second body no create reads. audit-issues, orch's start-new, plan-issues and merge-pr, and linear's patterns/workflow-actions.md cite these templates. |
| Reached by and Symptom lines | Tool: `linear.sh issues create`; meaning: § Disposition | The tool refuses missing values. The package says what each value names. audit-issues passes the template body and review-born flag. |
| Required issue labels | Tool and project taxonomy: [labels](references/labels.md) | The tool checks the project's declared labels. The audit's label preflight builds the complete set. |
| Project placement | Tool and project map: [project-map](references/project-map.md) | The tool refuses a project the map does not list, and `projects audit` reports every item outside it. tpm-audit routes, and audit-issues applies the moves. |
| Initiative and project body | Package: [initiative-project-template](templates/initiative-project-template.md) | Linear documents [issue templates](https://linear.app/docs/issue-templates) and [project templates](https://linear.app/docs/project-templates). [InitiativeCreateInput](https://github.com/linear/linear/blob/master/packages/sdk/src/_generated_documents.ts) has no template id. roadmap-create uses this shared template. |
| Initiative owner, lead team, labels, links and status updates; project lead, labels and links | Linear fields, set by the Linear CLI flags | Linear stores these values. roadmap-create sets the creation fields by flag. A Linear project template can prefill fields for a person in the app; the agent path needs no second template or consumer setup. Status updates use Linear's update fields when a workflow calls for them. |
| GitHub issue and pull request templates | Repository: `.github/ISSUE_TEMPLATE` and `pull_request_template.md` | The repository owns its GitHub forms. This package ships none; kendex tracks work in Linear. |
| Comments | Package: this section | A comment carries one update. A run of time stamps is one line and a link. Completion and verification comment producers keep their own forms. |
