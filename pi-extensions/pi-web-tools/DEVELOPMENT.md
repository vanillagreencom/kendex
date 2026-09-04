# pi-web-tools development

For maintainers. What it does for a consumer is [README.md](README.md); the Exa API map is [EXA.md](EXA.md); each tool's schema descriptions in `src/tools/` state its own arguments.

## Invariants

- Only package tools are managed. `src/active-tools.ts::computeNextActiveTools` adds and removes names from `PACKAGE_TOOL_NAMES` and never touches a native or third-party tool; `tests/provider-selection.test.ts` holds it.
- A tool whose backing is absent is withheld, not registered to fail: `desiredWebTools` drops the Exa-only tools without `EXA_API_KEY` and drops `web_search` when no provider resolves. `web_fetch` stays, because its primary paths need no key and the Exa fallback is skipped when the key is unset.
- Provider order in `auto` is one list, `src/provider-selection.ts::resolveWebProviderCandidates`; the doctor command prints it from the same function. A provider is a candidate only when `enabledProviders` names it and its key or condition is present.
- Stored content is the session, not memory: `src/storage.ts::storeWebContent` appends a `pi-web-tools.content` entry and `restoreStoredContent` rebuilds the map on `session_start`, so a content id survives a resume. A tool that returns a preview stores the full text first.
- Exa paths store a provider-capped excerpt, and `get_web_content` labels it `stored excerpt`; direct HTTP, GitHub, PDF and YouTube-caption paths store the full extracted text. Raising `textMaxCharacters` on an Exa path raises the provider cap, on a direct path only the preview.
- Multi-URL `web_fetch` caps the aggregate inline preview (`MULTI_URL_AGGREGATE_CAP_SMALL_BATCH` and `MULTI_URL_AGGREGATE_CAP_LARGE_BATCH` in `src/tools/web-fetch.ts`) and switches to a manifest at `MULTI_URL_LARGE_BATCH_THRESHOLD`; an explicit `textMaxCharacters` opts out. When the manifest itself cannot fit, rows fall back to id-only so every content id stays resolvable.
- A transcript request is captions or an error. `videoMode: "transcript"`, or a prompt `src/extract/youtube.ts::isTranscriptPrompt` recognises, never falls through to an Exa excerpt or a Gemini summary; `provider: "exa"` is rejected for transcript URLs and a mixed batch continues its other URLs. `transcriptLanguage` is BCP 47 and a base language recovers a regional track.
- Secrets are read in `src/settings.ts::loadSettings` in one order: the process environment, then the private config file, then Pi settings (accepted with a warning), then the project's `.env` and `.env.local`. Project files are read only after `recordProjectTrust` saw the workspace trusted. An `op://` reference past `PI_WEB_TOOLS_OP_READ_TIMEOUT_MS` (clamped between 100 and 10000) is unset, never a blocked startup.
- `PI_CODING_AGENT_DIR` counts only when root-anchored, matching `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`; the same rule appears in `src/extract/github-clone.ts` for the clone cache root.
- Research mode defaults live in `src/tools/web-research.ts` and resolve as explicit tool argument, then the `exaResearchModes` profile, then the mode default (`applyResearchMode`). `full` runs the primary query plus each `additionalQueries` entry and dedupes URLs.
- Codex-model activation is by provider id, not model name (`src/provider-selection.ts::isOpenAiNativeModel`); the native rewrite in `src/native-openai.ts` replaces only a tool named `web_search` in the outgoing payload.

## Tests

`node:test` suites under `tests/`, run through `tsx`. The host packages are optional peers and are not installed in the tree:

```bash
cd pi-extensions/pi-web-tools
npm install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund @earendil-works/pi-ai@0.84.1 @earendil-works/pi-coding-agent@0.84.1 @earendil-works/pi-tui@0.84.1 typebox tsx 'youtube-transcript-plus@^2.0.1'
npm run check
```

`npm run check` is `typecheck` then `test`; `.github/workflows/skill-tests.yml` runs the same install. Provider suites stub `fetch` and assert request and response shapes; a new provider ships with its shape test and a case in `tests/provider-selection.test.ts` for where it sits in `auto`.
