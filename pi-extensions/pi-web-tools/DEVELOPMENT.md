# pi-web-tools — development notes

Internals, design, and maintenance for the pi-web-tools Pi extension. Consumer docs live in [`README.md`](./README.md); the Exa API map lives in [`EXA.md`](./EXA.md).

## Layout

- `src/index.ts` — extension entry; `src/activation.ts` and `src/active-tools.ts` wire tools into the active set, `src/settings.ts` owns the settings schema, `src/storage.ts` the session content store.
- `src/providers/` — one client per provider (`exa`, `exa-mcp`, `perplexity`, `gemini-api`, `gemini-web`, `duckduckgo`, `openai-native`); `src/provider-selection.ts` implements `auto` ordering.
- `src/tools/` — the registered tools (`web-search`, `web-research`, `web-fetch`, `web-answer`, `web-find-similar`, `code-search`, `get-web-content`) plus Exa rendering.
- `src/extract/` — extraction paths: `github`, `github-clone`, `html`, `http`, `pdf`, `pdf-pages`, `rsc`, `video`, `youtube`.
- `tests/` — `node:test` suites executed through `tsx`.
- `scripts/append-system.mjs` — vendored npm `postinstall`/`preuninstall` helper that upserts and removes the `instructions.md` payload in the scope-appropriate `APPEND_SYSTEM.md`.

## Build and test

```bash
npm run typecheck   # tsc -p tsconfig.json --noEmit
npm test            # tsx --test tests/**/*.test.ts
npm run check       # typecheck, then tests
```

## Stored content by path

- GitHub, direct HTTP, and PDF paths store full extracted text before preview truncation.
- YouTube transcript requests store complete native captions with timestamps. They never fall through to Exa excerpts when caption extraction fails.
- Exa-provider paths (`provider=exa` and auto-mode Exa fallback) store provider-capped excerpts (default 6000 chars; override per call with `textMaxCharacters`). `get_web_content` labels these as `stored excerpt` so the caller knows to set a larger cap or fetch directly if it needs the full document.

## Multi-URL preview caps

A single `web_fetch` call accepts many URLs via `urls`/`filePaths`. To keep `content[0].text` from blowing past the model's input window, multi-URL calls cap the aggregate preview size and emit a manifest for large batches. Single-URL calls and explicit `textMaxCharacters` opt-ins are unaffected.

| URLs in call | Per-URL preview | Aggregate cap | Format |
| --- | --- | --- | --- |
| 1 | `textMaxCharacters` (default 4k) | — | preview blocks |
| 2–5 | `min(textMaxCharacters, floor(16 KB / count))` | 16 KB | preview blocks |
| 6+ | 512 chars head | 25 KB | manifest of all URLs + short preview heads |

The sidecar (`pi-web-tools.content` events + `get_web_content`) stores per-URL full extracted text for direct/GitHub/PDF/HTTP paths and provider-capped excerpts for Exa paths. The aggregate cap only applies to the inline preview returned to the model. Pass `textMaxCharacters` to opt back into larger inlined previews when the caller knows the context budget allows it; for Exa paths the same flag also raises the provider-side excerpt cap.

## Transcript request semantics

- `transcriptLanguage` accepts a BCP 47 language code. Explicit base-language requests can recover matching regional tracks such as `en-US`; stored metadata records the selected track language.
- Caption-unavailable errors surface directly. The tool does not substitute an Exa page excerpt or label a generated summary as a complete transcript.
- `provider: "exa"` is rejected for transcript-only batches; use `auto` or `http`. Mixed batches keep transcript conflicts as explicit per-URL failures and continue unrelated URLs. Disabled video extraction follows the same mixed-batch behavior.
