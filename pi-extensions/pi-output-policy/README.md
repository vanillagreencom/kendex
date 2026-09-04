# @vanillagreen/pi-output-policy

Keeps large output from swamping a Pi session: it stops a model response that has degenerated into repetition, and it bounds how much of a tool result stays inline while preserving the full text on disk. For anyone running long autonomous sessions or models that occasionally loop.

![Output Policy settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-output-policy/assets/settings-panel.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-output-policy"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-output-policy):

```bash
pi install npm:@vanillagreen/pi-output-policy
```

Restart Pi after installation.

## What it does

- Aborts a streaming assistant response when the same substantial line repeats past a threshold or the response passes a hard character cap; Pi keeps the partial response and a warning suggests a retry or another model.
- Truncates oversized tool results inline, from the head for search and listing tools and from the tail for command and log tools, and writes the full output to an artifact file named in the result.
- Leaves file reads and edit or write results untouched unless you opt them in.
- Compresses noisy shell output (git, npm, cargo, test runners) before truncation while keeping warnings, errors and summaries.
- Caps nested tool-result `details` and marks them as sanitized, skipping state-bearing tools whose details a restore depends on.
- Reports what was cut: size, lines, direction, artifact path, and bytes saved this turn and this session.

## How it works

Three policy modes size the caps. `balanced`, the default, keeps any single tool result small enough that a long run stays under provider request-buffer limits; `compact` stretches that further for very long runs; `compat` keeps only the wide caps that protect the TUI and turns details sanitization off. A knob you set overrides the mode's value for that knob. Truncation notices tell the agent how to continue: an offset for a head-truncated read, the artifact path for tail-truncated output. Pi's own built-in tools may truncate before this extension sees their output; custom tools that return large text benefit most.

## Customise

Open `/extensions:settings`; settings appear under the **Output Policy** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle; disabling it is the only way to get verbatim inline output, since `compat` still spills above its caps.
- `policyMode`: `balanced`, `compact` or `compat`.
- Model output guard: `modelOutputGuard.enabled`, `modelOutputGuard.maxChars`, `modelOutputGuard.repetition.enabled`, `modelOutputGuard.maxConsecutiveRepeats`, `modelOutputGuard.minRepeatBlockChars`, `modelOutputGuard.minRepeatedChars`; changes apply to the next assistant message.
- Truncation: `truncateReadOutputs`, `truncateMutationOutputs`, `spillThresholdKb`, `inlineTailKb`, `inlineTailLines`, `preserveFullOutput`.
- UI safety: `maxTextBlockKb`, `maxLineCount`, `maxLineWidth`, `sanitizeDetails`, `sanitizeDetails.exceptTools`.
- Shell minimizer: `shellMinimizer.enabled`, `shellMinimizer.only`, `shellMinimizer.except`, `shellMinimizer.maxCaptureBytes`.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
