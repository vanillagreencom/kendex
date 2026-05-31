# Research Spike Workflow

Human-initiated research with full agent consultation and asset preparation.

## Inputs

| Context | Source | Required |
|---------|--------|----------|
| `topic` | User input (standalone) or caller context | Yes |
| `issue_id` | Caller context | No (standalone creates new) |
| `type` | Caller context | No (standalone discovers) |
| `project` | Caller context | No (standalone discovers) |

## 1. Discover Topic

### 1.1 Get Topic

Prompt user (plain text): **"What research are you conducting?"**

User provides 1-2 sentence description directly.

### 1.2 Ask Clarifying Questions

Ask user with relevant questions from:

| Category | Questions |
|----------|-----------|
| **Motivation** | What prompted this? (bug, feature, vendor update, curiosity) |
| **Scope** | "Should we?" vs "How do we?" |
| **Baseline** | Current state? (version, pattern, existing approach) |
| **Blockers** | What would make this a no-go? |

Select 2-3 most relevant questions. Adapt wording to topic. Infer research type from description.

### 1.3 Ask Topic-Specific Follow-ups

**Skip if** initial answers are sufficient.

Ask any additional clarifying questions needed before proceeding, based on topic and initial answers.

## 2. Check Stack & Prior Research

### 2.1 Identify Affected Domains

1. **Identify domains** from topic + answers -- infer from component paths (project-configurable).

2. **Present identified domains** with reasoning:
   ```
   Affected domains:
   * [DOMAIN] - [REASON]
   * [DOMAIN] - [REASON]

   Confirm? (Y/n/adjust)
   ```

3. **If user adjusts**, update list accordingly.

### 2.2 Check Related Research

1. **Resolve research issue label**:
   - Load issue-label inventory: `.agents/skills/linear/scripts/linear.sh cache labels list --format=safe`.
   - Load project taxonomy/application rules.
   - Resolve `RESEARCH_WORKFLOW_LABEL` to the project-configured issue label for completed research artifacts.
   - If no unambiguous assignable issue label exists, skip related-research lookup and continue to § 3 (do not query a hard-coded fallback label).

2. **Search for related research**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --max --search "[TOPIC_KEYWORDS]"
   ```

3. **If matches found**:
   1. **Read the findings file** - project research docs `[ISSUE_ID]/findings.md`
   2. **Extract ALL key findings** - summary paragraph, bullet lists, Go/No-Go sections
   3. **Set [PRIOR_RESEARCH]** - extracted findings for handoff in § 3.3

4. **Notify user**:
   ```
   Prior Research: [ISSUE_ID] - [TITLE]
   ```

## 3. Create Issue & Prepare Assets

Hand off to full research-issue workflow with context gathered above.

### 3.1 Query Active Project

```bash
PROJECT=$(.agents/skills/linear/scripts/linear.sh cache projects list --state started --first)
```

### 3.2 Determine Type from Domain Count

| Domain Count | Type |
|--------------|------|
| 1 | Targeted |
| 2+ | Pervasive |

User can override if scope warrants Strategic (initiative-level, 10+ issues).

### 3.3 Run Research-Issue Workflow

Run Workflow: `⤵ workflows/research-issue.md § 1-5 → § 4` with context:
- `topic`: from § 1.1
- `questions`: merged from § 1.2-1.3
- `domains`: confirmed labels from § 2.1
- `project`: from § 3.1
- `blocked_issue`: (none -- spike has no blocker)
- `type`: from § 3.2
- `prior_research`: extracted findings from § 2.2, or empty

## 4. Present to User

<output_format>

### 📚 RESEARCH SPIKE DELEGATED

| Field | Value |
|-------|-------|
| Issue | [RESEARCH_ISSUE_ID] - Research: [TOPIC] |
| Type | [TYPE] |
| Project | [PROJECT] |

### 🎯 AFFECTED DOMAINS

| Domain | Reason |
|--------|--------|
| ☑ [DOMAIN] | [REASON] |

### 📖 PRIOR RESEARCH REFERENCED

| Reference |
|-----------|
| → [prior issue]: [TITLE] |

### ✅ ASSETS CREATED

| Asset |
|-------|
| ✓ [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/prompt.txt |
| ✓ [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/context-[TOPIC].md |
| ✓ [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/run.sh |

### 🤖 RESEARCHER EXECUTION

| Field | Value |
|-------|-------|
| Owner | agent:researcher |
| Status | Delegated when auto_execute=true; otherwise ready for researcher |
| Output | [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md |

### 📋 NEXT STEPS

| # | Step |
|---|------|
| 1 | Review generated findings |
| 2 | Run or continue `research-complete [RESEARCH_ISSUE_ID]` if not already invoked |
| 3 | Approve follow-up work/decisions |
</output_format>

**END**: Research spike complete. Research is owned by `agent:researcher`; user reviews findings and continues `research-complete` if the managed workflow did not already invoke it.
