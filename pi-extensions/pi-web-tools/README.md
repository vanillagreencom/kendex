# pi-web-tools

![Web Tools settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-web-tools/assets/settings-panel.png)
![Exa web_search results renderer](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-web-tools/assets/web-search.png)

Web access tools for Pi: search, deep research, content fetch, and code search.

For the Exa-specific API map and tool semantics, see [`EXA.md`](./EXA.md).

## Highlights

- `web_search` with provider selection: `auto`, `exa`, `perplexity`, `gemini`, `exa-mcp`, `duckduckgo`, `openai-native`.
- `web_research` runs Exa Deep Search with `lite`, `standard`, or `full` modes. Writes findings reports with raw-metadata sidecars.
- `web_fetch` extracts GitHub repos (clone cache), URL and local PDFs, HTML/text/JSON, complete YouTube caption transcripts, and Gemini-powered YouTube/local video understanding, with Jina Reader fallback on blocked pages.
- `web_answer` and `web_find_similar` for Exa-first quick answers.
- `code_search` uses Exa Code `/context` with fallback to code-focused Exa search.
- `get_web_content` retrieves stored full content by id — no refetch.
- OpenAI-native `web_search` rewrite on supported Codex models.

`auto` provider tries keyed providers first (Exa, Perplexity, Gemini API), then no-key fallbacks (Exa MCP, DuckDuckGo), then Gemini Web cookies if enabled, then `openai-native`.

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

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/web-tools` | Open settings (or print status if extension-manager isn't installed). |
| `/web-tools:doctor` | Show status and diagnostics. |
| `/web-tools:provider:<name>` | Switch the active provider for this session. |

## Fetch storage

`web_fetch` returns a compact preview and stores extracted content in the current Pi session under a generated content id (e.g. `web-...`). Use `get_web_content` with that id to retrieve the stored text — it doesn't refetch the URL.

- GitHub, direct HTTP, and PDF paths store full extracted text before preview truncation.
- YouTube transcript requests store complete native captions with timestamps. They never fall through to Exa excerpts when caption extraction fails.
- Exa-provider paths (`provider=exa` and auto-mode Exa fallback) store provider-capped excerpts (default 6000 chars; override per call with `textMaxCharacters`). `get_web_content` labels these as `stored excerpt` so the caller knows to set a larger cap or fetch directly if it needs the full document.
- Local PDFs supported via `filePath`/`filePaths`, `file://...`, or PDF-looking paths.
- `textMaxCharacters` caps the immediate preview (default 4k chars).
- `get_web_content.maxCharacters` caps retrieval (default 50k chars).

### Multi-URL preview caps

A single `web_fetch` call accepts many URLs via `urls`/`filePaths`. To keep `content[0].text` from blowing past the model's input window, multi-URL calls cap the aggregate preview size and emit a manifest for large batches. Single-URL calls and explicit `textMaxCharacters` opt-ins are unaffected.

| URLs in call | Per-URL preview | Aggregate cap | Format |
| --- | --- | --- | --- |
| 1 | `textMaxCharacters` (default 4k) | — | preview blocks |
| 2–5 | `min(textMaxCharacters, floor(16 KB / count))` | 16 KB | preview blocks |
| 6+ | 512 chars head | 25 KB | manifest of all URLs + short preview heads |

The sidecar (`pi-web-tools.content` events + `get_web_content`) stores per-URL full extracted text for direct/GitHub/PDF/HTTP paths and provider-capped excerpts for Exa paths. The aggregate cap only applies to the inline preview returned to the model. Pass `textMaxCharacters` to opt back into larger inlined previews when the caller knows the context budget allows it; for Exa paths the same flag also raises the provider-side excerpt cap.

## YouTube transcripts and video understanding

`web_fetch` separates exact caption retrieval from model-generated video understanding:

```typescript
web_fetch({
  url: "https://www.youtube.com/watch?v=...",
  videoMode: "transcript",
  transcriptLanguage: "en"
})

web_fetch({
  url: "https://www.youtube.com/watch?v=...",
  videoMode: "understand",
  prompt: "Describe diagrams and code shown on screen."
})
```

- `videoMode: "auto"` is the default. Prompts containing transcript, transcribe, verbatim, subtitle, caption, or lyrics terms use native YouTube captions; other prompts use Gemini.
- Native transcripts include every caption segment as `[HH:MM:SS] text`, decode caption HTML entities, and store the complete result under the content id.
- `transcriptLanguage` accepts a BCP 47 language code. When omitted, native extraction uses YouTube's first available caption track. Explicit base-language requests can recover matching regional tracks such as `en-US`; stored metadata records the selected track language.
- Caption-unavailable errors surface directly. The tool does not substitute an Exa page excerpt or label a generated summary as a complete transcript.
- `provider: "exa"` is rejected for transcript-only batches; use `auto` or `http`. Mixed batches keep transcript conflicts as explicit per-URL failures and continue unrelated URLs. Disabled video extraction follows the same mixed-batch behavior.
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

`standard` and `full` request Exa summaries and structured output. `full` runs the primary query plus each `additionalQueries` entry, then dedupes URLs.

Override per-mode defaults with the **Exa research mode overrides** setting (JSON keyed by `lite`/`standard`/`full`).

## Settings

Open `/extensions:settings`; settings appear under the **Web Tools** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

### General

| Setting | What it does |
| --- | --- |
| Auto-enable web tools | Add web tools to the active set while preserving Pi natives. |
| Default provider | Provider used by `web_search` unless the call overrides. |
| Enabled providers | Comma-separated allow-list. |

### OpenAI native

| Setting | What it does |
| --- | --- |
| OpenAI native web_search | Rewrite `web_search` to native OpenAI/Codex Responses `web_search`. |
| OpenAI external web access | Set `external_web_access` on native tools. |

### Exa

| Setting | What it does |
| --- | --- |
| Exa deep research | Register and enable `web_research`. |
| Exa research mode overrides | JSON object keyed by `lite`/`standard`/`full`. |
| Exa advanced tools | Enable `web_answer`, `web_find_similar`, `code_search`. |

### Content

| Setting | What it does |
| --- | --- |
| Jina Reader fallback | Fall back to `r.jina.ai` for blocked or 403/429/5xx pages. |
| GitHub clone extraction | Use a clone cache for GitHub repo URLs. |
| GitHub clone max size | Large-repo fallback threshold in MB. |
| Video extraction | Complete YouTube caption transcripts plus YouTube/local video understanding via Gemini. |
| Browser cookie access | Opt-in browser cookie extraction for Gemini Web fallback. |

### Compatibility

| Setting | What it does |
| --- | --- |
| Compatibility aliases | Register legacy aliases like `fetch_content` and `web_search_exa`. |

## Notes

`web_search` moved here from `pi-codex-minimal-tools`. Install both updated packages together; `pi-codex-minimal-tools` now owns only `image_generation`, `view_image`, and `apply_patch`.
