---
name: iced-rs
description: "Load whenever building or debugging an Iced UI."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Iced 0.14

## Workflow

1. Classify the surface with [Surface Selection](references/guide-surface-selection.md).
2. Read the canonical example in `examples/`.
   - Never generate 0.14 code from memory.
3. Read the guide for that surface.
   - For animated layered UI, read `references/guide-animated-layout.md` first.
4. When debugging, check the guide’s failure modes and API notes.
   - For animation or rendering, read [the diagnostic checklist](references/guide-animation-debugging.md).
   - Check event capture, layout invalidation, and the 0.14 event signature.

## Bundled resources

### `references/`: API refs and guides

- Choose guides and references from the [index](references/INDEX.md).
- Look up signatures and feature gates through the [Iced 0.14 API page](references/api-module-tree.md).

### Bundled Iced 0.14.0 examples

| Need | Read first |
|---|---|
| Custom Widget impl | `examples/custom_widget/src/main.rs` |
| GPU shader pipeline | `examples/custom_shader/` (full dir) |
| Mesh / vector geometry widget | `examples/geometry/src/main.rs` |
| Canvas 2D drawing | `examples/bezier_tool`, `examples/clock`, `examples/color_palette` |
| Canvas animation | `examples/solar_system`, `examples/the_matrix`, `examples/game_of_life` |
| Arc/ring animation | `examples/loading_spinners`, `examples/arc` |
| Modal dialog | `examples/modal/src/main.rs` (stack + opaque) |
| Toast/notification overlay | `examples/toast/src/main.rs` |
| Zoom-on-hover with clipped drawing | `examples/loupe/src/main.rs` |
| Styled components | `examples/styling/` |
| pane_grid layout | `examples/pane_grid/` |
| Multi-window | `examples/multi_window/` |
| WebSocket subscription | `examples/websocket/` |
| Text editing | `examples/editor/` |

### `iced_wgpu/` and external fallbacks

For shader work, read the renderer source in `iced_wgpu/src/`.

The bundled `iced_wgpu/` and `examples/` come from [Iced 0.14.0](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/Cargo.toml).

- Read the bundled source to match the example’s API.
- To run an example, use the upstream workspace at that revision. The skill omits the workspace manifest.

The snapshot's signatures are the authority.

- For discovery beyond it, run `ctx7 docs /websites/iced_rs "<query>"`.
- Then check each signature against `https://docs.rs/iced/0.14.0/iced/` or the tag's source, since lookups can return master APIs.
- Never copy code from upstream `master`.

## Breaking changes from Iced 0.13

- Use `keyboard::listen` for ignored key events. See [keyboard subscriptions](references/keyboard.md).

## Implementation rules

### Widget tree consistency

- Keep the wrapper in the widget tree as interaction state changes.
- Attach the handler only when the interaction is enabled.

```rust
// WRONG: conditional wrapping changes tree shape
if dragging { mouse_area(label).into() } else { label.into() }

// RIGHT
let mut area = mouse_area(label);
if enable {
    area = area.on_press(msg);
}
area
```

### view()

- Keep `view()` free of side effects, redraw requests, and caches that depend on how often it runs.
- Change app state in `update()`.
- Keep persistent widget interaction state in Tree.

### Redraw vs rebuild

A redraw request on its own uses the existing widget tree.

- Keep widget-driven motion in `widget::Tree` state.
- Use messages to update app-driven motion.

See [Redraw vs rebuild](references/animation.md#redraw-vs-rebuild).

### Overlay state isolation

Overlay layers (`stack` children beyond the base) must not affect base-layer widget structure. Never change base-layer construction based on overlay presence.

The one exception is a `float` popover pushed after its trigger in a `column` that holds only the trigger, so no child follows the float. See `references/widget-float.md` § Anchoring to a trigger.

### Overlay starvation

Stacked `mouse_area(...).interaction(...)` layers can block underlying hover/move handlers even without `opaque(...)`.

- Set `Interaction::Grabbing` on the real drag target.
- Reserve `opaque(...)` for true capture zones.

### Hover stability

- Hover sensors must not wrap content whose size changes during the animation they trigger.
- Use a stable outer hitbox. See `references/guide-custom-widgets.md` § "Stable hover hit regions."

### Scroll state initialization

`Scrollable::on_scroll` reports changes to the scroll viewport and can publish during redraw processing.

- Use `Sensor::on_show` to observe initial size.
- Use `Sensor::on_resize` for subsequent size changes.

### Single message per interaction

- One widget interaction produces one message.
- Composite actions (tab press becoming a drag) use a state machine in `update()`.
- When `mouse_area` handles semantics while `button` provides visual feedback, exactly one layer publishes: `mouse_area` owns the semantics and `button` stays visual-only.

`button.on_press` fires on mouse-up; `mouse_area.on_press` fires on mouse-down. Use `mouse_area.on_press` for drag initiation.

### pane_grid

- `PaneGrid::min_size` is uniform. Per-pane minimums must be enforced in pane content or in split/resize state.
- TitleBar content must use `Shrink` width so empty space remains for the pick area; `Fill` eliminates it.
- `button` and `mouse_area` both `capture_event()` on press: tab elements capturing means a custom tab drag, an empty title bar means native pane_grid drag.
- Tab drag is `mouse_area.on_press` per tab plus `listen_with` for `CursorMoved`/`ButtonReleased`, with an Idle → Pressed(origin) → Dragging state machine at an 8px threshold.
- `pane_grid::Content::update` forwards to the title bar before an unpicked pane’s body. Do not unconditionally clear state in body-exit handlers that the title bar just established.
- Keep drag feedback inside the picked pane subtree or in `pane_grid::Style`.
- `mouse_area`/`opaque` pane-drag overlays are rebuild-sensitive and can prevent `Dropped` events.
- Drag previews must reuse the same TitleBar/body shell.

### Subscriptions

- Give each data source a stable identity with `Subscription::run_with(id, build_stream)` or `.with(id)`.
- Combine the sources with `Subscription::batch`.

See `references/subscription.md`.

- Pre-aggregate high-frequency data in the subscription worker.
- Emit one batch per non-empty ~16ms window.
- Use bounded channels with producer-side `try_send()`.

### Theming

- Build the palette with `Theme::custom_with_fn("My Dark", palette, |p| theme::palette::Extended::generate(p))`.
- Keep app tokens in a `LazyLock<AppTokens>` sidecar.
- Route every visual value through it from style closures that ignore the passed `&Theme`.
- Introduce a custom `Theme` type only when runtime theme switching demands it.
- Load fonts on the entry point (`.font(include_bytes!(...))`).
- `Font::MONOSPACE` selects the monospace family.
- Use `Font::with_name("...")` to specify a family by name.

See `references/theme.md`, `references/theme-palette.md`, `references/catalog.md`.

### Cache staleness

- Before writing cached or mirrored UI state, enumerate every mutation path that can stale it.
- Extend the existing global event path rather than adding a parallel subscription for the same event family.

## Architecture

- `Message` enum and `State` struct live in the root module.
- Extracted modules receive `&State` or `&mut State`.
- Extract when a feature is gated and self-contained, forms a cohesive responsibility group, or exceeds ~30 lines over a well-defined `State` subset.

For multiple windows:

- Save the ID from `window::open(settings)`.
- Return its open task.
- Use `window::close(id)` to close it.

See [Window](references/window.md).

For testing, `iced_test` provides `Simulator` (headless widget), `Emulator` (full runtime), and snapshot support.

## Dev tools

For `cargo-hot`, `comet`, the built-in F12 debugger, stress-test switches, and `iced::debug::time`, read `references/debug.md`.
