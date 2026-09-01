# Research Complete Workflow

Link completed research to the issues it unblocks, analyze its impact, record the decision, and create only the follow-up work that clears the creation bar.

`research-complete [ISSUE_ID]` → §§ 1-6.

## 1. Read the Research

Commit any uncommitted files under `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/`:

```bash
git add [RESEARCH_DOCS_PATH]/[ISSUE_ID]/ && git commit -m "chore([ISSUE_ID]): Add research findings"
```

This workflow updates labels, descriptions, and issue state, so it reconciles before its first cache read:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
```

Read `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md` and summarize the key findings. If it is missing, route back to `research-issue.md § 4` to run the research — never ask the user to execute it externally.

Capture the researcher metadata from `raw-exa.json` (`.metadata`: `researchMode`, `type`, `queryCount`, `sourceCount`, `uniqueSourceCount`, `elapsedMs`, `rawOutputPath`). Treat `agent:researcher` as the producer unless the issue history says otherwise.

## 2. Domain Labels

```bash
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Issue labels only, validated per [labels.md](../references/labels.md) § Validation; any failure there halts before mutation.

**Skip if** the issue already carries domain labels. Otherwise infer them from `findings.md` by matching component paths, compute `FINAL_LABELS = EXISTING + INFERRED` preserving unrelated labels, preflight, then `issues update [ISSUE_ID] --labels "[FINAL_LABELS]"`. When the domain is unclear or spans several, add every likely one.

## 3. Type

`## Creates Roadmap` in the description → Strategic (§ 5.3); 2+ domain labels → Pervasive (§ 5.2); 1 domain label → Targeted (§ 5.1). Routing uses the label count, not the description section.

## 4. Link to Blocked Issues

**Skip if** the `.blocks` array is empty (self-initiated spike).

For each blocked issue and, recursively, its children (`cache issues children [BLOCKED_ISSUE_ID] --recursive --format=safe | jq -r '.[].id'`): read the current description, skip when the findings path is already present, and otherwise put the research reference at the top. `--recursive` returns three levels; walk a deeper tree per [dependencies.md](../references/dependencies.md) § Reading a Full Subtree.

```markdown
**Research**: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md
```

With several references, convert to a bulleted list under one `**Research**:` header, still at the top, each line noting its topic.

## 5. Analyze Impact

Run exactly one flow, unless it escalates. Both flows fill the delegation the same way.

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.
`[DIR]` is the caller's own checkout, main checkout included.

### 5.1 Targeted

Delegate to the domain agent:

<delegation_format>
Analyze the impact of these research findings on your domain.

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.

Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

Report with tables:
- Decision content: summary, reasoning, revisit conditions
- Technical changes: | Type | Description | Est | Paths | QA triggers |
- Supersedes: topics or patterns this replaces
- Refactors (existing code referencing superseded patterns, independent of the new implementation): | Path | Old → New |
- Doc/config updates: | Path | Change |
- Cross-domain impact: yes/no and which domains
- Scope: refactor-level or initiative-level?

List a technical change only when it changes what a user or operator experiences, or blocks work that does. Say so plainly when the finding needs no work.
</delegation_format>

**Cross-domain impact reported** → add the new domain labels (compute the final set, preflight, update), append `## Affected Domains` to the description, and switch to § 5.2. Do not assess severity yourself.

**Initiative-level scope** (10+ issues, needs phasing) → ask the user "Research scope suggests a new initiative. Escalate to a roadmap?" On yes, append `## Creates Roadmap` and switch to § 5.3.

### 5.2 Pervasive

Delegate the same analysis to every affected domain agent in parallel, minus the cross-domain and scope questions. Then delegate the synthesis to the architecture review agent.

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.

<delegation_format>
Synthesize the domain reports into a cross-cutting impact analysis.

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.

Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

Domain reports:
[summaries]

Report with tables:
1. Unified decision content: summary, reasoning, revisit conditions
2. Documentation drift: | File | Issue | Severity |
3. Conflicting issues: | Issue | Conflict | Resolution |
4. Cross-module dependencies
5. Breaking changes at module boundaries
6. Prioritized issues: | # | Description | Est | Dependencies | Domain |
7. Scope: refactor-level or initiative-level?
</delegation_format>

Initiative-level scope escalates to § 5.3 the same way as § 5.1.

### 5.3 Strategic

`$FEATURE_NAME` is the issue title without the `Research:` prefix. `$ORIGIN_ISSUE` is the single entry in `.blocks` (fetch its id, title, and project); with zero or several blocked issues it is null.

Run `⤵ workflows/roadmap-plan.md $FEATURE_NAME @[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md --origin-issue $ORIGIN_ISSUE`, then `⤵ workflows/roadmap-create.md @[PLAN_PATH]`. § 6 then handles only the decision record and the doc updates.

## 6. Complete

### 6.1 Record the Decision

Follow the decider skill's create-decision workflow: `decisions next-id`, pick the template scale from `templates/decision-entry.md` (minimal for a single clear choice, standard for several alternatives, comprehensive for architecture-level work), and write `[project decision documents]/[DECISION_ID]-[DESCRIPTOR].md` per `schemas/decision-format.md`.

Carry the research path, a 1-2 sentence summary, the reasoning as bullets, the impact on existing and future work, and the revisit conditions. Add the INDEX.md row per `templates/index-row.md`.

