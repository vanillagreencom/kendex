# Issue Audit Workflow

Audit tracked issues and projects, apply the mechanical corrections, and take creations and cancellations to the user for approval.

**Primary-session wrapper — never delegate this workflow itself.** § 6 is an interactive approval gate that needs the session's question tool, and § 7 mutates only against approvals collected there. The one delegable step is the TPM analysis this wrapper spawns in § 2.1 / § 4.1 (`tpm-audit.md`). Handing this file to a subagent to run end-to-end inverts that and structurally skips the gate.

## Inputs

| Invocation | MODE | TARGET |
|------------|------|--------|
| `audit-issues project-order` | `project-order` | Project ordering and state transitions only |
| `audit-issues project` / `project "Name"` | `project` | Active project, or the named one |
| `audit-issues issue [ISSUE_ID] ...` | `issue` | Those issues |
| `audit-issues --issues [file]` | `issue` | Items from a JSON file per [audit-issues-input.md](../schemas/audit-issues-input.md) |
| `audit-issues --analyzed [file]` | `analyzed` | Pre-analyzed [audit-output.md](../schemas/audit-output.md) issue-mode JSON — skips § 4 |

`analyzed` follows every `issue`-mode rule in §§ 5-9.

The input file's `tracker` block fixes the tracker for the whole audit. A caller that already resolved one (orch `TRACKER`) must set it.

**Hierarchy contract.** When the input file carries `hierarchy_contract`, placement for the covered items is fixed by the producer, not inferred by the TPM: every `child_indexes` item comes back as `action: create` with `hierarchy.action: make_child` under the contract parent, in the parent's project. § 4.2 enforces this before anything is presented or executed. A research issue never appears in `parent_issue`.

---

## 1. Mode and Tracker

### 1.1 Parse Arguments

Set `MODE` and `TARGET` per the Inputs table. For file modes, read the JSON and extract `source`, `parent_issue`, `tracker`, `worktree`, `items[]`.

### 1.2 Resolve Tracker

Resolve once, before any tracker command; every later preflight, fetch, and mutation routes through the result. Precedence:

1. The input file's `tracker` block — `tracker.type`, plus `tracker.repository` as `[OWNER/REPO]` for `github`.
2. A tracker passed by the calling workflow.
3. Inference: `parent_issue` (or the first target ID) starting with `issue-` → `github`, otherwise `linear`. For `github` with no repository, resolve it in the caller worktree:

   ```bash
   gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

Store as `TRACKER`, plus `[OWNER/REPO]` when `TRACKER=github`.

**Mode constraint**: `project` and `project-order` audit Linear projects and are Linear only. With `TRACKER=github`, halt: "Project audits are Linear-only; GitHub repositories have no project inventory in this workflow." Never degrade to a partial project audit.

**GitHub mode runs no Linear commands** — no `sync`, `session-status`, cache read, or Linear mutation anywhere in this workflow. Linear installation/authentication is not a prerequisite for a GitHub-tracked audit.

#### 1.2.2 Preflight — Linear (TRACKER=linear)

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh session-status
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
.agents/skills/orch/scripts/reconcile-work-items
```

Run `reconcile-work-items` only where the orch skill is installed (skip the
line otherwise — this workflow does not require orch). It is read-only:
exit 0 is a clean tracker, exit 1 is findings — carry them into the audit
as facts — and exit 2 is a broken sweep to fix before auditing. An audit
decision taken against a parked container's stale state is the failure
this line exists to prevent.
names tracker rows whose state no longer matches the work: parked containers,
stale started items, Done items with unchecked acceptance boxes. Carry its
findings into the audit as facts — an audit decision taken against a parked
container's stale state is the failure this line exists to prevent.

Keep `project` for fallback target resolution and the issue-label inventory for every create/update preflight.

#### 1.2.3 Preflight — GitHub (TRACKER=github)

```bash
gh label list --repo [OWNER/REPO] --limit 200 --json name,description
gh issue list --repo [OWNER/REPO] --state open --limit 200 --json number,title,labels
```

