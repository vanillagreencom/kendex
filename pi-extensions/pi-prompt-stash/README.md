# @vanillagreen/pi-prompt-stash

A per-session prompt stash for Pi. Save a draft, write something else, restore the draft later.

![Prompt Stash popup](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-prompt-stash/assets/stash-popup.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-prompt-stash"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-prompt-stash):

```bash
pi install npm:@vanillagreen/pi-prompt-stash
```

Restart Pi after installation.

## What it does

- One shortcut does both: with text in the editor it stashes the draft, with an empty editor it opens the popup. `/prompt-stash` opens the popup too.
- The popup searches, restores, deletes and clears stashes, and documents its keys in the footer.
- Stashes belong to the session and survive Pi restarts within it.
- Optional deduplication drops older entries with the same text.

## How it works

Stashes are a JSON file under the session's kendex data folder, `<Pi root>/kendex/sessions/<session>/prompt-stash/`, written atomically on every change; deleting the session through `pi-session-manager` removes it.

## Customise

Open `/extensions:settings`; settings appear under the **Prompt Stash** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` chrome, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: master toggle.
- `shortcut`: the stash-or-open shortcut.
- `storeFile`: the file name inside the session's stash folder.
- `deduplicate`: drop older entries with identical text.
- `popupWidth`, `popupMaxHeight`, `listRows`: popup size.
