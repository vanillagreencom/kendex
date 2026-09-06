# Pi package update audit: 0.84.3 to 0.85.1

Marker `0.84.2` → `0.85.1`. Audited against base `8d056a7f`. Sources fetched: every `*/CHANGELOG.md` in the Pi tree at `v0.85.1` (`agent`, `ai`, `client`, `coding-agent`, `protocol`, `server`, `session-backends/sqlite-node`, `telemetry`, `tui`), plus the curated release notes. The previous marker's `storage` key was an alias for the sqlite-node backend path; the marker now carries the path-derived key `session-backends/sqlite-node`, and `client`, `protocol` and `telemetry` are newly enumerated. `Unreleased` blocks scanned for heads-up only and excluded from the marker.

In scope since the previous marker: four releases, `0.84.3` (2026-08-24), `0.84.4` (2026-08-28), `0.85.0` (2026-09-04), `0.85.1` (2026-09-05). `client`, `protocol`, `server`, `session-backends/sqlite-node` and `telemetry` sections are empty across the range. The `coding-agent` changelog restates `ai`, `agent` and `tui` entries as `inherited`; those restatements are not counted as separate items.

## Counts

| Bucket | Count |
|---|---:|
| Required parity fix | 3 |
| Optional improvement (deferred) | 4 |
| Non-impact | grouped below, not tallied |

## Shipped

Three fixes, each with a test at the function that changed and a red-first control.

