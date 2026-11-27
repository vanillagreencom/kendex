# Issue Audit Workflow

Audit tracked issues and projects, apply mechanical corrections, and authorize creations and cancellations through § 6.

**Primary-session wrapper: never delegate this workflow itself.** Fleet ownership follows [skill-rules.md § Coordination](../../orch/references/skill-rules.md#coordination).

## Inputs

| Invocation | MODE | TARGET |
|------------|------|--------|
| `audit-issues project-order` | `project-order` | Project ordering and state transitions only |
| `audit-issues project` / `project "Name"` | `project` | Active project, or the named one |
| `audit-issues team` | `team` | Every Backlog/Todo/In Progress/In Review issue on the team |
| `audit-issues issue [ISSUE_ID] ...` | `issue` | Those issues |
| `audit-issues --issues [file]` | `issue` | Items from a JSON file per [audit-issues-input.md](../schemas/audit-issues-input.md) |
| `audit-issues --single [file]` | `single` | One item from such a file: creation bar, title duplicate check, label preflight and create, with no cancellation sweep |
| `audit-issues --analyzed [file]` | `analyzed` | Pre-analyzed [audit-output.md](../schemas/audit-output.md) issue-mode JSON |

- `analyzed` skips § 4.
- A `single` run performs no cancellation sweep. It can dispose only the filing's confirmed `supersedes[]` entries through § 7.2, with § 7.4 applying to its cancellations.
- `team` follows every `project`-mode rule in §§ 4-8, a rule added later included. Only a rule naming `team` overrides one.

---

## 1. Mode and Tracker

### 1.1 Parse Arguments

1. Set `MODE` and `TARGET` per the Inputs table.
2. For file modes, read the JSON and extract `source`, `parent_issue`, `tracker`, `worktree`, `items[]`.

### 1.2 Resolve Tracker

Resolve once, before any tracker command. Precedence:

1. The input file's `tracker` block — `tracker.type`, plus `tracker.repository` as `[OWNER/REPO]` for `github`.
2. A tracker passed by the calling workflow.
3. Inference: `parent_issue` (or the first target ID) starting with `issue-` → `github`, otherwise `linear`. For `github` with no repository, resolve it in the caller worktree:

   ```bash
   gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

Store as `TRACKER`, plus `[OWNER/REPO]` when `TRACKER=github`.

**Mode constraint**: `project`, `team`, and `project-order` are Linear only.

- With `TRACKER=github`, halt: "Project audits are Linear-only; GitHub repositories have no project inventory in this workflow."
- Never degrade to a partial project audit.

#### 1.2.1 Preflight — Linear (TRACKER=linear)

Only MODE `project` runs this read for § 3 fallback target resolution:

```bash
.agents/skills/linear/scripts/linear.sh session-status
```

MODE `team` and `issue` first bind the pass inventory:

- A caller that bound `[INVENTORY_FILE]` for its pass keeps that path for each run of the pass, as [Heartbeat audit](../../orch/references/heartbeat-audit.md) § Full audit binds one for its team and issue runs.
- Otherwise:
  1. Bind `[INVENTORY_FILE]` to `[WORKTREE_PATH]/tmp/inventory-[MODE]-YYYYMMDD-HHMMSS.json`, `[WORKTREE_PATH]` being the § 4.1 `Worktree:`.
  2. Create that `tmp/` if it is missing.
  3. Bind a path no earlier run wrote: a path another run wrote serves that run's older reading.

Every mode runs:

```bash
.agents/skills/linear/scripts/linear.sh labels list --max --format=safe
.agents/skills/orch/scripts/orch-runtime reconcile-items --inventory [INVENTORY_FILE]
```

- Run `orch-runtime reconcile-items` only where the orch skill is installed.
- Drop `--inventory [INVENTORY_FILE]` where it is unbound.
- Read `result.findings` and `result.lines` from its successful JSON reply and carry them into the audit as facts.
- A refused reply stops the audit until the failed read is fixed. Never rerun it without `--inventory`: the live listing would be a second reading.

The first read given `[INVENTORY_FILE]` collects the team into it: the pass's first reconciliation, or the TPM's first read where the orch skill is not installed. Every later read of the pass takes its rows from that file. § 4.1 hands the same path to the TPM, whose reads take their rows from that file ([tpm-audit § 1.1.2](tpm-audit.md#112-read-the-pass-inventory)).

#### 1.2.2 Preflight — GitHub (TRACKER=github)

```bash
gh label list --repo [OWNER/REPO] --limit 200 --json name,description
gh issue list --repo [OWNER/REPO] --state open --limit 200 --json number,title,labels
```

`--limit 200` is a stated cap, not a page: a repository whose label or open-issue count reaches 200 is audited against a truncated inventory.

- Scope the audit to what was fetched.
- Name the truncation on the § 8 degradation line.

### 1.3 Route

`project-order` → § 2 · `project` → § 3 · `team` → § 4 · `issue` → § 4 · `single` → § 4 · `analyzed` → § 5.

---

## 2. Project Order Audit

**Skip if** MODE is not `project-order`. Linear only.

### 2.1 Delegate

Spawn a one-shot `[TPM]` sub-agent (not a teammate — no re-delegation).

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the current repo root; project-order mode takes no input file.

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --project-order
Worktree: [WORKTREE_PATH]
</delegation_format>

### 2.2 Materialize and Present

Collect the artifact per § 4.2 step 1-2, then present:

<output_format>

### PROJECT ORDER AUDIT

| Initiative | Project | State | Layer | Pos | Reason |
|------------|---------|-------|-------|-----|-----------|
| [NAME] | [NAME] | [STATE] | L[N] | [CURRENT]→[RECOMMENDED] | [WHY] |

**Complete** (no open item left, needs state transition): [PROJECT] — unblocks [PROJECTS] [· ends_when holds: [ENDS_WHEN_EVIDENCE], for a deliverable]

**Held open** (no open item left, `ends_when` not shown to hold): [PROJECT] — ends when [ENDS_WHEN]

**Recommended next**: [PROJECT] — [REASON] [· waits for active project [BLOCKED_BY_ACTIVE]], or `None` with what blocks each candidate.
</output_format>

### 2.3 Apply and Activate

- Apply reorders and the `complete_candidates[]` completions without asking:

  ```bash
  .agents/skills/linear/scripts/linear.sh projects set-sort-order [PROJECT_ID] --position [NEW_SORT_ORDER]
  .agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state completed
  ```

- A `complete_held[]` project stays started.

**Skip if** `recommended_next.id` is null or `recommended_next.blocked_by_active` is set, the active project tpm-audit § 11 step 5 found. Otherwise:

1. Ask: `Activate [RECOMMENDED]` | other ready projects | `Skip`.
2. On activation, run:

   ```bash
   .agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started
   ```

3. Then ask "Continue to full audit of [PROJECT]?"
   - Yes sets MODE=project, TARGET=[PROJECT] → § 4.
   - No ends the workflow.

---

## 3. Resolve Project Target

**Skip if** MODE is `issue` or `team` — team audits the whole team and resolves no target. Linear only.

1. With `TARGET` set, use it.
2. Otherwise take the first `session-status.projects` entry with `has_active_work` that [project-map.md § Project kinds](../references/project-map.md#project-kinds) counts as the active project.
   - Read the team's projects first as that section says, with its team from `LINEAR_TEAM` ([project-map.md § Audit](../references/project-map.md#audit)).
   - `session-status` selects projects workspace-wide and reports no team, so confirm the chosen project belongs to the configured team before using it ([tracker-reads.md](../references/tracker-reads.md) § Scope by Path).
3. With no such project, take the first entry that counts as active, since it holds every other project from activation.
4. With none:
   1. Present the ready projects with their blockers.
   2. Ask which to activate. `Skip` ends the workflow.
   3. Activate the chosen one, then → § 4.

---

## 4. TPM Analysis

### 4.1 Delegate

**Authorized single filing.** A `single` item the owner or their delegate asked for, with its outcome, Done-when and `Reached by:` written and one landing ([filing.md § One landing per subsystem](../references/filing.md#one-landing-per-subsystem)), is judged in this session.

1. Run [tpm-audit § 14](tpm-audit.md#14-single-item-mode) here, with no subagent.
2. Carry its one row to § 5. § 4.2 does not apply.

Every other `single` item, and every other mode, delegates as below.

Spawn a one-shot `[TPM]` sub-agent (not a teammate).

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the input file's `worktree` when the invocation supplied one, the current repo root otherwise.

For `audit-issues issue [ISSUE_ID] ...`:

1. Write an [audit-issues-input.md](../schemas/audit-issues-input.md) file under that worktree's `tmp/`.
2. Set `source: "oversee"`, `parent_issue: null`, and `tracker` and `worktree` to the resolved values.
3. Keep every supplied ID in order as an existing-issue `items[]` entry.
4. Bind that path as `[FILE_PATH]`.
5. Delegate `--issues [FILE_PATH]`.

File invocations retain their supplied file.

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --project "[PROJECT_NAME]" | --team | --issues [FILE_PATH] | --single [FILE_PATH]
Worktree: [WORKTREE_PATH]
Tracker: [TRACKER] [OWNER/REPO]
</delegation_format>

- Omit `[OWNER/REPO]` when `TRACKER=linear`.
- When § 1.2.1 bound `[INVENTORY_FILE]`, append `--inventory [INVENTORY_FILE]` to `Arguments:`.

### 4.2 Collect and Validate

1. **Collect the payload.** The agent returns an `<output_format>` block with a `File:` line and fenced JSON.

2. **Materialize the artifact.** The caller worktree is the delegation's `Worktree:`, the input JSON's `worktree`, or the current repo root.
   1. Resolve the returned path under it. An absolute path outside the caller worktree is discarded for the fallback `tmp/audit-[MODE]-YYYYMMDD-HHMMSS.json`.
   2. With inline JSON present, ensure `tmp/` exists and write the inline JSON exactly to the resolved path.
   3. Without inline JSON, use the resolved path only if it already exists and is readable.
   4. If neither holds, halt and request a TPM rerun with inline JSON.
   5. Read the resulting file.

3. **Enforce the hierarchy contract** (issue mode with a `hierarchy_contract`; skip otherwise).
   - Every item whose `index` is in `hierarchy_contract.child_indexes` must have `action: "create"`, `hierarchy.action: "make_child"`, `hierarchy.parent` equal to the contract parent (or `null`, which § 7.2 resolves), and a recommended project matching the contract parent's.
   - Any covered item downgraded to `skip`/`expand`/`update`/`combine`/`cancel`, left at `hierarchy.action: none`, or parented elsewhere makes the output non-compliant.
   - Do NOT present or execute a non-compliant output. Halt and request a TPM rerun citing tpm-audit.md § 7.0, listing the violating items.

---

## 5. Present Findings

Two blocks, in this order.

- Omit empty sections.
- Keep each `Reason` to one line.

<output_format>

### AUDIT — [PROJECT, "Team", or "[N] item(s) from [SOURCE]"]

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

**Ready to schedule** ([N], project mode) — [ISSUE_ID]: blockers [CLEARED_BLOCKERS] all complete

**Gaps** ([N], project mode) — [SEVERITY] [COMPONENT]: [WHY], blocks [ISSUE_IDS]
</output_format>

In GitHub mode the Project column is `—` and hierarchy/relations render as the body-link forms from § 7.2 (`Parent: #N`, `Blocked by: #N`).

---

## 6. Approve Creations and Cancellations

```bash
.agents/skills/orch/scripts/orch-env PM_CREATE_AUTONOMY ask
```

- Accept `ask`, the caller default, or `auto`, which `ORCH_USER_MODE=ceo` composes when the settings ladder names neither.
- Stop on any other value.

The accepted creation set contains every bar-passing proposed creation in § 5, including architecture gaps. Cancel covers issue-mode `cancel`, `supersede`, `combine` and `supersedes[]`, plus project/team `obsolete[]`, `duplicates[]` and `combine[]` as defined in [audit-output.md](../schemas/audit-output.md).

**Auto.**

1. Authorize that set and every row in the displayed Cancel section without a question.
2. Keep declined entries declined.
3. Skip both follow-ups below and § 7.3.
4. Proceed to § 7.
5. Report the automatic actions and reasons in § 8.

**Ask.**

- Offer the same accepted creation set.
- Apply the rest of this section only in this mode.

**Fail closed without interactive capability.** Approval exists only as the user's in-session answers to the questions below, or as the carried roadmap-plan § 5 answer validated next.

- A primary session without an interactive multi-select MUST STOP here: return the § 5 findings and the audit JSON path, leaving § 7 unexecuted.
- No delegation prompt, scope reaffirmation, or follow-up message carries approval authority.

**Carried approval (roadmap-create only).** The roadmap-create wrapper alone sets `approved_at_plan_gate: true`, in this same session, after the user answered `Approve` at roadmap-plan § 5 for this plan. When the analyzed input carries it:

- The "Create these issues?" question is already answered for every `create` entry without `reapprove`.
- The question is asked only for entries marked `"reapprove": true` (changed since that answer).
- The flag has no authority from a subagent, another session, or any input file roadmap-create did not just write.
- Cancellations not already decided at roadmap-create § 2, declined follow-ups, and the fail-closed rule above stand in full.

Ask only about work, never about mechanics. Two multi-selects, each shown only when it has entries:

| Question | Options |
|----------|---------|
| "Create these issues?" | `#N: [TITLE]`, `All`, `None` |
| "Cancel these issues?" | `#N: [ISSUE_ID] — [KIND]`, `All`, `None` |

Two follow-ups, each conditional:

- Declined items exist → "Create any declined item anyway?" `#N: [TITLE]`, `None`.
- `research_ref` context was provided → "Add the research reference to these issues?" `[ISSUE_ID]: [TITLE]`, `All`, `None`.
  - Offer issues related to, overlapping with, or in the same domain as the research.

Everything in the § 5 corrections block — priorities, labels, relations, hierarchy, project moves, sort order, `update_parent_desc`, project state changes — is applied in § 7 without a question.

---

## 7. Execute

**Hard precondition: § 6 authorization obtained in the primary session.**

- Creations and cancellations execute only against its resolved `auto` policy or its `ask` approvals, including a validated carried approval (`approved_at_plan_gate`).
- If § 6 did not run, § 7 MUST NOT execute: stop and return to the primary session.

Apply [publish-artifacts.md](publish-artifacts.md) to each issue this section creates or updates.

- The artifact set is the audit JSON plus any supplied plan markdown, plan JSON, and cited research inputs.
- Resolve missing inputs before mutation.
- Skip this rule when the input's `source` is `roadmap-create`: that wrapper's § 5 publishes the plan set once, after every issue exists, and the audit JSON, a mechanical conversion of the plan JSON, is not published.
- An authorized single filing (§ 4.1) writes no audit JSON, so its set holds only the inputs supplied with it.

### 7.0 Label Preflight

Before any mutation that creates an issue or changes labels:

1. Build the intended operation per finding:
   - `create` and gap issues take the full `create_fields.labels[]`.
   - `agent_mismatch` is `replace_category` on `agent`.
   - `label_cooccurrence` is `add`.
   - A `label_updates[]` entry carries its own mode and category.
2. For an existing issue, fetch current labels and compute the full final set, preserving unrelated labels — Linear `issues get [ISSUE_ID]`, GitHub `gh issue view [N] --repo [OWNER/REPO] --json labels`.
3. Validate against the § 1.2 inventory and taxonomy per [labels.md](../references/labels.md) § Validation.
   - A label the tracker lacks follows § Creating Labels in the same file.
4. Pass only the validated final set: Linear `--labels`, GitHub `gh issue create --label` and the github skill's `label-add`/`label-remove`.

### 7.1 Apply Corrections

Execute every § 5 correction. Linear routes follow the Linear CLI's workflow-actions patterns:

| Finding | Pattern |
|---------|---------|
| `priority_misalignment` | `issues update [ID] --priority [P]` + reason comment |
| `agent_mismatch`, `label_cooccurrence` | § Labels (run § 7.0 first) |
| `add_relations`, `remove_relations` | § Hierarchy and Relations |
| `hierarchy` | § Hierarchy and Relations, then § Descriptions (parent rebuild) |
| `wrong_project` | `issues update [ID] --project "[TO_ID]"`, the finding's `to_id`, + reason comment |
| `project_dependency_issues`, `project_recommendations` | § Projects and Initiatives (project mode) |
| `project_needed`, `project_findings` | Reported in § 8, never applied: [project-map.md § Audit](../references/project-map.md#audit) |

A `hierarchy` `close_parent` closes through the verifier's route instead: `.agents/skills/orch/scripts/orch-runtime container-close . [ID]` from the checkout root.

- It derives the shared main repository itself.
- It keeps a parent with an open child as `deferred [ID...]`.
- It prints `closed [ID]`, `held [ID] [RESET]` or a `container-close: [KEY]` refusal on stderr.

GitHub routes carry their commands inline in § 7.2.

Order per issue: relations first, then priority and labels, then project/state, then sort order last.

### 7.2 Execute Approved Creations and Cancellations

- Process creates in dependency order: every issue after the issues it is blocked by and its parent.
- Attach each issue's relations and parent immediately after its own create, never after the whole batch.
- The route comes from `TRACKER`.

**Contract-parent scope transfer.** With a `hierarchy_contract`:

- Exclude its `parent_issue` from every supersession disposition, including carried or analyzed `supersedes[]` entries.
- Apply [tpm-audit § 7.0](tpm-audit.md#70-hierarchy-contract-binding)'s `related` scope-transfer representation instead.
- Never cancel or re-scope the contract parent here, or write it into a Completion block.
- The caller owns its coordination-only conversion after the audit.

**Project placement (Linear).**

- Each create passes `--project` with its target: its row's `project.recommended_id`, or `project_placement.target_project_id` on an architecture-gap row.
- A `project_needed` row is held, not created, and reported in § 8. It resumes once the project exists in Linear with its admission lines.

**Linear route (TRACKER=linear)**

| Action | Execution |
|--------|-----------|
| create | `issues create` with the Create template below, `--state "Backlog"`, and `--parent` per `hierarchy` |
| expand, update | workflow-actions § Descriptions + reason comment |
| supersede, combine | workflow-actions § State Transitions (cancel/absorb), then Superseded issues below |
| cancel | workflow-actions § State Transitions: disposition descendants before commenting and canceling the parent |
| skip, valid | No action outside the authorized Triage disposition in [Heartbeat audit](../../orch/references/heartbeat-audit.md) |

A Linear create:

- Backlog is mandatory, never the team-default Triage.
- A `hierarchy.parent` of null with `make_child` resolves to the input's `parent_issue`.
- A child must share the parent's project. If it cannot, create it standalone with `related`, except for `hierarchy_contract` items, where the standalone fallback is not permitted: create the child in the contract parent's project and never downgrade to standalone.
- [project-map.md § Routing](../references/project-map.md#routing) says how the parent's project is reached and when the fallback applies.

A `create` whose `create_fields.review_born` is true came from a review finding, and passes `--review-born` so the creation bar holds it to a reported `Symptom:` at priority 2:

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[TITLE]" --description-file [BODY_FILE] --project "[PROJECT_ID]" --labels "[VALIDATED_FINAL_LABELS]" --priority [PRIORITY] --review-born
```

A `create` whose `review_born` is false is the same command without that flag.

**GitHub route (TRACKER=github)**: `gh issue` against `[OWNER/REPO]`. Label mutations on existing issues go through the github skill's `label-add`/`label-remove`.

- **create:**
  1. Write the body to a tmp file.
  2. Run `gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body-file [BODY_FILE] --label "[VALIDATED_FINAL_LABELS]"`.
- **expand, update:**
  1. Fetch with `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`.
  2. Edit in a tmp file.
  3. Run `gh issue edit [N] --repo [OWNER/REPO] --body-file [BODY_FILE]`.
  - Title: `gh issue edit [N] --repo [OWNER/REPO] --title "[TITLE]"`.
  - Labels: `.agents/skills/github/scripts/github.sh label-add [N] "[LABEL]" --issue` / `label-remove`.
- **supersede, combine, cancel:**
  1. Run `gh issue comment [N] --repo [OWNER/REPO] --body "[REASON]"`.
  2. Then run `gh issue close [N] --repo [OWNER/REPO] --reason "not planned"`.

**Create template**: [issue-description-template.md](../templates/issue-description-template.md), or [parent-issue-template.md](../templates/parent-issue-template.md) for a bundle parent (`create_fields.is_bundle_parent: true`).

- Preserve the marked owner directive block in the returned `create_fields.description` unchanged when writing the body file. Never summarize it.
- In `analyzed` mode the create fields come from `issues[].create_fields`:
  - `create_fields.labels[]` is authoritative.
  - `source_path` supplies `[ORIGIN_CONTEXT]`.
  - `symptom` supplies `[SYMPTOM]`.
  - `review_born` decides the `--review-born` flag.
- A proposal-backed row also carries `source`, which must agree with `review_born` before execution.

**Supersession record.**

1. Before creating an issue, require § 6 authorization for every disposition its comparison requires, subject to Contract-parent scope transfer above.
2. If any required disposition is withheld, hold the create and its dependent dispositions, even when other entries remain authorized.
3. Report the held create and every withheld or unexecuted disposition in § 8 as not applied.
4. Resume only when every required disposition is authorized. Never replace a withheld action with a no-match record.

In the `**Supersession**:` line:

- Preserve entries for dispositions already executed or authorized to execute with the filing, including their timing.
- Leave withheld or held actions out of the actual-action record.
- Retain their not-applied outcomes in § 8.

**Superseded issues — Linear**: process every authorized `supersedes[]` entry after its replacement exists, including on a `create` row, subject to Contract-parent scope transfer above.

- For `when: now` (also the default when omitted), cancel it through workflow-actions § State Transitions, descendants first, with the comment `"Superseded by [ISSUE_ID]. [REASON]"`.
- For `when: partial`:
  1. Post the comment naming the replacement and transferred scope.
  2. Then use the expand/update Descriptions route above to retain only the remainder.
  3. Keep the named issue open.
- For `when: at-completion`:
  1. Write the exact Completion block from [audit-issues-input.md](../schemas/audit-issues-input.md#completion-block) into the replacement description, containing only those remaining entries.
  2. Add `issues add-relation [ISSUE_ID] --related [SUPERSEDED_ID]` for readers.
  3. Never cancel it at filing.
- An entry not confirmed by the TPM or held by authorization is not touched.

**GitHub degradation (explicit, never silent)**: GitHub has no bundle, typed-relation, project-state, or cascade model here.

- Represent structure in issue bodies:
  - `make_child` becomes a `Parent: #[N]` line in the template's Context section plus a comment on the parent.
  - Relations become `Blocks: #N` / `Blocked by: #N` / `Related: #N` lines maintained through the body-edit route.
- Supersession has no detach or cascade: enumerate any sub-items listed in the closed issue's body in the close comment.
- Apply `partial` through the body-edit route.
- For `at-completion`, retain the strict Completion block and report the automatic completion close as not executed: `linear.sh issues complete` has no GitHub counterpart here.
- Never drop an approved hierarchy or relation action. Either record its body representation or report it as not executed.
- List every degradation in § 8.

#### 7.2.1 Position in the Active Project

**Skip if** the analyzed input's `source` is `research-issue`. Keep its research issue in Backlog until research-issue § 3 publishes its assets and handles readiness.

**Linear only.** With `TRACKER=github`, record `positioning: n/a (github)` in § 8 and skip.

Once every create has landed and its relations and parent are attached, never per create, position each created issue in Todo unless any of these hold:

- The project state is not `started`.
- The issue's `blocked_by_open` names an issue in another project (linear references/writes.md § Blocked Label vs Issue Relations).
- It is P4 with no blocking relations.

```bash
.agents/skills/linear/scripts/linear.sh graphql --query 'query { project(id: "[PROJECT_ID]") { state } }' | jq -r '.project.state'
.agents/skills/linear/scripts/linear.sh issues list --project "[PROJECT]" --state "Todo" --max --format=safe | jq 'sort_by(.sort_order)'
.agents/skills/linear/scripts/linear.sh issues update [NEW_ID] --state "Todo" --sort-order [CALCULATED]
```

`sort_order`:

- 1000 below the first existing Todo of equal or lower priority.
- 1000 below any existing Todo this issue blocks. Blocking wins over priority.
- 1000 above the last Todo when this is the lowest priority.

### 7.3 Add Research References

**Skip if** no `research_ref` context. For each approved issue:

1. Read the current description (Linear `issues get [ISSUE_ID] | jq -r '.description'`, GitHub `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`).
2. Add or extend its research and decision references per [issue-description-template.md](../templates/issue-description-template.md) § Field Mapping and § Rules, using the parent's template for a container.
3. Preserve existing references.
4. Apply the § 7 artifact rule even when the reference already exists.

Propagate to children:

- Linear:
  1. Read `issues get [ISSUE_ID] | jq -r '.children[].id'`.
  2. Repeat per child.
  3. `issues get` returns three levels. Walk a deeper tree per [dependencies.md](../references/dependencies.md) § Reading a Full Subtree.
- GitHub has no recursive child query:
  - Propagate only to issues created in this audit carrying `Parent: #[N]`.
  - Report deeper propagation as not performed.

### 7.4 Post-Cancellation Cleanup

For each issue cancelled in § 7.1 or § 7.2:

**Linear**: a cancelled blocker leaves its targets' `blocked_by_open`.

**GitHub**: there are no relation objects.

1. Scan the § 1.2.2 inventory and the issues touched here for body lines referencing the closed number.
2. Update those bodies through the § 7.2 route, or note the stale reference in a comment.

If a target's `blocked_by_open` is left empty and this audit created an issue covering the same domain:

- Under `auto`, leave the blocker absent and report the candidate in § 8.
- Under `ask`, ask "[ISSUE_ID] unblocked by cancellation of [ISSUE_ID]. Add blocker?" and execute approved additions.

For decision-eliminated or superseded cancellations:

1. Take the old pattern from `obsolete[].evidence.eliminated_pattern` or `supersedes[].reason`.
2. Check the parent and siblings (GitHub: the § 1.2.2 inventory) for non-cancelled issues whose title or description still names it.
3. Under `auto`, leave these references unchanged and report them in § 8.
4. Under `ask`, ask "Update stale references?" before rewriting title or description and commenting `"Updated: [OLD] → [NEW] per [DECISION_ID]"`.

### 7.5 Post-Mutation Verification

Re-fetch every mutated issue and confirm state, labels, parent, project, relations, and description landed.

```bash
.agents/skills/linear/scripts/linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2] --format=safe
```

GitHub, per issue:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,state,url
```

Report any mismatch between an approved action and the re-fetched state in § 8. Never silently accept one.

---

## 8. Report

- Repeat cancellation, supersession, decline and deferred-cleanup bullets per entry.
- Omit empty categories.
- Include each absent identifier reported as not touched in a row's `reason`.
- Name each create's target project from the field its § 7.2 `--project` came from: `project.recommended` with `project.recommended_id`, or `project_placement.target_project` with `project_placement.target_project_id` on an architecture-gap row.

<output_format>

### AUDIT COMPLETE — created [N] / closed [M]

**Tracker**: [linear | github ([OWNER/REPO])]; **Authorization**: [all actual sources accepted by § 6, including carried roadmap-plan approval and new § 6 answers when combined; name PM_CREATE_AUTONOMY=auto when used]

| Outcome | Count | Items |
|---------|-------|-------|
| Created | N | [ISSUE_ID] in [TARGET_PROJECT] ([TARGET_PROJECT_ID]), one per create |
| Cancelled | N | [ISSUE_IDS] |
| Modified | N | expand/update/combine |
| Corrections applied | N | labels, priorities, relations, hierarchy, project moves |
| Declined | N | — |
| Research refs | N | — |

- Cancelled: [ISSUE_ID]: [REASON]
- Supersession: [SUPERSEDED_ID] → [REPLACEMENT_ID]: [now: cancelled | partial: re-scoped to REMAINDER | at-completion: completion block and related link recorded | not touched: REASON]
- Declined: [TITLE]: [REASON]
- Deferred cleanup: [candidate BLOCKER_ID for TARGET_ID: REASON, or stale reference ISSUE_ID: OLD PATTERN; not applied under auto]
- Project needed: [ISSUE_ID or TITLE]: [NAME] ([KIND]): [REASON], held until Linear holds the project
- Project finding: [KIND] [SUBJECT]

**Degraded (github)**: [every obligation executed through a documented degradation, or omit this line]

**Mismatches**: [any § 7.5 discrepancy, or omit this line]
</output_format>

- When M is 0 and N is not, say why the cancellation sweep found nothing.
- A `single` run always says it ran no sweep, whatever N and M are.

## 9. Return State

- **If managed**: return to the parent workflow's next section.
- **If standalone**: session complete.
