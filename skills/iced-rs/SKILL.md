---
name: iced-rs
description: "Load whenever building or debugging an Iced UI."
summary: "Iced 0.14 GUI reference: custom widgets via iced::advanced, overlays, Canvas, Shader, pane_grid, theming, subscriptions, Elm architecture, with versioned API links and bundled examples."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [ui]
---

# Iced 0.14

## Workflow

1. Classify the surface with [Surface Selection](references/guide-surface-selection.md).
2. Read the canonical example in `examples/`, never generate 0.14 code from memory.
3. Read the guide for that surface; for animated layered UI, `references/guide-animated-layout.md` comes first.
4. When debugging, check the guide’s failure modes and API notes. For animation or rendering, read [the diagnostic checklist](references/guide-animation-debugging.md). Check event capture, layout invalidation, and the 0.14 event signature.

Surface choice: built-in widgets + `.style(closure)` for standard UI; `Canvas` for 2D custom drawing; `Shader` for GPU-dense rendering; `iced::advanced::Widget` for custom events, state, or layout; for a floating layer try `tooltip`, `float`, or `stack`+`opaque` before a custom `Overlay`.

## Bundled resources

### `references/`: API refs and guides

Choose guides and references from the [index](references/INDEX.md). Look up signatures and feature gates through the [Iced 0.14 API page](references/api-module-tree.md).

| Guide | Use |
|---|---|
| `guide-surface-selection.md` | Pick the right primitive |
| `guide-custom-widgets.md` | `iced::advanced::Widget` |
| `guide-custom-overlays.md` | `iced::advanced::overlay::Overlay` |
| `guide-animated-layout.md` | Animated transitions, measured positions, keyed identity, clipping |
| `guide-animation-debugging.md` | Symptom→cause checklist for animation/render bugs |
| `widgets.md` | Widget catalog: every 0.14 widget, notes, canonical example |

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

Renderer source for shader work: `iced_wgpu/src/` (`engine.rs`, `layer.rs`, `quad.rs`, `quad/solid.rs`, `quad/gradient.rs`, `triangle.rs`, `triangle/msaa.rs`, `primitive.rs`, `buffer.rs`, `settings.rs`, `shader/quad.wgsl`).

The bundled `iced_wgpu/` and `examples/` come from [Iced 0.14.0](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/Cargo.toml). Read the bundled source to match the example’s API. To run an example, use the upstream workspace at that revision. The skill omits the workspace manifest.

The snapshot's signatures are the authority. For discovery beyond it, run `ctx7 docs /websites/iced_rs "<query>"`, then check each signature against `https://docs.rs/iced/0.14.0/iced/` or the tag's source, since lookups can return master APIs. Never copy code from upstream `master`.

## Breaking changes from Iced 0.13

- `Widget::update` takes `event: &Event` (by ref, not by value)
- `Widget::layout` takes `&mut Tree`
- Use `keyboard::listen` for ignored key events. See [keyboard subscriptions](references/keyboard.md).

## Implementation rules

### Widget tree consistency

Keep the wrapper in the widget tree as interaction state changes. Attach the handler only when the interaction is enabled.

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

`MouseArea` has no `on_press_maybe` (`button`-only); gate the `on_press` call, not the wrapper.

### view() is pure

Keep `view()` free of side effects, redraw requests, and caches that depend on how often it runs. Change app state in `update()`. Keep persistent widget interaction state in Tree.

### Redraw vs rebuild

