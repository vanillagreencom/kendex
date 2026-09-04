# @vanillagreen/pi-skills-manager

A skills manager for Pi. One `/skill` view browses, previews, creates, edits, renames, deletes and toggles skills, while Pi's native `/skill:<name>` invocation stays as it is.

![Skills Manager overlay](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-skills-manager/assets/skills-manager.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-skills-manager"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-skills-manager):

```bash
pi install npm:@vanillagreen/pi-skills-manager
```

Restart Pi after installation.

## What it does

- `/skill` opens the manager, with project, global and package skills listed separately and searchable by name, description, source, scope and path.
- Enter inserts an enabled skill into the editor as its native `/skill:<name>` command; tab previews the frontmatter and rendered body.
- Create a project or global skill from a name, a trigger-focused description and a location; the current model drafts the `SKILL.md`, and a deterministic template stands in when the model is unavailable or fails.
- Edit, rename and delete your own top-level skills. Package skills are preview, toggle and insert only.
- Toggling a skill writes Pi's own package filter patterns, so the change holds outside the manager too.
- Hides Pi's startup `[Skills]` block so discovery lives in the manager.
- `/skill disable` turns the feature off; `/skill:enable` turns it back on and reloads.
- Native `/skill:<name>` registration is Pi's `enableSkillCommands` setting and is left alone.

## How it works

The manager reads the skills Pi's resource loader already discovered, renders them in a popup that documents its keys in the footer, and writes through Pi's settings manager for toggles and through the filesystem for create, edit, rename and delete.

## Customise

Open `/extensions:settings`; settings appear under the **Skills Manager** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` chrome, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: master toggle.
- `hideStartupSkillsBlock`: hide Pi's startup `[Skills]` list.
- `aiGenerationEnabled`, `defaultCreateLocation`: how and where a created skill is drafted.
- `popupWidth`, `popupMaxHeight`, `listRows`: overlay size; short terminals shrink the list so the controls stay visible.

Based on ideas from the MIT-licensed [`@kmiyh/pi-skills-menu`](https://github.com/Kmiyh/pi-skills-menu); see `THIRD_PARTY_NOTICES.md`. Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
