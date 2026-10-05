# @vanillagreen/pi-codex-minimal-tools

Image and patch tools for Pi sessions using OpenAI or Codex models. It adds image generation, local image viewing and patch editing.

![apply_patch side-by-side diff rendering](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-codex-minimal-tools/assets/apply-patch-rendering.png)

![image_generation lifecycle](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-codex-minimal-tools/assets/image-generation.gif)

## Features

- Generate or edit images and display the saved output.
- Run image generation in the background.
- Show a local image to the model.
- Apply patches that add, change, move or delete files.
- Inspect tool availability for the current model.

## Install

- npm: `pi install npm:@vanillagreen/pi-codex-minimal-tools`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-codex-minimal-tools"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## How it works

The extension checks the selected model and enables supported tools. An image request goes to the configured provider and saves the result in the output directory. An image-view request reads a local file into the model context. A patch request updates workspace files and reports the changes.

## Request limits

- Codex SSE requests remain cancellable after response headers arrive. A body that stops sending data ends at Pi's HTTP idle timeout. The same timeout applies to a silent WebSocket. A WebSocket that cannot open ends at Pi's WebSocket connect timeout.
- The HTTP idle timeout defaults to 300,000 ms. The WebSocket connect timeout defaults to 15,000 ms. Pi passes its `httpIdleTimeoutMs` setting to providers as `timeoutMs`; `websocketConnectTimeoutMs` controls the handshake. Zero disables the corresponding idle or connect deadline.
- `/image-gen` runs at most four jobs at once. An additional command reports that the limit is reached. Session shutdown aborts every active image request and clears its status.

## Memory use

- The background-image status keeps one rendered layout of at most 65,536 characters and elapsed-time keys for at most four displayed jobs. Job changes, resizing, elapsed seconds and theme invalidation replace the layout. Session shutdown clears the cache and stops its redraw timer.
- A WebSocket response may hold at most 33,554,432 characters of received events that the reader has not taken yet, counted as each event arrives and before it is decoded; a binary frame counts its bytes. Past that the response stops with an error whose first line starts `codex-websocket-queue-overflow=`.
- Generated-image previews are read from disk in the background the first time a message shows them, and appear on the next redraw. At most 16,777,216 characters of base64 preview data are cached; the least recently shown previews are dropped. One preview larger than that bound by itself is still cached until the next preview loads. The cache is cleared when a session starts or ends.

## Setup

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-codex-minimal-tools"]`.

Open `/extensions:settings`; settings appear under the **Codex Minimal Tools** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`, `autoEnable`: the package and whether its tools join the active set on their own.
- `nativeProviderTools`: the Codex provider shim and the native `image_generation` rewrite.
- `imageGeneration`, `imageOutputDir`, `imageModel`, `directImageApiFallback`: image generation, where images land (relative to the workspace), and the direct Images API fallback, which needs `OPENAI_API_KEY`.
- `viewImage`, `viewImageWorkspaceOnly`: the `view_image` tool and whether it may read outside the workspace.
- `applyPatchEnabled`, `strictPatchMode`, `allowAbsolutePatchPaths`, `deferApplyPatchRendering`: the patch tool; strict mode removes `edit` and `write` from the active set so every edit goes through `apply_patch`.
- `glyphStyle`: Unicode or ASCII symbols; `pi-tool-renderer`'s global override wins when set.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Licence

[MIT](https://github.com/vanillagreencom/kendex/blob/main/LICENSE)
