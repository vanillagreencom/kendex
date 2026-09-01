# Research Issue Workflow

Create a research issue, prepare its assets, and delegate execution to the researcher agent.

## Inputs

| Context | Source | Required |
|---------|--------|----------|
| `topic`, `questions`, `domains`, `project`, `type` | Caller | Yes |
| `blocked_issue` | Caller — the issue this research unblocks | No (spikes have none) |
| `prior_research` | Caller — findings extracted inline | No |
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
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and this inventory per [labels.md](../references/labels.md); do not assume the literal name `research` exists.

Build `VALIDATED_LABELS = [agent:researcher, RESEARCH_WORKFLOW_LABEL, DOMAINS...]` from issue labels only and validate it per [labels.md](../references/labels.md) § Validation; any failure there halts before mutation. A label the tracker lacks follows § Creating Labels in the same file.

### 1.2 Create

Write the description to a file, then:

```bash
.agents/skills/linear/scripts/linear.sh issues create \
  --title "Research: [TOPIC]" \
  --project "[PROJECT]" \
  --labels "[VALIDATED_LABELS]" \
  --state "Backlog" \
  --priority 2 \
  --estimate 1 \
  --description-file [BODY_FILE]
```

`--state "Backlog"` is mandatory, never the team-default Triage.

`[REACH]` is the ask, run, or decision that raised the question.

```markdown
**Reached by**: [REACH]

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

Capture the returned identifier as `[RESEARCH_ISSUE_ID]`. **Skip if** no `blocked_issue` — otherwise record the dependency as a relation, never as description text:

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [RESEARCH_ISSUE_ID] --blocks [BLOCKED_ISSUE_ID]
```

## 2. Prepare Assets

### 2.1 Consult Domain Agents

Map each domain label to its agent type (project-configurable) and delegate in parallel. This is asset preparation, not impact analysis (research-complete § 5).

Re-delegate to `[CONSULTATION_AGENT_NAME]` when the caller supplied one, omitting the reading block below. Otherwise start a fresh agent with the full block.

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.
`[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Research: [RESEARCH_ISSUE_ID] - [TOPIC]

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.

Blocked issue: [BLOCKED_ISSUE_ID]
Read it: `.agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID]`
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

Under `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/`:

- **prompt.txt** — research objective (one sentence), context summary (2-3 sentences), attached files with descriptions, the merged and prioritized questions, scope constraints, deliverables.
- **context-[topic].md** — the agents' extractions, fully self-contained. Every reference is resolved into the file: no doc paths, no issue IDs, no decision IDs, no "per project rules". "See docs/architecture/module.md" becomes the extracted content; "Reference [ISSUE_ID] findings" becomes the findings inline; "Message Bus Design (D001)" becomes "Message Bus Design". The researcher has no repository access.
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

Append the asset paths to the issue description and move it to Todo. Read the current description (`cache issues get [RESEARCH_ISSUE_ID] | jq -r '.description'`), append the block below, and apply it with `issues update [RESEARCH_ISSUE_ID] --description-file [BODY_FILE]` followed by `issues update [RESEARCH_ISSUE_ID] --state "Todo"`.

```markdown
## Assets
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md

## Output
Save findings to: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md

## Completion
`research-complete [RESEARCH_ISSUE_ID]`

## Researcher Execution
Run `[RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh`, or use Pi `web_research` with `queryFile`, `contextGlob`, `researchMode`, `outputPath`, and `rawOutputPath` set to the paths above.
```

## 4. Delegate to the Researcher

**If `auto_execute` is false**: present the issue and assets and stop, noting that the issue is labeled `agent:researcher` and ready.

Otherwise delegate to `researcher` (or `[RESEARCHER_AGENT_NAME]`).

Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.
`[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Research issue: [RESEARCH_ISSUE_ID] - [TOPIC]

Worktree: [WORKTREE_PATH]
Worktree Check: `pwd -P` before any repo-relative command. It must print [WORKTREE_PATH]; your shell can start in another lane's worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.

Read:
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md

Use the deep-research skill with Exa. Prefer Pi `web_research` with:
- `queryFile`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt
- `contextGlob`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-*.md
- `researchMode`: [RESEARCH_MODE]
- `outputPath`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md
- `rawOutputPath`: [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/raw-exa.json

If Pi `web_research` is unavailable, run [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh.

Requirements:
1. Exa deep research in mode `[RESEARCH_MODE]`, with citations and source URLs.
2. findings.md contains Executive Summary, Key Findings, Evidence and Sources, Recommendation / Decision Criteria, Risks / Unknowns, Revisit Conditions, and Research Metadata.
3. Raw Exa metadata goes to raw-exa.json. Keep findings.md clean — no embedded raw JSON.
4. Do not run local reproduction, benchmark, test, code-inspection, or implementation commands unless this delegation asks for local validation.
5. Do not change production code.
6. Return only after findings.md and raw-exa.json exist.
</delegation_format>

On return, verify both files exist, that every required section in findings.md is non-empty, and that no raw JSON block was embedded. Comment on the research issue with a concise summary, the findings path, the researcher identity, and the raw metadata path.

**If managed**: invoke `research-complete [RESEARCH_ISSUE_ID]` directly. **If standalone**: set the research issue Done after verification and present `research-complete [RESEARCH_ISSUE_ID]` as the next command.
