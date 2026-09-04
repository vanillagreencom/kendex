# @vanillagreen/pi-nested-agents-md

Pi loads `AGENTS.md` from the directory it starts in and from every directory above it, never from one below. This extension attaches a subdirectory's `AGENTS.md` to the model's context the first time the agent reads a file under that directory, so local conventions arrive when the model works there and cost nothing until then.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-nested-agents-md"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-nested-agents-md):

```bash
pi install npm:@vanillagreen/pi-nested-agents-md
```

Restart Pi after installation.

## What it does

- On a successful `read`, appends every `AGENTS.md` between the file's directory and the project root to the read result, each under a line naming its path, root-most first.
- Attaches each file once per session; a session start of any kind begins the record again.
- Skips the files Pi loaded at startup: the project root's own, and any in the directory Pi started in or above it.
- Stays inside the project, resolved the way kendex resolves it. A path outside the project, or one that reaches outside through a symlink, attaches nothing; so does a session in no project.
- Reports an `AGENTS.md` it cannot read in one line inside the read result, and the read still succeeds.

Behaviour follows the community extension [code-yeongyu/pi-nested-agents-md](https://github.com/code-yeongyu/pi-nested-agents-md); the code is kendex's own.

## How it works

A `tool_result` listener on `read` resolves the file and the project root through symlinks, lists the directories between them, and takes each `AGENTS.md` the session has not seen. Only `AGENTS.md` is looked for: kendex renders the `CLAUDE.md` shim beside it, and Pi's own loader covers `AGENTS.override.md` and `CLAUDE.md` for the directories it reads at startup.

## Customise

Open `/extensions:settings`; settings appear under the **Nested AGENTS.md** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
