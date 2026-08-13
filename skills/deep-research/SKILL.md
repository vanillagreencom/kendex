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

Evidence-backed research reports: architectural investigations, vendor and library comparisons, technology choices, and workflow-owned `findings.md` reports.

In Pi with the `web_research` tool active, use that tool, passing `outputPath` when creating a report. In every other harness — Pi without it, Claude Code, Codex, OpenCode, Cursor — run `scripts/deep-research` with `EXA_API_KEY` set.

## Rules

- Exa is the research source. Substitute a general web search only when Exa is unavailable and the user approves the fallback.
- Write `findings.md` to the path the caller requested, exactly.
- Cite sources for material claims, and keep `findings.md` human-readable: provider payloads live in the sidecar JSON (`findings.raw.json` beside the report by default), never inline. Sanitize evidence excerpts so headings from source pages do not render as headings.
- Once the report and its sidecar exist, run `validate` and stop. Do not add local reproduction, benchmarks, tests, code inspection, or implementation unless the caller asked for local validation on top of the research.
- A missing `EXA_API_KEY` fails with setup instructions. The value may be a key or a 1Password `op://vault/item/field` reference when the `op` CLI is installed and signed in.
- One findings format serves every mode: the mode changes depth and source volume, not the required sections. Record mode and source counts in `## Research Metadata`.

## Running

```bash
skills/deep-research/scripts/deep-research report "question" --mode standard --output path/to/findings.md
skills/deep-research/scripts/deep-research report --query-file prompt.txt --context-glob 'context-*.md' --mode full --output findings.md
skills/deep-research/scripts/deep-research json "question" --output raw.json
skills/deep-research/scripts/deep-research validate findings.md findings.raw.json
skills/deep-research/scripts/deep-research doctor
```

`deep-research help` lists every flag. Exa `/search` caps the settings behind them: `numResults` 1-100, `text.maxCharacters` 1-10000, `additionalQueries` at most 10.

| Mode | Exa type | Results | Text cap | Timeout | Synthesis |
|---|---|---:|---:|---:|---|
| `lite` | `deep-lite` | 15 | 10k chars/result | 5 min | Not requested — evidence brief only |
| `standard` | `deep-reasoning` | 50 | 10k chars/result | 10 min | Requested via `outputSchema` |
| `full` | `deep-reasoning` | 100 | 10k chars/result | 30 min | Requested, per query |

`standard` is the default; `lite` suits fast spikes, `full` strategic or high-risk decisions. Explicit `--type`, `--num-results`, and `--text-max-characters` override a mode's defaults.

`--additional-query` (repeatable) reaches Exa as `additionalQueries` within the single request under `lite` and `standard`, and as one request per query with URLs deduped across responses under `full`; the sidecar records which, as `provider-additional-queries` or `local-fan-out`.

`--include-domain` is a hard host filter, not a quality filter: `--include-domain github.com` admits every repo on it and excludes everything else. Name authoritative projects and organizations in the query text when quality is what you want, and audit the returned source list either way.

## Validation

```bash
skills/deep-research/scripts/deep-research validate path/to/findings.md path/to/findings.raw.json
```

Prints `{ok, errors, warnings, mode, synthesis, queryCount}` and exits 0 when there are no errors. It checks structure: required sections present, sidecar parses, query-expansion metadata self-consistent, and a synthesized answer present for the modes that requested one.

It cannot judge content. Read for these yourself:

- Claims the cited sources contradict — spot-check material numbers (complexity classes, benchmark results) against the source text in the sidecar.
- Off-topic sources that share an acronym or name with the subject.
- Recommendations with no claim-level support in Evidence and Sources.
- Results generalized past what the source established.

## Findings format

`templates/findings.md` carries exactly the sections `validate` requires, in order. `Key Findings` holds distinct claims, not a restatement of the summary.
