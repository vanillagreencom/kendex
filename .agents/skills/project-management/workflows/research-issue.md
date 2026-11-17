# Research Issue Workflow

Create a research issue, prepare its assets, and delegate execution to the researcher agent.

## Inputs

| Context | Source | Required |
|---------|--------|----------|
| `topic`, `questions`, `domains`, `project`, `type` | Caller | Yes |
| `blocked_issue` | Caller — the issue this research unblocks | No (spikes have none) |
| `prior_research` | Caller — findings extracted inline | No |
| `prior_work` | Caller — already-read comparison rows, actual search terms, scope evidence and proposed dispositions from discovery | Yes |
| `consultation_agent_name` | Caller — an agent that already holds the context | No |
| `researcher_agent_name` | Caller — an existing researcher session | No |
| `auto_execute` | Caller, default true | No |
| `research_paths`, `decision_ids` | Caller | No |
| `batch_issues` | Caller — per-issue context for several research issues at once | No |

With `batch_issues` set, the single-issue fields are ignored and `project` is shared across entries. Run § 1 per entry, spawn every § 2 consultation in parallel across all entries, then run §§ 2.4-3 per issue.

Type follows domain count when the caller did not supply one: 1 domain is Targeted, 2+ Pervasive. Strategic requires explicit caller designation.

## 1. Create the Issue

### 1.1 Validate Labels

```bash
.agents/skills/linear/scripts/linear.sh labels list --max --format=safe
```

Resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and this inventory per [labels.md](../references/labels.md); do not assume the literal name `research` exists.

Build `VALIDATED_LABELS = [agent:researcher, RESEARCH_WORKFLOW_LABEL, DOMAINS...]` from issue labels only and validate it per [labels.md](../references/labels.md) § Validation; any failure there halts before mutation. A label the tracker lacks follows § Creating Labels in the same file.

### 1.2 Resolve Prior Work and Create

Use `prior_work` from discovery without another search or inventory read. Resolve the filing through the existing [audit-issues.md](audit-issues.md) authorization and execution owner:

| Comparison outcome | Filing route |
|---|---|
| Existing research covers the question | Return its identifier and available findings as covering work. Create no replacement and stop before § 2. |
| New research replaces or transfers an open item's scope | Carry the confirmed `supersedes[]` entries, reasons and `when` into the analyzed create row. audit-issues §§ 6–7.2 owns authorization, reciprocal records and execution. |
| No open item needs a disposition | The create row records `none found; searched: [TERMS]` using the actual discovery terms. A separate related match remains related, without an action claim. |
| Creation or a disposition is withheld, or execution fails | Return the audit writer's held/not-applied result and any applied outcomes. Continue to assets only when its authorized filing and dispositions succeeded. |

Build one issue-mode [audit-output.md](../schemas/audit-output.md) row with `action: "create"`, `identifier: null`, the research title, recommended project and `create_fields`: full validated labels, priority 2, estimate 1, `review_born: false`, the ask/run/decision as `reach`, and the topic and questions as description and recommendation. Its `supersession` follows that schema from the carried comparison and proposed `supersedes[]`; it is not evidence that those actions already ran. Fill Story and Why this matters following [issue-description-template.md](../templates/issue-description-template.md) § Field Mapping and § Rules. Use the research-specific content below in the body that audit-issues § 7.2 writes.

Set its `index` to 1 and wrap it as `{"mode": "issue", "source": "research-issue", "issues": [row]}`. Write this analyzed input to `tmp/audit-research-[SLUG].json` and run `⤵ workflows/audit-issues.md --analyzed tmp/audit-research-[SLUG].json § 5-9 → § 1.3`. Do not carry a roadmap approval flag. A denied creation or withheld disposition follows that owner's held/not-applied outcome; never substitute a no-match record for a refused action, create directly, or prepare/delegate assets for a held filing.

### 1.3 Continue After Filing

Continue only with the identifier of a successfully created issue and confirmed authorized outcomes from audit-issues. A failed or incomplete disposition stops here with that owner's diagnostic and applied outcomes preserved. The audit writer supplies `[SUPERSESSION]` from its execution result; `[REACH]` is the ask, run, or decision that raised the question.

```markdown
> **Story:** [Who needs this research.] [What they cannot decide today.] [What the findings let them decide, and its consequence.]

> **Why this matters:** [The cost of leaving the question unanswered, and the benefit of deciding with evidence.]

## Filing record

**Reached by**: [REACH]

**Supersession**: [SUPERSESSION]

## Summary
[1-2 sentences on TOPIC]

## Questions
[QUESTIONS]
[TYPE_SECTION]
## Expected Decision
Next available ID via `.agents/skills/decider/scripts/decisions next-id`
```

Execution and output sections are appended in § 3.

`[TYPE_SECTION]`: omitted for Targeted; `## Affected Domains` with each domain and its reason for Pervasive; `## Creates Roadmap` with scope and phases for Strategic.

