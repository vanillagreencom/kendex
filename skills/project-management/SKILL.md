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

# Project Management

Wrappers run in the primary session: they own the user dialog and every tracker mutation. TPM workflows analyze and return JSON inline; they never mutate the tracker. The fleet [proposal sweep](workflows/proposal-sweep.md) runs in a subagent the overseer launches and returns its analyzed JSON to the overseer.

## Disposition

- **Creation bar.** File an issue only when all three hold:
  - it changes what a user or operator experiences, or blocks work that does;
  - no open issue, active branch, or one-line fix already covers it;
  - someone could pick it up and finish it without a new investigation.

  A reproducible anomaly with evidence in hand passes all three as an investigation issue. Everything else is declined with one line in the report: no issue, no placeholder, no tracking artifact. Failing the bar: a severe-sounding edge case no real input reaches, a hypothetical of low severity, a coverage ask for a path that has not regressed, a refactor that neither changes behavior nor unblocks user-visible work, and the classes in [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow Step 0, whatever source the candidate arrived from. Two exceptions file at any likelihood: a security or data-loss defect a shipped path reaches, and an edge case whose failure is critical harm or financial loss.

- **Name what reaches it.** Every issue carries a `Reached by:` line giving the user action, run, check, or shipped producer that arrives at the defect; an owner-directed item names the ask.
  - The thread a finding came from, a shape ("a name containing a quote"), or something true in theory is not a reach, and an item with nothing to name is a decline, not an issue. The judgement is the author's: `issues create` under `LINEAR_REQUIRE_REACH` refuses only a body with no `Reached by:` line, an unsubstituted placeholder and a null token (`TBD`, `n/a`, `none`, `-`) counting as absent.
  - A filing whose source is a review round carries, at priority 2, a `Symptom:` line naming the run, the user, or the red check that already showed the defect (`--review-born`). Priority 2 from any other source is structural, reports no symptom, and is not checked for one. Where a review-born finding files at all is [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Filing bar.
- **A requirement asks for what code-quality admits.** A requirement, Done-when or test plan is written against the code-quality skill's SKILL.md § Tests, § Over-Engineering and the repository's compatibility policy under § Cleanup. A wording test, a fixed count of growing data, a compatibility or migration clause the policy does not require, or a gate with no named failure is cut from the item before filing; the cited section states each rule.
- **Done-when separates branch proof from live proof.** Prove every box the branch can prove before merge. Admit a post-merge box on the same item only when all three conditions hold. It needs something the branch cannot give: a deployment or installation (a release, consumer refresh or host), live use over time, or a person's screen or hands. Name that class in `Why after merge:`. Its `Where:` names evidence the verification pass can read, or the person for a person-only check. The repository's normal traffic produces its sample inside the window. A release trigger names a release the repository publishes within 72 hours of merge. A count names its sample size. Otherwise make it a pre-merge test or drop it. Write each such box on one line as `- [ ] Post-merge: <check>; Where: <location or command>; Why after merge: <why the branch cannot prove it>; Trigger: <trigger>; Deadline: <deadline>`. The `Post-merge:` check states its pass condition. Trigger is `merge`, a UTC time at or after merge, or `release OWNER/REPO TAG-GLOB`, the first matching GitHub release published after merge. A missing Trigger means `merge`. A merge or time trigger takes a real UTC deadline after its trigger and at most 72 hours later. A release trigger takes `+Nh`, with N from 1 through 72, after the release publication. The Linear completion command validates this form. Admit a count or rare-event check only when an existing query or counter answers it inside this window. Otherwise make it a pre-merge test or drop it. Absence of an event passes only when the check states absence as its pass condition. An open post-merge box keeps the merged item in Verifying. The overseer records evidence and ticks a passing box, then completes the same item after its last box. A failed check keeps the item Verifying and gets a peer fix item that blocks it. Evidence that remains unreadable at its deadline gets the same route, with the fix item correcting access, measurement, or the check. The same check runs again after the fix merges. A merged item never returns to In Progress. No deadline moves. Do not create a separate item to carry the verification check.
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

A Linear list read is workspace-wide, so each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters. Silence is not inheritance: a new mode adds its row.

| Path | Resolves | Filters |
|------|----------|---------|
| tpm-audit `project`, `team` | yes | § 1.3 projects, § 1.4 input set, § 1.5 comparison set |
| tpm-audit `issues`, Linear | yes | § 1.5 comparison set; a § 1.4 input issue outside scope halts |
| tpm-audit `issues`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `single`, Linear | yes | § 1.3 projects, § 14 title list |
| tpm-audit `single`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `project-order` | yes | § 11 initiatives, projects, and per-project issues |
| tpm-roadmap-plan | yes, § 1.1 | § 1.4 projects, § 1.5 comparison set |
| tpm-cycle-plan | **no** | **no**. `session-status` picks the active project workspace-wide, and every later read is scoped to that pick |
| audit-issues §§ 7.2-7.5 | n/a, executes an artifact tpm-audit produced under its scope | reads rooted at an in-scope project or an issue this run mutated |
| audit-issues § 1.2.1, § 3 | **no** | **no**. `session-status` selects projects workspace-wide |
| cycle-plan, roadmap-plan, roadmap-create, research-spike | **no** | **no**. Project, initiative, and label reads span the workspace |
| research-complete | n/a | reads are rooted at the caller's issue identifier |
| research-issue | n/a | reads rooted at the caller's identifiers; the project it creates into is the caller's pick |

## Hierarchy

`Initiative → Project → Milestone → Issue → Sub-Issue`. Parent and child must share a project; blocking relations may cross projects freely. See [references/dependencies.md](references/dependencies.md).

## Contracts

| Kind | Files |
|------|-------|
| Schemas | [audit-issues-input](schemas/audit-issues-input.md), [audit-output](schemas/audit-output.md), [roadmap-plan-input](schemas/roadmap-plan-input.md), [roadmap-plan-output](schemas/roadmap-plan-output.md), [cycle-plan-output](schemas/cycle-plan-output.md) |
| Templates | [issue-description-template](templates/issue-description-template.md), [parent-issue-template](templates/parent-issue-template.md) |
| References | [labels](references/labels.md), [dependencies](references/dependencies.md) |
| Tracker CLI | Linear: `.agents/skills/linear/scripts/linear.sh`; GitHub: `gh` + `.agents/skills/github/scripts/github.sh` |
