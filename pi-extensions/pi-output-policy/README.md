# @vanillagreen/pi-output-policy

A Pi extension that limits large tool results and repeated model output. It saves full tool output to files so the agent can read it when needed.

![Output Policy settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-output-policy/assets/settings-panel.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-output-policy`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-output-policy"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Stop model responses that exceed configured size or repetition limits.
- Show a preview of large tool results and save the full output.
- Reduce common shell output while retaining errors and summaries.
- Report saved output paths and the amount removed from the preview.

## How it works

The extension watches model output and completed tool results. It checks them against the selected policy and your overrides. Large tool results become previews with a link to the full saved text. A model response that crosses a configured limit stops with a warning.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-output-policy"]`.

Open `/extensions:settings`; settings appear under the **Output Policy** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle; disabling it is the only way to get verbatim inline output, since `compat` still spills above its caps.
- `policyMode`: `balanced`, `compact` or `compat`.
- Model output guard: `modelOutputGuard.enabled`, `modelOutputGuard.maxChars`, `modelOutputGuard.repetition.enabled`, `modelOutputGuard.maxConsecutiveRepeats`, `modelOutputGuard.minRepeatBlockChars`, `modelOutputGuard.minRepeatedChars`; changes apply to the next assistant message.
- Truncation: `truncateReadOutputs`, `truncateMutationOutputs`, `spillThresholdKb`, `inlineTailKb`, `inlineTailLines`, `preserveFullOutput`.
- Display limits: `maxTextBlockKb`, `maxLineCount`, `maxLineWidth`, `sanitizeDetails`, `sanitizeDetails.exceptTools`.
- Shell minimizer: `shellMinimizer.enabled`, `shellMinimizer.only`, `shellMinimizer.except`, `shellMinimizer.maxCaptureBytes`.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
