# @vanillagreen/pi-web-tools

Web access for Pi: search across several providers, Exa deep research, content fetch for pages, GitHub repositories, PDFs and videos, and code search. Everything fetched is stored in the session so the model can re-read it without fetching again.

![Web Tools settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-web-tools/assets/settings-panel.png) ![Exa web_search results renderer](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-web-tools/assets/web-search.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-web-tools"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-web-tools):

```bash
pi install npm:@vanillagreen/pi-web-tools
```

Restart Pi after installation. Web search lives here, not in `pi-codex-minimal-tools`.

## What it does

- `web_search` with a provider chosen per call or by the `defaultProvider` setting: `exa`, `perplexity`, `gemini`, `exa-mcp`, `duckduckgo`, `openai-native`, or `auto`.
- `web_fetch` for URLs and local files: HTML, JSON and text pages, GitHub repositories through a clone cache, remote and local PDFs, complete YouTube caption transcripts, and video understanding through Gemini. A blocked page falls back to Jina Reader.
- `get_web_content` returns the full stored text of anything a search or fetch already produced, by content id, without another request.
- `web_research` runs Exa deep search in `lite`, `standard` or `full` mode and writes a findings report with a raw-metadata sidecar.
- `web_answer`, `web_find_similar` and `code_search` through Exa, behind the `exaAdvancedEnabled` setting.
- On OpenAI and Codex models, `web_search` is rewritten to the provider's native tool when `nativeOpenAiWebSearch` is on.
- `/web-tools` opens the settings, `/web-tools:doctor` prints status and diagnostics, and `/web-tools:provider:<name>` switches the provider for the session.

## How it works

The tools are added to Pi's active set whenever the model or settings change, keeping Pi's native tools untouched; a tool whose provider or key is missing is left out of the set rather than failing on call. In `auto` mode the search order is keyed providers first (Exa, Perplexity, the Gemini API), then the no-key providers (Exa MCP, DuckDuckGo), then Gemini through browser cookies if that is enabled, then the OpenAI native tool. Every fetch stores its extracted text in the session under a content id and returns a preview; the Exa paths store a provider-capped excerpt and say so.

## API keys

Set these as environment variables, in the project's `.env` or `.env.local`, or in a private JSON file named by `PI_WEB_TOOLS_CONFIG_FILE`. The process environment wins over files, and a project file is read only once Pi marks the workspace trusted.

- `EXA_API_KEY`
- `PERPLEXITY_API_KEY`
- `GEMINI_API_KEY`
- `OPENAI_API_KEY`
- `JINA_API_KEY`, optional; Jina Reader works anonymously without it.

A value may be a 1Password reference such as `op://Private/Exa API Key/credential` when the `op` CLI is installed and signed in. A reference that does not resolve within the startup timeout is treated as unset so Pi starts anyway; `PI_WEB_TOOLS_OP_READ_TIMEOUT_MS` changes that timeout.

## Customise

Open `/extensions:settings`; settings appear under the **Web Tools** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`, `autoEnable`: the package and whether its tools join the active set on their own.
- `defaultProvider`, `enabledProviders`: which provider answers `web_search` and which are allowed at all.
- `nativeOpenAiWebSearch`, `openAiExternalWebAccess`: the native OpenAI rewrite.
- `exaDeepResearchEnabled`, `exaResearchModes`, `exaAdvancedEnabled`: `web_research`, its per-mode overrides, and the advanced Exa tools.
- `htmlExtraction.jinaFallback`, `githubClone.enabled`, `githubClone.maxRepoSizeMB`, `video.enabled`, `browserCookieAccess`: the fetch paths.
- `compatibilityTools`: register the older tool names such as `fetch_content` and `web_search_exa`.
- `glyphStyle`: Unicode or ASCII chrome; `pi-tool-renderer`'s global override wins when set.

The Exa endpoints each tool calls and what each stores are in [EXA.md](EXA.md). Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
