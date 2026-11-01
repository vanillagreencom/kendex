# `AGENTS.md`

Read when writing, editing or reviewing a root or nested `AGENTS.md`.

Read by every harness at the start of every session. What the repo is in two or three sentences; the commands not discoverable from the tooling; the conventions that differ from a tool default or a language norm; task triggers for principle docs, directly or through named nested `AGENTS.md` files. Keep only rules no linked principle doc owns; route to that doc instead of repeating its rules. Codex reads only the root-to-cwd chain of `AGENTS.md` files. Before changing a directory, read its applicable nested instructions even when the harness did not load them. Never: anything derivable from the code, rationale, history. Example: [examples/root-agents.md](../examples/root-agents.md).

Repository agent instructions live in `AGENTS.md` alone. A repository keeps no `CLAUDE.md`: no root or nested `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`. [Claude Code reads `AGENTS.md` natively](https://code.claude.com/docs/en/memory#agents-md) from [v2.1.277](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21277). The user-scope `~/.claude/CLAUDE.md` is a harness setting, not a repository document.

## `<dir>/AGENTS.md`

Read by an agent working in that folder. Keep the folder's commands and rules no linked principle doc owns, with no rationale. Give a task trigger for that doc instead of repeating its rules. An approach belongs in architecture when one reader's task needs it to prevent a harmful mistake, whatever folders the task crosses. Examples: [examples/nested-agents-plugins.md](../examples/nested-agents-plugins.md), [examples/nested-agents-components.md](../examples/nested-agents-components.md).
