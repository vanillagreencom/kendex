---
name: deep-research
description: "Exa-powered deep research for evidence-backed findings reports. Use for research tasks, architectural investigations, vendor/library comparisons, technology choices, and any workflow that needs a findings.md report. In Pi, prefer pi-web-tools web_research when available; in other harnesses, use the bundled script."
license: MIT
user-invocable: true
argument-hint: "report [query] --output findings.md"
dependencies:
  optional: [decider]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Deep Research

Use this skill for evidence-backed research reports, architectural investigations, vendor/library comparisons, technology choices, and workflow-owned `findings.md` reports.

## Harness Routing

| Running in | Preferred execution |
|---|---|
| Pi with `web_research` tool active | Use `web_research` with `outputPath` when creating a report. |
| Pi without active tool | Run `scripts/deep-research`. |
| Claude Code | Run `scripts/deep-research`; use `EXA_API_KEY`. |
| Codex | Run `scripts/deep-research`; use `EXA_API_KEY`. |
| OpenCode/Cursor | Run `scripts/deep-research`; use `EXA_API_KEY`. |

## Rules

- Always use Exa for deep research. Do not substitute general web search unless Exa is unavailable and the user explicitly approves a fallback.
- For workflow-owned research, write `findings.md` to the requested research docs path exactly.
- Include citations/source URLs in every findings report.
- Keep `findings.md` clean and human-readable; preserve raw Exa metadata in a sidecar JSON file (`findings.raw.json` by default when `--output findings.md` is used). Evidence excerpts must be sanitized so source Markdown headings do not render as large quoted headings.
- Once the requested report and raw sidecar exist, validate them and stop. Do not add local reproduction, benchmark, test, code-inspection, or implementation work unless the caller explicitly requested local validation in addition to Exa research.
- If `EXA_API_KEY` is missing, fail with clear setup instructions. `EXA_API_KEY` may be a direct key or a 1Password `op://vault/item/field` reference when the `op` CLI is installed and signed in.
- Use `--mode standard` by default. Use `--mode lite` for fast spikes and `--mode full` for strategic/high-risk decisions. Explicit `--type`, `--num-results`, and `--text-max-characters` override mode defaults.
- Use one adaptive findings format for all modes. The mode changes depth/source volume and Exa content settings, not the required report sections; record mode and source counts in `## Research Metadata`.
- In Pi, `web_research` uses Exa `/search` with deep search type, `systemPrompt`, text extraction, highlights, and, for `standard`/`full`, summaries plus structured `outputSchema`. `lite` avoids the default schema because live Exa `deep-lite` tests returned empty result sets when structured output was requested. Project/user settings may override mode profiles via `pi-web-tools.exaResearchModes`.

## Script Usage

```bash
skills/deep-research/scripts/deep-research report "question" --mode standard --output path/to/findings.md
skills/deep-research/scripts/deep-research report --query-file prompt.txt --context-glob 'context-*.md' --mode full --output findings.md
skills/deep-research/scripts/deep-research json "question" --output raw.json
skills/deep-research/scripts/deep-research doctor
```

Modes:

| Mode | Exa type | Default results | Text cap | Timeout | Notes |
|---|---|---:|---:|---:|---|
| `lite` | `deep-lite` | 15 | 10k chars/result | 5 min | Fast, lower-cost spikes. |
| `standard` | `deep-reasoning` | 50 | 16k chars/result | 10 min | Default workflow research. |
| `full` | `deep-reasoning` | 150 | 24k chars/result | 30 min | Runs primary query plus repeated `--additional-query`, then dedupes URLs. |

Common flags:

- `--mode lite|standard|full`
- `--research-mode lite|standard|full` (alias)
- `--type deep-reasoning|deep-lite|deep`
- `--output <path>`
- `--query-file <path>`
- `--context <path>` repeatable
- `--context-glob <glob>` simple sorted file glob, e.g. `context-*.md`
- `--system-prompt <path-or-text>`
- `--additional-query <query>` repeatable
- `--include-domain <domain>` repeatable
- `--exclude-domain <domain>` repeatable
- `--start-date YYYY-MM-DD`
- `--end-date YYYY-MM-DD`
- `--num-results <n>`
- `--text-max-characters <n>`
- `--raw-output <path>` (defaults to `findings.raw.json` next to `--output` for report mode)
- `--no-raw-output`
- `--timeout <seconds>`

## Findings Format

- Template: `templates/findings.md`
- Format checklist: `templates/findings-report-format.md` (this is a Markdown format guide, not a machine-readable schema)
- Required report sections: `Executive Summary`, `Key Findings`, `Evidence and Sources`, `Tradeoffs / Alternatives`, `Recommendation / Decision Criteria`, `Risks / Unknowns`, `Revisit Conditions`, and `Research Metadata`.
- Do not embed raw Exa JSON in `findings.md`. Store provider payloads in the sidecar JSON (`findings.raw.json` by default, or the explicit `--raw-output`/`rawOutputPath`).
