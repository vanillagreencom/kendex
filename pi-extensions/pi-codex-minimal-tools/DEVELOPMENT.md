# pi-codex-minimal-tools development

For maintainers. What it does for a consumer is [README.md](README.md); the provider shim's doc comments in `src/provider-shim.ts` hold its wire-format mechanics.

## Invariants

- Only package tools are managed. `src/capabilities.ts::computeNextActiveTools` adds and removes the names in `PACKAGE_TOOL_NAMES`, and in strict patch mode `edit` and `write`, and nothing else; `tests/capabilities.test.ts` holds that native tools survive every sync.
- Tools register lazily, once `src/activation.ts::hasOpenAiModelsLoaded` is true, and are removed from the active set whenever it is not. A session on a non-OpenAI model must never see them, even with OpenAI models in the registry.
- Each tool's availability is one function, `src/capabilities.ts::computeToolCapabilities`, and the doctor command prints its reasons from that same function. A new gate goes there, with its reason string.
- The Codex provider shim in `src/provider-shim.ts` is held to Pi's own `openai-codex` provider: cache and session ids clamp to `OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH`, `cacheRetention: "none"` suppresses the session cache key, sessionless WebSocket requests use UUIDv7, a `previous_response_not_found` retries once with full context, and the retry classifier mirrors upstream. `tests/provider-shim-parity.test.ts` is the parity suite; a Pi release that changes the wire format is matched there first.
- Provider failures keep their `HTTP <status>:` prefix (`tests/provider-shim-http-status.test.ts`), because Pi's limit and retry classification reads it.
- `apply_patch` paths resolve through `src/patch/apply.ts::resolvePatchPath` and a path outside `cwd` throws unless `allowAbsolutePaths`; application is all-or-nothing, rolling back touched files on a failed hunk, and CRLF files keep their line endings when the patch context is LF (`tests/apply-patch.test.ts`).
- `apply_patch` rendering is deferred to `pi-tool-renderer` by default; `tests/renderer-compatibility.test.ts` holds the tool definition to the shape that renderer assumes, so a change to either side is made in both.
- `/image-gen` authenticates with the token and headers Pi's model registry returns for the `openai-codex` provider and never with `OPENAI_API_KEY`; only `directImageGeneration` in `src/tools/image-generation.ts` reads the key, and only when `directImageApiFallback` is on.
- Project settings are read only after `recordProjectTrust` saw Pi report the workspace trusted, and `PI_CODING_AGENT_DIR` counts only when root-anchored, matching `crates/core/src/harness/pi.rs::pi_root_is_absolute_for` (`src/settings.ts`).

## Tests

`node:test` suites under `tests/`, run through `tsx`. The host packages are optional peers and are not installed in the tree:

```bash
cd pi-extensions/pi-codex-minimal-tools
npm install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund @earendil-works/pi-ai@0.84.1 @earendil-works/pi-coding-agent@0.84.1 @earendil-works/pi-tui@0.84.1 typebox 'undici@^7.25.0'
npm run check
```

`npm run check` is `typecheck` then `test`; `.github/workflows/skill-tests.yml` runs the same install. Provider suites stub `fetch` and assert the request bodies and streamed responses; a shim change ships with its parity case.
