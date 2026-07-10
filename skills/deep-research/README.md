# deep-research skill

Portable Exa Deep Search skill for producing evidence-backed findings reports in any harness.

Run `scripts/deep-research doctor` to verify Node/fetch availability and whether `EXA_API_KEY` is configured.

Report mode defaults (within Exa `/search` limits: `numResults` 1-100, `text.maxCharacters` 1-10000):

| Mode | Exa type | Results | Text cap | Timeout | Synthesis |
|---|---|---:|---:|---:|---|
| `lite` | `deep-lite` | 15 | 10k chars/result | 5 min | No (evidence brief) |
| `standard` | `deep-reasoning` | 50 | 10k chars/result | 10 min | Yes (`outputSchema`) |
| `full` | `deep-reasoning` | 100 | 10k chars/result | 30 min | Yes, per fanned-out query |

`report --output findings.md` writes clean Markdown and defaults raw metadata to `findings.raw.json`.

Repeated `--additional-query` values are sent as Exa `additionalQueries` in one request (`lite`/`standard`) or fanned out as separate requests with URL dedupe (`full`). The sidecar metadata records the queries and how they were applied.

After generating a report, run `scripts/deep-research validate findings.md findings.raw.json` for deterministic post-run checks (required sections, query-expansion metadata consistency, synthesis presence, duplicated sections). It prints `{ok, errors, warnings}` and exits non-zero on errors.

The findings format is mode-adaptive: `lite`, `standard`, and `full` use the same required sections, while mode/source/query counts are recorded in `## Research Metadata`. This avoids separate templates drifting over time.

Format references:

- `templates/findings.md` — Markdown findings template.
- `templates/findings-report-format.md` — section checklist/format guide (not a JSON schema).

Raw Exa/provider payloads belong in the sidecar JSON only. Do not embed raw JSON or fenced raw metadata blocks in `findings.md`.

Pi `web_research` uses Exa highlights and, for `standard`/`full`, structured output (`outputSchema`) plus source summaries when available. `lite` avoids the default output schema after live Exa testing showed empty result sets with `deep-lite` + structured output. Evidence excerpts are sanitized before rendering so Markdown headings from source pages do not become giant quoted headings in reports.
