## pi-web-tools — web and code retrieval

Tool selection:

1. Choose only active tools.
2. Pick the cheapest option that answers the question.

- Select `code_search`, `web_answer`, `web_find_similar` and `web_research` only when Exa is configured; `web_research` also requires `exaDeepResearchEnabled`.

Tools:

- `code_search` — code patterns, library APIs, developer documentation. Token-efficient via Exa Code; the default for "how do I use X library / what's the API for Y".
- `web_search` — general web queries; the default for "find me…" when not code-specific.
  - For a simple factual question, run one search with `numResults` of 5 or fewer and answer from the best source.
- `web_answer` — quick cited answer to a focused factual question (single short response, not a deep dive).
- `web_fetch` — a URL or local PDF you already have.
  - Exa-provider paths store provider-capped excerpts (default 6000 chars; override per call with `textMaxCharacters`).
  - 6+ URLs return a manifest plus short 512-char preview heads.
- `web_find_similar` — expand from a known good URL.
- `web_research` — multi-source deep-dive findings report.
  - Expensive; use it only when the user wants a researched recommendation, not a quick lookup.
- `get_web_content` — re-read content already fetched/searched in this session by id (`web-...`).
  - Never refetch what you already have.
  - To page another tool's truncated output, re-call that tool with `offset:` — don't pass its tool-call id or sidecar path here.
