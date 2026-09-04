# deep-research

Evidence-backed findings reports from Exa Deep Search, usable from any AI coding harness. Give it a research question and it writes a `findings.md` with the same sections every time, keeping the raw provider payload in a sidecar JSON beside it.

## Install

```bash
kendex add vanillagreencom/kendex --skill deep-research
```

Needs Node 18 or newer and an Exa API key in `EXA_API_KEY`. A 1Password `op://vault/item/field` reference works when the `op` CLI is signed in. Check both with `scripts/deep-research doctor`.

## What it does

- `report` writes a findings document: executive summary, key findings, cited evidence, tradeoffs, recommendation, risks, revisit conditions.
- Three modes trade cost against depth: `lite` (15 sources, no synthesis), `standard` (50 sources), `full` (100 sources, one request per query angle).
- `validate` re-checks a finished report against its sidecar for a missing section, contradictory query-expansion metadata, or a recommendation report that came back unsynthesized.
- `json` returns the raw provider response.

## How it works

The script sends the question to Exa's deep search and renders the response into a fixed set of sections, so every findings document in a project reads the same way. In Pi the `web_research` tool takes the same role. Every command and flag: `scripts/deep-research help`.

## Customise

- `EXA_API_KEY`: the only setting; keep it in `.env.local`.
- Domain, date, result-count and context flags are per call, listed by `scripts/deep-research help`.
