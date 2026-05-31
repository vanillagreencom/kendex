# Research Issue Workflow

Create research issue in issue tracker, prepare assets, and delegate execution to the researcher agent.

## Inputs

| Context | Source | Required |
|---------|--------|----------|
| `topic` | Caller (start § 3.3 or research-spike § 1.1) | Yes |
| `questions` | Caller (agent consultation or user input) | Yes |
| `domains` | Caller (list of domain labels) | Yes |
| `project` | Caller or query | Yes |
| `blocked_issue` | Caller (start § 2) | No (spikes have none) |
| `type` | Caller (Targeted/Pervasive/Strategic) | Yes |
| `prior_research` | Caller (research-spike § 2.2 findings) | No |
| `consultation_agent_name` | Caller (start § 3.3 agent name) | No |
| `researcher_agent_name` | Caller (existing researcher pane/session) | No |
| `auto_execute` | Caller (default true) | No |
| `research_paths` | Caller (project research docs paths) | No |
| `decision_ids` | Caller (DXXX references) | No |
| `batch_issues` | Caller (list of per-issue context: {topic, questions, domains, blocked_issue, type, consultation_agent_name, research_paths, decision_ids}) | No |

When `batch_issues` is set, single-issue fields are ignored. `project` is shared across all entries.

## 1. Create Issue

### 1.1 Batch Mode

**Skip if** `batch_issues` not set → use single-issue fields

For each entry in `batch_issues`, run § 1.2-1.4 with that entry's fields. Collect `[RESEARCH_ISSUE_ID]` per entry. After loop → § 2 with all collected IDs.

### 1.2 Validate Inputs

Confirm all required variables are set. If [TYPE] not provided, determine from [DOMAINS]:

| Domain Count | Type |
|--------------|------|
| 1 | Targeted |
| 2+ | Pervasive |

Strategic requires explicit caller designation (initiative-level scope).

Load issue-label inventory and project taxonomy per [labels.md](../references/labels.md):

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy/application rules and live issue-label inventory. It is the project-configured workflow/classification label for research issues; do not assume the literal name `research` exists.

Build `VALIDATED_LABELS = ["agent:researcher", RESEARCH_WORKFLOW_LABEL, DOMAINS...]` using issue labels only. Validate that:
- `agent:researcher` exists in live issue-label inventory and is not a parent/group label.
- `RESEARCH_WORKFLOW_LABEL` exists in live issue-label inventory, is assignable to issues, and satisfies the project-configured research workflow/classification category.
- Every `[DOMAINS]` entry exists as an issue label and satisfies the taxonomy domain/category rules.
- Required categories and exclusivity rules pass.

If any label is missing or invalid, halt before create. If a required taxonomy label is missing from Linear, report it and ask for explicit user authorization before creating it; do not create labels automatically.

Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation.

### 1.3 Create Issue

Create issue using input variables.

```bash
.agents/skills/linear/scripts/linear.sh issues create \
  --title "Research: [TOPIC]" \
  --project "[PROJECT]" \
  --labels "[VALIDATED_LABELS]" \
  --priority 2 \
  --estimate 1 \
  --description "[DESCRIPTION]"
```

**[DESCRIPTION]** template:
```
## Summary
[1-2 sentence summary of TOPIC]

## Questions
[QUESTIONS]
[TYPE_SECTION]
## Expected Decision
Next available DXXX via `.agents/skills/decider/scripts/decisions next-id` (decider skill)

## Researcher Execution
Use the deep-research skill with Exa. Run mode `[RESEARCH_MODE]` (`standard` by default; `full` for Strategic/high-risk/pervasive decisions). Write clean findings to `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md` and raw metadata to `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json`.
```

**[TYPE_SECTION]** — insert based on [TYPE]:

| Type | Section |
|------|---------|
| Targeted | (omit) |
| Pervasive | `## Affected Domains` with domain list and reasons |
| Strategic | `## Creates Roadmap` with scope and phases |

