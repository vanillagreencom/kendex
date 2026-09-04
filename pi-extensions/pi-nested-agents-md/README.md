# @vanillagreen/pi-nested-agents-md

Pi loads `AGENTS.md` from the directory it starts in and from every directory above it, and never from a directory below. This extension attaches a subdirectory's `AGENTS.md` to the model's context the first time the agent reads a file under that directory, so a directory's local conventions reach the model when it works there and cost nothing until then.

## Behavior

- On every successful `read`, the extension walks from the file's directory up to the project root. Each `AGENTS.md` it passes that this session has not yet attached is appended to the read result as its own block, under a line naming the file's path.
- Root-most first, nearest last: `crates/AGENTS.md` before `crates/core/AGENTS.md`. This is the order Claude Code layers nested `CLAUDE.md` files, so a general rule is read before the one that refines it.
- Once per session per file. A later read under a directory already attached adds nothing. A session start, of any kind, begins the record again.
- Never the project root's own `AGENTS.md`, and never one from the directory Pi started in or from any directory above it: Pi loaded those at startup.
- Bounded by the project root, resolved the way kendex resolves it: a `.kendex-lock.json` wherever it stands, otherwise the nearest ancestor of the cwd carrying a harness marker directory (`.claude/`, `.codex/`, `.opencode/`, `.cursor/`, `.pi/`, `.agents/`, `.gemini/`). A read of a path outside that root attaches nothing, including a path inside the project that reaches outside through a symlink. A cwd in no project attaches nothing.
- Only `AGENTS.md` is looked for. Pi's own loader also takes `AGENTS.override.md` and `CLAUDE.md` from the directories it covers; a nested directory's instructions live in `AGENTS.md`, with kendex rendering the `CLAUDE.md` shim beside it.
- An `AGENTS.md` that cannot be read is reported to the model in one line inside the read result, once per session, and the read itself still succeeds.

Behavior follows the community extension [code-yeongyu/pi-nested-agents-md](https://github.com/code-yeongyu/pi-nested-agents-md); the code is kendex's own.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-nested-agents-md"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing; `kendex refresh` leaves Pi packages to `update-pi`.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-nested-agents-md):

```bash
pi install npm:@vanillagreen/pi-nested-agents-md
```

Restart Pi after installation.

## Settings

Open `/extensions:settings`; settings appear under the **Nested AGENTS.md** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, kendex Pi extensions read user/global settings only.

| Setting | What it does |
| --- | --- |
| Enable nested AGENTS.md | Master toggle. Disable to make the extension inert without uninstalling. |
