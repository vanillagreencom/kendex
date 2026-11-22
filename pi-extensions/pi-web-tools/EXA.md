# Exa integration reference

`pi-web-tools` uses Exa through a thin local `ExaClient` (`src/providers/exa.ts`). Tool renderers show concise provider labels. Tool `details` carry each result's title, URL, published date and content id; the stored text sits in the content store under its content id. No tool keeps the provider response in `details`. The `web_research` raw metadata file keeps the full research metadata and the Exa response, when one is written; a `json` report keeps the Exa response alone.

## API paths used

| Pi tool/path | Exa API | Purpose | Stored content |
|---|---|---|---|
| `web_search provider=exa` | `POST /search` | General web search | A **stored excerpt** per result |
| `web_research` | `POST /search` | Evidence-backed research | Findings and raw files |
| `web_fetch provider=exa` | `POST /contents` | Extract known remote URLs | Exa-returned page contents |
| URL fetch fallback | `POST /contents` | Extract known remote URLs | Exa-returned page contents |
| `web_answer` | `POST /answer` | A direct answer from Exa's search and LLM synthesis | The answer text, returned directly |
| `web_find_similar` | `POST /findSimilar` | Find pages similar to one URL | Returned source text as excerpts |
| `code_search` | `POST /search` | Search code and technical docs | Returned text as excerpts |

- `textMaxCharacters` defaults to 12k per result for `web_search` and `web_find_similar`.
- `textMaxCharacters` defaults to 6k per URL for `web_fetch`, lower than for search because `web_fetch` can pass dozens of URLs in one call.
- `web_search` sends `type: auto` by default.
- `web_search` text and highlights are optional.
- `web_research` sends `type: deep-lite`, `deep`, or `deep-reasoning`.
- `web_research` modes tune result count, text and highlight caps, summaries, structured output, and report sidecars.
- `web_research` source text is provider-capped evidence, not a local crawl.
- `web_fetch` calls `/contents` when `provider=exa` is forced or when a direct fetch fails.
- `web_answer` stores any source with text as an excerpt.
- `code_search` sends code/docs domain hints.
- `code_search` is currently biased to GitHub, docs and Stack Overflow.

## Search vs answer vs research

- `web_search`: returns ranked pages. Good for current facts and source discovery.
- `web_answer`: returns a synthesized answer from Exa's answer endpoint. Good for quick Q&A; source rows may be absent if Exa returns only an answer.
- `web_research`: uses Exa deep search types and optional structured output. Good for durable findings reports and multi-query investigations.

## Content ids and UI

Session storage uses generated content ids internally so the assistant can call `get_web_content`. Compact renderers intentionally hide those ids from users and show URLs/source metadata instead.

`get_web_content` labels search/answer/similar/code stored text as `stored excerpt` when it came from provider-capped Exa text. Direct `web_fetch` paths show `full` when the extension stored the full extracted text before preview truncation, and `source cut at N bytes` when a byte limit cut the source short.