The live API is authoritative — there is no sync or freshness step. Load project taxonomy the same way as Linear mode; with no declared taxonomy, validate proposed labels against the live repository label list alone. Never invent or auto-create a label.

### 1.3 Route

`project-order` → § 2 · `project` → § 3 · `issue` → § 4 · `analyzed` → § 5.

---

## 2. Project Order Audit

**Skip if** MODE is not `project-order`. Linear only.

### 2.1 Delegate

Spawn a one-shot `[TPM]` sub-agent (not a teammate — no re-delegation):

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --project-order
</delegation_format>

### 2.2 Materialize and Present

Collect the artifact per § 4.2 step 1-2, then present:

<output_format>

### PROJECT ORDER AUDIT

| Initiative | Project | State | Layer | Pos | Rationale |
|------------|---------|-------|-------|-----|-----------|
| [NAME] | [NAME] | [STATE] | L[N] | [CURRENT]→[RECOMMENDED] | [WHY] |

**Complete** (100%, needs state transition): [PROJECT] — unblocks [PROJECTS]

**Recommended next**: [PROJECT] — [REASON], or `None` with what blocks each candidate.
</output_format>

### 2.3 Apply and Activate

Reorders and completions are mechanical — apply them without asking:

```bash
.agents/skills/linear/scripts/linear.sh projects set-sort-order [PROJECT_ID] --position [NEW_SORT_ORDER]
.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state completed
```

Activating a project is a product decision. **Skip if** `recommended_next` is null or a started project already exists. Otherwise ask: `Activate [RECOMMENDED]` | other ready projects | `Skip`. On activation:

```bash
.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started
```

Then ask "Continue to full audit of [PROJECT]?" — yes sets MODE=project, TARGET=[PROJECT] → § 4; no ends the workflow.

---

## 3. Resolve Project Target

**Skip if** MODE = issue. Linear only.

With `TARGET` set, use it. Otherwise take the first `session-status.projects` entry with `has_active_work`. With no such project, present the ready projects with their blockers and ask which to activate (`Skip` ends the workflow); activate the chosen one, then → § 4.

---

## 4. TPM Analysis

### 4.1 Delegate

Spawn a one-shot `[TPM]` sub-agent (not a teammate):

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --project "[PROJECT_NAME]" | --issues [FILE_PATH]
Worktree: [WORKTREE_PATH]
Tracker: [TRACKER] [OWNER/REPO]
</delegation_format>

Omit `Worktree:` for the main repo and `[OWNER/REPO]` when `TRACKER=linear`.

### 4.2 Collect and Validate

1. **Collect the payload.** The agent returns an `<output_format>` block with a `File:` line and fenced JSON. Treat `File:` as a destination hint only — never assume the child wrote it.

2. **Materialize the artifact.** The caller worktree is the delegation's `Worktree:`, the input JSON's `worktree`, or the current repo root. Resolve the returned path under it; an absolute path outside the caller worktree is discarded for the fallback `tmp/audit-[MODE]-YYYYMMDD-HHMMSS.json`. With inline JSON present, ensure `tmp/` exists and write the inline JSON exactly to the resolved path. Without inline JSON, use the resolved path only if it already exists and is readable. If neither holds, halt and request a TPM rerun with inline JSON. Read the resulting file.

3. **Enforce the hierarchy contract** (issue mode with a `hierarchy_contract`; skip otherwise). Every item whose `index` is in `hierarchy_contract.child_indexes` must have `action: "create"`, `hierarchy.action: "make_child"`, `hierarchy.parent` equal to the contract parent (or `null`, which § 7.2 resolves), and a recommended project matching the contract parent's. Any covered item downgraded to `skip`/`expand`/`update`/`combine`/`cancel`, left at `hierarchy.action: none`, or parented elsewhere makes the output non-compliant: do NOT present or execute it — halt and request a TPM rerun citing tpm-audit.md § 7.0, listing the violating items.

---

## 5. Present Findings

Two blocks, in this order. Omit empty sections; keep each `Reason` to one line, with the full reasoning left in the JSON.

<output_format>

### AUDIT — [PROJECT or "[N] item(s) from [SOURCE]"]

