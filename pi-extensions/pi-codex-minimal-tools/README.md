# @vanillagreen/pi-codex-minimal-tools

Codex-style tools for Pi on OpenAI and Codex models: `image_generation`, `view_image` and `apply_patch`, plus a background `/image-gen` command. Pi's native `read`, `grep`, `find`, `ls`, `bash`, `edit` and `write` stay as they are. Web search is in [pi-web-tools](../pi-web-tools/README.md).

![apply_patch side-by-side diff rendering](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-codex-minimal-tools/assets/apply-patch-rendering.png)

![image_generation lifecycle](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-codex-minimal-tools/assets/image-generation.gif)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-codex-minimal-tools"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-codex-minimal-tools):

```bash
pi install npm:@vanillagreen/pi-codex-minimal-tools
```

Restart Pi after installation.

## What it does

- `image_generation` on image-capable `openai-codex` models, through OpenAI's native tool; generated images are saved with a timestamp name and a `latest.<ext>` mirror and previewed inline.
- `/image-gen <prompt> [reference.png]` generates or edits an image in the background through Codex OAuth, with a live status card, while the agent carries on. It needs no `OPENAI_API_KEY`.
- `view_image` returns a local image to the model as image content. Off by default.
- `apply_patch` applies a Codex-format patch locally, with add, update, delete and move, and rolls back every touched file when one hunk fails.
- A Codex provider shim that keeps session and cache identifiers within provider limits, retries a missing cached continuation once with full context, and preserves `HTTP <status>:` prefixes on failures so Pi can classify limits and retries.
- `/codex-minimal-tools` opens the settings and `/codex-minimal-tools:doctor` prints which tools are supported and active for the current model, and why.

## How it works

The tools register once an OpenAI or Codex model is loaded and join Pi's active set only on a model that supports them; on any other model they are removed again. On `openai-codex` the outgoing request is rewritten so `image_generation` becomes the provider's native tool. Patch paths resolve against the workspace and a path that escapes it is refused unless `allowAbsolutePatchPaths` is on. Rendering of `apply_patch` is left to `pi-tool-renderer` when it is present.

## Customise

Open `/extensions:settings`; settings appear under the **Codex Minimal Tools** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`, `autoEnable`: the package and whether its tools join the active set on their own.
- `nativeProviderTools`: the Codex provider shim and the native `image_generation` rewrite.
- `imageGeneration`, `imageOutputDir`, `imageModel`, `directImageApiFallback`: image generation, where images land (relative to the workspace), and the direct Images API fallback, which needs `OPENAI_API_KEY`.
- `viewImage`, `viewImageWorkspaceOnly`: the `view_image` tool and whether it may read outside the workspace.
- `applyPatchEnabled`, `strictPatchMode`, `allowAbsolutePatchPaths`, `deferApplyPatchRendering`: the patch tool; strict mode removes `edit` and `write` from the active set so every edit goes through `apply_patch`.
- `glyphStyle`: Unicode or ASCII chrome; `pi-tool-renderer`'s global override wins when set.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