Capture returned identifier as `[RESEARCH_ISSUE_ID]`.

### 1.4 Add Blocking Relation (if applicable)

**Skip if** [BLOCKED_ISSUE_ID] not set (self-initiated spike).

Blocking relations are managed via the issue tracker's relation system -- never via description text.

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [RESEARCH_ISSUE_ID] --blocks [BLOCKED_ISSUE_ID]
```

CLI enforces same-project constraint for blocking relations.

Asset paths added in § 3 after preparation.

---

## 2. Prepare Assets

Gather domain-specific context for the research prompt.

### 2.1 Batch Mode

**Skip if** single issue

Apply § 2.2 mapping per issue. Spawn § 2.3 consultations for ALL issues in parallel (one sub-agent per {issue, domain} pair). Collect results, then run § 2.4-2.5 per issue sequentially. After all → § 3.

### 2.2 Map Domain Agents

Map domain labels to agent types -- infer from component paths (project-configurable).

### 2.3 Consult Domain Agents (Parallel)

**Purpose**: Asset preparation — gather context for research prompt. NOT impact analysis (that happens in research-complete § 5).

**Delegate to each domain agent** from § 2.2 (parallel sub-agent calls).

#### If `consultation_agent_name` set (from start § 3.3)

Re-delegate to the existing consultation agent `[CONSULTATION_AGENT_NAME]` — it retains full context from the initial consultation. Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Research issue created: [RESEARCH_ISSUE_ID] - [TOPIC]

Draft your domain's contribution for the research assets:
1. Precise questions from your domain perspective
2. Context to extract from your docs (inline, no external refs)
3. Scope constraints from your expertise
4. Relevant prior decisions or patterns

Reply with structured sections for each item.
</delegation_format>

#### If no `consultation_agent_name` (spike, multi-domain, or agent terminated)

Start fresh with full context. **Delegation prompt:** Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Research: [RESEARCH_ISSUE_ID] - [TOPIC]

Blocked Issue: [BLOCKED_ISSUE_ID]
Read blocked issue context: `.agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID]`

Read: [RESEARCH_PATHS]
Read: [project decision documents]/INDEX.md
Read: [project decision documents]/[DECISION_ID]-*.md
Prior findings (inline):
[PRIOR_RESEARCH]

Read relevant architecture docs and in-project code for context.

Draft your domain's contribution:
1. Precise questions from your domain perspective
2. Context to extract from your docs (inline, no external refs)
3. Scope constraints from your expertise
4. Relevant prior decisions or patterns

Reply with structured sections for each item.
</delegation_format>

### 2.4 Assemble Assets

Create project research docs directory for `[RESEARCH_ISSUE_ID]/`:

**prompt.txt** - Merge agent questions into structured prompt:
- Research objective (1 sentence)
- Context summary (2-3 sentences)
- Attached files list with descriptions
- Questions (prioritized, merged from agents)
- Scope constraints
- Deliverables

**context-{topic}.md** - From agent extractions:
- Self-contained (no external references, no issue IDs, no file paths)
- Include prior research findings inline if referenced
- Extract relevant architecture content directly
- Ensure the researcher agent has all necessary context to execute the research effectively. If there is anything they need to know, add it.

Determine `[RESEARCH_MODE]` before writing commands:

| Type | Default mode |
|------|--------------|
| Targeted | `standard` |
| Pervasive | `standard` unless risk is high, then `full` |
| Strategic | `full` |

**run.sh** - Generated executable command helper:
```bash
#!/usr/bin/env bash
set -euo pipefail
.agents/skills/deep-research/scripts/deep-research report \
  --query-file "[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt" \
  --context-glob "[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md" \
  --mode "[RESEARCH_MODE]" \
  --output "[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md" \
  --raw-output "[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json"
