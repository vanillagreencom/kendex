# pi-codex-minimal-tools

![apply_patch side-by-side diff rendering](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-codex-minimal-tools/assets/apply-patch-rendering.png)

![image_generation lifecycle](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-codex-minimal-tools/assets/image-generation.gif)

Minimal Codex/OpenAI tools for Pi. Adds Codex-style tools without replacing Pi natives like `read`, `grep`, `find`, `ls`, `bash`, `edit`, or `write`. Pi 0.75 ships general image-generation APIs and OpenRouter image models; this package keeps the Codex-specific in-chat `image_generation` bridge, `/image-gen` Codex OAuth flow, `view_image`, and `apply_patch`.

## Highlights

- `image_generation` — Codex-specific native image generation on supported `openai-codex` models, with saved local outputs.
- `view_image` — return a local image as model image content (off by default).
- `apply_patch` — local Codex-style patch application.
- `/image-gen <prompt> [reference.png]` — background image generation/editing via Codex OAuth, with a live status card.
- Generated images saved with timestamp filenames, `latest.<ext>` mirrors, metadata, and inline previews.
- Tools only activate on OpenAI/Codex-like models; hidden on Anthropic/Claude-bridge sessions.
- Optional direct OpenAI Images API fallback when `OPENAI_API_KEY` is set.
- Codex provider failures keep HTTP status prefixes such as `HTTP 429:` or `HTTP 503:` so Pi can classify retries and limits.

`web_search` moved to `pi-web-tools`. Install both packages together if you use search.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-codex-minimal-tools):

```bash
pi install npm:@vanillagreen/pi-codex-minimal-tools
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-codex-minimal-tools --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/codex-minimal-tools` | Open settings (or print status if extension-manager isn't installed). |
| `/codex-minimal-tools:doctor` | Run self-checks. |
| `/image-gen <prompt> [reference.png]` | Background image generation/editing via Codex OAuth. |

`/image-gen` uses Codex/ChatGPT OAuth headers from Pi's model registry. It does **not** require `OPENAI_API_KEY`. Reference images may be `@reference.png` or bare local PNG/JPEG/WebP paths. The in-chat `image_generation` tool remains in-stream; use `/image-gen` when you want image work to continue while the agent does other things.

## Settings

Open `/extensions:settings`; settings appear under the **Codex Minimal Tools** tab.

### General

| Setting | What it does |
| --- | --- |
| Enable Codex minimal tools | Register `image_generation`, `view_image`, and `apply_patch`. |
| Auto-add tools to active set | Auto-activate this package's tools when a supported model is selected. |

### Provider

| Setting | What it does |
| --- | --- |
| Native image_generation on Codex | Rewrite this package's `image_generation` function into OpenAI's Responses-API native tool on `openai-codex`. This is Codex-specific and coexists with Pi 0.75's general image APIs. |

### Images

| Setting | What it does |
| --- | --- |
| Enable image_generation | Expose `image_generation` on supported models. |
| Image output directory | Where generated images are saved. Relative paths resolve against the workspace root. |
| Direct image API model | Model for direct OpenAI Images API fallback. |
| Direct Images API fallback | Allow direct OpenAI Images API generation when native Codex generation is unavailable. |
| Enable view_image | Expose `view_image` on image-capable models. |
| Restrict view_image to workspace | Reject `view_image` paths outside the workspace. |

### Patch

| Setting | What it does |
| --- | --- |
| Enable apply_patch | Expose `apply_patch`. |
| Strict patch mode | Block `edit`/`write` so all edits go through `apply_patch`. |
| Allow absolute patch paths | Permit absolute paths in `apply_patch`. |
| Defer apply_patch rendering | Let `pi-tool-renderer` (preferred) handle display instead of registering an in-package renderer. |
