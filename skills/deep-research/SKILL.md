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

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

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
- Once the requested report and raw sidecar exist, run `deep-research validate <findings.md> <findings.raw.json>` (see § Validation) and stop. Do not add local reproduction, benchmark, test, code-inspection, or implementation work unless the caller explicitly requested local validation in addition to Exa research.
- If `EXA_API_KEY` is missing, fail with clear setup instructions. `EXA_API_KEY` may be a direct key or a 1Password `op://vault/item/field` reference when the `op` CLI is installed and signed in.
- Use `--mode standard` by default. Use `--mode lite` for fast spikes and `--mode full` for strategic/high-risk decisions. Explicit `--type`, `--num-results`, and `--text-max-characters` override mode defaults.
- Use one adaptive findings format for all modes. The mode changes depth/source volume and Exa content settings, not the required report sections; record mode and source counts in `## Research Metadata`.
- In Pi, `web_research` uses Exa `/search` with deep search type, `systemPrompt`, text extraction, highlights, and, for `standard`/`full`, summaries plus structured `outputSchema`. `lite` avoids the default schema because live Exa `deep-lite` tests returned empty result sets when structured output was requested. Project/user settings may override mode profiles via `pi-web-tools.exaResearchModes`.

## Script Usage

```bash
skills/deep-research/scripts/deep-research report "question" --mode standard --output path/to/findings.md
skills/deep-research/scripts/deep-research report --query-file prompt.txt --context-glob 'context-*.md' --mode full --output findings.md
skills/deep-research/scripts/deep-research json "question" --output raw.json
skills/deep-research/scripts/deep-research validate findings.md findings.raw.json
skills/deep-research/scripts/deep-research doctor
```

Modes (Exa `/search` caps: `numResults` 1-100, `text.maxCharacters` 1-10000, `additionalQueries` max 10):

| Mode | Exa type | Default results | Text cap | Timeout | Synthesis | Notes |
|---|---|---:|---:|---:|---|---|
| `lite` | `deep-lite` | 15 | 10k chars/result | 5 min | Not requested (no `outputSchema`) — evidence brief only. | Fast, lower-cost spikes. |
| `standard` | `deep-reasoning` | 50 | 10k chars/result | 10 min | Requested via `outputSchema`. | Default workflow research. |
| `full` | `deep-reasoning` | 100 | 10k chars/result | 30 min | Requested via `outputSchema`, per query. | Fans out one Exa request per query (primary + each `--additional-query`), then dedupes URLs. |

`--additional-query` semantics (recorded in metadata — verify with `validate`):

| Mode | How expansions are applied | Sidecar `additionalQueriesApplied` |
|---|---|---|
| `lite` / `standard` | Sent as Exa `additionalQueries` in the single request; consumed by deep search types as query variations. | `provider-additional-queries` |
| `full` | One separate Exa request per query; URLs deduped across responses. | `local-fan-out` |

Sidecar metadata records `queryCount` (distinct queries: 1 primary + additional), `requestCount` (Exa API calls), the `additionalQueries` list, and `synthesis` (whether a synthesized answer came back).

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

## Task-Type Recipes

| Research need | Flags | Caveats |
|---|---|---|
| Technical decision synthesis (algorithm/library choice needing a recommendation) | `--mode standard` (or `full` for high-risk); name authoritative papers/orgs in the query; 1-2 `--additional-query` variants | Audit the source list for off-topic same-acronym papers and low-signal repos; `validate` cannot catch claim-vs-source contradictions. |
| Targeted evidence brief (collect primary sources, you synthesize) | `--mode lite --include-domain <host>` per authoritative host, `--num-results 15-25` | `lite` requests no synthesis — expect an evidence brief. Do not use when the deliverable is a recommendation; `validate` warns on this. |
| Broad landscape / vendor comparison | `--mode full`, one `--additional-query` per vendor/angle (max 10) | Breadth trades precision for coverage; expect marketing pages and duplicates — cut them during review. |
| Current docs / API research | `--mode standard --include-domain <official-docs-host> --start-date <recent>` | Domain filter plus date window keeps results to current official docs; verify version applicability in the report. |

## Choosing Flag Values

- `--num-results`: more results = more noise exposure, not better synthesis. 10-25 for targeted questions; 50 (standard default) for decision research; 100 only for landscape scans where you will prune sources.
- `--text-max-characters`: caps extracted text per result (Exa max 10000). Lower it (2000-4000) when many sources are expected and only key claims matter; keep the default for dense primary sources.
- `--include-domain` is a hard host filter ("results will only come from these domains"), not a quality filter: `--include-domain github.com` admits any repo, not just reputable ones, and excludes everything else. Name authoritative projects/organizations in the query text for quality, use domain filters only to constrain hosts, and audit the resulting source list either way.
- `--additional-query`: phrase each as a full natural-language question from a different angle (terminology variant, competing approach, failure mode) rather than keyword permutations.

## Validation

After generating a report, run:

```bash
skills/deep-research/scripts/deep-research validate path/to/findings.md path/to/findings.raw.json
```

Prints `{ok, errors, warnings, mode, synthesis, queryCount}`; exit 0 means no errors. Deterministic checks:

| Check | Severity |
|---|---|
| Report and raw sidecar exist; sidecar parses with `metadata` + `raw` | error |
| All required report sections present | error |
| `queryCount` consistent with recorded `additionalQueries` and `additionalQueriesApplied` | error |
| `standard`/`full` payload has a synthesized answer (modes request `outputSchema`) | error |
| Missing synthesis in other modes (evidence brief — unsuitable as a recommendation) | warning |
| Sidecar predates additional-query metadata | warning |
| Key Findings duplicates Executive Summary text | warning |
| Zero sources; sidecar path mismatch vs report reference | warning |

Manual review checks (need judgment; `validate` cannot perform them):

- Claims contradicted by the returned sources (e.g. complexity classes, benchmark numbers) — spot-check material claims against the cited source text in the sidecar.
- Off-topic sources sharing an acronym or name with the research subject.
- Recommendation assertions with no claim-level support in Evidence and Sources.
- Results generalized beyond what the source established (e.g. a line-chart result applied to candlesticks).

## Findings Format

- Template: `templates/findings.md`
- Format checklist: `templates/findings-report-format.md` (this is a Markdown format guide, not a machine-readable schema)
- Required report sections: `Executive Summary`, `Key Findings`, `Evidence and Sources`, `Tradeoffs / Alternatives`, `Recommendation / Decision Criteria`, `Risks / Unknowns`, `Revisit Conditions`, and `Research Metadata`.
- Do not embed raw Exa JSON in `findings.md`. Store provider payloads in the sidecar JSON (`findings.raw.json` by default, or the explicit `--raw-output`/`rawOutputPath`).