| Item | Extension | Fix |
|---|---|---|
| Compaction and branch summaries reject token-capped generations (0.84.3, [#7048](https://github.com/earendil-works/pi/issues/7048)) | `pi-qol` | `singleShotSummary` in `extensions/qol/compaction.ts` now throws on `stopReason: "length"`, matching Pi's `getSummarizationFailure`. The single function feeds the direct, chunk/reduce and branch-summary consumers, so all three reject an incomplete summary before it can become the continuation checkpoint. Reachable with `compaction.customEnabled` off through the budget-guard sentinel. Test: `tests/compaction-length-stop.test.ts`. |
| OpenAI Codex SSE parsing processes a terminal event not followed by a blank line (0.85.0, [#9047](https://github.com/earendil-works/pi/issues/9047)) | `pi-codex-minimal-tools` | `parseSSE` in `src/provider-shim.ts` flushes the decoder at EOF and treats EOF as the end of the residual frame, mirroring Pi's `openai-codex-responses.ts`. Before the fix a completed response whose last frame lacked the trailing blank line reported `Stream closed before response.completed` on the SSE transport, which is shipped both as an explicit setting and as the fallback after a pre-start WebSocket failure. CRLF normalization and the ignore-malformed-frame policy are unchanged. Test: `tests/provider-shim-http-status.test.ts`, one row per line-ending shape plus a malformed-residual control. |
| Single-object `edit` inputs accepted as one-edit arrays (0.84.3, [#7835](https://github.com/earendil-works/pi/issues/7835)) | `pi-tool-renderer` | `registerEdit` in `extensions/tool-renderer/tools.ts` re-registers Pi's edit tool and copied only `description` and `parameters`, dropping `prepareArguments`. Pi's agent loop runs that hook before schema validation, so with `renderMutationTools` on, the shapes Pi's own tool normalizes (single edit object, JSON-string edits, legacy `oldText`/`newText`) failed validation before `execute` could delegate. The registered definition now forwards the original hook; nothing is duplicated locally. The 0.84.2 audit's "no extension ships an edits-array tool" was wrong for this source. Test: `extensions/__tests__/edit-prepare-arguments.test.ts`. |

Not live-tested inside Pi; each fix is proven at its unit surface against the installed peer packages.

## Deferred (Optional)

| Item | Reasoning |
|---|---|
| `ui_prompt_start` / `ui_prompt_end` and `session_compact_failed` extension events (0.84.3, 0.85.0) | `pi-session-bridge` republishes an explicit event allowlist (`extensions/session-bridge.ts:49-65`) and publishes `ctx.isIdle()`; a waiting-for-input distinction would help orchestration but the bridge never promised these events. `pi-qol` already has completion and error callbacks on the compactions it starts. Adopt with a bridge design, not in a parity round. |
| RPC `clear_queue` (0.84.4) | Pi stdio RPC, not a method of kendex's socket bridge. Adding it is a bridge feature. |
| `SessionManager.inMemory()` restorable sessions, summary routing ids, `detectSupportedImageMimeTypeFromFile` (0.85.0) | Additive SDK. The file-backed session manager and local image format detection stay correct; no net simplification without a redesign. |
| Embedded working indicator in the default editor (0.85.0, [#8799](https://github.com/earendil-works/pi/pull/8799)) | `CustomEditor` defaults `embedWorkingStatus` to false, so `QolEditor` and `QolCompactPromptEditor` keep the standalone indicator; the compact editor strips its top border, so embedding needs a deliberate layout choice. |

The 0.84.2 deferral of `sendUserMessage(..., { expandPromptTemplates: true })` stands unchanged; see the previous audit's reasoning (skill-hash reminder cache, live peer test).

## Non-impact

Already protected or inherited beneath us:

- **Built-in tools honor `ctx.cwd` (0.85.0, [#8627](https://github.com/earendil-works/pi/pull/8627))**: `pi-tool-renderer` caches built-in tools per normalized cwd and picks the execution context's cwd before delegating (`tools.ts:56-83`, `batch.ts:261-263`).
- **Write tool byte-count removal (0.85.0, [#8979](https://github.com/earendil-works/pi/issues/8979))**: our write renderer reports line totals and diffs, never the UTF-16 count; raw output delegates to Pi.
- **`NO_PROXY` root and subdomain matching (0.85.0, [#8737](https://github.com/earendil-works/pi/pull/8737))**: `provider-shim.ts` `noProxyMatches` already strips a leading dot and matches exact host or `.domain` suffix; `tests/provider-shim-proxy.test.ts` covers it.
- **Record-only `sendMessage` ordering (0.84.4)**: benefits our `triggerTurn: false` sites; the hooks' end-of-turn report keeps `triggerTurn: true` on purpose.
- **Session newline repair, fork compaction boundary, import collisions, concurrent share writes (0.85.0)**: `pi-session-manager` goes through `SessionManager.open` and SDK append on the normal path. Its exception-path `appendSessionInfoFallback` does no newline repair; that combination was not established as a shipped producer path.
- **Truncated-response recovery no longer labeled context overflow (0.84.3, [#8130](https://github.com/earendil-works/pi/issues/8130))**: `pi-agents-tmux` matches explicit context-length errors, not the generic truncated text; no regex change.
- **Skill discovery fixes, BOM tolerance, root Markdown in skill dirs**: `pi-skills-manager` resolves through Pi's package resolver and `parseFrontmatter`, then drops entries without name/description.
- **Branch summary token cap raised to 4096, reasoning-consumed cap fix ([#8845](https://github.com/earendil-works/pi/issues/8845))**: QOL's default is 8192 (`constants.ts`); the length-stop rejection above is the part that mattered.

Provider and model catalog (our overrides are `openai-codex` in `pi-codex-minimal-tools` and the Claude native provider in `pi-claude-bridge`):

- **GPT-6 Astra (0.85.1)**: the Codex shim already recognizes `gpt-6-astra` (`provider-shim.ts:499`).
- **Responses `prompt_cache_options.ttl` (0.85.1)**: the shim sends `prompt_cache_key` and neither `prompt_cache_retention` nor `prompt_cache_options`; it never emitted the obsolete field.
- **Persistent Claude thinking effort, signed-thinking recovery, refusal fallback (0.84.3, 0.85.0)**: Anthropic Messages transport. The bridge drives the Claude Agent SDK and maps thinking levels itself (`query-options.ts`); parity with Pi's per-turn effort markers is not claimed and needs its own verification if wanted.
- **Copilot Fable transport, Gemini/Vertex, Bedrock, xAI Responses, ZAI, DeepSeek, Qwen, Baseten, Fireworks, Mistral, Cerebras, Cloudflare, Kimi, Xiaomi, vLLM and llama.cpp catalog and adapter fixes; `vllmPriority`, `supportsMaxOutputTokens`; provider-neutral `toolChoice`; `GoogleThinkingLevel` rename; `createGatewayBindingFetch`; default `User-Agent`; CONNECT tunneling for proxied plain-HTTP**: built-in transports we neither register nor override. The QOL summary call passes no tools, so `toolChoice` does not apply to it.

Host, SDK and platform:

- **`prepareNextTurn` between-turn compaction, withdrawn `AgentHarness` controls (0.84.4)**: no consumer in extension TypeScript; QOL handles `agent_end`, `agent_settled` and `session_compact`.
- **0.85.0 published experimental `client`/`experimental/plugin` subpaths; 0.85.1 made them source-only and repaired SDK imports ([#9132](https://github.com/earendil-works/pi/issues/9132))**: no import of either subpath in our extensions; the supported SDK and stdio RPC are unchanged.
- **`pi update` registry-version comparison ([#8226](https://github.com/earendil-works/pi/issues/8226))**: reconciles `git:`/`npm:` entries only; kendex path packages stay out of scope.
- **Agent CLI `--` task delimiter**: `pi-agents-tmux` prefixes tasks with `Task: ` (`runner.ts:672`), so a dash-prefixed task never reached the parser.
- **Managed `fd`/ripgrep downloads, SEA extension loading, lazy runtime, package globs, update staging, clipboard packaging, auth-file ACLs, EXIF orientation, selector save keybindings, RPC `abort` cancelling manual compaction, skills with Bash-only tools, optional PowerShell tool**: Pi host behavior. PowerShell receives no kendex renderer or hook policy; adding Windows policy coverage is a separate choice.
- **TUI: fullscreen transcript search caching, jump-to-latest label, Alt wheel acceleration, hover selection fix, drag selection, seccomp `SIGWINCH`, Zed image detection, LaTeX join symbols, `PI_DEBUG_REDRAW` → `PI_TUI_DEBUG_REDRAW`, renderer constructor defaults ([#8699](https://github.com/earendil-works/pi/pull/8699))**: no `new TUI`/`new TuiAltScreen` or `PI_DEBUG_REDRAW` in our extensions; our popups and renderers build on Pi's components. Standing caveat: popups were not live-tested in fullscreen this run either.

## Heads-up (`Unreleased`, not processed)

- **Strict-prefer JSON-schema sampling becomes the default for built-in `read`, `bash`, `powershell`, `edit`, `write`; extensions may set `constrainedSampling: false`**: `pi-tool-renderer` re-registers those tools and does not forward `constrainedSampling` today. Decide on forwarding when this releases.
- Login waits for catalog discovery before declaring models missing; Radius defaults changed. Host only.
