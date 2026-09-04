# pi-nested-agents-md development

For maintainers. What it does for a consumer is [README.md](README.md); the mechanics are the doc comments in `extensions/nested-agents-md.ts`.

## Invariants

- The bound is checked on canonical paths or not at all. `extensions/nested-agents-md.ts::attachments` resolves the file, the cwd and the root through `realpath` and attaches nothing when any of them cannot be resolved or the file does not lie under the root; a read reached through a symlink is judged by where it landed. `tests/nested-agents-md.test.ts` plants both the direct and the symlinked escape.
- The project root is kendex's own rule, `extensions/config.ts::projectRoot` copying `crates/core/src/discover.rs::project_root_from` with the marker set and lock file pi-hooks carries. The root this finds is the root kendex rendered shims into; a marker only one side knows is an `AGENTS.md` attached from the wrong tree or never.
- Order is root-most first, the order Claude Code layers nested `CLAUDE.md`; `directoriesBetween` throws rather than walk to the filesystem top when handed a file outside the root, because its callers hold that precondition.
- A file is recorded as attached when taken, the unreadable ones included, so the model hears about each file once per session; the record is replaced on every `session_start`.
- An unreadable `AGENTS.md` never fails the read. The block is one line naming the file and the reason.
- Project settings are read only after `recordProjectTrust` saw Pi report the workspace trusted, and `PI_CODING_AGENT_DIR` counts only when root-anchored, matching `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`.

## Tests

```bash
cd pi-extensions/pi-nested-agents-md
npm test
```

`bun test ./tests`; the suite imports nothing from Pi outside type positions, so no install is needed. It builds a project tree in a temporary directory with the root bound canonical at creation, and points `PI_CODING_AGENT_DIR` at an empty root so the developer's own global settings never answer. A new rule about what attaches ships with the case that plants its counterexample.