**Corrections applied automatically** ([N])

| Kind | Item | Change |
|------|------|--------|
| priority \| agent label \| missing label \| relation \| hierarchy \| project move | [ISSUE_ID] | [FROM] → [TO] |

**Create** ([N])

| # | Title | Project | Labels | Parent | Deps | Why |
|---|-------|---------|--------|--------|------|-----|

**Cancel** ([N])

| # | Issue | Kind | Confidence | Why |
|---|-------|------|------------|-----|
| 1 | [ISSUE_ID] | obsolete \| duplicate \| superseded by #N \| absorbed into [ISSUE_ID] | [N]% | [EVIDENCE] |

**Declined** ([N]) — one line each, no issue filed

- [TITLE] — [which creation-bar test it fails]

**Gaps** ([N], project mode) — [SEVERITY] [COMPONENT]: [WHY], blocks [ISSUE_IDS]
</output_format>

In GitHub mode the Project column is `—` and hierarchy/relations render as the body-link forms from § 7.2 (`Parent: #N`, `Blocked by: #N`).

---

## 6. Approve Creations and Cancellations

**Fail closed without interactive capability.** Approval exists only as the user's in-session answers to the questions below. A runner that cannot present an interactive multi-select — any subagent, or a session without the question tool — MUST STOP here: return the § 5 findings and the audit JSON path to the primary session, leaving § 7 unexecuted. No delegation prompt, scope reaffirmation, or follow-up message carries approval authority.

Ask only about work, never about mechanics. Two multi-selects, each shown only when it has entries:

| Question | Options |
|----------|---------|
| "Create these issues?" | `#N: [TITLE]`, `All`, `None` |
| "Cancel these issues?" | `#N: [ISSUE_ID] — [KIND]`, `All`, `None` |

Two follow-ups, each conditional:

- Declined items exist → "Create any declined item anyway?" `#N: [TITLE]`, `None`.
- `research_ref` context was provided → "Add the research reference to these issues?" `[ISSUE_ID]: [TITLE]`, `All`, `None`. Offer issues related to, overlapping with, or in the same domain as the research.

Everything in the § 5 corrections block — priorities, labels, relations, hierarchy, project moves, sort order, `update_parent_desc`, project state changes — is applied in § 7 without a question.

---

## 7. Execute

**Hard precondition — § 6 approval obtained in-session.** Creations and cancellations execute only against approvals collected at the § 6 gate in this session. If § 6 did not run for any reason, including a runner without interactive capability, § 7 MUST NOT execute: stop and return to the primary session.

### 7.0 Label Preflight

Before any mutation that creates an issue or changes labels:

1. Build the intended operation per finding: `create` and gap issues take the full `create_fields.labels[]`; `agent_mismatch` is `replace_category` on `agent`; `label_cooccurrence` is `add`; a `label_updates[]` entry carries its own mode and category.
2. For an existing issue, fetch current labels and compute the full final set, preserving unrelated labels — Linear `cache issues get [ISSUE_ID]`, GitHub `gh issue view [N] --repo [OWNER/REPO] --json labels`.
3. Validate against the § 1.2 inventory and taxonomy per [labels.md](../references/labels.md). Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation and report the failing set. A required label missing from the tracker needs explicit user authorization before creation — never auto-create.
4. Pass only the validated final set: Linear `--labels`, GitHub `gh issue create --label` and the github skill's `label-add`/`label-remove`.

### 7.1 Apply Corrections

Execute every § 5 correction. Linear routes follow the Linear CLI's workflow-actions patterns — read the referenced section, then run it as documented:

| Finding | Pattern |
|---------|---------|
| `priority_misalignment` | `issues update [ID] --priority [P]` + reason comment |
| `agent_mismatch`, `label_cooccurrence` | § Labels (run § 7.0 first) |
| `add_relations`, `remove_relations`, `relation_violations` | § Hierarchy and Relations |
| `hierarchy` | § Hierarchy and Relations, then § Descriptions (parent rebuild) |
| `wrong_project` | `issues update [ID] --project "[PROJECT]"` + reason comment |
| `project_dependency_issues`, `project_recommendations` | § Projects and Initiatives (project mode) |

