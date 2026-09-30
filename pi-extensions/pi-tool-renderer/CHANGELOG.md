# Changelog

## Consumer-impacting changes

### Unreleased

- Replacement tools preserve Pi's output schemas and structured results, so codemode scripts receive structured bash output on Pi 0.99.0 and later. Tools without an output schema still work on earlier Pi versions.
- Malformed Git diff headers with unterminated quoted paths no longer freeze Pi while rendering tool output.

### 2.0.8

- User messages reuse Markdown layout during typing and streaming. Width, content and theme changes rebuild the layout.

### 2.0.7

- Long sessions no longer grow in memory with every read, bash, grep, find and ls call. Grouped tool calls are tracked only while `stackToolCalls` is on, at most 256 are kept (in groups of at most 64), each keeps at most 16,384 characters of its result, and all of them are cleared when a session starts or ends. Once a group has been dropped, a dropped call that Pi draws again (ctrl+o, a resize) is shown on its own, and the groups still kept and the group receiving live calls are left as they were. A tool display Pi no longer shows is not kept alive for the settings refresh.

### 2.0.6

- A project trust answer that another kendex Pi extension records now applies on the next settings read. Before, it applied only after the one-second window in which settings are answered from memory.

### 2.0.5

- Pi 0.86.0 parity: the replacement `read`, `bash`, `edit` and `write` tools carry Pi's `constrainedSampling` setting from the wrapped tool, so their requests keep Pi's strict-prefer JSON-schema sampling with the renderer active. Every replacement tool now forwards the wrapped tool's description, parameters, `constrainedSampling` and `prepareArguments`.

### 2.0.4

- Long sessions no longer hold Pi's main thread at full CPU under the renderer. Extension settings are read from disk at most once per second for each package and working directory, and, while tool chrome is on, each tool block keeps its drawn lines until its content, width, chrome mode or rule changes. A hand edit to `settings.json` now applies within one second; changes made through the extension manager and project trust changes still apply on the next render (#2837).

### 2.0.3

- Bash commands and `tool_batch` children run through the renderer keep Pi's session and model metadata: `PI_SESSION_ID`, `PI_SESSION_FILE`, `PI_PROVIDER`, `PI_MODEL` and `PI_REASONING_LEVEL` reach the command instead of arriving empty. The replacement tools and batch child calls forward Pi's execution context to the built-in tool unchanged (#3101).

### 2.0.2

- Batch refusal, timeout, and result notices start with stable keys and values.

### 2.0.1

- Pi 0.85.1 parity: the re-registered `edit` tool forwards Pi's `prepareArguments` hook from the wrapped definition. Argument shapes Pi's own tool normalizes before validation are accepted with the renderer active instead of failing validation.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-tool-renderer"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-tool-renderer"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-tool-renderer.assistant-message-patch`, `kendex.pi-tool-renderer.compaction-summary-renderer-patch`, `kendex.pi-tool-renderer.custom-message-spacing-patch`, `kendex.pi-tool-renderer.installed`, `kendex.pi-tool-renderer.markdown-code-block-patch`, `kendex.pi-tool-renderer.overlay-check`, `kendex.pi-tool-renderer.skill-invocation-renderer-patch`, `kendex.pi-tool-renderer.tool-chrome-patch`, `kendex.pi-tool-renderer.tool-chrome-theme`, `kendex.pi-tool-renderer.tool-execution-renderer-patch.v2`, `kendex.pi-tool-renderer.user-message-box-state`, `kendex.pi-tool-renderer.user-message-patch`, `kendex.pi-tool-renderer.working-loader-alignment-patch`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.7.2

- Documentation only, no runtime change. This version ships what landed on main after 1.7.1 was published: the packaged README trimmed to the consumer contract — what the extension does, its settings, and setup — with contributor-facing internals moved to the unpublished `DEVELOPMENT.md` (#1473), and a `test` script in the manifest, `bun test ./extensions/__tests__`, which the repo's CI and `tools/validate-changed` now run (#1474). Published so the npm and pi.dev gallery pages carry the current copy; `extensions/` is byte-identical to 1.7.1.

### 1.7.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
