# Changelog

## Consumer-impacting changes

### 1.0.2

- Codex CLI 0.166.0 is supported beside 0.163.0. Codex 0.166.0 offers the model its own `apply_patch` file-edit tool, and no setting removes it. On a bridge turn Codex answers that call itself, because the turn has no execution environment, so the call changes no file; the model edits files through Pi's tools. The bridge also turns off 0.166.0's plugin-directory prefetch at start.

### 1.0.1

- `package.json` declares the supported Codex CLI releases as an optional `@openai/codex` peer range, and the bridge reads that range from its own installed copy. Codex 0.163.0 remains the one supported release. Codex 0.166.0 is not supported, because it offers the model Codex's own `apply_patch` file-edit tool, and the bridge allows the model only Pi's tools.
- An unsupported Codex release is refused with `codex-version-unsupported found=<version> supported=<list>`, which replaces `expected=0.163.0`.

### 1.0.0

- Add a Pi provider that runs account models through Codex CLI 0.163.0 and its existing login. Pi's tools run in Pi, configured MCP servers stay stopped, and Codex's native tools are refused.