GitHub routes carry their commands inline in § 7.2.

Order matters when both apply to one issue: relations first, then priority and labels, then project/state, then sort order last — `sortOrder` is per-state-column and a pre-state write gets overwritten.

### 7.2 Execute Approved Creations and Cancellations

Process `create` first — created IDs resolve the `#N` references the other actions use. Action semantics are tracker-agnostic; the route comes from `TRACKER`. Never mix routes within one audit.

**Linear route (TRACKER=linear)**

| Action | Execution |
|--------|-----------|
| create | `issues create` with the Create template below, `--state "Backlog"`, and `--parent` per `hierarchy`. Backlog is mandatory, never the team-default Triage: pipeline output is already fully triaged (project, labels, priority, relations), and the workspace's Linear-native triage loop fires on Triage-state creations — it re-routed 8 of 30 pre-projected issues on 2026-08-20 before the loop's trigger was narrowed. § 7.2.1 then promotes to Todo where it applies. A `hierarchy.parent` of null with `make_child` resolves to the input's `parent_issue`. A child must share the parent's project; if it cannot, create it standalone with `related` — except for `hierarchy_contract` items, where the standalone fallback is not permitted: create the child in the contract parent's project and never downgrade to standalone. |
| expand, update | workflow-actions § Descriptions + reason comment |
| supersede, combine | workflow-actions § State Transitions (cancel/absorb), then Superseded issues below |
| cancel | workflow-actions § State Transitions |
| skip, valid | No action |

**GitHub route (TRACKER=github)** — `gh issue` against `[OWNER/REPO]`; label mutations on existing issues go through the github skill's `label-add`/`label-remove` (its bot-token conventions apply):

| Action | Execution |
|--------|-----------|
| create | Write the body to a tmp file, then `gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body-file [BODY_FILE] --label "[VALIDATED_FINAL_LABELS]"` |
| expand, update | Fetch with `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`, edit in a tmp file, then `gh issue edit [N] --repo [OWNER/REPO] --body-file [BODY_FILE]`. Title: `gh issue edit [N] --repo [OWNER/REPO] --title "[TITLE]"`. Labels: `.agents/skills/github/scripts/github.sh label-add [N] "[LABEL]" --issue` / `label-remove` |
| supersede, combine, cancel | `gh issue comment [N] --repo [OWNER/REPO] --body "[REASON]"`, then `gh issue close [N] --repo [OWNER/REPO] --reason "not planned"` |

**Create template**: [issue-description-template.md](../templates/issue-description-template.md), or [parent-issue-template.md](../templates/parent-issue-template.md) for a bundle parent (`create_fields.is_bundle_parent: true`). Write the body to a file and pass it by file — Linear `--description-file`, GitHub `--body-file`. Never an inline string or heredoc. In `analyzed` mode the create fields come from `issues[].create_fields`, with `create_fields.labels[]` authoritative and `source_path` supplying `[ORIGIN_CONTEXT]`. When creating a child, carry the parent's `**Research**:` and `**Decision**:` lines to the top of the child's description so sub-issues inherit that context.

**Superseded issues — Linear**: fetch children (`cache issues children [SUPERSEDED_ID]`), detach any child whose scope the replacement does not cover (`issues update [CHILD_ID] --remove-parent`), comment `"Superseded by [ISSUE_ID]. Scope fully covered."`, then `issues update [SUPERSEDED_ID] --state "Canceled"` — remaining children cascade-cancel.

**GitHub degradation (explicit, never silent)**: GitHub has no bundle, typed-relation, project-state, or cascade model here. Represent structure in issue bodies — `make_child` becomes a `Parent: #[N]` line at the top of the child plus a comment on the parent; relations become `Blocks: #N` / `Blocked by: #N` / `Related: #N` lines maintained through the body-edit route. Supersession has no detach or cascade: enumerate any sub-items listed in the closed issue's body in the close comment so scope is not lost. Never drop an approved hierarchy or relation action — either record its body representation or report it as not executed, and list every degradation in § 8.