```

Also write `command.txt` with the same command if executable bits are not preserved by the harness.

### 2.5 Validate Self-Containment

| Bad | Good |
|-----|------|
| "See docs/architecture/module.md" | Extract content into context file |
| "Reference [ISSUE_ID] findings" | Include findings inline |
| "per project rules" | State the rule directly |
| "Message Bus Design (D001)" | "Message Bus Design" |

---

## 3. Complete

Assets complete. Update issue description with asset paths, then set state to Todo.

**If batch**: Repeat per issue. After all: "Research assets ready for [ID1], [ID2], ...".

1. **Get current description**: `.agents/skills/linear/scripts/linear.sh cache issues get [RESEARCH_ISSUE_ID] | jq -r '.description'`

2. **Append to description**:
   ```
   ## Assets
   - [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
   - [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md

   ## Output
   Save findings to: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md

   ## Completion
   `research-complete [RESEARCH_ISSUE_ID]`

   ## Researcher Execution
   Run `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh` or use Pi `web_research` with `queryFile`, `contextGlob`, `researchMode`, `outputPath` set to `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md`, and `rawOutputPath` set to `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json`.
   ```

3. **Update**: `.agents/skills/linear/scripts/linear.sh issues update [RESEARCH_ISSUE_ID] --description "[FULL_DESCRIPTION]"`

4. **Set state**: `.agents/skills/linear/scripts/linear.sh issues update [RESEARCH_ISSUE_ID] --state "Todo"`

Present to user: "Research assets ready for [RESEARCH_ISSUE_ID]".

---

## 4. Delegate to Researcher

**If `auto_execute` is false**: Present the issue/assets and stop. Tell the caller the issue is labeled `agent:researcher` and ready for researcher execution.

Otherwise delegate to `researcher` (or `[RESEARCHER_AGENT_NAME]` when provided). Use the exact self-contained prompt below. Fill placeholders and omit empty lines only.

<delegation_format>
Research issue: [RESEARCH_ISSUE_ID] - [TOPIC]

Read:
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md

Use the deep-research skill with Exa. Prefer Pi `web_research` with:
- `queryFile`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- `contextGlob`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md
- `researchMode`: [RESEARCH_MODE]
- `outputPath`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md
- `rawOutputPath`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json

If Pi `web_research` is unavailable, run `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh`.
Write findings to:
[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md

Requirements:
1. Use Exa deep research with mode `[RESEARCH_MODE]`.
2. Include citations/source URLs.
3. Include executive summary, key findings, evidence and sources, recommendation/decision criteria, risks, and revisit conditions.
4. Save raw Exa metadata to `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json`.
5. Keep `findings.md` clean; do not embed raw JSON or fenced raw metadata.
6. Do not run local reproduction, benchmark, test, code-inspection, or implementation commands unless this delegation explicitly requests local validation in addition to Exa research.
7. Do not change production code.
8. Return only after findings.md and raw-exa.json exist.
</delegation_format>

After researcher returns:

1. Verify `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md` exists.
2. Verify it has non-empty `Executive Summary`, `Key Findings`, `Evidence and Sources`, `Recommendation / Decision Criteria`, `Risks / Unknowns`, `Revisit Conditions`, and `Research Metadata` sections, and does not contain embedded raw JSON blocks.
3. Add a comment to the research issue with a concise summary, findings path, researcher identity, and raw metadata path when present.
4. If this workflow is running inside a managed parent orchestration flow, directly invoke `research-complete [RESEARCH_ISSUE_ID]`. If standalone, set the research issue Done only after verification and present the next command: `research-complete [RESEARCH_ISSUE_ID]`.

---

## 5. Asset Quality Checklist

- [ ] prompt.txt follows project research prompt template
- [ ] All context files are self-contained
- [ ] No external references in any file
- [ ] Questions refined by domain agents
- [ ] Deliverables are specific and actionable
- [ ] run.sh or command.txt invokes deep-research with prompt/context-glob/mode/output/raw-output paths
- [ ] Delegation prompt is self-contained

## 6. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — research issue created and delegated, or ready for researcher if `auto_execute=false`.
