# Research Spike Workflow

User-initiated research: scope the question, gather prior work, then hand off to `research-issue`.

## 1. Scope the Question

Ask in plain text: **"What research are you conducting?"** Expect a 1-2 sentence description.

Then ask the 2-3 most relevant clarifying questions, worded for this topic — what prompted it (bug, feature, vendor change, curiosity), whether it is a "should we?" or a "how do we?", the current baseline (version, pattern, existing approach), and what would make it a no-go. Ask follow-ups only when the answers leave the scope ambiguous.

Infer the research type from the description and answers.

## 2. Domains and Prior Work

Infer the affected domains from the topic and answers by matching component paths (project-configurable). Domain inference is routing, not a product decision — do not ask the user to confirm it. State the domains and the reason for each in the § 4 report.

Look for prior research: resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and the live inventory (`cache labels list --format=safe`), then search it. Without an unambiguous assignable label, skip the lookup and continue — do not query a hard-coded fallback label.

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --max --search "[TOPIC_KEYWORDS]"
```

On a match, read `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md` and extract its full findings — summary, bullets, go/no-go — as `PRIOR_RESEARCH` for the handoff.

## 3. Hand Off

```bash
.agents/skills/linear/scripts/linear.sh cache projects list --state started --first
```

Type follows domain count: one domain is Targeted, two or more Pervasive. Strategic (initiative-level, 10+ issues) requires the user to say so.

Run `⤵ workflows/research-issue.md § 1-5 → § 4` with `topic` (§ 1), `questions` (§ 1), `domains` (§ 2), `project` (above), `type`, `prior_research` (§ 2, or empty), and no `blocked_issue` — a spike has no blocker.

## 4. Report

<output_format>

### RESEARCH SPIKE DELEGATED

| Field | Value |
|-------|-------|
| Issue | [RESEARCH_ISSUE_ID] — Research: [TOPIC] |
| Type | [TYPE] |
| Project | [PROJECT] |
| Owner | agent:researcher |
| Output | [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/findings.md |

**Domains**: [DOMAIN] — [REASON] (one line each)

**Prior research**: [ISSUE_ID] — [TITLE], or omit the line

**Assets**: prompt.txt, context-[TOPIC].md, run.sh under [RESEARCH_DOCS_PATH]/[RESEARCH_ISSUE_ID]/

**Next**: review the findings, then `research-complete [RESEARCH_ISSUE_ID]` if the managed flow did not already invoke it.
</output_format>
