---
name: deep-research
description: "Load for research tasks, architectural investigations, and vendor, library, or technology comparisons."
license: MIT
user-invocable: true
argument-hint: "report [query] --output findings.md"
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Deep Research

In Pi with the `web_research` tool active, use that tool, passing `outputPath` when creating a report. In every other harness, run `scripts/deep-research` with `EXA_API_KEY` set.

## Rules

- Exa is the research source. Substitute a general web search only when Exa is unavailable and the user approves the fallback.
- Write `findings.md` to the path the caller requested, exactly. Given no path, write it to `tmp/plans/<slug>-research.md`, never under a tracked `docs/` path; the full rule is `agents/planner.md` § Plan Artifacts. The report reaches other sessions as an attachment on its tracker issue.
- Research on building against another system is held to [code-quality § Over-Engineering](../code-quality/SKILL.md#over-engineering).
- Cite sources for material claims. Provider payloads go in the sidecar JSON (`findings.raw.json` beside the report by default), never inline. Sanitize evidence excerpts: source-page headings must not render as headings.
- Once the report and its sidecar exist, run `validate` and stop. No local reproduction, benchmarks, tests, code inspection, or implementation unless the caller asked for it.
- A missing `EXA_API_KEY` fails with setup instructions. Set it on this package's Customize tab in the kendex app, or by hand in the project's private env file — `.env.local` unless `KENDEX_ENV_FILE` names another. The value may be a key or a 1Password `op://vault/item/field` reference when the `op` CLI is installed and signed in.
- Every mode uses the same findings sections. Record mode and source counts in `## Research Metadata`.

## Running

```bash
.agents/skills/deep-research/scripts/deep-research report "question" --mode standard --output path/to/findings.md
.agents/skills/deep-research/scripts/deep-research report --query-file prompt.txt --context-glob 'context-*.md' --mode full --output findings.md
.agents/skills/deep-research/scripts/deep-research json "question" --output raw.json
.agents/skills/deep-research/scripts/deep-research validate findings.md findings.raw.json
.agents/skills/deep-research/scripts/deep-research doctor
```

Run `deep-research help` for the flags and exact mode presets. `scripts/deep-research` owns the presets in `modeDefaults` and accepted limits in `applyMode`.

Use `lite` for a fast evidence brief; it requests no synthesis. `standard` is the default and requests a synthesized answer. Use `full` for strategic or high-risk decisions; it requests synthesis for each query. The type, result count, text cap and timeout flags override the preset values.

`--additional-query` (repeatable) reaches Exa as `additionalQueries` within the single request under `lite` and `standard`, and as one request per query with URLs deduped across responses under `full`.

`--include-domain` restricts results to matching domains or paths, as [Exa Search](https://exa.ai/docs/reference/search) defines. A domain such as `github.com` does not select authoritative repositories. Name authoritative projects and organizations in the query, and audit the returned source list.

## Validation

```bash
.agents/skills/deep-research/scripts/deep-research validate path/to/findings.md path/to/findings.raw.json
```

`validate` exits 0 when it finds no errors. It checks report structure, sidecar parsing, query-expansion metadata and synthesis for modes that request it. Its result does not verify the claims against the sources. The output contract is in `deep-research help`; `scripts/deep-research::validateCommand` owns the checks.

Read for these yourself:

- Claims the cited sources contradict. Spot-check material numbers against the sidecar source text.
- Off-topic sources that share an acronym or name with the subject.
- Recommendations with no claim-level support in Evidence and Sources.
- Results generalized past what the source established.

## Findings format

Read `templates/findings.md` when writing a report. It gives the required sections in report order. `Key Findings` holds distinct claims, not a restatement of the summary.
