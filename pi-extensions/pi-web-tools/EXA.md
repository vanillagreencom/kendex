# Exa integration reference

`pi-web-tools` uses Exa through a thin local `ExaClient` (`src/providers/exa.ts`). Tool renderers show concise provider labels while full provider payloads stay in tool `details`/raw sidecars.

## API paths used

| Pi tool/path | Exa API | Purpose | Stored content semantics |
|---|---|---|---|
| `web_search provider=exa` | `POST /search` with `type: auto` by default | General web search with optional text/highlights. | Stores Exa-returned text as a **stored excerpt** capped by `textMaxCharacters` (default 12k/result). |
| `web_research` | `POST /search` with `type: deep-lite`, `deep`, or `deep-reasoning` | Evidence-backed research. Modes tune result count, text/highlight caps, summaries, structured output, and report sidecars. | Usually writes findings/raw files; source text is provider-capped evidence, not a local crawl. |
| `web_fetch provider=exa` or URL fetch fallback | `POST /contents` | Extract known remote URLs when forced or when direct fetch fails. | Stores Exa-returned page contents; capped by `textMaxCharacters` (default 6k/url — lower than search/findSimilar because `web_fetch` can pass dozens of URLs in one call). |
| `web_answer` | `POST /answer` | Exa performs search + LLM synthesis for a direct answer. | Answer text is returned directly; any sources with text are stored as excerpts. |
| `web_find_similar` | `POST /findSimilar` | Find pages similar to one URL. | Stores returned source text as excerpts capped by `textMaxCharacters` (default 12k/result). |
| `code_search` | `POST /search` with code/docs domain hints | Search code and technical docs, currently biased to GitHub/docs/Stack Overflow. | Stores returned text as excerpts. |

## Search vs answer vs research

- `web_search`: returns ranked pages. Good for current facts and source discovery.
- `web_answer`: returns a synthesized answer from Exa's answer endpoint. Good for quick Q&A; source rows may be absent if Exa returns only an answer.
- `web_research`: uses Exa deep search types and optional structured output. Good for durable findings reports and multi-query investigations.

## Content ids and UI

Session storage uses generated content ids internally so the assistant can call `get_web_content`. Compact renderers intentionally hide those ids from users and show URLs/source metadata instead.

`get_web_content` labels search/answer/similar/code stored text as `stored excerpt` when it came from provider-capped Exa text. Direct `web_fetch` paths can show `full` when the extension stored the full extracted text before preview truncation.

## Settings and keys

- Exa key source: `EXA_API_KEY`, project `.env.local`/`.env`, or `PI_WEB_TOOLS_CONFIG_FILE`/private config.
- Advanced tools (`web_answer`, `web_find_similar`, `code_search`) are registered but only auto-enabled when `pi-web-tools.exaAdvancedEnabled=true` and an Exa key is available.
- Deep research is controlled separately by `pi-web-tools.exaDeepResearchEnabled`.
