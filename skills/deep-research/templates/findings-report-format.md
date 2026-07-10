# Findings Report Format

This is a Markdown report format/checklist, not a machine-readable JSON schema.

Required sections:

1. `# Findings: [TITLE]`
2. `## Research Question`
3. `## Executive Summary`
4. `## Key Findings`
5. `## Evidence and Sources`
6. `## Tradeoffs / Alternatives`
7. `## Recommendation / Decision Criteria`
8. `## Risks / Unknowns`
9. `## Revisit Conditions`
10. `## Research Metadata`

Report requirements:

- Include source URLs/citations for material claims, or clearly state that Exa returned no source URLs.
- Keep evidence excerpts concise and readable; prefer short blockquotes or summaries over raw payload dumps.
- Do not embed raw Exa JSON or fenced raw metadata blocks in `findings.md`.
- Preserve raw provider payloads in a sidecar JSON file: `findings.raw.json` by default when writing `findings.md`, or the explicit raw output path supplied by the workflow/tool.
- Use the same section layout for `lite`, `standard`, and `full`; the `Research Metadata` section records the mode, Exa type, query count (with additional queries and how they were applied), request count, synthesis presence, source counts, and sidecar path.
- `Key Findings` must contain distinct claims, not a repeat of the `Executive Summary`.
- Validate the finished pair with `scripts/deep-research validate <findings.md> <findings.raw.json>`.