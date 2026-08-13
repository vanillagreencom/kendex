# deep-research

Portable Exa Deep Search for evidence-backed findings reports, usable from any AI coding harness. Give it a research question and it writes a `findings.md` — executive summary, key findings, cited evidence, tradeoffs, recommendation, risks, revisit conditions — keeping the raw provider payload in a sidecar JSON beside it.

## How it works

`report` sends the question to Exa's deep search and renders the response into a fixed set of sections, so every findings document in a project reads the same way. Three modes trade cost against depth: `lite` (15 sources, no synthesis — an evidence brief), `standard` (50 sources, synthesized), and `full` (100 sources, one request per query angle with URLs deduped).

`validate` re-checks a finished report against its sidecar for the structural problems that are easy to miss: a missing section, query-expansion metadata that contradicts itself, or a report meant to carry a recommendation that came back without a synthesized answer.

## Setup

Needs Node 18+ and an Exa API key in `EXA_API_KEY` — a 1Password `op://vault/item/field` reference works when the `op` CLI is signed in. Check both:

```bash
scripts/deep-research doctor
```

`scripts/deep-research help` lists every command and flag.