A redraw request on its own uses the existing widget tree. Keep widget-driven motion in `widget::Tree` state and use messages to update app-driven motion. See [Redraw vs rebuild](references/animation.md#redraw-vs-rebuild).

### Animation invalidation

Paint-only changes (color, opacity, rotation within fixed bounds) need `shell.request_redraw()`. Layout-affecting changes (size, position, expand/collapse, clipping bounds) need `shell.request_redraw()` **and** `shell.invalidate_layout()`. If geometry updates on a second click, check that the first state change invalidates layout.

### Draw order is z-order

In custom widget `draw()`, child iteration order determines z-order; last drawn is on top. `stack` semantics do not apply inside manual draw loops.

### Overlay visibility requires layout invalidation

A widget that conditionally returns an overlay must call `shell.invalidate_layout()` when visibility changes.

### Custom overlays

Prefer `tooltip`, `float`, or `stack` with `opaque`. In the custom overlay template, keep a fixed child count and reconcile both children whether or not the popup is visible. Pair each forwarded child with its own Tree entry and layout. The popup has a separate layout pass. Follow [the overlay guide](references/guide-custom-overlays.md).

### Overlay viewport contract

In the overlay pattern, pass `Rectangle::INFINITE` to descendant `Widget` methods that take a viewport. Use `bounds: Size` in `Overlay::layout()` to place the popup. A parent viewport can clip popup content.

### Overlay state isolation

Overlay layers (`stack` children beyond the base) must not affect base-layer widget structure. Never change base-layer construction based on overlay presence.

### Overlay starvation

Stacked `mouse_area(...).interaction(...)` layers can block underlying hover/move handlers even without `opaque(...)`. Set `Interaction::Grabbing` on the real drag target, and reserve `opaque(...)` for true capture zones.

### Hover stability

Hover sensors must not wrap content whose size changes during the animation they trigger. Use a stable outer hitbox. See `references/guide-custom-widgets.md` § "Stable hover hit regions."

### Scroll state initialization

`Scrollable::on_scroll` reports changes to the scroll viewport and can publish during redraw processing. Use `Sensor::on_show` to observe initial size and `Sensor::on_resize` for subsequent size changes.

### Single message per interaction

One widget interaction produces one message. Composite actions (tab press becoming a drag) use a state machine in `update()`. When `mouse_area` handles semantics while `button` provides visual feedback, exactly one layer publishes: `mouse_area` owns the semantics and `button` stays visual-only.

`button.on_press` fires on mouse-up; `mouse_area.on_press` fires on mouse-down. Use it for drag initiation.

### pane_grid

- `PaneGrid::min_size` is uniform. Per-pane minimums must be enforced in pane content or in split/resize state.
- TitleBar content must use `Shrink` width so empty space remains for the pick area; `Fill` eliminates it.
- `button` and `mouse_area` both `capture_event()` on press: tab elements capturing means a custom tab drag, an empty title bar means native pane_grid drag.
- Tab drag is `mouse_area.on_press` per tab plus `listen_with` for `CursorMoved`/`ButtonReleased`, with an Idle → Pressed(origin) → Dragging state machine at an 8px threshold.
- `pane_grid::Content::update` forwards to the title bar before an unpicked pane’s body. Do not unconditionally clear state in body-exit handlers that the title bar just established.
- Keep drag feedback inside the picked pane subtree or in `pane_grid::Style`. `mouse_area`/`opaque` pane-drag overlays are rebuild-sensitive and can prevent `Dropped` events; drag previews must reuse the same TitleBar/body shell.

### Subscriptions

Each data source needs stable identity: `Subscription::run_with(id, build_stream)` or `.with(id)`, batched with `Subscription::batch`. See `references/subscription.md`.

Pre-aggregate high-frequency data in the subscription worker: emit one batch per non-empty ~16ms window, over bounded channels with producer-side `try_send()`.

### Theming: no custom Theme type for tokens

Build the palette with `Theme::custom_with_fn("My Dark", palette, |p| theme::palette::Extended::generate(p))`, keep app tokens in a `LazyLock<AppTokens>` sidecar, and route every visual value through it from style closures that ignore the passed `&Theme`. Introduce a custom `Theme` type only when runtime theme switching demands it.

Built-in palette roles are `primary`, `success`, `danger`, `warning`. Fonts load on the entry point (`.font(include_bytes!(...))`); `Font::MONOSPACE` selects the monospace family. Use `Font::with_name("...")` to specify a family by name. See `references/theme.md`, `references/theme-palette.md`, `references/catalog.md`.

### Cache staleness

Before writing cached or mirrored UI state, enumerate every mutation path that can stale it. Extend the existing global event path rather than adding a parallel subscription for the same event family. Admit regression tests for stale cache behavior under code-quality § Tests.

## Architecture

`Message` enum and `State` struct live in the root module; extracted modules receive `&State` or `&mut State`. Extract when a feature is gated and self-contained, forms a cohesive responsibility group, or exceeds ~30 lines over a well-defined `State` subset.

For multiple windows, save the ID from `window::open(settings)` and return its open task. Use `window::close(id)` to close it. See [Window](references/window.md). Testing: `iced_test` provides `Simulator` (headless widget), `Emulator` (full runtime), and snapshot support.

## Dev tools

`cargo-hot`, `comet`, the built-in F12 debugger, stress-test switches, and `iced::debug::time`: `references/debug.md`.
