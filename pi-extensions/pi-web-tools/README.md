# pi-web-tools

![Web Tools settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-web-tools/assets/settings-panel.png)
![Exa web_search results renderer](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-web-tools/assets/web-search.png)

Web access tools for Pi: search, deep research, content fetch, and code search.

For the Exa-specific API map and tool semantics, see [`EXA.md`](./EXA.md). Internals, design, and maintenance live in [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## Highlights

- `web_search` with provider selection: `auto`, `exa`, `perplexity`, `gemini`, `exa-mcp`, `duckduckgo`, `openai-native`.
- `web_research` runs Exa Deep Search with `lite`, `standard`, or `full` modes. Writes findings reports with raw-metadata sidecars.
- `web_fetch` extracts GitHub repos (clone cache), URL and local PDFs, HTML/text/JSON, complete YouTube caption transcripts, and Gemini-powered YouTube/local video understanding, with Jina Reader fallback on blocked pages.
- `web_answer` and `web_find_similar` for Exa-first quick answers.
- `code_search` uses Exa Code `/context` with fallback to code-focused Exa search.
- `get_web_content` retrieves stored full content by id — no refetch.
- OpenAI-native `web_search` rewrite on supported Codex models.
- `auto` provider tries keyed providers first (Exa, Perplexity, Gemini API), then no-key fallbacks (Exa MCP, DuckDuckGo), then Gemini Web cookies if enabled, then `openai-native`.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-web-tools):

```bash
pi install npm:@vanillagreen/pi-web-tools
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-web-tools --harness pi -y
```

Restart Pi after installation. `web_search` lives in this package rather than `pi-codex-minimal-tools`, which owns only `image_generation`, `view_image`, and `apply_patch`; install both updated packages together.

## Commands

| Command | Action |
| --- | --- |
| `/web-tools` | Open settings (or print status if extension-manager isn't installed). |
| `/web-tools:doctor` | Show status and diagnostics. |
| `/web-tools:provider:<name>` | Switch the active provider for this session. |

## Fetch storage

`web_fetch` returns a compact preview and stores extracted content in the current Pi session under a generated content id (e.g. `web-...`). Use `get_web_content` with that id to retrieve the stored text — it doesn't refetch the URL.

- `textMaxCharacters` caps the immediate preview (default 4k chars); multi-URL calls additionally cap the aggregate preview and emit a manifest for large batches.
- `get_web_content.maxCharacters` caps retrieval (default 50k chars).
- Local PDFs supported via `filePath`/`filePaths`, `file://...`, or PDF-looking paths.
- Exa-provider paths store provider-capped excerpts (default 6000 chars; raise with `textMaxCharacters`), which `get_web_content` labels as `stored excerpt`.

## YouTube transcripts and video understanding

`web_fetch` separates exact caption retrieval from model-generated video understanding:

```typescript
web_fetch({ url: "https://www.youtube.com/watch?v=...", videoMode: "transcript", transcriptLanguage: "en" })
web_fetch({ url: "https://www.youtube.com/watch?v=...", videoMode: "understand", prompt: "Describe diagrams and code shown on screen." })
```

- `videoMode: "auto"` is the default. Prompts containing transcript, transcribe, verbatim, subtitle, caption, or lyrics terms use native YouTube captions; other prompts use Gemini.
- Native transcripts include every caption segment as `[HH:MM:SS] text`, decode caption HTML entities, and store the complete result under the content id.
- `transcriptLanguage` accepts a BCP 47 language code. When omitted, native extraction uses YouTube's first available caption track.
- Gemini Web/API remains the path for visual details, questions about frames, and videos without a transcript request.

## API keys

Set via environment variables, project `.env.local`/`.env`, or a private config file. Process env wins over files.

- `EXA_API_KEY`
- `PERPLEXITY_API_KEY`
- `GEMINI_API_KEY`
- `OPENAI_API_KEY`
- `JINA_API_KEY` (optional; anonymous Jina Reader works without it)
- `PI_WEB_TOOLS_CONFIG_FILE=/path/to/private.json`

Values may be 1Password references such as `op://Private/Exa API Key/credential` when the `op` CLI is installed and signed in. References resolve best-effort with a short startup timeout (default 1500 ms, override with `PI_WEB_TOOLS_OP_READ_TIMEOUT_MS`); unresolved references are treated as unset so Pi startup does not block.

## Deep research modes

| Mode | Exa type | Results | Text cap | Highlight cap |
| --- | --- | ---: | ---: | ---: |
| `lite` | `deep-lite` | 15 | 10k | 600 |
| `standard` | `deep-reasoning` | 50 | 16k | 900 |
| `full` | `deep-reasoning` | 150 | 24k | 1200 |

`standard` and `full` request Exa summaries and structured output. `full` runs the primary query plus each `additionalQueries` entry, then dedupes URLs. Override per-mode defaults with the **Exa research mode overrides** setting (JSON keyed by `lite`/`standard`/`full`).

## Settings

Open `/extensions:settings`; settings appear under the **Web Tools** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only. Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

| Group | Setting | What it does |
| --- | --- | --- |
| General | Auto-enable web tools | Add web tools to the active set while preserving Pi natives. |
| General | Default provider | Provider used by `web_search` unless the call overrides. |
| General | Enabled providers | Comma-separated allow-list. |
| OpenAI native | OpenAI native web_search | Rewrite `web_search` to native OpenAI/Codex Responses `web_search`. |
| OpenAI native | OpenAI external web access | Set `external_web_access` on native tools. |
| Exa | Exa deep research | Register and enable `web_research`. |
| Exa | Exa research mode overrides | JSON object keyed by `lite`/`standard`/`full`. |
| Exa | Exa advanced tools | Enable `web_answer`, `web_find_similar`, `code_search`. |
| Content | Jina Reader fallback | Fall back to `r.jina.ai` for blocked or 403/429/5xx pages. |
| Content | GitHub clone extraction | Use a clone cache for GitHub repo URLs. |
| Content | GitHub clone max size | Large-repo fallback threshold in MB. |
| Content | Video extraction | Complete YouTube caption transcripts plus YouTube/local video understanding via Gemini. |
| Content | Browser cookie access | Opt-in browser cookie extraction for Gemini Web fallback. |
| Compatibility | Compatibility aliases | Register legacy aliases like `fetch_content` and `web_search_exa`. |
