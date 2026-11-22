---
name: deep-research
description: "Load for research tasks, architectural investigations, and vendor, library, or technology comparisons."
summary: "Exa-powered deep research that produces an evidence-backed findings.md report."
license: MIT
user-invocable: true
argument-hint: "report [query] --output findings.md"
dependencies:
  required: [code-quality]
  optional: [decider]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [research]
---

# Deep Research

- In Pi with the `web_research` tool active, use that tool.
  - Pass `outputPath` when creating a report.
- In every other harness, run `scripts/deep-research` with `EXA_API_KEY` set, or with `KENDEX_KEY_FILE` naming a key file that holds it.

## Rules

- Exa is the research source. Substitute a general web search only when Exa is unavailable and the user approves the fallback.
- Write `findings.md` to the path the caller requested, exactly.
- Given no path, write it to `tmp/plans/<slug>-research.md`, never under a tracked `docs/` path. The full rule is `agents/planner.md` § Plan Artifacts.
- The report reaches other sessions as an attachment on its tracker issue.
- Research on building against another system is held to [code-quality § Over-Engineering](../code-quality/SKILL.md#over-engineering).
- Cite sources for material claims.
- Provider payloads go in the sidecar JSON, never inline. By default the sidecar sits beside the report, named as the report with `.raw.json` in place of its extension: `findings.raw.json` for `findings.md`.
- Sanitize evidence excerpts: source-page headings must not render as headings.
- Once the report and its sidecar exist, run `validate` and stop.
- A report written by hand on the approved fallback route has no sidecar: run `validate` on the report alone.
- Do no local reproduction, benchmarks, tests, code inspection or implementation unless the caller asked for it.

## Running

```bash
.agents/skills/deep-research/scripts/deep-research report "question" --mode standard --output path/to/findings.md
.agents/skills/deep-research/scripts/deep-research report --query-file prompt.txt --context-glob 'context-*.md' --mode full --output findings.md
.agents/skills/deep-research/scripts/deep-research json "question" --output raw.json
.agents/skills/deep-research/scripts/deep-research validate findings.md findings.raw.json
.agents/skills/deep-research/scripts/deep-research doctor
```

`deep-research help` lists the flags and mode settings.

The flags can override a mode's settings.

- Use `lite` for an evidence brief.
- `standard` and `full` request synthesized findings.
- Use `full` when the research needs a separate request for each additional query.

`--include-domain` is a hard host filter, not a quality filter: `--include-domain github.com` admits every repo on it and excludes everything else.

- Name authoritative projects and organizations in the query text for quality.
- Audit the returned source list either way.

## Validation

```bash
.agents/skills/deep-research/scripts/deep-research validate path/to/findings.md path/to/findings.raw.json
```

`validate` checks structure only. Read the report yourself:

- Find claims the cited sources contradict.
- Spot-check material numbers against the sidecar source text.
- Find off-topic sources that share an acronym or name with the subject.
- Find recommendations with no claim-level support in Evidence and Sources.
- Find results generalized past what the source established.

## Findings format

- `templates/findings.md` carries exactly the sections `validate` requires, in order.
- `Key Findings` holds distinct claims, not a restatement of the summary.
- Record mode and source counts in `## Research Metadata`.
