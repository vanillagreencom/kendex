# @vanillagreen/pi-caveman

Caveman communication mode for Pi: fewer output tokens, the same technical accuracy. A mode is a system-prompt directive the model holds across turns; the extension steers style and never rewrites output.

![/caveman command autocomplete](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-caveman/assets/command-autocomplete.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-caveman"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-caveman):

```bash
pi install npm:@vanillagreen/pi-caveman
```

Restart Pi after installation.

## What it does

- Four modes: `lite` (tight professional sentences, no filler or hedging), `full` (terse, fragments allowed), `ultra` (maximum compression with abbreviations and arrows), `micro` (the shortest directive, for token-sensitive sessions).
- `/caveman` toggles the session between off and the last active mode; `/caveman:lite`, `:full`, `:ultra`, `:micro` set a session override; `/caveman off`, `/caveman status` and `/caveman debug` clear it, show where the mode comes from, and print the rendered directive. Arguments autocomplete.
- Replies stay flowing chat with no markdown headers, and no marker lines or `Caveman` prefixes leak into answers.
- When a prompt names an irreversible destructive operation (force-push, hard reset, drop table, `rm -rf`, branch delete) the model answers that one reply in plain English and resumes caveman on the next turn.
- Code blocks, quoted errors, commit messages, PR descriptions, formal reviews and anything sent to other systems stay normal English, each boundary its own toggle.
- A session keeps the mode it started with across `pi -r`, including slash-command changes made before the next model turn, even when the default changes later; changing the default in the settings editor replaces the session override.
- `pi-qol` shows a Caveman badge in its statusline and cycles modes on alt+c.

## How it works

Before every model turn the extension reads the configured mode and the session override, renders one directive block for the effective mode, and appends it to Pi's system prompt. Session state lives in a small sidecar file under the session's kendex data folder, so a resumed session restores its override without replaying the conversation.

## Customise

Open `/extensions:settings`; settings appear under the **Caveman** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `mode`: the default mode for new sessions.
- `showStatusBadge`, `sessionOverrideAllowed`: the statusline badge and whether `/caveman` commands may override the default.
- `autoClarityEscape`, `resumeAfterClarityEscape`: the plain-English reply for destructive operations and the return to caveman afterwards.
- `boundaryNormalForCode`, `boundaryNormalForCommits`, `boundaryNormalForReviews`, `boundaryNormalForExternalWrites`: which outputs stay normal English.
- `customPromptSuffix`: project-specific guidance appended to the directive.

With `pi-claude-bridge` as the provider the directive reaches Claude only when the bridge's `includeCavemanHook` setting is on; it is off by default, and caveman warns once at session start while it is off. Native Pi providers need nothing.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
