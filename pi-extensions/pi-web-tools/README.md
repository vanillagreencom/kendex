# @vanillagreen/pi-web-tools

Web search, page retrieval and research tools for Pi. The agent can search providers, read documents and return to saved results.

![Web Tools settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-web-tools/assets/settings-panel.png) ![Exa web_search results renderer](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-web-tools/assets/web-search.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-web-tools`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-web-tools"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Search the web through a selected provider.
- Read pages, repositories, PDFs and supported videos.
- Read saved result text without another fetch.
- Produce research reports through Exa.
- Use optional Exa answer, similar-page and code search tools.

## How it works

The extension enables tools for the configured providers and available credentials. The agent sends a search or fetch request. The chosen provider returns results, which the extension saves with the session. The tool returns a preview and a content identifier. The agent can use that identifier to read the saved text.

## Memory and disk use

- Fetched text is written to `~/.pi/agent/kendex/sessions/<session>/pi-web-tools/content/`, one file per content id. The session record and the tool details carry the id, title, URL, length and the id of the session that stored the text, not the text. A forked session reads its parent's ids from the parent's directory.
- The tool details of `web_search`, `code_search`, `web_answer`, `web_find_similar` and `web_research` carry each result's title, URL, published date and content id, not its text or the provider's raw response. The `web_research` details also carry the research mode, Exa type and query and source counts, not the request bodies, which hold the text of every context file. The raw metadata file keeps the full metadata; `web_research` writes it when `outputPath` is given with a `reportFormat` other than `json`, or when `rawOutputPath` is given without `outputPath`.
- At most 8,388,608 characters of fetched text are held in memory; the least recently read items are dropped and read from disk again when needed. One item larger than that bound by itself is still held until the next item is stored. Memory is cleared when a session starts or ends.
- A session's content directory is deleted once the session's working directory is gone (a merged worktree), and any content file older than 5 days is deleted. Pi applies both rules when a session starts. A deleted id can no longer be read: `get_web_content` fails with `Stored content text gone: <id>` and names the URL to fetch again.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-web-tools"]`.

Open `/extensions:settings`; settings appear under the **Web Tools** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`, `autoEnable`: the package and whether its tools join the active set on their own.
- `defaultProvider`, `enabledProviders`: which provider answers `web_search` and which are allowed at all.
- `nativeOpenAiWebSearch`, `openAiExternalWebAccess`: the native OpenAI rewrite.
- `exaDeepResearchEnabled`, `exaResearchModes`, `exaAdvancedEnabled`: `web_research`, its per-mode overrides, and the advanced Exa tools.
- `htmlExtraction.jinaFallback`, `githubClone.enabled`, `githubClone.maxRepoSizeMB`, `video.enabled`, `browserCookieAccess`: the fetch paths.
- `compatibilityTools`: register the older tool names such as `fetch_content` and `web_search_exa`.
- `glyphStyle`: Unicode or ASCII symbols; `pi-tool-renderer`'s global override wins when set.

The Exa endpoints each tool calls and what each stores are in [EXA.md](EXA.md). Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).

## API keys

Set these as environment variables, in the project's `.env` or `.env.local`, or in a private JSON file named by `PI_WEB_TOOLS_CONFIG_FILE`. The process environment wins over files, and a project file is read only once Pi marks the workspace trusted.

- `EXA_API_KEY`
- `PERPLEXITY_API_KEY`
- `GEMINI_API_KEY`
- `OPENAI_API_KEY`
- `JINA_API_KEY`, optional; Jina Reader works anonymously without it.

A value may be a 1Password reference such as `op://Private/Exa API Key/credential` when the `op` CLI is installed and signed in. A reference that does not resolve within the startup timeout is treated as unset so Pi starts anyway; `PI_WEB_TOOLS_OP_READ_TIMEOUT_MS` changes that timeout.