When the new decision replaces specific components of an active decision without superseding it wholesale, update that decision's status to `Active ([COMPONENTS] → [NEW_DECISION_ID])` in both its file and its INDEX row.

### 6.2 Append the Decision to Blocked Issues

**Skip if** `.blocks` is empty. For each blocked issue and its recursive children, skip when `**Decision**: [DECISION_ID]` is already present; otherwise add `**Decision [DECISION_ID]**: [project decision documents]/[DECISION_ID]-[DESCRIPTOR].md` directly after the § 4 Research block.

### 6.3 Apply Doc and Config Updates

Implement the doc changes the agents reported: update the architecture docs, add decision references to affected files, and combine every domain's updates for a Pervasive flow. Reusable rules and project-specific insights go into the managing project's kendex config — `[skill-instructions]` for skill-level context, `[agent-additional-instructions]` for persistent agent rules, `[agent-launch-instructions]` for launch instructions. A config edit takes effect only once it is rendered: run `kendex refresh` from a checkout that permits it, which a worktree does not, so a worktree run leaves the edit in place and the rendered copies stale.

### 6.4 Decompose the Blocked Work

**Skip if** Strategic — roadmap-create already created the issues.

For each blocked issue, merge its existing `## Requirements`, the new requirements from the decision and agent reports, and drop the requirements the decision explicitly replaces. Each requirement is one bullet with a description, a domain, and an estimate. Apply the creation bar to every one: a requirement that changes nothing a user or operator experiences is dropped with a one-line note.

Agent-reported refactors go into the audit input as standalone items in step 7 below, not as blocked-issue requirements.

**Single domain** → write the requirements into the issue description (§ 6.5) and skip the rest of this section.

**2+ domains** → decompose every requirement, existing and new, into one sub-issue per domain, leaving the parent coordination-only:

1. One sub-issue per domain, in the parent's project, titled `[Domain verb]: [scope] for [DECISION_ID]`.
2. Full validated `labels[]` per sub-issue — `agent:[TYPE]` for the domain plus the required domain, stack, workflow, and classification labels, validated against the § 2 inventory before the file is written.
3. Blocking order between the sub-issues, recorded as `blocks_items`/`blocked_by_items`.
4. Supplementary findings fold into the sub-issue for their domain — never a separate issue for a small item in the same domain.
5. Build the audit input per [audit-issues-input.md](../schemas/audit-issues-input.md) with `source: "research-complete"`, `parent_issue` (the single blocked issue, else null), `worktree`, `blocked_issues`, `research_issue`, `research_ref`, `decision_ref`, and:

   `hierarchy_contract` (required when `parent_issue` is non-null): `mode: "decompose-under-parent"`, `parent_issue` = the blocked implementation issue, `child_indexes` = the `index` of every domain sub-issue from step 1 (exclude step 7 `origin: "discovered"` refactor items), `sequencing` = the order from step 3. The TPM MUST create every listed item as a same-project child of `parent_issue` and MUST NOT fold any domain back into the parent as its implementation leaf or spin it off standalone. Omit only when `parent_issue` is null — then `blocked_issues` acts as a hint.

6. Every `items[]` entry carries its full validated `labels[]`.
7. Add the agent-reported refactors as extra items with `origin: "discovered"`, no `blocks_items`/`blocked_by_items`, and NOT listed in `hierarchy_contract.child_indexes`.
8. Write `tmp/audit-research-YYYYMMDD-HHMMSS.json`, then run `⤵ workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.5`.

### 6.5 Update the Blocked Issues

For each blocked issue, keeping the Research and Decision references, the effort rollup, and the dependency lines:

- **Children were created** → apply [parent-issue-template.md](../templates/parent-issue-template.md): replace `## Requirements` with `## Sub-Issues` and `## Context`, and remove every implementation-level requirement. Set the parent's agent label to the project's multi-agent label when the children span 2+ agent domains (compute the final set, replace only the agent category, preflight, update), and clear the parent's estimate.
- **No children** → replace the vague summary with the concrete scope from the decision (1-2 sentences), add `## Requirements` with one bullet per deliverable, and add `## Context` with the key constraints and cross-references.

Adjust the estimate when the research materially changed the size of the work, and add domain labels for any cross-domain work it revealed.

### 6.6 Close Out

Comment on the research issue, omitting empty sections:

```markdown
## Research Complete

### Decision
[DECISION_ID] — [SUMMARY]
- **Researcher**: agent:researcher
- **Deep Research Metadata**: mode=[researchMode], type=[type], queries=[queryCount], sources=[uniqueSourceCount/sourceCount], raw=[path]
- **Reasoning**: [BRIEF_REASONING]
- **Revisit**: [CONDITIONS]

### Created Issues
- [CREATED_ISSUE_ID]: [TITLE] (P[N]) — [parent, or project when different]

### Doc Updates
- [PATH]: [CHANGE]

### Declined
- [ITEM]: [which creation-bar test it failed]
```

For informational research that produced no decision, replace the Decision section with `### Key Findings` (2-3 bullets) and `### Outcome` (what was learned or why no action is needed).

```bash
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "Done"
```

## 7. Return State

**If managed**: return to the parent workflow's next section. **If standalone**: session complete.
