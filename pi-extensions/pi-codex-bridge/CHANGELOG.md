# Changelog

## Consumer-impacting changes

### Unreleased

- `package.json` declares the supported Codex CLI releases as an optional `@openai/codex` peer range, and the bridge reads that range from its own installed copy. Codex 0.163.0 remains the one supported release. Codex 0.166.0 is not supported, because it offers the model Codex's own `apply_patch` file-edit tool, and the bridge allows the model only Pi's tools.
- An unsupported Codex release is refused with `codex-version-unsupported found=<version> supported=<list>`, which replaces `expected=0.163.0`.

### 1.0.0

- Add a Pi provider that runs account models through Codex CLI 0.163.0 and its existing login. Pi's tools run in Pi, configured MCP servers stay stopped, and Codex's native tools are refused.