Keep the audit writer's created identifier as `[RESEARCH_ISSUE_ID]`. **Skip if** no `blocked_issue` — otherwise record the dependency as a relation, never as description text:

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [RESEARCH_ISSUE_ID] --blocks [BLOCKED_ISSUE_ID]
```

## 2. Prepare Assets

### 2.1 Consult Domain Agents

Map each domain label to its agent type (project-configurable) and delegate in parallel. This is asset preparation, not impact analysis (research-complete § 5).

Re-delegate to `[CONSULTATION_AGENT_NAME]` when the caller supplied one, omitting the reading block below. Otherwise start a fresh agent with the full block.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Research: [RESEARCH_ISSUE_ID] - [TOPIC]

Worktree: [WORKTREE_PATH]

Blocked issue: [BLOCKED_ISSUE_ID]
Read it: `.agents/skills/linear/scripts/linear.sh issues get [BLOCKED_ISSUE_ID]`
Read: [RESEARCH_PATHS]
Read: [project decision documents]/INDEX.md
Read: [project decision documents]/[DECISION_ID]-*.md
Read the relevant architecture docs and in-project code for context.

Prior findings (inline):
[PRIOR_RESEARCH]

Draft your domain's contribution:
1. Precise questions from your domain perspective
2. Context to extract from your docs, inline, with no external references
3. Scope constraints from your expertise
4. Relevant prior decisions or patterns

Reply with a structured section per item.
</delegation_format>

### 2.2 Assemble

`[RESEARCH_DOCS_PATH]` is the research directory [SKILL.md § Planning artifacts](../SKILL.md#planning-artifacts) defines. Under `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/`:

- **prompt.txt** — research objective (one sentence), context summary (2-3 sentences), attached files with descriptions, the merged and prioritized questions, scope constraints, deliverables.
- **context-[topic].md** — the agents' extractions, fully self-contained. Every reference is resolved into the file: no doc paths, no issue IDs, no decision IDs, no "per project rules". "See docs/architecture/module.md" becomes the extracted content; "Reference [ISSUE_ID] findings" becomes the findings inline; "Message Bus Design ([DECISION_ID])" becomes "Message Bus Design". The researcher has no repository access.
- **run.sh** (and `command.txt` with the same command):

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

`[RESEARCH_MODE]` is `standard` for Targeted, `standard` for Pervasive unless the risk is high, and `full` for Strategic or high-risk work.

## 3. Publish the Assets

Read the current description (`issues get [RESEARCH_ISSUE_ID] | jq -r '.description'`) and append the block below. Expand the context glob and append both run assets so Assets lists one concrete repository path per § 2 file. Apply it with `issues update [RESEARCH_ISSUE_ID] --description-file [BODY_FILE]`, then publish every prepared asset through [publish-artifacts.md](publish-artifacts.md). Only after attachment and description writes succeed, run `issues update [RESEARCH_ISSUE_ID] --state "Todo"`.

```markdown
## Assets
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md

## Output
Save findings to: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md

## Completion
`research-complete [RESEARCH_ISSUE_ID]`

## Researcher Execution
Before either execution route, use existing local assets first. For each absent file in Assets, find it on [RESEARCH_ISSUE_ID] by the route the project-management skill's SKILL.md § Planning artifacts gives, create its parent directories inside this checkout, and copy the resolved bytes to its listed repository path. Stop on any lookup or copy failure before starting research. Use the deep-research skill with Exa. Prefer Pi `web_research`, taking `queryFile`, `contextGlob`, `researchMode`, `outputPath`, and `rawOutputPath` from `command.txt`'s `--query-file`, `--context-glob`, `--mode`, `--output`, and `--raw-output` arguments respectively. If Pi is unavailable, run `bash [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh`.
```

## 4. Delegate to the Researcher

**If `auto_execute` is false**: present the issue and assets and stop, noting that the issue is labeled `agent:researcher` and ready.

Otherwise delegate to `researcher` (or `[RESEARCHER_AGENT_NAME]`).

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Research issue: [RESEARCH_ISSUE_ID] - [TOPIC]

Worktree: [WORKTREE_PATH]

Read the research issue and follow its Researcher Execution section.

Requirements:
1. Exa deep research in mode `[RESEARCH_MODE]`, with citations and source URLs.
2. findings.md contains Executive Summary, Key Findings, Evidence and Sources, Recommendation / Decision Criteria, Risks / Unknowns, Revisit Conditions, and Research Metadata.
3. Raw Exa metadata goes to raw-exa.json. Keep findings.md clean — no embedded raw JSON.
4. Do not run local reproduction, benchmark, test, code-inspection, or implementation commands unless this delegation asks for local validation.
5. Do not change production code.
6. Return only after findings.md and raw-exa.json exist.
</delegation_format>

On return, verify both files exist, that every required section in findings.md is non-empty, and that no raw JSON block was embedded. Apply [publish-artifacts.md](publish-artifacts.md) before reporting the result. Comment on the research issue with a concise summary, the findings path, the researcher identity, and the raw metadata path.

**If managed**: invoke `research-complete [RESEARCH_ISSUE_ID]` directly. **If standalone**: set the research issue Done after verification and present `research-complete [RESEARCH_ISSUE_ID]` as the next command.