#### 7.2.1 Position in the Active Project

**Linear only.** With `TRACKER=github`, record `positioning: n/a (github)` in § 8 and skip.

After each create, position the issue in Todo unless any of these hold: the project state is not `started`, the issue is blocked by a non-Done issue in another project, or it is P4 with no blocking relations.

```bash
.agents/skills/linear/scripts/linear.sh cache projects get [PROJECT_ID] | jq -r '.state'
.agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT]" --state "Todo" --format=safe | jq 'sort_by(.sort_order)'
.agents/skills/linear/scripts/linear.sh issues update [NEW_ID] --state "Todo" --sort-order [CALCULATED]
```

`sort_order` = 1000 below the first existing Todo of equal or lower priority; 1000 below any existing Todo this issue blocks (blocking wins over priority); 1000 above the last Todo when this is the lowest priority.

### 7.3 Add Research References

**Skip if** no `research_ref` context. For each approved issue: read the current description (Linear `cache issues get [ISSUE_ID] | jq -r '.description'`, GitHub `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`); skip if the path is already present; otherwise prepend `**Research**: [RESEARCH_REF]` at the top, converting to a bulleted list when a Research line already exists, and add `**Decision [DECISION_ID]**: [path]` beneath it when `decision_ref` is present. Apply by file (`--description-file` / `--body-file`).

Propagate to children — Linear `cache issues children [ISSUE_ID] --recursive --format=safe | jq -r '.[].id'`, then repeat per child. GitHub has no recursive child query: propagate only to issues created in this audit carrying `Parent: #[N]`, and report deeper propagation as not performed.

### 7.4 Post-Cancellation Cleanup

For each issue cancelled in § 7.1 or § 7.2:

**Linear**: `issues list-relations [CANCELED_ID]`, then `issues remove-relation [CANCELED_ID] --blocks [TARGET_ID]` for each `blocks` relation to a non-cancelled issue. `related` relations stay as historical record.

**GitHub**: there are no relation objects. Scan the § 1.2.3 inventory and the issues touched here for body lines referencing the closed number, and update those bodies through the § 7.2 route or note the stale reference in a comment.

If a target is left with no remaining blocker and this audit created an issue covering the same domain, ask: "[ISSUE_ID] unblocked by cancellation of [ISSUE_ID]. Add blocker?" — that is a work decision. Execute approved additions.

For decision-eliminated or superseded cancellations, take the old pattern from `obsolete[].evidence.eliminated_pattern` or `supersedes[].reason`, check the parent and siblings (GitHub: the § 1.2.3 inventory) for non-cancelled issues whose title or description still names it, and ask "Update stale references?" before rewriting title or description and commenting `"Updated: [OLD] → [NEW] per [DECISION_ID]"`.

### 7.5 Post-Mutation Verification

Re-fetch every mutated issue and confirm state, labels, parent, project, relations, and description landed. Use only these commands — the Linear CLI has no `view` action; do not improvise one.

```bash
.agents/skills/linear/scripts/linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2] --format=safe
```

For a single Linear issue, `.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]` also works — mutations write through to the cache. GitHub, per issue:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,state,url
```

Report any mismatch between an approved action and the re-fetched state in § 8. Never silently accept one.

---

## 8. Report

<output_format>

### AUDIT COMPLETE — created [N] / closed [M]

**Tracker**: [linear | github ([OWNER/REPO])]

| Outcome | Count | Items |
|---------|-------|-------|
| Created | N | [ISSUE_IDS] |
| Cancelled | N | [ISSUE_IDS] |
| Modified | N | expand/update/combine |
| Corrections applied | N | labels, priorities, relations, hierarchy, project moves |
| Declined | N | — |
| Research refs | N | — |

**Degraded (github)**: [every obligation executed through a documented degradation, or omit this line]

**Mismatches**: [any § 7.5 discrepancy, or omit this line]
</output_format>

`created N / closed M` is the audit's headline. When M is 0 and N is not, say why the cancellation sweep found nothing.

## 9. Return State

**If managed**: return to the parent workflow's next section. **If standalone**: session complete.
