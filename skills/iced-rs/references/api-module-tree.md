# API discovery

Read when locating an Iced 0.14.0 public API before loading its task reference. The [versioned crate documentation](https://docs.rs/iced/0.14.0/iced/) provides the public module inventory. The pinned [root exports](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs), [advanced exports](https://github.com/iced-rs/iced/blob/0.14.0/src/advanced.rs) and [feature declarations](https://github.com/iced-rs/iced/blob/0.14.0/Cargo.toml) own availability and names.

## Reading routes

Use `INDEX.md` to choose the local reference for a task. Read the source behind a re-export before relying on its signature or feature boundary.

| Task | Start with |
|---|---|
| Launch, update and effects | `application.md`, `task.md`, `subscription.md` |
| Built-in controls and layout | `widgets.md`, then the widget's named reference |
| Canvas, paths and cached geometry | `canvas.md`, `canvas-path.md`, `canvas-geometry.md` |
| GPU primitives | `shader.md` and the bundled renderer source |
| Custom widget state, layout, drawing and overlays | The surface guide, then the relevant `advanced-*` reference |
| Input, timing and windows | `events.md`, `keyboard.md`, `mouse.md`, `touch.md`, `time.md`, `window.md` |
| Styling and text | `theme.md`, `theme-palette.md`, `catalog.md`, `advanced-text.md` |

## Public and advanced APIs

The root crate re-exports types from core, runtime, futures, widgets and the renderer. A top-level name and an advanced name can refer to the same underlying type; the advanced module's feature gate does not imply that every underlying type is unavailable through a public route.

The advanced module exposes custom-widget contracts and low-level operations. Feature declarations separately govern optional widgets, executors, renderers and developer tools. Check the exact declaration for the configured target and feature set. A docs.rs all-features listing does not establish availability in an application's build.

The bundled snapshot's signatures remain the authority described in `../SKILL.md`. This discovery reference does not maintain another symbol inventory or establish native behavior.
