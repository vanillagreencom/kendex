# Changelog

## Consumer-impacting changes

### 2.0.3

- **The Codex provider shim sends the system prompt and tools again on Pi 0.86.0 and later.** Pi 0.86 moved the system prompt and the tool declarations out of a provider's `systemPrompt` and `tools` fields and into the transcript's `system` messages. The Codex provider shim still read the old fields, so on Pi 0.86 and later every `openai-codex` request reached the model with no system prompt and no tools. The shim now reads both from the transcript, with later system messages folded into the instructions and the tool set, and sends no `system` message as an input item. On a Pi host below 0.86.0 it still reads the old fields, as before.
- Long Codex sessions spend less of Pi's main thread per turn. Tool-call arguments are parsed when the call completes instead of on every streamed chunk, and streamed text is appended instead of rebuilt. A cached WebSocket request no longer serializes the whole transcript, and SSE request compression runs off the main thread.

### 2.0.2

- Patch and image validation errors expose stable error codes. Grammar schema and response-header timeout errors include a stable key and value before their explanation.

### 2.0.1

- Pi 0.85.1 parity: the SSE transport no longer fails with "Stream closed before response.completed" when the backend closes the stream right after the terminal event without a trailing blank line. The last frame is parsed at end of stream.
- `gpt-6-astra` replaces `gpt-5.6-sol` in the OpenAI model probe lists and as the model with the 2.5x `priority` service-tier cost multiplier.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-codex-minimal-tools"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-codex-minimal-tools"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-codex-minimal-tools.installed`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.4.0

- Pi 0.84.0 parity: `null` provider headers are now treated as deletion markers. `ModelRegistry.getApiKeyAndHeaders()` returns `ProviderHeaders` (`Record<string, string | null>`) where `null` means "remove this header"; the background image-generation request passed them to `Headers.set()`, which stringified them and transmitted the literal `"null"`. `buildHeaders()` is now exported and deletes on `null`.

### 1.3.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
