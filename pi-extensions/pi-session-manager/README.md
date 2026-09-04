# @vanillagreen/pi-session-manager

A session manager overlay for Pi. It complements the built-in `/resume` with search, a lineage view, rename, and delete that can go to the trash.

![Session Manager overlay and model-change confirmation](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-session-manager/assets/session-manager.gif)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-session-manager"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-session-manager):

```bash
pi install npm:@vanillagreen/pi-session-manager
```

Restart Pi after installation.

## What it does

- `/sessions`, or the configured shortcut, opens the manager; tabs switch between the current project's sessions and all of them.
- Search by tokens, quoted phrases, or `re:<regex>`; the list filters as you type, and delete-all acts only on the sessions shown.
- A threaded view follows Pi's parent-session links and ranks branches by the newest activity anywhere in the subtree; `recent` and `relevance` sorts are one key away.
- The detail pane shows each session's working directory and saved model. Resuming keeps the saved model, and when your active model differs a confirmation lets you pick either.
- Inline rename, and delete with confirmation. Deleting a session also removes the per-session data every kendex extension keeps for it.
- Session titles match `/resume`: the explicit name, else the first user message, else the file name. Session files are read line by line, so a large session never loads whole to be listed or searched.
- Pi's own `/resume`, `/tree`, `/fork`, `/clone` and `/name` stay available; the overlay's footer documents its keys.

## How it works

The overlay lists Pi's session files, reads only the header and user-message lines it needs, and hands a chosen action back to Pi: a resume switches the session through Pi's own session API, a delete tries the `trash` command first and unlinks only when that is unavailable.

## Customise

Open `/extensions:settings`; settings appear under the **Session Manager** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` chrome, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: master toggle.
- `shortcutKey`: the opening shortcut; `none` disables it.
- `defaultScope`, `defaultSort`: the tab and sort the overlay opens with.
- `visibleRows`, `overlayWidth`: overlay size.
- `deleteUsesTrash`: try `trash` before a permanent unlink.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
