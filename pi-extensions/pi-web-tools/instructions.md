## pi-web-tools — web and code retrieval

Tool selection (pick the cheapest option that answers the question):
- `code_search` — code patterns, library APIs, developer documentation. Token-efficient via Exa Code; the default for "how do I use X library / what's the API for Y".
- `web_search` — general web queries; the default for "find me…" when not code-specific.
- `web_answer` — quick cited answer to a focused factual question (single short response, not a deep dive).
- `web_fetch` — a URL or local PDF you already have. Stores the full extracted text so later `get_web_content` calls retrieve without refetching. Multi-URL calls (2–5 URLs) shrink each per-URL preview to fit a 16 KB aggregate cap; 6+ URLs return a manifest plus short 512-char preview heads under a 25 KB aggregate cap. Pass `textMaxCharacters` to opt back into larger inlined previews; the sidecar always stores the full text.
- `web_find_similar` — expand from a known good URL.
- `web_research` — multi-source deep-dive findings report. Expensive; only when the user wants a researched recommendation, not a quick lookup.
- `get_web_content` — re-read content already fetched/searched in this session by id. Never refetch what you already have.
